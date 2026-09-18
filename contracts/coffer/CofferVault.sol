// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./V3Deployments4663.sol";
import "./CofferLiquidShares.sol";
import "./interfaces/ICofferVault.sol";
import "./interfaces/ICofferStrategy.sol";
import "./interfaces/ICofferOperatorRegistry.sol";

interface IWETHV3Rh is IERC20 {
    function deposit() external payable;
}

/// @title CofferVault
/// @notice One share token over several single-pair strategies. The vault is an allocator: it holds target weights,
///         routes each deposit toward whichever strategies are under weight, prices shares on the sum of every
///         strategy's NAV in one unit (aeWETH), and pays a withdrawal by taking the same fraction from every
///         strategy. Shares are a claim on the whole, never on one position, so a loss in one pair is already in
///         everyone's share price and nobody is disadvantaged by which position pays them out.
/// @dev Built from AutoVaultRhV3. What did not change: ETH-only deposits wrapped to aeWETH, the owner-only first
///      mint, min(spot, TWAP-gated) share pricing with virtual offsets, the fee index for off-chain APR. What did:
///      the single `strategy` slot is a list, and every read or call over it is a loop; and there is no clone
///      factory, so the vault is wired in its constructor and creates its own share token.
contract CofferVault is Ownable, ReentrancyGuard, ICofferVault {
    using SafeERC20 for IERC20;

    struct StrategyInfo {
        ICofferStrategy strat;
        /// @dev Target share of NAV, relative to the sum of weights over non-retired strategies. Weights need not
        ///      sum to DIVISOR.
        uint16 targetWeightBps;
        /// @dev A retired strategy takes no new deposits and does not gate minting, but still pays withdrawals
        ///      and still counts in NAV. It is how a dead or dying pair stops steering the allocator.
        bool retired;
    }

    uint256 public constant DIVISOR = 10_000;
    uint256 public constant MAX_STRATEGIES = 8;

    IWETHV3Rh public immutable weth;
    CofferLiquidShares public immutable liquidShares;
    ICofferOperatorRegistry public immutable operatorRegistry;
    address public immutable keeper;
    StrategyInfo[] public strategies;
    mapping(address => bool) public isStrategy;
    /// @notice High-water WETH-per-share (scaled 1e18). Later mints use min(spot, this).
    uint256 public lastSharePriceX18;
    uint256 public accUniswapFeesPerShare;
    uint256 public uniswapFeesCollectedSynced;
    /// @dev Near-full withdraw sweeps leftover shares below this (avoids wei dust blocking empty+HW reset).
    uint256 internal constant MIN_SHARE_DUST = 1e10;
    /// @dev OZ-style virtual offset so a dust seed + donation cannot floor a later mint to 1 share.
    uint256 internal constant VIRTUAL_SHARES = 1e3;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    event Deposit(address indexed user, uint256 wethNotional, uint256 shares, uint256 acc);
    event Withdraw(address indexed user, uint256 shares, uint256 outAmount, uint256 acc);
    event PoolValueSnapshotRecorded(uint256 valueWeth, uint256 uniswapFeesCollected, uint64 indexed timestamp);
    event SharePriceHighWater(uint256 priceX18);
    event StrategyAdded(uint256 indexed index, address indexed strategy, uint16 targetWeightBps);
    event StrategyWeightSet(uint256 indexed index, uint16 targetWeightBps);
    event StrategyRetired(uint256 indexed index, bool retired);
    event Routed(uint256 indexed index, uint256 amount);

    error Unauthorized();
    error ZeroAddress();
    error ZeroValue();
    error FirstMintOwnerOnly();
    error TwapUnavailable();
    error TooManyStrategies();
    error DuplicateStrategy();
    error NotThisVault();
    error NoRoute();
    error BadIndex();

    constructor(address operatorRegistry_, address keeper_) Ownable(msg.sender) {
        if (operatorRegistry_ == address(0) || keeper_ == address(0)) revert ZeroAddress();
        weth = IWETHV3Rh(V3Deployments4663.WETH);
        operatorRegistry = ICofferOperatorRegistry(operatorRegistry_);
        keeper = keeper_;
        liquidShares = new CofferLiquidShares();
    }

    modifier onlyAutoKeeper() {
        if (msg.sender != keeper) revert Unauthorized();
        _;
    }

    function _onlyOperatorOrOwner() internal view {
        if (!operatorRegistry.isOperator(msg.sender) && msg.sender != owner()) revert Unauthorized();
    }

    // ---- strategies ---------------------------------------------------------------------------------------------

    /// @notice Add a strategy constructed against this vault. Owner only; at most `MAX_STRATEGIES`.
    function addStrategy(address strategy_, uint16 targetWeightBps) external onlyOwner {
        if (strategy_ == address(0)) revert ZeroAddress();
        if (isStrategy[strategy_]) revert DuplicateStrategy();
        if (strategies.length >= MAX_STRATEGIES) revert TooManyStrategies();
        ICofferStrategy s = ICofferStrategy(strategy_);
        if (s.vault() != address(this)) revert NotThisVault();
        strategies.push(StrategyInfo({strat: s, targetWeightBps: targetWeightBps, retired: false}));
        isStrategy[strategy_] = true;
        uniswapFeesCollectedSynced += s.UniswapFeesCollected();
        emit StrategyAdded(strategies.length - 1, strategy_, targetWeightBps);
    }

    function setTargetWeight(uint256 index, uint16 targetWeightBps) external {
        _onlyOperatorOrOwner();
        if (index >= strategies.length) revert BadIndex();
        strategies[index].targetWeightBps = targetWeightBps;
        emit StrategyWeightSet(index, targetWeightBps);
    }

    /// @notice Stop routing deposits to a strategy (or resume). Withdrawals and NAV are unaffected either way.
    function setRetired(uint256 index, bool retired) external {
        _onlyOperatorOrOwner();
        if (index >= strategies.length) revert BadIndex();
        strategies[index].retired = retired;
        emit StrategyRetired(index, retired);
    }

    function strategyCount() external view returns (uint256) {
        return strategies.length;
    }

    // ---- NAV ----------------------------------------------------------------------------------------------------

    /// @notice Spot NAV: the sum of every strategy's `poolValue()`, retired ones included.
    function balance() public view override returns (uint256 nav) {
        uint256 n = strategies.length;
        for (uint256 i; i < n; ++i) {
            nav += strategies[i].strat.poolValue();
        }
    }

    /// @dev Gated NAV for minting. An active strategy whose TWAP gate is closed returns 0 here and the mint reverts,
    ///      exactly as a single-strategy vault would. A retired strategy must not be able to block minting forever
    ///      through a dead oracle, so it contributes the smaller of its spot and its TWAP value instead; its
    ///      weight in NAV is by construction small, which bounds what a manipulated spot there could do.
    function _gatedNav() internal view returns (uint256 nav) {
        uint256 n = strategies.length;
        for (uint256 i; i < n; ++i) {
            StrategyInfo storage info = strategies[i];
            uint256 twap = info.strat.poolValueTwap();
            if (info.retired) {
                uint256 spot = info.strat.poolValue();
                nav += twap == 0 ? spot : Math.min(spot, twap);
            } else {
                if (twap == 0) return 0;
                nav += twap;
            }
        }
    }

    function _totalFeesCollected() internal view returns (uint256 total) {
        uint256 n = strategies.length;
        for (uint256 i; i < n; ++i) {
            total += strategies[i].strat.UniswapFeesCollected();
        }
    }

    /// @notice Emit NAV + cumulative Uniswap fees for off-chain indexing. Keeper-only.
    function recordPoolValueSnapshot() external override onlyAutoKeeper {
        emit PoolValueSnapshotRecorded(balance(), _totalFeesCollected(), uint64(block.timestamp));
    }

    function balanceOf(address account) public view override returns (uint256) {
        return liquidShares.balanceOf(account);
    }

    function totalSupply() public view override returns (uint256) {
        return liquidShares.totalSupply();
    }

    // ---- deposit ------------------------------------------------------------------------------------------------

    function depositETH() external payable override nonReentrant returns (uint256 shares) {
        if (msg.value == 0) revert ZeroValue();
        weth.deposit{value: msg.value}();
        return _mintSharesAndDeploy(msg.value);
    }

    function _mintSharesAndDeploy(uint256 amount) internal returns (uint256 shares) {
        uint256 n = strategies.length;
        if (n == 0) revert NoRoute();
        uint256 supply = totalSupply();
        if (supply == 0 && msg.sender != owner()) revert FirstMintOwnerOnly();

        // Collect fees everywhere before pricing so they accrue to the pre-mint supply.
        for (uint256 i; i < n; ++i) {
            strategies[i].strat.syncFees();
        }
        uint256 navBefore = balance();
        uint256 navTwap;
        if (supply != 0) {
            navTwap = _gatedNav();
            if (navTwap == 0) revert TwapUnavailable();
        }
        _route(amount);
        uint256 navAfter = balance();
        uint256 credited = navAfter > navBefore ? navAfter - navBefore : 0;
        // Cap to deposited WETH so spot/NAV jumps between reads cannot overmint shares (V-NAV-MINT).
        if (credited > amount) credited = amount;
        shares = _sharesForDeposit(credited, navBefore, supply, navTwap);
        if (shares == 0) revert ZeroValue();
        _syncAcc();
        liquidShares.mint(msg.sender, shares);
        _bumpSharePriceHighWater(balance(), totalSupply());
        emit Deposit(msg.sender, credited, shares, accUniswapFeesPerShare);
    }

    /// @dev Split `amount` across non-retired strategies. Each gets a share of the deposit proportional to how far it
    ///      sits below its target weight of total NAV, so weights self-correct as pairs drift. If nothing is under
    ///      weight, split by target weights. Weights float otherwise: the vault never swaps between strategies,
    ///      because realising one pair's gains to chase another's losses pays fees and impact for a rebalance no
    ///      shareholder asked for. Any strategy's refusal (a closed quote-pool gate) reverts the deposit whole.
    function _route(uint256 amount) internal {
        uint256 n = strategies.length;
        uint256 nav = balance();
        uint256 totalWeight;
        for (uint256 i; i < n; ++i) {
            StrategyInfo storage info = strategies[i];
            if (!info.retired) totalWeight += info.targetWeightBps;
        }
        if (totalWeight == 0) revert NoRoute();
        // Targets are shares of the live weights, so weights need not sum to DIVISOR and retiring a strategy
        // redistributes its target over the rest instead of leaving it unclaimed.
        uint256[] memory want = new uint256[](n);
        uint256 totalWant;
        for (uint256 i; i < n; ++i) {
            StrategyInfo storage info = strategies[i];
            if (info.retired || info.targetWeightBps == 0) continue;
            uint256 target = Math.mulDiv(nav + amount, info.targetWeightBps, totalWeight);
            uint256 have = info.strat.poolValue();
            if (target > have) {
                want[i] = target - have;
                totalWant += want[i];
            }
        }
        // Size every part first, then fold the rounding remainder into the largest one, then send. A remainder sent
        // on its own would be a wei-sized deposit that a conversion floor rounds to nothing and refuses.
        uint256[] memory part = new uint256[](n);
        uint256 sent;
        uint256 biggest = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            StrategyInfo storage info = strategies[i];
            if (info.retired || info.targetWeightBps == 0) continue;
            part[i] = totalWant > 0
                ? Math.mulDiv(amount, want[i], totalWant)
                : Math.mulDiv(amount, info.targetWeightBps, totalWeight);
            sent += part[i];
            if (biggest == type(uint256).max || part[i] > part[biggest]) biggest = i;
        }
        if (biggest == type(uint256).max) revert NoRoute();
        part[biggest] += amount - sent;
        for (uint256 i; i < n; ++i) {
            if (part[i] > 0) _send(i, part[i]);
        }
    }

    function _send(uint256 i, uint256 part) internal {
        ICofferStrategy s = strategies[i].strat;
        IERC20(address(weth)).forceApprove(address(s), part);
        s.deposit(part);
        emit Routed(i, part);
    }

    /// @dev Owner seeds 1:1. Later min(spot, gated TWAP); high-water only if TWAP is unreadable.
    function _sharesForDeposit(uint256 credited, uint256 navBefore, uint256 supply, uint256 navTwap)
        internal
        view
        returns (uint256)
    {
        if (supply == 0) return credited;
        uint256 sharesSpot = navBefore == 0
            ? type(uint256).max
            : Math.mulDiv(credited, supply + VIRTUAL_SHARES, navBefore + VIRTUAL_ASSETS);
        if (navTwap > 0) {
            return Math.min(sharesSpot, Math.mulDiv(credited, supply + VIRTUAL_SHARES, navTwap + VIRTUAL_ASSETS));
        }
        if (lastSharePriceX18 == 0) return sharesSpot;
        return Math.min(sharesSpot, Math.mulDiv(credited, 1e18, lastSharePriceX18));
    }

    function _bumpSharePriceHighWater(uint256 nav, uint256 supply) internal {
        if (supply == 0 || nav == 0) return;
        uint256 priceX18 = Math.mulDiv(nav, 1e18, supply);
        if (priceX18 > lastSharePriceX18) {
            lastSharePriceX18 = priceX18;
            emit SharePriceHighWater(priceX18);
        }
    }

    // ---- withdraw -----------------------------------------------------------------------------------------------

    /// @notice Burn `shares` and take that fraction of every strategy — position, idle and reserve alike — paid
    ///         in aeWETH at each strategy's exit floor, in kind for any leg a floor refuses. Retired strategies pay
    ///         too: their value is the shareholder's whether or not the allocator still feeds them. One strategy
    ///         reverting reverts the whole withdrawal; there are no partial burns.
    function withdraw(uint256 shares) external override nonReentrant returns (uint256 received) {
        uint256 supply = totalSupply();
        uint256 bal = balanceOf(msg.sender);
        if (shares == 0 || supply == 0) revert ZeroValue();
        // Clamp rather than revert. A caller sizing shares from a supply or NAV that has since moved overshoots its
        // own balance, and reverting gives it no way to tell that apart from an empty vault: estimation just fails
        // and no transaction is produced. Nobody can withdraw more than they hold either way.
        if (shares > bal) shares = bal;
        // Treat near-full personal exits as full exits so wei dust is not left behind.
        if (bal - shares < MIN_SHARE_DUST) shares = bal;
        _syncAcc();
        uint256 beforeBal = weth.balanceOf(msg.sender);
        uint256 n = strategies.length;
        for (uint256 i; i < n; ++i) {
            strategies[i].strat.withdraw(shares, msg.sender, ICofferStrategy.WithdrawToken.WETH);
        }
        liquidShares.burn(msg.sender, shares);
        if (totalSupply() == 0) lastSharePriceX18 = 0;
        uint256 afterBal = weth.balanceOf(msg.sender);
        received = afterBal > beforeBal ? afterBal - beforeBal : 0;
        emit Withdraw(msg.sender, shares, received, accUniswapFeesPerShare);
    }

    function _syncAcc() internal {
        uint256 feesNow = _totalFeesCollected();
        uint256 supply = liquidShares.totalSupply();
        if (supply > 0 && feesNow > uniswapFeesCollectedSynced) {
            accUniswapFeesPerShare += (feesNow - uniswapFeesCollectedSynced) * 1e18 / supply;
        }
        uniswapFeesCollectedSynced = feesNow;
    }

    receive() external payable {
        revert("use depositETH");
    }
}

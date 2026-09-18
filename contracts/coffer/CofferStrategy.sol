// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./V3Deployments4663.sol";
import "./CofferStrategyManager.sol";
import "./libraries/LiquidityLibraryV2.sol";
import "./libraries/AutoBandLib.sol";
import "./libraries/TrailingFloorLib.sol";
import "./libraries/TwapQuoteLib.sol";
import "./libraries/CofferSwapLib.sol";
import "./interfaces/ICofferStrategy.sol";
import "./interfaces/ICofferSwapRouter.sol";
import "./interfaces/ICofferOperatorRegistry.sol";
import "./interfaces/ICofferVault.sol";
import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IUniswapV3Factory.sol";
import "./interfaces/IUniswapV3PoolMinimal.sol";

contract CofferStrategy is CofferStrategyManager, ReentrancyGuard, IERC721Receiver, ICofferStrategy {
    using SafeERC20 for IERC20;
    using LiquidityLibraryV2 for LiquidityLibraryV2.PositionState;

    error E();

    /// @notice Everything a strategy needs at construction. There is no clone factory, so there is no second
    ///         initialisation step: the pair, the infra and the reserve mode are all fixed here.
    struct Config {
        /// @dev The pair's quote token: aeWETH for a volatile/WETH pair, USDG for a stock/USDG pair.
        address quote;
        /// @dev QUOTE/aeWETH Uniswap V3 pool used to value QUOTE in the unit of account. `address(0)` when
        ///      `quote` is aeWETH; otherwise a pool of exactly those two tokens. Its fee tier is read from it.
        address quotePool;
        address vault;
        address swapRouter;
        address operatorRegistry;
        address keeper;
        address feeManager;
        address asset;
        uint24 poolFee;
        ReserveMode reserveMode;
    }

    INonfungiblePositionManager public immutable positionManager;
    IUniswapV3Factory public immutable v3Factory;
    /// @notice The vault's unit of account (aeWETH). Deposits arrive in it, withdrawals and NAV are reported in it.
    IERC20 private immutable UNIT;
    /// @notice The pair's quote leg: aeWETH for a volatile/WETH pair, USDG for a stock/USDG pair. Every band,
    ///         swap floor and reserve bucket in this contract is denominated against `QUOTE`; only the edges —
    ///         deposit, withdraw, NAV, fee routing — convert to `UNIT`.
    IERC20 private immutable QUOTE;
    /// @notice QUOTE/UNIT reference pool for that conversion. Unset when QUOTE is UNIT.
    IUniswapV3PoolMinimal private immutable _quotePool;
    uint24 private immutable _quotePoolFee;

    LiquidityLibraryV2.PositionState private liqPos;
    IERC20 private _asset;
    ICofferSwapRouter public swapRouter;
    ICofferOperatorRegistry public immutable operatorRegistry;
    IUniswapV3PoolMinimal private _pool;

    address public immutable vault;
    address public immutable keeper;
    address private immutable _feeManager;
    uint24 public poolFee;
    bool public watched;
    int24 public lastBandBaseTick;
    bool public hasBandBase;
    uint256 public lastHarvest;
    uint256 public lastRebalanceTime;
    uint256 public UniswapFeesCollected;
    uint256 public reservedAsset;
    uint256 public reservedQuote;
    /// @notice Idle (in QUOTE) left behind by the last in-range remint. While idle stays at or below this, the
    ///         in-range path will not remint again: the position already declined to absorb it, and repeating the
    ///         rotation churns the position without changing the inventory. Cleared by an out-of-range move.
    uint256 internal idleRemintFloor;
    uint256 private constant LIQUIDITY_DUST = 1_000_000_000_000;

    /// @dev `LIQUIDITY_DUST` is 1e12 wei of an 18-decimal token. USDG is 6 decimals, so the same raw number is
    ///      $1,000,000 and would decline every realistic stock mint. Scale with the token.
    function _dust(IERC20 token) internal view returns (uint256) {
        return LiquidityLibraryV2.dustOf(address(token), LIQUIDITY_DUST);
    }

    function _bothDust(uint256 assetBal, uint256 quoteBal) internal view returns (bool) {
        return assetBal <= _dust(_asset) && quoteBal <= _dust(QUOTE);
    }

    /// @notice `ACTIVE` runs the band; `IDLE` holds QUOTE only, after `exitToQuote`, until the next `changeAsset`.
    ///         The keeper does nothing in IDLE, so it cannot remint an asset the operator is rotating away from.
    enum Mode {
        ACTIVE,
        IDLE
    }
    Mode public mode;
    /// @notice Assets this strategy may hold. Owner-managed; the current asset is always in it. The set is read
    ///         from `AllowedTokenSet` events; there is no on-chain enumeration.
    mapping(address => bool) public isAllowedToken;

    event AssetChanged(address indexed previousAsset, address indexed newAsset, uint24 poolFee, uint256 quoteAfterExit);
    event ExitedToQuote(address indexed asset, uint256 quoteAfterExit);
    event AllowedTokenSet(address indexed token, bool allowed);

    // `SwapFailed` is emitted from this address by `CofferSwapLib` (delegatecall); see the library for its declaration.

    /// @notice Deployer is owner. Robinhood (4663) Uniswap v3 addresses are compiled in; the pair, the quote
    ///         conversion and the infra come from `cfg`.
    constructor(Config memory cfg) CofferStrategyManager() {
        positionManager = INonfungiblePositionManager(V3Deployments4663.NPM);
        v3Factory = IUniswapV3Factory(V3Deployments4663.FACTORY);
        UNIT = IERC20(V3Deployments4663.WETH);
        if (
            cfg.quote == address(0) || cfg.vault == address(0) || cfg.swapRouter == address(0)
                || cfg.operatorRegistry == address(0) || cfg.keeper == address(0) || cfg.feeManager == address(0)
                || cfg.asset == address(0) || cfg.asset == cfg.quote || cfg.asset == V3Deployments4663.WETH
        ) revert E();
        QUOTE = IERC20(cfg.quote);
        if (cfg.quote == V3Deployments4663.WETH) {
            if (cfg.quotePool != address(0)) revert E();
            _quotePoolFee = 0;
        } else {
            IUniswapV3PoolMinimal qp = IUniswapV3PoolMinimal(cfg.quotePool);
            address t0 = qp.token0();
            address t1 = qp.token1();
            bool ok = (t0 == cfg.quote && t1 == V3Deployments4663.WETH) || (t1 == cfg.quote && t0 == V3Deployments4663.WETH);
            if (!ok) revert E();
            _quotePoolFee = qp.fee();
        }
        _quotePool = IUniswapV3PoolMinimal(cfg.quotePool);

        address pool_ = v3Factory.getPool(cfg.asset, cfg.quote, cfg.poolFee);
        if (pool_ == address(0)) revert E();
        vault = cfg.vault;
        swapRouter = ICofferSwapRouter(cfg.swapRouter);
        operatorRegistry = ICofferOperatorRegistry(cfg.operatorRegistry);
        keeper = cfg.keeper;
        _feeManager = cfg.feeManager;
        _asset = IERC20(cfg.asset);
        _pool = IUniswapV3PoolMinimal(pool_);
        poolFee = cfg.poolFee;
        isAllowedToken[cfg.asset] = true;
        emit AllowedTokenSet(cfg.asset, true);
        reserveMode = cfg.reserveMode;
        int24 sp = _pool.tickSpacing();
        if (sp <= 0) revert E();
        _alignBandOffsets(sp);
        _asset.forceApprove(address(positionManager), type(uint256).max);
        QUOTE.forceApprove(address(positionManager), type(uint256).max);
    }

    function renounceOwnership() public pure override {
        revert E();
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function ASSET() external view override returns (address) {
        return address(_asset);
    }

    function quoteToken() external view override returns (address) {
        return address(QUOTE);
    }

    /// @notice Repoint this strategy at a different swap router.
    function setSwapRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert E();
        swapRouter = ICofferSwapRouter(router_);
    }

    function pool() external view override returns (address) {
        return address(_pool);
    }

    function setWatched(bool status) external override {
        if (msg.sender != keeper && msg.sender != owner()) revert E();
        watched = status;
    }

    // ---- rotation ----------------------------------------------------------------------------------------------

    /// @notice Allow or disallow `token` as a rotation target. The current asset cannot be disallowed.
    function setAllowedToken(address token, bool allowed) external onlyOwner {
        if (token == address(0) || token == address(QUOTE) || token == address(UNIT)) revert E();
        if (!allowed && token == address(_asset)) revert E();
        isAllowedToken[token] = allowed;
        emit AllowedTokenSet(token, allowed);
    }

    function _onlyOperatorOrOwner() internal view {
        if (!operatorRegistry.isOperator(msg.sender) && msg.sender != owner()) revert E();
    }

    /// @notice Rotate the position to `newAsset`/QUOTE on the `newPoolFee` pool. Flattens the current position,
    ///         sells the old asset for QUOTE at the rebalance floor, re-points the pair, re-peels the reserve from
    ///         the QUOTE inventory, and remints at the band ratio. Reverts unless the old asset is down to dust
    ///         afterward — a strategy holding an asset its accounting no longer sees is not a state to be in. For a
    ///         position too large to sell at the floor in one go, `exitToQuote` first and `sellAsset` in tranches.
    /// @dev Also the way back from IDLE: calling it with the current asset re-enters the band.
    function changeAsset(address newAsset, uint24 newPoolFee) external nonReentrant {
        _onlyOperatorOrOwner();
        if (!isAllowedToken[newAsset]) revert E();
        if (newAsset == address(_asset) && newPoolFee == poolFee && mode == Mode.ACTIVE) revert E();
        address newPool = v3Factory.getPool(newAsset, address(QUOTE), newPoolFee);
        if (newPool == address(0)) revert E();

        address previous = address(_asset);
        uint256 quoteBal = _exitToQuoteInternal();
        uint256 left = _asset.balanceOf(address(this));
        if (left > _dust(_asset)) revert E();
        if (left > 0) _asset.safeTransfer(_feeManager, left);
        if (newAsset != previous) {
            _asset.forceApprove(address(positionManager), 0);
            _asset = IERC20(newAsset);
            _asset.forceApprove(address(positionManager), type(uint256).max);
        }
        _pool = IUniswapV3PoolMinimal(newPool);
        poolFee = newPoolFee;
        int24 sp = _pool.tickSpacing();
        if (sp <= 0) revert E();
        _alignBandOffsets(sp);
        hasBandBase = false;
        idleRemintFloor = 0;
        // The reserve was consumed by the exit; rebuild it from the QUOTE inventory in whichever mode applies.
        // In PAIRED mode it stays quote-only until the next deposit's peel, which is the accepted drift.
        _setReserved(0, _min(Math.mulDiv(quoteBal, _bps(reserveBps), DIVISOR), quoteBal));
        mode = Mode.ACTIVE;
        emit AssetChanged(previous, newAsset, newPoolFee, quoteBal);
        _remintAtTarget();
    }

    /// @notice Flatten the position, sell what the floor allows, and hold the rest idle in IDLE mode. Unsold asset
    ///         stays counted in NAV as this strategy's asset; the keeper stands down until `changeAsset` re-enters.
    function exitToQuote() external nonReentrant {
        _onlyOperatorOrOwner();
        if (mode == Mode.IDLE) revert E();
        uint256 quoteBal = _exitToQuoteInternal();
        mode = Mode.IDLE;
        emit ExitedToQuote(address(_asset), quoteBal);
    }

    /// @notice In IDLE, sell up to `amount` of the remaining asset for QUOTE at the rebalance floor — the way a
    ///         position too large for one swap is unwound in tranches before `changeAsset`.
    function sellAsset(uint256 amount) external nonReentrant {
        _onlyOperatorOrOwner();
        if (mode != Mode.IDLE) revert E();
        _swap(_asset, amount, maxTwapDeviationBps, swapSlippageBps);
    }

    /// @dev Burn the position, collect, release the reserve, and sell ASSET for QUOTE at the rebalance floor.
    ///      Reverts if the pair is not priceable at all; a refused sale is not a revert, the asset simply stays.
    ///      Returns the QUOTE balance afterward.
    function _exitToQuoteInternal() internal returns (uint256 quoteBal) {
        if (_rebalancePrice1e18() == 0) revert E();
        if (liqPos.positionId != 0) {
            _decreaseAllLiquidity();
            liqPos.positionId = 0;
        }
        _setReserved(0, 0);
        uint256 assetBal = _asset.balanceOf(address(this));
        if (assetBal > 0) _swap(_asset, assetBal, maxTwapDeviationBps, swapSlippageBps);
        quoteBal = QUOTE.balanceOf(address(this));
    }

    function _isOperator() internal view override returns (bool) {
        return operatorRegistry.isOperator(msg.sender);
    }

    /// @dev The protocol slice of collected fees goes to the fee manager in kind. There is no staking split: what
    ///      is not taken as protocol fee stays in the position and compounds for shareholders.
    function _routeProtocolFee(address token, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(token).safeTransfer(_feeManager, amount);
    }

    /// @dev Swap route through the pair pool, TWAP expressed against QUOTE.
    function _pairRoute(uint256 maxDevBps, uint256 slipBps) internal view returns (CofferSwapLib.Route memory) {
        return CofferSwapLib.Route(swapRouter, _pool, address(QUOTE), poolFee, maxDevBps, slipBps, twapSeconds);
    }

    /// @dev Swap route through the quote pool, TWAP expressed against UNIT. Meaningless when QUOTE is UNIT.
    function _quoteRoute(uint256 maxDevBps, uint256 slipBps) internal view returns (CofferSwapLib.Route memory) {
        return CofferSwapLib.Route(swapRouter, _quotePool, address(UNIT), _quotePoolFee, maxDevBps, slipBps, twapSeconds);
    }

    function _onlyVault() internal view {
        if (msg.sender != vault) revert E();
    }

    function _onlyKeeper() internal view {
        if (
            msg.sender != keeper && msg.sender != address(this) && !operatorRegistry.isOperator(msg.sender)
                && msg.sender != owner()
        ) revert E();
    }

    function _readSlot0() internal view returns (uint160 sqrtPriceX96, int24 tick) {
        (sqrtPriceX96, tick,,,,,) = _pool.slot0();
    }

    function _inOuterRange() internal view returns (bool) {
        if (liqPos.positionId == 0) return false;
        (, int24 tick) = _readSlot0();
        return _inOuterRange(tick);
    }

    function _inOuterRange(int24 tick) internal view returns (bool) {
        return AutoBandLib.inBand(tick, liqPos.tickLower, liqPos.tickUpper);
    }

    function _inInnerComfort(int24 tick) internal view returns (bool) {
        if (!hasBandBase) return false;
        (int24 lower, int24 upper) =
            AutoBandLib.innerTicks(lastBandBaseTick, _spacing(), innerBelowTicks, innerAboveTicks);
        return AutoBandLib.inBand(tick, lower, upper);
    }

    /// @dev Unreserved idle ≥ 5% of NAV and rebalance-priceable. Reserved inventory does not count.
    uint256 private constant IDLE_DEPLOY_BPS = 500;

    function _idleDeployableMaterial() internal view returns (bool) {
        (uint256 a, uint256 w) = _getDeployableBalances();
        if (a <= _dust(_asset) && w <= _dust(QUOTE)) return false;
        uint256 p = _rebalancePrice1e18();
        if (p == 0) return false;
        uint256 nav = _quoteNavSpot();
        if (nav == 0) return true;
        return w + Math.mulDiv(a, 1e18, p) >= Math.mulDiv(nav, IDLE_DEPLOY_BPS, DIVISOR);
    }

    /// @dev Deployable idle valued in QUOTE. An unreadable price leaves only the QUOTE leg countable, which
    ///      understates idle rather than inventing a value for it. Quote terms are enough here: the latch and the
    ///      materiality test compare idle with itself and with NAV in the same unit.
    function _idleValue() internal view returns (uint256) {
        (uint256 a, uint256 w) = _getDeployableBalances();
        if (a == 0) return w;
        uint256 p = _rebalancePrice1e18();
        if (p == 0) return w;
        return w + Math.mulDiv(a, 1e18, p);
    }

    function keeperCheck() external override nonReentrant returns (bool) {
        _onlyKeeper();
        // IDLE is the operator's: it exited on purpose and will re-enter with `changeAsset`. Nothing to do here.
        if (mode == Mode.IDLE) return false;
        if (liqPos.positionId == 0) {
            (uint256 a, uint256 w) = _getDeployableBalances();
            if (_bothDust(a, w) && _bothDust(reservedAsset, reservedQuote)) return false;
            _remintAtTarget();
            return liqPos.positionId != 0;
        }
        (, int24 tick) = _readSlot0();
        if (_inOuterRange(tick) && _inInnerComfort(tick)) {
            if (!_idleDeployableMaterial()) return false;
            // An in-range add needs both legs at the position's ratio at this tick. Release the short leg from
            // reserve first: one-sided idle otherwise prices to zero liquidity and the add adds nothing.
            (uint256 dA, uint256 dW) = _getDeployableBalances();
            _fundDeficitFromReserve(dA, dW, _bandShare(liqPos.tickLower, liqPos.tickUpper, tick));
            uint128 added = _increaseLiquidityInternal();
            if (!_idleDeployableMaterial()) return added > 0;
            // Idle still material, so the only remaining route is a swap and a remint. Both are bounded: the
            // cooldown says how often, whether or not the add worked, and the latch refuses to repeat a remint
            // that already failed to absorb this same inventory. A rotation whose swap keeps getting rejected
            // would otherwise burn and remint the position on every pass. Report `added`, not `true`, so a
            // pass that deployed nothing says so.
            if (minHarvestDelay > 0 && lastRebalanceTime != 0 && block.timestamp - lastRebalanceTime < minHarvestDelay)
            {
                return added > 0;
            }
            uint256 idleBefore = _idleValue();
            if (idleRemintFloor != 0 && idleBefore <= idleRemintFloor) return added > 0;
            bool reminted = _remintAtTarget();
            // Only a remint that ran latches: a gate refusal deserves another attempt later. Less than 1%
            // absorbed is no progress; rounding alone moves idle a few wei across a rotation.
            if (reminted) {
                uint256 idleAfter = _idleValue();
                idleRemintFloor = idleAfter + idleBefore / 100 >= idleBefore ? idleAfter : 0;
            }
            return reminted;
        }
        // Out of range. The band has to move whatever idle does, so the latch must not hold it back.
        bool moved = _remintAtTarget();
        if (moved) idleRemintFloor = 0;
        return moved;
    }

    function harvestBoolean(bool skipIncreaseLiquidity) external override nonReentrant returns (uint256) {
        _onlyKeeper();
        if (liqPos.positionId == 0) return poolValue();
        if (
            !skipIncreaseLiquidity
                && minHarvestDelay > 0
                && lastHarvest != 0
                && block.timestamp - lastHarvest < minHarvestDelay
        ) return poolValue();
        (,, uint256 valueInQuote) = _collectAllFees(true);
        if (skipIncreaseLiquidity) return poolValue();
        if (valueInQuote == 0) return poolValue();
        // Increase at the band ratio. Do not `_balanceTokens`.
        _increaseLiquidityInternal();
        lastHarvest = block.timestamp;
        return poolValue();
    }

    /// @notice Take `amount` of UNIT from the vault and deploy it. A pair quoted in something other than UNIT
    ///         converts at the quote pool's TWAP floor first. The conversion is not optional: UNIT left behind
    ///         would sit outside every band and reserve, so a refused floor fails the deposit instead — the vault
    ///         reports it the way it reports its own closed TWAP gate, and the user tries again later.
    function deposit(uint256 amount) external override nonReentrant {
        _onlyVault();
        if (amount == 0) revert E();
        UNIT.safeTransferFrom(msg.sender, address(this), amount);
        uint256 capital = amount;
        if (address(QUOTE) != address(UNIT)) {
            uint256 qBefore = QUOTE.balanceOf(address(this));
            _swapQuoteUnit(true, amount);
            capital = QUOTE.balanceOf(address(this)) - qBefore;
            if (capital == 0) revert E();
        }
        _deposit(capital);
    }

    /// @notice Collect pending LP fees into idle before the vault prices a deposit.
    function syncFees() external override nonReentrant {
        _onlyVault();
        _collectAllFees(true);
    }

    function withdraw(uint256 userShares, address receiver, WithdrawToken outToken) external override nonReentrant {
        _onlyVault();
        if (receiver == address(0)) revert E();
        ICofferVault v = ICofferVault(vault);
        uint256 supply = v.totalSupply();
        if (userShares == 0 || supply == 0 || userShares > v.balanceOf(receiver)) revert E();

        if (userShares == supply) {
            if (liqPos.positionId != 0) {
                _decreaseAllLiquidity();
                liqPos.positionId = 0;
            }
            _setReserved(0, 0);
            _payWithdraw(receiver, outToken, _asset.balanceOf(address(this)), QUOTE.balanceOf(address(this)));
            return;
        }

        // Fees into idle first so they pay pro-rata. H001 delta is then principal-only.
        if (liqPos.positionId != 0) _collectAllFees(true);
        uint256 idleAssetBefore = _asset.balanceOf(address(this));
        uint256 idleQuoteBefore = QUOTE.balanceOf(address(this));
        // Share of liquidity units — avoids spot-priced LP exit sizing (H001).
        if (liqPos.positionId != 0) {
            uint128 liquidity = liqPos.getPositionLiquidity(positionManager);
            if (liquidity > 0) {
                uint256 liqToRemove = Math.mulDiv(uint256(liquidity), userShares, supply);
                if (liqToRemove == 0 && userShares > 0) liqToRemove = 1;
                if (liqToRemove > liquidity) liqToRemove = liquidity;
                _decreaseLiquidityInternal(uint128(liqToRemove), false);
            }
        }
        uint256 assetAfter = _asset.balanceOf(address(this));
        uint256 quoteAfter = QUOTE.balanceOf(address(this));
        uint256 userAsset = (assetAfter > idleAssetBefore ? assetAfter - idleAssetBefore : 0)
            + Math.mulDiv(idleAssetBefore, userShares, supply);
        uint256 userQuote = (quoteAfter > idleQuoteBefore ? quoteAfter - idleQuoteBefore : 0)
            + Math.mulDiv(idleQuoteBefore, userShares, supply);
        _consumeReservedShare(userShares, supply);
        _payWithdraw(receiver, outToken, userAsset, userQuote);
    }

    /// @dev Pay `userAsset` + `userQuote` to `receiver`, less the withdrawal fee, in the token asked for. `WETH`
    ///      means the unit of account: ASSET is sold for QUOTE at the widened exit floor, then QUOTE for UNIT at
    ///      the quote pool's; each hop that a floor refuses pays that leg in kind. Shares burn regardless, so
    ///      nothing a user is owed may stay behind.
    function _payWithdraw(address receiver, WithdrawToken outToken, uint256 userAsset, uint256 userQuote) internal {
        uint256 assetFee = Math.mulDiv(userAsset, withdrawalFeeBps, DIVISOR);
        uint256 quoteFee = Math.mulDiv(userQuote, withdrawalFeeBps, DIVISOR);
        userAsset -= assetFee;
        userQuote -= quoteFee;
        if (assetFee > 0) _asset.safeTransfer(_feeManager, assetFee);
        if (quoteFee > 0) QUOTE.safeTransfer(_feeManager, quoteFee);

        CofferSwapLib.Route memory pair = _pairRoute(_withdrawBandBps(), _withdrawSlippageBps());
        if (outToken == WithdrawToken.WETH) {
            if (userAsset > 0) {
                userQuote += CofferSwapLib.sellForWithdraw(pair, _asset, QUOTE, _min(userAsset, _spendable(_asset)), receiver);
            }
            if (address(QUOTE) == address(UNIT)) {
                userQuote = _min(userQuote, QUOTE.balanceOf(address(this)));
                if (userQuote > 0) QUOTE.safeTransfer(receiver, userQuote);
            } else {
                uint256 userUnit = CofferSwapLib.sellForWithdraw(
                    _quoteRoute(_withdrawBandBps(), _withdrawSlippageBps()),
                    QUOTE,
                    UNIT,
                    _min(userQuote, _spendable(QUOTE)),
                    receiver
                );
                userUnit = _min(userUnit, UNIT.balanceOf(address(this)));
                if (userUnit > 0) UNIT.safeTransfer(receiver, userUnit);
            }
        } else {
            if (userQuote > 0) {
                userAsset += CofferSwapLib.sellForWithdraw(pair, QUOTE, _asset, _min(userQuote, _spendable(QUOTE)), receiver);
            }
            userAsset = _min(userAsset, _asset.balanceOf(address(this)));
            if (userAsset > 0) _asset.safeTransfer(receiver, userAsset);
        }
    }

    /// @param newCapital Fresh QUOTE this deposit brought in; the reserve peel is sized from it.
    function _deposit(uint256 newCapital) internal {
        // In IDLE the capital waits as QUOTE, fully counted in NAV, until the operator re-enters a band.
        if (mode == Mode.IDLE) return;
        (uint256 assetBal, uint256 quoteBal) = _getDeployableBalances();
        if (assetBal == 0 && quoteBal == 0) return;
        // A quote-only reserve is peeled before the balancing swap, so the reserve is never bought as ASSET.
        if (reserveMode == ReserveMode.QUOTE_ONLY) {
            _peelReserveForCapital(newCapital);
            (assetBal, quoteBal) = _getDeployableBalances();
            if (assetBal == 0 && quoteBal == 0) return;
        }
        // An in-range add joins the existing position, so it wants that position's ratio at today's tick;
        // anything else mints or remints and wants the fresh band's.
        (int24 tick, int24 lower, int24 upper) = _newBand();
        bool inRange = liqPos.positionId != 0 && _inOuterRange();
        uint256 share = inRange ? _bandShare(liqPos.tickLower, liqPos.tickUpper, tick) : _bandShare(lower, upper, tick);
        _balanceTokens(assetBal, quoteBal, share);
        if (reserveMode == ReserveMode.PAIRED) _peelReserveForCapital(newCapital);
        (assetBal, quoteBal) = _getDeployableBalances();
        if (assetBal == 0 && quoteBal == 0) return;
        if (liqPos.positionId == 0) _mintPosition(lower, upper, tick);
        else if (inRange) _increaseLiquidityInternal();
        else _remintAtTarget();
    }

    /// @dev The band a mint at the current tick would open, spacing-aligned, with the tick it was built from.
    function _newBand() internal view returns (int24 tick, int24 lower, int24 upper) {
        (, tick) = _readSlot0();
        (lower, upper) = AutoBandLib.outerTicks(tick, _spacing(), rangeBelowTicks, rangeAboveTicks);
    }

    /// @dev Asset value share a position `[lower, upper]` takes at `tick`.
    function _bandShare(int24 lower, int24 upper, int24 tick) internal view returns (uint256) {
        return LiquidityLibraryV2.mintShare(lower, upper, tick, _pool.token0() != address(QUOTE));
    }

    function _remintAtTarget() internal returns (bool) {
        // Do not exit the old range when TWAP is unusable: that is the sandwich (dump, remint at the fake
        // tick or sit idle, reverse without our liquidity).
        if (_rebalancePrice1e18() == 0) return false;
        if (liqPos.positionId != 0) {
            _decreaseAllLiquidity();
            liqPos.positionId = 0;
        }
        (uint256 assetBal, uint256 quoteBal) = _getDeployableBalances();
        if (_bothDust(assetBal, quoteBal)) {
            if (_bothDust(reservedAsset, reservedQuote)) return false;
            _setReserved(0, 0);
            (assetBal, quoteBal) = _getDeployableBalances();
        }
        // Pick the band first and aim the swap at its ratio, then mint into that same band. The swap moves the
        // tick a little, so the ratio the mint actually takes differs from the one balanced for by a bounded
        // amount — well inside the idle threshold, and the same either way round.
        (int24 tick, int24 lower, int24 upper) = _newBand();
        uint256 share = _bandShare(lower, upper, tick);
        _fundDeficitFromReserve(assetBal, quoteBal, share);
        (assetBal, quoteBal) = _getDeployableBalances();
        if (_bothDust(assetBal, quoteBal)) return false;
        _balanceTokens(assetBal, quoteBal, share);
        _mintPosition(lower, upper, tick);
        if (liqPos.positionId == 0) return false;
        lastRebalanceTime = block.timestamp;
        return true;
    }

    /// @dev Pull the short side from reserve toward `assetShare1e18` of current deployable value.
    /// @dev Reserve is a balancing source first. It is drawn one leg at a time and is not refilled here, so it
    ///      drifts one-sided across rotations and is rebuilt by the next deposit's peel. Accepted. In
    ///      `QUOTE_ONLY` mode `reservedAsset` is always zero, so only the quote branch can ever release.
    function _fundDeficitFromReserve(uint256 assetBal, uint256 quoteBal, uint256 assetShare1e18) internal {
        uint256 p = _rebalancePrice1e18();
        if (p == 0) return;
        uint256 totalValue = assetBal + Math.mulDiv(quoteBal, p, 1e18);
        if (totalValue == 0) return;
        uint256 target = Math.mulDiv(totalValue, assetShare1e18, 1e18);
        if (assetBal > target && reservedQuote > 0) {
            uint256 pull = _min(Math.mulDiv(assetBal - target, 1e18, p), reservedQuote);
            _setReserved(reservedAsset, reservedQuote - pull);
        } else if (assetBal < target && reservedAsset > 0) {
            uint256 pull = _min(target - assetBal, reservedAsset);
            _setReserved(reservedAsset - pull, reservedQuote);
        }
    }

    /// @notice Peel `reserveBps` of `newCapital` (QUOTE) into reserve. `PAIRED`: pro-rata from both deployable
    ///         legs, per-leg if unpriceable. `QUOTE_ONLY`: from the deployable quote leg alone.
    function _peelReserveForCapital(uint256 newCapital) internal {
        if (reserveBps == 0) return;
        (uint256 a, uint256 q) = _getDeployableBalances();
        uint256 want = Math.mulDiv(newCapital, _bps(reserveBps), DIVISOR);
        if (reserveMode == ReserveMode.QUOTE_ONLY) {
            _setReserved(reservedAsset, reservedQuote + _min(want, q));
            return;
        }
        uint256 p = _rebalancePrice1e18();
        uint256 ra;
        uint256 rq;
        if (p == 0) {
            ra = Math.mulDiv(a, _bps(reserveBps), DIVISOR);
            rq = Math.mulDiv(q, _bps(reserveBps), DIVISOR);
        } else {
            uint256 deployable = q + Math.mulDiv(a, 1e18, p);
            if (deployable == 0) return;
            if (want > deployable) want = deployable;
            ra = Math.mulDiv(a, want, deployable);
            rq = Math.mulDiv(q, want, deployable);
        }
        _setReserved(reservedAsset + _min(ra, a), reservedQuote + _min(rq, q));
    }

    /// @dev Mints into the band the caller balanced for, built by `_newBand` before any swap; `currentTick` is the
    ///      tick that band was centred on and becomes the comfort base.
    function _mintPosition(int24 lower, int24 upper, int24 currentTick) internal {
        if (_rebalancePrice1e18() == 0) return;
        (uint256 assetBal, uint256 quoteBal) = _getDeployableBalances();
        if (_bothDust(assetBal, quoteBal)) return;
        LiquidityLibraryV2.MintContext memory ctx = LiquidityLibraryV2.MintContext({
            npm: positionManager,
            factory: v3Factory,
            pool: _pool,
            weth: address(QUOTE),
            tokens: address(_asset),
            assetPoolV3: address(_pool),
            fee: poolFee,
            tickSpacing: tickSpacing,
            m: 1,
            slippageBps: slippageBps,
            dust: LIQUIDITY_DUST
        });
        (uint256 id, uint128 liquidity) = liqPos.mintNewPositionWithRange(ctx, assetBal, quoteBal, lower, upper);
        if (id != 0 && liquidity > 0) {
            lastBandBaseTick = TrailingFloorLib.alignDown(currentTick, _spacing());
            hasBandBase = true;
        }
    }

    /// @dev Swap deployable inventory toward `assetShare1e18` of its value, which callers derive from the band
    ///      the inventory is about to enter. A policy-set target here is what stranded a third of NAV: the swap
    ///      produced one mix and the mint took another, and the difference sat idle for the keeper to chase.
    function _balanceTokens(uint256 assetBal, uint256 quoteBal, uint256 assetShare1e18) internal {
        if (assetBal == 0 && quoteBal == 0) return;
        // H001-W2: size inventory swaps from TWAP; skip if oracle missing or spot is far from TWAP.
        uint256 p = _rebalancePrice1e18();
        if (p == 0) return;
        uint256 total = assetBal + Math.mulDiv(quoteBal, p, 1e18);
        uint256 target = Math.mulDiv(total, assetShare1e18, 1e18);
        if (assetBal > target) _swap(_asset, assetBal - target, maxTwapDeviationBps, swapSlippageBps);
        else if (assetBal < target) {
            _swap(QUOTE, _min(Math.mulDiv(target - assetBal, 1e18, p), quoteBal), maxTwapDeviationBps, swapSlippageBps);
        }
    }

    /// @dev Pair-pool swap between ASSET and QUOTE. Floor is TWAP-gated; skips if unpriceable so withdrawals can
    ///      still pay in kind. `maxDevBps` and `slipBps` travel together: rebalances pass the tight pair, exits the
    ///      widened pair.
    function _swap(IERC20 tokenIn, uint256 amount, uint256 maxDevBps, uint256 slipBps) internal {
        IERC20 tokenOut = tokenIn == QUOTE ? _asset : QUOTE;
        CofferSwapLib.swapVia(_pairRoute(maxDevBps, slipBps), tokenIn, tokenOut, _min(amount, _spendable(tokenIn)));
    }

    /// @dev Quote-pool swap between QUOTE and UNIT at the rebalance floors. `unitIn` sells UNIT for QUOTE. UNIT
    ///      carries no reserve; QUOTE spends only its unreserved part.
    function _swapQuoteUnit(bool unitIn, uint256 amount) internal {
        if (address(QUOTE) == address(UNIT)) return;
        if (!unitIn) amount = _min(amount, _spendable(QUOTE));
        CofferSwapLib.swapVia(
            _quoteRoute(maxTwapDeviationBps, swapSlippageBps), unitIn ? UNIT : QUOTE, unitIn ? QUOTE : UNIT, amount
        );
    }

    /// @dev Exits tolerate more drift than rebalances: a skipped rebalance retries, a blocked exit strands a user.
    function _withdrawBandBps() internal view returns (uint256) {
        return maxTwapDeviationBps * WITHDRAW_DEVIATION_MULTIPLE;
    }

    /// @dev Exit counterpart to `_withdrawBandBps`. Clamped so the widened haircut stays inside the same 10% the
    ///      base setter enforces, however high an owner has pushed `swapSlippageBps`.
    function _withdrawSlippageBps() internal view returns (uint256) {
        uint256 bps = uint256(swapSlippageBps) * WITHDRAW_SLIPPAGE_MULTIPLE;
        return bps > MAX_WITHDRAW_SLIPPAGE_BPS ? MAX_WITHDRAW_SLIPPAGE_BPS : bps;
    }

    /// @dev The third return is the fees collected for the position valued in QUOTE at spot, after the protocol slice.
    function _collectAllFees(bool trackFees) internal returns (uint256 amount0, uint256 amount1, uint256 valueInQuote) {
        if (liqPos.positionId == 0) return (0, 0, 0);
        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: liqPos.positionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        if (amount0 == 0 && amount1 == 0) return (0, 0, 0);
        address token0 = _pool.token0();
        uint256 feeBps = _protocolFeeBps();
        if (trackFees && feeBps > 0) {
            uint256 fee0 = Math.mulDiv(amount0, feeBps, DIVISOR);
            uint256 fee1 = Math.mulDiv(amount1, feeBps, DIVISOR);
            if (fee0 > 0) _routeProtocolFee(token0, fee0);
            if (fee1 > 0) _routeProtocolFee(_pool.token1(), fee1);
            amount0 -= fee0;
            amount1 -= fee1;
        }
        uint256 feesQuote = token0 == address(QUOTE) ? amount0 : amount1;
        uint256 feesAsset = token0 == address(QUOTE) ? amount1 : amount0;
        if (trackFees && reserveBps > 0) {
            uint256 rq = _min(Math.mulDiv(feesQuote, _bps(reserveBps), DIVISOR), feesQuote);
            uint256 ra = reserveMode == ReserveMode.QUOTE_ONLY
                ? 0
                : _min(Math.mulDiv(feesAsset, _bps(reserveBps), DIVISOR), feesAsset);
            _setReserved(reservedAsset + ra, reservedQuote + rq);
        }
        uint256 p = _spotPrice1e18();
        valueInQuote = feesQuote + (p == 0 ? 0 : Math.mulDiv(feesAsset, 1e18, p));
        if (trackFees) UniswapFeesCollected += _toUnit(valueInQuote, _quotePerUnitSpot());
    }

    function _decreaseAllLiquidity() internal {
        if (liqPos.positionId != 0) _collectAllFees(true);
        _decreaseLiquidityInternal(0, true);
    }

    function _decreaseLiquidityInternal(uint128 liquidityToRemove, bool removeAll) internal {
        if (liqPos.positionId == 0) return;
        LiquidityLibraryV2.DecreaseContext memory ctx =
            LiquidityLibraryV2.DecreaseContext({npm: positionManager, pool: _pool});
        if (removeAll) {
            liqPos.decreaseAllLiquidity(ctx);
            if (liqPos.getPositionLiquidity(positionManager) > 0) {
                liqPos.decreaseAllLiquidity(ctx);
            }
        } else {
            if (liquidityToRemove == 0) return;
            // Skim protocolFeeBps / reserveBps before principal exit (parity with `_decreaseAllLiquidity`).
            _collectAllFees(true);
            liqPos.decreaseLiquidityByAmount(ctx, liquidityToRemove);
        }
        _collectAllFees(false);
    }

    function _increaseLiquidityInternal() internal returns (uint128) {
        if (liqPos.positionId == 0 || _rebalancePrice1e18() == 0) return 0;
        (uint256 assetBal, uint256 quoteBal) = _getDeployableBalances();
        (uint256 amount0, uint256 amount1) = _poolBalances(assetBal, quoteBal);
        LiquidityLibraryV2.IncreaseContext memory ctx = LiquidityLibraryV2.IncreaseContext({
            npm: positionManager, pool: _pool, fee: poolFee, slippageBps: slippageBps, dust: LIQUIDITY_DUST
        });
        return liqPos.increaseLiquidityInternal(ctx, IERC20(_pool.token0()), IERC20(_pool.token1()), amount0, amount1);
    }

    function _getDeployableBalances() internal view returns (uint256 assetBal, uint256 quoteBal) {
        assetBal = _asset.balanceOf(address(this));
        quoteBal = QUOTE.balanceOf(address(this));
        assetBal = assetBal > reservedAsset ? assetBal - reservedAsset : 0;
        quoteBal = quoteBal > reservedQuote ? quoteBal - reservedQuote : 0;
    }

    function _spendable(IERC20 token) internal view returns (uint256 bal) {
        bal = token.balanceOf(address(this));
        uint256 reserved = token == QUOTE ? reservedQuote : reservedAsset;
        return bal > reserved ? bal - reserved : 0;
    }

    function _setReserved(uint256 assetAmount, uint256 quoteAmount) internal {
        reservedAsset = assetAmount;
        reservedQuote = quoteAmount;
    }

    function _consumeReservedShare(uint256 shares, uint256 supply) internal {
        _setReserved(
            reservedAsset - Math.mulDiv(reservedAsset, shares, supply),
            reservedQuote - Math.mulDiv(reservedQuote, shares, supply)
        );
    }

    // ---- prices: ASSET per QUOTE (pair pool) and QUOTE per UNIT (quote pool), both 1e18 ------------------------

    function _spotPrice1e18() internal view returns (uint256) {
        return TwapQuoteLib.spotPrice1e18(_pool, address(QUOTE));
    }

    /// @notice TWAP price for rebalance if spot is within `maxTwapDeviationBps`; else 0 (caller skips).
    function _rebalancePrice1e18() internal view returns (uint256 twap) {
        (twap,) = TwapQuoteLib.bandPrices(_pool, address(QUOTE), twapSeconds, maxTwapDeviationBps);
    }

    /// @dev QUOTE per UNIT at spot; 1e18 when they are the same token. Mirrors the pair-pool trio above so each NAV
    ///      flavour converts with the same kind of reference it priced the pair with.
    function _quotePerUnitSpot() internal view returns (uint256) {
        if (address(QUOTE) == address(UNIT)) return 1e18;
        return TwapQuoteLib.spotPrice1e18(_quotePool, address(UNIT));
    }

    function _quotePerUnitBand() internal view returns (uint256 twap) {
        if (address(QUOTE) == address(UNIT)) return 1e18;
        (twap,) = TwapQuoteLib.bandPrices(_quotePool, address(UNIT), twapSeconds, maxTwapDeviationBps);
    }

    /// @dev QUOTE amount → UNIT at `quotePerUnit1e18`; 0 when unpriceable (never inflated, never a revert).
    function _toUnit(uint256 quoteAmount, uint256 quotePerUnit1e18) internal pure returns (uint256) {
        return quotePerUnit1e18 == 0 ? 0 : Math.mulDiv(quoteAmount, 1e18, quotePerUnit1e18);
    }

    function _poolBalances(uint256 assetBal, uint256 quoteBal) internal view returns (uint256, uint256) {
        return _pool.token0() == address(QUOTE) ? (quoteBal, assetBal) : (assetBal, quoteBal);
    }

    /// @notice Position inventory as (ASSET, QUOTE) at the current pool price.
    function balanceOfPool() public view returns (uint256 assetAmt, uint256 quoteAmt) {
        return liqPos.positionInventory(positionManager, _pool, address(QUOTE));
    }

    // ---- NAV: everything below is in QUOTE until the public views convert to UNIT -------------------------------

    /// @dev Position + idle valued in QUOTE at ASSET price `p`; 0 when `p` is 0.
    function _quoteNavAt(uint256 p) internal view returns (uint256) {
        if (p == 0) return 0;
        (uint256 assetAmt, uint256 quoteAmt) = balanceOfPool();
        uint256 poolQuote = quoteAmt + Math.mulDiv(assetAmt, 1e18, p);
        uint256 idleQuote = QUOTE.balanceOf(address(this)) + Math.mulDiv(_asset.balanceOf(address(this)), 1e18, p);
        return poolQuote + idleQuote;
    }

    /// @dev Spot NAV in QUOTE. An unpriceable ASSET leg counts as zero rather than blocking the read.
    function _quoteNavSpot() internal view returns (uint256) {
        (uint256 assetAmt, uint256 quoteAmt) = balanceOfPool();
        uint256 p = _spotPrice1e18();
        uint256 assetAll = assetAmt + _asset.balanceOf(address(this));
        return quoteAmt + QUOTE.balanceOf(address(this)) + (p == 0 ? 0 : Math.mulDiv(assetAll, 1e18, p));
    }

    /// @dev UNIT that is neither ASSET nor QUOTE: a deposit's conversion that the vault's own accounting has not
    ///      yet seen, or an exit swap's leftover. Always UNIT-denominated already, so it needs no reference.
    function _strayUnit() internal view returns (uint256) {
        return address(QUOTE) == address(UNIT) ? 0 : UNIT.balanceOf(address(this));
    }

    /// @notice Idle inventory (both legs, reserve included) valued in UNIT at spot.
    function balanceOfIdle() public view returns (uint256) {
        uint256 p = _spotPrice1e18();
        uint256 idleQuote =
            QUOTE.balanceOf(address(this)) + (p == 0 ? 0 : Math.mulDiv(_asset.balanceOf(address(this)), 1e18, p));
        return _toUnit(idleQuote, _quotePerUnitSpot()) + _strayUnit();
    }

    /// @notice Spot NAV in UNIT.
    function poolValue() public view override returns (uint256) {
        return _toUnit(_quoteNavSpot(), _quotePerUnitSpot()) + _strayUnit();
    }

    /// @notice NAV using TWAP (same gate as rebalance) for both the pair and the quote conversion. `0` if either
    ///         oracle is unreadable or either spot is off its TWAP.
    function poolValueTwap() public view override returns (uint256) {
        uint256 nav = _toUnit(_quoteNavAt(_rebalancePrice1e18()), _quotePerUnitBand());
        return nav == 0 ? 0 : nav + _strayUnit();
    }


    function balance() external view override returns (uint256) {
        return poolValue();
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}

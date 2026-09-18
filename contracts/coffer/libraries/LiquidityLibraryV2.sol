// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IUniswapV3Factory.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/IUniswapV3PoolMinimal.sol";
import "./TickMath.sol";

/// @title LiquidityLibraryV2
/// @notice Uniswap V3 LP helpers with increase capped to explicit amounts (deployable balances).
library LiquidityLibraryV2 {
    using SafeERC20 for IERC20;

    // FixedPoint96 constants (from LiquidityAmounts)
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    // Structs
    struct PositionState {
        uint256 positionId;
        int24 tickLower;
        int24 tickUpper;
    }

    struct MintContext {
        INonfungiblePositionManager npm;
        IUniswapV3Factory factory;
        IUniswapV3PoolMinimal pool;
        address weth;
        address tokens;
        address assetPoolV3;
        uint24 fee;
        int24 tickSpacing;
        int24 m; // your width multiplier
        uint16 slippageBps;
        uint256 dust; // min dust amount
    }

    struct IncreaseContext {
        INonfungiblePositionManager npm;
        IUniswapV3PoolMinimal pool;
        uint24 fee;
        uint16 slippageBps;
        uint256 dust;
    }

    struct DecreaseContext {
        INonfungiblePositionManager npm;
        IUniswapV3PoolMinimal pool;
    }

    struct IncreaseRequest {
        IERC20 token0;
        IERC20 token1;
        uint256 amount0Max;
        uint256 amount1Max;
    }

    struct IncreaseAmounts {
        uint256 amount0;
        uint256 amount1;
        uint128 liquidity;
    }

    // ============ TickAlignmentMath functions ============

    function alignDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        return r == 0 ? tick : (tick < 0 ? tick - r - spacing : tick - r);
    }

    function alignUp(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        return r == 0 ? tick : (tick < 0 ? tick - r : tick + (spacing - r));
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y;
        z = (x + 1) >> 1;
        while (z < x) {
            x = z;
            z = (y / z + z) >> 1;
        }
        return x;
    }

    function sqrt1e18(uint256 x1e18) internal pure returns (uint256) {
        uint256 maxSafeX1e18 = type(uint256).max / 1e18;

        if (x1e18 > maxSafeX1e18) {
            uint256 sqrtX = sqrt(x1e18);
            // Check if sqrtX * 1e18 would overflow
            if (sqrtX > type(uint256).max / 1e18) {
                revert("overflow");
            }
            return sqrtX * 1e18;
        }

        unchecked {
            return sqrt(x1e18 * 1e18);
        }
    }

    function getSqrtRatios(int24 lowerTick, int24 upperTick) internal pure returns (uint160 sqrtL, uint160 sqrtU) {
        sqrtL = TickMath.getSqrtRatioAtTick(lowerTick);
        sqrtU = TickMath.getSqrtRatioAtTick(upperTick);
    }

    /// @notice Value share of the asset leg that a position `[lower, upper]` takes at `current`, in 1e18.
    /// @dev The mint ratio is fixed by band geometry, not by policy. Per unit liquidity the position holds
    ///      `amount0 = (√Pu − √P) / (√P·√Pu)` and `amount1 = √P − √Pl`; valued in token1 those weigh
    ///      `w0 = (√Pu − √P)·√P / √Pu` and `w1 = √P − √Pl`. Balancing inventory to any other split, however
    ///      chosen, strands the difference as idle the mint cannot use. Symmetric bands come out 50/50; an
    ///      asymmetric band, or a band snapped off-centre by tick spacing, does not, and this is what tells the
    ///      pre-mint swap where to aim instead of a hand-set number.
    /// @dev Outside the band the position is single-sided: at or below `lower` it is all token0, at or above
    ///      `upper` all token1. Callers pass the ticks the mint will actually use (already spacing-aligned).
    function mintShare(int24 lower, int24 upper, int24 current, bool assetIsToken0)
        public pure returns (uint256 assetShare1e18)
    {
        uint256 share0;
        if (current <= lower) {
            share0 = 1e18;
        } else if (current >= upper) {
            share0 = 0;
        } else {
            uint160 sqrtP = TickMath.getSqrtRatioAtTick(current);
            (uint160 sqrtL, uint160 sqrtU) = getSqrtRatios(lower, upper);
            uint256 w0 = Math.mulDiv(uint256(sqrtU) - sqrtP, sqrtP, sqrtU);
            uint256 w1 = uint256(sqrtP) - sqrtL;
            share0 = Math.mulDiv(w0, 1e18, w0 + w1);
        }
        return assetIsToken0 ? share0 : 1e18 - share0;
    }

    function calculateMinAmounts(uint256 amount0, uint256 amount1, uint16 slippageBps)
        internal
        pure
        returns (uint256 min0, uint256 min1)
    {
        require(slippageBps <= 10_000, "slip 100");

        uint256 slippage0 = Math.mulDiv(amount0, slippageBps, 10_000);
        uint256 slippage1 = Math.mulDiv(amount1, slippageBps, 10_000);

        min0 = slippage0 >= amount0 ? 0 : amount0 - slippage0;
        min1 = slippage1 >= amount1 ? 0 : amount1 - slippage1;
    }

    // ============ LiquidityAmounts functions ============

    /// @notice Downcasts uint256 to uint128
    function toUint128(uint256 x) private pure returns (uint128 y) {
        require((y = uint128(x)) == x);
    }

    function getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = Math.mulDiv(sqrtRatioAX96, sqrtRatioBX96, Q96);
        return toUint128(Math.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        return toUint128(Math.mulDiv(amount1, Q96, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            liquidity = getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtRatioX96, sqrtRatioBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioX96, amount1);

            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
        }
    }

    function getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return
            Math.mulDiv(uint256(liquidity) << RESOLUTION, sqrtRatioBX96 - sqrtRatioAX96, sqrtRatioBX96) / sqrtRatioAX96;
    }

    function getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return Math.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96);
    }

    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        }

        if (sqrtRatioX96 <= sqrtRatioAX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = getAmount0ForLiquidity(sqrtRatioX96, sqrtRatioBX96, liquidity);
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioX96, liquidity);
        } else {
            amount1 = getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
        }
    }

    /// @notice The position's current inventory as (asset, quote) at the pool's spot price. Public so the strategy
    ///         does not inline `TickMath` for this one read; it has no runtime bytes to spare for it.
    function positionInventory(
        PositionState storage ps,
        INonfungiblePositionManager npm,
        IUniswapV3PoolMinimal pool,
        address quote
    ) public view returns (uint256 assetAmt, uint256 quoteAmt) {
        if (ps.positionId == 0) return (0, 0);
        uint128 liquidity = getPositionLiquidity(ps, npm);
        (uint160 sqrtP,,,,,,) = pool.slot0();
        (uint160 sqrtL, uint160 sqrtU) = getSqrtRatios(ps.tickLower, ps.tickUpper);
        (uint256 amount0, uint256 amount1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liquidity);
        (assetAmt, quoteAmt) = pool.token0() == quote ? (amount1, amount0) : (amount0, amount1);
    }

    // ============ Position Management functions ============

    function getPositionLiquidity(PositionState storage ps, INonfungiblePositionManager npm)
        internal
        view
        returns (uint128 liquidity)
    {
        if (ps.positionId == 0) return 0;
        (,,,,,,, liquidity,,,,) = npm.positions(ps.positionId);
    }

    function getPositionData(PositionState storage ps, INonfungiblePositionManager npm)
        internal
        view
        returns (address token0, address token1, uint24 fee, int24 posTickLower, int24 posTickUpper, uint128 liquidity)
    {
        if (ps.positionId == 0) return (address(0), address(0), 0, 0, 0, 0);
        (,, token0, token1, fee, posTickLower, posTickUpper, liquidity,,,,) = npm.positions(ps.positionId);
    }

    function mintNewPosition(PositionState storage ps, MintContext memory ctx, uint256 tokenBal, uint256 wethBal)
        internal
        returns (uint256 newTokenId, uint128 newLiquidity)
    {
        if (tokenBal == 0 && wethBal == 0) return (ps.positionId, 0);

        // Recreate your existing Uniswap pool fetch & validation
        address poolAddr = ctx.factory.getPool(ctx.weth, ctx.tokens, ctx.fee);
        require(poolAddr == ctx.assetPoolV3, "mismatch");

        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(poolAddr);
        address token0 = pool.token0();
        address token1 = pool.token1();

        require(
            (token0 == ctx.weth && token1 == ctx.tokens) || (token0 == ctx.tokens && token1 == ctx.weth), "mismatch"
        );
        (, int24 currentTick,,,,,) = pool.slot0();
        int24 base = alignDown(currentTick, ctx.tickSpacing);
        int24 total = int24(int256(ctx.m) * int256(ctx.tickSpacing));
        require(total > 0, "width=0");
        int24 lower;
        int24 upper;
        if (ctx.m % 2 == 0) {
            lower = base - (ctx.m / 2) * ctx.tickSpacing;
            upper = base + (ctx.m / 2) * ctx.tickSpacing;
        } else {
            lower = base - ((ctx.m - 1) / 2) * ctx.tickSpacing;
            upper = lower + total;
        }
        int24 minTick = alignUp(TickMath.MIN_TICK, ctx.tickSpacing);
        int24 maxTick = alignDown(TickMath.MAX_TICK, ctx.tickSpacing);

        if (lower < minTick) lower = minTick;
        if (upper > maxTick) upper = maxTick;
        if (lower >= upper) {
            lower -= ctx.tickSpacing;
            upper += ctx.tickSpacing;
        }
        require(lower < upper, "b ticks");
        ps.tickLower = lower;
        ps.tickUpper = upper;
        uint160 sqrtP;
        (sqrtP,,,,,,) = pool.slot0();
        (uint160 sqrtL, uint160 sqrtU) = getSqrtRatios(ps.tickLower, ps.tickUpper);
        uint256 bal0;
        uint256 bal1;
        if (token0 == ctx.weth) {
            bal0 = wethBal;
            bal1 = tokenBal;
        } else {
            bal0 = tokenBal;
            bal1 = wethBal;
        }
        uint128 liq = getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, bal0, bal1);
        // Dust / one-sided in-range inventory → 0 liquidity; leave idle rather than revert the rotation.
        if (liq == 0) return (ps.positionId, 0);
        (uint256 need0, uint256 need1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        if (need0 > bal0) need0 = bal0;
        if (need1 > bal1) need1 = bal1;
        // Same rounding gap as the increase path: a wei of the short leg prices to non-zero `liq` but a zero
        // `need`, and the position manager mints zero from zero and reverts bare. Ask its question first.
        if (getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, need0, need1) == 0) return (ps.positionId, 0);
        if (_dustLeg(need0, token0, ctx.dust) || _dustLeg(need1, token1, ctx.dust)) return (ps.positionId, 0);
        (uint256 min0, uint256 min1) = calculateMinAmounts(need0, need1, ctx.slippageBps);
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: ctx.fee,
            tickLower: ps.tickLower,
            tickUpper: ps.tickUpper,
            amount0Desired: need0,
            amount0Min: min0,
            amount1Desired: need1,
            amount1Min: min1,
            recipient: address(this),
            deadline: block.timestamp + 300
        });
        (uint256 tokenId, uint128 liquidity,,) = ctx.npm.mint(params);

        ps.positionId = tokenId;
        newTokenId = tokenId;
        newLiquidity = liquidity;
    }

    /// @dev `public`, so this deploys once and links by address instead of inlining into every consumer.
    ///      `CofferStrategy` sits against the EIP-170 runtime limit and this is its largest single block.
    function mintNewPositionWithRange(
        PositionState storage ps,
        MintContext memory ctx,
        uint256 tokenBal,
        uint256 wethBal,
        int24 tickLower,
        int24 tickUpper
    ) public returns (uint256 newTokenId, uint128 newLiquidity) {
        if (tokenBal == 0 && wethBal == 0) return (ps.positionId, 0);

        address poolAddr = ctx.factory.getPool(ctx.weth, ctx.tokens, ctx.fee);
        require(poolAddr == ctx.assetPoolV3, "mismatch");

        IUniswapV3PoolMinimal pool = IUniswapV3PoolMinimal(poolAddr);
        address token0 = pool.token0();
        address token1 = pool.token1();

        require(
            (token0 == ctx.weth && token1 == ctx.tokens) || (token0 == ctx.tokens && token1 == ctx.weth), "mismatch"
        );

        int24 minTick = alignUp(TickMath.MIN_TICK, ctx.tickSpacing);
        int24 maxTick = alignDown(TickMath.MAX_TICK, ctx.tickSpacing);
        int24 lower = tickLower;
        int24 upper = tickUpper;
        if (lower < minTick) lower = minTick;
        if (upper > maxTick) upper = maxTick;
        if (lower >= upper) upper = lower + ctx.tickSpacing;
        require(lower < upper, "b ticks");
        ps.tickLower = lower;
        ps.tickUpper = upper;

        uint160 sqrtP;
        (sqrtP,,,,,,) = pool.slot0();
        (uint160 sqrtL, uint160 sqrtU) = getSqrtRatios(ps.tickLower, ps.tickUpper);
        uint256 bal0;
        uint256 bal1;
        if (token0 == ctx.weth) {
            bal0 = wethBal;
            bal1 = tokenBal;
        } else {
            bal0 = tokenBal;
            bal1 = wethBal;
        }
        uint128 liq = getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, bal0, bal1);
        // Dust / one-sided in-range inventory → 0 liquidity; leave idle rather than revert the rotation.
        if (liq == 0) return (ps.positionId, 0);
        (uint256 need0, uint256 need1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, liq);
        if (need0 > bal0) need0 = bal0;
        if (need1 > bal1) need1 = bal1;
        // Same rounding gap as the increase path: a wei of the short leg prices to non-zero `liq` but a zero
        // `need`, and the position manager mints zero from zero and reverts bare. Ask its question first.
        if (getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, need0, need1) == 0) return (ps.positionId, 0);
        if (_dustLeg(need0, token0, ctx.dust) || _dustLeg(need1, token1, ctx.dust)) return (ps.positionId, 0);
        (uint256 min0, uint256 min1) = calculateMinAmounts(need0, need1, ctx.slippageBps);
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: ctx.fee,
            tickLower: ps.tickLower,
            tickUpper: ps.tickUpper,
            amount0Desired: need0,
            amount0Min: min0,
            amount1Desired: need1,
            amount1Min: min1,
            recipient: address(this),
            deadline: block.timestamp + 300
        });
        (uint256 tokenId, uint128 liquidity,,) = ctx.npm.mint(params);

        ps.positionId = tokenId;
        newTokenId = tokenId;
        newLiquidity = liquidity;
    }

    /// @param amount0Max Cap for token0 (e.g. deployable); also capped to on-strategy balance.
    /// @param amount1Max Cap for token1 (e.g. deployable); also capped to on-strategy balance.
    function increaseLiquidityInternal(
        PositionState storage ps,
        IncreaseContext memory ctx,
        IERC20 token0,
        IERC20 token1,
        uint256 amount0Max,
        uint256 amount1Max
    ) public returns (uint128 addedLiquidity) {
        if (ps.positionId == 0) return 0;
        _validateIncreasePosition(ps, ctx, token0, token1);
        IncreaseRequest memory request = IncreaseRequest(token0, token1, amount0Max, amount1Max);
        IncreaseAmounts memory amounts = _calculateIncreaseAmounts(ps, ctx, request);
        if (amounts.liquidity == 0) return 0;
        (uint256 min0, uint256 min1) = calculateMinAmounts(amounts.amount0, amounts.amount1, ctx.slippageBps);
        INonfungiblePositionManager.IncreaseLiquidityParams memory p =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: ps.positionId,
                amount0Desired: amounts.amount0,
                amount1Desired: amounts.amount1,
                amount0Min: min0,
                amount1Min: min1,
                deadline: block.timestamp + 1200
            });
        (uint128 liqAdded,,) = ctx.npm.increaseLiquidity(p);
        addedLiquidity = liqAdded;
    }

    function _validateIncreasePosition(
        PositionState storage ps,
        IncreaseContext memory ctx,
        IERC20 token0,
        IERC20 token1
    ) private view {
        (address posToken0, address posToken1, uint24 fee,,,) = getPositionData(ps, ctx.npm);
        require(fee == ctx.fee, "wrg f tr");
        require(address(token0) == posToken0 && address(token1) == posToken1, "mismatch");
    }

    function _calculateIncreaseAmounts(
        PositionState storage ps,
        IncreaseContext memory ctx,
        IncreaseRequest memory request
    ) private view returns (IncreaseAmounts memory amounts) {
        uint160 sqrtP;
        (sqrtP,,,,,,) = ctx.pool.slot0();
        (uint160 sqrtL, uint160 sqrtU) = getSqrtRatios(ps.tickLower, ps.tickUpper);
        uint256 bal0 = request.token0.balanceOf(address(this));
        uint256 bal1 = request.token1.balanceOf(address(this));
        if (request.amount0Max < bal0) bal0 = request.amount0Max;
        if (request.amount1Max < bal1) bal1 = request.amount1Max;
        if (bal0 < dustOf(address(request.token0), ctx.dust) && bal1 < dustOf(address(request.token1), ctx.dust)) {
            return amounts;
        }
        uint128 fromBalances = getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, bal0, bal1);
        if (fromBalances == 0) return amounts;
        (amounts.amount0, amounts.amount1) = getAmountsForLiquidity(sqrtP, sqrtL, sqrtU, fromBalances);
        if (amounts.amount0 > bal0) amounts.amount0 = bal0;
        if (amounts.amount1 > bal1) amounts.amount1 = bal1;
        // Price the amounts that will actually be sent, not the balances they were derived from. The two differ
        // by rounding, and the difference is not academic: a single wei of the short leg prices to non-zero
        // liquidity here, then rounds to a zero amount, and the position manager recomputes zero liquidity from
        // that amount and hits `require(amount > 0)` in the pool — a revert with no data, on every keeper pass.
        // Asking the manager's own question before calling it is what turns that into a zero return.
        amounts.liquidity = getLiquidityForAmounts(sqrtP, sqrtL, sqrtU, amounts.amount0, amounts.amount1);
        // A leg that is needed but below dust is not worth an add and cannot survive one: at wei scale the
        // slippage floor rounds to the amount itself, and the pool's own rounding then misses it by a wei.
        if (_dustLeg(amounts.amount0, address(request.token0), ctx.dust)
            || _dustLeg(amounts.amount1, address(request.token1), ctx.dust)) amounts.liquidity = 0;
    }

    /// @dev `dust18` is the 18-decimal threshold (1e12 wei of WETH). A 6-decimal quote such as USDG must
    ///      scale with it or every realistic mint looks like dust: 1e12 of USDG is $1,000,000.
    function dustOf(address token, uint256 dust18) public view returns (uint256) {
        uint8 d = IERC20Metadata(token).decimals();
        if (d >= 18) return dust18;
        uint256 scaled = dust18 / (10 ** (18 - d));
        return scaled == 0 ? 1 : scaled;
    }

    /// @dev Non-zero and below the token's scaled dust. Zero is a leg the range does not need, and is fine.
    function _dustLeg(uint256 amount, address token, uint256 dust18) private view returns (bool) {
        return amount != 0 && amount < dustOf(token, dust18);
    }

    function decreaseAllLiquidity(PositionState storage ps, DecreaseContext memory ctx)
        public
        returns (uint128 totalRemoved)
    {
        if (ps.positionId == 0) return 0;
        uint128 liq = getPositionLiquidity(ps, ctx.npm);
        if (liq == 0) {
            return 0;
        }
        while (liq > 0) {
            INonfungiblePositionManager.DecreaseLiquidityParams memory p =
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: ps.positionId,
                    liquidity: liq,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp + 300
                });
            ctx.npm.decreaseLiquidity(p);
            totalRemoved += liq;
            liq = getPositionLiquidity(ps, ctx.npm);
        }
    }

    function decreaseLiquidityByAmount(PositionState storage ps, DecreaseContext memory ctx, uint128 liqToRemove)
        public
        returns (uint128 removed)
    {
        if (ps.positionId == 0) return 0;
        if (liqToRemove == 0) return 0;

        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: ps.positionId,
                liquidity: liqToRemove,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 300
            });

        ctx.npm.decreaseLiquidity(params);
        removed = liqToRemove;
    }

    /// @notice token1/token0 price increase from `anchorTick` to `currentTick` in bps (10_000 = 100%), when current is above anchor; else 0.
    function priceDeviationBpsAbove(int24 anchorTick, int24 currentTick) internal pure returns (uint256 deviationBps) {
        if (currentTick <= anchorTick) return 0;
        uint160 sa = TickMath.getSqrtRatioAtTick(anchorTick);
        uint160 sc = TickMath.getSqrtRatioAtTick(currentTick);
        uint256 sa2 = uint256(sa) * uint256(sa);
        uint256 sc2 = uint256(sc) * uint256(sc);
        uint256 priceRatio1e18 = Math.mulDiv(sc2, 1e18, sa2);
        if (priceRatio1e18 <= 1e18) return 0;
        return Math.mulDiv(priceRatio1e18 - 1e18, 10000, 1e18);
    }

    /// @notice Trailing-floor depth below current price (bps). E.g. num/den = 1/3 => 3% rally vs baseline => ~1% pullback band under spot.
    function trailingFloorDepthBps(uint256 rallyBps, uint32 num, uint32 den) internal pure returns (uint256 depthBps) {
        if (den == 0) return 0;
        return Math.mulDiv(rallyBps, uint256(num), uint256(den));
    }

    /// @notice Tick at or below the sqrt price that is `depthBps`/10000 below the current token1/token0 price (0 < depthBps < 10_000).
    function floorTickBelowCurrentByBps(int24 currentTick, uint256 depthBps) internal pure returns (int24) {
        if (depthBps == 0) return currentTick;
        if (depthBps >= 10000) depthBps = 9999;
        uint160 sc = TickMath.getSqrtRatioAtTick(currentTick);
        uint256 priceFactor1e18 = Math.mulDiv(10000 - depthBps, 1e18, 10000);
        uint256 sqrtScale1e18 = sqrt1e18(priceFactor1e18);
        uint256 newSqrt256 = Math.mulDiv(uint256(sc), sqrtScale1e18, 1e18);
        if (newSqrt256 <= uint256(TickMath.MIN_SQRT_RATIO)) {
            return TickMath.MIN_TICK;
        }
        if (newSqrt256 >= uint256(TickMath.MAX_SQRT_RATIO)) {
            newSqrt256 = uint256(TickMath.MAX_SQRT_RATIO) - 1;
        }
        return TickMath.getTickAtSqrtRatio(uint160(newSqrt256));
    }
}

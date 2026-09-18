// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IUniswapV3PoolMinimal.sol";
import "./TickMath.sol";

/// @title TwapQuoteLib
/// @notice TWAP-gated spot quotes and swap floors for CofferStrategy.
/// @dev Functions are `public` so this deploys once and links by address instead of inlining into the strategy.
library TwapQuoteLib {
    uint256 internal constant DIVISOR = 10_000;

    /// @dev Quote the opposite token at `sqrtRatioX96`. Excludes pool fee and impact.
    function quoteAtSqrt(uint160 sqrtRatioX96, uint256 amount, bool baseIsToken0) public pure returns (uint256) {
        if (sqrtRatioX96 == 0) return 0;
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            return baseIsToken0
                ? Math.mulDiv(ratioX192, amount, 1 << 192)
                : Math.mulDiv(1 << 192, amount, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
        return baseIsToken0 ? Math.mulDiv(ratioX128, amount, 1 << 128) : Math.mulDiv(1 << 128, amount, ratioX128);
    }

    /// @dev ASSET per WETH in 1e18 from a Uniswap V3 sqrtPriceX96.
    function price1e18FromSqrt(uint160 sqrtP, bool wethIsToken0) public pure returns (uint256) {
        return quoteAtSqrt(sqrtP, 1e18, wethIsToken0);
    }

    /// @dev Spot ASSET per WETH in 1e18.
    function spotPrice1e18(IUniswapV3PoolMinimal pool, address weth) public view returns (uint256) {
        (uint160 sqrtP,,,,,,) = pool.slot0();
        return price1e18FromSqrt(sqrtP, pool.token0() == weth);
    }

    /// @dev Arithmetic-mean tick TWAP via pool `observe`. Returns 0 if disabled or cardinality insufficient.
    function twapSqrtX96(IUniswapV3PoolMinimal pool, uint32 period) public view returns (uint160) {
        if (period == 0) return 0;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = period;
        secondsAgos[1] = 0;
        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 periodI = int56(uint56(period));
            int24 meanTick = int24(delta / periodI);
            if (delta < 0 && (delta % periodI != 0)) meanTick--;
            return TickMath.getSqrtRatioAtTick(meanTick);
        } catch {
            return 0;
        }
    }

    /// @dev ASSET per WETH in 1e18 at the TWAP tick.
    function twapPrice1e18(IUniswapV3PoolMinimal pool, address weth, uint32 period) public view returns (uint256) {
        uint160 sqrtP = twapSqrtX96(pool, period);
        if (sqrtP == 0) return 0;
        return price1e18FromSqrt(sqrtP, pool.token0() == weth);
    }

    /// @dev TWAP price and TWAP sqrt, or `(0, 0)` if unreadable or spot is outside `maxDevBps` of TWAP.
    function bandPrices(IUniswapV3PoolMinimal pool, address weth, uint32 period, uint256 maxDevBps)
        public
        view
        returns (uint256 twap, uint160 twapSqrt)
    {
        twapSqrt = twapSqrtX96(pool, period);
        if (twapSqrt == 0) return (0, 0);
        twap = price1e18FromSqrt(twapSqrt, pool.token0() == weth);
        (uint160 spotSqrt,,,,,,) = pool.slot0();
        uint256 spot = quoteAtSqrt(spotSqrt, 1e18, pool.token0() == weth);
        if (spot == 0) return (0, 0);
        uint256 hi = spot > twap ? spot : twap;
        uint256 lo = spot > twap ? twap : spot;
        if (Math.mulDiv(hi - lo, DIVISOR, twap) > maxDevBps) return (0, 0);
    }

    /// @dev `0` if the oracle is unusable or spot is outside `maxDevBps`. Floor is TWAP quote after `poolFee`, then `slipBps`.
    function minOutAtBand(
        IUniswapV3PoolMinimal pool,
        address weth,
        address tokenIn,
        uint256 amount,
        uint24 poolFee,
        uint256 maxDevBps,
        uint256 slipBps,
        uint32 period
    ) public view returns (uint256) {
        (, uint160 twapSqrt) = bandPrices(pool, weth, period, maxDevBps);
        if (twapSqrt == 0) return 0;
        uint256 quote = quoteAtSqrt(twapSqrt, amount, tokenIn == pool.token0());
        if (quote == 0) return 0;
        // Fee tiers are hundredths of a bip, so /100 puts `poolFee` in bps alongside the tolerance.
        uint256 afterPoolFee = Math.mulDiv(quote, DIVISOR - uint256(poolFee) / 100, DIVISOR);
        return Math.mulDiv(afterPoolFee, DIVISOR - slipBps, DIVISOR);
    }
}

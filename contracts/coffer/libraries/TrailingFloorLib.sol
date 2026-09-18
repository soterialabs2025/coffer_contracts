// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "./TickMath.sol";  

library TrailingFloorLib {
    error SqrtOverflow();

    function alignDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        return r == 0 ? tick : (tick < 0 ? tick - r - spacing : tick - r);
    }

    function alignUp(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 r = tick % spacing;
        return r == 0 ? tick : (tick < 0 ? tick - r : tick + (spacing - r));
    }

    error RangeNotAlignedToSpacing();

    /// @dev `ticks` must be a positive multiple of `spacing` (Uniswap usable-tick step). No silent rounding.
    function requireSpacedTicks(uint256 ticks, int24 spacing) internal pure returns (int24) {
        if (spacing <= 0) revert RangeNotAlignedToSpacing();
        uint256 sp = uint256(uint24(spacing));
        if (ticks == 0 || ticks % sp != 0) revert RangeNotAlignedToSpacing();
        uint256 maxTicks = uint256(uint24(type(int24).max)) / sp * sp;
        if (ticks > maxTicks) revert RangeNotAlignedToSpacing();
        return int24(int256(ticks));
    }

    /// @dev Floor `ticks` to a positive multiple of `spacing` (used after OFFENSIVE ratchet).
    function alignTicksDownToSpacing(uint256 ticks, int24 spacing) internal pure returns (uint256) {
        if (spacing <= 0) return ticks;
        uint256 sp = uint256(uint24(spacing));
        uint256 aligned = (ticks / sp) * sp;
        if (aligned < sp) aligned = sp;
        return aligned;
    }

    /// @dev Uni-style discrete band: `alignDown(current)` ± exact spacing-aligned tick offsets.
    ///      `belowTicks` / `aboveTicks` are tick distances (e.g. 200/400/600), not free-form price %.
    function asymmetricSpacedTicks(
        int24 currentTick,
        int24 spacing,
        uint256 belowTicks,
        uint256 aboveTicks
    ) internal pure returns (int24 lower, int24 upper) {
        int24 below = requireSpacedTicks(belowTicks, spacing);
        int24 above = requireSpacedTicks(aboveTicks, spacing);
        int24 base = alignDown(currentTick, spacing);
        lower = base - below;
        upper = base + above;

        int24 minTick = alignUp(TickMath.MIN_TICK, spacing);
        int24 maxTick = alignDown(TickMath.MAX_TICK, spacing);
        if (lower < minTick) lower = minTick;
        if (upper > maxTick) upper = maxTick;
        if (lower >= upper) {
            lower = base - spacing;
            upper = base + spacing;
            if (lower < minTick) {
                lower = minTick;
                upper = minTick + spacing;
            }
            if (upper > maxTick) {
                upper = maxTick;
                lower = maxTick - spacing;
            }
        }
    }

    function sqrt(uint256 y) private pure returns (uint256 z) {
        if (y == 0) return 0;
        uint256 x = y;
        z = (x + 1) >> 1;
        while (z < x) {
            x = z;
            z = (y / z + z) >> 1;
        }
        return x;
    }

    function sqrt1e18(uint256 x1e18) private pure returns (uint256) {
        uint256 maxSafeX1e18 = type(uint256).max / 1e18;
        if (x1e18 > maxSafeX1e18) {
            uint256 sqrtX = sqrt(x1e18);
            if (sqrtX > type(uint256).max / 1e18) revert SqrtOverflow();
            return sqrtX * 1e18;
        }
        unchecked {
            return sqrt(x1e18 * 1e18);
        }
    }

    function priceDeviationBpsAbove(int24 anchorTick, int24 currentTick) internal pure returns (uint256 deviationBps) {
        if (currentTick <= anchorTick) return 0;
        uint160 sa = TickMath.getSqrtRatioAtTick(anchorTick);
        uint160 sc = TickMath.getSqrtRatioAtTick(currentTick);
        uint256 sa2 = uint256(sa) * uint256(sa);
        uint256 sc2 = uint256(sc) * uint256(sc);
        uint256 priceRatio1e18 = Math.mulDiv(sc2, 1e18, sa2);
        if (priceRatio1e18 <= 1e18) return 0;
        return Math.mulDiv(priceRatio1e18 - 1e18, 10_000, 1e18);
    }

    function trailingFloorDepthBps(uint256 rallyBps, uint32 num, uint32 den) internal pure returns (uint256 depthBps) {
        if (den == 0) return 0;
        return Math.mulDiv(rallyBps, uint256(num), uint256(den));
    }

    function floorTickBelowCurrentByBps(int24 currentTick, uint256 depthBps) internal pure returns (int24) {
        if (depthBps == 0) return currentTick;
        if (depthBps >= 10_000) depthBps = 9999;
        uint160 sc = TickMath.getSqrtRatioAtTick(currentTick);
        uint256 priceFactor1e18 = Math.mulDiv(10_000 - depthBps, 1e18, 10_000);
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

    function ceilTickAboveCurrentByBps(int24 currentTick, uint256 riseBps) internal pure returns (int24) {
        if (riseBps == 0) return currentTick;
        if (riseBps >= 10_000) riseBps = 9999;
        uint160 sc = TickMath.getSqrtRatioAtTick(currentTick);
        uint256 priceFactor1e18 = Math.mulDiv(10_000 + riseBps, 1e18, 10_000);
        uint256 sqrtScale1e18 = sqrt1e18(priceFactor1e18);
        uint256 newSqrt256 = Math.mulDiv(uint256(sc), sqrtScale1e18, 1e18);
        if (newSqrt256 <= uint256(TickMath.MIN_SQRT_RATIO)) {
            newSqrt256 = uint256(TickMath.MIN_SQRT_RATIO) + 1;
        }
        if (newSqrt256 >= uint256(TickMath.MAX_SQRT_RATIO)) {
            return TickMath.MAX_TICK;
        }
        return TickMath.getTickAtSqrtRatio(uint160(newSqrt256));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./TrailingFloorLib.sol";

/// @title AutoBandLib
/// @notice Outer LP span + inner comfort band helpers for AutoStrategy remints.
library AutoBandLib {
    error InnerWiderThanOuter();
    error InnerNotInsideOuter();

    /// @dev Outer LP ticks from current price.
    function outerTicks(int24 currentTick, int24 spacing, uint256 rangeBelowTicks, uint256 rangeAboveTicks)
        internal
        pure
        returns (int24 lower, int24 upper)
    {
        return TrailingFloorLib.asymmetricSpacedTicks(currentTick, spacing, rangeBelowTicks, rangeAboveTicks);
    }

    /// @dev Inner comfort band around the same base tick used for the outer mint.
    function innerTicks(int24 bandBaseTick, int24 spacing, uint256 innerBelowTicks, uint256 innerAboveTicks)
        internal
        pure
        returns (int24 lower, int24 upper)
    {
        return TrailingFloorLib.asymmetricSpacedTicks(bandBaseTick, spacing, innerBelowTicks, innerAboveTicks);
    }

    function inBand(int24 poolTick, int24 lower, int24 upper) internal pure returns (bool) {
        return poolTick >= lower && poolTick < upper;
    }

    function requireInnerWithinOuter(
        uint256 rangeBelowTicks,
        uint256 rangeAboveTicks,
        uint256 innerBelowTicks,
        uint256 innerAboveTicks
    ) internal pure {
        if (innerBelowTicks > rangeBelowTicks || innerAboveTicks > rangeAboveTicks) {
            revert InnerWiderThanOuter();
        }
        if (innerBelowTicks == 0 || innerAboveTicks == 0) revert InnerNotInsideOuter();
    }
}

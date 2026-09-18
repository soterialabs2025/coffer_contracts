// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ICofferKeeper {
    function addStrategy(address strat) external returns (uint256 id);
    function performUpkeep(uint256 id) external;
    function performHarvest(uint256 id, bool skipIncreaseLiquidity) external;
    /// @notice Snapshot vault NAV + UniswapFeesCollected for watched strategy `id` (no harvest).
    function snapshotVaultPoolValue(uint256 id) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Shared operator allowlist for CofferKeeper wallet sharding.
interface ICofferOperatorRegistry {
    function isOperator(address account) external view returns (bool);
}

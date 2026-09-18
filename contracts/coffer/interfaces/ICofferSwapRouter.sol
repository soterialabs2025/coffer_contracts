// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ICofferSwapRouter {
    /// @param minAmountOut Caller-supplied output floor. Must be non-zero; the router does not derive one.
    /// @param deadline Unix timestamp after which the swap reverts. `0` disables the check.
    function swapExactInputSingleStrict(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint128 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external returns (uint256 amountOut);

    function addAuthorizedStrategy(address strategy) external;
    function removeAuthorizedStrategy(address strategy) external;
}

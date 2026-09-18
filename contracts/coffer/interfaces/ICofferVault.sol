// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ICofferVault {
    function depositETH() external payable returns (uint256 shares);
    /// @notice Burn `shares` and receive the unit of account (aeWETH) from every strategy pro-rata. Any leg a
    ///         strategy could not sell at its exit floor arrives in kind alongside.
    function withdraw(uint256 shares) external returns (uint256 received);

    /// @notice Spot NAV across all strategies, in the unit of account.
    function balance() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);

    /// @notice Emit NAV + cumulative Uniswap fees (off-chain). Callable only by the keeper.
    function recordPoolValueSnapshot() external;
}

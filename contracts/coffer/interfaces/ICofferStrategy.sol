// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ICofferStrategy {
    /// @notice `WETH` is the vault's unit of account (aeWETH); `ASSET` is this strategy's own asset leg.
    enum WithdrawToken {
        WETH,
        ASSET
    }

    /// @notice Spot NAV in the unit of account.
    function poolValue() external view returns (uint256);
    /// @notice TWAP-gated NAV in the unit of account. `0` when either the pair or the quote reference is unusable.
    function poolValueTwap() external view returns (uint256);
    function balance() external view returns (uint256);
    function UniswapFeesCollected() external view returns (uint256);
    function vault() external view returns (address);
    function keeper() external view returns (address);
    function ASSET() external view returns (address);
    /// @notice The pair's quote leg (aeWETH or USDG).
    function quoteToken() external view returns (address);
    function poolFee() external view returns (uint24);
    function pool() external view returns (address);
    function keeperCheck() external returns (bool);
    function harvestBoolean(bool skipIncreaseLiquidity) external returns (uint256);
    function syncFees() external;
    function deposit(uint256 amount) external;
    function withdraw(uint256 userShares, address receiver, WithdrawToken outToken) external;
    function setWatched(bool status) external;
}

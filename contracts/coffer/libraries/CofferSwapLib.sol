// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/ICofferSwapRouter.sol";
import "../interfaces/IUniswapV3PoolMinimal.sol";
import "./TwapQuoteLib.sol";

/// @title CofferSwapLib
/// @notice The strategy's swap chokepoint and the exit payout built on it.
/// @dev Public and linked, so the code lives at one address instead of inside a strategy that has no runtime bytes to
///      spare. Every function runs by DELEGATECALL in the strategy's own context: token balances, approvals,
///      transfers and events are all the strategy's. Nothing here reads strategy storage; callers pass what is needed.
library CofferSwapLib {
    using SafeERC20 for IERC20;

    /// @notice Router rejected the swap. The caller continued and the unswapped token stayed put.
    event SwapFailed(address indexed tokenIn, uint256 amountIn);

    struct Route {
        ICofferSwapRouter router;
        IUniswapV3PoolMinimal pool;
        /// @dev The pool token the TWAP floor is expressed against.
        address base;
        uint24 fee;
        uint256 maxDevBps;
        uint256 slipBps;
        uint32 twapSeconds;
    }

    /// @notice Swap `amount` of `tokenIn` for `tokenOut` along `r` behind a TWAP-gated floor. A closed gate or a
    ///         router rejection is a skip, never a revert: withdrawals pay the unswapped leg in kind and
    ///         rebalances retry.
    /// @return sold The `tokenIn` actually spent (0 when skipped).
    function swapVia(Route memory r, IERC20 tokenIn, IERC20 tokenOut, uint256 amount) public returns (uint256 sold) {
        if (amount == 0 || amount > type(uint128).max) return 0;
        uint256 minOut = TwapQuoteLib.minOutAtBand(
            r.pool, r.base, address(tokenIn), amount, r.fee, r.maxDevBps, r.slipBps, r.twapSeconds
        );
        if (minOut == 0) return 0;
        uint256 before = tokenIn.balanceOf(address(this));
        tokenIn.forceApprove(address(r.router), amount);
        try r.router.swapExactInputSingleStrict(
            address(tokenIn), address(tokenOut), r.fee, uint128(amount), minOut, block.timestamp
        ) {
            sold = before - tokenIn.balanceOf(address(this));
        } catch {
            emit SwapFailed(address(tokenIn), amount);
        }
    }

    /// @notice Sell up to `amount` of `tokenIn` for `tokenOut` for a withdrawer, paying any unsold `tokenIn` to
    ///         `receiver` in kind. Shares burn whether or not the swap ran, so nothing owed may stay behind.
    /// @return got The `tokenOut` obtained.
    function sellForWithdraw(Route memory r, IERC20 tokenIn, IERC20 tokenOut, uint256 amount, address receiver)
        public
        returns (uint256 got)
    {
        uint256 have = tokenIn.balanceOf(address(this));
        uint256 toSwap = amount < have ? amount : have;
        if (toSwap == 0) return 0;
        uint256 beforeOut = tokenOut.balanceOf(address(this));
        uint256 sold = swapVia(r, tokenIn, tokenOut, toSwap);
        got = tokenOut.balanceOf(address(this)) - beforeOut;
        uint256 unsold = toSwap - sold;
        if (unsold > 0) {
            uint256 left = tokenIn.balanceOf(address(this));
            if (unsold > left) unsold = left;
            if (unsold > 0) tokenIn.safeTransfer(receiver, unsold);
        }
    }
}

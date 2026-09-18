// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./V3Deployments4663.sol";
import "./interfaces/ICofferSwapRouter.sol";
import "./interfaces/IUniswapRouter.sol";

/// @title CofferSwapRouter
/// @notice Robinhood Chain (4663) Uniswap v3 swap router for Coffer strategies. Owner-managed allowlist.
/// @dev Caller supplies `minAmountOut`; router does not quote.
contract CofferSwapRouter is ICofferSwapRouter, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapRouter public immutable router = IUniswapRouter(V3Deployments4663.SWAP_ROUTER02);
    mapping(address => bool) public isAuthorizedStrategy;

    error Unauthorized();
    error NotAuthorized();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroMinOut();
    error Expired();
    error AlreadyAuthorized();

    event StrategyAuthorized(address indexed strategy);
    event StrategyDeauthorized(address indexed strategy);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event SwapExecuted(
        address indexed strategy, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut
    );

    constructor() Ownable(msg.sender) {}

    function addAuthorizedStrategy(address strategy) external override onlyOwner {
        if (strategy == address(0)) revert ZeroAddress();
        if (isAuthorizedStrategy[strategy]) revert AlreadyAuthorized();
        isAuthorizedStrategy[strategy] = true;
        emit StrategyAuthorized(strategy);
    }

    function removeAuthorizedStrategy(address strategy) external override onlyOwner {
        if (!isAuthorizedStrategy[strategy]) revert NotAuthorized();
        delete isAuthorizedStrategy[strategy];
        emit StrategyDeauthorized(strategy);
    }

    /// @notice Recover tokens or ETH stranded outside a swap. The router holds no balance between transactions.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert ZeroAmount();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }

    function swapExactInputSingleStrict(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint128 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) external override nonReentrant returns (uint256 amountOut) {
        if (!isAuthorizedStrategy[msg.sender]) revert Unauthorized();
        if (amountIn == 0) revert ZeroAmount();
        // A zero floor would leave the swap wholly unprotected; callers that cannot price must not swap.
        if (minAmountOut == 0) revert ZeroMinOut();
        if (deadline != 0 && block.timestamp > deadline) revert Expired();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);
        amountOut = router.exactInputSingle(
            IUniswapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: msg.sender,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }
}

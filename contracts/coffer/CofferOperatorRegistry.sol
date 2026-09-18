// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ICofferOperatorRegistry.sol";

contract CofferOperatorRegistry is ICofferOperatorRegistry, Ownable {
    error ZeroAddress();

    mapping(address => bool) public operators;

    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);

    constructor(address initialOperator) Ownable(msg.sender) {
        if (initialOperator == address(0)) revert ZeroAddress();
        operators[initialOperator] = true;
        emit OperatorAdded(initialOperator);
    }

    function isOperator(address account) external view returns (bool) {
        return operators[account];
    }

    function addOperator(address operator) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        if (operators[operator]) return;
        operators[operator] = true;
        emit OperatorAdded(operator);
    }

    function removeOperator(address operator) external onlyOwner {
        if (!operators[operator]) return;
        operators[operator] = false;
        emit OperatorRemoved(operator);
    }
}

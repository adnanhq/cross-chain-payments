// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title ISimpleFundReceiver
 * @notice Interface for contracts that can receive cross-chain payments
 */
interface ISimpleFundReceiver {
    function processPayment(bytes32 intentId, address sender, address token, uint256 amount, bytes calldata data)
        external;
}


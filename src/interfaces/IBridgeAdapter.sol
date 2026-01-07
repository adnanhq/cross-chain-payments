// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IBridgeAdapter
 * @notice Interface that each bridge implementation must satisfy for cross-chain refunds
 */
interface IBridgeAdapter {
    /// @notice Send tokens back to the source chain as a refund
    /// @param destinationChainSelector The destination chain selector (source chain of original intent)
    /// @param recipient The recipient address on the destination chain
    /// @param token The token address on this chain
    /// @param amount The amount to send
    /// @return refundId The bridge message ID for tracking
    function sendRefund(uint64 destinationChainSelector, address recipient, address token, uint256 amount)
        external
        payable
        returns (bytes32 refundId);

    /// @notice Get the fee required to send a refund
    /// @param destinationChainSelector The destination chain selector
    /// @param token The token address
    /// @param amount The amount to send
    /// @return fee The fee in native currency
    function quoteRefundFee(uint64 destinationChainSelector, address token, uint256 amount)
        external
        view
        returns (uint256 fee);
}


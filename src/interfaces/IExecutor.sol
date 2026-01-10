// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IExecutor
 * @notice Interface for the Executor contract that handles cross-chain payment intents
 */
interface IExecutor {
    /// @notice The type of intent being executed
    enum IntentKind {
        Payment,
        Pledge
    }

    /// @notice The lifecycle status of an intent
    enum IntentStatus {
        Unseen,
        Executed,
        RefundRequested,
        Refunded
    }

    /// @notice Cross-chain payment intent structure
    /// @param intentId Unique identifier (also used as paymentId/pledgeId on destination)
    /// @param sourceChainSelector Origin chain selector
    /// @param sender Original sender on source chain
    /// @param token ERC20 token on destination chain delivered by the bridge
    /// @param amount Amount delivered (in token decimals)
    /// @param receiver The fund receiver contract on destination
    /// @param kind Payment or Pledge
    /// @param data ABI-encoded kind-specific params
    /// @param deadline Intent expiration timestamp
    struct CrossChainIntent {
        bytes32 intentId;
        uint64 sourceChainSelector;
        address sender;
        address destinationToken;
        uint256 amount;
        address receiver;
        IntentKind kind;
        bytes data;
        uint256 deadline;
    }

    /// @notice Refund request created by the treasury at refund time
    /// @param destinationToken Token to refund (destination chain token)
    /// @param amount Amount to refund
    /// @param recipient Recipient on source chain
    /// @param sourceChainSelector Source chain selector for routing
    struct RefundRequest {
        address destinationToken;
        uint256 amount;
        address recipient;
        uint64 sourceChainSelector;
    }

    /// @notice Called by bridge adapters after assets are delivered to Executor
    /// @param bridgeId Identifier like keccak256("CCIP") used for refund routing
    /// @param intent The cross-chain intent to execute
    function executeIntent(bytes32 bridgeId, CrossChainIntent calldata intent) external;

    /// @notice Called by the fund receiver to request a refund back to source chain
    /// @param intentId The intent ID to refund
    /// @param destinationToken Token to refund
    /// @param amount Amount to refund
    /// @param recipient Recipient on source chain
    function requestRefund(bytes32 intentId, address destinationToken, uint256 amount, address recipient) external;

    /// @notice Execute a pending refund by bridging tokens back to source chain
    /// @param intentId The intent ID to refund
    /// @return refundId The bridge message ID for tracking
    function executeRefund(bytes32 intentId) external payable returns (bytes32 refundId);

    /// @notice Get the status of an intent
    /// @param intentId The intent ID to query
    /// @return status The current status
    function getIntentStatus(bytes32 intentId) external view returns (IntentStatus status);

    /// @notice Get the refund request for an intent
    /// @param intentId The intent ID to query
    /// @return request The refund request details
    function getRefundRequest(bytes32 intentId) external view returns (RefundRequest memory request);

    // Events
    event IntentExecuted(
        bytes32 indexed intentId, address indexed sender, address token, uint256 amount, address receiver
    );
    event RefundRequested(bytes32 indexed intentId, address token, uint256 amount, address recipient);
    event RefundExecuted(bytes32 indexed intentId, bytes32 indexed refundMessageId);
    event AdapterAuthorized(address indexed adapter, bool authorized);
}

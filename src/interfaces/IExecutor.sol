// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/**
 * @title IExecutor
 * @notice Interface for the Executor contract that handles cross-chain payment intents
 */
interface IExecutor {
    /// @notice The lifecycle status of an intent
    enum IntentStatus {
        Unseen,
        Executed,
        RefundRequested,
        Refunded
    }

    /// @notice Cross-chain payment intent structure
    /// @param intentId Unique identifier (also used as paymentId on destination)
    /// @param sourceChainId Origin EVM chainId (set by bridge adapter from message provenance)
    /// @param sender Original sender on source chain
    /// @param destinationToken ERC20 token on destination chain delivered by the bridge
    /// @param amount Amount delivered (in token decimals)
    /// @param receiver The fund receiver contract on destination
    /// @param data ABI-encoded payment-specific params (optional / app-defined)
    /// @param deadline Intent expiration timestamp
    struct CrossChainIntent {
        bytes32 intentId;
        uint256 sourceChainId;
        address sender;
        address destinationToken;
        uint256 amount;
        address receiver;
        uint256 deadline;
        bytes data;
    }

    /// @notice Refund request created by the treasury at refund time
    /// @param destinationToken Token to refund (destination chain token)
    /// @param amount Amount to refund
    /// @param recipient Recipient on source chain
    /// @param sourceChainId Source chainId for routing
    struct RefundRequest {
        address destinationToken;
        uint256 amount;
        address recipient;
        uint256 sourceChainId;
    }

    /// @notice Called by bridge adapters after assets are delivered to Executor
    /// @param bridgeId Identifier like keccak256("CCIP")
    /// @param intent The cross-chain intent to execute (sourceChainId populated by adapter)
    function executeIntent(bytes32 bridgeId, CrossChainIntent calldata intent) external;

    /// @notice Called by the fund receiver to request a refund back to source chain
    /// @param intentId The intent ID to refund
    /// @param destinationToken Token to refund
    /// @param amount Amount to refund
    /// @param recipient Recipient on source chain
    function requestRefund(bytes32 intentId, address destinationToken, uint256 amount, address recipient) external;

    /// @notice Execute a pending refund by bridging tokens back to source chain.
    /// @param intentId The intent ID to refund
    /// @param refundBridgeId Bridge to use for the refund (can differ from inbound bridge)
    /// @return refundId The bridge message ID for tracking
    function executeRefund(bytes32 intentId, bytes32 refundBridgeId) external payable returns (bytes32 refundId);

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

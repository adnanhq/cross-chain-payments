// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IExecutor} from "./interfaces/IExecutor.sol";
import {IBridgeAdapter} from "./interfaces/IBridgeAdapter.sol";
import {ICrossChainRegistry} from "./interfaces/ICrossChainRegistry.sol";
import {ISimpleFundReceiver} from "./interfaces/ISimpleFundReceiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Executor
 * @notice Central executor that receives bridged assets and executes payments on fund receivers
 * @dev Simplified PoC version - no EIP-712 signature verification
 */
contract Executor is IExecutor, Ownable, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Bridge identifier for CCIP
    bytes32 public constant BRIDGE_ID_CCIP = keccak256("CCIP");

    /// @notice Registry for chain/adapter configuration
    ICrossChainRegistry public registry;

    /// @notice Intent record storing execution details
    struct IntentRecord {
        IntentStatus status;
        uint64 sourceChainSelector;
        bytes32 bridgeId;
        address destinationToken;
        uint256 escrowedAmount;
        address sender;
        address receiver;
    }

    /// @notice Intent records by intentId
    mapping(bytes32 => IntentRecord) public intents;

    /// @notice Refund requests by intentId
    mapping(bytes32 => RefundRequest) public refundRequests;

    /// @notice Authorized bridge adapters
    mapping(address => bool) public authorizedAdapters;

    // Errors
    error Executor__Unauthorized();
    error Executor__IntentAlreadyProcessed();
    error Executor__IntentExpired();
    error Executor__ChainNotSupported();
    error Executor__AdapterMismatch();
    error Executor__InvalidReceiver();
    error Executor__InvalidAmount();
    error Executor__RefundNotRequested();
    error Executor__InsufficientFee();
    error Executor__TransferFailed();

    modifier onlyBridgeAdapter() {
        _onlyBridgeAdapter();
        _;
    }

    function _onlyBridgeAdapter() internal view {
        if (!authorizedAdapters[msg.sender]) revert Executor__Unauthorized();
    }

    constructor(address _registry) Ownable(msg.sender) {
        registry = ICrossChainRegistry(_registry);
    }

    /// @inheritdoc IExecutor
    function executeIntent(bytes32 bridgeId, CrossChainIntent calldata intent)
        external
        onlyBridgeAdapter
        whenNotPaused
    {
        // Check intent hasn't been processed
        if (intents[intent.intentId].status != IntentStatus.Unseen) {
            revert Executor__IntentAlreadyProcessed();
        }

        // Check deadline
        if (block.timestamp > intent.deadline) {
            revert Executor__IntentExpired();
        }

        // Check chain is supported
        ICrossChainRegistry.ChainConfig memory config = registry.getChainConfig(intent.sourceChainSelector);
        if (!config.isSupported || config.isPaused) {
            revert Executor__ChainNotSupported();
        }

        // Verify adapter integrity
        (address expectedAdapter, bool enabled) = registry.getBridgeAdapter(intent.sourceChainSelector, bridgeId);
        if (!enabled || expectedAdapter != msg.sender) {
            revert Executor__AdapterMismatch();
        }

        // Validate receiver
        if (intent.receiver == address(0)) {
            revert Executor__InvalidReceiver();
        }

        // Validate amount
        if (intent.amount == 0) {
            revert Executor__InvalidAmount();
        }

        // Record the intent (acts as reentrancy guard for this intentId)
        intents[intent.intentId] = IntentRecord({
            status: IntentStatus.Executed,
            sourceChainSelector: intent.sourceChainSelector,
            bridgeId: bridgeId,
            destinationToken: intent.destinationToken,
            escrowedAmount: intent.amount,
            sender: intent.sender,
            receiver: intent.receiver
        });

        // Transfer tokens from executor to the receiver
        // The adapter has already transferred tokens to this contract
        IERC20(intent.destinationToken).safeTransfer(intent.receiver, intent.amount);

        // Call the receiver to process the payment
        ISimpleFundReceiver(intent.receiver).processPayment(
            intent.intentId, intent.sender, intent.destinationToken, intent.amount, intent.data
        );

        emit IntentExecuted(intent.intentId, intent.sender, intent.destinationToken, intent.amount, intent.receiver);
    }

    /// @inheritdoc IExecutor
    function requestRefund(bytes32 intentId, address destinationToken, uint256 amount, address recipient) external {
        IntentRecord storage record = intents[intentId];

        // Verify caller is the receiver that executed this intent
        if (msg.sender != record.receiver) {
            revert Executor__Unauthorized();
        }

        // Verify intent was executed
        if (record.status != IntentStatus.Executed) {
            revert Executor__InvalidAmount();
        }

        // Update status
        record.status = IntentStatus.RefundRequested;

        // Store refund request
        refundRequests[intentId] = RefundRequest({
            destinationToken: destinationToken,
            amount: amount,
            recipient: recipient,
            sourceChainSelector: record.sourceChainSelector
        });

        emit RefundRequested(intentId, destinationToken, amount, recipient);
    }

    /// @inheritdoc IExecutor
    function executeRefund(bytes32 intentId) external payable whenNotPaused returns (bytes32 refundId) {
        IntentRecord memory record = intents[intentId];
        RefundRequest memory request = refundRequests[intentId];

        // Verify refund was requested
        if (record.status != IntentStatus.RefundRequested) {
            revert Executor__RefundNotRequested();
        }

        // Get the adapter for this bridge
        (address adapter, bool enabled) = registry.getBridgeAdapter(record.sourceChainSelector, record.bridgeId);
        if (!enabled) {
            revert Executor__AdapterMismatch();
        }

        // Check fee
        uint256 requiredFee = IBridgeAdapter(adapter).quoteRefundFee(
            request.sourceChainSelector, request.destinationToken, request.amount
        );
        if (msg.value < requiredFee) {
            revert Executor__InsufficientFee();
        }

        // Update status
        intents[intentId].status = IntentStatus.Refunded;

        // Approve adapter to spend tokens
        IERC20(request.destinationToken).forceApprove(adapter, request.amount);

        // Send refund via bridge
        refundId = IBridgeAdapter(adapter).sendRefund{value: msg.value}(
            request.sourceChainSelector, request.recipient, request.destinationToken, request.amount
        );

        // Reset approval
        IERC20(request.destinationToken).forceApprove(adapter, 0);

        emit RefundExecuted(intentId, refundId);
    }

    /// @inheritdoc IExecutor
    function getIntentStatus(bytes32 intentId) external view returns (IntentStatus) {
        return intents[intentId].status;
    }

    /// @inheritdoc IExecutor
    function getRefundRequest(bytes32 intentId) external view returns (RefundRequest memory) {
        return refundRequests[intentId];
    }

    // Admin functions (simplified for PoC - no access control)

    /// @notice Authorize or deauthorize a bridge adapter
    function setAdapterAuthorization(address adapter, bool authorized) external onlyOwner {
        authorizedAdapters[adapter] = authorized;
        emit AdapterAuthorized(adapter, authorized);
    }

    /// @notice Pause the executor
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause the executor
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Update the registry
    function setRegistry(address _registry) external onlyOwner {
        registry = ICrossChainRegistry(_registry);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IExecutor} from "./interfaces/IExecutor.sol";
import {IBridgeAdapter} from "./interfaces/IBridgeAdapter.sol";
import {ICrossChainRegistry} from "./interfaces/ICrossChainRegistry.sol";
import {ISimpleFundReceiver} from "./interfaces/ISimpleFundReceiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Executor
 * @notice Central executor that receives bridged assets and executes payments on fund receivers
 * @dev Simplified PoC version - no EIP-712 signature verification
 */
contract Executor is IExecutor, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Bridge identifier for CCIP
    bytes32 public constant BRIDGE_ID_CCIP = keccak256("CCIP");

    /// @notice Global pause flag
    bool public isPaused;

    /// @notice Registry for chain/adapter configuration
    ICrossChainRegistry public registry;

    /// @notice Intent record storing execution details
    struct IntentRecord {
        IntentStatus status;
        uint64 sourceChainSelector;
        bytes32 bridgeId;
        address token;
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
    error Unauthorized();
    error ExecutorPaused();
    error IntentAlreadyProcessed();
    error IntentExpired();
    error ChainNotSupported();
    error AdapterMismatch();
    error InvalidReceiver();
    error InvalidAmount();
    error RefundNotRequested();
    error InsufficientFee();
    error TransferFailed();

    modifier onlyBridgeAdapter() {
        _onlyBridgeAdapter();
        _;
    }

    modifier whenNotPaused() {
        _whenNotPaused();
        _;
    }

    function _onlyBridgeAdapter() internal view {
        if (!authorizedAdapters[msg.sender]) revert Unauthorized();
    }

    function _whenNotPaused() internal view {
        if (isPaused) revert ExecutorPaused();
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
            revert IntentAlreadyProcessed();
        }

        // Check deadline
        if (block.timestamp > intent.deadline) {
            revert IntentExpired();
        }

        // Check chain is supported
        ICrossChainRegistry.ChainConfig memory config = registry.getChainConfig(intent.sourceChainSelector);
        if (!config.isSupported || config.isPaused) {
            revert ChainNotSupported();
        }

        // Verify adapter integrity
        (address expectedAdapter, bool enabled) = registry.getBridgeAdapter(intent.sourceChainSelector, bridgeId);
        if (!enabled || expectedAdapter != msg.sender) {
            revert AdapterMismatch();
        }

        // Validate receiver
        if (intent.receiver == address(0)) {
            revert InvalidReceiver();
        }

        // Validate amount
        if (intent.amount == 0) {
            revert InvalidAmount();
        }

        // Record the intent (acts as reentrancy guard for this intentId)
        intents[intent.intentId] = IntentRecord({
            status: IntentStatus.Executed,
            sourceChainSelector: intent.sourceChainSelector,
            bridgeId: bridgeId,
            token: intent.token,
            escrowedAmount: intent.amount,
            sender: intent.sender,
            receiver: intent.receiver
        });

        // Transfer tokens from executor to the receiver
        // The adapter has already transferred tokens to this contract
        IERC20(intent.token).safeTransfer(intent.receiver, intent.amount);

        // Call the receiver to process the payment
        ISimpleFundReceiver(intent.receiver)
            .processPayment(intent.intentId, intent.sender, intent.token, intent.amount, intent.data);

        emit IntentExecuted(intent.intentId, intent.sender, intent.token, intent.amount, intent.receiver);
    }

    /// @inheritdoc IExecutor
    function requestRefund(bytes32 intentId, address token, uint256 amount, address recipient) external {
        IntentRecord storage record = intents[intentId];

        // Verify caller is the receiver that executed this intent
        if (msg.sender != record.receiver) {
            revert Unauthorized();
        }

        // Verify intent was executed
        if (record.status != IntentStatus.Executed) {
            revert InvalidAmount();
        }

        // Update status
        record.status = IntentStatus.RefundRequested;

        // Store refund request
        refundRequests[intentId] = RefundRequest({
            token: token, amount: amount, recipient: recipient, sourceChainSelector: record.sourceChainSelector
        });

        emit RefundRequested(intentId, token, amount, recipient);
    }

    /// @inheritdoc IExecutor
    function executeRefund(bytes32 intentId) external payable whenNotPaused returns (bytes32 refundId) {
        IntentRecord memory record = intents[intentId];
        RefundRequest memory request = refundRequests[intentId];

        // Verify refund was requested
        if (record.status != IntentStatus.RefundRequested) {
            revert RefundNotRequested();
        }

        // Get the adapter for this bridge
        (address adapter, bool enabled) = registry.getBridgeAdapter(record.sourceChainSelector, record.bridgeId);
        if (!enabled) {
            revert AdapterMismatch();
        }

        // Check fee
        uint256 requiredFee =
            IBridgeAdapter(adapter).quoteRefundFee(request.sourceChainSelector, request.token, request.amount);
        if (msg.value < requiredFee) {
            revert InsufficientFee();
        }

        // Update status
        intents[intentId].status = IntentStatus.Refunded;

        // Approve adapter to spend tokens
        IERC20(request.token).forceApprove(adapter, request.amount);

        // Send refund via bridge
        refundId = IBridgeAdapter(adapter).sendRefund{value: msg.value}(
            request.sourceChainSelector, request.recipient, request.token, request.amount
        );

        // Reset approval
        IERC20(request.token).forceApprove(adapter, 0);

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
        isPaused = true;
    }

    /// @notice Unpause the executor
    function unpause() external onlyOwner {
        isPaused = false;
    }

    /// @notice Update the registry
    function setRegistry(address _registry) external onlyOwner {
        registry = ICrossChainRegistry(_registry);
    }
}

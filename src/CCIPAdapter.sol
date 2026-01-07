// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IBridgeAdapter} from "./interfaces/IBridgeAdapter.sol";
import {IExecutor} from "./interfaces/IExecutor.sol";
import {Ownable} from "./utils/Ownable.sol";
import {
    IERC20
} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CCIPAdapter
 * @notice Chainlink CCIP adapter for receiving cross-chain messages and sending refunds
 * @dev Implements CCIPReceiver for incoming messages and IBridgeAdapter for outgoing refunds
 */
contract CCIPAdapter is CCIPReceiver, IBridgeAdapter, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Bridge identifier
    bytes32 public constant BRIDGE_ID = keccak256("CCIP");

    /// @notice The Executor contract
    IExecutor public executor;

    /// @notice Allowed source chain senders: chainSelector => sender => allowed
    mapping(uint64 => mapping(address => bool)) public allowedSenders;

    // Errors
    error Unauthorized();
    error InvalidSender();
    error NoTokensReceived();
    error UnexpectedTokenCount();
    error TokenMismatch();
    error AmountMismatch();
    error SourceChainMismatch();
    error InvalidReceiver();

    // Events
    event SenderAllowed(uint64 indexed chainSelector, address indexed sender, bool allowed);
    event RefundSent(bytes32 indexed messageId, uint64 destinationChainSelector, address recipient, uint256 amount);

    constructor(address _router, address _executor) CCIPReceiver(_router) {
        executor = IExecutor(_executor);
    }

    /**
     * @notice Handle incoming CCIP messages
     * @dev Validates the message, transfers tokens to executor, and calls executeIntent
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        // Decode sender from source chain
        address sourceSender = abi.decode(message.sender, (address));

        // Validate sender is allowed
        if (!allowedSenders[message.sourceChainSelector][sourceSender]) {
            revert InvalidSender();
        }

        // Ensure we received exactly one token (PoC only supports single-token intents)
        if (message.destTokenAmounts.length == 0) revert NoTokensReceived();
        if (message.destTokenAmounts.length != 1) revert UnexpectedTokenCount();

        // Get the token and amount received
        address receivedToken = message.destTokenAmounts[0].token;
        uint256 receivedAmount = message.destTokenAmounts[0].amount;

        // Decode the intent from message data
        IExecutor.CrossChainIntent memory intent = abi.decode(message.data, (IExecutor.CrossChainIntent));

        // Bind intent source chain selector to the CCIP message provenance
        if (intent.sourceChainSelector != message.sourceChainSelector) {
            revert SourceChainMismatch();
        }

        // Receiver must be set
        if (intent.receiver == address(0)) revert InvalidReceiver();

        // Verify token matches
        if (intent.token != receivedToken) {
            revert TokenMismatch();
        }

        // Verify amount matches what was actually delivered
        if (intent.amount != receivedAmount) {
            revert AmountMismatch();
        }

        // Transfer tokens to executor
        IERC20(receivedToken).safeTransfer(address(executor), receivedAmount);

        // Call executor to process the intent
        executor.executeIntent(BRIDGE_ID, intent);
    }

    /**
     * @inheritdoc IBridgeAdapter
     * @notice Send tokens back to source chain as a refund
     */
    function sendRefund(uint64 destinationChainSelector, address recipient, address token, uint256 amount)
        external
        payable
        returns (bytes32 messageId)
    {
        // Only executor can send refunds
        if (msg.sender != address(executor)) revert Unauthorized();

        // Transfer tokens from executor to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Build the CCIP message
        Client.EVM2AnyMessage memory ccipMessage =
            _buildRefundMessage(destinationChainSelector, recipient, token, amount);

        // Get the router
        IRouterClient router = IRouterClient(getRouter());

        // Approve router to spend tokens
        IERC20(token).safeApprove(address(router), amount);

        // Send the message
        messageId = router.ccipSend{value: msg.value}(destinationChainSelector, ccipMessage);

        emit RefundSent(messageId, destinationChainSelector, recipient, amount);
    }

    /**
     * @inheritdoc IBridgeAdapter
     * @notice Get the fee for sending a refund
     */
    function quoteRefundFee(uint64 destinationChainSelector, address token, uint256 amount)
        external
        view
        returns (uint256 fee)
    {
        Client.EVM2AnyMessage memory ccipMessage =
            _buildRefundMessage(destinationChainSelector, address(0), token, amount);
        return IRouterClient(getRouter()).getFee(destinationChainSelector, ccipMessage);
    }

    /**
     * @notice Build a CCIP message for refund
     */
    function _buildRefundMessage(uint64, address recipient, address token, uint256 amount)
        internal
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        // Create token amounts array
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: token, amount: amount});

        // Build message - just sending tokens, no data needed for refund
        return Client.EVM2AnyMessage({
            receiver: abi.encode(recipient),
            data: "",
            tokenAmounts: tokenAmounts,
            feeToken: address(0), // Pay in native
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 200_000}))
        });
    }

    // Admin functions (simplified for PoC - no access control)

    /**
     * @notice Allow or disallow a sender from a source chain
     */
    function setAllowedSender(uint64 chainSelector, address sender, bool allowed) external onlyOwner {
        allowedSenders[chainSelector][sender] = allowed;
        emit SenderAllowed(chainSelector, sender, allowed);
    }

    /**
     * @notice Update the executor address
     */
    function setExecutor(address _executor) external onlyOwner {
        executor = IExecutor(_executor);
    }

    receive() external payable {}
}

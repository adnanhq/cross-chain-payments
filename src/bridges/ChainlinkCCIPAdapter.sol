// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IExecutor} from "../interfaces/IExecutor.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ChainlinkCCIPAdapter
 * @notice Chainlink CCIP adapter for receiving cross-chain messages and sending refunds
 * @dev Implements CCIPReceiver for incoming messages and IBridgeAdapter for outgoing refunds
 */
contract ChainlinkCCIPAdapter is CCIPReceiver, IBridgeAdapter, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Bridge identifier
    bytes32 public constant BRIDGE_ID = keccak256("CCIP");

    /// @notice The Executor contract
    IExecutor public executor;

    /// @notice Allowed source chain senders: chainSelector => sender => allowed
    mapping(uint64 => mapping(address => bool)) public allowedSenders;

    /// @notice EVM chainId -> CCIP chain selector (for refunds)
    mapping(uint256 => uint64) public selectorByChainId;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error ChainlinkCCIPAdapter__Unauthorized();
    error ChainlinkCCIPAdapter__InvalidSender();
    error ChainlinkCCIPAdapter__UnexpectedTokenCount();
    error ChainlinkCCIPAdapter__TokenMismatch();
    error ChainlinkCCIPAdapter__AmountMismatch();
    error ChainlinkCCIPAdapter__UnknownDestinationChainId();
    error ChainlinkCCIPAdapter__SourceChainIdMismatch(uint256 payloadChainId, uint64 provenanceSelector, uint64 expectedSelector);

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event SenderAllowed(uint64 indexed chainSelector, address indexed sender, bool allowed);
    event RefundSent(bytes32 indexed messageId, uint256 destinationChainId, address recipient, uint256 amount);

    constructor(address _router, address _executor) CCIPReceiver(_router) Ownable(msg.sender) {
        executor = IExecutor(_executor);
    }

    /*//////////////////////////////////////////////////////////////
                              CCIP RECEIVE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Handle incoming CCIP messages
     * @dev Validates the message, transfers tokens to executor, and calls executeIntent
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        // Decode sender from source chain
        address sourceSender = abi.decode(message.sender, (address));

        // Validate sender is allowed
        if (!allowedSenders[message.sourceChainSelector][sourceSender]) revert ChainlinkCCIPAdapter__InvalidSender();

        // Ensure we received exactly one token (PoC only supports single-token intents)
        if (message.destTokenAmounts.length != 1) revert ChainlinkCCIPAdapter__UnexpectedTokenCount();

        // Get the token and amount received
        address receivedToken = message.destTokenAmounts[0].token;
        uint256 receivedAmount = message.destTokenAmounts[0].amount;

        // Decode the intent from message data
        IExecutor.CrossChainIntent memory intent = abi.decode(message.data, (IExecutor.CrossChainIntent));

        // Validate the claimed sourceChainId against CCIP provenance selector using the chainId->selector mapping.
        // This avoids maintaining a separate selector->chainId mapping and ensures refunds will route correctly.
        uint64 expectedSelector = selectorByChainId[intent.sourceChainId];
        if (expectedSelector != message.sourceChainSelector) {
            revert ChainlinkCCIPAdapter__SourceChainIdMismatch(intent.sourceChainId, message.sourceChainSelector, expectedSelector);
        }

        // Verify token matches
        if (intent.destinationToken != receivedToken) revert ChainlinkCCIPAdapter__TokenMismatch();

        // Verify amount matches what was actually delivered
        if (intent.amount != receivedAmount) revert ChainlinkCCIPAdapter__AmountMismatch();

        // Transfer tokens to executor
        IERC20(receivedToken).safeTransfer(address(executor), receivedAmount);

        // Call executor to process the intent
        executor.executeIntent(BRIDGE_ID, intent);
    }

    /*//////////////////////////////////////////////////////////////
                        REFUNDS (IBridgeAdapter)
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc IBridgeAdapter
     * @notice Send tokens back to source chain as a refund
     */
    function sendRefund(uint256 destinationChainId, address recipient, address token, uint256 amount)
        external
        payable
        returns (bytes32 messageId)
    {
        // Only executor can send refunds
        if (msg.sender != address(executor)) revert ChainlinkCCIPAdapter__Unauthorized();

        uint64 destinationChainSelector = selectorByChainId[destinationChainId];
        if (destinationChainSelector == 0) revert ChainlinkCCIPAdapter__UnknownDestinationChainId();

        // Transfer tokens from executor to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Build the CCIP message
        Client.EVM2AnyMessage memory ccipMessage = _buildRefundMessage(destinationChainSelector, recipient, token, amount);

        // Get the router
        IRouterClient router = IRouterClient(getRouter());

        // Approve router to spend tokens
        IERC20(token).forceApprove(address(router), amount);

        // Send the message
        messageId = router.ccipSend{value: msg.value}(destinationChainSelector, ccipMessage);

        emit RefundSent(messageId, destinationChainId, recipient, amount);
    }

    /**
     * @inheritdoc IBridgeAdapter
     * @notice Get the fee for sending a refund
     */
    function quoteRefundFee(uint256 destinationChainId, address token, uint256 amount)
        external
        view
        returns (uint256 fee)
    {
        uint64 destinationChainSelector = selectorByChainId[destinationChainId];
        if (destinationChainSelector == 0) revert ChainlinkCCIPAdapter__UnknownDestinationChainId();

        Client.EVM2AnyMessage memory ccipMessage =
            _buildRefundMessage(destinationChainSelector, address(0), token, amount);
        return IRouterClient(getRouter()).getFee(destinationChainSelector, ccipMessage);
    }

    /*//////////////////////////////////////////////////////////////
                               ADMIN CONFIG
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Build a CCIP message for refund
     */
    function _buildRefundMessage(uint64, address recipient, address token, uint256 amount)
        private
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
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV2({gasLimit: 200_000, allowOutOfOrderExecution: true}))
        });
    }

    /**
     * @notice Allow or disallow a sender from a source chain
     */
    function setAllowedSender(uint64 chainSelector, address sender, bool allowed) external onlyOwner {
        allowedSenders[chainSelector][sender] = allowed;
        emit SenderAllowed(chainSelector, sender, allowed);
    }

    /**
     * @notice Map an EVM chainId to a CCIP chain selector (used for refunds).
     */
    function setSelectorForChainId(uint256 chainId, uint64 ccipChainSelector) external onlyOwner {
        if (ccipChainSelector == 0) revert ChainlinkCCIPAdapter__UnknownDestinationChainId();
        selectorByChainId[chainId] = ccipChainSelector;
    }

    /**
     * @notice Update the executor address
     */
    function setExecutor(address _executor) external onlyOwner {
        executor = IExecutor(_executor);
    }

    receive() external payable {}
}



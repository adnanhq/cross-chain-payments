// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {IExecutor} from "./interfaces/IExecutor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title CCIPSender
 * @notice Contract deployed on source chains to send cross-chain payment intents
 * @dev Encodes CrossChainIntent, approves tokens, and sends via CCIP
 */
contract CCIPSender {
    using SafeERC20 for IERC20;

    /// @notice The CCIP router on this chain
    IRouterClient public immutable ROUTER;

    // Errors
    error CCIPSender__InvalidAmount();
    error CCIPSender__InvalidReceiver();
    error CCIPSender__InsufficientFee();
    error CCIPSender__UnsupportedChain();
    error CCIPSender__FeeRefundFailed();

    // Events
    event IntentSent(
        bytes32 indexed messageId,
        bytes32 indexed intentId,
        uint64 destinationChainSelector,
        address sender,
        address sourceToken,
        address destinationToken,
        uint256 amount
    );

    constructor(address router_) {
        ROUTER = IRouterClient(router_);
    }

    /**
     * @notice Send a cross-chain payment intent
     * @param destinationChainSelector The destination chain selector
     * @param destinationAdapter The CCIPAdapter address on the destination chain
     * @param sourceToken The token address on the source chain to bridge via CCIP
     * @param intent The cross-chain intent to send
     * @return messageId The CCIP message ID
     */
    function sendIntent(
        uint64 destinationChainSelector,
        address destinationAdapter,
        address sourceToken,
        IExecutor.CrossChainIntent memory intent
    ) external payable returns (bytes32 messageId) {
        // Validate amount
        if (intent.amount == 0) revert CCIPSender__InvalidAmount();

        // Validate receiver
        if (intent.receiver == address(0)) revert CCIPSender__InvalidReceiver();

        // Check chain is supported
        if (!ROUTER.isChainSupported(destinationChainSelector)) {
            revert CCIPSender__UnsupportedChain();
        }

        // Sanitize intent: bind sender to caller (sourceChainSelector populated by destination adapter)
        intent.sender = msg.sender;

        // Build the CCIP message
        Client.EVM2AnyMessage memory ccipMessage = _buildMessage(destinationAdapter, sourceToken, intent);

        // Get fee and validate payment
        uint256 fee = ROUTER.getFee(destinationChainSelector, ccipMessage);
        if (msg.value < fee) revert CCIPSender__InsufficientFee();

        // Transfer tokens from sender to this contract
        IERC20(sourceToken).safeTransferFrom(msg.sender, address(this), intent.amount);

        // Approve ROUTER to spend tokens
        IERC20(sourceToken).forceApprove(address(ROUTER), intent.amount);

        // Send the message
        messageId = ROUTER.ccipSend{value: fee}(destinationChainSelector, ccipMessage);

        // Refund excess fee
        if (msg.value > fee) {
            (bool success,) = msg.sender.call{value: msg.value - fee}("");
            if (!success) revert CCIPSender__FeeRefundFailed();
        }

        emit IntentSent(
            messageId,
            intent.intentId,
            destinationChainSelector,
            msg.sender,
            sourceToken,
            intent.destinationToken,
            intent.amount
        );
    }

    /**
     * @notice Get the fee for sending an intent
     * @param destinationChainSelector The destination chain selector
     * @param destinationAdapter The CCIPAdapter address on the destination chain
     * @param sourceToken The token address on the source chain to bridge via CCIP
     * @param intent The cross-chain intent
     * @return fee The fee in native currency
     */
    function quoteFee(
        uint64 destinationChainSelector,
        address destinationAdapter,
        address sourceToken,
        IExecutor.CrossChainIntent memory intent
    ) external view returns (uint256 fee) {
        // Sanitize intent for accurate fee quote
        intent.sender = msg.sender;

        Client.EVM2AnyMessage memory ccipMessage = _buildMessage(destinationAdapter, sourceToken, intent);
        fee = ROUTER.getFee(destinationChainSelector, ccipMessage);
    }

    /**
     * @notice Build a CCIP message for an intent
     */
    function _buildMessage(address destinationAdapter, address sourceToken, IExecutor.CrossChainIntent memory intent)
        private
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        // Create token amounts array
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: sourceToken, amount: intent.amount});

        // Build message with out-of-order execution enabled (payments are independent)
        return Client.EVM2AnyMessage({
            receiver: abi.encode(destinationAdapter),
            data: abi.encode(intent),
            tokenAmounts: tokenAmounts,
            feeToken: address(0), // Pay in native
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV2({gasLimit: 500_000, allowOutOfOrderExecution: true}))
        });
    }

    receive() external payable {}
}

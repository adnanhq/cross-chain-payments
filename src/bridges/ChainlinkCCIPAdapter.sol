// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ICrossChainExecutor} from "../interfaces/ICrossChainExecutor.sol";
import {IChainlinkCCIPAdapter} from "../interfaces/IChainlinkCCIPAdapter.sol";

/**
 * @title ChainlinkCCIPAdapter
 * @author 0x4dnanH (https://github.com/adnanhq)
 * @notice Destination-chain adapter for receiving cross-chain intents via Chainlink CCIP.
 * @dev This adapter serves as the CCIP receiver on the destination chain and handles:
 *      - Receiving and validating incoming CCIP messages containing payment intents
 *      - Forwarding validated intents to the CrossChainExecutor
 *      - Sending refunds back to source chains via CCIP
 *
 *      The adapter implements soft-failure validation: invalid intents are marked as Failed
 *      rather than reverting, allowing funds to be held for refund processing.
 *
 *      PoC simplification: Stores executor address directly (no GlobalParams).
 */
contract ChainlinkCCIPAdapter is CCIPReceiver, IChainlinkCCIPAdapter, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Bridge identifier: keccak256("CCIP")
    bytes32 public constant BRIDGE_ID = 0x5fa42365004d29017b6e1fff462c90ecf163a6f09987e7af7e4b8c324fc7cc5f;

    /// @notice Cross-chain executor contract address.
    address public executor;

    /**
     * @notice Deploys a new ChainlinkCCIPAdapter.
     * @param router Chainlink CCIP router address on this chain.
     * @param _executor Cross-chain executor contract address.
     */
    constructor(address router, address _executor) CCIPReceiver(router) Ownable(msg.sender) {
        executor = _executor;
    }

    /// @inheritdoc IChainlinkCCIPAdapter
    function sendRefund(
        uint256 destinationChainId,
        address recipient,
        address token,
        uint256 amount,
        address feeRefundRecipient
    ) external payable override returns (bytes32 messageId) {
        if (msg.sender != executor) {
            revert ChainlinkCCIPAdapterUnauthorized();
        }

        uint64 destinationSelector = ICrossChainExecutor(executor).getCcipChainSelector(destinationChainId);
        if (destinationSelector == 0) {
            revert ChainlinkCCIPAdapterUnknownChainSelector();
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        Client.EVM2AnyMessage memory ccipMessage = _buildRefundMessage(destinationSelector, recipient, token, amount);
        IRouterClient router = IRouterClient(getRouter());

        uint256 requiredFee = router.getFee(destinationSelector, ccipMessage);
        if (msg.value < requiredFee) {
            revert ChainlinkCCIPAdapterInsufficientFee(requiredFee, msg.value);
        }

        IERC20(token).forceApprove(address(router), amount);
        messageId = router.ccipSend{value: requiredFee}(destinationSelector, ccipMessage);
        IERC20(token).forceApprove(address(router), 0);

        if (msg.value > requiredFee) {
            (bool ok,) = feeRefundRecipient.call{value: msg.value - requiredFee}("");
            if (!ok) {
                revert ChainlinkCCIPAdapterFeeRefundFailed();
            }
        }

        emit RefundSentCCIP(messageId, destinationChainId, recipient, amount);
    }

    /// @inheritdoc IChainlinkCCIPAdapter
    function quoteRefundFee(uint256 destinationChainId, address recipient, address token, uint256 amount)
        external
        view
        override
        returns (uint256 fee)
    {
        uint64 destinationSelector = ICrossChainExecutor(executor).getCcipChainSelector(destinationChainId);

        Client.EVM2AnyMessage memory ccipMessage = _buildRefundMessage(destinationSelector, recipient, token, amount);
        return IRouterClient(getRouter()).getFee(destinationSelector, ccipMessage);
    }

    /**
     * @notice Updates the executor address.
     * @param _executor New executor address.
     */
    function setExecutor(address _executor) external onlyOwner {
        executor = _executor;
    }

    // =============================================================
    //                       INTERNAL FUNCTIONS
    // =============================================================

    /**
     * @dev CCIP receive callback. Validates the incoming message and forwards to the executor.
     *      Implements soft-failure: validation errors mark the intent as Failed rather than reverting.
     */
    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        (ICrossChainExecutor.Intent memory intent, bytes memory payload) =
            abi.decode(message.data, (ICrossChainExecutor.Intent, bytes));

        ICrossChainExecutor exec = ICrossChainExecutor(executor);
        address sourceSender = abi.decode(message.sender, (address));

        address expectedSender = exec.getIntentSender(intent.sourceChainId);
        if (expectedSender != sourceSender) {
            revert ChainlinkCCIPAdapterInvalidIntentSender();
        }

        bytes4 errorSelector;

        address receivedToken = message.destTokenAmounts[0].token;
        uint256 receivedAmount = message.destTokenAmounts[0].amount;

        if (intent.status != ICrossChainExecutor.Status.Ongoing) {
            errorSelector = ChainlinkCCIPAdapterInvalidIntentStatus.selector;
        } else if (exec.getCcipChainSelector(intent.sourceChainId) != message.sourceChainSelector) {
            errorSelector = ChainlinkCCIPAdapterChainSelectorMismatch.selector;
        } else if (intent.amount != receivedAmount) {
            errorSelector = ChainlinkCCIPAdapterAmountMismatch.selector;
            intent.amount = receivedAmount;
        }

        intent.token = receivedToken;

        if (errorSelector != bytes4(0)) {
            intent.status = ICrossChainExecutor.Status.Failed;
            emit ICrossChainExecutor.IntentFailed(intent.intentId, errorSelector);
        }

        IERC20(receivedToken).safeTransfer(address(exec), receivedAmount);
        exec.executeIntent(BRIDGE_ID, intent, payload);
    }

    /**
     * @dev Constructs a CCIP message for a token-only refund (no data payload).
     */
    function _buildRefundMessage(uint64, address recipient, address token, uint256 amount)
        private
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: token, amount: amount});

        return Client.EVM2AnyMessage({
            receiver: abi.encode(recipient),
            data: "",
            tokenAmounts: tokenAmounts,
            feeToken: address(0),
            extraArgs: Client._argsToBytes(Client.GenericExtraArgsV2({gasLimit: 200_000, allowOutOfOrderExecution: true}))
        });
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {IStargate} from "@stargate-v2/interfaces/IStargate.sol";
import {
    SendParam,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

import {ICrossChainExecutor} from "../interfaces/ICrossChainExecutor.sol";
import {ILayerZeroStargateAdapter} from "../interfaces/ILayerZeroStargateAdapter.sol";

/**
 * @title LayerZeroStargateAdapter
 * @author 0x4dnanH (https://github.com/adnanhq)
 * @notice Destination-chain adapter for receiving cross-chain intents via LayerZero Stargate.
 * @dev This adapter implements ILayerZeroComposer to receive OFT transfers with compose messages
 *      from Stargate v2. It handles:
 *      - Receiving and validating incoming compose messages containing payment intents
 *      - Forwarding validated intents to the CrossChainExecutor
 *      - Sending refunds back to source chains via Stargate
 *
 *      The adapter implements soft-failure validation: invalid intents are marked as Failed
 *      rather than reverting, allowing funds to be held for refund processing.
 *
 *      PoC simplification: Stores executor address directly (no GlobalParams).
 *      rescueTokens uses onlyOwner instead of protocol admin.
 */
contract LayerZeroStargateAdapter is ILayerZeroComposer, ILayerZeroStargateAdapter, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Bridge identifier: keccak256("LAYERZERO")
    bytes32 public constant BRIDGE_ID = 0xe34d309d2a3947d08baad60196a07f69352ed61cce4b781f48c19141173b2894;

    /// @notice LayerZero endpoint contract on this chain.
    ILayerZeroEndpointV2 public immutable ENDPOINT;

    /// @notice Cross-chain executor contract address.
    address public executor;

    /// @notice Trusted Stargate sender for each supported destination token.
    mapping(address token => address stargate) public stargateByToken;

    /// @dev Destination token configured for each trusted Stargate sender.
    mapping(address stargate => address token) private _tokenByStargate;

    event StargateSet(address indexed token, address indexed stargate);

    /**
     * @notice Deploys a new LayerZeroStargateAdapter.
     * @param endpoint LayerZero endpoint address on this chain.
     * @param _executor Cross-chain executor contract address.
     */
    constructor(address endpoint, address _executor) Ownable(msg.sender) {
        ENDPOINT = ILayerZeroEndpointV2(endpoint);
        executor = _executor;
    }

    /**
     * @notice Configures the trusted Stargate sender for a destination token.
     * @param token Destination token delivered by Stargate.
     * @param stargate Trusted Stargate contract for that token.
     */
    function setStargateForToken(address token, address stargate) external onlyOwner {
        if (token == address(0) || stargate == address(0)) {
            revert LayerZeroStargateAdapterTokenNotConfigured();
        }

        address previousStargate = stargateByToken[token];
        if (previousStargate != address(0)) {
            delete _tokenByStargate[previousStargate];
        }

        address previousToken = _tokenByStargate[stargate];
        if (previousToken != address(0) && previousToken != token) {
            delete stargateByToken[previousToken];
        }

        stargateByToken[token] = stargate;
        _tokenByStargate[stargate] = token;

        emit StargateSet(token, stargate);
    }

    /**
     * @notice LayerZero compose callback for receiving Stargate OFT transfers.
     * @dev Called by the LayerZero endpoint after a Stargate transfer with a compose message.
     *      Validates the message provenance and forwards the intent to the executor.
     * @param from The Stargate pool contract that initiated the compose.
     * @param guid LayerZero GUID of the message.
     * @param message The compose message containing the encoded intent and payload.
     */
    function lzCompose(address from, bytes32 guid, bytes calldata message, address, bytes calldata)
        external
        payable
        override
    {
        if (msg.sender != address(ENDPOINT)) {
            revert LayerZeroStargateAdapterUnauthorized();
        }

        uint32 srcEid = OFTComposeMsgCodec.srcEid(message);
        bytes32 composeFrom = OFTComposeMsgCodec.composeFrom(message);
        uint256 amountLD = OFTComposeMsgCodec.amountLD(message);

        bytes memory inner = OFTComposeMsgCodec.composeMsg(message);
        (ICrossChainExecutor.Intent memory intent, bytes memory payload) =
            abi.decode(inner, (ICrossChainExecutor.Intent, bytes));

        ICrossChainExecutor exec = ICrossChainExecutor(executor);
        address expectedSender = exec.getIntentSender(intent.sourceChainId);
        bytes32 expectedPeer = bytes32(uint256(uint160(expectedSender)));

        if (expectedPeer != composeFrom) {
            revert LayerZeroStargateAdapterInvalidPeer();
        }

        bytes4 errorSelector;

        if (intent.status != ICrossChainExecutor.Status.Ongoing) {
            errorSelector = LayerZeroStargateAdapterInvalidIntentStatus.selector;
        } else if (exec.getLayerZeroEid(intent.sourceChainId) != srcEid) {
            errorSelector = LayerZeroStargateAdapterEidMismatch.selector;
        }

        address receivedToken = _tokenByStargate[from];
        if (receivedToken == address(0)) {
            revert LayerZeroStargateAdapterTokenNotConfigured();
        }

        intent.token = receivedToken;
        intent.amount = amountLD;

        if (errorSelector != bytes4(0)) {
            intent.status = ICrossChainExecutor.Status.Failed;
            emit ICrossChainExecutor.IntentFailed(intent.intentId, errorSelector);
        }

        IERC20(receivedToken).safeTransfer(address(exec), amountLD);
        exec.executeIntent(BRIDGE_ID, intent, payload);

        emit IntentComposed(guid, srcEid, intent.intentId, amountLD);
    }

    /// @inheritdoc ILayerZeroStargateAdapter
    function quoteRefundFee(
        uint256 destinationChainId,
        address recipient,
        address token,
        uint256 amount,
        address stargate
    ) external view override returns (uint256 fee) {
        if (stargateByToken[token] != stargate) {
            revert LayerZeroStargateAdapterTokenNotConfigured();
        }

        uint32 dstEid = ICrossChainExecutor(executor).getLayerZeroEid(destinationChainId);
        if (dstEid == 0) {
            revert LayerZeroStargateAdapterUnknownDestinationChainId();
        }

        SendParam memory sendParam = SendParam({
            dstEid: dstEid,
            to: bytes32(uint256(uint160(recipient))),
            amountLD: amount,
            minAmountLD: 0,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory mfee = IStargate(stargate).quoteSend(sendParam, false);
        return mfee.nativeFee;
    }

    /// @inheritdoc ILayerZeroStargateAdapter
    function sendRefund(
        uint256 destinationChainId,
        address recipient,
        address token,
        uint256 amount,
        address stargate,
        address feeRefundRecipient
    ) external payable override returns (bytes32 refundId) {
        if (msg.sender != executor) {
            revert LayerZeroStargateAdapterUnauthorized();
        }

        if (stargateByToken[token] != stargate) {
            revert LayerZeroStargateAdapterTokenNotConfigured();
        }
        uint32 dstEid = ICrossChainExecutor(executor).getLayerZeroEid(destinationChainId);
        if (dstEid == 0) {
            revert LayerZeroStargateAdapterUnknownDestinationChainId();
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(stargate, amount);

        SendParam memory sendParam = SendParam({
            dstEid: dstEid,
            to: bytes32(uint256(uint160(recipient))),
            amountLD: amount,
            minAmountLD: 0,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory requiredFee = IStargate(stargate).quoteSend(sendParam, false);
        if (msg.value < requiredFee.nativeFee) {
            revert LayerZeroStargateAdapterInsufficientFee(requiredFee.nativeFee, msg.value);
        }

        (MessagingReceipt memory msgReceipt,) = IStargate(stargate).send{value: msg.value}(
            sendParam, MessagingFee({nativeFee: msg.value, lzTokenFee: 0}), payable(feeRefundRecipient)
        );

        IERC20(token).forceApprove(stargate, 0);

        refundId = msgReceipt.guid;
        emit RefundSentLZStargate(refundId, destinationChainId, recipient, token, amount);
    }

    /**
     * @notice Rescue tokens held by this adapter.
     * @dev Only callable by the owner (PoC: no protocol admin).
     * @param token Token address to rescue.
     * @param recipient Address receiving the rescued tokens.
     * @param amount Amount of tokens to rescue.
     */
    function rescueTokens(address token, address recipient, uint256 amount) external override onlyOwner {
        IERC20(token).safeTransfer(recipient, amount);
        emit TokensRescued(token, recipient, amount);
    }

    /**
     * @notice Updates the executor address.
     * @param _executor New executor address.
     */
    function setExecutor(address _executor) external onlyOwner {
        executor = _executor;
    }
}

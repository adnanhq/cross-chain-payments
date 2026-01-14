// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";

import {IExecutor} from "./interfaces/IExecutor.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IStargate} from "@stargate-v2/interfaces/IStargate.sol";
import {
    SendParam,
    MessagingFee,
    MessagingReceipt,
    OFTReceipt,
    OFTLimit,
    OFTFeeDetail
} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

/**
 * @title IntentSender
 * @notice Unified source-chain sender that can initiate cross-chain payment intents via multiple bridges.
 * @dev Stateless: pulls tokens from the user per call, approves the bridge router, sends, then clears approvals.
 */
contract IntentSender {
    using SafeERC20 for IERC20;

    struct LzStargateSendParams {
        address stargate;
        uint32 dstEid;
        address destinationAdapter;
        address sourceToken;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
    }

    /// @notice Chainlink CCIP router on this chain
    IRouterClient public immutable CCIP_ROUTER;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error IntentSender__InvalidAmount();
    error IntentSender__InvalidReceiver();
    error IntentSender__IntentExpired();
    error IntentSender__InsufficientFee();
    error IntentSender__FeeRefundFailed();

    // LayerZero/Stargate specific
    error IntentSender__InvalidStargate();
    error IntentSender__UnsupportedLzFeeToken();
    error IntentSender__UnexpectedReceivedAmount(uint256 expected, uint256 actual);

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event IntentSentCCIP(
        bytes32 indexed messageId,
        bytes32 indexed intentId,
        uint64 destinationChainSelector,
        address sender,
        address sourceToken,
        address destinationToken,
        uint256 amount
    );

    event IntentSentLayerZeroStargate(
        bytes32 indexed guid,
        bytes32 indexed intentId,
        uint32 dstEid,
        address sender,
        address stargate,
        address sourceToken,
        address destinationToken,
        uint256 amountReceivedLD
    );

    constructor(address ccipRouter_) {
        CCIP_ROUTER = IRouterClient(ccipRouter_);
    }

    /*//////////////////////////////////////////////////////////////
                             SHARED VALIDATION
    //////////////////////////////////////////////////////////////*/

    function _sanitizeIntent(IExecutor.CrossChainIntent memory intent) internal view {
        if (intent.amount == 0) revert IntentSender__InvalidAmount();
        if (intent.receiver == address(0)) revert IntentSender__InvalidReceiver();
        if (block.timestamp >= intent.deadline) revert IntentSender__IntentExpired();
        // Bind sender to caller
        intent.sender = msg.sender;
        intent.sourceChainId = block.chainid;
    }

    /*//////////////////////////////////////////////////////////////
                           CHAINLINK CCIP: SEND/QUOTE
    //////////////////////////////////////////////////////////////*/

    function quoteFeeCCIP(
        uint64 destinationChainSelector,
        address destinationAdapter,
        address sourceToken,
        IExecutor.CrossChainIntent memory intent
    ) external view returns (uint256 fee) {
        _sanitizeIntent(intent);
        Client.EVM2AnyMessage memory ccipMessage = _buildCCIPIntentMessage(destinationAdapter, sourceToken, intent);
        fee = CCIP_ROUTER.getFee(destinationChainSelector, ccipMessage);
    }

    function sendIntentCCIP(
        uint64 destinationChainSelector,
        address destinationAdapter,
        address sourceToken,
        IExecutor.CrossChainIntent memory intent
    ) external payable returns (bytes32 messageId) {
        _sanitizeIntent(intent);

        Client.EVM2AnyMessage memory ccipMessage = _buildCCIPIntentMessage(destinationAdapter, sourceToken, intent);

        uint256 fee = CCIP_ROUTER.getFee(destinationChainSelector, ccipMessage);
        if (msg.value < fee) revert IntentSender__InsufficientFee();

        IERC20(sourceToken).safeTransferFrom(msg.sender, address(this), intent.amount);
        IERC20(sourceToken).forceApprove(address(CCIP_ROUTER), intent.amount);

        messageId = CCIP_ROUTER.ccipSend{value: fee}(destinationChainSelector, ccipMessage);

        // reset approval (defensive; also prevents lingering allowance on router)
        IERC20(sourceToken).forceApprove(address(CCIP_ROUTER), 0);

        if (msg.value > fee) {
            (bool success,) = msg.sender.call{value: msg.value - fee}("");
            if (!success) revert IntentSender__FeeRefundFailed();
        }

        emit IntentSentCCIP(
            messageId,
            intent.intentId,
            destinationChainSelector,
            msg.sender,
            sourceToken,
            intent.destinationToken,
            intent.amount
        );
    }

    function _buildCCIPIntentMessage(address destinationAdapter, address sourceToken, IExecutor.CrossChainIntent memory intent)
        internal
        pure
        returns (Client.EVM2AnyMessage memory)
    {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: sourceToken, amount: intent.amount});

        return Client.EVM2AnyMessage({
            receiver: abi.encode(destinationAdapter),
            data: abi.encode(intent),
            tokenAmounts: tokenAmounts,
            feeToken: address(0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV2({gasLimit: 500_000, allowOutOfOrderExecution: true}))
        });
    }

    /*//////////////////////////////////////////////////////////////
                      LAYERZERO (STARGATE V2): SEND/QUOTE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Quote the native messaging fee for a Stargate v2 send.
     * @dev This quotes LayerZero messaging only. The amount delivered on destination may differ from amountLD
     *      due to Stargate fee/reward. Use `quoteLayerZeroStargateOFT` to compute expected delivered amount.
     */
    function quoteFeeLayerZeroStargate(
        address stargate,
        SendParam calldata sendParam,
        bool payInLzToken
    ) external view returns (uint256 nativeFee) {
        MessagingFee memory fee = IStargate(stargate).quoteSend(sendParam, payInLzToken);
        return fee.nativeFee;
    }

    /**
     * @notice Quote the expected delivered amount (OFTReceipt) for a Stargate v2 send.
     */
    function quoteLayerZeroStargateOFT(address stargate, SendParam calldata sendParam)
        external
        view
        returns (OFTLimit memory limit, OFTFeeDetail[] memory feeDetails, OFTReceipt memory receipt)
    {
        return IStargate(stargate).quoteOFT(sendParam);
    }

    /**
     * @notice Send an intent via Stargate v2 + LayerZero v2 compose.
     * @dev The destination adapter will receive tokens and then execute `lzCompose` with the encoded intent.
     *      For safety, we require that the user-provided intent.amount equals the expected delivered amount.
     *
     * @param p Stargate + LayerZero send parameters (dstEid, destinationAdapter, sourceToken, amountLD, minAmountLD, extraOptions).
     * @param intent Cross-chain intent; intent.amount must equal the expected delivered amount (amountReceivedLD).
     * @return guid The LayerZero guid for tracking.
     */
    function sendIntentLayerZeroStargate(
        LzStargateSendParams calldata p,
        IExecutor.CrossChainIntent memory intent
    ) external payable returns (bytes32 guid) {
        _sanitizeIntent(intent);

        // Validate Stargate token matches provided sourceToken to avoid approving/bridging wrong assets.
        if (IStargate(p.stargate).token() != p.sourceToken) revert IntentSender__InvalidStargate();

        // Build compose message: [composeFrom=this][composeMsg=abi.encode(intent)]
        bytes memory composeMsg = abi.encodePacked(bytes32(uint256(uint160(address(this)))), abi.encode(intent));

        SendParam memory sendParam = SendParam({
            dstEid: p.dstEid,
            to: bytes32(uint256(uint160(p.destinationAdapter))),
            amountLD: p.amountLD,
            minAmountLD: p.minAmountLD,
            extraOptions: p.extraOptions,
            composeMsg: composeMsg,
            oftCmd: "" // Taxi mode required for compose (bus does not support compose)
        });

        // Quote expected delivered amount and require it matches intent.amount.
        uint256 amountReceivedLD;
        {
            (, , OFTReceipt memory receipt) = IStargate(p.stargate).quoteOFT(sendParam);
            amountReceivedLD = receipt.amountReceivedLD;
        }
        if (amountReceivedLD != intent.amount) revert IntentSender__UnexpectedReceivedAmount(intent.amount, amountReceivedLD);

        uint256 nativeFee;
        {
            MessagingFee memory fee = IStargate(p.stargate).quoteSend(sendParam, false);
            if (fee.lzTokenFee != 0) revert IntentSender__UnsupportedLzFeeToken();
            nativeFee = fee.nativeFee;
        }
        if (msg.value < nativeFee) revert IntentSender__InsufficientFee();

        IERC20(p.sourceToken).safeTransferFrom(msg.sender, address(this), p.amountLD);
        IERC20(p.sourceToken).forceApprove(p.stargate, p.amountLD);

        // Stargate requires `msg.value == fee.nativeFee` (see StargateBase._assertMessagingFee), so if a caller
        // provides a buffer above the quote we pass the full msg.value as `nativeFee`. LayerZero EndpointV2 will
        // refund any excess above the required fee to `refundAddress`.
        (MessagingReceipt memory msgReceipt,) = IStargate(p.stargate).send{value: msg.value}(
            sendParam,
            MessagingFee({nativeFee: msg.value, lzTokenFee: 0}),
            payable(msg.sender) // receive LayerZero/Stargate fee refunds directly
        );

        // reset approval
        IERC20(p.sourceToken).forceApprove(p.stargate, 0);

        guid = msgReceipt.guid;

        emit IntentSentLayerZeroStargate(
            guid,
            intent.intentId,
            p.dstEid,
            msg.sender,
            p.stargate,
            p.sourceToken,
            intent.destinationToken,
            amountReceivedLD
        );
    }

    receive() external payable {}
}



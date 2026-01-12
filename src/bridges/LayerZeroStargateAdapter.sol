// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IExecutor} from "../interfaces/IExecutor.sol";

import {ILayerZeroComposer} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {OFTComposeMsgCodec} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/libs/OFTComposeMsgCodec.sol";
import {IStargate} from "@stargate-v2/interfaces/IStargate.sol";
import {SendParam, MessagingFee, MessagingReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

/**
 * @title LayerZeroStargateAdapter
 * @notice Destination-chain adapter for LayerZero v2 + Stargate v2 token delivery + compose execution.
 * @dev Receives compose calls from the local LayerZero Endpoint, verifies provenance, forwards funds to Executor,
 *      and triggers intent execution. Implements `IBridgeAdapter` for refund bridging via Stargate v2.
 */
contract LayerZeroStargateAdapter is ILayerZeroComposer, IBridgeAdapter, Ownable {
    using SafeERC20 for IERC20;

    bytes32 public constant BRIDGE_ID = keccak256("LAYERZERO");

    /// @notice Local LayerZero EndpointV2 (calls lzCompose)
    ILayerZeroEndpointV2 public immutable ENDPOINT;

    /// @notice Destination-chain Executor (receives funds + executes intent)
    IExecutor public executor;

    /// @notice srcEid => trusted composeFrom (bytes32-encoded source sender contract)
    mapping(uint32 => bytes32) public peers;

    /// @notice destination chainId => dstEid (used for refunds back to the source chain)
    mapping(uint256 => uint32) public dstEidByChainId;

    /// @notice Destination token => Stargate v2 contract address on this chain for that token
    mapping(address => address) public stargateByDestinationToken;

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error LayerZeroStargateAdapter__Unauthorized();
    error LayerZeroStargateAdapter__InvalidPeer();
    error LayerZeroStargateAdapter__InvalidStargateComposer();
    error LayerZeroStargateAdapter__TokenNotConfigured();
    error LayerZeroStargateAdapter__AmountMismatch();
    error LayerZeroStargateAdapter__UnknownDestinationChainId();
    error LayerZeroStargateAdapter__SourceChainIdMismatch(uint256 payloadChainId, uint32 provenanceSrcEid, uint32 expectedEid);

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event PeerSet(uint32 indexed srcEid, bytes32 indexed peer);
    event ChainIdMapped(uint256 indexed chainId, uint32 indexed dstEid);
    event StargateForTokenSet(address indexed token, address indexed stargate);
    event ExecutorSet(address indexed executor);
    event IntentComposed(bytes32 indexed guid, uint32 indexed srcEid, bytes32 indexed intentId, uint256 amountLD);
    event RefundSent(bytes32 indexed guid, uint256 destinationChainId, address recipient, address token, uint256 amount);

    constructor(address endpoint, address _executor) Ownable(msg.sender) {
        ENDPOINT = ILayerZeroEndpointV2(endpoint);
        executor = IExecutor(_executor);
    }

    /*//////////////////////////////////////////////////////////////
                         LAYERZERO COMPOSE RECEIVE
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice LayerZero compose entrypoint (called by local EndpointV2).
     * @dev Security model:
     *  - Only EndpointV2 can call this function.
     *  - `_from` must be the Stargate v2 contract expected for `intent.destinationToken` (prevents arbitrary local sendCompose abuse).
     *  - `_message` must have `composeFrom` matching `peers[srcEid]` (source-side sender allowlist).
     *  - Amount delivered in `_message` must match `intent.amount`.
     */
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address, /*_executor*/
        bytes calldata /*_extraData*/
    ) external payable override {
        if (msg.sender != address(ENDPOINT)) revert LayerZeroStargateAdapter__Unauthorized();

        uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);

        bytes32 composeFrom = OFTComposeMsgCodec.composeFrom(_message);
        if (composeFrom != peers[srcEid]) revert LayerZeroStargateAdapter__InvalidPeer();

        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);

        bytes memory inner = OFTComposeMsgCodec.composeMsg(_message);
        IExecutor.CrossChainIntent memory intent = abi.decode(inner, (IExecutor.CrossChainIntent));

        // Validate the claimed sourceChainId against LayerZero provenance srcEid using the chainId->eid mapping.
        uint32 expectedEid = dstEidByChainId[intent.sourceChainId];
        if (expectedEid != srcEid) {
            revert LayerZeroStargateAdapter__SourceChainIdMismatch(intent.sourceChainId, srcEid, expectedEid);
        }

        // Ensure the compose was initiated by the correct Stargate contract for this token.
        address expectedStargate = stargateByDestinationToken[intent.destinationToken];
        if (expectedStargate == address(0)) revert LayerZeroStargateAdapter__TokenNotConfigured();
        if (_from != expectedStargate) revert LayerZeroStargateAdapter__InvalidStargateComposer();

        // Ensure amount matches.
        if (intent.amount != amountLD) revert LayerZeroStargateAdapter__AmountMismatch();

        // Forward funds to Executor then execute intent.
        IERC20(intent.destinationToken).safeTransfer(address(executor), amountLD);
        executor.executeIntent(BRIDGE_ID, intent);

        emit IntentComposed(_guid, srcEid, intent.intentId, amountLD);
    }

    /*//////////////////////////////////////////////////////////////
                        REFUNDS (IBridgeAdapter)
    //////////////////////////////////////////////////////////////*/

    function quoteRefundFee(uint256 destinationChainId, address token, uint256 amount)
        external
        view
        override
        returns (uint256 fee)
    {
        address stargate = stargateByDestinationToken[token];
        if (stargate == address(0)) revert LayerZeroStargateAdapter__TokenNotConfigured();
        uint32 dstEid = dstEidByChainId[destinationChainId];
        if (dstEid == 0) revert LayerZeroStargateAdapter__UnknownDestinationChainId();

        SendParam memory sendParam = SendParam({
            dstEid: dstEid,
            to: bytes32(uint256(uint160(address(0)))), // placeholder; fee is independent of recipient for typical configs
            amountLD: amount,
            minAmountLD: amount, // conservative: require full amount delivered
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory mfee = IStargate(stargate).quoteSend(sendParam, false);
        return mfee.nativeFee;
    }

    function sendRefund(uint256 destinationChainId, address recipient, address token, uint256 amount)
        external
        payable
        override
        returns (bytes32 refundId)
    {
        if (msg.sender != address(executor)) revert LayerZeroStargateAdapter__Unauthorized();

        address stargate = stargateByDestinationToken[token];
        if (stargate == address(0)) revert LayerZeroStargateAdapter__TokenNotConfigured();
        uint32 dstEid = dstEidByChainId[destinationChainId];
        if (dstEid == 0) revert LayerZeroStargateAdapter__UnknownDestinationChainId();

        // Pull tokens from Executor.
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Approve Stargate, send, then clear approval.
        IERC20(token).forceApprove(stargate, amount);

        SendParam memory sendParam = SendParam({
            dstEid: dstEid,
            to: bytes32(uint256(uint160(recipient))),
            amountLD: amount,
            minAmountLD: amount, // conservative: require full amount delivered
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        (MessagingReceipt memory msgReceipt,) = IStargate(stargate).send{value: msg.value}(
            sendParam,
            MessagingFee({nativeFee: msg.value, lzTokenFee: 0}),
            payable(address(this)) // adapter can safely receive any native refunds from Stargate/LayerZero
        );

        IERC20(token).forceApprove(stargate, 0);

        refundId = msgReceipt.guid;
        emit RefundSent(refundId, destinationChainId, recipient, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               ADMIN CONFIG
    //////////////////////////////////////////////////////////////*/

    function setPeer(uint32 srcEid, bytes32 peer) external onlyOwner {
        peers[srcEid] = peer;
        emit PeerSet(srcEid, peer);
    }

    function setChainIdMapping(uint256 chainId, uint32 dstEid) external onlyOwner {
        if (dstEid == 0) revert LayerZeroStargateAdapter__UnknownDestinationChainId();
        dstEidByChainId[chainId] = dstEid;
        emit ChainIdMapped(chainId, dstEid);
    }

    function setStargateForToken(address token, address stargate) external onlyOwner {
        stargateByDestinationToken[token] = stargate;
        emit StargateForTokenSet(token, stargate);
    }

    function setExecutor(address _executor) external onlyOwner {
        executor = IExecutor(_executor);
        emit ExecutorSet(_executor);
    }

    receive() external payable {}
}



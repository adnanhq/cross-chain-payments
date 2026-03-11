// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IntentSender} from "../src/IntentSender.sol";
import {ICrossChainExecutor} from "../src/interfaces/ICrossChainExecutor.sol";
import {ISimpleFundReceiver} from "../src/interfaces/ISimpleFundReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStargate} from "@stargate-v2/interfaces/IStargate.sol";
import {SendParam, OFTReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

/**
 * Send a cross-chain intent via CCIP or LayerZero/Stargate.
 *
 * Required env:
 * - SENDER: IntentSender contract address
 * - BRIDGE: "CCIP" or "LAYERZERO"
 * - ACCOUNT: Payer account (must approve IntentSender for token amount)
 * - TREASURY: SimpleFundReceiver (or treasury) address on destination
 * - SOURCE_TOKEN: Token address on source chain
 * - AMOUNT: Token amount to bridge
 *
 * For CCIP: DEST_CHAIN_SELECTOR, DEST_ADAPTER are on IntentSender (immutable).
 * For LZ: STARGATE, DST_EID - use quoteFeeLZStargate for fee.
 *
 * Note: ACCOUNT must approve IntentSender for AMOUNT before running.
 * Script runs as AGENT (onlyAgent can call send).
 */
contract SendIntent is Script {
    function run() external {
        string memory bridge = vm.envOr("BRIDGE", string("CCIP"));

        if (keccak256(bytes(bridge)) == keccak256("CCIP")) {
            _runCCIP();
        } else if (keccak256(bytes(bridge)) == keccak256("LAYERZERO")) {
            _runLayerZero();
        } else {
            revert("Unsupported BRIDGE");
        }
    }

    function _runCCIP() internal {
        address senderContract = vm.envAddress("SENDER");
        address account = vm.envAddress("ACCOUNT");
        address treasury = vm.envAddress("TREASURY");
        address token = vm.envAddress("SOURCE_TOKEN");
        uint256 amount = vm.envUint("AMOUNT");

        IntentSender sender = IntentSender(payable(senderContract));

        bytes32 intentId = keccak256(abi.encodePacked(block.timestamp, account, "test-intent"));

        ICrossChainExecutor.Intent memory intent = ICrossChainExecutor.Intent({
            intentId: intentId,
            sourceChainId: 0,
            status: ICrossChainExecutor.Status.None,
            treasury: treasury,
            account: account,
            token: token,
            amount: amount
        });

        bytes memory payload = abi.encodeWithSelector(
            ISimpleFundReceiver.processPayment.selector,
            intentId,
            account,
            token,
            amount,
            ""
        );

        vm.startBroadcast();

        uint256 fee = sender.quoteFeeCCIP(intent, payload, 0);
        console.log("CCIP Fee:", fee);

        bytes32 messageId = sender.sendIntentCCIP{value: fee}(intent, payload, 0);

        vm.stopBroadcast();

        console.log("Intent ID:");
        console.logBytes32(intentId);
        console.log("CCIP Message ID:");
        console.logBytes32(messageId);
    }

    function _runLayerZero() internal {
        address senderContract = vm.envAddress("SENDER");
        address account = vm.envAddress("ACCOUNT");
        address treasury = vm.envAddress("TREASURY");
        address token = vm.envAddress("SOURCE_TOKEN");
        uint256 amount = vm.envUint("AMOUNT");
        address stargate = vm.envAddress("STARGATE");

        IntentSender sender = IntentSender(payable(senderContract));

        bytes32 intentId = keccak256(abi.encodePacked(block.timestamp, account, "test-intent"));

        ICrossChainExecutor.Intent memory intent = ICrossChainExecutor.Intent({
            intentId: intentId,
            sourceChainId: 0,
            status: ICrossChainExecutor.Status.None,
            treasury: treasury,
            account: account,
            token: token,
            amount: amount
        });

        IntentSender.LZStargateParams memory params = IntentSender.LZStargateParams({
            stargate: stargate,
            minAmount: amount,
            gasLimit: 0
        });

        bytes memory payload = abi.encodeWithSelector(
            ISimpleFundReceiver.processPayment.selector,
            intentId,
            account,
            token,
            amount,
            ""
        );

        vm.startBroadcast();

        (uint256 nativeFee,,, OFTReceipt memory receipt) = sender.quoteFeeLZStargate(params, intent, payload);
        console.log("LayerZero Fee:", nativeFee);

        if (receipt.amountReceivedLD != amount) {
            intent.amount = receipt.amountReceivedLD;
            payload = abi.encodeWithSelector(
                ISimpleFundReceiver.processPayment.selector,
                intentId,
                account,
                token,
                receipt.amountReceivedLD,
                ""
            );
        }

        bytes32 guid = sender.sendIntentLZStargate{value: nativeFee}(params, intent, payload);

        vm.stopBroadcast();

        console.log("Intent ID:");
        console.logBytes32(intentId);
        console.log("LayerZero GUID:");
        console.logBytes32(guid);
    }
}

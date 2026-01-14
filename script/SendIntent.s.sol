// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {IntentSender} from "../src/IntentSender.sol";
import {IExecutor} from "../src/interfaces/IExecutor.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IStargate} from "@stargate-v2/interfaces/IStargate.sol";
import {SendParam, OFTReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

contract SendIntent is Script {
    function run() external {
        string memory bridge = vm.envOr("BRIDGE", string("CCIP")); // "CCIP" or "LAYERZERO"
        bytes32 bridgeHash = keccak256(bytes(bridge));

        if (bridgeHash == keccak256("CCIP")) {
            _runCCIP();
        } else if (bridgeHash == keccak256("LAYERZERO")) {
            _runLayerZero();
        } else {
            revert("Unsupported BRIDGE");
        }
    }

    function _runCCIP() internal {
        address senderContract = vm.envAddress("SENDER");
        uint64 destChainSelector = uint64(vm.envUint("DEST_CHAIN_SELECTOR"));
        address destAdapter = vm.envAddress("DEST_ADAPTER");
        address destReceiver = vm.envAddress("DEST_RECEIVER");
        address sourceToken = vm.envAddress("SOURCE_TOKEN");
        address destToken = vm.envAddress("DEST_TOKEN");
        uint256 amount = vm.envUint("AMOUNT");

        IntentSender sender = IntentSender(payable(senderContract));

        vm.startBroadcast();

        bytes32 intentId = keccak256(abi.encodePacked(block.timestamp, msg.sender, "test-intent"));

        IExecutor.CrossChainIntent memory intent = IExecutor.CrossChainIntent({
            intentId: intentId,
            sourceChainId: 0, // ignored; populated by destination adapter from bridge provenance
            sender: address(0),
            destinationToken: destToken,
            amount: amount,
            receiver: destReceiver,
            data: "",
            deadline: block.timestamp + 1 hours
        });

        IERC20(sourceToken).approve(senderContract, amount);
        uint256 fee = sender.quoteFeeCCIP(destChainSelector, destAdapter, sourceToken, intent);
        console.log("CCIP Fee:", fee);

        bytes32 messageId = sender.sendIntentCCIP{value: fee}(destChainSelector, destAdapter, sourceToken, intent);

        vm.stopBroadcast();

        console.log("Intent ID:");
        console.logBytes32(intentId);
        console.log("CCIP Message ID:");
        console.logBytes32(messageId);
    }

    function _runLayerZero() internal {
        address senderContract = vm.envAddress("SENDER");
        address destReceiver = vm.envAddress("DEST_RECEIVER");
        address destToken = vm.envAddress("DEST_TOKEN");
        address destAdapter = vm.envAddress("DEST_ADAPTER");

        IntentSender.LzStargateSendParams memory p = IntentSender.LzStargateSendParams({
            stargate: vm.envAddress("STARGATE"),
            dstEid: uint32(vm.envUint("DST_EID")),
            destinationAdapter: destAdapter,
            sourceToken: vm.envAddress("SOURCE_TOKEN"),
            amountLD: vm.envUint("AMOUNT"),
            minAmountLD: 0, // set below
            extraOptions: vm.envOr("LZ_EXTRA_OPTIONS", bytes(""))
        });
        p.minAmountLD = vm.envOr("MIN_AMOUNT_LD", p.amountLD);

        IntentSender sender = IntentSender(payable(senderContract));

        vm.startBroadcast();

        bytes32 intentId = keccak256(abi.encodePacked(block.timestamp, msg.sender, "test-intent"));

        // Intent amount must match the expected delivered amount (after Stargate fee/reward).
        IExecutor.CrossChainIntent memory intent = IExecutor.CrossChainIntent({
            intentId: intentId,
            sourceChainId: 0, // ignored; populated by destination adapter from bridge provenance
            sender: address(0),
            destinationToken: destToken,
            amount: 0, // set below from quoteOFT
            receiver: destReceiver,
            data: "",
            deadline: block.timestamp + 1 hours
        });

        SendParam memory quoteParam = SendParam({
            dstEid: p.dstEid,
            to: bytes32(uint256(uint160(destAdapter))),
            amountLD: p.amountLD,
            minAmountLD: p.minAmountLD,
            extraOptions: p.extraOptions,
            composeMsg: "",
            oftCmd: ""
        });

        (, , OFTReceipt memory receipt) = IStargate(p.stargate).quoteOFT(quoteParam);
        intent.amount = receipt.amountReceivedLD;

        bytes memory composeMsg = abi.encodePacked(bytes32(uint256(uint160(senderContract))), abi.encode(intent));
        SendParam memory sendParam = SendParam({
            dstEid: p.dstEid,
            to: bytes32(uint256(uint160(destAdapter))),
            amountLD: p.amountLD,
            minAmountLD: p.minAmountLD,
            extraOptions: p.extraOptions,
            composeMsg: composeMsg,
            oftCmd: ""
        });

        IERC20(p.sourceToken).approve(senderContract, p.amountLD);
        uint256 fee = sender.quoteFeeLayerZeroStargate(p.stargate, sendParam, false);
        console.log("LayerZero/Stargate Fee:", fee);

        bytes32 guid = sender.sendIntentLayerZeroStargate{value: fee}(p, intent);

        vm.stopBroadcast();

        console.log("Intent ID:");
        console.logBytes32(intentId);
        console.log("LayerZero GUID:");
        console.logBytes32(guid);
    }
}

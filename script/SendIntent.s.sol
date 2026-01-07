// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {CCIPSender} from "../src/CCIPSender.sol";
import {IExecutor} from "../src/interfaces/IExecutor.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract SendIntent is Script {
    function run() external {
        address senderContract = vm.envAddress("SENDER");
        uint64 destChainSelector = uint64(vm.envUint("DEST_CHAIN_SELECTOR"));
        address destAdapter = vm.envAddress("DEST_ADAPTER");
        address destReceiver = vm.envAddress("DEST_RECEIVER");
        uint64 sourceChainSelector = uint64(vm.envUint("SOURCE_CHAIN_SELECTOR"));
        address sourceToken = vm.envAddress("SOURCE_TOKEN");
        address destToken = vm.envAddress("DEST_TOKEN");
        uint256 amount = vm.envUint("AMOUNT");

        CCIPSender sender = CCIPSender(payable(senderContract));

        vm.startBroadcast();

        // Build intent AFTER broadcast so `msg.sender` is the broadcaster EOA
        bytes32 intentId = keccak256(abi.encodePacked(block.timestamp, msg.sender, "test-intent"));

        IExecutor.CrossChainIntent memory intent = IExecutor.CrossChainIntent({
            intentId: intentId,
            sourceChainSelector: sourceChainSelector, // CCIP chain selector of the source chain
            sender: msg.sender, // will be bound again in CCIPSender for safety
            token: destToken, // destination-chain token expected to be delivered by CCIP
            amount: amount,
            receiver: destReceiver,
            kind: IExecutor.IntentKind.Payment,
            data: "",
            deadline: block.timestamp + 1 hours
        });

        // Approve the SOURCE token (on this chain) to be bridged via CCIP
        IERC20(sourceToken).approve(senderContract, amount);

        // Quote fee and send intent
        uint256 fee = sender.quoteFee(destChainSelector, destAdapter, sourceToken, intent);
        console.log("CCIP Fee:", fee);

        bytes32 messageId = sender.sendIntent{value: fee}(destChainSelector, destAdapter, sourceToken, intent);

        vm.stopBroadcast();

        console.log("Intent ID:");
        console.logBytes32(intentId);
        console.log("CCIP Message ID:");
        console.logBytes32(messageId);
    }
}

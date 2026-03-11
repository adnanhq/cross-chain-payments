// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CrossChainExecutor} from "../src/CrossChainExecutor.sol";

/**
 * Configure the CrossChainExecutor after deployment.
 * Use when adding/updating intent senders, chain selectors, or LayerZero eids
 * (e.g. after deploying the source-chain IntentSender).
 *
 * Required env:
 * - EXECUTOR: CrossChainExecutor address
 *
 * Intent senders:
 * - SOURCE_CHAIN_ID: Source chain EVM ID
 * - SOURCE_SENDER: IntentSender address on source chain
 *
 * CCIP:
 * - CCIP_SOURCE_CHAIN_SELECTOR: CCIP chain selector for source chain
 *
 * LayerZero:
 * - LZ_SOURCE_EID: LayerZero endpoint ID for source chain
 */
contract ConfigureExecutor is Script {
    function run() external {
        address executorAddress = vm.envAddress("EXECUTOR");
        CrossChainExecutor exec = CrossChainExecutor(executorAddress);

        uint256 sourceChainId = vm.envOr("SOURCE_CHAIN_ID", uint256(0));
        address sourceSender = vm.envOr("SOURCE_SENDER", address(0));
        uint64 ccipSourceChainSelector = uint64(vm.envOr("CCIP_SOURCE_CHAIN_SELECTOR", uint256(0)));
        uint32 lzSourceEid = uint32(vm.envOr("LZ_SOURCE_EID", uint256(0)));

        vm.startBroadcast();

        if (sourceChainId != 0 && sourceSender != address(0)) {
            uint256[] memory chainIds = new uint256[](1);
            chainIds[0] = sourceChainId;
            address[] memory senders = new address[](1);
            senders[0] = sourceSender;
            exec.setIntentSenders(chainIds, senders);
            console.log("IntentSender set for chain:", sourceChainId, "sender:", sourceSender);
        }

        if (sourceChainId != 0 && ccipSourceChainSelector != 0) {
            uint256[] memory chainIds = new uint256[](1);
            chainIds[0] = sourceChainId;
            uint64[] memory selectorsArr = new uint64[](1);
            selectorsArr[0] = ccipSourceChainSelector;
            exec.setCcipChainSelectors(chainIds, selectorsArr);
            console.log("CCIP selector set for chain:", sourceChainId);
        }

        if (sourceChainId != 0 && lzSourceEid != 0) {
            uint256[] memory chainIds = new uint256[](1);
            chainIds[0] = sourceChainId;
            uint32[] memory eids = new uint32[](1);
            eids[0] = lzSourceEid;
            exec.setLayerZeroEids(chainIds, eids);
            console.log("LayerZero eid set for chain:", sourceChainId);
        }

        vm.stopBroadcast();
    }
}

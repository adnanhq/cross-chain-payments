// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {CrossChainExecutor} from "../src/CrossChainExecutor.sol";
import {ChainlinkCCIPAdapter} from "../src/bridges/ChainlinkCCIPAdapter.sol";
import {LayerZeroStargateAdapter} from "../src/bridges/LayerZeroStargateAdapter.sol";
import {SimpleFundReceiver} from "../src/SimpleFundReceiver.sol";
import {ISimpleFundReceiver} from "../src/interfaces/ISimpleFundReceiver.sol";

/**
 * Deploy destination-chain contracts.
 *
 * Required env:
 * - CCIP_ROUTER: Chainlink CCIP router address
 * - AGENT: Authorized agent for sending intents and executing refunds
 *
 * Optional (for executor config):
 * - SOURCE_CHAIN_ID: Source chain EVM ID
 * - SOURCE_SENDER: IntentSender address on source chain
 * - CCIP_SOURCE_CHAIN_SELECTOR: CCIP chain selector for source chain
 * - LZ_SOURCE_EID: LayerZero endpoint ID for source chain
 * - LZ_ENDPOINT_V2: LayerZero endpoint address (if using LZ)
 * - LZ_DESTINATION_TOKEN: Destination token delivered by Stargate (optional)
 * - LZ_DESTINATION_STARGATE: Trusted Stargate contract for that token (optional)
 */
contract DeployDestination is Script {
    function run() external {
        address ccipRouter = vm.envAddress("CCIP_ROUTER");
        address agent = vm.envAddress("AGENT");
        uint256 sourceChainId = vm.envOr("SOURCE_CHAIN_ID", uint256(0));
        address sourceSender = vm.envOr("SOURCE_SENDER", address(0));
        uint64 ccipSourceChainSelector = uint64(vm.envOr("CCIP_SOURCE_CHAIN_SELECTOR", uint256(0)));
        uint32 lzSourceEid = uint32(vm.envOr("LZ_SOURCE_EID", uint256(0)));
        address lzEndpointV2 = vm.envOr("LZ_ENDPOINT_V2", address(0));
        address lzDestinationToken = vm.envOr("LZ_DESTINATION_TOKEN", address(0));
        address lzDestinationStargate = vm.envOr("LZ_DESTINATION_STARGATE", address(0));

        vm.startBroadcast();

        CrossChainExecutor executor = new CrossChainExecutor(agent);
        console.log("CrossChainExecutor:", address(executor));

        ChainlinkCCIPAdapter ccipAdapter = new ChainlinkCCIPAdapter(ccipRouter, address(executor));
        console.log("ChainlinkCCIPAdapter:", address(ccipAdapter));

        LayerZeroStargateAdapter lzAdapter;
        if (lzEndpointV2 != address(0)) {
            lzAdapter = new LayerZeroStargateAdapter(lzEndpointV2, address(executor));
            console.log("LayerZeroStargateAdapter:", address(lzAdapter));

            if (lzDestinationToken != address(0) && lzDestinationStargate != address(0)) {
                lzAdapter.setStargateForToken(lzDestinationToken, lzDestinationStargate);
                console.log("LayerZeroStargate configured for token:", lzDestinationToken);
            }
        }

        SimpleFundReceiver receiver = new SimpleFundReceiver(address(executor));
        console.log("SimpleFundReceiver:", address(receiver));

        _configureExecutor(executor, ccipAdapter, lzAdapter, sourceChainId, sourceSender, ccipSourceChainSelector, lzSourceEid);

        vm.stopBroadcast();
    }

    function _configureExecutor(
        CrossChainExecutor exec,
        ChainlinkCCIPAdapter ccipAdapter,
        LayerZeroStargateAdapter lzAdapter,
        uint256 sourceChainId,
        address sourceSender,
        uint64 ccipSourceChainSelector,
        uint32 lzSourceEid
    ) internal {
        bytes32[] memory bridgeIds;
        address[] memory adapters;

        if (address(lzAdapter) != address(0)) {
            bridgeIds = new bytes32[](2);
            bridgeIds[0] = exec.BRIDGE_ID_CCIP();
            bridgeIds[1] = exec.BRIDGE_ID_LAYERZERO();
            adapters = new address[](2);
            adapters[0] = address(ccipAdapter);
            adapters[1] = address(lzAdapter);
        } else {
            bridgeIds = new bytes32[](1);
            bridgeIds[0] = exec.BRIDGE_ID_CCIP();
            adapters = new address[](1);
            adapters[0] = address(ccipAdapter);
        }

        exec.setBridgeAdapters(bridgeIds, adapters);

        bytes4 processPaymentSelector = ISimpleFundReceiver.processPayment.selector;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = processPaymentSelector;
        exec.setSelectors(selectors, true);

        if (sourceChainId != 0 && sourceSender != address(0)) {
            uint256[] memory chainIds = new uint256[](1);
            chainIds[0] = sourceChainId;
            address[] memory senders = new address[](1);
            senders[0] = sourceSender;
            exec.setIntentSenders(chainIds, senders);
            console.log("IntentSender set for chain:", sourceChainId);
        }

        if (sourceChainId != 0 && ccipSourceChainSelector != 0) {
            uint256[] memory chainIds = new uint256[](1);
            chainIds[0] = sourceChainId;
            uint64[] memory selectorsArr = new uint64[](1);
            selectorsArr[0] = ccipSourceChainSelector;
            exec.setCcipChainSelectors(chainIds, selectorsArr);
            console.log("CCIP selector set for chain:", sourceChainId);
        }

        if (sourceChainId != 0 && lzSourceEid != 0 && address(lzAdapter) != address(0)) {
            uint256[] memory chainIds = new uint256[](1);
            chainIds[0] = sourceChainId;
            uint32[] memory eids = new uint32[](1);
            eids[0] = lzSourceEid;
            exec.setLayerZeroEids(chainIds, eids);
            console.log("LayerZero eid set for chain:", sourceChainId);
        }
    }
}

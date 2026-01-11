// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {Executor} from "../src/Executor.sol";
import {CrossChainRegistry} from "../src/CrossChainRegistry.sol";
import {ChainlinkCCIPAdapter} from "../src/bridges/ChainlinkCCIPAdapter.sol";
import {LayerZeroStargateAdapter} from "../src/bridges/LayerZeroStargateAdapter.sol";
import {SimpleFundReceiver} from "../src/SimpleFundReceiver.sol";
import {ICrossChainRegistry} from "../src/interfaces/ICrossChainRegistry.sol";

contract DeployDestination is Script {
    function run() external {
        address ccipRouter = vm.envAddress("CCIP_ROUTER");
        uint64 sourceChainSelector = uint64(vm.envUint("SOURCE_CHAIN_SELECTOR"));
        address sourceSender = vm.envOr("SOURCE_SENDER", address(0));
        address lzEndpointV2 = vm.envOr("LZ_ENDPOINT_V2", address(0));
        uint32 lzSourceEid = uint32(vm.envOr("LZ_SOURCE_EID", uint256(0)));
        address lzDestinationToken = vm.envOr("LZ_DESTINATION_TOKEN", address(0));
        address lzDestinationStargate = vm.envOr("LZ_DESTINATION_STARGATE", address(0));

        vm.startBroadcast();

        CrossChainRegistry registry = new CrossChainRegistry();
        console.log("CrossChainRegistry:", address(registry));

        Executor executor = new Executor(address(registry));
        console.log("Executor:", address(executor));

        ChainlinkCCIPAdapter adapter = new ChainlinkCCIPAdapter(ccipRouter, address(executor));
        console.log("ChainlinkCCIPAdapter:", address(adapter));

        LayerZeroStargateAdapter lzAdapter;
        if (lzEndpointV2 != address(0)) {
            lzAdapter = new LayerZeroStargateAdapter(lzEndpointV2, address(executor));
            console.log("LayerZeroStargateAdapter:", address(lzAdapter));
        }

        SimpleFundReceiver receiver = new SimpleFundReceiver(address(executor));
        console.log("SimpleFundReceiver:", address(receiver));

        registry.setChainConfig(
            sourceChainSelector, ICrossChainRegistry.ChainConfig({isSupported: true, isPaused: false})
        );

        bytes32 bridgeId = keccak256("CCIP");
        registry.setBridgeAdapter(sourceChainSelector, bridgeId, address(adapter), true);
        executor.setAdapterAuthorization(address(adapter), true);

        if (sourceSender != address(0)) {
            adapter.setAllowedSender(sourceChainSelector, sourceSender, true);
            console.log("Source sender allowed:", sourceSender);
        }

        if (address(lzAdapter) != address(0)) {
            bytes32 lzBridgeId = keccak256("LAYERZERO");
            registry.setBridgeAdapter(sourceChainSelector, lzBridgeId, address(lzAdapter), true);
            executor.setAdapterAuthorization(address(lzAdapter), true);

            // Minimal required config for secure compose verification.
            if (lzSourceEid != 0 && sourceSender != address(0)) {
                lzAdapter.setPeer(lzSourceEid, bytes32(uint256(uint160(sourceSender))));
                lzAdapter.setSrcEidMapping(lzSourceEid, sourceChainSelector);
                lzAdapter.setChainSelectorMapping(sourceChainSelector, lzSourceEid);
                console.log("LayerZero peer set to source sender for srcEid:", lzSourceEid);
            }

            // Token -> Stargate mapping on destination chain (required for compose sender verification + refunds).
            if (lzDestinationToken != address(0) && lzDestinationStargate != address(0)) {
                lzAdapter.setStargateForToken(lzDestinationToken, lzDestinationStargate);
                console.log("LayerZero destination token configured:", lzDestinationToken);
            }
        }

        vm.stopBroadcast();
    }
}

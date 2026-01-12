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
        uint256 sourceChainId = vm.envUint("SOURCE_CHAIN_ID");
        address sourceSender = vm.envOr("SOURCE_SENDER", address(0));
        address lzEndpointV2 = vm.envOr("LZ_ENDPOINT_V2", address(0));

        vm.startBroadcast();

        CrossChainRegistry registry = new CrossChainRegistry();
        console.log("CrossChainRegistry:", address(registry));

        Executor executor = new Executor(address(registry));
        console.log("Executor:", address(executor));

        ChainlinkCCIPAdapter adapter = new ChainlinkCCIPAdapter(ccipRouter, address(executor));
        console.log("ChainlinkCCIPAdapter:", address(adapter));

        _configureCCIP(registry, executor, adapter, sourceChainId, sourceSender);

        LayerZeroStargateAdapter lzAdapter;
        if (lzEndpointV2 != address(0)) {
            lzAdapter = new LayerZeroStargateAdapter(lzEndpointV2, address(executor));
            console.log("LayerZeroStargateAdapter:", address(lzAdapter));
            _configureLayerZero(registry, executor, lzAdapter, sourceChainId, sourceSender);
        }

        SimpleFundReceiver receiver = new SimpleFundReceiver(address(executor));
        console.log("SimpleFundReceiver:", address(receiver));

        vm.stopBroadcast();
    }

    function _configureCCIP(
        CrossChainRegistry registry,
        Executor executor,
        ChainlinkCCIPAdapter adapter,
        uint256 sourceChainId,
        address sourceSender
    ) internal {
        registry.setChainConfig(sourceChainId, ICrossChainRegistry.ChainConfig({isSupported: true, isPaused: false}));

        bytes32 bridgeId = keccak256("CCIP");
        registry.setBridgeAdapter(sourceChainId, bridgeId, address(adapter), true);
        executor.setAdapterAuthorization(address(adapter), true);

        uint64 ccipSourceChainSelector = uint64(vm.envOr("CCIP_SOURCE_CHAIN_SELECTOR", uint256(0)));
        if (ccipSourceChainSelector != 0) {
            adapter.setSelectorForChainId(sourceChainId, ccipSourceChainSelector);
        }

        if (sourceSender != address(0) && ccipSourceChainSelector != 0) {
            adapter.setAllowedSender(ccipSourceChainSelector, sourceSender, true);
            console.log("Source sender allowed (CCIP selector):", sourceSender);
        }
    }

    function _configureLayerZero(
        CrossChainRegistry registry,
        Executor executor,
        LayerZeroStargateAdapter lzAdapter,
        uint256 sourceChainId,
        address sourceSender
    ) internal {
        bytes32 lzBridgeId = keccak256("LAYERZERO");
        registry.setBridgeAdapter(sourceChainId, lzBridgeId, address(lzAdapter), true);
        executor.setAdapterAuthorization(address(lzAdapter), true);

        uint32 lzSourceEid = uint32(vm.envOr("LZ_SOURCE_EID", uint256(0)));
        if (lzSourceEid != 0 && sourceSender != address(0)) {
            lzAdapter.setPeer(lzSourceEid, bytes32(uint256(uint160(sourceSender))));
            lzAdapter.setChainIdMapping(sourceChainId, lzSourceEid);
            console.log("LayerZero peer set to source sender for srcEid:", lzSourceEid);
        }

        address lzDestinationToken = vm.envOr("LZ_DESTINATION_TOKEN", address(0));
        address lzDestinationStargate = vm.envOr("LZ_DESTINATION_STARGATE", address(0));
        if (lzDestinationToken != address(0) && lzDestinationStargate != address(0)) {
            lzAdapter.setStargateForToken(lzDestinationToken, lzDestinationStargate);
            console.log("LayerZero destination token configured:", lzDestinationToken);
        }
    }
}

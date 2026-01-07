// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {Executor} from "../src/Executor.sol";
import {CrossChainRegistry} from "../src/CrossChainRegistry.sol";
import {CCIPAdapter} from "../src/CCIPAdapter.sol";
import {SimpleFundReceiver} from "../src/SimpleFundReceiver.sol";
import {ICrossChainRegistry} from "../src/interfaces/ICrossChainRegistry.sol";

contract DeployDestination is Script {
    function run() external {
        address ccipRouter = vm.envAddress("CCIP_ROUTER");
        uint64 sourceChainSelector = uint64(vm.envUint("SOURCE_CHAIN_SELECTOR"));
        address sourceSender = vm.envOr("SOURCE_SENDER", address(0));

        vm.startBroadcast();

        CrossChainRegistry registry = new CrossChainRegistry();
        console.log("CrossChainRegistry:", address(registry));

        Executor executor = new Executor(address(registry));
        console.log("Executor:", address(executor));

        CCIPAdapter adapter = new CCIPAdapter(ccipRouter, address(executor));
        console.log("CCIPAdapter:", address(adapter));

        SimpleFundReceiver receiver = new SimpleFundReceiver(address(executor));
        console.log("SimpleFundReceiver:", address(receiver));

        registry.setChainConfig(
            sourceChainSelector,
            ICrossChainRegistry.ChainConfig({
                isSupported: true, isPaused: false, minAmount: 0, maxAmount: type(uint256).max
            })
        );

        bytes32 bridgeId = keccak256("CCIP");
        registry.setBridgeAdapter(sourceChainSelector, bridgeId, address(adapter), true);
        executor.setAdapterAuthorization(address(adapter), true);

        if (sourceSender != address(0)) {
            adapter.setAllowedSender(sourceChainSelector, sourceSender, true);
            console.log("Source sender allowed:", sourceSender);
        }

        vm.stopBroadcast();
    }
}

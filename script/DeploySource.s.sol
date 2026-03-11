// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IntentSender} from "../src/IntentSender.sol";

/**
 * Deploy source-chain IntentSender.
 *
 * Required env:
 * - AGENT: Authorized agent for submitting intents
 * - CCIP_ROUTER: Chainlink CCIP router address
 * - CCIP_DEST_CHAIN_SELECTOR: CCIP chain selector for destination chain
 * - CCIP_DEST_ADAPTER: CCIP adapter address on destination chain
 * - LZ_DEST_EID: LayerZero endpoint ID for destination chain
 * - LZ_DEST_ADAPTER: LayerZero/Stargate adapter address on destination chain
 */
contract DeploySource is Script {
    function run() external {
        address agent = vm.envAddress("AGENT");
        address ccipRouter = vm.envAddress("CCIP_ROUTER");
        uint64 ccipDestSelector = uint64(vm.envUint("CCIP_DEST_CHAIN_SELECTOR"));
        address ccipDestAdapter = vm.envAddress("CCIP_DEST_ADAPTER");
        uint32 lzDestEid = uint32(vm.envUint("LZ_DEST_EID"));
        address lzDestAdapter = vm.envAddress("LZ_DEST_ADAPTER");

        vm.startBroadcast();

        IntentSender sender = new IntentSender(
            agent,
            ccipRouter,
            ccipDestSelector,
            ccipDestAdapter,
            lzDestEid,
            lzDestAdapter
        );
        console.log("IntentSender:", address(sender));

        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {LayerZeroStargateAdapter} from "../src/bridges/LayerZeroStargateAdapter.sol";

/**
 * Configure trusted Stargate senders for the LayerZero adapter.
 *
 * Required env:
 * - ADAPTER: LayerZeroStargateAdapter address
 * - LZ_DESTINATION_TOKEN: Destination token delivered by Stargate
 * - LZ_DESTINATION_STARGATE: Trusted Stargate contract for that token
 */
contract ConfigureLayerZeroAdapter is Script {
    function run() external {
        address adapterAddress = vm.envAddress("ADAPTER");
        address token = vm.envAddress("LZ_DESTINATION_TOKEN");
        address stargate = vm.envAddress("LZ_DESTINATION_STARGATE");

        vm.startBroadcast();

        LayerZeroStargateAdapter(adapterAddress).setStargateForToken(token, stargate);
        console.log("LayerZeroStargateAdapter configured");
        console.log("Token:", token);
        console.log("Stargate:", stargate);

        vm.stopBroadcast();
    }
}

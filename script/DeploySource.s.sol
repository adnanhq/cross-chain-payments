// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {IntentSender} from "../src/IntentSender.sol";

contract DeploySource is Script {
    function run() external {
        address ccipRouter = vm.envAddress("CCIP_ROUTER");

        vm.startBroadcast();

        IntentSender sender = new IntentSender(ccipRouter);
        console.log("IntentSender:", address(sender));

        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {CCIPSender} from "../src/CCIPSender.sol";

contract DeploySource is Script {
    function run() external {
        address ccipRouter = vm.envAddress("CCIP_ROUTER");

        vm.startBroadcast();

        CCIPSender sender = new CCIPSender(ccipRouter);
        console.log("CCIPSender:", address(sender));

        vm.stopBroadcast();
    }
}

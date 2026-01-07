// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {CCIPAdapter} from "../src/CCIPAdapter.sol";

contract ConfigureAdapter is Script {
    function run() external {
        address adapterAddress = vm.envAddress("ADAPTER");
        uint64 sourceChainSelector = uint64(vm.envUint("SOURCE_CHAIN_SELECTOR"));
        address sourceSender = vm.envAddress("SOURCE_SENDER");

        vm.startBroadcast();

        CCIPAdapter adapter = CCIPAdapter(payable(adapterAddress));
        adapter.setAllowedSender(sourceChainSelector, sourceSender, true);

        vm.stopBroadcast();

        console.log("Allowed sender", sourceSender, "from chain", sourceChainSelector);
    }
}

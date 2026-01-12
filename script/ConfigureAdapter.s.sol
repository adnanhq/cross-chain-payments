// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkCCIPAdapter} from "../src/bridges/ChainlinkCCIPAdapter.sol";

contract ConfigureAdapter is Script {
    function run() external {
        address adapterAddress = vm.envAddress("ADAPTER");
        uint256 sourceChainId = vm.envUint("SOURCE_CHAIN_ID");
        uint64 ccipSourceChainSelector = uint64(vm.envUint("CCIP_SOURCE_CHAIN_SELECTOR"));
        address sourceSender = vm.envAddress("SOURCE_SENDER");

        vm.startBroadcast();

        ChainlinkCCIPAdapter adapter = ChainlinkCCIPAdapter(payable(adapterAddress));
        adapter.setSelectorForChainId(sourceChainId, ccipSourceChainSelector);
        adapter.setAllowedSender(ccipSourceChainSelector, sourceSender, true);

        vm.stopBroadcast();

        console.log("Allowed sender", sourceSender, "from CCIP selector", ccipSourceChainSelector);
    }
}

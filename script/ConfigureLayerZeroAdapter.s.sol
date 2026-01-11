// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {LayerZeroStargateAdapter} from "../src/bridges/LayerZeroStargateAdapter.sol";

/**
 * Configure the destination-chain LayerZero adapter after deployments.
 *
 * Required env vars:
 * - ADAPTER: LayerZeroStargateAdapter address (destination chain)
 * - SOURCE_CHAIN_SELECTOR: your protocol source chain selector (uint64, used by Executor/Registry)
 * - LZ_SOURCE_EID: LayerZero srcEid for the source chain (uint32)
 * - SOURCE_SENDER: source chain IntentSender address
 *
 * Token routing (required for compose verification + refunds):
 * - LZ_DESTINATION_TOKEN: destination-chain token address delivered to Executor
 * - LZ_DESTINATION_STARGATE: destination-chain Stargate v2 address for that token
 *
 * Optional (for refunds back to source):
 * - LZ_DST_EID: LayerZero dstEid to use when bridging refunds back to the source chain (uint32)
 *   If not set, defaults to LZ_SOURCE_EID.
 */
contract ConfigureLayerZeroAdapter is Script {
    function run() external {
        address adapterAddress = vm.envAddress("ADAPTER");
        uint64 sourceChainSelector = uint64(vm.envUint("SOURCE_CHAIN_SELECTOR"));
        uint32 srcEid = uint32(vm.envUint("LZ_SOURCE_EID"));
        address sourceSender = vm.envAddress("SOURCE_SENDER");

        address destinationToken = vm.envAddress("LZ_DESTINATION_TOKEN");
        address destinationStargate = vm.envAddress("LZ_DESTINATION_STARGATE");

        uint32 dstEid = uint32(vm.envOr("LZ_DST_EID", uint256(srcEid)));

        vm.startBroadcast();

        LayerZeroStargateAdapter adapter = LayerZeroStargateAdapter(payable(adapterAddress));

        adapter.setPeer(srcEid, bytes32(uint256(uint160(sourceSender))));
        adapter.setSrcEidMapping(srcEid, sourceChainSelector);
        adapter.setChainSelectorMapping(sourceChainSelector, dstEid);
        adapter.setStargateForToken(destinationToken, destinationStargate);

        vm.stopBroadcast();

        console.log("Configured LayerZero adapter:", adapterAddress);
        console.log("srcEid:", srcEid);
        console.log("peer (source sender):", sourceSender);
        console.log("sourceChainSelector:", sourceChainSelector);
        console.log("refund dstEid:", dstEid);
        console.log("destination token:", destinationToken);
        console.log("destination stargate:", destinationStargate);
    }
}



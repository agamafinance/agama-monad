// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AgamaCREReceiver, IDataStreamsOracle} from "../src/cre/AgamaCREReceiver.sol";

/// @notice The receiver of the `agama-monad` CRE workflow, on Monad testnet,
///         wired to the deployed oracle and both Keystone Forwarders.
///
///   forge script script/DeployCREReceiver.s.sol --rpc-url monad_testnet --broadcast --slow \
///     --private-key $DEPLOYER_KEY
contract DeployCREReceiver is Script {
    /// `cre workflow simulate --broadcast` writes through this one.
    address internal constant MOCK_FORWARDER = 0xB9F79d863261869B234c481D1f9A7af84AeAd192;
    /// The DON's, once the workflow is deployed.
    address internal constant KEYSTONE_FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;

    function run() external returns (AgamaCREReceiver receiver) {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        address oracle = vm.parseJsonAddress(vm.readFile(path), ".contracts.oracle");
        address[] memory forwarders = new address[](2);
        forwarders[0] = MOCK_FORWARDER;
        forwarders[1] = KEYSTONE_FORWARDER;

        vm.startBroadcast();
        receiver = new AgamaCREReceiver(IDataStreamsOracle(oracle), msg.sender, forwarders);
        vm.stopBroadcast();

        vm.writeJson(vm.toString(address(receiver)), path, ".contracts.creReceiver");
        console.log("creReceiver", address(receiver));
    }
}

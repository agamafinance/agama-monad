// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AgamaJournal} from "../src/journal/AgamaJournal.sol";

/// @notice The passkey-sealed journal, on Monad testnet. Writes
///         `deployments/<chainId>.added.json` (journal), folded into
///         `deployments/<chainId>.json` (contracts).
///
///   forge script script/DeployJournal.s.sol --rpc-url monad_testnet --broadcast --slow \
///     --private-key $DEPLOYER_KEY
contract DeployJournal is Script {
    function run() external returns (AgamaJournal journal) {
        vm.startBroadcast();
        journal = new AgamaJournal();
        vm.stopBroadcast();

        string memory last = vm.serializeAddress("added", "journal", address(journal));
        string memory added = string.concat("deployments/", vm.toString(block.chainid), ".added.json");
        vm.writeJson(last, added);
        console.log("written", added);
    }
}

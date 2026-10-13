// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {AgamaCREReceiver, IStabilityPoolLiquidate} from "../src/cre/AgamaCREReceiver.sol";
import {AgamaKeeperLens, ILensPool, ILensFactory} from "../src/cre/AgamaKeeperLens.sol";

/// @notice The receiver of the `agama-monad` CRE workflow, on Monad testnet,
///         wired to both oracles (stocks and gold), the stability pool and
///         both Keystone Forwarders, and the lens the workflow reads its jobs
///         from. Writes `deployments/<chainId>.added.json` (creReceiver,
///         creLens), folded into `deployments/<chainId>.json` (contracts).
///
///   forge script script/DeployCREReceiver.s.sol --rpc-url monad_testnet --broadcast --slow \
///     --private-key $DEPLOYER_KEY
contract DeployCREReceiver is Script {
    /// `cre workflow simulate --broadcast` writes through this one.
    address internal constant MOCK_FORWARDER = 0xB9F79d863261869B234c481D1f9A7af84AeAd192;
    /// The DON's, once the workflow is deployed.
    address internal constant KEYSTONE_FORWARDER = 0xF8344CFd5c43616a4366C34E3EEE75af79a74482;

    string[10] internal tickers =
        ["TSLA", "NVDA", "SPY", "AAPL", "QQQ", "GOOGL", "MSFT", "AMZN", "META", "XAUT"];

    function run() external returns (AgamaCREReceiver receiver, AgamaKeeperLens lens) {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address[] memory oracles = new address[](2);
        oracles[0] = vm.parseJsonAddress(json, ".contracts.oracle");
        oracles[1] = vm.parseJsonAddress(json, ".contracts.goldOracle");
        address sp = vm.parseJsonAddress(json, ".contracts.stabilityPool");
        address[] memory stocks = new address[](tickers.length);
        address[] memory retired = new address[](tickers.length);
        for (uint256 i; i < tickers.length; ++i) {
            stocks[i] = vm.parseJsonAddress(json, string.concat(".adapters.", tickers[i]));
            retired[i] = vm.parseJsonAddress(json, string.concat(".adaptersRetired.", tickers[i]));
        }
        address[] memory forwarders = new address[](2);
        forwarders[0] = MOCK_FORWARDER;
        forwarders[1] = KEYSTONE_FORWARDER;

        vm.startBroadcast();
        receiver = new AgamaCREReceiver(IStabilityPoolLiquidate(sp), msg.sender, forwarders, oracles);
        lens = new AgamaKeeperLens(
            ILensPool(vm.parseJsonAddress(json, ".contracts.pool")),
            ILensFactory(vm.parseJsonAddress(json, ".contracts.factory")),
            vm.parseJsonAddress(json, ".adapters.VAULT"),
            vm.parseJsonAddress(json, ".kuru.venue"),
            stocks,
            retired
        );
        vm.stopBroadcast();

        string memory out = "added";
        vm.serializeAddress(out, "creReceiver", address(receiver));
        string memory last = vm.serializeAddress(out, "creLens", address(lens));
        string memory added = string.concat("deployments/", vm.toString(block.chainid), ".added.json");
        vm.writeJson(last, added);
        console.log("written", added);
    }
}

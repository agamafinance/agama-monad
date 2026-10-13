// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ArrowLendingPool} from "../src/arrow/ArrowLendingPool.sol";
import {ArrowStabilityPool} from "../src/arrow/ArrowStabilityPool.sol";
import {ArrowXStockAdapter} from "../src/arrow/adapters/ArrowXStockAdapter.sol";
import {StockOracle} from "../src/arrow/oracle/StockOracle.sol";
import {IVerifierProxy} from "../src/arrow/oracle/DataStreamsStockOracle.sol";
import {DataStreamsGoldOracle} from "../src/arrow/oracle/DataStreamsGoldOracle.sol";
import {KuruVenue, IKuruOrderBook} from "../src/venues/KuruVenue.sol";
import {KuruListing} from "../src/venues/KuruListing.sol";
import {TestXStock, TestXStockWrapper} from "../src/mocks/TestnetTokens.sol";

/// @notice Tether Gold on the live deployment: a test XAUt0 and its wrapper,
///         its own oracle reading Chainlink's XAU/USD stream (schema v3),
///         an Arrow market at 60% LTV, a Kuru book. Writes the new addresses
///         to `deployments/<chainId>.added.json`, folded into
///         `deployments/<chainId>.json` (contracts, tokens, adapters, kuru).
///
///   forge script script/AddGold.s.sol --rpc-url monad_testnet --broadcast --slow \
///     --private-key $DEPLOYER_KEY
contract AddGold is Script {
    bytes32 internal constant XAU_USD = 0x0003036191b204b5ba40ae93b6004917000f66d8527b64bad7f6b1d346ccdce9;
    bytes32 internal constant TICKER = "XAUT";

    function run() external {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address usdc = vm.parseJsonAddress(json, ".tokens.USDC");
        ArrowLendingPool pool = ArrowLendingPool(vm.parseJsonAddress(json, ".contracts.pool"));
        ArrowStabilityPool sp = ArrowStabilityPool(vm.parseJsonAddress(json, ".contracts.stabilityPool"));
        KuruVenue venue = KuruVenue(vm.parseJsonAddress(json, ".kuru.venue"));
        IVerifierProxy verifier = IVerifierProxy(vm.parseJsonAddress(json, ".contracts.verifierProxy"));

        vm.startBroadcast();
        DataStreamsGoldOracle oracle = new DataStreamsGoldOracle(msg.sender, msg.sender, verifier);
        oracle.addFeed(TICKER);
        oracle.setStream(XAU_USD, TICKER);

        TestXStock base = new TestXStock("Test Tether Gold", "XAUt0");
        TestXStockWrapper w = new TestXStockWrapper(base, "Wrapped Test Tether Gold", "wXAUt0");

        // Gold trades around the clock: one set of terms, no closed-market buffer.
        ArrowXStockAdapter a = new ArrowXStockAdapter(
            address(pool),
            IERC4626(address(w)),
            TICKER,
            StockOracle(address(oracle)),
            6,
            msg.sender,
            6_000,
            7_000,
            500,
            0
        );
        pool.registerAdapter(address(a), true);
        sp.addAdapter(address(a));

        address market = KuruListing.list(address(base), usdc);
        venue.setMarket(address(w), IKuruOrderBook(market));
        vm.stopBroadcast();

        string memory out = "added";
        vm.serializeAddress(out, "goldOracle", address(oracle));
        vm.serializeAddress(out, "wXAUt0", address(w));
        vm.serializeAddress(out, "adapter_XAUT", address(a));
        string memory last = vm.serializeAddress(out, "kuru_XAUT", market);
        string memory added = string.concat("deployments/", vm.toString(block.chainid), ".added.json");
        vm.writeJson(last, added);
        console.log("written", added);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AgamaZapRouter} from "../src/agama/AgamaZapRouter.sol";
import {KuruVenue, IKuruOrderBook} from "../src/venues/KuruVenue.sol";
import {KuruListing} from "../src/venues/KuruListing.sol";

/// @notice Lists the four test xStocks on Kuru against our USDC and routes the
///         stack's swaps through the books. Runs after DeployTestnet, reads and
///         extends `deployments/<chainId>.json` (adds `.kuru`).
///
///   forge script script/KuruMarkets.s.sol --rpc-url monad_testnet --broadcast --slow \
///     --private-key $DEPLOYER_KEY
///
/// The books start empty: `scripts/kuru_mm.py` places the first quotes around
/// the oracle price and keeps them there.
contract KuruMarkets is Script {
    string[4] internal TICKERS = ["TSLA", "NVDA", "SPY", "AAPL"];

    function run() external {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address usdc = vm.parseJsonAddress(json, ".tokens.USDC");
        AgamaZapRouter zap = AgamaZapRouter(vm.parseJsonAddress(json, ".contracts.zapRouter"));

        vm.startBroadcast();
        KuruVenue venue = new KuruVenue(IERC20(usdc), msg.sender);
        address[4] memory markets;
        for (uint256 i; i < 4; ++i) {
            address wrapper = vm.parseJsonAddress(json, string.concat(".tokens.w", TICKERS[i], "x"));
            markets[i] = KuruListing.list(IERC4626(wrapper).asset(), usdc);
            venue.setMarket(wrapper, IKuruOrderBook(markets[i]));
        }
        zap.setTarget(address(venue), true);
        zap.setSpender(address(venue), true);
        vm.stopBroadcast();

        string memory k = "kuru";
        vm.serializeAddress(k, "venue", address(venue));
        vm.serializeAddress(k, "router", KuruListing.ROUTER);
        vm.serializeAddress(k, "marginAccount", KuruListing.MARGIN_ACCOUNT);
        vm.serializeAddress(k, "TSLA", markets[0]);
        vm.serializeAddress(k, "NVDA", markets[1]);
        vm.serializeAddress(k, "SPY", markets[2]);
        string memory kuru = vm.serializeAddress(k, "AAPL", markets[3]);
        vm.writeJson(kuru, path, ".kuru");
        console.log("venue", address(venue));
        console.log("written", path);
    }
}

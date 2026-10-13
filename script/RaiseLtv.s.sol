// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ArrowLendingPool} from "../src/arrow/ArrowLendingPool.sol";
import {ArrowStabilityPool} from "../src/arrow/ArrowStabilityPool.sol";
import {ArrowXStockAdapter} from "../src/arrow/adapters/ArrowXStockAdapter.sol";
import {StockOracle} from "../src/arrow/oracle/StockOracle.sol";

/// @notice New Arrow markets for the ten assets, at higher terms: an adapter's
///         risk parameters are immutable, so raising them is a new adapter on
///         the same pool, wrapper, oracle and Kuru book. The old adapters stay
///         registered, so a position opened on them can still be closed.
///         Writes `deployments/<chainId>.added.json` (adapter_<TICKER>),
///         folded into `deployments/<chainId>.json` (adapters).
///
///   forge script script/RaiseLtv.s.sol --rpc-url monad_testnet --broadcast --slow \
///     --private-key $DEPLOYER_KEY
contract RaiseLtv is Script {
    struct Terms {
        string ticker;
        string wrapper;
        uint256 ltv;
        uint256 lt;
        uint256 bonus;
        uint256 closedBuffer; // off by this much while the market is shut
    }

    function _terms() internal pure returns (Terms[10] memory) {
        return [
            // Index funds, then the large caps, then the names that move most.
            Terms("SPY", "wSPYx", 7_000, 8_000, 500, 500),
            Terms("QQQ", "wQQQx", 7_000, 8_000, 500, 500),
            Terms("AAPL", "wAAPLx", 6_500, 7_500, 600, 800),
            Terms("MSFT", "wMSFTx", 6_500, 7_500, 600, 800),
            Terms("GOOGL", "wGOOGLx", 6_500, 7_500, 600, 800),
            Terms("AMZN", "wAMZNx", 6_500, 7_500, 600, 800),
            Terms("TSLA", "wTSLAx", 6_000, 7_000, 800, 800),
            Terms("NVDA", "wNVDAx", 6_000, 7_000, 800, 800),
            Terms("META", "wMETAx", 6_000, 7_000, 800, 800),
            // Gold trades around the clock.
            Terms("XAUT", "wXAUt0", 7_000, 8_000, 500, 0)
        ];
    }

    function run() external {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        ArrowLendingPool pool = ArrowLendingPool(vm.parseJsonAddress(json, ".contracts.pool"));
        ArrowStabilityPool sp = ArrowStabilityPool(vm.parseJsonAddress(json, ".contracts.stabilityPool"));
        address stockOracle = vm.parseJsonAddress(json, ".contracts.oracle");
        address goldOracle = vm.parseJsonAddress(json, ".contracts.goldOracle");

        Terms[10] memory t = _terms();
        string memory out = "added";
        string memory last;
        vm.startBroadcast();
        for (uint256 i; i < t.length; ++i) {
            bool gold = keccak256(bytes(t[i].ticker)) == keccak256("XAUT");
            ArrowXStockAdapter a = new ArrowXStockAdapter(
                address(pool),
                IERC4626(vm.parseJsonAddress(json, string.concat(".tokens.", t[i].wrapper))),
                bytes32(bytes(t[i].ticker)),
                StockOracle(gold ? goldOracle : stockOracle),
                6,
                msg.sender,
                t[i].ltv,
                t[i].lt,
                t[i].bonus,
                t[i].closedBuffer
            );
            pool.registerAdapter(address(a), true);
            sp.addAdapter(address(a));
            last = vm.serializeAddress(out, string.concat("adapter_", t[i].ticker), address(a));
        }
        vm.stopBroadcast();

        string memory added = string.concat("deployments/", vm.toString(block.chainid), ".added.json");
        vm.writeJson(last, added);
        console.log("written", added);
    }
}

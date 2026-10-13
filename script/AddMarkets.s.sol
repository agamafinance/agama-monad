// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ArrowLendingPool} from "../src/arrow/ArrowLendingPool.sol";
import {ArrowStabilityPool} from "../src/arrow/ArrowStabilityPool.sol";
import {ArrowXStockAdapter} from "../src/arrow/adapters/ArrowXStockAdapter.sol";
import {StockOracle} from "../src/arrow/oracle/StockOracle.sol";
import {DataStreamsStockOracle} from "../src/arrow/oracle/DataStreamsStockOracle.sol";
import {KuruVenue, IKuruOrderBook} from "../src/venues/KuruVenue.sol";
import {KuruListing} from "../src/venues/KuruListing.sol";
import {TestXStock, TestXStockWrapper} from "../src/mocks/TestnetTokens.sol";

/// @notice Five more xStocks on the live deployment, the way the first four
///         were made: a test stock and its wrapper, three Chainlink Data
///         Streams per ticker on the oracle, an Arrow market, a Kuru book.
///         Writes the new addresses to `deployments/<chainId>.added.json`,
///         folded into `deployments/<chainId>.json` (tokens, adapters, kuru).
///
///   forge script script/AddMarkets.s.sol --rpc-url monad_testnet --broadcast --slow \
///     --private-key $DEPLOYER_KEY
contract AddMarkets is Script {
    uint32 internal constant SESSION_REGULAR = (1 << 2) | (1 << 5);
    uint32 internal constant SESSION_EXTENDED = (1 << 1) | (1 << 3);
    uint32 internal constant SESSION_OVERNIGHT = 1 << 4;

    struct Stock {
        string ticker;
        string name;
        bytes32 regular;
        bytes32 extended;
        bytes32 overnight;
        uint256 ltv;
        uint256 lt;
        uint256 bonus;
        uint256 weekendBuffer;
    }

    function _stocks() internal pure returns (Stock[5] memory) {
        return [
            // An index fund carries the terms of SPY, single names those of AAPL, Meta those of Tesla.
            Stock(
                "QQQ",
                "Nasdaq 100",
                0x000bebb97e1da3eb1a71ac362a99255f944224355ef09067cd54f2fe2d0075f6,
                0x000b084fdb7383d198d9a793f5bda0d526a479722c3dd60166e0ebde078962d8,
                0x000bb5ccf08dd3ad9e9a0f3c1794acbd0d1039601630c75fe3a0d19bdbe0bacb,
                5_000,
                6_000,
                600,
                500
            ),
            Stock(
                "GOOGL",
                "Alphabet",
                0x000b62925feea3a68e02358e2cdd0edade49ba782cd7ba605bd834cdfd5e04af,
                0x000b38cecfeca43e3b5cce05b2e25abebad62de192727e5d6fae47846ff90e0a,
                0x000b27e8a01b15d1151b1dec1f33702d3d4966414b9b750bbb261f75a2c29bb4,
                3_500,
                4_500,
                800,
                800
            ),
            Stock(
                "MSFT",
                "Microsoft",
                0x000b032fac53b731d7e9e8b0767151984f97ef151900a78be2fcc9713455ffc5,
                0x000b48add0681d9ca52424c1eccda5bcbf038eb85db3e67fe9b2931f1c2fd97a,
                0x000bd230c2a3f549aad1288360bcd329e8b5591ae205b31595d009bb122dcf8e,
                3_500,
                4_500,
                800,
                800
            ),
            Stock(
                "AMZN",
                "Amazon",
                0x000babb1ff3f6920ebb15da8439f03f3b8669cc3f4c6b69594289e2e6af485ef,
                0x000b3a32200a6ca3e3c55a7de7ba690c86a071c58167f34778ab0cbf1d37fdc6,
                0x000b042e894fb4404a2384854e4d678a85f943f2b83b25b2d837a426218dfcb3,
                3_500,
                4_500,
                800,
                800
            ),
            Stock(
                "META",
                "Meta",
                0x000b7a8a64a03bee8c58f32e24bef3cad363bd33cf5384f485d301f0c8cf2fc0,
                0x000bb3991a740a35cafa5cdb2f9bd9372d575ec137a99543e943caa4a6b9c4bc,
                0x000b2ef7c9d5369d8494a1000933a6815fd79dead95acb8ae07ce4f10127f926,
                3_000,
                4_000,
                1_000,
                800
            )
        ];
    }

    function run() external {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address usdc = vm.parseJsonAddress(json, ".tokens.USDC");
        DataStreamsStockOracle oracle = DataStreamsStockOracle(vm.parseJsonAddress(json, ".contracts.oracle"));
        ArrowLendingPool pool = ArrowLendingPool(vm.parseJsonAddress(json, ".contracts.pool"));
        ArrowStabilityPool sp = ArrowStabilityPool(vm.parseJsonAddress(json, ".contracts.stabilityPool"));
        KuruVenue venue = KuruVenue(vm.parseJsonAddress(json, ".kuru.venue"));

        Stock[5] memory s = _stocks();
        string memory out = "added";
        string memory last;
        vm.startBroadcast();
        for (uint256 i; i < s.length; ++i) {
            bytes32 ticker = bytes32(bytes(s[i].ticker));
            TestXStock base =
                new TestXStock(string.concat("Test ", s[i].name, " xStock"), string.concat(s[i].ticker, "x"));
            TestXStockWrapper w = new TestXStockWrapper(
                base,
                string.concat("Wrapped Test ", s[i].name, " xStock"),
                string.concat("w", s[i].ticker, "x")
            );

            oracle.addFeed(ticker);
            oracle.setStream(s[i].regular, ticker, 18, true, SESSION_REGULAR);
            oracle.setStream(s[i].extended, ticker, 18, true, SESSION_EXTENDED);
            oracle.setStream(s[i].overnight, ticker, 18, true, SESSION_OVERNIGHT);

            ArrowXStockAdapter a = new ArrowXStockAdapter(
                address(pool),
                IERC4626(address(w)),
                ticker,
                StockOracle(address(oracle)),
                6,
                msg.sender,
                s[i].ltv,
                s[i].lt,
                s[i].bonus,
                s[i].weekendBuffer
            );
            pool.registerAdapter(address(a), true);
            sp.addAdapter(address(a));

            address market = KuruListing.list(address(base), usdc);
            venue.setMarket(address(w), IKuruOrderBook(market));

            vm.serializeAddress(out, string.concat("w", s[i].ticker, "x"), address(w));
            vm.serializeAddress(out, string.concat("adapter_", s[i].ticker), address(a));
            last = vm.serializeAddress(out, string.concat("kuru_", s[i].ticker), market);
        }
        vm.stopBroadcast();

        string memory added = string.concat("deployments/", vm.toString(block.chainid), ".added.json");
        vm.writeJson(last, added);
        console.log("written", added);
    }
}

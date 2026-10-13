// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DataStreamsGoldOracle} from "../src/arrow/oracle/DataStreamsGoldOracle.sol";
import {IVerifierProxy} from "../src/arrow/oracle/DataStreamsStockOracle.sol";

/// @notice A real signed XAU/USD report (schema v3, test/fixtures/reports.json)
///         through Chainlink's own VerifierProxy on a fork of Monad testnet.
///         Needs the network: MONAD_FORK=1.
contract GoldOracleForkTest is Test {
    IVerifierProxy constant VERIFIER = IVerifierProxy(0x72790f9eB82db492a7DDb6d2af22A270Dcc3Db64);
    bytes32 constant XAUT = "XAUT";

    DataStreamsGoldOracle oracle;
    string fixtures;

    function setUp() public {
        if (!vm.envOr("MONAD_FORK", false)) vm.skip(true);
        vm.createSelectFork("monad_testnet");
        fixtures = vm.readFile("test/fixtures/reports.json");
        oracle = new DataStreamsGoldOracle(address(this), address(this), VERIFIER);
        oracle.addFeed(XAUT);
        oracle.setStream(vm.parseJsonBytes32(fixtures, ".xau.feed"), XAUT);
        vm.warp(vm.parseJsonUint(fixtures, ".xau.observedAt") + 10);
    }

    function _report(string memory name) internal view returns (bytes memory) {
        return vm.parseJsonBytes(fixtures, string.concat(".", name, ".report"));
    }

    function test_genuineGoldReportIsVerifiedAndStored() public {
        vm.prank(makeAddr("anyone"));
        oracle.pushReport(_report("xau"));
        (uint256 price, uint256 observedAt, bool open) = oracle.getPrice(XAUT);
        assertEq(price, vm.parseUint(vm.parseJsonString(fixtures, ".xau.mid")));
        assertGt(price, 1_000e18);
        assertEq(observedAt, vm.parseJsonUint(fixtures, ".xau.observedAt"));
        assertTrue(open);
    }

    function test_tamperedGoldReportIsRejectedByChainlink() public {
        bytes memory r = _report("xau");
        r[r.length - 100] ^= 0x01; // one bit of a signature
        vm.expectRevert(bytes4(keccak256("BadVerification()")));
        oracle.pushReport(r);
    }

    function test_goldReportOlderThanFiveMinutesRefused() public {
        vm.warp(vm.getBlockTimestamp() + 300);
        vm.expectRevert(abi.encodeWithSelector(DataStreamsGoldOracle.ReportTooOld.selector, 310));
        oracle.pushReport(_report("xau"));
    }

    function test_sameGoldReportTwiceRefused() public {
        oracle.pushReport(_report("xau"));
        vm.expectRevert();
        oracle.pushReport(_report("xau"));
    }

    function test_stockReportRefusedByTheGoldOracle() public {
        vm.expectRevert(
            abi.encodeWithSelector(DataStreamsGoldOracle.UnsupportedSchema.selector, uint16(0x000b))
        );
        oracle.pushReport(_report("tsla_regular"));
    }

    function test_unknownStreamRefused() public {
        oracle.setStream(vm.parseJsonBytes32(fixtures, ".xau.feed"), bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                DataStreamsGoldOracle.UnknownStream.selector, vm.parseJsonBytes32(fixtures, ".xau.feed")
            )
        );
        oracle.pushReport(_report("xau"));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DataStreamsStockOracle, IVerifierProxy} from "../src/arrow/oracle/DataStreamsStockOracle.sol";

/// @notice Real signed Chainlink reports (test/fixtures/reports.json, fetched
///         from the testnet Data Engine) through Chainlink's own VerifierProxy
///         on a fork of Monad testnet. Needs the network: MONAD_FORK=1.
contract DataStreamsForkTest is Test {
    IVerifierProxy constant VERIFIER = IVerifierProxy(0x72790f9eB82db492a7DDb6d2af22A270Dcc3Db64);
    uint32 constant REGULAR = (1 << 2) | (1 << 5);
    uint32 constant OVERNIGHT = 1 << 4;

    DataStreamsStockOracle oracle;
    string fixtures;

    function setUp() public {
        if (!vm.envOr("MONAD_FORK", false)) vm.skip(true);
        vm.createSelectFork("monad_testnet");
        fixtures = vm.readFile("test/fixtures/reports.json");
        oracle = new DataStreamsStockOracle(address(this), address(this), VERIFIER);
        oracle.addFeed("TSLA");
        oracle.setStream(_feed("tsla_regular"), "TSLA", 18, true, REGULAR);
        oracle.setStream(_feed("tsla_overnight"), "TSLA", 18, true, OVERNIGHT);
        vm.warp(vm.parseJsonUint(fixtures, ".tsla_regular.observedAt") + 10);
    }

    function _feed(string memory name) internal view returns (bytes32) {
        return vm.parseJsonBytes32(fixtures, string.concat(".", name, ".feed"));
    }

    function _report(string memory name) internal view returns (bytes memory) {
        return vm.parseJsonBytes(fixtures, string.concat(".", name, ".report"));
    }

    function test_genuineReportIsVerifiedAndStored() public {
        vm.prank(makeAddr("anyone"));
        oracle.pushReport(_report("tsla_regular"));
        (uint256 price,, bool open) = oracle.getPrice("TSLA");
        assertGt(price, 100e18);
        assertTrue(open);
    }

    function test_tamperedReportIsRejectedByChainlink() public {
        bytes memory r = _report("tsla_regular");
        r[r.length - 100] ^= 0x01; // one bit of a signature
        vm.expectRevert(bytes4(keccak256("BadVerification()"))); // Chainlink's own verifier
        oracle.pushReport(r);
        (uint256 price,,) = _feedOf();
        assertEq(price, 0);
    }

    /// Chainlink's overnight stream still publishes during the regular
    /// session, at a different price: the oracle refuses it there.
    function test_overnightStreamRefusedInRegularSession() public {
        bytes32 feed = _feed("tsla_overnight");
        vm.expectRevert(abi.encodeWithSelector(DataStreamsStockOracle.WrongSession.selector, feed, 2));
        oracle.pushReport(_report("tsla_overnight"));
    }

    function test_reportOlderThanFiveMinutesRefused() public {
        vm.warp(vm.getBlockTimestamp() + 300);
        vm.expectRevert(abi.encodeWithSelector(DataStreamsStockOracle.ReportTooOld.selector, 310));
        oracle.pushReport(_report("tsla_regular"));
    }

    function _feedOf() internal view returns (uint256 price, uint64 observedAt, bool open) {
        DataStreamsStockOracle.Feed memory f = oracle.feed("TSLA");
        return (f.price, f.observedAt, f.marketOpen);
    }
}

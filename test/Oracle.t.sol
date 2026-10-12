// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StockOracle, IAggregatorV3} from "../src/arrow/oracle/StockOracle.sol";
import {DataStreamsStockOracle, IVerifierProxy} from "../src/arrow/oracle/DataStreamsStockOracle.sol";

/// @dev Stands in for the Monad VerifierProxy: returns the report body,
///      exactly what the real proxy returns after checking signatures.
contract MockVerifierProxy is IVerifierProxy {
    bool public reject;

    function setReject(bool r) external {
        reject = r;
    }

    function verify(bytes calldata payload, bytes calldata) external payable returns (bytes memory) {
        require(!reject, "bad signature");
        (, bytes memory reportData) = abi.decode(payload, (bytes32[3], bytes));
        return reportData;
    }
}

contract MockSequencer is IAggregatorV3 {
    int256 public answer;
    uint256 public startedAt;

    function set(int256 a, uint256 s) external {
        answer = a;
        startedAt = s;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, answer, startedAt, startedAt, 0);
    }
}

contract OracleTest is Test {
    DataStreamsStockOracle oracle;
    MockVerifierProxy verifier;
    address keeper = makeAddr("keeper");
    uint32 constant ALL_SESSIONS = 0x3E;
    bytes32 constant FEED = 0x000b2dbed1640ead18d37338b75e4755630a900649261baf4ed79d9a749be13d;

    function setUp() public {
        vm.warp(1_790_000_000);
        verifier = new MockVerifierProxy();
        oracle = new DataStreamsStockOracle(address(this), keeper, verifier);
        oracle.addFeed("TSLA");
        oracle.setStream(FEED, "TSLA", 18, true, ALL_SESSIONS);
    }

    function _report(int192 mid, uint32 obsTs, uint32 expiresAt, uint32 status)
        internal
        pure
        returns (bytes memory)
    {
        DataStreamsStockOracle.ReportV11 memory r = DataStreamsStockOracle.ReportV11({
            feedId: FEED,
            validFromTimestamp: obsTs,
            observationsTimestamp: obsTs,
            nativeFee: 0,
            linkFee: 0,
            expiresAt: expiresAt,
            mid: mid,
            lastSeenTimestampNs: uint64(obsTs) * 1e9,
            bid: mid - 1e16,
            bidVolume: 100e18,
            ask: mid + 1e16,
            askVolume: 100e18,
            lastTradedPrice: mid,
            marketStatus: status
        });
        bytes32[3] memory ctx;
        return abi.encode(ctx, abi.encode(r));
    }

    // ---- Data Streams path --------------------------------------------------------

    function test_pushReport_storesPriceAndStatus_permissionless() public {
        uint32 t = uint32(vm.getBlockTimestamp());
        vm.prank(makeAddr("anyone"));
        oracle.pushReport(_report(377.79e18, t, t + 60, 2));
        (uint256 p,, bool open) = oracle.getPrice("TSLA");
        assertEq(p, 377.79e18);
        assertTrue(open);
    }

    function test_pushReport_closedStatusFreezes() public {
        uint32 t = uint32(vm.getBlockTimestamp());
        oracle.pushReport(_report(377.79e18, t, t + 60, 5));
        assertFalse(oracle.isMarketOpen("TSLA"));
    }

    function test_pushReport_overnightCountsAsOpen_24_5() public {
        uint32 t = uint32(vm.getBlockTimestamp());
        oracle.pushReport(_report(377.79e18, t, t + 60, 4));
        assertTrue(oracle.isMarketOpen("TSLA"));
    }

    function test_pushReport_rejectsExpired() public {
        uint32 t = uint32(vm.getBlockTimestamp());
        vm.expectRevert(DataStreamsStockOracle.ReportExpired.selector);
        oracle.pushReport(_report(377e18, t - 10, t - 1, 2));
    }

    function test_pushReport_rejectsOlderThanFiveMinutes() public {
        uint32 t = uint32(vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(DataStreamsStockOracle.ReportTooOld.selector, 301));
        oracle.pushReport(_report(377e18, t - 301, t + 60, 2));
    }

    /// The regular-hours stream is only believed for the regular session and
    /// the close: replayed during the overnight session, it is refused.
    function test_pushReport_streamOnlyBelievedForItsSession() public {
        oracle.setStream(FEED, "TSLA", 18, true, (1 << 2) | (1 << 5));
        uint32 t = uint32(vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(DataStreamsStockOracle.WrongSession.selector, FEED, 4));
        oracle.pushReport(_report(377e18, t, t + 60, 4));
        oracle.pushReport(_report(377e18, t, t + 60, 5));
        assertFalse(oracle.isMarketOpen("TSLA"));
    }

    function test_pushReport_rejectsReplayOfOlderReport() public {
        uint32 t = uint32(vm.getBlockTimestamp());
        oracle.pushReport(_report(377e18, t, t + 60, 2));
        vm.expectRevert(StockOracle.ObservationNotNewer.selector);
        oracle.pushReport(_report(300e18, t - 5, t + 60, 2));
    }

    function test_pushReport_rejectsBadSignature() public {
        verifier.setReject(true);
        uint32 t = uint32(vm.getBlockTimestamp());
        vm.expectRevert("bad signature");
        oracle.pushReport(_report(377e18, t, t + 60, 2));
    }

    function test_pushReport_acceptsRealGap_noDeviationCap() public {
        uint32 t = uint32(vm.getBlockTimestamp());
        oracle.pushReport(_report(400e18, t, t + 60, 2));
        vm.warp(vm.getBlockTimestamp() + 10);
        oracle.pushReport(_report(240e18, t + 10, t + 70, 2)); // -40%
        (uint256 p,,) = oracle.getPrice("TSLA");
        assertEq(p, 240e18);
    }

    function test_pushReport_unknownStream() public {
        oracle.setStream(FEED, "TSLA", 18, false, ALL_SESSIONS);
        uint32 t = uint32(vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(DataStreamsStockOracle.UnknownStream.selector, FEED));
        oracle.pushReport(_report(377e18, t, t + 60, 2));
    }

    function test_pushReport_scalesEightDecimalStreams() public {
        oracle.setStream(FEED, "TSLA", 8, true, ALL_SESSIONS);
        uint32 t = uint32(vm.getBlockTimestamp());
        oracle.pushReport(_report(37_779_000_000, t, t + 60, 2));
        (uint256 p,,) = oracle.getPrice("TSLA");
        assertEq(p, 377.79e18);
    }

    // ---- Keeper path --------------------------------------------------------------

    function test_keeper_deviationCapInSession() public {
        vm.startPrank(keeper);
        oracle.push("TSLA", 400e18, uint64(vm.getBlockTimestamp()), true);
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.expectRevert(abi.encodeWithSelector(StockOracle.DeviationTooLarge.selector, 2_000, 1_500));
        oracle.push("TSLA", 320e18, uint64(vm.getBlockTimestamp()), true);
        vm.stopPrank();
    }

    function test_keeper_widerGapAllowedOnReopen() public {
        vm.startPrank(keeper);
        oracle.push("TSLA", 400e18, uint64(vm.getBlockTimestamp()), false); // Friday close
        vm.warp(vm.getBlockTimestamp() + 2 days);
        oracle.push("TSLA", 300e18, uint64(vm.getBlockTimestamp()), true); // -25% Monday gap
        vm.stopPrank();
        (uint256 p,,) = oracle.getPrice("TSLA");
        assertEq(p, 300e18);
    }

    function test_forcePush_governorOnly() public {
        vm.prank(keeper);
        oracle.push("TSLA", 400e18, uint64(vm.getBlockTimestamp()), true);
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.prank(keeper);
        vm.expectRevert();
        oracle.forcePush("TSLA", 40e18, uint64(vm.getBlockTimestamp()), true);
        oracle.forcePush("TSLA", 40e18, uint64(vm.getBlockTimestamp()), true); // e.g. 10:1 split
    }

    function test_nonKeeperCannotPush() public {
        vm.prank(makeAddr("mallory"));
        vm.expectRevert();
        oracle.push("TSLA", 1e18, uint64(vm.getBlockTimestamp()), true);
    }

    function test_staleness_openVsClosed() public {
        vm.prank(keeper);
        oracle.push("TSLA", 400e18, uint64(vm.getBlockTimestamp()), true);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.expectRevert();
        oracle.getPrice("TSLA");

        vm.prank(keeper);
        oracle.push("TSLA", 400e18, uint64(vm.getBlockTimestamp()), false);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        oracle.getPrice("TSLA"); // frozen weekend price still valid
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        vm.expectRevert();
        oracle.getPrice("TSLA");
    }

    function test_futureObservationRejected() public {
        vm.prank(keeper);
        vm.expectRevert(StockOracle.ObservationInFuture.selector);
        oracle.push("TSLA", 400e18, uint64(vm.getBlockTimestamp() + 1), true);
    }

    /// The feed stores a uint128 and a Solidity downcast truncates in silence.
    /// The deviation cap would catch an absurd value from the keeper, but the
    /// signed path skips that cap, so the bound has to be its own check.
    function test_priceAboveUint128Rejected() public {
        vm.prank(keeper);
        vm.expectPartialRevert(StockOracle.PriceOutOfRange.selector);
        oracle.push("TSLA", uint256(type(uint128).max) + 1, uint64(vm.getBlockTimestamp()), true);
    }

    // ---- L2 sequencer -------------------------------------------------------------

    function test_sequencerDown_blocksReads() public {
        MockSequencer seq = new MockSequencer();
        oracle.setSequencerUptimeFeed(address(seq));
        vm.prank(keeper);
        oracle.push("TSLA", 400e18, uint64(vm.getBlockTimestamp()), true);

        seq.set(1, vm.getBlockTimestamp() - 10 hours);
        vm.expectRevert(StockOracle.SequencerDown.selector);
        oracle.getPrice("TSLA");

        seq.set(0, vm.getBlockTimestamp() - 10 minutes); // just came back
        vm.expectRevert(StockOracle.SequencerGracePeriod.selector);
        oracle.getPrice("TSLA");

        seq.set(0, vm.getBlockTimestamp() - 2 hours);
        oracle.getPrice("TSLA");
    }
}

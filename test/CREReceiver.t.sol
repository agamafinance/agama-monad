// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {DataStreamsStockOracle} from "../src/arrow/oracle/DataStreamsStockOracle.sol";
import {AgamaAccount} from "../src/agama/AgamaAccount.sol";
import {AgamaEarnRouter} from "../src/agama/AgamaEarnRouter.sol";
import {AgamaCREReceiver, IStabilityPoolLiquidate, IReceiver} from "../src/cre/AgamaCREReceiver.sol";
import {MockDexRouter} from "./Zap.t.sol";
import {AgamaKeeperLens, ILensPool, ILensFactory} from "../src/cre/AgamaKeeperLens.sol";

/// @notice The CRE workflow's landing point: one DON report carries Data
///         Streams reports for the oracles and the agents' jobs.
contract CREReceiverTest is BaseTest {
    AgamaCREReceiver receiver;
    address forwarder = makeAddr("forwarder");
    address workflowOwner = makeAddr("workflowOwner");

    function setUp() public override {
        super.setUp();
        address[] memory fwd = new address[](1);
        fwd[0] = forwarder;
        address[] memory oracles = new address[](1);
        oracles[0] = address(d.oracle);
        receiver = new AgamaCREReceiver(IStabilityPoolLiquidate(address(d.sp)), address(this), fwd, oracles);
    }

    function _streamReport(bytes32 feed, int192 mid, uint32 t, uint32 status)
        internal
        pure
        returns (bytes memory)
    {
        DataStreamsStockOracle.ReportV11 memory r = DataStreamsStockOracle.ReportV11({
            feedId: feed,
            validFromTimestamp: t,
            observationsTimestamp: t,
            nativeFee: 0,
            linkFee: 0,
            expiresAt: t + 300,
            mid: mid,
            lastSeenTimestampNs: uint64(t) * 1e9,
            bid: mid,
            bidVolume: 0,
            ask: mid,
            askVolume: 0,
            lastTradedPrice: mid,
            marketStatus: status
        });
        bytes32[3] memory ctx;
        return abi.encode(ctx, abi.encode(r));
    }

    function _metadata(address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(1)), bytes10("agama"), owner);
    }

    function _prices(bytes[] memory reports) internal view returns (AgamaCREReceiver.Prices[] memory p) {
        p = new AgamaCREReceiver.Prices[](1);
        p[0] = AgamaCREReceiver.Prices(address(d.oracle), reports);
    }

    function _job(AgamaCREReceiver.Kind kind, address account, address adapter)
        internal
        pure
        returns (AgamaCREReceiver.Job memory)
    {
        return AgamaCREReceiver.Job(kind, account, adapter, "");
    }

    function _deliver(AgamaCREReceiver.Prices[] memory prices, AgamaCREReceiver.Job[] memory jobs) internal {
        vm.prank(forwarder);
        receiver.onReport(_metadata(workflowOwner), abi.encode(prices, jobs));
    }

    function _empty() internal pure returns (bytes memory) {
        return abi.encode(new AgamaCREReceiver.Prices[](0), new AgamaCREReceiver.Job[](0));
    }

    function test_onlyAForwarderDelivers() public {
        vm.expectRevert(abi.encodeWithSelector(AgamaCREReceiver.NotForwarder.selector, address(this)));
        receiver.onReport(_metadata(workflowOwner), _empty());
    }

    function test_expectedOwnerIsEnforced() public {
        receiver.setExpectedOwner(makeAddr("someoneElse"));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(AgamaCREReceiver.WrongOwner.selector, workflowOwner));
        receiver.onReport(_metadata(workflowOwner), _empty());
    }

    function test_supportsIReceiver() public view {
        assertTrue(receiver.supportsInterface(type(IReceiver).interfaceId));
    }

    function test_pricesLandInTheOracle() public {
        uint32 t = uint32(_warp(30));
        bytes[] memory prices = new bytes[](2);
        prices[0] = _streamReport(_streams("TSLA").regular, 431e18, t, 2);
        prices[1] = _streamReport(_streams("SPY").regular, 671e18, t, 2);
        _deliver(_prices(prices), new AgamaCREReceiver.Job[](0));
        assertEq(d.oracle.feed("TSLA").price, 431e18);
        assertEq(d.oracle.feed("SPY").price, 671e18);
        assertEq(d.oracle.feed("TSLA").observedAt, t);
    }

    /// One report: the stock is up, and the same run brings the position back
    /// to its target. A second pair that cannot run (no Earn position on NVDA)
    /// and a stale price are skipped without taking the rest down.
    function test_priceThenRebalance_andFailuresAreSkipped() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        uint256 debtBefore = d.earn.position(alice, address(d.tsla)).debt;

        uint32 t = uint32(_warp(30));
        bytes[] memory prices = new bytes[](2);
        prices[0] = _streamReport(_streams("TSLA").regular, 480e18, t, 2);
        prices[1] = _streamReport(_streams("NVDA").regular, 190e18, t - 120, 2); // older than stored
        AgamaCREReceiver.Job[] memory jobs = new AgamaCREReceiver.Job[](2);
        jobs[0] = _job(AgamaCREReceiver.Kind.Rebalance, address(acct), address(d.nvda));
        jobs[1] = _job(AgamaCREReceiver.Kind.Rebalance, address(acct), address(d.tsla));

        vm.expectEmit(false, false, false, true, address(receiver));
        emit AgamaCREReceiver.ReportHandled(bytes32(uint256(1)), 2, 1, 2, 1);
        _deliver(_prices(prices), jobs);

        assertEq(d.oracle.feed("TSLA").price, 480e18);
        assertEq(d.oracle.feed("NVDA").price, NVDA_PX, "the stale report was skipped");
        AgamaEarnRouter.Position memory p = d.earn.position(alice, address(d.tsla));
        assertGt(p.debt, debtBefore, "borrowed the difference");
        assertApproxEqRel(p.debt, (p.collateralValue * 2_500) / 10_000, 0.01e18, "back at 25%");
    }

    /// Prices only go to the oracles the governor listed.
    function test_unknownOracleReverts() public {
        address other = makeAddr("otherOracle");
        AgamaCREReceiver.Prices[] memory p = new AgamaCREReceiver.Prices[](1);
        p[0] = AgamaCREReceiver.Prices(other, new bytes[](0));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(AgamaCREReceiver.UnknownOracle.selector, other));
        receiver.onReport(_metadata(workflowOwner), abi.encode(p, new AgamaCREReceiver.Job[](0)));
    }

    /// Only the receiver runs its own jobs.
    function test_runIsInternalToTheReceiver() public {
        vm.expectRevert(abi.encodeWithSelector(AgamaCREReceiver.NotForwarder.selector, address(this)));
        receiver.run(_job(AgamaCREReceiver.Kind.Snapshot, address(0), address(d.vaultAdapter)));
    }

    /// The vault earned: the DON's report takes the daily NAV snapshot, then
    /// turns the yield into more stock through an allowlisted venue.
    function test_snapshotThenCompound_theYieldBecomesStock() public {
        MockDexRouter router = new MockDexRouter(usdc, wtsla, uint256(1e18) * 1e6 / 420e6);
        _dealStock(W_TSLAX, address(router), 100e18);
        d.zap.setTarget(address(router), true);
        d.zap.setSpender(address(router), true);

        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        _settleYield(200e6);
        _warp(20 days);
        _pushAll(true);

        AgamaCREReceiver.Job[] memory jobs = new AgamaCREReceiver.Job[](1);
        jobs[0] = _job(AgamaCREReceiver.Kind.Snapshot, address(0), address(d.vaultAdapter));
        _deliver(new AgamaCREReceiver.Prices[](0), jobs);
        assertEq(d.vaultAdapter.snapshotAt(), vm.getBlockTimestamp(), "snapshot taken");

        uint256 profit = acct.redeemableUsdc() - d.earn.position(alice, address(d.tsla)).debt;
        assertGt(profit, 1e6, "there is yield to compound");
        jobs[0] = AgamaCREReceiver.Job(
            AgamaCREReceiver.Kind.Compound,
            address(acct),
            address(d.tsla),
            abi.encode(
                profit, address(router), address(router), abi.encodeCall(MockDexRouter.swap, (profit)), 1
            )
        );
        vm.expectEmit(true, true, true, false, address(receiver));
        emit AgamaCREReceiver.JobDone(AgamaCREReceiver.Kind.Compound, address(acct), address(d.tsla));
        _deliver(new AgamaCREReceiver.Prices[](0), jobs);
        assertGt(d.earn.position(alice, address(d.tsla)).collateral, 10e18, "the stock grew");
    }

    /// The stock falls hard: the report repays from the vault buffer before
    /// the position gets near liquidation. The stock is not sold.
    function test_softDeleverage_underTheTrigger() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        uint256 px = d.oracle.feed("TSLA").price;
        while (d.pool.calculateHealthFactor(address(d.tsla), address(acct), "") >= 1.15e27) {
            px = (px * 95) / 100;
            _walkPrice("TSLA", px, true);
        }
        uint256 debtBefore = d.earn.position(alice, address(d.tsla)).debt;

        AgamaCREReceiver.Job[] memory jobs = new AgamaCREReceiver.Job[](1);
        jobs[0] = _job(AgamaCREReceiver.Kind.SoftDeleverage, address(acct), address(d.tsla));
        _deliver(new AgamaCREReceiver.Prices[](0), jobs);

        AgamaEarnRouter.Position memory p = d.earn.position(alice, address(d.tsla));
        assertLt(p.debt, debtBefore, "repaid from the buffer");
        assertEq(p.collateral, 10e18, "the stock itself is never sold");
    }

    function test_governorManagesForwarders() public {
        address other = makeAddr("other");
        receiver.setForwarder(other, true);
        assertTrue(receiver.isForwarder(other));
        vm.prank(other);
        vm.expectRevert();
        receiver.setForwarder(other, false);
        receiver.setOracle(other, true);
        assertTrue(receiver.isOracle(other));
    }

    /// The lens tells the workflow what is due, shaped as the receiver's jobs:
    /// the stock went up, so a rebalance; a day passed, so the snapshot. The
    /// same jobs delivered as a report bring the position back on target.
    function test_lensFindsTheJobs_andTheReceiverRunsThem() public {
        address[] memory stocks = new address[](2);
        stocks[0] = address(d.tsla);
        stocks[1] = address(d.nvda);
        AgamaKeeperLens lens = new AgamaKeeperLens(
            ILensPool(address(d.pool)),
            ILensFactory(address(d.factory)),
            address(d.vaultAdapter),
            address(0),
            stocks,
            new address[](0)
        );

        _openEarn(alice, 10e18, 2_500);
        (, AgamaCREReceiver.Job[] memory none,) = lens.scan(0, 10, 8);
        assertEq(none.length, 0, "on target, nothing due");

        _warp(1 days + 120);
        _pushAll(true);
        _walkPrice("TSLA", 500e18, true);
        (AgamaKeeperLens.FeedState[] memory feeds, AgamaCREReceiver.Job[] memory jobs, uint256 count) =
            lens.scan(0, 10, 8);
        assertEq(count, 1);
        assertEq(feeds[0].ticker, bytes32("TSLA"));
        assertEq(feeds[0].price, 500e18);
        assertEq(jobs.length, 2);
        assertEq(uint8(jobs[0].kind), uint8(AgamaCREReceiver.Kind.Rebalance));
        assertEq(jobs[0].adapter, address(d.tsla));
        assertEq(uint8(jobs[1].kind), uint8(AgamaCREReceiver.Kind.Snapshot));

        _deliver(new AgamaCREReceiver.Prices[](0), jobs);
        AgamaEarnRouter.Position memory p = d.earn.position(alice, address(d.tsla));
        assertApproxEqRel(p.debt, (p.collateralValue * 2_500) / 10_000, 0.01e18, "back at 25%");
        (, jobs,) = lens.scan(0, 10, 8);
        assertEq(jobs.length, 0, "and nothing left to do");
    }
}

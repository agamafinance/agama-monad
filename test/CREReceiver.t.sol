// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {DataStreamsStockOracle} from "../src/arrow/oracle/DataStreamsStockOracle.sol";
import {AgamaAccount} from "../src/agama/AgamaAccount.sol";
import {AgamaEarnRouter} from "../src/agama/AgamaEarnRouter.sol";
import {AgamaCREReceiver, IDataStreamsOracle, IReceiver} from "../src/cre/AgamaCREReceiver.sol";

/// @notice The CRE workflow's landing point: one DON report carries Data
///         Streams reports for the oracle and the positions to rebalance.
contract CREReceiverTest is BaseTest {
    AgamaCREReceiver receiver;
    address forwarder = makeAddr("forwarder");
    address workflowOwner = makeAddr("workflowOwner");

    function setUp() public override {
        super.setUp();
        address[] memory fwd = new address[](1);
        fwd[0] = forwarder;
        receiver = new AgamaCREReceiver(IDataStreamsOracle(address(d.oracle)), address(this), fwd);
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

    function _deliver(bytes[] memory prices, address[] memory accounts, address[] memory adapters) internal {
        vm.prank(forwarder);
        receiver.onReport(_metadata(workflowOwner), abi.encode(prices, accounts, adapters));
    }

    function test_onlyAForwarderDelivers() public {
        bytes memory report = abi.encode(new bytes[](0), new address[](0), new address[](0));
        vm.expectRevert(abi.encodeWithSelector(AgamaCREReceiver.NotForwarder.selector, address(this)));
        receiver.onReport(_metadata(workflowOwner), report);
    }

    function test_expectedOwnerIsEnforced() public {
        receiver.setExpectedOwner(makeAddr("someoneElse"));
        bytes memory report = abi.encode(new bytes[](0), new address[](0), new address[](0));
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(AgamaCREReceiver.WrongOwner.selector, workflowOwner));
        receiver.onReport(_metadata(workflowOwner), report);
    }

    function test_supportsIReceiver() public view {
        assertTrue(receiver.supportsInterface(type(IReceiver).interfaceId));
    }

    function test_pricesLandInTheOracle() public {
        uint32 t = uint32(_warp(30));
        bytes[] memory prices = new bytes[](2);
        prices[0] = _streamReport(_streams("TSLA").regular, 431e18, t, 2);
        prices[1] = _streamReport(_streams("SPY").regular, 671e18, t, 2);
        _deliver(prices, new address[](0), new address[](0));
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
        address[] memory accounts = new address[](2);
        address[] memory adapters = new address[](2);
        accounts[0] = address(acct);
        adapters[0] = address(d.nvda);
        accounts[1] = address(acct);
        adapters[1] = address(d.tsla);

        vm.expectEmit(false, false, false, true, address(receiver));
        emit AgamaCREReceiver.ReportHandled(bytes32(uint256(1)), 2, 1, 1);
        _deliver(prices, accounts, adapters);

        assertEq(d.oracle.feed("TSLA").price, 480e18);
        assertEq(d.oracle.feed("NVDA").price, NVDA_PX, "the stale report was skipped");
        AgamaEarnRouter.Position memory p = d.earn.position(alice, address(d.tsla));
        assertGt(p.debt, debtBefore, "borrowed the difference");
        assertApproxEqRel(p.debt, (p.collateralValue * 2_500) / 10_000, 0.01e18, "back at 25%");
    }

    function test_mismatchedPairsRevert() public {
        vm.prank(forwarder);
        vm.expectRevert(AgamaCREReceiver.LengthMismatch.selector);
        receiver.onReport(
            _metadata(workflowOwner), abi.encode(new bytes[](0), new address[](1), new address[](0))
        );
    }

    function test_governorManagesForwarders() public {
        address other = makeAddr("other");
        receiver.setForwarder(other, true);
        assertTrue(receiver.isForwarder(other));
        vm.prank(other);
        vm.expectRevert();
        receiver.setForwarder(other, false);
    }
}

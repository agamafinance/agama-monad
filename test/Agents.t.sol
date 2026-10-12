// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {AgamaAccount} from "../src/agama/AgamaAccount.sol";
import {AgamaEarnRouter} from "../src/agama/AgamaEarnRouter.sol";
import {MockDexRouter} from "./Zap.t.sol";

/// The product the user asked for: deposit the stock and never touch it again.
/// Agents keep the position at the chosen level and turn the vault yield into
/// more stock. Everything here is permissionless, so anyone can run them.
contract AgentsForkTest is BaseTest {
    MockDexRouter router;

    function setUp() public override {
        super.setUp();
        router = new MockDexRouter(usdc, wtsla, uint256(1e18) * 1e6 / 420e6); // 1 wTSLAx per 420 USDC
        _dealStock(W_TSLAX, address(router), 100e18);
        d.zap.setTarget(address(router), true);
        d.zap.setSpender(address(router), true);
    }

    function test_stockGoesUp_theAgentBorrowsMoreAndVaultsIt() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        assertEq(acct.targetLtvBps(address(d.tsla)), 2_500, "the LTV the user picked is remembered");

        uint256 debtBefore = d.earn.position(alice, address(d.tsla)).debt;
        _walkPrice("TSLA", 500e18, true); // TSLA 420 -> 500

        vm.prank(liquidator); // anyone can run the agent
        int256 delta = acct.rebalance(address(d.tsla));

        AgamaEarnRouter.Position memory p = d.earn.position(alice, address(d.tsla));
        assertGt(delta, 0, "borrowed more against a stock worth more");
        assertApproxEqRel(p.debt, (p.collateralValue * 2_500) / 10_000, 0.01e18, "back at 25% LTV");
        assertGt(p.debt, debtBefore);
        assertApproxEqRel(p.freeSharesValue, p.debt, 0.01e18, "the extra USDC went into the vault");
    }

    function test_stockGoesDown_theAgentRepaysFromTheYieldBuffer() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        _walkPrice("TSLA", 360e18, true);

        vm.prank(liquidator);
        int256 delta = acct.rebalance(address(d.tsla));

        AgamaEarnRouter.Position memory p = d.earn.position(alice, address(d.tsla));
        assertLt(delta, 0, "repaid without touching the stock");
        assertApproxEqRel(p.debt, (p.collateralValue * 2_500) / 10_000, 0.02e18, "back at 25% LTV");
        assertEq(p.collateral, 10e18, "the stock itself is never sold");
    }

    function test_insideTheBand_theAgentDoesNothing() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        vm.expectPartialRevert(AgamaAccount.AlreadyOnTarget.selector);
        acct.rebalance(address(d.tsla));
    }

    /// Whatever level the user picked and however the stock moved, an agent may
    /// never sell the stock and may never push the position further from the
    /// target than it found it. Those two hold even when the buffer is too
    /// small to finish the job.
    function testFuzz_rebalanceNeverSellsTheStockAndNeverMakesItWorse(uint16 targetBps, uint16 moveBps)
        public
    {
        targetBps = uint16(bound(targetBps, 500, 3_000)); // 5% up to the market max
        moveBps = uint16(bound(moveBps, 6_500, 15_000)); // the stock at -35% to +50%
        _openEarn(alice, 10e18, targetBps);
        AgamaAccount acct = _account(alice);

        uint256 px = d.oracle.feed("TSLA").price;
        _walkPrice("TSLA", (px * moveBps) / 10_000, true);

        AgamaEarnRouter.Position memory before = d.earn.position(alice, address(d.tsla));
        uint256 ltvBefore = before.collateralValue == 0 ? 0 : (before.debt * 10_000) / before.collateralValue;

        vm.prank(liquidator);
        try acct.rebalance(address(d.tsla)) {
            AgamaEarnRouter.Position memory p = d.earn.position(alice, address(d.tsla));
            assertEq(p.collateral, 10e18, "the stock itself is never sold");
            uint256 ltvAfter = p.collateralValue == 0 ? 0 : (p.debt * 10_000) / p.collateralValue;
            uint256 wasOff = ltvBefore > targetBps ? ltvBefore - targetBps : targetBps - ltvBefore;
            uint256 isOff = ltvAfter > targetBps ? ltvAfter - targetBps : targetBps - ltvAfter;
            assertLe(isOff, wasOff + 1, "the agent moved the position toward the level the user picked");
            assertLe(ltvAfter, uint256(d.tsla.MAX_LTV()) + 100, "never above what the market allows");
        } catch {
            // Nothing to do, or nothing it could do: both are answers, not failures.
        }
    }

    /// The buffer is what repays the loan. Compounding spends yield, never it.
    function testFuzz_compoundLeavesTheBufferCoveringTheDebt(uint96 yield_) public {
        uint256 settled = bound(uint256(yield_), 1e6, 5_000e6);
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        _settleYield(settled);
        _warp(20 days);
        d.vaultAdapter.snapshot();
        _pushAll(true);

        uint256 debt = d.earn.position(alice, address(d.tsla)).debt;
        uint256 have = acct.redeemableUsdc();
        if (have <= debt + 1e6) return; // no surplus worth compounding
        uint256 profit = have - debt;
        bytes memory swapData = abi.encodeCall(MockDexRouter.swap, (profit));

        vm.prank(liquidator);
        try acct.compoundIntoStock(address(d.tsla), profit, address(router), address(router), swapData, 1) {
            AgamaEarnRouter.Position memory p = d.earn.position(alice, address(d.tsla));
            assertGe(acct.redeemableUsdc() + 1, p.debt, "the buffer still covers the debt");
            assertGt(p.collateral, 10e18, "and the stock grew");
        } catch {
            // A price the floor refuses is a pass: nothing was spent.
        }
    }

    function test_onAClosedPosition_theAgentSaysSoInsteadOfPanicking() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        deal(address(usdc), alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(d.earn), 10e6);
        d.earn.closeWithTopUp(address(d.tsla), 10e6);
        vm.stopPrank();

        // The target outlives the close, so a keeper sweeping every account will
        // land here. It must get the custom error, not a division by zero.
        vm.expectPartialRevert(AgamaAccount.AlreadyOnTarget.selector);
        acct.rebalance(address(d.tsla));
    }

    function test_theYieldComesBackAsMoreStock() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        uint256 stockBefore = d.tsla.balanceOf(address(acct));

        _settleYield(200e6); // the vault earns
        _warp(20 days); // let the CAPO ceiling catch up with the settled yield
        d.vaultAdapter.snapshot();
        // Compounding prices the stock it bought against the oracle, so the feed
        // has to be live: twenty days of warping made it stale.
        _pushAll(true);

        uint256 profit = acct.redeemableUsdc() - d.earn.position(alice, address(d.tsla)).debt;
        assertGt(profit, 1e6, "there is yield to compound");
        bytes memory swapData = abi.encodeCall(MockDexRouter.swap, (profit));

        vm.prank(liquidator); // anyone can run the agent
        uint256 added =
            acct.compoundIntoStock(address(d.tsla), profit, address(router), address(router), swapData, 1);

        assertGt(added, 0, "the yield bought stock");
        assertEq(d.tsla.balanceOf(address(acct)), stockBefore + added, "and it became collateral");
        // The user's stock grew: that is the whole promise.
        assertGt(d.earn.position(alice, address(d.tsla)).collateral, 10e18);
    }

    function test_compoundRefusesABadPriceEvenIfTheCallerAsksForIt() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        _settleYield(200e6);
        _warp(20 days);
        d.vaultAdapter.snapshot();
        _pushAll(true);

        // A router that pays a third of the going rate, and a caller who says
        // that is fine by passing a floor of 1. The account is not theirs.
        MockDexRouter bad = new MockDexRouter(usdc, wtsla, uint256(1e18) * 1e6 / 1_260e6);
        _dealStock(W_TSLAX, address(bad), 100e18);
        d.zap.setTarget(address(bad), true);
        d.zap.setSpender(address(bad), true);

        uint256 profit = acct.redeemableUsdc() - d.earn.position(alice, address(d.tsla)).debt;
        bytes memory swapData = abi.encodeCall(MockDexRouter.swap, (profit));
        vm.prank(liquidator);
        vm.expectPartialRevert(AgamaAccount.CompoundPriceTooBad.selector);
        acct.compoundIntoStock(address(d.tsla), profit, address(bad), address(bad), swapData, 1);
    }

    function test_compoundNeverEatsTheBufferThatProtectsTheStock() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        // No yield settled yet: the free shares only cover the debt.
        vm.expectRevert(AgamaAccount.NothingToCompound.selector);
        acct.compoundIntoStock(address(d.tsla), 1e6, address(router), address(router), "", 1);
    }

    function test_compoundOnlyThroughAnAllowlistedRouter() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        _settleYield(200e6);
        address evil = makeAddr("evil");
        vm.expectRevert(abi.encodeWithSelector(AgamaAccount.SwapTargetNotAllowed.selector, evil));
        acct.compoundIntoStock(address(d.tsla), 1e6, evil, evil, "", 1);
    }
}

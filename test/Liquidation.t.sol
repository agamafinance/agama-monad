// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {AgamaAccount} from "../src/agama/AgamaAccount.sol";
import {ArrowLendingPool} from "../src/arrow/ArrowLendingPool.sol";

contract LiquidationForkTest is BaseTest {
    function _earnWithoutBuffer() internal returns (AgamaAccount acct) {
        _openEarn(alice, 10e18, 2_500);
        acct = _account(alice);
        // Alice pulls her free vault shares out: no soft-deleverage buffer left.
        vm.prank(alice);
        acct.sweep(d.vault);
    }

    function test_stockGap_partialLiquidation_leavesRestToBorrower() public {
        AgamaAccount acct = _earnWithoutBuffer();

        // TSLA 420 -> 250: HF = 2500 * 40% / 1050 = 0.95
        _walkPrice("TSLA", 250e18, true);
        assertLt(d.pool.calculateHealthFactor(address(d.tsla), address(acct), ""), 1e27);

        uint256 spSharesBefore = d.pool.balanceOf(address(d.sp));
        vm.prank(liquidator); // permissionless
        uint256 absorbed = d.sp.liquidate(address(d.tsla), address(acct));

        assertApproxEqAbs(absorbed, 1_050e6, 1e3, "debt incl. a few minutes of interest");
        assertEq(d.pool.getPositionScaledDebt(address(d.tsla), address(acct), ""), 0, "debt cleared");
        // Seized = 1050 * 1.10 / 250 = 4.62 wTSLAx; Alice keeps 5.38.
        assertApproxEqRel(wtsla.balanceOf(address(d.sp)), 4.62e18, 1e12);
        assertApproxEqRel(d.tsla.balanceOf(address(acct)), 5.38e18, 1e12);
        assertLt(d.pool.balanceOf(address(d.sp)), spSharesBefore, "SP burned lender shares");
        // SP value includes the inventory: the 10% bonus minus the 3% buyer
        // discount leaves SP depositors whole or better.
        assertGe(d.pool.convertToAssets(d.sp.totalAssets()), 5_000e6 - 1);
    }

    /// Found by the end-to-end run: with an empty stability pool the call used
    /// to succeed while seizing nothing, so a keeper announced a liquidation
    /// that never happened.
    function test_liquidation_revertsWhenTheStabilityPoolIsEmpty() public {
        AgamaAccount acct = _earnWithoutBuffer();

        // Drain the SP: its depositor exits after the cooldown.
        uint256 shares = d.sp.balanceOf(spDepositor);
        vm.prank(spDepositor);
        d.sp.requestExit(shares);
        _warp(1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(spDepositor);
        d.sp.redeem(shares, spDepositor, spDepositor);
        assertEq(d.pool.balanceOf(address(d.sp)), 0, "stability pool drained");

        _pushAll(true); // prices went stale while the cooldown ran
        _walkPrice("TSLA", 250e18, true);
        vm.expectRevert(ArrowLendingPool.StabilityPoolEmpty.selector);
        d.sp.liquidate(address(d.tsla), address(acct));
    }

    function test_liquidation_revertsWhenHealthy() public {
        AgamaAccount acct = _earnWithoutBuffer();
        vm.expectRevert(ArrowLendingPool.HealthFactorTooHigh.selector);
        d.sp.liquidate(address(d.tsla), address(acct));
    }

    function test_buyCollateral_recyclesInventoryIntoLenderShares() public {
        AgamaAccount acct = _earnWithoutBuffer();
        _walkPrice("TSLA", 250e18, true);
        d.sp.liquidate(address(d.tsla), address(acct));

        uint256 inv = wtsla.balanceOf(address(d.sp));
        // Fair 250 * inv, minus 3% discount.
        uint256 cost = (inv * 250 * 9_700) / 10_000 / 1e12 + 1;
        _fund(liquidator, cost);
        vm.startPrank(liquidator);
        usdc.approve(address(d.sp), cost);
        uint256 paid = d.sp.buyCollateral(address(d.tsla), inv, cost, liquidator);
        vm.stopPrank();

        assertEq(wtsla.balanceOf(liquidator), inv);
        assertLe(paid, cost);
        assertEq(wtsla.balanceOf(address(d.sp)), 0);
        // All value back in liquid lender shares, above the initial 5,000 USDC.
        assertGt(d.pool.convertToAssets(d.pool.balanceOf(address(d.sp))), 5_000e6);
    }

    function test_liquidation_blockedOnStalePrice() public {
        AgamaAccount acct = _earnWithoutBuffer();
        _walkPrice("TSLA", 250e18, true);
        _warp(2 hours); // open-market price older than 1h
        vm.expectRevert();
        d.sp.liquidate(address(d.tsla), address(acct));
    }

    function test_weekendBuffer_canTriggerLiquidationOnClose() public {
        AgamaAccount acct = _earnWithoutBuffer();
        // 330: open HF = 3300 * 40% / 1050 = 1.257 ; closed HF = 3300 * 32% / 1050 = 1.006
        _walkPrice("TSLA", 330e18, true);
        uint256 t = _warp(60);
        vm.prank(keeper);
        d.oracle.push("TSLA", 300e18, uint64(t), false); // Friday close at 300
        // closed HF = 3000 * 32% / 1050 = 0.914 -> liquidatable over the weekend
        assertLt(d.pool.calculateHealthFactor(address(d.tsla), address(acct), ""), 1e27);
        d.sp.liquidate(address(d.tsla), address(acct));
    }

    function test_amplify_liquidation_andVaultShareRecycling() public {
        _openAmplify(bob, 1_000e6, 30_000);
        AgamaAccount acct = _account(bob);

        // Push utilization up so interest outruns the (flat) vault NAV.
        _dealStock(W_SPYX, liquidator, 100e18);
        vm.startPrank(liquidator);
        d.pool.openVaultPosition();
        wspy.approve(address(d.spy), 100e18);
        d.pool.depositAsset(address(d.spy), abi.encode(uint256(100e18)));
        d.pool.borrow(address(d.spy), "", 22_000e6);
        vm.stopPrank();

        _warp(365 days);
        assertLt(d.pool.calculateHealthFactor(address(d.vaultAdapter), address(acct), ""), 1e27);

        d.sp.liquidate(address(d.vaultAdapter), address(acct));
        uint256 seized = d.vault.balanceOf(address(d.sp));
        assertGt(seized, 0, "SP holds vault shares");

        // Seized sagUSD is redeemed with priority and supplied back to Arrow.
        uint256 before = d.pool.balanceOf(address(d.sp));
        d.sp.redeemVaultShares(seized);
        assertEq(d.vault.balanceOf(address(d.sp)), 0);
        assertGt(d.pool.balanceOf(address(d.sp)), before);
    }
}

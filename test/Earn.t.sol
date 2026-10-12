// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseTest} from "./Base.t.sol";
import {AgamaEarnRouter} from "../src/agama/AgamaEarnRouter.sol";
import {AgamaAccount} from "../src/agama/AgamaAccount.sol";
import {ArrowLendingPool} from "../src/arrow/ArrowLendingPool.sol";

contract EarnForkTest is BaseTest {
    function test_open_borrowsAtChosenLtv_andParksUsdcInVault() public {
        uint256 borrowed = _openEarn(alice, 10e18, 2_500);

        // 10 wTSLAx * 420 * wrapper ratio (1.0 for TSLA) = 4,200 USDC; 25% = 1,050.
        assertEq(borrowed, 1_050e6, "borrow");
        AgamaEarnRouter.Position memory p = d.earn.position(alice, address(d.tsla));
        assertEq(p.collateral, 10e18);
        assertEq(p.collateralValue, 4_200e6);
        assertEq(p.debt, 1_050e6);
        // HF = 4200 * 40% / 1050 = 1.6
        assertApproxEqRel(p.healthFactorRay, 1.6e27, 1e14);
        // The borrowed USDC sits in the Agama vault as free shares.
        assertApproxEqAbs(p.freeSharesValue, 1_050e6, 1);
        assertEq(wtsla.balanceOf(alice), 0);
    }

    function test_close_returnsStock_andYield() public {
        _openEarn(alice, 10e18, 2_500);
        // Vault earns: 2% of its assets over the period.
        _settleYield(21e6);
        _warp(30 days);
        _pushAll(true);

        vm.prank(alice);
        d.earn.close(address(d.tsla));

        assertEq(wtsla.balanceOf(alice), 10e18, "stock back");
        assertEq(d.pool.getPositionScaledDebt(address(d.tsla), address(_account(alice)), ""), 0, "no debt");
        // Alice keeps the spread: vault yield minus 30 days of interest, as
        // vault shares and/or USDC. Yield (net of 10% fee) is ~18.9 USDC,
        // interest at the low utilization of this test is ~1.3 USDC.
        // Measured at the live vault rate (the adapter's CAPO ceiling would
        // under-count a yield jump settled right after deployment).
        uint256 leftover = d.vault.convertToAssets(d.vault.balanceOf(alice)) / 1e12 + usdc.balanceOf(alice);
        assertGt(leftover, 15e6, "positive carry");
        assertLt(leftover, 20e6);
    }

    /// The chain does not keep office hours, so neither does the market. What
    /// closes is the equity session, and with it the price feed: the terms
    /// tighten by the weekend buffer on both sides at once, so a position
    /// opened out of session sits the same distance from liquidation as one
    /// opened in it.
    function test_sessionClosed_keepsBorrowingOpenOnTighterTerms() public {
        uint256 t = _warp(60);
        vm.prank(keeper);
        d.oracle.push("TSLA", TSLA_PX, uint64(t), false);

        assertTrue(d.tsla.borrowAllowed(), "a shut session is not a shut market");
        assertEq(d.tsla.LIQUIDATION_THRESHOLD(), 3_200, "40% - 8% weekend buffer");
        assertEq(d.tsla.MAX_LTV(), 2_200, "30% - 8%, the same buffer on the other side");

        // The weekday maximum is refused, the out of session one is not.
        vm.startPrank(alice);
        wtsla.approve(address(d.earn), 10e18);
        vm.expectRevert(abi.encodeWithSelector(AgamaEarnRouter.LtvTooHigh.selector, 3_000, 2_200));
        d.earn.open(address(d.tsla), 5e18, 3_000);
        d.earn.open(address(d.tsla), 5e18, 2_200);
        vm.stopPrank();
        assertGt(
            d.pool.getPositionScaledDebt(address(d.tsla), address(_account(alice)), ""),
            0,
            "the borrow went through with the session shut"
        );

        // And it lands with the cushion the open market gives, near enough.
        uint256 hf = d.pool.calculateHealthFactor(address(d.tsla), address(_account(alice)), "");
        assertGt(hf, 1.4e27, "opened out of session, still well clear of liquidation");

        // Frozen price stays usable for valuation for up to 4 days.
        _warp(3 days);
        assertEq(d.tsla.valueOf(1e18), 420e6);
        _warp(2 days);
        vm.expectRevert();
        d.tsla.valueOf(1e18);
    }

    function test_ltvAboveMax_reverts() public {
        vm.startPrank(alice);
        wtsla.approve(address(d.earn), 10e18);
        vm.expectRevert(abi.encodeWithSelector(AgamaEarnRouter.LtvTooHigh.selector, 3_100, 3_000));
        d.earn.open(address(d.tsla), 10e18, 3_100);
        vm.stopPrank();
    }

    function test_softDeleverage_usesVaultShares_notTheStock() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);

        // TSLA 420 -> 300: HF = 3000 * 40% / 1050 = 1.143 < 1.15
        _walkPrice("TSLA", 300e18, true);
        uint256 hf = d.pool.calculateHealthFactor(address(d.tsla), address(acct), "");
        assertLt(hf, 1.15e27);

        // Anyone can trigger it.
        vm.prank(liquidator);
        uint256 repaid = acct.softDeleverage(address(d.tsla));

        uint256 hfAfter = d.pool.calculateHealthFactor(address(d.tsla), address(acct), "");
        assertApproxEqRel(hfAfter, 1.4e27, 1e15, "back to 1.40");
        assertApproxEqAbs(repaid, 1_050e6 - 857_142_857, 2e6);
        assertEq(d.tsla.balanceOf(address(acct)), 10e18, "stock untouched");
    }

    /// Found while building the front: right after a soft deleverage the free
    /// shares no longer cover the debt. `close` reverts with the exact
    /// shortfall, `closeWithTopUp` pulls it from the wallet in the same tx.
    function test_close_afterSoftDeleverage_needsTopUp() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        _walkPrice("TSLA", 300e18, true);
        acct.softDeleverage(address(d.tsla));
        _warp(30 days);
        _walkPrice("TSLA", TSLA_PX, true); // back to 420

        vm.prank(alice);
        vm.expectPartialRevert(AgamaAccount.InsufficientToRepay.selector);
        d.earn.close(address(d.tsla));

        uint256 short = d.earn.closeShortfall(alice, address(d.tsla));
        assertGt(short, 0);
        assertLt(short, 5e6, "a few USDC of interest");
        _fund(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(d.earn), short);
        d.earn.closeWithTopUp(address(d.tsla), short);
        vm.stopPrank();
        assertEq(wtsla.balanceOf(alice), 10e18, "stock back");
        assertEq(d.pool.getPositionScaledDebt(address(d.tsla), address(acct), ""), 0);
        // The unused margin comes back as vault shares (they were not redeemed).
        uint256 back = usdc.balanceOf(alice) + d.vault.convertToAssets(d.vault.balanceOf(alice)) / 1e12;
        assertGt(back, 10e6 - short, "unused margin returned");
    }

    /// Withdrawing a tokenized stock from the OKX app to X Layer delivers the
    /// BASE xStock, not the ERC-4626 wrapper the market takes. Both directions
    /// must work in one transaction, or the OKX rail does not connect.
    function test_openWithBase_andCloseToBase_matchTheOkxRails() public {
        IERC4626 wrapper = IERC4626(W_TSLAX);
        IERC20 base = IERC20(wrapper.asset());
        deal(address(base), alice, 10e18);

        vm.startPrank(alice);
        base.approve(address(d.earn), 10e18);
        uint256 borrowed = d.earn.openWithBase(address(d.tsla), 10e18, 2_500);
        vm.stopPrank();

        AgamaEarnRouter.Position memory p = d.earn.position(alice, address(d.tsla));
        // ERC-4626 rounds the wrap down by a wei.
        assertApproxEqAbs(
            wrapper.convertToAssets(p.collateral), 10e18, 2, "10 base xStock wrapped as collateral"
        );
        assertApproxEqRel(p.debt, (p.collateralValue * 25) / 100, 1e12);
        assertGt(borrowed, 0);
        assertEq(base.balanceOf(alice), 0, "the base token went in");

        // The vault buffer sits a hair under the debt (interest), so the close
        // needs the same top-up path as the wrapper one.
        uint256 short = d.earn.closeShortfall(alice, address(d.tsla));
        _fund(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(d.earn), short + 1e6);
        if (short > 0) d.earn.closeToBaseWithTopUp(address(d.tsla), short + 1e6);
        else d.earn.closeToBase(address(d.tsla));
        vm.stopPrank();
        assertApproxEqAbs(base.balanceOf(alice), 10e18, 2, "base token back, ready to deposit on OKX");
        // Her 10 wrapped tokens from setUp are untouched: only the base ones
        // she brought in came back, in the form an OKX deposit takes.
        assertEq(IERC20(W_TSLAX).balanceOf(alice), 10e18, "wrapped balance untouched");
    }

    function test_softDeleverage_revertsWhenHealthy() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        vm.expectRevert();
        acct.softDeleverage(address(d.tsla));
    }

    function test_onlyOwnerOrRouter_canOperateAccount() public {
        _openEarn(alice, 10e18, 2_500);
        AgamaAccount acct = _account(alice);
        vm.prank(bob);
        vm.expectRevert(AgamaAccount.NotAuthorized.selector);
        acct.earnClose(alice, address(d.tsla), false);
        vm.prank(bob);
        vm.expectRevert(AgamaAccount.NotAuthorized.selector);
        acct.earnClose(bob, address(d.tsla), false);
    }

    /// A stale price is what stops a borrow, not the clock. The feed survives
    /// the weekend by design, so the test has to outlive it to see the block.
    function test_directBorrow_blockedWhenThePriceGoesStale() public {
        uint256 t = _warp(60);
        vm.prank(keeper);
        d.oracle.push("TSLA", TSLA_PX, uint64(t), false);
        vm.startPrank(alice);
        d.pool.openVaultPosition();
        wtsla.approve(address(d.tsla), 1e18);
        d.pool.depositAsset(address(d.tsla), abi.encode(uint256(1e18)));

        // Session shut, price fresh: the borrow goes through.
        d.pool.borrow(address(d.tsla), "", 10e6);
        vm.stopPrank();

        assertTrue(d.tsla.borrowAllowed());
        _warp(5 days);
        assertFalse(d.tsla.borrowAllowed(), "nobody has priced this in five days");

        vm.startPrank(alice);
        vm.expectRevert(ArrowLendingPool.BorrowNotAllowed.selector);
        d.pool.borrow(address(d.tsla), "", 10e6);
        vm.stopPrank();
    }
}

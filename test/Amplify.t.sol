// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {AgamaAmplifyRouter} from "../src/agama/AgamaAmplifyRouter.sol";
import {AgamaAccount} from "../src/agama/AgamaAccount.sol";

contract AmplifyForkTest is BaseTest {
    function test_open3x_reachesTargetLeverage() public {
        uint256 debt = _openAmplify(bob, 1_000e6, 30_000);

        AgamaAmplifyRouter.Position memory p = d.amplify.position(bob);
        assertApproxEqRel(debt, 2_000e6, 0.01e18, "debt ~2x equity");
        assertApproxEqRel(p.exposure, 3_000e6, 0.01e18, "exposure ~3x");
        assertApproxEqRel(p.leverageBps, 30_000, 0.01e18);
        // HF = exposure * (1 - 3% haircut) * 80% / debt ~ 1.164
        assertApproxEqRel(p.healthFactorRay, 1.164e27, 0.01e18);
        assertEq(usdc.balanceOf(bob), 4_000e6);
    }

    function test_leverageAbove3x_reverts() public {
        vm.startPrank(bob);
        usdc.approve(address(d.amplify), 1_000e6);
        vm.expectRevert(AgamaAccount.LeverageOutOfRange.selector);
        d.amplify.open(1_000e6, 30_001);
        vm.stopPrank();
    }

    function test_close_returnsEquityPlusLeveragedYield() public {
        _openAmplify(bob, 1_000e6, 30_000);
        // The vault holds ~3,000 USDC of Bob's exposure: settle 1% gross yield.
        _settleYield(30e6);
        _warp(30 days);

        vm.prank(bob);
        d.amplify.close(true);

        uint256 got = usdc.balanceOf(bob) - 4_000e6;
        // 30 USDC gross -> 27 net of the 10% vault fee, on 3x exposure,
        // minus ~2,000 USDC * ~1.4% * 30/365 of interest (~2.3 USDC).
        assertGt(got, 1_020e6, "leveraged carry");
        assertLt(got, 1_027e6);
        AgamaAmplifyRouter.Position memory p = d.amplify.position(bob);
        assertEq(p.debt, 0);
        assertEq(p.pledgedShares, 0);
    }

    function test_close_withoutYield_losesOnlyInterest() public {
        _openAmplify(bob, 1_000e6, 20_000);
        _warp(7 days);
        vm.prank(bob);
        d.amplify.close(true);
        uint256 got = usdc.balanceOf(bob) - 4_000e6;
        assertGt(got, 999e6);
        assertLe(got, 1_000e6);
    }

    function test_netApyView_matchesFormula() public view {
        // vault 10%, live borrow rate r: net = 10% + 2 * (10% - r)
        uint256 r = d.pool.getReserveState().currentBorrowRate;
        int256 net = d.amplify.netApyRay(0.1e27, 30_000);
        assertEq(net, int256(0.1e27) + 2 * (int256(0.1e27) - int256(r)));
    }

    function test_autoUnwind_whenSpreadTurnsNegative() public {
        _openAmplify(bob, 1_000e6, 30_000);
        AgamaAccount acct = _account(bob);

        // Tiny realized yield: ~0.1% over 30 days, far under the borrow rate.
        _warp(30 days);
        _settleYield(3e6);
        d.vaultAdapter.snapshot();
        assertGt(d.vaultAdapter.realizedApyRay(), 0);

        vm.prank(liquidator);
        acct.autoUnwind();

        AgamaAmplifyRouter.Position memory p = d.amplify.position(bob);
        assertEq(p.debt, 0, "unwound to 1x");
        assertGt(acct.freeShares(), 0, "equity kept as vault shares");
    }

    function test_autoUnwind_revertsWhileSpreadPositive() public {
        _openAmplify(bob, 1_000e6, 30_000);
        AgamaAccount acct = _account(bob);
        // No measured yield yet: nobody can unwind blind.
        vm.expectRevert();
        acct.autoUnwind();

        // Healthy yield: ~1% per month, well above the borrow rate.
        _warp(30 days);
        _settleYield(30e6);
        d.vaultAdapter.snapshot();
        vm.expectRevert();
        acct.autoUnwind();
    }

    /// Found while extending the e2e: closing an Amplify stacked on Earn used
    /// to send the shares to the wallet, leaving Earn without its buffer (and
    /// unable to close without a full top-up). The equity now stays in the
    /// account as the Earn buffer.
    function test_closeStacked_restoresEarnBuffer() public {
        _openEarn(alice, 10e18, 2_500);
        uint256 bufferBefore = _account(alice).freeSharesValue();
        vm.startPrank(alice);
        d.amplify.openFromEarn(20_000);
        assertEq(_account(alice).freeShares(), 0);
        d.amplify.close(true); // even with redeem=true, equity stays for Earn
        vm.stopPrank();

        AgamaAccount acct = _account(alice);
        assertTrue(acct.hasEarnDebt());
        assertApproxEqRel(acct.redeemableUsdc(), bufferBefore, 0.001e18, "buffer restored");
        assertEq(d.vault.balanceOf(alice), 0, "nothing leaked to the wallet");

        // Earn closes on its own buffer, no (or dust) top-up needed.
        assertLt(d.earn.closeShortfall(alice, address(d.tsla)), 1e6);
    }

    function test_stackOnEarn_pledgesFreeShares() public {
        _openEarn(alice, 10e18, 2_500); // 1,050 USDC of free shares
        vm.prank(alice);
        d.amplify.openFromEarn(20_000);
        AgamaAmplifyRouter.Position memory p = d.amplify.position(alice);
        assertApproxEqRel(p.exposure, 2_100e6, 0.01e18);
        assertApproxEqRel(p.debt, 1_050e6, 0.01e18);
        assertEq(_account(alice).freeShares(), 0);
    }
}

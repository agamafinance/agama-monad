// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {agUSDQueue} from "../src/vault/agUSDQueue.sol";
import {ArrowVaultShareAdapter} from "../src/arrow/adapters/ArrowVaultShareAdapter.sol";
import {ArrowXStockAdapter} from "../src/arrow/adapters/ArrowXStockAdapter.sol";
import {StockOracle} from "../src/arrow/oracle/StockOracle.sol";
import {TestXStock} from "../src/mocks/TestnetTokens.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract SafetyForkTest is BaseTest {
    /// Stream xUSD / Elixir lesson: the vault must never fund the pool that
    /// accepts its own shares as collateral.
    function test_vaultCannotLendIntoArrow() public {
        assertEq(d.queue.forbiddenVault(), address(d.pool));
        vm.expectRevert(abi.encodeWithSelector(agUSDQueue.ForbiddenVault.selector, address(d.pool)));
        d.queue.addCreditVault(address(d.pool));
        vm.expectRevert(agUSDQueue.ForbiddenVaultAlreadySet.selector);
        d.queue.setForbiddenVault(address(0xBEEF));
    }

    /// Never a hardcoded 1$: the vault share is valued at its exchange rate,
    /// and a NAV jump above the CAPO ceiling is not borrowable.
    function test_vaultShare_capoCapsNavJump() public {
        _openAmplify(bob, 1_000e6, 10_000);
        uint256 shares = d.vaultAdapter.balanceOf(address(_account(bob)));
        uint256 before = d.vaultAdapter.valueOf(shares);
        _settleYield(100e6); // +9% net on a ~1,000 USDC vault, instantly
        uint256 live = d.vault.convertToAssets(shares) / 1e12;
        uint256 valued = d.vaultAdapter.valueOf(shares);
        assertGt(live, before + 80e6, "live NAV jumped");
        assertLt(valued, before + 1e6, "valuation capped at the ceiling");
    }

    function test_vaultShare_haircutApplied() public {
        _openAmplify(bob, 1_000e6, 10_000);
        address acct = address(_account(bob));
        uint256 fair = d.vaultAdapter.valueOf(d.vaultAdapter.balanceOf(acct));
        uint256 collat = d.vaultAdapter.getAssetValue(acct, "");
        assertEq(collat, (fair * 9_700) / 10_000);
    }

    function test_riskParams_rejectWeekendBufferAboveCushion() public {
        vm.expectRevert(ArrowXStockAdapter.InvalidRiskParams.selector);
        new ArrowXStockAdapter(
            address(d.pool),
            IERC4626(W_TSLAX),
            "TSLA",
            StockOracle(address(d.oracle)),
            6,
            address(this),
            3_000,
            4_000,
            1_000,
            1_000 // buffer == LT - LTV: a Friday max-LTV position would be liquidatable at close
        );
    }

    function test_wrapperPrice_includesDividendMultiplier() public {
        // A dividend accrues to the wrapper as more base tokens (wSPYx wraps
        // about 1.0057 SPYx on mainnet): its price ends up above SPY's.
        _dealStock(W_SPYX, alice, 100e18);
        address base = IERC4626(W_SPYX).asset();
        vm.prank(address(this));
        TestXStock(base).faucet(W_SPYX, 0.57e18);
        uint256 ratio = IERC4626(W_SPYX).convertToAssets(1e18);
        assertGt(ratio, 1e18);
        assertEq(d.spy.wrapperPrice(), (SPY_PX * ratio / 1e18) / 1e12);
    }

    function test_spExit_requiresCooldown() public {
        uint256 shares = d.sp.balanceOf(spDepositor);
        vm.startPrank(spDepositor);
        vm.expectRevert();
        d.sp.redeem(shares, spDepositor, spDepositor);
        d.sp.requestExit(shares);
        _warp(1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
        d.sp.redeem(shares, spDepositor, spDepositor);
        vm.stopPrank();
        assertGt(d.pool.balanceOf(spDepositor), 0);
    }

    function test_borrowCap_enforced() public {
        d.pool.setBorrowCap(500e6);
        vm.startPrank(alice);
        wtsla.approve(address(d.earn), 10e18);
        vm.expectRevert();
        d.earn.open(address(d.tsla), 10e18, 2_500); // 1,050 > 500
        vm.stopPrank();
    }
}

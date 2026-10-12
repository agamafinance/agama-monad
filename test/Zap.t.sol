// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {AgamaZapRouter} from "../src/agama/AgamaZapRouter.sol";
import {AgamaEarnRouter} from "../src/agama/AgamaEarnRouter.sol";

/// @dev Stands in for the OKX DEX aggregator: pulls the input token from the
///      caller (it is the approved spender) and pays out the stock.
contract MockDexRouter {
    IERC20 public immutable IN;
    IERC20 public immutable OUT;
    uint256 public rateOutPerIn; // OUT (1e18) per 1e6 of IN
    bool public payNothing;

    constructor(IERC20 in_, IERC20 out_, uint256 rate) {
        IN = in_;
        OUT = out_;
        rateOutPerIn = rate;
    }

    function setPayNothing(bool v) external {
        payNothing = v;
    }

    function swap(uint256 amountIn) external {
        IN.transferFrom(msg.sender, address(this), amountIn);
        if (payNothing) return;
        OUT.transfer(msg.sender, (amountIn * rateOutPerIn) / 1e6);
    }
}

contract ZapForkTest is BaseTest {
    MockDexRouter router;

    function setUp() public override {
        super.setUp();
        // 1 wTSLAx costs 420 USDC in this mock: 100 USDC -> 0.238095e18.
        // 1 wTSLAx per 420 USDC: OUT (1e18) per 1e6 of IN.
        router = new MockDexRouter(usdc, wtsla, uint256(1e18) * 1e6 / 420e6);
        _dealStock(W_TSLAX, address(router), 100e18);
        d.zap.setTarget(address(router), true);
        d.zap.setSpender(address(router), true);
        _fund(alice, 1_000e6);
    }

    function _zap(uint256 usdcIn, uint256 minOut, uint256 ltv) internal returns (uint256 bought) {
        vm.startPrank(alice);
        usdc.approve(address(d.zap), usdcIn);
        bought = d.zap
            .buyAndEarn(
                usdcIn,
                address(router),
                address(router),
                abi.encodeCall(MockDexRouter.swap, (usdcIn)),
                address(d.tsla),
                minOut,
                ltv
            );
        vm.stopPrank();
    }

    function test_buyAndEarn_opensThePositionForTheBuyer() public {
        uint256 bought = _zap(420e6, 0.99e18, 2_500);

        assertApproxEqRel(bought, 1e18, 0.001e18, "1 wTSLAx bought");
        AgamaEarnRouter.Position memory p = d.earn.position(alice, address(d.tsla));
        assertEq(p.collateral, bought, "collateral is the bought stock");
        assertApproxEqRel(p.debt, 105e6, 0.01e18, "borrowed 25% of 420 USDC");
        assertApproxEqRel(p.freeSharesValue, p.debt, 0.001e18, "borrowed USDC is in the vault");
        assertEq(usdc.balanceOf(address(d.zap)), 0, "zap holds nothing");
        assertEq(wtsla.balanceOf(address(d.zap)), 0);
        // The position belongs to Alice, not to the zap.
        assertEq(p.account, d.factory.accountOf(alice));
        assertEq(d.factory.accountOf(address(d.zap)), address(0));
    }

    function test_buyAndEarn_withoutBorrow() public {
        _zap(420e6, 0.99e18, 0);
        AgamaEarnRouter.Position memory p = d.earn.position(alice, address(d.tsla));
        assertEq(p.debt, 0);
        assertGt(p.collateral, 0);
    }

    /// @dev The approval must not sit between `expectRevert` and the call.
    function _zapExpectingRevert(uint256 usdcIn, uint256 minOut) internal {
        vm.startPrank(alice);
        usdc.approve(address(d.zap), usdcIn);
        vm.expectPartialRevert(AgamaZapRouter.TooLittleBought.selector);
        d.zap
            .buyAndEarn(
                usdcIn,
                address(router),
                address(router),
                abi.encodeCall(MockDexRouter.swap, (usdcIn)),
                address(d.tsla),
                minOut,
                2_500
            );
        vm.stopPrank();
    }

    function test_slippageGuard() public {
        _zapExpectingRevert(420e6, 2e18); // asking for 2 wTSLAx out of 420 USDC
        assertEq(usdc.balanceOf(alice), 1_000e6, "no USDC lost");
    }

    function test_routeThatPaysNothing_reverts() public {
        router.setPayNothing(true);
        _zapExpectingRevert(420e6, 0.99e18);
        assertEq(usdc.balanceOf(alice), 1_000e6, "no USDC lost");
    }

    function test_onlyAllowlistedTargetsAndSpenders() public {
        address evil = makeAddr("evil");
        vm.startPrank(alice);
        usdc.approve(address(d.zap), 420e6);
        vm.expectRevert(abi.encodeWithSelector(AgamaZapRouter.TargetNotAllowed.selector, evil));
        d.zap.buyAndEarn(420e6, evil, address(router), "", address(d.tsla), 1, 0);
        vm.expectRevert(abi.encodeWithSelector(AgamaZapRouter.SpenderNotAllowed.selector, evil));
        d.zap.buyAndEarn(420e6, address(router), evil, "", address(d.tsla), 1, 0);
        vm.stopPrank();
    }

    function test_openFor_onlyCallableByAZap() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgamaEarnRouter.NotAZap.selector, alice));
        d.earn.openFor(alice, address(d.tsla), 1e18, 2_500);
    }

    function test_governorControlsTheAllowlists() public {
        vm.prank(alice);
        vm.expectRevert();
        d.zap.setTarget(address(router), false);
        vm.prank(alice);
        vm.expectRevert();
        d.earn.setZap(alice, true);
    }
}

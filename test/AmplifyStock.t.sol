// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "./Base.t.sol";
import {AgamaAccount} from "../src/agama/AgamaAccount.sol";

/// @dev Stands in for the OKX DEX aggregator, both ways, at a price this test
///      sets. It is the approved spender, so it pulls what it is selling.
contract TwoWayDex {
    IERC20 public immutable USDC;
    IERC20 public immutable STOCK;
    /// USDC (1e6) for one whole stock (1e18).
    uint256 public price;

    constructor(IERC20 usdc_, IERC20 stock_, uint256 price_) {
        USDC = usdc_;
        STOCK = stock_;
        price = price_;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function buy(uint256 usdcIn) external {
        USDC.transferFrom(msg.sender, address(this), usdcIn);
        STOCK.transfer(msg.sender, (usdcIn * 1e18) / price);
    }

    function sell(uint256 stockIn) external {
        STOCK.transferFrom(msg.sender, address(this), stockIn);
        USDC.transfer(msg.sender, (stockIn * price) / 1e18);
    }
}

/// @notice Amplify on the stock itself: borrow against it, buy more of it, and
///         do it again. What the loop can reach is set by the market's LTV
///         ceiling, not by how many times it goes round.
contract AmplifyStockTest is BaseTest {
    TwoWayDex dex;

    /// TSLA is 420 USDC in this fixture, and the market's ceiling is 30%.
    uint256 internal constant PX = 420e6;

    function setUp() public override {
        super.setUp();
        dex = new TwoWayDex(usdc, wtsla, PX);
        _dealStock(W_TSLAX, address(dex), 1_000e18);
        deal(USDC, address(dex), 1_000_000e6);
        d.zap.setTarget(address(dex), true);
        d.zap.setSpender(address(dex), true);
    }

    // ---- helpers --------------------------------------------------------------------

    function _buyHop(uint256 usdcIn) internal view returns (AgamaAccount.Hop memory) {
        return AgamaAccount.Hop({
            amount: usdcIn,
            swapTarget: address(dex),
            swapSpender: address(dex),
            swapData: abi.encodeCall(TwoWayDex.buy, (usdcIn)),
            // 1% under the quote, the way a front would size it.
            minOut: ((usdcIn * 1e18) / PX) * 99 / 100
        });
    }

    function _sellHop(uint256 stockIn) internal view returns (AgamaAccount.Hop memory) {
        return AgamaAccount.Hop({
            amount: stockIn,
            swapTarget: address(dex),
            swapSpender: address(dex),
            swapData: abi.encodeCall(TwoWayDex.sell, (stockIn)),
            minOut: ((stockIn * PX) / 1e18) * 99 / 100
        });
    }

    /// @dev What the front computes: borrow up to the ceiling each time, leaving
    ///      half a percent of room, and stop when the position is at `target`.
    function _plan(uint256 stock, uint256 targetLeverageBps)
        internal
        view
        returns (AgamaAccount.Hop[] memory hops)
    {
        uint256 maxLtv = d.tsla.MAX_LTV();
        uint256 value = (stock * PX) / 1e18;
        uint256 wanted = (value * targetLeverageBps) / 10_000;
        AgamaAccount.Hop[] memory tmp = new AgamaAccount.Hop[](8);
        uint256 n;
        uint256 debt;
        while (n < 8 && value + 1e6 < wanted) {
            uint256 room = ((value * maxLtv) / 10_000);
            if (room <= debt) break;
            uint256 borrow = ((room - debt) * 995) / 1_000;
            uint256 need = wanted - value;
            if (borrow > need) borrow = need;
            if (borrow < 1e6) break;
            tmp[n] = _buyHop(borrow);
            debt += borrow;
            value += borrow;
            ++n;
        }
        hops = new AgamaAccount.Hop[](n);
        for (uint256 i; i < n; ++i) {
            hops[i] = tmp[i];
        }
    }

    function _open(uint256 stock, uint256 leverageBps) internal returns (uint256 debt) {
        vm.startPrank(alice);
        wtsla.approve(address(d.amplify), stock);
        debt = d.amplify.openStock(address(d.tsla), stock, _plan(stock, leverageBps));
        vm.stopPrank();
    }

    function _collateral() internal view returns (uint256) {
        return d.tsla.getInternalBalance(address(_account(alice)), "");
    }

    // ---- the loop -------------------------------------------------------------------

    function test_open_turns_ten_stock_into_thirteen() public {
        uint256 debt = _open(10e18, 13_300);

        uint256 held = _collateral();
        assertGt(held, 13e18, "the loop bought more of the same stock");
        assertLt(held, 13.4e18, "and stopped at the level asked for");
        assertGt(debt, 0, "against USDC borrowed on Arrow");

        // A leveraged position is still a safe one: the pool would have refused
        // the borrow otherwise, and this is the margin it left.
        uint256 hf = d.pool.calculateHealthFactor(address(d.tsla), address(_account(alice)), "");
        assertGt(hf, 1.15e27, "above the soft deleverage trigger");
    }

    function test_the_agents_hold_the_level_the_loop_reached() public {
        _open(10e18, 13_300);
        AgamaAccount account = _account(alice);
        uint256 target = account.targetLtvBps(address(d.tsla));
        // A loop at L times carries an LTV of (L - 1) / L: 1.33x is 24.8%, and
        // the market's 30% ceiling is 1.43x. That is the whole relation, and it
        // is why an equity cannot be looped to 3x without raising the ceiling.
        uint256 expected = 10_000 - (uint256(10_000) * 10_000) / 13_300;
        assertApproxEqAbs(target, expected, 60, "(L - 1) / L");
    }

    /// The ceiling is the market's, so asking for more than the LTV allows
    /// gets what the LTV allows, not a revert and not a riskier position.
    function test_the_ltv_ceiling_is_what_bounds_the_leverage() public {
        _open(10e18, 30_000); // 3x, which an equity at 30% LTV cannot reach
        uint256 held = _collateral();
        assertLt(held, 15e18, "1.43x is the mathematical ceiling at a 30% LTV");
        assertGt(held, 13e18, "and the loop got most of the way there");
    }

    // ---- the way out ----------------------------------------------------------------

    function test_close_sells_its_way_out_and_returns_the_stock() public {
        _open(10e18, 13_300);
        uint256 debt = d.pool.getPositionScaledDebt(address(d.tsla), address(_account(alice)), "");

        // Sell a little over the debt, in two hops, the way a front would.
        uint256 toSell = ((debt + 5e6) * 1e18) / PX;
        AgamaAccount.Hop[] memory out = new AgamaAccount.Hop[](2);
        out[0] = _sellHop(toSell / 2);
        out[1] = _sellHop(toSell - toSell / 2);

        vm.prank(alice);
        d.amplify.closeStock(address(d.tsla), out, false);

        assertEq(_collateral(), 0, "nothing pledged");
        assertEq(
            d.pool.getPositionScaledDebt(address(d.tsla), address(_account(alice)), ""), 0, "nothing owed"
        );
        // Ten in, and what the leverage earned or cost, less the spread paid to
        // the venue on the way in and the way out.
        assertGt(wtsla.balanceOf(alice), 9.8e18, "the stock came back");
    }

    function test_close_refuses_to_half_unwind() public {
        _open(10e18, 13_300);
        AgamaAccount.Hop[] memory out = new AgamaAccount.Hop[](1);
        out[0] = _sellHop(0.1e18); // nowhere near the debt

        vm.prank(alice);
        // The shortfall is whatever is left; that it reverts at all is the point.
        vm.expectPartialRevert(AgamaAccount.InsufficientToRepay.selector);
        d.amplify.closeStock(address(d.tsla), out, false);
    }

    // ---- what the loop refuses ------------------------------------------------------

    function test_open_refuses_a_venue_nobody_allowlisted() public {
        TwoWayDex rogue = new TwoWayDex(usdc, wtsla, PX);
        _dealStock(W_TSLAX, address(rogue), 100e18);

        AgamaAccount.Hop[] memory hops = new AgamaAccount.Hop[](1);
        hops[0] = AgamaAccount.Hop({
            amount: 100e6,
            swapTarget: address(rogue),
            swapSpender: address(rogue),
            swapData: abi.encodeCall(TwoWayDex.buy, (100e6)),
            minOut: 0
        });

        vm.startPrank(alice);
        wtsla.approve(address(d.amplify), 10e18);
        vm.expectRevert(abi.encodeWithSelector(AgamaAccount.SwapTargetNotAllowed.selector, address(rogue)));
        d.amplify.openStock(address(d.tsla), 10e18, hops);
        vm.stopPrank();
    }

    /// The caller sets `minOut`, so the caller can set it to nothing. The check
    /// that actually protects the position is the oracle's.
    function test_open_refuses_a_route_that_underdelivers() public {
        dex.setPrice(PX * 2); // half the stock for the same USDC

        AgamaAccount.Hop[] memory hops = new AgamaAccount.Hop[](1);
        hops[0] = AgamaAccount.Hop({
            amount: 1_000e6,
            swapTarget: address(dex),
            swapSpender: address(dex),
            swapData: abi.encodeCall(TwoWayDex.buy, (1_000e6)),
            minOut: 0
        });

        vm.startPrank(alice);
        wtsla.approve(address(d.amplify), 10e18);
        vm.expectPartialRevert(AgamaAccount.CompoundPriceTooBad.selector);
        d.amplify.openStock(address(d.tsla), 10e18, hops);
        vm.stopPrank();
    }

    function test_close_refuses_a_route_that_dumps_the_stock() public {
        _open(10e18, 13_300);
        dex.setPrice(PX / 2); // half the USDC for the same stock

        AgamaAccount.Hop[] memory out = new AgamaAccount.Hop[](1);
        out[0] = AgamaAccount.Hop({
            amount: 1e18,
            swapTarget: address(dex),
            swapSpender: address(dex),
            swapData: abi.encodeCall(TwoWayDex.sell, (1e18)),
            minOut: 0
        });

        vm.prank(alice);
        vm.expectPartialRevert(AgamaAccount.CompoundPriceTooBad.selector);
        d.amplify.closeStock(address(d.tsla), out, false);
    }

    /// Closing one market must not take the buffer another one is relying on.
    /// The loop's close ends on the Earn path, which used to hand every free
    /// vault share back to the owner whichever market it was closing.
    function test_closing_one_market_leaves_the_other_its_buffer() public {
        // An Earn position on SPY, whose borrow becomes the account's buffer.
        _dealStock(W_SPYX, alice, 5e18);
        vm.startPrank(alice);
        wspy.approve(address(d.earn), 5e18);
        d.earn.open(address(d.spy), 5e18, 2_500);
        vm.stopPrank();

        AgamaAccount account = _account(alice);
        uint256 bufferBefore = account.redeemableUsdc();
        assertGt(bufferBefore, 0, "SPY borrowed into the buffer");

        // Now a TSLA loop, opened and unwound.
        _open(10e18, 13_300);
        uint256 debt = d.pool.getPositionScaledDebt(address(d.tsla), address(_account(alice)), "");
        uint256 toSell = ((debt + 5e6) * 1e18) / PX;
        AgamaAccount.Hop[] memory out = new AgamaAccount.Hop[](2);
        out[0] = _sellHop(toSell / 2);
        out[1] = _sellHop(toSell - toSell / 2);
        vm.prank(alice);
        d.amplify.closeStock(address(d.tsla), out, false);

        assertGt(account.redeemableUsdc(), (bufferBefore * 99) / 100, "SPY still has its buffer");
        // And SPY can still close on it, which is the point.
        vm.prank(alice);
        d.earn.close(address(d.spy));
        assertGe(wspy.balanceOf(alice), 5e18, "SPY closed on its own buffer");
    }

    /// The OKX rail: the token a withdrawal delivers goes straight in.
    function test_open_from_the_base_token_an_okx_withdrawal_sends() public {
        address base = address(d.tsla.getAssetToken());
        // Unwrap alice's holding to get the base token she would have received.
        vm.startPrank(alice);
        uint256 got = IERC4626Minimal(base).redeem(10e18, alice, alice);
        IERC20(IERC4626Minimal(base).asset()).approve(address(d.amplify), got);
        d.amplify.openStockWithBase(address(d.tsla), got, new AgamaAccount.Hop[](0));
        vm.stopPrank();

        assertGt(_collateral(), 0, "the base token was wrapped on the way in");
    }
}

interface IERC4626Minimal {
    function asset() external view returns (address);
    function redeem(uint256 shares, address to, address from) external returns (uint256);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {BaseTest} from "./Base.t.sol";
import {AgamaAccount} from "../src/agama/AgamaAccount.sol";
import {TestXStock} from "../src/mocks/TestnetTokens.sol";
import {KuruVenue, IKuruOrderBook} from "../src/venues/KuruVenue.sol";
import {KuruListing, IKuruMarginAccount, IKuruMaker} from "../src/venues/KuruListing.sol";

/// @notice Against the real Kuru deployment on Monad testnet: a market listed
///         through Kuru's own Router, quoted by a maker, traded through the
///         venue and through an Amplify loop end to end.
///
///         Needs the network, so it only runs when asked:
///           MONAD_FORK=true forge test --match-contract KuruVenueForkTest
contract KuruVenueForkTest is BaseTest {
    KuruVenue venue;
    IKuruOrderBook market;
    address maker = makeAddr("maker");
    bool live;

    /// TSLA is 420 USDC in this fixture: the maker quotes a cent either side.
    uint256 internal constant PX = 420e6;

    modifier onlyFork() {
        vm.skip(!live);
        _;
    }

    function setUp() public override {
        live = vm.envOr("MONAD_FORK", false);
        if (!live) return;
        vm.createSelectFork("monad_testnet");
        super.setUp();

        address base = IERC4626(W_TSLAX).asset();
        market = IKuruOrderBook(KuruListing.list(base, USDC));
        venue = new KuruVenue(usdc, address(this));
        venue.setMarket(W_TSLAX, market);
        d.zap.setTarget(address(venue), true);
        d.zap.setSpender(address(venue), true);

        _quote(base, 50e18);
    }

    /// @dev Four levels a side, 50 shares each, a cent apart from 420.01 up and
    ///      419.99 down: the depth a keeper's quotes give the demo.
    function _quote(address base, uint256 sizePerLevel) internal {
        for (uint256 i; i < 3; ++i) {
            TestXStock(base).faucet(maker, 100e18);
        }
        deal(USDC, maker, 1_000_000e6);
        vm.startPrank(maker);
        IERC20(base).approve(KuruListing.MARGIN_ACCOUNT, type(uint256).max);
        usdc.approve(KuruListing.MARGIN_ACCOUNT, type(uint256).max);
        IKuruMarginAccount(KuruListing.MARGIN_ACCOUNT).deposit(maker, base, 300e18);
        IKuruMarginAccount(KuruListing.MARGIN_ACCOUNT).deposit(maker, USDC, 1_000_000e6);

        uint32[] memory bids = new uint32[](4);
        uint32[] memory asks = new uint32[](4);
        uint96[] memory sizes = new uint96[](4);
        for (uint256 i; i < 4; ++i) {
            bids[i] = KuruListing.toBookPrice(PX - 0.01e6 - i * 0.01e6);
            asks[i] = KuruListing.toBookPrice(PX + 0.01e6 + i * 0.01e6);
            sizes[i] = KuruListing.toBookSize(sizePerLevel);
        }
        IKuruMaker(address(market)).batchUpdate(bids, sizes, asks, sizes, new uint40[](0), true);
        vm.stopPrank();
    }

    // ---- the venue on its own -------------------------------------------------------

    function test_buy_on_the_book_and_wrap() public onlyFork {
        uint256 before = usdc.balanceOf(bob);
        vm.startPrank(bob);
        usdc.approve(address(venue), 1_000e6);
        uint256 shares = venue.buy(W_TSLAX, 1_000e6, 0);
        vm.stopPrank();

        // 1,000 USDC at 420.01: 2.3808 shares, to the book's ten-thousandth.
        assertApproxEqAbs(shares, uint256(1_000e6 * 1e18) / 420.01e6, 1e14, "bought at the best ask");
        assertEq(wtsla.balanceOf(bob), shares, "wrapped and sent to the caller");
        assertGt(usdc.balanceOf(bob), before - 1_000e6 - 1, "spent, with only the sub-cent dust back");
        assertLt(usdc.balanceOf(bob), before - 1_000e6 + 0.01e6);
        assertEq(usdc.balanceOf(address(venue)), 0, "nothing left behind");
    }

    function test_sell_on_the_book_and_unwrap() public onlyFork {
        _dealStock(W_TSLAX, bob, 2e18);
        uint256 before = usdc.balanceOf(bob);
        vm.startPrank(bob);
        wtsla.approve(address(venue), 2e18);
        uint256 out = venue.sell(W_TSLAX, 2e18, 839e6);
        vm.stopPrank();

        assertEq(out, 839.98e6, "two shares at the best bid, 419.99");
        assertEq(usdc.balanceOf(bob), before + out);
        assertEq(wtsla.balanceOf(bob), 0);
        assertEq(IERC20(IERC4626(W_TSLAX).asset()).balanceOf(address(venue)), 0, "nothing left behind");
    }

    function test_buy_respects_the_floor() public onlyFork {
        _fund(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(venue), 1_000e6);
        vm.expectPartialRevert(KuruVenue.TooLittleOut.selector);
        venue.buy(W_TSLAX, 1_000e6, 3e18);
        vm.stopPrank();
    }

    function test_market_must_trade_the_wrappers_base_against_usdc() public onlyFork {
        vm.expectRevert(abi.encodeWithSelector(KuruVenue.MarketMismatch.selector, address(market)));
        venue.setMarket(W_SPYX, market);
    }

    // ---- Amplify, end to end through Kuru -------------------------------------------

    function _buyHop(uint256 usdcIn) internal view returns (AgamaAccount.Hop memory) {
        return AgamaAccount.Hop({
            amount: usdcIn,
            swapTarget: address(venue),
            swapSpender: address(venue),
            swapData: abi.encodeCall(KuruVenue.buy, (W_TSLAX, usdcIn, 0)),
            minOut: ((usdcIn * 1e18) / PX) * 99 / 100
        });
    }

    function _sellHop(uint256 stockIn) internal view returns (AgamaAccount.Hop memory) {
        return AgamaAccount.Hop({
            amount: stockIn,
            swapTarget: address(venue),
            swapSpender: address(venue),
            swapData: abi.encodeCall(KuruVenue.sell, (W_TSLAX, stockIn, 0)),
            minOut: ((stockIn * PX) / 1e18) * 99 / 100
        });
    }

    function test_amplify_loops_and_unwinds_through_kuru() public onlyFork {
        // 10 TSLA at 420 = 4,200; two hops of borrow-and-buy, under the 30% ceiling.
        AgamaAccount.Hop[] memory hops = new AgamaAccount.Hop[](2);
        hops[0] = _buyHop(1_200e6);
        hops[1] = _buyHop(150e6);
        vm.startPrank(alice);
        wtsla.approve(address(d.amplify), 10e18);
        uint256 debt = d.amplify.openStock(address(d.tsla), 10e18, hops);
        vm.stopPrank();

        uint256 held = d.tsla.getInternalBalance(address(_account(alice)), "");
        assertGt(held, 13.2e18, "the loop bought more of the same stock on Kuru");
        assertGt(debt, 1_349e6, "against USDC borrowed on Arrow");

        uint256 owed = d.pool.getPositionScaledDebt(address(d.tsla), address(_account(alice)), "");
        uint256 toSell = ((owed + 5e6) * 1e18) / 419.9e6;
        AgamaAccount.Hop[] memory out = new AgamaAccount.Hop[](1);
        out[0] = _sellHop(toSell);
        vm.prank(alice);
        d.amplify.closeStock(address(d.tsla), out, false);

        assertEq(d.tsla.getInternalBalance(address(_account(alice)), ""), 0, "nothing pledged");
        assertEq(
            d.pool.getPositionScaledDebt(address(d.tsla), address(_account(alice)), ""), 0, "nothing owed"
        );
        assertGt(wtsla.balanceOf(alice), 9.9e18, "the stock came back, less a cent of spread each way");
    }
}

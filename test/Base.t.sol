// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Deployer} from "../script/Deployer.sol";
import {AgamaAccount} from "../src/agama/AgamaAccount.sol";
import {TestUSDC, TestXStock, TestXStockWrapper} from "../src/mocks/TestnetTokens.sol";
import {MockVerifierProxy} from "./Oracle.t.sol";

/// @notice The full Arrow x Agama deployment, as the testnet script wires it,
///         on the testnet stand-ins for USDC and the wrapped xStocks.
abstract contract BaseTest is Test, Deployer {
    Deployment internal d;

    address internal keeper = makeAddr("keeper");
    address internal treasury = makeAddr("treasury");
    address internal lender = makeAddr("lender");
    address internal spDepositor = makeAddr("spDepositor");
    address internal alice = makeAddr("alice"); // Earn user (TSLA holder)
    address internal bob = makeAddr("bob"); // Amplify user
    address internal liquidator = makeAddr("liquidator");

    address internal USDC;
    address internal W_TSLAX;
    address internal W_NVDAX;
    address internal W_SPYX;
    address internal W_AAPLX;
    IERC20 internal usdc;
    IERC20 internal wtsla;
    IERC20 internal wspy;

    uint256 internal constant TSLA_PX = 420e18;
    uint256 internal constant NVDA_PX = 180e18;
    uint256 internal constant SPY_PX = 660e18;
    uint256 internal constant AAPL_PX = 250e18;

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        USDC = address(new TestUSDC());
        W_TSLAX = address(_pair("TSLA"));
        W_NVDAX = address(_pair("NVDA"));
        W_SPYX = address(_pair("SPY"));
        W_AAPLX = address(_pair("AAPL"));
        usdc = IERC20(USDC);
        wtsla = IERC20(W_TSLAX);
        wspy = IERC20(W_SPYX);
        Config memory cfg = Config({
            admin: address(this),
            keeper: keeper,
            guardian: address(this),
            treasury: treasury,
            supplyCapUsdc: 1_000_000e6,
            borrowCapUsdc: 500_000e6,
            spCooldown: 1 days,
            assets: Assets({
                usdc: USDC,
                wTsla: W_TSLAX,
                wNvda: W_NVDAX,
                wSpy: W_SPYX,
                wAapl: W_AAPLX,
                verifierProxy: address(new MockVerifierProxy())
            })
        });
        d = _deployAll(cfg);

        _pushAll(true);

        // Lenders supply USDC to Arrow; part of it is staked in the SP.
        _fund(lender, 20_000e6);
        vm.startPrank(lender);
        usdc.approve(address(d.pool), type(uint256).max);
        d.pool.deposit(20_000e6, lender);
        vm.stopPrank();

        _fund(spDepositor, 5_000e6);
        vm.startPrank(spDepositor);
        usdc.approve(address(d.sp), type(uint256).max);
        d.sp.depositUSDC(5_000e6, spDepositor);
        vm.stopPrank();

        _dealStock(W_TSLAX, alice, 10e18);
        _fund(bob, 5_000e6);
    }

    // ---- helpers ----------------------------------------------------------------------

    /// @dev `block.timestamp` is cached under via-IR inside one test
    ///      function; always read the warped time through the cheatcode.
    function _warp(uint256 dt) internal returns (uint256 t) {
        t = vm.getBlockTimestamp() + dt;
        vm.warp(t);
    }

    function _pair(string memory ticker) internal returns (TestXStockWrapper) {
        TestXStock base = new TestXStock(string.concat("Test ", ticker), string.concat(ticker, "x"));
        return new TestXStockWrapper(base, string.concat("Wrapped ", ticker), string.concat("w", ticker, "x"));
    }

    /// @dev Wrapped stock backed one for one, as a real wrapper would be:
    ///      `deal` on the wrapper alone would leave its shares unbacked.
    function _dealStock(address wrapper, address who, uint256 amount) internal {
        while (amount > 0) {
            uint256 step = amount > 100e18 ? 100e18 : amount;
            TestXStockWrapper(wrapper).faucet(who, step);
            amount -= step;
        }
    }

    function _fund(address who, uint256 amount) internal {
        deal(USDC, who, usdc.balanceOf(who) + amount);
    }

    function _pushAll(bool open) internal {
        vm.startPrank(keeper);
        uint64 t = uint64(vm.getBlockTimestamp());
        d.oracle.push("TSLA", TSLA_PX, t, open);
        d.oracle.push("NVDA", NVDA_PX, t, open);
        d.oracle.push("SPY", SPY_PX, t, open);
        d.oracle.push("AAPL", AAPL_PX, t, open);
        vm.stopPrank();
    }

    /// @dev Moves a price in steps that respect the keeper deviation cap.
    function _walkPrice(bytes32 ticker, uint256 target, bool open) internal {
        uint256 cur = d.oracle.feed(ticker).price;
        while (cur != target) {
            uint256 next;
            if (target < cur) {
                uint256 floor = (cur * 8_600) / 10_000;
                next = target < floor ? floor : target;
            } else {
                uint256 ceil = (cur * 11_400) / 10_000;
                next = target > ceil ? ceil : target;
            }
            uint256 t = vm.getBlockTimestamp() + 60;
            vm.warp(t);
            vm.prank(keeper);
            d.oracle.push(ticker, next, uint64(t), open);
            cur = next;
        }
    }

    function _settleYield(uint256 usdcAmount) internal {
        _fund(keeper, usdcAmount);
        vm.startPrank(keeper);
        usdc.transfer(address(d.queue), usdcAmount);
        d.queue.settleYield(usdcAmount);
        vm.stopPrank();
    }

    function _account(address user) internal view returns (AgamaAccount) {
        return AgamaAccount(d.factory.accountOf(user));
    }

    function _openEarn(address user, uint256 amount, uint256 ltvBps) internal returns (uint256 borrowed) {
        vm.startPrank(user);
        wtsla.approve(address(d.earn), amount);
        borrowed = d.earn.open(address(d.tsla), amount, ltvBps);
        vm.stopPrank();
    }

    function _openAmplify(address user, uint256 amount, uint256 levBps) internal returns (uint256 debt) {
        vm.startPrank(user);
        usdc.approve(address(d.amplify), amount);
        debt = d.amplify.open(amount, levBps);
        vm.stopPrank();
    }
}

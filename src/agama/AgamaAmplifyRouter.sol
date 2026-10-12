// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {AgamaAccount} from "./AgamaAccount.sol";
import {IArrowAdapter} from "../arrow/adapters/IArrowAdapter.sol";
import {AgamaAccountFactory} from "./AgamaAccountFactory.sol";
import {ArrowVaultShareAdapter} from "../arrow/adapters/ArrowVaultShareAdapter.sol";
import {IArrowPool} from "../interfaces/IArrowPool.sol";

/// @title AgamaAmplifyRouter
/// @notice Amplify: the Agama vault yield, looped on Arrow, capped at 3x.
///
///         net APY = vaultAPY + (L - 1) * (vaultAPY - borrowAPR)
///
///         Break-even is borrowAPR = vaultAPY; every extra point of borrow
///         rate costs (L - 1) points. `AgamaAccount.autoUnwind` enforces the
///         spread guard on-chain.
contract AgamaAmplifyRouter {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant RAY = 1e27;

    AgamaAccountFactory public immutable FACTORY;
    IArrowPool public immutable POOL;
    ArrowVaultShareAdapter public immutable VAULT_ADAPTER;
    IERC20 public immutable USDC;

    event Opened(address indexed user, uint256 usdc, uint256 leverageBps, uint256 debt);
    event Closed(address indexed user, bool redeemed);
    event StockOpened(address indexed user, address indexed adapter, uint256 stockIn, uint256 debt);
    event StockClosed(address indexed user, address indexed adapter);

    constructor(AgamaAccountFactory factory, IArrowPool pool, ArrowVaultShareAdapter vaultAdapter) {
        FACTORY = factory;
        POOL = pool;
        VAULT_ADAPTER = vaultAdapter;
        USDC = IERC20(pool.asset());
    }

    /// @param usdc        USDC to put to work.
    /// @param leverageBps 10_000 = 1x ... 30_000 = 3x.
    function open(uint256 usdc, uint256 leverageBps) external returns (uint256 debt) {
        address account = FACTORY.getOrCreate(msg.sender);
        USDC.safeTransferFrom(msg.sender, account, usdc);
        debt = AgamaAccount(account).amplifyOpen(msg.sender, usdc, false, leverageBps);
        emit Opened(msg.sender, usdc, leverageBps, debt);
    }

    /// @notice Stack Amplify on the vault shares an Earn position produced.
    function openFromEarn(uint256 leverageBps) external returns (uint256 debt) {
        address account = FACTORY.accountOf(msg.sender);
        debt = AgamaAccount(account).amplifyOpen(msg.sender, 0, true, leverageBps);
        emit Opened(msg.sender, 0, leverageBps, debt);
    }

    /// @notice Leveraged stock: the loop buys more of what you deposited.
    /// @param stockAmount Wrapped stock, approved to this router.
    /// @param hops One borrow-buy-deposit hop each, with the swap for it.
    function openStock(address adapter, uint256 stockAmount, AgamaAccount.Hop[] calldata hops)
        external
        returns (uint256 debt)
    {
        address account = FACTORY.getOrCreate(msg.sender);
        IERC20(IArrowAdapter(adapter).getAssetToken()).safeTransferFrom(msg.sender, account, stockAmount);
        debt = AgamaAccount(account).amplifyStockOpen(msg.sender, adapter, stockAmount, hops);
        emit StockOpened(msg.sender, adapter, stockAmount, debt);
    }

    /// @notice The same, starting from the base xStock an OKX withdrawal sends.
    function openStockWithBase(address adapter, uint256 baseAmount, AgamaAccount.Hop[] calldata hops)
        external
        returns (uint256 debt)
    {
        IERC4626 wrapper = IERC4626(IArrowAdapter(adapter).getAssetToken());
        IERC20 base = IERC20(wrapper.asset());
        base.safeTransferFrom(msg.sender, address(this), baseAmount);
        base.forceApprove(address(wrapper), baseAmount);
        uint256 wrapped = wrapper.deposit(baseAmount, address(this));

        address account = FACTORY.getOrCreate(msg.sender);
        IERC20(address(wrapper)).safeTransfer(account, wrapped);
        debt = AgamaAccount(account).amplifyStockOpen(msg.sender, adapter, wrapped, hops);
        emit StockOpened(msg.sender, adapter, wrapped, debt);
    }

    /// @param unwrap Hand back the base xStock, the form an OKX deposit takes.
    function closeStock(address adapter, AgamaAccount.Hop[] calldata hops, bool unwrap) external {
        AgamaAccount(FACTORY.accountOf(msg.sender)).amplifyStockClose(msg.sender, adapter, hops, unwrap);
        emit StockClosed(msg.sender, adapter);
    }

    function close(bool redeemToUsdc) external {
        AgamaAccount(FACTORY.accountOf(msg.sender)).amplifyClose(msg.sender, redeemToUsdc);
        emit Closed(msg.sender, redeemToUsdc);
    }

    // ---- Views for the front ------------------------------------------------------

    /// @notice Net APY at `leverageBps` for a given vault APY (RAY), using
    ///         the live Arrow borrow rate. Signed: a negative carry shows.
    function netApyRay(uint256 vaultApyRay, uint256 leverageBps) public view returns (int256) {
        int256 borrowRate = int256(POOL.getReserveState().currentBorrowRate);
        int256 v = int256(vaultApyRay);
        int256 extra = int256(leverageBps) - int256(BPS);
        return v + (extra * (v - borrowRate)) / int256(BPS);
    }

    struct Position {
        address account;
        uint256 pledgedShares;
        uint256 exposure; // USDC units, fair value of pledged shares
        uint256 debt;
        uint256 equity;
        uint256 leverageBps;
        uint256 healthFactorRay;
        uint256 borrowRateRay;
        uint256 vaultApyRay;
    }

    function position(address user) external view returns (Position memory p) {
        p.account = FACTORY.accountOf(user);
        p.borrowRateRay = POOL.getReserveState().currentBorrowRate;
        p.vaultApyRay = VAULT_ADAPTER.realizedApyRay();
        if (p.account == address(0)) return p;
        p.pledgedShares = VAULT_ADAPTER.balanceOf(p.account);
        p.exposure = VAULT_ADAPTER.valueOf(p.pledgedShares);
        p.debt = POOL.getPositionScaledDebt(address(VAULT_ADAPTER), p.account, "");
        p.equity = p.exposure > p.debt ? p.exposure - p.debt : 0;
        p.leverageBps = p.equity == 0 ? 0 : (p.exposure * BPS) / p.equity;
        p.healthFactorRay = POOL.calculateHealthFactor(address(VAULT_ADAPTER), p.account, "");
    }
}

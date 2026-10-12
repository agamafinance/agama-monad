// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {AgamaAccount} from "./AgamaAccount.sol";
import {AgamaAccountFactory} from "./AgamaAccountFactory.sol";
import {IArrowAdapter} from "../arrow/adapters/IArrowAdapter.sol";
import {IArrowPool} from "../interfaces/IArrowPool.sol";

/// @title AgamaEarnRouter
/// @notice "Earn on your stocks", one transaction each way.
///
///         open:  wrapped xStock in -> Arrow borrow USDC at `ltvBps` of the
///                stock value -> USDC into the Agama vault. The user keeps
///                the stock exposure and earns (vault APY - borrow APR) on
///                the borrowed amount.
///         close: repay from the vault shares, stock back to the wallet,
///                leftover yield sent as vault shares.
///
///         OKX rails: withdrawing a tokenized stock from the OKX app to X Layer
///         delivers the BASE xStock (TSLAx), not the ERC-4626 wrapper the
///         markets take as collateral. `openWithBase` wraps it on the way in,
///         and `close(..., unwrap = true)` hands the base token back, which is
///         what a deposit to OKX expects. One transaction each way, no manual
///         wrapping step.
contract AgamaEarnRouter is AccessControl {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;

    AgamaAccountFactory public immutable FACTORY;
    IArrowPool public immutable POOL;
    IERC20 public immutable USDC;

    event Opened(
        address indexed user, address indexed adapter, uint256 amount, uint256 ltvBps, uint256 borrowed
    );
    event Closed(address indexed user, address indexed adapter);

    error LtvTooHigh(uint256 ltvBps, uint256 maxLtvBps);
    error MarketClosed();
    error NotAZap(address caller);

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    /// @notice Contracts allowed to open a position on behalf of a user
    ///         (AgamaZapRouter: buy the stock and open Earn in one call).
    mapping(address zap => bool) public isZap;

    event ZapSet(address indexed zap, bool allowed);

    constructor(AgamaAccountFactory factory, IArrowPool pool, address admin) {
        FACTORY = factory;
        POOL = pool;
        USDC = IERC20(pool.asset());
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    function setZap(address zap, bool allowed) external onlyRole(GOVERNOR_ROLE) {
        isZap[zap] = allowed;
        emit ZapSet(zap, allowed);
    }

    /// @param adapter Arrow xStock adapter (e.g. the wTSLAx market).
    /// @param amount  Wrapped xStock amount (18 decimals).
    /// @param ltvBps  Borrow as a share of the stock value (2_500 = 25%).
    function open(address adapter, uint256 amount, uint256 ltvBps) external returns (uint256 borrowed) {
        uint256 maxLtv = IArrowAdapter(adapter).MAX_LTV();
        if (ltvBps > maxLtv) revert LtvTooHigh(ltvBps, maxLtv);
        if (ltvBps > 0 && !IArrowAdapter(adapter).borrowAllowed()) revert MarketClosed();
        address account = FACTORY.getOrCreate(msg.sender);
        IERC20(IArrowAdapter(adapter).getAssetToken()).safeTransferFrom(msg.sender, account, amount);
        borrowed = (IArrowAdapter(adapter).valueOf(amount) * ltvBps) / BPS;
        AgamaAccount(account).earnOpen(msg.sender, adapter, amount, borrowed);
        emit Opened(msg.sender, adapter, amount, ltvBps, borrowed);
    }

    /// @notice Same as `open`, for `user`, called by an allowlisted zap that
    ///         already holds the stock tokens. The position belongs to `user`.
    function openFor(address user, address adapter, uint256 amount, uint256 ltvBps)
        external
        returns (uint256 borrowed)
    {
        if (!isZap[msg.sender]) revert NotAZap(msg.sender);
        uint256 maxLtv = IArrowAdapter(adapter).MAX_LTV();
        if (ltvBps > maxLtv) revert LtvTooHigh(ltvBps, maxLtv);
        if (ltvBps > 0 && !IArrowAdapter(adapter).borrowAllowed()) revert MarketClosed();
        address account = FACTORY.getOrCreate(user);
        IERC20(IArrowAdapter(adapter).getAssetToken()).safeTransferFrom(msg.sender, account, amount);
        borrowed = (IArrowAdapter(adapter).valueOf(amount) * ltvBps) / BPS;
        AgamaAccount(account).earnOpen(user, adapter, amount, borrowed);
        emit Opened(user, adapter, amount, ltvBps, borrowed);
    }

    /// @notice Open with the BASE xStock, the token an OKX withdrawal sends
    ///         (TSLAx, NVDAx, ...). It is wrapped here, then used as collateral.
    /// @param baseAmount Amount of the base xStock (18 decimals).
    function openWithBase(address adapter, uint256 baseAmount, uint256 ltvBps)
        external
        returns (uint256 borrowed)
    {
        IERC4626 wrapper = IERC4626(IArrowAdapter(adapter).getAssetToken());
        IERC20 base = IERC20(wrapper.asset());
        base.safeTransferFrom(msg.sender, address(this), baseAmount);
        base.forceApprove(address(wrapper), baseAmount);
        uint256 wrapped = wrapper.deposit(baseAmount, address(this));

        uint256 maxLtv = IArrowAdapter(adapter).MAX_LTV();
        if (ltvBps > maxLtv) revert LtvTooHigh(ltvBps, maxLtv);
        if (ltvBps > 0 && !IArrowAdapter(adapter).borrowAllowed()) revert MarketClosed();
        address account = FACTORY.getOrCreate(msg.sender);
        IERC20(address(wrapper)).safeTransfer(account, wrapped);
        borrowed = (IArrowAdapter(adapter).valueOf(wrapped) * ltvBps) / BPS;
        AgamaAccount(account).earnOpen(msg.sender, adapter, wrapped, borrowed);
        emit Opened(msg.sender, adapter, wrapped, ltvBps, borrowed);
    }

    function addCollateral(address adapter, uint256 amount) external {
        address account = FACTORY.getOrCreate(msg.sender);
        IERC20(IArrowAdapter(adapter).getAssetToken()).safeTransferFrom(msg.sender, account, amount);
        AgamaAccount(account).earnAddCollateral(msg.sender, adapter, amount);
    }

    function close(address adapter) external {
        AgamaAccount(FACTORY.accountOf(msg.sender)).earnClose(msg.sender, adapter, false);
        emit Closed(msg.sender, adapter);
    }

    /// @notice Close and hand back the BASE xStock instead of the wrapper, so
    ///         the stock can go straight back to an OKX deposit address.
    function closeToBase(address adapter) external {
        AgamaAccount(FACTORY.accountOf(msg.sender)).earnClose(msg.sender, adapter, true);
        emit Closed(msg.sender, adapter);
    }

    /// @notice Close in one transaction even when the vault shares no longer
    ///         cover the debt: pulls the shortfall (plus a 0.01% margin for
    ///         interest accrued before inclusion) from the caller, capped by
    ///         `maxTopUp`. Anything unused comes back with the leftovers.
    function closeWithTopUp(address adapter, uint256 maxTopUp) external returns (uint256 toppedUp) {
        return _closeWithTopUp(adapter, maxTopUp, false);
    }

    /// @notice `closeWithTopUp`, returning the BASE xStock (for an OKX deposit).
    function closeToBaseWithTopUp(address adapter, uint256 maxTopUp) external returns (uint256 toppedUp) {
        return _closeWithTopUp(adapter, maxTopUp, true);
    }

    function _closeWithTopUp(address adapter, uint256 maxTopUp, bool unwrap)
        internal
        returns (uint256 toppedUp)
    {
        address account = FACTORY.accountOf(msg.sender);
        uint256 short = closeShortfall(msg.sender, adapter);
        if (short > 0) {
            toppedUp = short > maxTopUp ? maxTopUp : short;
            USDC.safeTransferFrom(msg.sender, account, toppedUp);
        }
        AgamaAccount(account).earnClose(msg.sender, adapter, unwrap);
        emit Closed(msg.sender, adapter);
    }

    /// @notice USDC the owner must add for `close` to succeed now (0 if none).
    function closeShortfall(address user, address adapter) public view returns (uint256) {
        address account = FACTORY.accountOf(user);
        if (account == address(0)) return 0;
        uint256 debt = POOL.getPositionScaledDebt(adapter, account, "");
        uint256 have = AgamaAccount(account).redeemableUsdc();
        if (have >= debt) return 0;
        return debt - have + debt / 10_000 + 1;
    }

    // ---- Views for the front ------------------------------------------------------

    /// @notice What `open` would borrow, and the HF right after.
    function quote(address adapter, uint256 amount, uint256 ltvBps)
        external
        view
        returns (uint256 stockValue, uint256 borrow, uint256 hfRay)
    {
        stockValue = IArrowAdapter(adapter).valueOf(amount);
        borrow = (stockValue * ltvBps) / BPS;
        hfRay = borrow == 0
            ? type(uint256).max
            : (stockValue * IArrowAdapter(adapter).LIQUIDATION_THRESHOLD() * 1e27) / (borrow * BPS);
    }

    struct Position {
        address account;
        uint256 collateral; // wrapped xStock units
        uint256 collateralValue; // USDC units
        uint256 debt; // USDC units
        uint256 healthFactorRay;
        uint256 freeShares;
        uint256 freeSharesValue; // USDC units
        bool borrowAllowed;
        uint256 liquidationThresholdBps;
    }

    function position(address user, address adapter) external view returns (Position memory p) {
        p.account = FACTORY.accountOf(user);
        p.borrowAllowed = IArrowAdapter(adapter).borrowAllowed();
        p.liquidationThresholdBps = IArrowAdapter(adapter).LIQUIDATION_THRESHOLD();
        if (p.account == address(0)) return p;
        p.collateral = IArrowAdapter(adapter).getInternalBalance(p.account, "");
        try IArrowAdapter(adapter).valueOf(p.collateral) returns (uint256 v) {
            p.collateralValue = v;
        } catch {}
        p.debt = POOL.getPositionScaledDebt(adapter, p.account, "");
        try POOL.calculateHealthFactor(adapter, p.account, "") returns (uint256 hf) {
            p.healthFactorRay = hf;
        } catch {}
        p.freeShares = AgamaAccount(p.account).freeShares();
        p.freeSharesValue = AgamaAccount(p.account).freeSharesValue();
    }
}

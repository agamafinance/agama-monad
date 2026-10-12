// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {IAssetAdapter} from "./adapters/IAssetAdapter.sol";
import {IArrowAdapter} from "./adapters/IArrowAdapter.sol";
import {DebtToken} from "./DebtToken.sol";
import {ReserveLogic} from "./libs/ReserveLogic.sol";
import {InterestRateModel as IRM} from "./libs/InterestRateModel.sol";
import {WadRayMath} from "./libs/WadRayMath.sol";

interface IFeeCollector {
    function collectFee(address token, address from, uint256 amount, bytes32 feeType) external;
}

/// @title ArrowLendingPool
/// @notice Arrow Finance lending pool on X Layer (deployed by Agama as part of
///         the Arrow x Agama partnership). An ERC-4626 vault on USDC whose
///         shares are the lender receipt, plus a borrow surface against
///         adapter-managed collateral (wrapped xStocks, Agama vault shares).
/// @dev    Ported from the Agama protocol LendingPool (per-market isolated
///         debt, Aave-style indices, Liquity-style bad-debt accumulator).
///         Changes for X Layer:
///         - Every adapter is an `IArrowAdapter`. `borrow` asks the adapter
///           `borrowAllowed()` first: a closed stock market, a stale price or
///           a vault NAV circuit breaker blocks NEW debt only. Repay,
///           withdraw and liquidation are not gated by it.
///         - Liquidation is PARTIAL in collateral: the StabilityPool absorbs
///           the debt and receives collateral worth `debt * (1 + bonus)` at
///           fair price. The rest stays with the borrower. (The original
///           pool seized the whole position, which for a 40% LT stock means
///           losing 2.5x the debt.)
///         - If the StabilityPool is short, only the covered part of the debt
///           is liquidated; bad debt is socialized only once the borrower
///           has no collateral left.
///         - No SettlementVault (xStocks do not mature).
///         - `minBorrowAmount` follows the asset decimals (USDC = 6).
contract ArrowLendingPool is ERC4626, ILendingPool, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ReserveLogic for ReserveLogic.ReserveData;
    using WadRayMath for uint256;

    // ---- Roles -----------------------------------------------------------

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant LIQUIDATION_PROXY_ROLE = keccak256("LIQUIDATION_PROXY_ROLE");
    bytes32 public constant STABILITY_POOL_ROLE = keccak256("STABILITY_POOL_ROLE");

    /// @notice Fee-type tag for the origination fee deducted at borrow time.
    bytes32 public constant FEE_ORIGINATION = keccak256("FEE_ORIGINATION");

    // ---- Constants -------------------------------------------------------

    uint256 internal constant RAY = WadRayMath.RAY;
    uint256 internal constant BPS_DENOM = 10_000;
    /// @notice HF threshold below which a position is liquidatable. RAY = 1.0.
    uint256 public constant HF_LIQUIDATION_THRESHOLD = RAY;

    // ---- Immutables ------------------------------------------------------

    DebtToken public immutable DEBT_TOKEN;

    /// @notice Set to true on testnet, false on mainnet. Locked at deploy.
    ///         Gates ONLY `fastForwardInterest` (the demo cheat that projects
    ///         indices forward without waiting). Every other risk parameter
    ///         is identical mainnet vs testnet.
    bool public immutable testnetMode;

    // ---- Reserve state ---------------------------------------------------

    ReserveLogic.ReserveData internal _reserve;
    IRM.Params internal _irmParams;

    // ---- Risk parameters (governance-controlled) -------------------------

    uint256 public reserveFactorBps;
    uint256 public originationFeeBps;
    uint256 public vaultOpeningFee;
    uint256 public minBorrowAmount;
    uint256 public supplyCap;
    uint256 public borrowCap;
    bool public withdrawalsPaused;

    address public feeRecipient;
    address public stabilityPool;

    // ---- User storage ----------------------------------------------------

    mapping(address user => bool) public vaultOpened;
    mapping(address adapter => bool) public supportedAdapter;

    // ---- Bad-debt redistribution (Liquity O(1) accumulator) --------------

    /// @notice Cumulative ray-scaled debt-per-collateral attributed to active
    ///         borrowers when liquidations exceed the StabilityPool's
    ///         capacity.
    uint256 public bdAccLDebt;

    /// @dev adapter => user => snapshot of `bdAccLDebt` at last interaction.
    mapping(address => mapping(address => uint256)) internal _userLDebtSnapshot;

    // ---- Events ----------------------------------------------------------

    event VaultOpened(address indexed user, uint256 feePaid);
    event AssetDeposited(address indexed user, address indexed adapter, bytes data);
    event AssetWithdrawn(address indexed user, address indexed adapter, bytes data);
    event Borrow(address indexed user, address indexed adapter, uint256 amount, uint256 originationFee);
    event Repay(address indexed user, address indexed adapter, uint256 amount);
    event AdapterRegistered(address indexed adapter, bool supported);
    event FeeRecipientSet(address indexed recipient);
    event StabilityPoolSet(address indexed sp);
    event DonationBurned(address indexed from, uint256 shares);
    event RiskParamSet(bytes32 indexed key, uint256 value);
    event Liquidated(
        address indexed sp,
        address indexed user,
        address indexed adapter,
        uint256 scaledDebt,
        uint256 absorbedAssets,
        uint256 badDebt
    );
    event BadDebtRedistributed(uint256 badDebtAssets, uint256 newLDebtAcc);
    event BadDebtStuck(uint256 badDebtAssets);
    event RedistributionMaterialized(address indexed adapter, address indexed user, uint256 extraDebt);

    // ---- Errors ----------------------------------------------------------

    error AmountZero();
    error WithdrawalsArePaused();
    error SupplyCapExceeded();
    error BorrowCapExceeded();
    error LiquidityShortfall();
    error UnsupportedAdapter();
    error VaultPositionAlreadyOpened();
    error VaultPositionNotOpened();
    error HealthFactorTooLow();
    error AmountBelowMinimum();
    error NoDebtToLiquidate();
    error HealthFactorTooHigh();
    error StabilityPoolNotSet();
    error StabilityPoolEmpty();
    error OnlyTestnet();
    error BpsExceedsDenom();
    error BorrowNotAllowed();

    // ---- Construction ----------------------------------------------------

    constructor(
        IERC20 usdr,
        address admin,
        string memory name_,
        string memory symbol_,
        IRM.Params memory irmParams_,
        bool _testnetMode
    ) ERC20(name_, symbol_) ERC4626(usdr) {
        IRM.validate(irmParams_);
        _irmParams = irmParams_;
        _reserve.init();
        testnetMode = _testnetMode;

        // V1 production risk parameters: IDENTICAL on testnet and mainnet.
        reserveFactorBps = 1000; // 10%
        originationFeeBps = 0; // disabled: Aave-style, no origination fee
        vaultOpeningFee = 0;
        minBorrowAmount = 10 ** IERC20Metadata(address(usdr)).decimals(); // 1 unit of the asset
        supplyCap = type(uint256).max;
        borrowCap = type(uint256).max;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        DEBT_TOKEN = new DebtToken(
            address(this),
            address(usdr),
            string.concat("Agama Debt ", IERC20Metadata(address(usdr)).symbol()),
            string.concat("agDEBT-", IERC20Metadata(address(usdr)).symbol()),
            IERC20Metadata(address(usdr)).decimals()
        );
    }

    // ---- ILendingPool views ----------------------------------------------

    function asset() public view override(ERC4626, ILendingPool) returns (address) {
        return ERC4626.asset();
    }

    function getNormalizedIncome() external view returns (uint256) {
        return _reserve.getNormalizedIncome();
    }

    function getNormalizedDebt() external view returns (uint256) {
        return _reserve.getNormalizedDebt();
    }

    // ---- ERC4626 overrides -----------------------------------------------

    function totalAssets() public view override returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 debt = DEBT_TOKEN.totalSupply();
        return cash + debt;
    }

    /// @dev OZ ERC4626 inflation-attack mitigation. With offset = 6, the
    ///      virtual share count is 1e6, so an attacker depositing 1 wei of
    ///      USDr into an empty pool then donating N USDr only inflates
    ///      share price by N / 1e6 instead of N: making the canonical
    ///      donation attack non-economical for any realistic N.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _reserve.updateState();
        if (assets == 0) revert AmountZero();
        super._deposit(caller, receiver, assets, shares);
        _afterMutation();
        if (totalSupply() > supplyCap) revert SupplyCapExceeded();
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _reserve.updateState();
        if (withdrawalsPaused && !hasRole(STABILITY_POOL_ROLE, caller)) {
            revert WithdrawalsArePaused();
        }
        if (IERC20(asset()).balanceOf(address(this)) < assets) revert LiquidityShortfall();
        super._withdraw(caller, receiver, owner, assets, shares);
        _afterMutation();
    }

    // ---- Vault position lifecycle ----------------------------------------

    function openVaultPosition() external whenNotPaused {
        if (vaultOpened[msg.sender]) revert VaultPositionAlreadyOpened();
        vaultOpened[msg.sender] = true;
        if (vaultOpeningFee > 0) {
            _collectFee(msg.sender, vaultOpeningFee);
        }
        emit VaultOpened(msg.sender, vaultOpeningFee);
    }

    function depositAsset(address adapter, bytes calldata data)
        external
        nonReentrant
        whenNotPaused
        onlySupportedAdapter(adapter)
    {
        if (!vaultOpened[msg.sender]) revert VaultPositionNotOpened();
        _reserve.updateState();
        _materializeRedistribution(adapter, msg.sender);
        IAssetAdapter(adapter).deposit(msg.sender, data);
        emit AssetDeposited(msg.sender, adapter, data);
    }

    function withdrawAsset(address adapter, bytes calldata data)
        external
        nonReentrant
        whenNotPaused
        onlySupportedAdapter(adapter)
    {
        _reserve.updateState();
        _materializeRedistribution(adapter, msg.sender);

        // Health-factor preview when there's still debt outstanding ON
        // THIS market. If oracle is stale, `getAssetValue` reverts inside
        // the adapter: blocking partial withdraws while letting full
        // exits work (debt = 0 path skips the HF check entirely, and
        // `adapter.withdraw` itself doesn't depend on the oracle).
        // V3: only the per-market debt is checked: withdrawing collateral
        // here cannot affect any other market's HF (their debt+collat are
        // isolated).
        uint256 debt = _userDebtFor(msg.sender, adapter);
        if (debt > 0) {
            uint256 totalCollateral = IAssetAdapter(adapter).getAssetValue(msg.sender, data);
            uint256 withdrawing = IAssetAdapter(adapter).getWithdrawValue(msg.sender, data);
            uint256 remaining = totalCollateral > withdrawing ? totalCollateral - withdrawing : 0;
            uint256 ltBps = IAssetAdapter(adapter).LIQUIDATION_THRESHOLD();
            uint256 hf = _hf(remaining, debt, ltBps);
            if (hf < HF_LIQUIDATION_THRESHOLD) revert HealthFactorTooLow();
        }

        IAssetAdapter(adapter).withdraw(msg.sender, data);
        emit AssetWithdrawn(msg.sender, adapter, data);
    }

    // ---- Borrow / repay --------------------------------------------------

    function borrow(address adapter, bytes calldata data, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlySupportedAdapter(adapter)
    {
        if (amount == 0) revert AmountZero();
        if (!vaultOpened[msg.sender]) revert VaultPositionNotOpened();

        _reserve.updateState();
        _materializeRedistribution(adapter, msg.sender);

        if (!IArrowAdapter(adapter).borrowAllowed()) revert BorrowNotAllowed();
        if (DEBT_TOKEN.totalSupply() + amount > borrowCap) revert BorrowCapExceeded();
        if (amount < minBorrowAmount) revert AmountBelowMinimum();

        // HF after borrow at adapter MAX_LTV. `getAssetValue` reverts on stale
        // oracle, so a stale oracle naturally blocks new borrows.
        // V3: debt is per-market: each adapter is checked against ITS OWN
        // debt only. No cross-collateral aggregation.
        uint256 collateralValue = IAssetAdapter(adapter).getAssetValue(msg.sender, data);
        uint256 newDebt = _userDebtFor(msg.sender, adapter) + amount;
        uint256 ltBps = IAssetAdapter(adapter).MAX_LTV();
        uint256 hf = _hf(collateralValue, newDebt, ltBps);
        if (hf < HF_LIQUIDATION_THRESHOLD) revert HealthFactorTooLow();

        if (IERC20(asset()).balanceOf(address(this)) < amount) revert LiquidityShortfall();

        // Origination fee charged BEFORE the debt mint. The cash dip → fresh
        // share-price baseline ensures Treasury's auto-stake captures
        // ~100% of the fee (no leak to existing lenders).
        uint256 fee = 0;
        if (feeRecipient != address(0)) {
            fee = (amount * originationFeeBps) / BPS_DENOM;
            if (fee > 0) {
                IERC20(asset()).approve(feeRecipient, fee);
                IFeeCollector(feeRecipient).collectFee(asset(), address(this), fee, FEE_ORIGINATION);
            }
        }

        DEBT_TOKEN.mint(msg.sender, adapter, amount, _reserve.usageIndex);
        IERC20(asset()).safeTransfer(msg.sender, amount - fee);

        _afterMutation();
        emit Borrow(msg.sender, adapter, amount, fee);
    }

    function repay(address adapter, bytes calldata data, uint256 amount)
        external
        nonReentrant
        onlySupportedAdapter(adapter)
        returns (uint256 paid)
    {
        // No oracle dependency: repay is always allowed (exit path).
        // V3: repay is scoped to a market: only the user's debt on
        // `adapter` is reduced. No cross-market spillover.
        IAssetAdapter(adapter).getPositionKey(data); // sanity decode
        _reserve.updateState();
        _materializeRedistribution(adapter, msg.sender);

        uint256 debt = _userDebtFor(msg.sender, adapter);
        paid = amount == type(uint256).max ? debt : amount;
        if (paid == 0) revert AmountZero();
        if (paid > debt) paid = debt;

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), paid);
        DEBT_TOKEN.burn(msg.sender, adapter, paid, _reserve.usageIndex);

        _afterMutation();
        emit Repay(msg.sender, adapter, paid);
    }

    // ---- Liquidation ------------------------------------------------------

    /// @notice Liquidate `user`'s position on `adapter` when HF < 1.
    ///         The StabilityPool burns lender shares to absorb the debt and
    ///         receives collateral worth `absorbed * (1 + bonus)` at fair
    ///         price. Remaining collateral stays with the borrower.
    /// @dev    Gated by LIQUIDATION_PROXY_ROLE (held by the StabilityPool,
    ///         whose own `liquidate` is permissionless). A stale price makes
    ///         `getAssetValue` revert, which blocks the liquidation instead
    ///         of seizing blind.
    function liquidate(address adapter, address user, bytes calldata data)
        external
        nonReentrant
        onlyRole(LIQUIDATION_PROXY_ROLE)
        returns (uint256 absorbedAssets, uint256 badDebt)
    {
        if (!supportedAdapter[adapter]) revert UnsupportedAdapter();
        address sp = stabilityPool;
        if (sp == address(0)) revert StabilityPoolNotSet();

        _reserve.updateState();
        _materializeRedistribution(adapter, user);

        uint256 marketDebt = DEBT_TOKEN.balanceOf(user, adapter);
        if (marketDebt == 0) revert NoDebtToLiquidate();

        uint256 collateralValue = IAssetAdapter(adapter).getAssetValue(user, data);
        uint256 ltBps = IAssetAdapter(adapter).LIQUIDATION_THRESHOLD();
        uint256 hf = _hf(collateralValue, marketDebt, ltBps);
        if (hf >= HF_LIQUIDATION_THRESHOLD) revert HealthFactorTooHigh();

        // 1. The SP absorbs what it can. An empty pool must revert rather than
        //    mine a transaction that seizes nothing: a keeper reporting a
        //    liquidation that did not happen is worse than a failed call.
        uint256 spCapacityAssets = convertToAssets(balanceOf(sp));
        if (spCapacityAssets == 0) revert StabilityPoolEmpty();
        absorbedAssets = marketDebt < spCapacityAssets ? marketDebt : spCapacityAssets;
        uint256 sharesToBurn = convertToShares(absorbedAssets);
        if (sharesToBurn > 0) {
            _burn(sp, sharesToBurn);
            emit DonationBurned(sp, sharesToBurn);
        }
        if (absorbedAssets > 0) {
            DEBT_TOKEN.burn(user, adapter, absorbedAssets, _reserve.usageIndex);
        }

        // 2. Seize collateral worth absorbed * (1 + bonus), not the whole position.
        uint256 seizeTarget =
            (absorbedAssets * (BPS_DENOM + IAssetAdapter(adapter).LIQUIDATION_BONUS())) / BPS_DENOM;
        uint256 remainingCollateral = IAssetAdapter(adapter).getInternalBalance(user, data);
        if (seizeTarget > 0) {
            (, remainingCollateral) = IArrowAdapter(adapter).seizeValue(user, seizeTarget, sp);
        }

        // 3. Debt left with no collateral behind it is bad debt: burn it and
        //    socialize it across the other borrowers of this market.
        uint256 leftover = marketDebt - absorbedAssets;
        if (leftover > 0 && remainingCollateral == 0) {
            badDebt = leftover;
            DEBT_TOKEN.burn(user, adapter, badDebt, _reserve.usageIndex);
            _redistributeBadDebt(adapter, badDebt);
        }

        _userLDebtSnapshot[adapter][user] = bdAccLDebt;
        _afterMutation();
        emit Liquidated(sp, user, adapter, marketDebt, absorbedAssets, badDebt);
    }

    // ---- Protocol-specific extensions (clearly non-standard) -------------

    /// @notice Burns `shares` from `from` without releasing any USDr. Used by
    ///         the StabilityPool during liquidation.
    function burnDonation(address from, uint256 shares) external nonReentrant onlyRole(STABILITY_POOL_ROLE) {
        if (shares == 0) revert AmountZero();
        _burn(from, shares);
        emit DonationBurned(from, shares);
    }

    // ---- Views -----------------------------------------------------------

    function calculateHealthFactor(address adapter, address user, bytes calldata data)
        external
        view
        returns (uint256)
    {
        uint256 debt = _userActualDebt(adapter, user);
        if (debt == 0) return type(uint256).max;
        uint256 collateral = IAssetAdapter(adapter).getAssetValue(user, data);
        uint256 ltBps = IAssetAdapter(adapter).LIQUIDATION_THRESHOLD();
        return _hf(collateral, debt, ltBps);
    }

    function getPositionScaledDebt(address adapter, address user, bytes calldata)
        external
        view
        returns (uint256)
    {
        return _userActualDebt(adapter, user);
    }

    function getReserveState() external view returns (ReserveLogic.ReserveData memory) {
        return _reserve;
    }

    function getIRMParams() external view returns (IRM.Params memory) {
        return _irmParams;
    }

    // ---- Admin -----------------------------------------------------------

    function registerAdapter(address adapter, bool supported) external onlyRole(GOVERNOR_ROLE) {
        supportedAdapter[adapter] = supported;
        emit AdapterRegistered(adapter, supported);
    }

    function setFeeRecipient(address recipient) external onlyRole(GOVERNOR_ROLE) {
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function setStabilityPool(address sp) external onlyRole(GOVERNOR_ROLE) {
        address old = stabilityPool;
        if (old != address(0)) {
            _revokeRole(STABILITY_POOL_ROLE, old);
            _revokeRole(LIQUIDATION_PROXY_ROLE, old);
        }
        stabilityPool = sp;
        if (sp != address(0)) {
            _grantRole(STABILITY_POOL_ROLE, sp);
            _grantRole(LIQUIDATION_PROXY_ROLE, sp);
        }
        emit StabilityPoolSet(sp);
    }

    function setReserveFactor(uint256 bps) external onlyRole(GOVERNOR_ROLE) {
        if (bps > BPS_DENOM) revert BpsExceedsDenom();
        reserveFactorBps = bps;
        emit RiskParamSet("reserveFactorBps", bps);
    }

    function setOriginationFee(uint256 bps) external onlyRole(GOVERNOR_ROLE) {
        if (bps > BPS_DENOM) revert BpsExceedsDenom();
        originationFeeBps = bps;
        emit RiskParamSet("originationFeeBps", bps);
    }

    function setMinBorrowAmount(uint256 v) external onlyRole(GOVERNOR_ROLE) {
        minBorrowAmount = v;
        emit RiskParamSet("minBorrowAmount", v);
    }

    function setSupplyCap(uint256 v) external onlyRole(GOVERNOR_ROLE) {
        supplyCap = v;
        emit RiskParamSet("supplyCap", v);
    }

    function setBorrowCap(uint256 v) external onlyRole(GOVERNOR_ROLE) {
        borrowCap = v;
        emit RiskParamSet("borrowCap", v);
    }

    /// @notice Testnet-only cheat: project the LP's interest indices forward
    ///         by `secs` seconds at the current rates, without waiting. On
    ///         mainnet, `testnetMode` is false at deploy and this reverts
    ///         forever.
    function fastForwardInterest(uint256 secs) external onlyRole(GOVERNOR_ROLE) {
        if (!testnetMode) revert OnlyTestnet();
        _reserve.updateState();
        uint256 incrLiq = (_reserve.currentLiquidityRate * secs) / 365 days;
        uint256 incrDebt = (_reserve.currentBorrowRate * secs) / 365 days;
        _reserve.liquidityIndex = _reserve.liquidityIndex.rayMul(RAY + incrLiq);
        _reserve.usageIndex = _reserve.usageIndex.rayMul(RAY + incrDebt);
        emit RiskParamSet("fastForwardInterest", secs);
    }

    function setWithdrawalsPaused(bool paused) external onlyRole(PAUSER_ROLE) {
        withdrawalsPaused = paused;
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function setIRMParams(IRM.Params memory p) external onlyRole(GOVERNOR_ROLE) {
        IRM.validate(p);
        _irmParams = p;
        _afterMutation();
    }

    // ---- Internals -------------------------------------------------------

    modifier onlySupportedAdapter(address adapter) {
        if (!supportedAdapter[adapter]) revert UnsupportedAdapter();
        _;
    }

    /// @notice Per-market debt of `user` on `adapter`: the canonical
    ///         number used by every economic check (HF, repay cap,
    ///         liquidation seizure target).
    function _userDebtFor(address user, address adapter) internal view returns (uint256) {
        return DEBT_TOKEN.balanceOf(user, adapter);
    }

    /// @notice Per-market debt of `user` ON `adapter` plus their pending
    ///         pro-rata share of bad-debt redistribution. Bad debt is
    ///         materialized lazily: this view applies the unsettled
    ///         delta on top of the on-chain per-market balance.
    function _userActualDebt(address adapter, address user) internal view returns (uint256) {
        uint256 base = DEBT_TOKEN.balanceOf(user, adapter);
        uint256 snapL = _userLDebtSnapshot[adapter][user];
        if (bdAccLDebt <= snapL) return base;
        uint256 collat = IAssetAdapter(adapter).getInternalBalance(user, "");
        if (collat == 0) return base;
        unchecked {
            uint256 delta = bdAccLDebt - snapL;
            return base + (collat * delta) / RAY;
        }
    }

    function _materializeRedistribution(address adapter, address user) internal {
        uint256 snapL = _userLDebtSnapshot[adapter][user];
        if (bdAccLDebt <= snapL) return;
        uint256 collat = IAssetAdapter(adapter).getInternalBalance(user, "");
        _userLDebtSnapshot[adapter][user] = bdAccLDebt;
        if (collat == 0) return;
        uint256 delta = bdAccLDebt - snapL;
        uint256 extra = (collat * delta) / RAY;
        if (extra > 0) {
            DEBT_TOKEN.mint(user, adapter, extra, _reserve.usageIndex);
            emit RedistributionMaterialized(adapter, user, extra);
        }
    }

    function _redistributeBadDebt(address adapter, uint256 badDebtAssets) internal {
        uint256 totalColl = IAssetAdapter(adapter).totalInternalBalance();
        if (totalColl == 0) {
            emit BadDebtStuck(badDebtAssets);
            return;
        }
        bdAccLDebt += (badDebtAssets * RAY) / totalColl;
        emit BadDebtRedistributed(badDebtAssets, bdAccLDebt);
    }

    function _hf(uint256 collateralValue, uint256 debt, uint256 ltBps) internal pure returns (uint256) {
        if (debt == 0) return type(uint256).max;
        return (collateralValue * ltBps * RAY) / (debt * BPS_DENOM);
    }

    function _afterMutation() internal {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 debt = DEBT_TOKEN.totalSupply();
        _reserve.updateInterestRates(_irmParams, cash, debt, reserveFactorBps);
    }

    function _collectFee(address from, uint256 amount) internal {
        if (feeRecipient == address(0)) {
            IERC20(asset()).safeTransferFrom(from, address(this), amount);
        } else {
            IERC20(asset()).safeTransferFrom(from, feeRecipient, amount);
        }
    }
}

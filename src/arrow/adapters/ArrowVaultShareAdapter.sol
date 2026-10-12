// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IArrowAdapter} from "./IArrowAdapter.sol";

/// @title ArrowVaultShareAdapter
/// @notice Collateral adapter for Agama vault shares (sagUSD) in the Arrow
///         lending pool. This is the leg that makes Amplify (looping) work.
///
///         Pricing lessons taken from the 2025-26 blow-ups:
///           - NEVER a hardcoded 1$ (Stream xUSD, Resolv USR): the value is
///             read from the vault's own exchange rate, `convertToAssets`.
///           - CAPO-style growth cap: the rate used for valuation cannot
///             grow faster than `MAX_GROWTH_BPS_PER_YEAR` from the last
///             snapshot, so a manipulated or fat-fingered NAV jump cannot
///             be borrowed against.
///           - Haircut: collateral value = fair value * (1 - HAIRCUT_BPS).
///             The haircut and the liquidation bonus together must cover the
///             vault's redemption delay: a liquidator (the StabilityPool)
///             may have to wait in the redemption queue.
///           - Circuit breaker: if the live rate falls more than
///             `MAX_DROP_BPS` under the snapshot, `borrowAllowed()` turns
///             false. Repay, withdraw and liquidation keep working (the
///             failure mode of MainStreet msY was a feed that REVERTED and
///             froze liquidations).
///
/// @dev    Values are in pool-asset base units (USDC, 6 decimals). The vault
///         asset (agUSD, 18 decimals) is redeemable 1:1 for USDC through the
///         agUSDQueue, so 1 agUSD is valued at 1 USDC.
contract ArrowVaultShareAdapter is IArrowAdapter, Ownable {
    using SafeERC20 for IERC20;

    bytes32 public constant POSITION_KEY = keccak256("ARROW_VAULT_SHARE_V1");
    uint256 internal constant BPS = 10_000;

    address public immutable POOL;
    IERC4626 public immutable SHARE;
    /// @notice 10^(assetDecimals - poolDecimals): agUSD (18) -> USDC (6) = 1e12.
    uint256 public immutable ASSET_TO_POOL;
    /// @notice One full share (10^shareDecimals), used to express rates.
    uint256 public immutable ONE_SHARE;

    uint256 public immutable override MAX_LTV;
    uint256 public immutable override LIQUIDATION_THRESHOLD;
    uint256 public immutable override LIQUIDATION_BONUS;
    uint256 public immutable HAIRCUT_BPS;
    uint256 public immutable MAX_GROWTH_BPS_PER_YEAR;
    uint256 public immutable MAX_DROP_BPS;
    uint256 public constant MIN_SNAPSHOT_INTERVAL = 1 days;

    /// @notice CAPO reference: vault assets per ONE_SHARE at `snapshotAt`.
    uint256 public snapshotRate;
    uint256 public snapshotAt;
    /// @notice Previous snapshot, kept to expose a realized APY on-chain.
    uint256 public prevSnapshotRate;
    uint256 public prevSnapshotAt;

    mapping(address user => uint256) internal _balances;
    uint256 public override totalInternalBalance;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Seized(address indexed from, address indexed to, uint256 amount, uint256 value);
    event Snapshot(uint256 rate, uint256 at);

    error OnlyPool();
    error AmountZero();
    error InsufficientPositionBalance();
    error InvalidData();
    error InvalidRiskParams();
    error SnapshotTooSoon();

    constructor(
        address pool,
        IERC4626 share,
        uint8 poolDecimals,
        address admin,
        uint256 maxLtvBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        uint256 haircutBps,
        uint256 maxGrowthBpsPerYear,
        uint256 maxDropBps
    ) Ownable(admin) {
        if (maxLtvBps == 0 || maxLtvBps >= liquidationThresholdBps) {
            revert InvalidRiskParams();
        }
        if (liquidationThresholdBps > BPS || liquidationBonusBps > 2_000) revert InvalidRiskParams();
        if (haircutBps > 2_000 || maxDropBps == 0 || maxDropBps > BPS) revert InvalidRiskParams();
        uint8 assetDecimals = IERC20Metadata(share.asset()).decimals();
        if (assetDecimals < poolDecimals) revert InvalidRiskParams();
        POOL = pool;
        SHARE = share;
        ASSET_TO_POOL = 10 ** (assetDecimals - poolDecimals);
        ONE_SHARE = 10 ** IERC20Metadata(address(share)).decimals();
        MAX_LTV = maxLtvBps;
        LIQUIDATION_THRESHOLD = liquidationThresholdBps;
        LIQUIDATION_BONUS = liquidationBonusBps;
        HAIRCUT_BPS = haircutBps;
        MAX_GROWTH_BPS_PER_YEAR = maxGrowthBpsPerYear;
        MAX_DROP_BPS = maxDropBps;

        uint256 r = share.convertToAssets(ONE_SHARE);
        snapshotRate = r;
        snapshotAt = block.timestamp;
        prevSnapshotRate = r;
        prevSnapshotAt = block.timestamp;
        emit Snapshot(r, block.timestamp);
    }

    modifier onlyPool() {
        if (msg.sender != POOL) revert OnlyPool();
        _;
    }

    // ---- Rates -------------------------------------------------------------------

    function liveRate() public view returns (uint256) {
        return SHARE.convertToAssets(ONE_SHARE);
    }

    /// @notice Max rate the valuation accepts right now (CAPO ceiling).
    function rateCeiling() public view returns (uint256) {
        uint256 dt = block.timestamp - snapshotAt;
        return snapshotRate + Math.mulDiv(snapshotRate, MAX_GROWTH_BPS_PER_YEAR * dt, BPS * 365 days);
    }

    /// @notice Rate used for valuation: live rate capped by the CAPO ceiling.
    function cappedRate() public view returns (uint256) {
        uint256 live = liveRate();
        uint256 ceil = rateCeiling();
        return live < ceil ? live : ceil;
    }

    /// @notice Permissionless CAPO snapshot, at most once a day. The new
    ///         reference is the capped rate, so a snapshot can never jump the
    ///         reference above the ceiling. A rate BELOW the reference is
    ///         recorded as-is (losses propagate immediately).
    function snapshot() external {
        if (block.timestamp < snapshotAt + MIN_SNAPSHOT_INTERVAL) revert SnapshotTooSoon();
        uint256 r = cappedRate();
        prevSnapshotRate = snapshotRate;
        prevSnapshotAt = snapshotAt;
        snapshotRate = r;
        snapshotAt = block.timestamp;
        emit Snapshot(r, block.timestamp);
    }

    /// @notice Annualized growth between the last two snapshots, RAY (1e27 = 100%).
    ///         Read by the Amplify spread guard.
    function realizedApyRay() external view returns (uint256) {
        if (snapshotAt <= prevSnapshotAt || snapshotRate <= prevSnapshotRate) return 0;
        uint256 growth = Math.mulDiv(snapshotRate - prevSnapshotRate, 1e27, prevSnapshotRate);
        return Math.mulDiv(growth, 365 days, snapshotAt - prevSnapshotAt);
    }

    function borrowAllowed() external view override returns (bool) {
        return liveRate() * BPS >= snapshotRate * (BPS - MAX_DROP_BPS);
    }

    function ORACLE_STALENESS_MAX() external pure override returns (uint256) {
        return type(uint256).max; // on-chain exchange rate, never stale
    }

    // ---- Valuation ---------------------------------------------------------------

    /// @notice Fair value (no haircut) of `amount` shares, in pool units.
    function valueOf(uint256 amount) public view override returns (uint256) {
        if (amount == 0) return 0;
        return Math.mulDiv(amount, cappedRate(), ONE_SHARE) / ASSET_TO_POOL;
    }

    /// @notice Collateral value used by the pool (fair value minus haircut).
    function collateralValueOf(uint256 amount) public view returns (uint256) {
        return (valueOf(amount) * (BPS - HAIRCUT_BPS)) / BPS;
    }

    function getAssetValue(address user, bytes calldata) external view override returns (uint256) {
        return collateralValueOf(_balances[user]);
    }

    function getWithdrawValue(address user, bytes calldata data) external view override returns (uint256) {
        uint256 amount = _decodeAmount(data);
        uint256 bal = _balances[user];
        return collateralValueOf(amount > bal ? bal : amount);
    }

    function getTotalAssetValue(address user) external view override returns (uint256) {
        return collateralValueOf(_balances[user]);
    }

    // ---- Position lifecycle (pool only) --------------------------------------------

    function deposit(address user, bytes calldata data) external override onlyPool {
        uint256 amount = _decodeAmount(data);
        if (amount == 0) revert AmountZero();
        _balances[user] += amount;
        totalInternalBalance += amount;
        IERC20(address(SHARE)).safeTransferFrom(user, address(this), amount);
        emit Deposited(user, amount);
    }

    function withdraw(address user, bytes calldata data) external override onlyPool {
        uint256 amount = _decodeAmount(data);
        if (amount == 0) revert AmountZero();
        uint256 bal = _balances[user];
        if (amount > bal) revert InsufficientPositionBalance();
        unchecked {
            _balances[user] = bal - amount;
            totalInternalBalance -= amount;
        }
        IERC20(address(SHARE)).safeTransfer(user, amount);
        emit Withdrawn(user, amount);
    }

    /// @inheritdoc IArrowAdapter
    function seizeValue(address from, uint256 value, address to)
        external
        override
        onlyPool
        returns (uint256 seized, uint256 remaining)
    {
        uint256 bal = _balances[from];
        if (bal == 0) revert InsufficientPositionBalance();
        uint256 rate = cappedRate();
        // shares = value * ASSET_TO_POOL * ONE_SHARE / rate, rounded up
        seized = Math.mulDiv(value * ASSET_TO_POOL, ONE_SHARE, rate, Math.Rounding.Ceil);
        if (seized > bal) seized = bal;
        remaining = bal - seized;
        _balances[from] = remaining;
        totalInternalBalance -= seized;
        IERC20(address(SHARE)).safeTransfer(to, seized);
        emit Seized(from, to, seized, valueOf(seized));
    }

    function transferAsset(address from, bytes calldata, address to) external override onlyPool {
        uint256 bal = _balances[from];
        if (bal == 0) revert InsufficientPositionBalance();
        _balances[from] = 0;
        totalInternalBalance -= bal;
        IERC20(address(SHARE)).safeTransfer(to, bal);
        emit Seized(from, to, bal, 0);
    }

    // ---- Identification / validation ------------------------------------------------

    function getPositionKey(bytes calldata) external pure override returns (bytes32) {
        return POSITION_KEY;
    }

    function getPositionKeys(address user) external view override returns (bytes32[] memory keys) {
        if (_balances[user] == 0) return new bytes32[](0);
        keys = new bytes32[](1);
        keys[0] = POSITION_KEY;
    }

    function validate(address, bytes calldata data) external pure override {
        _decodeAmount(data);
    }

    function validateLiquidationData(address user, bytes calldata) external view override returns (bool) {
        return _balances[user] > 0;
    }

    function getAssetToken() external view override returns (address) {
        return address(SHARE);
    }

    function getAssetType() external pure override returns (string memory) {
        return "Agama vault share (sagUSD)";
    }

    function supportsPartialWithdraw() external pure override returns (bool) {
        return true;
    }

    function getInternalBalance(address user, bytes calldata) external view override returns (uint256) {
        return _balances[user];
    }

    function balanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

    /// @notice No external oracle: the price is the vault's own exchange rate.
    function setPriceOracle(address) external pure override {
        revert InvalidData();
    }

    function _decodeAmount(bytes calldata data) internal pure returns (uint256 amount) {
        if (data.length == 0) return 0;
        if (data.length != 32) revert InvalidData();
        amount = abi.decode(data, (uint256));
    }
}

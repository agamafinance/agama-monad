// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IArrowAdapter} from "./adapters/IArrowAdapter.sol";

interface IArrowLendingPoolLiquidate {
    function supportedAdapter(address adapter) external view returns (bool);
    function liquidate(address adapter, address user, bytes calldata data)
        external
        returns (uint256 absorbedAssets, uint256 badDebt);
}

interface IagUSDQueueRedeem {
    function requestRedemption(uint256 agUSDAmount, address recipient) external returns (uint256 requestId);
}

/// @title ArrowStabilityPool
/// @notice Liquidation backstop of the Arrow lending pool, same model as
///         Arrow Finance on Robinhood Chain: depositors stake lender shares,
///         those shares absorb the debt of liquidated positions, and the
///         pool receives the seized collateral with a bonus.
///
///         Why not swap the collateral on a DEX: wrapped xStocks on X Layer
///         have almost no DEX depth (a few USDC of real exit in the
///         USDC/wTSLAx pool). So the SP holds the seized inventory and
///         recycles it two ways:
///           - `buyCollateral`: anyone buys inventory at the fair oracle
///             price minus `buyerDiscountBps`, paying USDC. The buyer can
///             redeem the xStock with the issuer (24/5, 1,000$ minimum).
///           - `redeemVaultShares`: seized Agama vault shares are redeemed
///             through the agUSDQueue, where the SP holds PRIORITY_ROLE.
///         Either way the USDC goes back into the lending pool as lender
///         shares, so the liquidation bonus accrues to SP depositors.
///
///         `liquidate` is permissionless: anyone can trigger a liquidation of
///         an HF < 1 position; the pool itself enforces the HF check.
///
/// @dev    ERC-4626 over the lending pool's share token. `totalAssets`
///         counts lender shares held plus the inventory valued at fair price
///         minus the buyer discount (0 if a price is unavailable), converted
///         to lender shares. Exits go through a cooldown so a depositor
///         cannot front-run a liquidation they see coming.
contract ArrowStabilityPool is ERC4626, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    uint256 internal constant BPS = 10_000;

    IERC4626 public immutable LENDING_POOL;
    IERC20 public immutable POOL_ASSET; // USDC

    /// @notice Collateral adapters whose seized tokens the SP may hold.
    address[] public adapters;
    mapping(address adapter => bool) public isAdapter;

    uint256 public buyerDiscountBps;
    uint256 public cooldown;

    /// @notice Agama vault plumbing for recycling seized sagUSD.
    IERC4626 public vaultShare; // sagUSD
    IagUSDQueueRedeem public vaultQueue;

    struct ExitRequest {
        uint128 shares;
        uint64 unlockAt;
    }

    mapping(address => ExitRequest) public exitRequests;
    mapping(address => uint256) public depositBlock;

    event AdapterAdded(address indexed adapter);
    event Liquidation(
        address indexed caller, address indexed adapter, address indexed user, uint256 absorbed
    );
    event CollateralBought(
        address indexed buyer,
        address indexed adapter,
        uint256 tokenAmount,
        uint256 paid,
        uint256 lenderShares
    );
    event VaultSharesRedeemed(uint256 shares, uint256 usdcOut, uint256 lenderShares);
    event ExitRequested(address indexed user, uint256 shares, uint64 unlockAt);
    event ParamsSet(uint256 buyerDiscountBps, uint256 cooldown);

    error AmountZero();
    error UnknownAdapter(address adapter);
    error SlippageExceeded(uint256 cost, uint256 maxCost);
    error InsufficientInventory();
    error CooldownActive(uint64 unlockAt);
    error ExceedsRequest(uint256 requested);
    error SameBlock();
    error RedemptionQueued(uint256 requestId);
    error InvalidParams();
    error VaultNotSet();

    constructor(IERC4626 lendingPool, address admin, uint256 buyerDiscountBps_, uint256 cooldown_)
        ERC20("Arrow Stability Pool USDC", "aSP-USDC")
        ERC4626(IERC20(address(lendingPool)))
    {
        if (buyerDiscountBps_ > 1_500) revert InvalidParams();
        LENDING_POOL = lendingPool;
        POOL_ASSET = IERC20(lendingPool.asset());
        buyerDiscountBps = buyerDiscountBps_;
        cooldown = cooldown_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    // ---- Accounting -----------------------------------------------------------------

    /// @notice Lender shares held + inventory at fair value minus the buyer
    ///         discount, expressed in lender shares.
    function totalAssets() public view override returns (uint256) {
        uint256 lenderShares = LENDING_POOL.balanceOf(address(this));
        uint256 inventoryUsdc = inventoryValue();
        if (inventoryUsdc == 0) return lenderShares;
        return lenderShares + LENDING_POOL.convertToShares(inventoryUsdc);
    }

    /// @notice Seized collateral held, valued in USDC (fair price minus discount).
    function inventoryValue() public view returns (uint256 total) {
        for (uint256 i; i < adapters.length; ++i) {
            IArrowAdapter a = IArrowAdapter(adapters[i]);
            uint256 bal = IERC20(a.getAssetToken()).balanceOf(address(this));
            if (bal == 0) continue;
            try a.valueOf(bal) returns (uint256 v) {
                total += (v * (BPS - buyerDiscountBps)) / BPS;
            } catch {
                // No trustworthy price: count it at zero (conservative).
            }
        }
    }

    // ---- Deposits ---------------------------------------------------------------------

    /// @notice Deposit USDC directly: supplied to the lending pool on behalf
    ///         of the SP, then staked. One step for the depositor.
    function depositUSDC(uint256 usdc, address receiver) external nonReentrant returns (uint256 shares) {
        if (usdc == 0) revert AmountZero();
        uint256 lenderShares = LENDING_POOL.previewDeposit(usdc);
        shares = previewDeposit(lenderShares);
        POOL_ASSET.safeTransferFrom(msg.sender, address(this), usdc);
        POOL_ASSET.forceApprove(address(LENDING_POOL), usdc);
        LENDING_POOL.deposit(usdc, address(this));
        _mint(receiver, shares);
        depositBlock[receiver] = block.number;
        emit Deposit(msg.sender, receiver, lenderShares, shares);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (assets == 0) revert AmountZero();
        super._deposit(caller, receiver, assets, shares);
        depositBlock[receiver] = block.number;
    }

    // ---- Exits (cooldown) ---------------------------------------------------------------

    /// @notice Start the cooldown for `shares`. The shares keep absorbing
    ///         liquidations until they are redeemed.
    function requestExit(uint256 shares) external {
        if (shares == 0 || shares > balanceOf(msg.sender)) revert AmountZero();
        uint64 unlockAt = uint64(block.timestamp + cooldown);
        exitRequests[msg.sender] = ExitRequest({shares: uint128(shares), unlockAt: unlockAt});
        emit ExitRequested(msg.sender, shares, unlockAt);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (depositBlock[owner] == block.number) revert SameBlock();
        ExitRequest memory r = exitRequests[owner];
        if (block.timestamp < r.unlockAt || r.unlockAt == 0) revert CooldownActive(r.unlockAt);
        if (shares > r.shares) revert ExceedsRequest(r.shares);
        exitRequests[owner].shares = uint128(r.shares - shares);
        // Pay out only liquid lender shares, never inventory.
        if (assets > LENDING_POOL.balanceOf(address(this))) revert InsufficientInventory();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ---- Liquidations -------------------------------------------------------------------

    /// @notice Permissionless. The lending pool checks HF < 1 and sizes the seizure.
    function liquidate(address adapter, address user) external nonReentrant returns (uint256 absorbed) {
        if (!isAdapter[adapter]) revert UnknownAdapter(adapter);
        (absorbed,) = IArrowLendingPoolLiquidate(address(LENDING_POOL)).liquidate(adapter, user, "");
        emit Liquidation(msg.sender, adapter, user, absorbed);
    }

    /// @notice Buy seized collateral at fair price minus the buyer discount.
    function buyCollateral(address adapter, uint256 tokenAmount, uint256 maxCost, address receiver)
        external
        nonReentrant
        returns (uint256 cost)
    {
        if (!isAdapter[adapter]) revert UnknownAdapter(adapter);
        if (tokenAmount == 0) revert AmountZero();
        IERC20 token = IERC20(IArrowAdapter(adapter).getAssetToken());
        if (token.balanceOf(address(this)) < tokenAmount) revert InsufficientInventory();

        uint256 fair = IArrowAdapter(adapter).valueOf(tokenAmount); // reverts on stale price
        cost = Math.mulDiv(fair, BPS - buyerDiscountBps, BPS, Math.Rounding.Ceil);
        if (cost > maxCost) revert SlippageExceeded(cost, maxCost);

        POOL_ASSET.safeTransferFrom(msg.sender, address(this), cost);
        uint256 lenderShares = _supplyToPool(cost);
        token.safeTransfer(receiver, tokenAmount);
        emit CollateralBought(msg.sender, adapter, tokenAmount, cost, lenderShares);
    }

    /// @notice Permissionless. Redeems seized Agama vault shares through the
    ///         queue (instant thanks to PRIORITY_ROLE, within the reserve) and
    ///         supplies the USDC back to the lending pool.
    function redeemVaultShares(uint256 shares) external nonReentrant returns (uint256 usdcOut) {
        IERC4626 vs = vaultShare;
        if (address(vs) == address(0)) revert VaultNotSet();
        if (shares == 0 || shares > vs.balanceOf(address(this))) revert InsufficientInventory();
        uint256 agUsd = vs.redeem(shares, address(this), address(this));
        IERC20 agUsdToken = IERC20(vs.asset());
        agUsdToken.forceApprove(address(vaultQueue), agUsd);
        uint256 before = POOL_ASSET.balanceOf(address(this));
        uint256 requestId = vaultQueue.requestRedemption(agUsd, address(this));
        if (requestId != 0) revert RedemptionQueued(requestId);
        usdcOut = POOL_ASSET.balanceOf(address(this)) - before;
        uint256 lenderShares = _supplyToPool(usdcOut);
        emit VaultSharesRedeemed(shares, usdcOut, lenderShares);
    }

    function _supplyToPool(uint256 usdc) internal returns (uint256 lenderShares) {
        if (usdc == 0) return 0;
        POOL_ASSET.forceApprove(address(LENDING_POOL), usdc);
        lenderShares = LENDING_POOL.deposit(usdc, address(this));
    }

    // ---- Views --------------------------------------------------------------------------

    function adapterCount() external view returns (uint256) {
        return adapters.length;
    }

    // ---- Admin --------------------------------------------------------------------------

    function addAdapter(address adapter) external onlyRole(GOVERNOR_ROLE) {
        if (isAdapter[adapter]) revert InvalidParams();
        if (!IArrowLendingPoolLiquidate(address(LENDING_POOL)).supportedAdapter(adapter)) {
            revert UnknownAdapter(adapter);
        }
        isAdapter[adapter] = true;
        adapters.push(adapter);
        emit AdapterAdded(adapter);
    }

    function setVault(IERC4626 vaultShare_, IagUSDQueueRedeem queue_) external onlyRole(GOVERNOR_ROLE) {
        vaultShare = vaultShare_;
        vaultQueue = queue_;
    }

    function setParams(uint256 buyerDiscountBps_, uint256 cooldown_) external onlyRole(GOVERNOR_ROLE) {
        if (buyerDiscountBps_ > 1_500 || cooldown_ > 30 days) revert InvalidParams();
        buyerDiscountBps = buyerDiscountBps_;
        cooldown = cooldown_;
        emit ParamsSet(buyerDiscountBps_, cooldown_);
    }
}

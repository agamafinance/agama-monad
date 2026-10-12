// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IArrowAdapter} from "./IArrowAdapter.sol";
import {StockOracle} from "../oracle/StockOracle.sol";

/// @title ArrowXStockAdapter
/// @notice Collateral adapter for one wrapped xStock (Backed) on X Layer,
///         e.g. wTSLAx. One deployment per stock.
///
///         Why the WRAPPER and not the base token: xStocks base tokens
///         rebase (balances move with dividends and corporate actions via a
///         `multiplier`). The ERC-4626 wrapper holds raw shares, so internal
///         balances never drift. Valuation:
///
///             wrapperPrice = stockPrice * wrapper.convertToAssets(1e18) / 1e18
///
///         where `convertToAssets` returns how many base xStock tokens one
///         wrapper token is worth (1.0057 for wSPYx today: accumulated
///         dividends). One base xStock tracks one underlying share.
///
///         Market hours (read from the StockOracle feed). The chain never
///         closes and neither does this market: what closes is the equity
///         session, and with it the price feed, which stops moving from the
///         Friday close until Monday. Borrowing stays open against that frozen
///         price, on tighter terms:
///           - closed session: both `MAX_LTV` and the liquidation threshold
///             drop by `WEEKEND_BUFFER_BPS`, so a position opened out of hours
///             carries the same cushion as one opened in them, and a Monday
///             gap is absorbed by that cushion instead of by bad debt.
///           - open session: base parameters.
///           - either way, `borrowAllowed()` only asks whether the price is
///             fresh. A stale feed is what stops a borrow, not the clock.
///
/// @dev    Values are returned in pool-asset base units (USDC, 6 decimals),
///         assuming 1 USDC = 1 USD.
contract ArrowXStockAdapter is IArrowAdapter, Ownable {
    using SafeERC20 for IERC20;

    bytes32 public constant POSITION_KEY = keccak256("ARROW_XSTOCK_V1");
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    address public immutable POOL;
    IERC4626 public immutable WRAPPER;
    bytes32 public immutable TICKER;
    StockOracle public oracle;
    /// @notice 10^(18 - poolDecimals): converts a 1e18 USD value into pool units.
    uint256 public immutable USD_TO_POOL;

    uint256 public immutable BASE_MAX_LTV;
    uint256 public immutable BASE_LIQUIDATION_THRESHOLD;
    uint256 public immutable override LIQUIDATION_BONUS;
    uint256 public immutable WEEKEND_BUFFER_BPS;

    mapping(address user => uint256) internal _balances;
    uint256 public override totalInternalBalance;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Seized(address indexed from, address indexed to, uint256 amount, uint256 value);
    event OracleUpdated(address indexed newOracle);

    error OnlyPool();
    error AmountZero();
    error InsufficientPositionBalance();
    error InvalidData();
    error InvalidRiskParams();

    constructor(
        address pool,
        IERC4626 wrapper,
        bytes32 ticker,
        StockOracle oracle_,
        uint8 poolDecimals,
        address admin,
        uint256 maxLtvBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps,
        uint256 weekendBufferBps
    ) Ownable(admin) {
        if (maxLtvBps == 0 || maxLtvBps >= liquidationThresholdBps) {
            revert InvalidRiskParams();
        }
        if (liquidationThresholdBps > BPS || liquidationBonusBps > 3_000) revert InvalidRiskParams();
        // The closed-market threshold must still sit above the max LTV,
        // otherwise a position opened at max LTV on Friday would be
        // liquidatable the second the market closes.
        if (weekendBufferBps >= liquidationThresholdBps - maxLtvBps) revert InvalidRiskParams();
        if (poolDecimals > 18) revert InvalidRiskParams();
        POOL = pool;
        WRAPPER = wrapper;
        TICKER = ticker;
        oracle = oracle_;
        USD_TO_POOL = 10 ** (18 - poolDecimals);
        BASE_MAX_LTV = maxLtvBps;
        BASE_LIQUIDATION_THRESHOLD = liquidationThresholdBps;
        LIQUIDATION_BONUS = liquidationBonusBps;
        WEEKEND_BUFFER_BPS = weekendBufferBps;
    }

    modifier onlyPool() {
        if (msg.sender != POOL) revert OnlyPool();
        _;
    }

    // ---- Risk parameters -----------------------------------------------------

    /// @notice Liquidation threshold, tightened while the market is closed.
    function LIQUIDATION_THRESHOLD() public view override returns (uint256) {
        if (oracle.isMarketOpen(TICKER)) return BASE_LIQUIDATION_THRESHOLD;
        return BASE_LIQUIDATION_THRESHOLD - WEEKEND_BUFFER_BPS;
    }

    /// @notice How much can be borrowed against this stock, now.
    /// @dev    Moves with the liquidation threshold, so the distance between
    ///         the two is the same in session and out of it. Lending at the
    ///         weekday maximum against a price that stopped moving on Friday
    ///         would put a new position one Monday gap from liquidation.
    function MAX_LTV() public view override returns (uint256) {
        if (oracle.isMarketOpen(TICKER)) return BASE_MAX_LTV;
        return BASE_MAX_LTV - WEEKEND_BUFFER_BPS;
    }

    function ORACLE_STALENESS_MAX() external view override returns (uint256) {
        return oracle.maxOpenStaleness();
    }

    /// @notice New borrows only while the market is open AND the price is fresh.
    /// @notice Whether the pool may create new debt against this stock.
    /// @dev    A fresh price, and nothing else. The equity session being shut
    ///         tightens the terms above rather than closing the market: these
    ///         are tokens on a chain that does not keep office hours.
    function borrowAllowed() external view override returns (bool) {
        try oracle.getPrice(TICKER) returns (uint256, uint256, bool) {
            return true;
        } catch {
            return false;
        }
    }

    // ---- Valuation -------------------------------------------------------------

    /// @notice Fair value of one full wrapper token (1e18 units), in pool units.
    function wrapperPrice() public view returns (uint256) {
        (uint256 stockUsd,,) = oracle.getPrice(TICKER);
        uint256 basePerWrapper = WRAPPER.convertToAssets(WAD);
        return Math.mulDiv(stockUsd, basePerWrapper, WAD) / USD_TO_POOL;
    }

    function valueOf(uint256 amount) public view override returns (uint256) {
        if (amount == 0) return 0;
        return Math.mulDiv(amount, wrapperPrice(), WAD);
    }

    function getAssetValue(address user, bytes calldata) external view override returns (uint256) {
        return valueOf(_balances[user]);
    }

    function getWithdrawValue(address user, bytes calldata data) external view override returns (uint256) {
        uint256 amount = _decodeAmount(data);
        uint256 bal = _balances[user];
        return valueOf(amount > bal ? bal : amount);
    }

    function getTotalAssetValue(address user) external view override returns (uint256) {
        return valueOf(_balances[user]);
    }

    // ---- Position lifecycle (pool only) ----------------------------------------

    /// @notice Adding collateral is always allowed (it can only improve HF),
    ///         including while the market is closed.
    function deposit(address user, bytes calldata data) external override onlyPool {
        uint256 amount = _decodeAmount(data);
        if (amount == 0) revert AmountZero();
        _balances[user] += amount;
        totalInternalBalance += amount;
        IERC20(address(WRAPPER)).safeTransferFrom(user, address(this), amount);
        emit Deposited(user, amount);
    }

    /// @notice Exit path. No oracle dependency here: the pool runs the HF
    ///         check only if debt remains, so a debt-free user can always exit.
    function withdraw(address user, bytes calldata data) external override onlyPool {
        uint256 amount = _decodeAmount(data);
        if (amount == 0) revert AmountZero();
        uint256 bal = _balances[user];
        if (amount > bal) revert InsufficientPositionBalance();
        unchecked {
            _balances[user] = bal - amount;
            totalInternalBalance -= amount;
        }
        IERC20(address(WRAPPER)).safeTransfer(user, amount);
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
        uint256 price = wrapperPrice(); // reverts on stale price: no blind seizure
        seized = Math.mulDiv(value, WAD, price, Math.Rounding.Ceil);
        if (seized > bal) seized = bal;
        remaining = bal - seized;
        _balances[from] = remaining;
        totalInternalBalance -= seized;
        IERC20(address(WRAPPER)).safeTransfer(to, seized);
        emit Seized(from, to, seized, Math.mulDiv(seized, price, WAD));
    }

    /// @notice Full seizure, kept for `IAssetAdapter` compatibility. The Arrow
    ///         pool uses `seizeValue` instead.
    function transferAsset(address from, bytes calldata, address to) external override onlyPool {
        uint256 bal = _balances[from];
        if (bal == 0) revert InsufficientPositionBalance();
        _balances[from] = 0;
        totalInternalBalance -= bal;
        IERC20(address(WRAPPER)).safeTransfer(to, bal);
        emit Seized(from, to, bal, 0);
    }

    // ---- Identification / validation -------------------------------------------

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
        return address(WRAPPER);
    }

    function getAssetType() external pure override returns (string memory) {
        return "xStock (Backed) wrapped share";
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

    // ---- Owner -------------------------------------------------------------------

    function setPriceOracle(address newOracle) external override onlyOwner {
        oracle = StockOracle(newOracle);
        emit OracleUpdated(newOracle);
    }

    function _decodeAmount(bytes calldata data) internal pure returns (uint256 amount) {
        if (data.length == 0) return 0;
        if (data.length != 32) revert InvalidData();
        amount = abi.decode(data, (uint256));
    }
}

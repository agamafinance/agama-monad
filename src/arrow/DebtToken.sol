// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";
import {WadRayMath} from "./libs/WadRayMath.sol";

/// @title DebtToken
/// @notice Non-transferable, ERC20-compliant scaled debt token. Mirrors Aave
///         V2's VariableDebtToken pattern, ADAPTED for V3 isolated-position
///         accounting: scaled balances are keyed by `(user, adapter)` pair
///         instead of by user only. Each market (adapter) has its own
///         independent debt counter: borrows, repays, and liquidations
///         scope to a single market.
/// @dev    transfer/transferFrom/approve all revert. Mint/burn restricted to
///         the LendingPool. The token implements IERC20Metadata so wallets
///         and explorers can render it like any other ERC20, but the
///         "balanceOf(user)" displayed there is the AGGREGATE across all
///         markets (no protocol code uses it).
contract DebtToken is IERC20, IERC20Metadata {
    using WadRayMath for uint256;

    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    /// @notice The LendingPool authorized to mint/burn.
    address public immutable POOL;

    /// @notice Underlying asset (e.g. MockUSDr).
    address public immutable UNDERLYING_ASSET;

    /// @notice Scaled debt balance keyed by (user, adapter).
    mapping(address user => mapping(address adapter => uint256)) private _scaledBalances;
    /// @notice Scaled total supply keyed by adapter.
    mapping(address adapter => uint256) private _scaledTotalSupplyByAdapter;
    /// @notice Aggregate scaled supply across all markets (sum). Tracked
    ///         alongside per-market for cheap global-utilization reads.
    uint256 private _scaledTotalSupply;
    /// @notice Per-user aggregate of scaled debt across all markets. Updated
    ///         alongside the per-market mapping. Used ONLY by the aggregate
    ///         view function `totalUserDebtAcrossMarkets`. Core protocol
    ///         logic must NOT read this.
    mapping(address user => uint256) private _scaledTotalByUser;

    event Mint(address indexed user, address indexed adapter, uint256 amount, uint256 index);
    event Burn(address indexed user, address indexed adapter, uint256 amount, uint256 index);

    error OnlyPool();
    error NonTransferable();
    error AmountZero();

    modifier onlyPool() {
        if (msg.sender != POOL) revert OnlyPool();
        _;
    }

    constructor(
        address pool,
        address underlying,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) {
        POOL = pool;
        UNDERLYING_ASSET = underlying;
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    // ---- IERC20Metadata ---------------------------------------------------

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    // ---- IERC20 -----------------------------------------------------------

    /// @notice Aggregate nominal debt across every market.
    function totalSupply() external view returns (uint256) {
        uint256 idx = ILendingPool(POOL).getNormalizedDebt();
        return _scaledTotalSupply.rayMul(idx);
    }

    /// @notice Aggregate nominal debt of `user` across every market.
    /// @dev    DO NOT USE FOR ECONOMIC CHECKS: aggregate view only, exposed
    ///         for IERC20 compliance and UI/event consumers. Core code
    ///         (LendingPool, LiquidationProxy, StabilityPool) MUST call
    ///         `balanceOf(user, adapter)` instead.
    function balanceOf(address user) external view returns (uint256) {
        uint256 idx = ILendingPool(POOL).getNormalizedDebt();
        return _scaledTotalByUser[user].rayMul(idx);
    }

    /// @notice Always reverts: debt tokens are non-transferable.
    function transfer(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    /// @notice Always reverts: debt tokens are non-transferable.
    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    /// @notice Always reverts: debt tokens are non-transferable.
    function approve(address, uint256) external pure returns (bool) {
        revert NonTransferable();
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    // ---- Per-market views (canonical API) --------------------------------

    /// @notice Nominal debt of `user` ON `adapter` at the current pool index.
    ///         This is the CANONICAL accessor: the single number the protocol
    ///         consults for HF checks, repay limits, and liquidation seizure
    ///         caps. Each market is independent: a user can have non-zero
    ///         debt on one adapter and zero on another.
    function balanceOf(address user, address adapter) external view returns (uint256) {
        uint256 idx = ILendingPool(POOL).getNormalizedDebt();
        return _scaledBalances[user][adapter].rayMul(idx);
    }

    /// @notice Per-market scaled supply (raw: not multiplied by index).
    function scaledTotalSupply(address adapter) external view returns (uint256) {
        return _scaledTotalSupplyByAdapter[adapter];
    }

    /// @notice Per-market nominal supply (multiplied by current index).
    function totalSupply(address adapter) external view returns (uint256) {
        uint256 idx = ILendingPool(POOL).getNormalizedDebt();
        return _scaledTotalSupplyByAdapter[adapter].rayMul(idx);
    }

    // ---- Scaled views (Aave parity) --------------------------------------

    function scaledBalanceOf(address user, address adapter) external view returns (uint256) {
        return _scaledBalances[user][adapter];
    }

    function scaledTotalSupply() external view returns (uint256) {
        return _scaledTotalSupply;
    }

    // ---- Aggregate views (UI / events ONLY) ------------------------------

    /// @notice Aggregate nominal debt of `user` across every market.
    /// @dev    DO NOT USE FOR ECONOMIC CHECKS: aggregate view only. Core
    ///         protocol logic MUST use `balanceOf(user, adapter)`. Use this
    ///         for UI summary cards, event payloads, off-chain dashboards.
    function totalUserDebtAcrossMarkets(address user) external view returns (uint256) {
        uint256 idx = ILendingPool(POOL).getNormalizedDebt();
        return _scaledTotalByUser[user].rayMul(idx);
    }

    // ---- Pool-only mutators ----------------------------------------------

    /// @notice Mint `amount` of nominal debt to `user` on `adapter` at the
    ///         current `index`. Increments the per-market mapping AND the
    ///         per-user / global aggregates in lock-step.
    /// @dev    `amountScaled = amount.rayDiv(index)`. Half-up rounding is
    ///         applied via the WadRayMath library.
    function mint(address user, address adapter, uint256 amount, uint256 index)
        external
        onlyPool
        returns (uint256 amountScaled)
    {
        if (amount == 0) revert AmountZero();
        amountScaled = amount.rayDiv(index);
        _scaledBalances[user][adapter] += amountScaled;
        _scaledTotalSupplyByAdapter[adapter] += amountScaled;
        _scaledTotalSupply += amountScaled;
        _scaledTotalByUser[user] += amountScaled;
        emit Transfer(address(0), user, amount);
        emit Mint(user, adapter, amount, index);
    }

    /// @notice Burn `amount` of nominal debt from `user` on `adapter`.
    /// @dev    Caps at the user's per-market scaled balance to handle the
    ///         "repay max" pattern where `amount` may slightly exceed nominal
    ///         due to rounding.
    function burn(address user, address adapter, uint256 amount, uint256 index)
        external
        onlyPool
        returns (uint256 amountScaled)
    {
        if (amount == 0) revert AmountZero();
        uint256 userMarketScaled = _scaledBalances[user][adapter];
        amountScaled = amount.rayDiv(index);
        if (amountScaled > userMarketScaled) amountScaled = userMarketScaled;
        unchecked {
            _scaledBalances[user][adapter] = userMarketScaled - amountScaled;
            _scaledTotalSupplyByAdapter[adapter] -= amountScaled;
            _scaledTotalSupply -= amountScaled;
            _scaledTotalByUser[user] -= amountScaled;
        }
        emit Transfer(user, address(0), amount);
        emit Burn(user, adapter, amount, index);
    }
}

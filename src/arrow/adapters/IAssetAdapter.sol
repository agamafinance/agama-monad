// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IAssetAdapter
/// @notice Uniform interface between the LendingPool and each collateral asset
///         class. Adapters are responsible for valuation, custody of the
///         underlying RWA tokens, and per-user position bookkeeping. The
///         LendingPool itself never holds RWA: it only routes calls.
/// @dev    `bytes data` is opaque to the LendingPool and decoded only by the
///         adapter. V1 encoding (ERC20 collateral): `abi.encode(uint256 amount)`.
///         V1 also enforces "1 user = 1 position per adapter": `getPositionKey`
///         returns a constant per adapter, regardless of `data`.
interface IAssetAdapter {
    // ---- Valuation -------------------------------------------------------

    /// @notice Total USD value of `user`'s collateral in this adapter's position
    ///         identified by `data`. 1e18-fixed (USD).
    function getAssetValue(address user, bytes calldata data) external view returns (uint256);

    /// @notice USD value being withdrawn for the `withdraw(user, data)` call
    ///         (used for HF preview before the underlying transfer happens).
    function getWithdrawValue(address user, bytes calldata data) external view returns (uint256);

    /// @notice Sum of USD value across all positions a user holds in this adapter.
    /// @dev    V1 returns the same as `getAssetValue` for the canonical key,
    ///         since a user has at most one position per adapter.
    function getTotalAssetValue(address user) external view returns (uint256);

    // ---- Position lifecycle (LendingPool-only) ---------------------------

    /// @notice Custody-in: pulls underlying tokens from `user` (caller must have
    ///         approved this adapter) and credits the internal position.
    function deposit(address user, bytes calldata data) external;

    /// @notice Custody-out: debits the internal position and pushes underlying
    ///         tokens back to `user`.
    function withdraw(address user, bytes calldata data) external;

    /// @notice Liquidation hook: transfers underlying from `from`'s position to `to`.
    ///         The adapter must zero out `from`'s position. Used by the
    ///         LendingPool's `finalizeLiquidation` path.
    function transferAsset(address from, bytes calldata data, address to) external;

    // ---- Position identification -----------------------------------------

    /// @notice Computes the storage key for a position from its `data`.
    /// @dev    V1: returns a constant per adapter, ignoring `data`. V2 may
    ///         decode `data` to enable multi-position-per-user.
    function getPositionKey(bytes calldata data) external pure returns (bytes32);

    /// @notice All position keys held by `user`. V1 returns at most one entry.
    function getPositionKeys(address user) external view returns (bytes32[] memory);

    // ---- Validation ------------------------------------------------------

    /// @notice Reverts if `data` is malformed or the user's position invariants
    ///         don't hold (e.g. amount > internal balance). Read-only.
    function validate(address user, bytes calldata data) external view;

    /// @notice Returns true iff `data` matches a real liquidatable position
    ///         for `user`. Used to guard `liquidateBorrower` against bad input.
    function validateLiquidationData(address user, bytes calldata data) external view returns (bool);

    // ---- Asset metadata --------------------------------------------------

    function getAssetToken() external view returns (address);

    /// @notice Free-form label of the collateral class (e.g. "AmFi senior tranche").
    function getAssetType() external view returns (string memory);

    /// @notice Whether the adapter supports partial withdrawals (V1 AmFi: true).
    function supportsPartialWithdraw() external view returns (bool);

    /// @notice Raw internal balance (token units, not USD) for `user`'s position
    ///         identified by `data`. Used by the LendingPool's bad-debt
    ///         redistribution to size each borrower's pro-rata weight.
    function getInternalBalance(address user, bytes calldata data) external view returns (uint256);

    /// @notice Sum of internal balances across every active position in this
    ///         adapter. Updated synchronously on deposit / withdraw / seize.
    function totalInternalBalance() external view returns (uint256);

    // ---- Risk parameters (per adapter, immutable in V1) ------------------

    /// @notice Borrow LTV cap, basis points (e.g. 7000 = 70%).
    function MAX_LTV() external view returns (uint256);

    /// @notice Liquidation LTV (LLTV), basis points; HF goes below 1 once
    ///         debt × 1e4 / (collateralValue × LIQUIDATION_THRESHOLD) > 1.
    function LIQUIDATION_THRESHOLD() external view returns (uint256);

    /// @notice Bonus seized on liquidation, basis points.
    function LIQUIDATION_BONUS() external view returns (uint256);

    /// @notice Max age (seconds) of the oracle reading before the adapter rejects.
    function ORACLE_STALENESS_MAX() external view returns (uint256);

    // ---- Oracle management (owner-only on the adapter) -------------------

    function setPriceOracle(address newOracle) external;
}

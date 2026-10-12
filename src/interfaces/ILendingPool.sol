// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ILendingPool
/// @notice Minimal surface used by satellite contracts (DebtToken, adapters,
///         StabilityPool, SettlementVault). Full surface lives on the
///         LendingPool itself.
interface ILendingPool {
    /// @notice Current usage (debt) index, RAY-scaled, projected to `block.timestamp`.
    function getNormalizedDebt() external view returns (uint256);

    /// @notice Current liquidity (deposit) index, RAY-scaled, projected to now.
    function getNormalizedIncome() external view returns (uint256);

    /// @notice Asset token used as the reserve (e.g. MockUSDr address).
    function asset() external view returns (address);
}

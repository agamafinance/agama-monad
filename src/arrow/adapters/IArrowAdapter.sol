// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAssetAdapter} from "./IAssetAdapter.sol";

/// @title IArrowAdapter
/// @notice Extension of `IAssetAdapter` used by the Arrow lending pool on
///         X Layer. Three additions over the base interface:
///           - `borrowAllowed`: an adapter can refuse NEW exposure (market
///             closed, stale price, NAV circuit breaker) without blocking
///             repayments, withdrawals or liquidations.
///           - `valueOf`: fair value of a token amount, in pool-asset base
///             units (USDC, 6 decimals). Used by the StabilityPool to price
///             seized collateral.
///           - `seizeValue`: partial seizure. The pool asks for a VALUE
///             (debt absorbed plus the liquidation bonus), the adapter
///             converts it into tokens at the fair price. The rest of the
///             collateral stays with the borrower.
/// @dev    Unit convention for every Arrow adapter: `getAssetValue`,
///         `getWithdrawValue`, `getTotalAssetValue`, `valueOf` and the
///         `value` argument of `seizeValue` are all denominated in the pool
///         asset's base units (1 USDC = 1e6). The HF math in the pool
///         compares them directly with debt amounts.
interface IArrowAdapter is IAssetAdapter {
    /// @notice False when the adapter refuses to back a new borrow.
    function borrowAllowed() external view returns (bool);

    /// @notice Fair value of `amount` collateral tokens, in pool-asset base
    ///         units. No haircut. Reverts when no trustworthy price exists.
    function valueOf(uint256 amount) external view returns (uint256);

    /// @notice Pool-only. Moves collateral worth `value` (pool-asset base
    ///         units, at fair price) from `from`'s position to `to`. Seizes
    ///         the whole position if it is worth less than `value`.
    /// @return seized Collateral tokens transferred.
    /// @return remaining Collateral tokens left in `from`'s position.
    function seizeValue(address from, uint256 value, address to)
        external
        returns (uint256 seized, uint256 remaining);
}

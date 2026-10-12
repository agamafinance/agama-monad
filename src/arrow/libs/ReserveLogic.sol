// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WadRayMath} from "./WadRayMath.sol";
import {InterestRateModel as IRM} from "./InterestRateModel.sol";

/// @title ReserveLogic
/// @notice Maintains the per-reserve interest indices (liquidity & usage) and
///         the corresponding lender/borrow APRs. Indices are updated on every
///         user-facing entry into the LendingPool via `updateState`.
/// @dev    Uses the Aave V2 linear-approximation pattern:
///             newIndex = oldIndex × (1 + rate × elapsed / SECONDS_PER_YEAR)
///         The error vs continuous compounding is negligible at the time
///         resolutions and rate magnitudes used by V1.
library ReserveLogic {
    using WadRayMath for uint256;

    uint256 internal constant RAY = WadRayMath.RAY;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @param liquidityIndex        RAY: cumulative deposit index, starts at RAY.
    /// @param usageIndex            RAY: cumulative debt index, starts at RAY.
    /// @param currentLiquidityRate  RAY: per-year lender APR.
    /// @param currentBorrowRate     RAY: per-year borrow APR.
    /// @param lastUpdate            Unix seconds; bumped by `updateState`.
    struct ReserveData {
        uint256 liquidityIndex;
        uint256 usageIndex;
        uint256 currentLiquidityRate;
        uint256 currentBorrowRate;
        uint256 lastUpdate;
    }

    event ReserveStateUpdated(
        uint256 liquidityIndex, uint256 usageIndex, uint256 borrowRate, uint256 liquidityRate
    );

    /// @notice Initializes the reserve with both indices at RAY (= 1.0) and
    ///         flat rates. Idempotent only on a zero-state struct; calling on
    ///         an initialized reserve will reset it.
    function init(ReserveData storage r) internal {
        r.liquidityIndex = RAY;
        r.usageIndex = RAY;
        r.currentLiquidityRate = 0;
        r.currentBorrowRate = 0;
        r.lastUpdate = block.timestamp;
    }

    /// @notice Income index projected to `block.timestamp` without mutation.
    function getNormalizedIncome(ReserveData storage r) internal view returns (uint256) {
        if (r.lastUpdate == block.timestamp) return r.liquidityIndex;
        return _projectIndex(r.liquidityIndex, r.currentLiquidityRate, block.timestamp - r.lastUpdate);
    }

    /// @notice Debt index projected to `block.timestamp` without mutation.
    function getNormalizedDebt(ReserveData storage r) internal view returns (uint256) {
        if (r.lastUpdate == block.timestamp) return r.usageIndex;
        return _projectIndex(r.usageIndex, r.currentBorrowRate, block.timestamp - r.lastUpdate);
    }

    /// @notice Materializes index growth since `lastUpdate` into storage and
    ///         bumps the timestamp. Caller invokes this before any state change
    ///         that would affect rates (deposit / borrow / repay / withdraw).
    function updateState(ReserveData storage r) internal {
        if (r.lastUpdate == block.timestamp) return;
        uint256 elapsed = block.timestamp - r.lastUpdate;
        r.liquidityIndex = _projectIndex(r.liquidityIndex, r.currentLiquidityRate, elapsed);
        r.usageIndex = _projectIndex(r.usageIndex, r.currentBorrowRate, elapsed);
        r.lastUpdate = block.timestamp;
    }

    /// @notice Recomputes the lender/borrow rates given a post-action snapshot
    ///         of the reserve's cash and total debt. Caller passes the final
    ///         values; the library does no balance reads.
    /// @param params           IRM parameters.
    /// @param finalCash        USDr balance held by the LendingPool *after* the action.
    /// @param finalTotalDebt   Nominal debt outstanding *after* the action.
    /// @param reserveFactorBps Protocol cut on borrow interest, in BPS.
    function updateInterestRates(
        ReserveData storage r,
        IRM.Params memory params,
        uint256 finalCash,
        uint256 finalTotalDebt,
        uint256 reserveFactorBps
    ) internal {
        (uint256 br, uint256 lr) = IRM.getRates(params, finalCash, finalTotalDebt, reserveFactorBps);
        r.currentBorrowRate = br;
        r.currentLiquidityRate = lr;
        emit ReserveStateUpdated(r.liquidityIndex, r.usageIndex, br, lr);
    }

    // ---- Internal helpers -------------------------------------------------

    function _projectIndex(uint256 index, uint256 ratePerYear, uint256 elapsed)
        private
        pure
        returns (uint256)
    {
        // increment = rate × elapsed / SECONDS_PER_YEAR (RAY)
        uint256 increment = (ratePerYear * elapsed) / SECONDS_PER_YEAR;
        return index.rayMul(RAY + increment);
    }
}

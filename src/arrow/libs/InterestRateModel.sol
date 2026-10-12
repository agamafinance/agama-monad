// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {WadRayMath} from "./WadRayMath.sol";

/// @title InterestRateModel
/// @notice Two-slope kink rate model (Aave/Compound family). All rates are
///         RAY-denominated annual rates (1 RAY = 100% APR). Utilization is in
///         RAY (1 RAY == 100%).
/// @dev Pure stateless math. Callers (e.g. LendingPool) hold the Params in
///      storage and pass them in.
library InterestRateModel {
    using WadRayMath for uint256;

    /// @param baseRate     Borrow APR at zero utilization (RAY).
    /// @param slope1       Additional APR at the kink point (RAY).
    /// @param slope2       Additional APR from kink to 100% utilization (RAY).
    /// @param optimalUtil  Utilization where the curve kinks (RAY, < RAY).
    struct Params {
        uint256 baseRate;
        uint256 slope1;
        uint256 slope2;
        uint256 optimalUtil;
    }

    uint256 internal constant RAY = WadRayMath.RAY;
    uint256 internal constant BPS_DENOM = 10_000;

    error InvalidParams();
    error InvalidReserveFactor();

    /// @notice Returns the V1 default parameter set (in RAY).
    /// @dev BASE 2%, SLOPE_1 8%, SLOPE_2 60%, kink 80%.
    function defaults() internal pure returns (Params memory p) {
        p.baseRate = 0.02e27;
        p.slope1 = 0.08e27;
        p.slope2 = 0.6e27;
        p.optimalUtil = 0.8e27;
    }

    /// @notice Sanity-check a parameter set; reverts on malformed input.
    function validate(Params memory p) internal pure {
        if (p.optimalUtil == 0 || p.optimalUtil >= RAY) revert InvalidParams();
        // baseRate, slope1, slope2 may be zero individually but borrow rate would be flat.
        // Cap absurd values to avoid overflow downstream.
        if (p.baseRate > 10 * RAY || p.slope1 > 10 * RAY || p.slope2 > 100 * RAY) {
            revert InvalidParams();
        }
    }

    /// @notice Computes utilization (RAY).
    /// @dev   utilization = borrowed / (liquidity + borrowed)
    ///        liquidity here is the *cash on hand* (not deposits-minus-borrows).
    ///        Returns 0 if both are zero.
    function utilization(uint256 liquidityCash, uint256 borrowed) internal pure returns (uint256) {
        uint256 total = liquidityCash + borrowed;
        if (total == 0) return 0;
        return borrowed.rayDiv(total);
    }

    /// @notice Computes the borrow APR for a given utilization (RAY).
    function borrowRate(Params memory p, uint256 u) internal pure returns (uint256) {
        if (u <= p.optimalUtil) {
            // base + (u / optimalUtil) * slope1
            return p.baseRate + u.rayDiv(p.optimalUtil).rayMul(p.slope1);
        }
        // base + slope1 + ((u - optimalUtil) / (RAY - optimalUtil)) * slope2
        uint256 excess = (u - p.optimalUtil).rayDiv(RAY - p.optimalUtil);
        return p.baseRate + p.slope1 + excess.rayMul(p.slope2);
    }

    /// @notice Computes the lender APR.
    /// @dev   lenderRate = borrowRate * utilization * (1 - reserveFactor)
    ///        reserveFactorBps in [0, 10000]; 1000 = 10%.
    function lenderRate(uint256 borrowRate_, uint256 u, uint256 reserveFactorBps)
        internal
        pure
        returns (uint256)
    {
        if (reserveFactorBps > BPS_DENOM) revert InvalidReserveFactor();
        uint256 grossLender = borrowRate_.rayMul(u);
        // (1 - rf) in RAY
        uint256 oneMinusRf;
        unchecked {
            oneMinusRf = ((BPS_DENOM - reserveFactorBps) * RAY) / BPS_DENOM;
        }
        return grossLender.rayMul(oneMinusRf);
    }

    /// @notice Convenience wrapper returning (borrow, lender) at once.
    function getRates(Params memory p, uint256 liquidityCash, uint256 borrowed, uint256 reserveFactorBps)
        internal
        pure
        returns (uint256 br, uint256 lr)
    {
        uint256 u = utilization(liquidityCash, borrowed);
        br = borrowRate(p, u);
        lr = lenderRate(br, u, reserveFactorBps);
    }
}

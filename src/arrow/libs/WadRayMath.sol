// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title WadRayMath
/// @notice Fixed-point math in WAD (1e18) and RAY (1e27). Half-up rounding.
/// @dev Patterns adapted from Aave V2/V3. Solc 0.8 checked arithmetic is relied upon
///      for the multiplications; the unchecked blocks only contain divisions that
///      cannot overflow once the multiplication has succeeded.
library WadRayMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant HALF_WAD = 0.5e18;

    uint256 internal constant RAY = 1e27;
    uint256 internal constant HALF_RAY = 0.5e27;

    uint256 internal constant WAD_RAY_RATIO = 1e9;
    uint256 internal constant HALF_WAD_RAY_RATIO = 0.5e9;

    error MulOverflow();
    error DivByZero();

    /// @notice (a * b + HALF_WAD) / WAD with half-up rounding.
    function wadMul(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (a == 0 || b == 0) return 0;
        // overflow check: a * b + HALF_WAD must fit in uint256
        if (a > (type(uint256).max - HALF_WAD) / b) revert MulOverflow();
        unchecked {
            c = (a * b + HALF_WAD) / WAD;
        }
    }

    /// @notice (a * WAD + b/2) / b with half-up rounding.
    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (b == 0) revert DivByZero();
        uint256 halfB = b / 2;
        if (a > (type(uint256).max - halfB) / WAD) revert MulOverflow();
        unchecked {
            c = (a * WAD + halfB) / b;
        }
    }

    /// @notice (a * b + HALF_RAY) / RAY with half-up rounding.
    function rayMul(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (a == 0 || b == 0) return 0;
        if (a > (type(uint256).max - HALF_RAY) / b) revert MulOverflow();
        unchecked {
            c = (a * b + HALF_RAY) / RAY;
        }
    }

    /// @notice (a * RAY + b/2) / b with half-up rounding.
    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (b == 0) revert DivByZero();
        uint256 halfB = b / 2;
        if (a > (type(uint256).max - halfB) / RAY) revert MulOverflow();
        unchecked {
            c = (a * RAY + halfB) / b;
        }
    }

    /// @notice Casts a RAY to a WAD with half-up rounding (drops 9 decimals).
    function rayToWad(uint256 a) internal pure returns (uint256 b) {
        unchecked {
            b = a / WAD_RAY_RATIO;
            uint256 remainder = a % WAD_RAY_RATIO;
            if (remainder >= HALF_WAD_RAY_RATIO) b += 1;
        }
    }

    /// @notice Casts a WAD to a RAY (adds 9 decimals).
    function wadToRay(uint256 a) internal pure returns (uint256 b) {
        // a * 1e9 cannot overflow if a fits in uint256/1e9 (>~1e68 WAD); guard anyway
        if (a > type(uint256).max / WAD_RAY_RATIO) revert MulOverflow();
        unchecked {
            b = a * WAD_RAY_RATIO;
        }
    }
}

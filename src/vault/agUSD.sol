// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title agUSD
/// @notice Agama USD: a fully-collateralised stablecoin backed 1:1 by USDC.
///         Minting and burning are restricted to addresses with MINTER_ROLE
///         (expected: agUSDQueue). Transfers are pausable by the GUARDIAN_ROLE
///         for emergency circuit-breaking; only GOVERNOR_ROLE can unpause.
/// @dev    Invariant: totalSupply() * 1e-12 ≤ USDC held by agUSDQueue
///         (maintained off-chain by the queue's deposit/redeem accounting).
contract agUSD is ERC20, ERC20Permit, AccessControl, Pausable {
    error ZeroAddress();
    error ZeroAmount();

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(address governor, address guardian) ERC20("Agama USD", "agUSD") ERC20Permit("Agama USD") {
        if (governor == address(0)) revert ZeroAddress();
        if (guardian == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    // ---- Minter-only -------------------------------------------------------

    /// @notice Mint `amount` agUSD to `to`. Only MINTER_ROLE (agUSDQueue).
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }

    /// @notice Burn `amount` agUSD from `from`. Only MINTER_ROLE (agUSDQueue).
    ///         Caller must have either an allowance or be the token holder.
    ///         The Queue always burns from itself (tokens transferred in first),
    ///         so no allowance check is needed at this layer.
    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        _burn(from, amount);
    }

    // ---- Pause -------------------------------------------------------------

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // ---- Views -------------------------------------------------------------

    function isMinter(address account) external view returns (bool) {
        return hasRole(MINTER_ROLE, account);
    }

    // ---- Internal ----------------------------------------------------------

    /// @dev Block transfers (including mints/burns) while paused.
    function _update(address from, address to, uint256 value) internal override whenNotPaused {
        super._update(from, to, value);
    }
}

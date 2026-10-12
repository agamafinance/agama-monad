// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IsagUSD} from "./interfaces/IsagUSD.sol";

/// @title sagUSD
/// @notice Staked Agama USD: an ERC-4626 vault that accrues yield from the
///         Agama private-credit strategy. Users deposit agUSD and receive
///         sagUSD shares. Yield is pushed into the vault by the Queue via a
///         direct agUSD mint, which increases totalAssets() and therefore the
///         share price. sagUSD itself holds no strategy logic.
///
/// @dev    Inflation-attack protection: `_decimalsOffset()` returns 3, giving
///         10^3 virtual shares at genesis. An attacker would need to donate
///         >1000× their deposit to round any other depositor's shares to zero.
///         See OZ ERC4626 "Defending against the Inflation Attack" docs.
///
///         Pause semantics: GUARDIAN_ROLE pauses; GOVERNOR_ROLE unpauses.
///         Pausing blocks deposit/mint/withdraw/redeem. Yield can still be
///         pushed (totalAssets increases): share price is not frozen.
contract sagUSD is IsagUSD, ERC4626, AccessControl, Pausable, ReentrancyGuard {
    using Math for uint256;

    // ---- Roles / constants -------------------------------------------------

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @notice Held by agUSDQueue: the only address authorised to syncYield.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant MAX_FEE_BPS = 2_000; // 20 %
    uint256 public constant BPS_DENOM = 10_000;

    uint256 public protocolFeeBps;
    address public feeRecipient;

    constructor(
        address agUSD_,
        address governor,
        address guardian,
        address operator,
        uint256 initialFeeBps,
        address initialFeeRecipient
    ) ERC4626(IERC20(agUSD_)) ERC20("Staked Agama USD", "sagUSD") {
        if (agUSD_ == address(0)) revert ZeroAddress();
        if (governor == address(0)) revert ZeroAddress();
        if (guardian == address(0)) revert ZeroAddress();
        if (operator == address(0)) revert ZeroAddress();
        if (initialFeeRecipient == address(0)) revert ZeroAddress();
        if (initialFeeBps > MAX_FEE_BPS) revert FeeTooHigh();

        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(OPERATOR_ROLE, operator);

        protocolFeeBps = initialFeeBps;
        feeRecipient = initialFeeRecipient;
    }

    // ---- ERC4626 overrides ------------------------------------------------

    /// @dev 3-decimal offset → 10^3 virtual assets/shares at genesis.
    ///      This makes the cost of a profitable inflation attack ≥ 1000× the
    ///      victim's deposit, which is economically irrational.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /// @dev Block user-facing vault operations while paused.
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner_);
    }

    // ---- ERC-4626: max* return 0 when paused (EIP-4626 compliance) ----------

    function maxDeposit(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return paused() ? 0 : type(uint256).max;
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        return paused() ? 0 : super.maxWithdraw(owner_);
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        return paused() ? 0 : super.maxRedeem(owner_);
    }

    // ---- Yield sync -------------------------------------------------------

    /// @notice Push `agUSDAmount` of yield into the vault.
    ///         OPERATOR_ROLE (agUSDQueue) must transfer agUSD to this contract
    ///         BEFORE calling syncYield. The function validates the unaccounted
    ///         balance, charges the protocol fee via share dilution, and emits
    ///         an event for off-chain indexers.
    ///
    ///         Fee accounting: fee shares are minted to feeRecipient such that
    ///         their value equals `feeBps/BPS_DENOM` of the gross yield. The
    ///         remaining yield stays in the vault, lifting the share price for
    ///         all existing holders.
    ///
    ///         Formula (derived from value conservation):
    ///           feeShares = feeBps * Y * S / (BPS_DENOM * A + (BPS_DENOM - feeBps) * Y)
    ///         where A = totalAssets() BEFORE yield, S = totalSupply() BEFORE fee,
    ///         Y = gross yield amount.
    function syncYield(uint256 agUSDAmount) external onlyRole(OPERATOR_ROLE) {
        if (agUSDAmount == 0) revert ZeroAmount();
        uint256 currentBalance = IERC20(asset()).balanceOf(address(this));
        uint256 prevAssets = currentBalance - agUSDAmount; // reverts on underflow if not pre-transferred

        uint256 feeBps = protocolFeeBps;
        uint256 feeShares;
        if (feeBps > 0) {
            uint256 S = totalSupply();
            if (S > 0) {
                // feeShares = feeBps * Y * S / (BPS_DENOM * A + (BPS_DENOM - feeBps) * Y)
                // Split into mulDiv to prevent intermediate overflow:
                //   numerator   = feeBps * Y  (max: 2000 * 1e45 ≈ 2e48, safe)
                //   denominator = BPS_DENOM * A + (BPS_DENOM - feeBps) * Y
                uint256 num = feeBps * agUSDAmount;
                uint256 denom = BPS_DENOM * prevAssets + (BPS_DENOM - feeBps) * agUSDAmount;
                feeShares = Math.mulDiv(num, S, denom); // floor → conservative for fee recipient
            }
        }

        if (feeShares > 0) {
            _mint(feeRecipient, feeShares);
        }

        emit YieldSynced(agUSDAmount, feeShares);
    }

    // ---- Pause -------------------------------------------------------------

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // ---- Governance --------------------------------------------------------

    function setProtocolFee(uint256 newFeeBps) external onlyRole(GOVERNOR_ROLE) {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit ProtocolFeeUpdated(protocolFeeBps, newFeeBps);
        protocolFeeBps = newFeeBps;
    }

    function setFeeRecipient(address newRecipient) external onlyRole(GOVERNOR_ROLE) {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }
}

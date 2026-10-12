// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Custom extension interface for sagUSD. Does NOT inherit IERC4626 to
///         avoid C3-linearisation conflicts when sagUSD inherits both this and
///         ERC4626. The full ERC-4626 surface is available on sagUSD directly.
interface IsagUSD {
    event YieldSynced(uint256 agUSDAmount, uint256 feeSharesMinted);
    event ProtocolFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    error ZeroAmount();
    error ZeroAddress();
    error FeeTooHigh();

    /// @notice Push `agUSDAmount` of yield into the vault.
    ///         The agUSD must have been minted to sagUSD BEFORE this call.
    ///         Fee shares are minted to feeRecipient; remaining yield lifts share price.
    function syncYield(uint256 agUSDAmount) external;

    /// @notice Current protocol fee on yield, in basis points (max 2000 = 20%).
    function protocolFeeBps() external view returns (uint256);

    /// @notice Address that receives the protocol fee shares on each syncYield.
    function feeRecipient() external view returns (address);
}

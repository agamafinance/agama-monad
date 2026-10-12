// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReserveLogic} from "../arrow/libs/ReserveLogic.sol";

/// @title IArrowPool
/// @notice Surface of the Arrow lending pool used by Agama accounts and routers.
interface IArrowPool {
    function asset() external view returns (address);
    function vaultOpened(address user) external view returns (bool);
    function openVaultPosition() external;
    function depositAsset(address adapter, bytes calldata data) external;
    function withdrawAsset(address adapter, bytes calldata data) external;
    function borrow(address adapter, bytes calldata data, uint256 amount) external;
    function repay(address adapter, bytes calldata data, uint256 amount) external returns (uint256 paid);
    function calculateHealthFactor(address adapter, address user, bytes calldata data)
        external
        view
        returns (uint256);
    /// @notice Actual debt of `user` on `adapter`, accrued interest included.
    function getPositionScaledDebt(address adapter, address user, bytes calldata data)
        external
        view
        returns (uint256);
    function getReserveState() external view returns (ReserveLogic.ReserveData memory);
    function minBorrowAmount() external view returns (uint256);
    function totalAssets() external view returns (uint256);
}

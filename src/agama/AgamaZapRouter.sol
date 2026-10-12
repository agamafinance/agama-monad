// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {AgamaEarnRouter} from "./AgamaEarnRouter.sol";
import {IArrowAdapter} from "../arrow/adapters/IArrowAdapter.sol";

/// @title AgamaZapRouter
/// @notice "Buy and Earn" in one transaction: USDC in, the OKX DEX aggregator
///         buys the wrapped xStock, and the position opens on Arrow right
///         after, all from the user's wallet.
///
///         The swap calldata is built off-chain by the OKX Onchain OS DEX API
///         (`/api/v6/dex/aggregator/swap`) with this contract as the wallet.
///         Only addresses the governor allowlisted can be called or approved,
///         and the amount bought is measured as a balance delta and checked
///         against `minStockOut`, so a bad route cannot silently underdeliver.
///
/// @dev    The contract holds nothing between transactions: leftovers go back
///         to the user at the end of the call.
contract AgamaZapRouter is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    AgamaEarnRouter public immutable EARN;
    IERC20 public immutable USDC;

    /// @notice Contracts the zap may call with aggregator calldata (OKX DEX router).
    mapping(address target => bool) public allowedTarget;
    /// @notice Contracts the zap may approve to spend USDC (OKX approve address).
    mapping(address spender => bool) public allowedSpender;

    event TargetSet(address indexed target, bool allowed);
    event SpenderSet(address indexed spender, bool allowed);
    event BoughtAndEarned(
        address indexed user,
        address indexed adapter,
        uint256 usdcIn,
        uint256 stockBought,
        uint256 ltvBps,
        uint256 usdcRefunded
    );

    error TargetNotAllowed(address target);
    error SpenderNotAllowed(address spender);
    error SwapFailed(bytes reason);
    error TooLittleBought(uint256 got, uint256 minOut);
    error AmountZero();

    constructor(AgamaEarnRouter earn, address admin) {
        EARN = earn;
        USDC = IERC20(earn.USDC());
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNOR_ROLE, admin);
    }

    /// @param usdcIn      USDC to spend (the caller must approve this contract).
    /// @param swapTarget  OKX DEX router, from the API response `tx.to`.
    /// @param swapSpender Address to approve, from `/approve-transaction`.
    /// @param swapData    `tx.data` from the API, built for this contract.
    /// @param adapter     Arrow market of the stock being bought.
    /// @param minStockOut Minimum wrapped xStock to receive (API `minReceiveAmount`).
    /// @param ltvBps      LTV of the Earn position opened right after (0 = no borrow).
    function buyAndEarn(
        uint256 usdcIn,
        address swapTarget,
        address swapSpender,
        bytes calldata swapData,
        address adapter,
        uint256 minStockOut,
        uint256 ltvBps
    ) external nonReentrant returns (uint256 bought) {
        if (usdcIn == 0 || minStockOut == 0) revert AmountZero();
        if (!allowedTarget[swapTarget]) revert TargetNotAllowed(swapTarget);
        if (!allowedSpender[swapSpender]) revert SpenderNotAllowed(swapSpender);

        IERC20 stock = IERC20(IArrowAdapter(adapter).getAssetToken());
        uint256 stockBefore = stock.balanceOf(address(this));

        USDC.safeTransferFrom(msg.sender, address(this), usdcIn);
        USDC.forceApprove(swapSpender, usdcIn);
        (bool okCall, bytes memory reason) = swapTarget.call(swapData);
        if (!okCall) revert SwapFailed(reason);
        USDC.forceApprove(swapSpender, 0);

        bought = stock.balanceOf(address(this)) - stockBefore;
        if (bought < minStockOut) revert TooLittleBought(bought, minStockOut);

        stock.forceApprove(address(EARN), bought);
        EARN.openFor(msg.sender, adapter, bought, ltvBps);

        uint256 refund = USDC.balanceOf(address(this));
        if (refund > 0) USDC.safeTransfer(msg.sender, refund);
        emit BoughtAndEarned(msg.sender, adapter, usdcIn, bought, ltvBps, refund);
    }

    // ---- Governance -----------------------------------------------------------

    function setTarget(address target, bool allowed) external onlyRole(GOVERNOR_ROLE) {
        allowedTarget[target] = allowed;
        emit TargetSet(target, allowed);
    }

    function setSpender(address spender, bool allowed) external onlyRole(GOVERNOR_ROLE) {
        allowedSpender[spender] = allowed;
        emit SpenderSet(spender, allowed);
    }

    /// @notice Nothing should ever sit here between transactions; this is the
    ///         way out if a router ever leaves dust behind.
    function sweep(IERC20 token, address to) external onlyRole(GOVERNOR_ROLE) {
        token.safeTransfer(to, token.balanceOf(address(this)));
    }
}

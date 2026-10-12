// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IagUSDQueue {
    // ---- Structs -----------------------------------------------------------

    struct RedemptionRequest {
        address requester; // address that locked agUSD: only they can cancel
        address recipient; // address that receives USDC on fulfillment
        uint256 agUSDLocked; // agUSD held by this contract for this request
        uint256 usdcOwed; // USDC to be returned (= agUSDLocked / SCALAR)
        uint256 timestamp;
        bool processed;
        bool cancelled;
    }

    // ---- Events ------------------------------------------------------------

    event Deposited(address indexed sender, address indexed recipient, uint256 usdcIn, uint256 agUSDOut);
    event RedemptionRequested(
        uint256 indexed requestId,
        address indexed requester,
        address indexed recipient,
        uint256 agUSDLocked,
        uint256 usdcOwed
    );
    event RedemptionProcessed(uint256 indexed requestId, address indexed recipient, uint256 usdcOut);
    event RedemptionCancelled(uint256 indexed requestId, address indexed requester);
    event PrimaryVaultUpdated(address indexed oldVault, address indexed newVault);
    event CreditVaultAdded(address indexed vault);
    event CreditVaultRemoved(address indexed vault);
    event DeployedToVault(address indexed vault, uint256 usdcAmount, uint256 sharesReceived);
    event RecalledFromVault(address indexed vault, uint256 shares, uint256 usdcReceived);
    event YieldSettled(uint256 usdcGross, uint256 usdcFee, uint256 agUSDNetMinted);
    event ReserveRatioUpdated(uint256 oldBps, uint256 newBps);
    event ProtocolFeeUpdated(uint256 oldBps, uint256 newBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event MinDepositUpdated(uint256 oldMin, uint256 newMin);
    event MaxInstantRedemptionUpdated(uint256 oldMax, uint256 newMax);

    // ---- Errors ------------------------------------------------------------

    error ZeroAmount();
    error ZeroAddress();
    error BelowMinDeposit(uint256 amount, uint256 min);
    error RequestNotFound(uint256 requestId);
    error AlreadyProcessed(uint256 requestId);
    error AlreadyCancelled(uint256 requestId);
    error NotRequester(uint256 requestId);
    error VaultAlreadyAdded(address vault);
    error VaultNotFound(address vault);
    error InsufficientReserve(uint256 available, uint256 needed);
    error FeeTooHigh();
    error ReserveRatioTooHigh();
    error QueueEmpty();

    // ---- User-facing -------------------------------------------------------

    function deposit(uint256 usdcAmount, address recipient) external returns (uint256 agUSDOut);
    function requestRedemption(uint256 agUSDAmount, address recipient) external returns (uint256 requestId);
    function cancelRedemption(uint256 requestId) external;

    // ---- Operator ----------------------------------------------------------

    function processRedemptions(uint256 maxCount) external returns (uint256 processed);
    function deployToCreditVault(address vault, uint256 usdcAmount) external returns (uint256 sharesOut);
    function recallFromCreditVault(address vault, uint256 shares) external returns (uint256 usdcOut);
    function settleYield(uint256 usdcGross) external;

    // ---- Governor ----------------------------------------------------------

    function setPrimaryVault(address vault) external;
    function addCreditVault(address vault) external;
    function removeCreditVault(address vault) external;
    function setReserveRatio(uint256 bps) external;
    function setProtocolFee(uint256 bps) external;
    function setFeeRecipient(address recipient) external;
    function setMinDeposit(uint256 amount) external;
    function setMaxInstantRedemption(uint256 amount) external;

    // ---- Views -------------------------------------------------------------

    function primaryVault() external view returns (address);
    function totalUsdcInSystem() external view returns (uint256);
    function usdcReserve() external view returns (uint256);
    function pendingRedemptionUsdcOwed() external view returns (uint256);
    function creditVaults() external view returns (address[] memory);
    function vaultDeployed(address vault) external view returns (uint256);
    function redemptionRequest(uint256 requestId) external view returns (RedemptionRequest memory);
    function queueHead() external view returns (uint256);
    function queueTail() external view returns (uint256);
}

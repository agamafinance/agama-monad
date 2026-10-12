// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IagUSD} from "./interfaces/IagUSD.sol";
import {IsagUSD} from "./interfaces/IsagUSD.sol";
import {IagUSDQueue} from "./interfaces/IagUSDQueue.sol";

/// @title agUSDQueue
/// @custom:xlayer On X Layer the `usdc` slot holds USDC (Paxos, 6 decimals).
/// @notice Central clearinghouse for the Agama USD stablecoin system.
///
///         DEPOSITS : users send USDC, receive agUSD 1:1 (scaled for decimals).
///         REDEMPTIONS: users lock agUSD; the Queue returns USDC either
///           instantly (if reserves allow) or via a FIFO queue when the
///           operator recalls liquidity from credit vaults.
///         CREDIT ROUTING: the operator deploys idle USDC into whitelisted
///           ERC-4626 credit vaults (private-credit strategies) and recalls it
///           when redemptions need filling.
///         YIELD SETTLEMENT: when credit strategies earn USDC, the operator
///           calls settleYield(): the Queue takes its protocol fee in USDC,
///           mints agUSD for the net amount directly to sagUSD, then calls
///           sagUSD.syncYield() so the vault can track the push and optionally
///           charge its own fee-in-shares layer.
///
/// @dev    Decimal accounting:
///           USDC  = 6 decimals
///           agUSD = 18 decimals
///           SCALAR = 10^12: multiply USDC amounts by SCALAR to get agUSD,
///                            divide agUSD amounts by SCALAR to get USDC.
///           Floor rounding on USDC output: any sub-SCALAR agUSD remainder
///           stays in the system, accruing to sagUSD holders as a micro-yield.
///
///         Reentrancy: all state-mutating external functions are nonReentrant.
///         The FIFO redemption queue uses head/tail pointers; cancelled and
///         processed slots are skipped during processRedemptions() to keep
///         gas linear in the number of UNPROCESSED entries.
contract agUSDQueue is IagUSDQueue, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---- Roles -------------------------------------------------------------

    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    /// @notice X Layer addition. Holders (the Arrow StabilityPool) redeem
    ///         instantly regardless of `maxInstantRedemption`, within the
    ///         available reserve: seized vault shares get recycled first.
    bytes32 public constant PRIORITY_ROLE = keccak256("PRIORITY_ROLE");

    // ---- Constants ---------------------------------------------------------

    /// @notice Decimal multiplier: 10^(18-6) = 10^12.
    uint256 public constant SCALAR = 1e12;
    uint256 public constant BPS_DENOM = 10_000;

    uint256 public constant MAX_RESERVE_RATIO_BPS = 5_000; // 50 %
    uint256 public constant MAX_FEE_BPS = 3_000; // 30 %

    // ---- Immutables --------------------------------------------------------

    /// @notice The agUSD ERC-20 token (this contract holds MINTER_ROLE on it).
    IagUSD public immutable agUSD;
    /// @notice USDC ERC-20 (6 decimals).
    IERC20 public immutable usdc;
    /// @notice sagUSD vault: receives minted agUSD on yield settlements.
    IsagUSD public immutable sagUSD;

    // ---- Parameters (GOVERNOR_ROLE) ----------------------------------------

    /// @notice Fraction of total USDC in the system kept liquid as reserve (in BPS).
    ///         Enforced on every deposit via _autoDeployExcess(): any USDC above
    ///         max(targetReserve, pendingRedemptionUsdcOwed) is routed to primaryVault.
    uint256 public reserveRatioBps;

    /// @notice Protocol fee on gross yield (in BPS). Charged in USDC before
    ///         minting agUSD for the net yield portion.
    uint256 public protocolFeeBps;

    /// @notice Destination for the protocol fee in USDC.
    address public feeRecipient;

    /// @notice Minimum USDC per deposit (prevents dust spam).
    uint256 public minDeposit;

    /// @notice Maximum USDC repayable instantly in a single requestRedemption
    ///         call. Larger requests always go to the queue.
    uint256 public maxInstantRedemption;

    /// @notice Default credit vault that receives auto-deployed USDC on every
    ///         deposit. Address(0) disables auto-deployment (USDC stays in reserve).
    ///         Must be whitelisted via addCreditVault() before being set here.
    address public primaryVault;

    // ---- Credit vault registry ---------------------------------------------

    address[] private _vaultList;
    mapping(address vault => bool) public isVault;
    /// @notice USDC currently deployed to each vault (tracked on deposit/recall).
    mapping(address vault => uint256) public vaultDeployed;
    uint256 public totalUsdcDeployed;

    // ---- Redemption queue --------------------------------------------------

    /// @notice All requests ever created; slots are never deleted.
    mapping(uint256 id => RedemptionRequest) private _requests;
    uint256 public nextRequestId = 1;
    /// @notice Oldest potentially-unprocessed request ID.
    uint256 public queueHead = 1;
    /// @notice Sum of usdcOwed across all pending (not yet processed/cancelled) requests.
    uint256 public pendingRedemptionUsdcOwed;

    // ---- Yield accounting --------------------------------------------------

    uint256 public totalYieldSettledUsdc;

    // ---- Anti-circularity (X Layer addition) --------------------------------

    /// @notice The lending pool that accepts sagUSD as collateral. The vault
    ///         must NEVER lend into it: a vault that funds loans backed by its
    ///         own shares is the Stream xUSD / Elixir deUSD loop. Set once.
    address public forbiddenVault;

    error ForbiddenVault(address vault);
    error ForbiddenVaultAlreadySet();
    event ForbiddenVaultSet(address vault);

    // ---- Constructor -------------------------------------------------------

    constructor(
        address agUSD_,
        address usdc_,
        address sagUSD_,
        address governor,
        address guardian,
        address operator,
        uint256 initialReserveRatioBps,
        uint256 initialFeeBps,
        address initialFeeRecipient,
        uint256 initialMinDeposit,
        uint256 initialMaxInstantRedemption
    ) {
        if (agUSD_ == address(0)) revert ZeroAddress();
        if (usdc_ == address(0)) revert ZeroAddress();
        if (sagUSD_ == address(0)) revert ZeroAddress();
        if (governor == address(0)) revert ZeroAddress();
        if (guardian == address(0)) revert ZeroAddress();
        if (operator == address(0)) revert ZeroAddress();
        if (initialFeeRecipient == address(0)) revert ZeroAddress();
        if (initialReserveRatioBps > MAX_RESERVE_RATIO_BPS) revert ReserveRatioTooHigh();
        if (initialFeeBps > MAX_FEE_BPS) revert FeeTooHigh();

        agUSD = IagUSD(agUSD_);
        usdc = IERC20(usdc_);
        sagUSD = IsagUSD(sagUSD_);

        _grantRole(DEFAULT_ADMIN_ROLE, governor);
        _grantRole(GOVERNOR_ROLE, governor);
        _grantRole(GUARDIAN_ROLE, guardian);
        _grantRole(OPERATOR_ROLE, operator);

        reserveRatioBps = initialReserveRatioBps;
        protocolFeeBps = initialFeeBps;
        feeRecipient = initialFeeRecipient;
        minDeposit = initialMinDeposit;
        maxInstantRedemption = initialMaxInstantRedemption;
    }

    // ---- User: deposit -----------------------------------------------------

    /// @notice Deposit `usdcAmount` USDC and receive `agUSDOut` agUSD (1:1).
    ///         Caller must have approved this contract for `usdcAmount` USDC.
    /// @param  usdcAmount  Amount of USDC to deposit (6-decimal).
    /// @param  recipient   Address that receives the agUSD.
    /// @return agUSDOut    agUSD minted (= usdcAmount * SCALAR).
    function deposit(uint256 usdcAmount, address recipient)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 agUSDOut)
    {
        if (usdcAmount < minDeposit) revert BelowMinDeposit(usdcAmount, minDeposit);
        if (recipient == address(0)) revert ZeroAddress();

        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        agUSDOut = usdcAmount * SCALAR;
        agUSD.mint(recipient, agUSDOut);

        emit Deposited(msg.sender, recipient, usdcAmount, agUSDOut);

        // Immediately route any USDC above the target reserve into the primary vault.
        _autoDeployExcess();
    }

    // ---- User: redemption --------------------------------------------------

    /// @notice Lock `agUSDAmount` agUSD and request USDC back.
    ///         Caller must have approved this contract for `agUSDAmount` agUSD.
    ///         If the USDC reserve is sufficient AND the redemption is within
    ///         `maxInstantRedemption`, the USDC is sent immediately. Otherwise
    ///         the request is queued; the operator calls processRedemptions()
    ///         after recalling liquidity from credit vaults.
    /// @param  agUSDAmount  Amount of agUSD to burn (18-decimal).
    /// @param  recipient    Address that will receive USDC.
    /// @return requestId    Queue ID (0 if instantly processed).
    function requestRedemption(uint256 agUSDAmount, address recipient)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (agUSDAmount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        // Transfer agUSD from caller to this contract (held until processed/cancelled).
        IERC20(address(agUSD)).safeTransferFrom(msg.sender, address(this), agUSDAmount);

        uint256 usdcOwed = agUSDAmount / SCALAR; // floor: dust stays in system
        if (usdcOwed == 0) revert ZeroAmount();

        // Attempt instant redemption.
        uint256 reserve = usdcReserve();
        bool priority = hasRole(PRIORITY_ROLE, msg.sender);
        if ((priority || usdcOwed <= maxInstantRedemption) && reserve >= usdcOwed) {
            agUSD.burn(address(this), agUSDAmount);
            usdc.safeTransfer(recipient, usdcOwed);
            emit RedemptionProcessed(0, recipient, usdcOwed);
            return 0;
        }

        // Queue the request.
        requestId = nextRequestId++;
        _requests[requestId] = RedemptionRequest({
            requester: msg.sender,
            recipient: recipient,
            agUSDLocked: agUSDAmount,
            usdcOwed: usdcOwed,
            timestamp: block.timestamp,
            processed: false,
            cancelled: false
        });
        pendingRedemptionUsdcOwed += usdcOwed;

        emit RedemptionRequested(requestId, msg.sender, recipient, agUSDAmount, usdcOwed);
    }

    /// @notice Cancel a pending redemption and reclaim the locked agUSD.
    ///         Only the original requester (stored at request creation) can cancel.
    ///         The locked agUSD is returned to `req.requester`, not necessarily msg.sender,
    ///         so the requester can cancel from any wallet that calls on their behalf.
    ///
    /// @dev    OPERATOR_ROLE can also trigger cancellations via processRedemptions
    ///         skip logic, but cannot forcibly cancel an individual request on behalf
    ///         of a user: the agUSD would only go back to the original requester.
    function cancelRedemption(uint256 requestId) external nonReentrant {
        RedemptionRequest storage req = _requests[requestId];
        if (req.agUSDLocked == 0) revert RequestNotFound(requestId);
        if (req.processed) revert AlreadyProcessed(requestId);
        if (req.cancelled) revert AlreadyCancelled(requestId);
        if (msg.sender != req.requester) revert NotRequester(requestId);

        req.cancelled = true;
        pendingRedemptionUsdcOwed -= req.usdcOwed;

        IERC20(address(agUSD)).safeTransfer(req.requester, req.agUSDLocked);

        emit RedemptionCancelled(requestId, req.requester);
    }

    // ---- Operator: process queue -------------------------------------------

    /// @notice Process up to `maxCount` pending redemptions in FIFO order.
    ///         Burns agUSD and sends USDC for each processed entry.
    ///         Reverts if the USDC reserve is insufficient for ANY entry in the
    ///         batch: operator should recall from credit vaults first.
    /// @return processed  Number of redemptions actually settled.
    function processRedemptions(uint256 maxCount)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
        returns (uint256 processed)
    {
        uint256 head = queueHead;
        uint256 tail = nextRequestId;
        if (head >= tail) return 0; // nothing queued: no-op, not an error

        uint256 reserve = usdcReserve();

        for (uint256 id = head; id < tail && processed < maxCount; ++id) {
            RedemptionRequest storage req = _requests[id];

            // Advance head past settled slots.
            if (req.processed || req.cancelled) {
                if (id == queueHead) queueHead = id + 1;
                continue;
            }

            if (reserve < req.usdcOwed) {
                // Insufficient funds: stop; operator must recall more liquidity.
                break;
            }

            req.processed = true;
            reserve -= req.usdcOwed;
            pendingRedemptionUsdcOwed -= req.usdcOwed;

            agUSD.burn(address(this), req.agUSDLocked);
            usdc.safeTransfer(req.recipient, req.usdcOwed);

            emit RedemptionProcessed(id, req.recipient, req.usdcOwed);
            ++processed;

            if (id == queueHead) queueHead = id + 1;
        }
    }

    // ---- Operator: credit vault routing ------------------------------------

    /// @notice Deploy `usdcAmount` USDC into a whitelisted ERC-4626 credit
    ///         vault. The vault must have been added by governance.
    function deployToCreditVault(address vault, uint256 usdcAmount)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
        returns (uint256 sharesOut)
    {
        if (!isVault[vault]) revert VaultNotFound(vault);
        if (usdcAmount == 0) revert ZeroAmount();

        // forceApprove resets to 0 then sets, avoiding accumulated allowance from prior reverts.
        usdc.forceApprove(vault, usdcAmount);
        sharesOut = IERC4626(vault).deposit(usdcAmount, address(this));
        // Reset allowance after use: belt-and-suspenders against vault calling transferFrom again.
        usdc.forceApprove(vault, 0);

        vaultDeployed[vault] += usdcAmount;
        totalUsdcDeployed += usdcAmount;

        emit DeployedToVault(vault, usdcAmount, sharesOut);
    }

    /// @notice Recall `shares` from a whitelisted credit vault.
    ///         The actual USDC received may differ from `vaultDeployed` if the
    ///         vault incurred losses (haircut) or earned yield since deployment.
    ///         The function updates `vaultDeployed` by the amount originally
    ///         tracked pro-rata to shares redeemed.
    function recallFromCreditVault(address vault, uint256 shares)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
        returns (uint256 usdcOut)
    {
        if (!isVault[vault]) revert VaultNotFound(vault);
        if (shares == 0) revert ZeroAmount();

        // Snapshot the Queue's own share position before redeeming.
        // Using the Queue's balance (not vault.totalSupply) so other depositors
        // in the same vault don't distort the cost-basis reduction.
        uint256 queueSharesBefore = IERC4626(vault).balanceOf(address(this));

        usdcOut = IERC4626(vault).redeem(shares, address(this), address(this));

        // Reduce tracked deployment proportionally.
        // Full exit (shares == queueSharesBefore): clear entirely.
        // Partial exit: pro-rata on the Queue's own position only.
        uint256 deployedBefore = vaultDeployed[vault];
        uint256 deployedReduction;
        if (shares >= queueSharesBefore) {
            deployedReduction = deployedBefore; // full exit: clear precisely
        } else {
            deployedReduction =
                queueSharesBefore > 0 ? (deployedBefore * shares) / queueSharesBefore : deployedBefore;
        }
        if (deployedReduction > totalUsdcDeployed) deployedReduction = totalUsdcDeployed;

        vaultDeployed[vault] -= deployedReduction;
        totalUsdcDeployed -= deployedReduction;

        emit RecalledFromVault(vault, shares, usdcOut);
    }

    // ---- Operator: yield settlement ----------------------------------------

    /// @notice Settle `usdcGross` of yield earned by the private-credit strategy.
    ///         The USDC must already be in this contract (transferred by the
    ///         operator prior to this call, e.g. via a recall or direct transfer
    ///         from the strategy wallet). This function does NOT pull from caller.
    ///
    ///         Flow:
    ///           1. Charge protocol fee (in USDC) → transfer to feeRecipient.
    ///           2. Mint net agUSD directly to sagUSD (totalAssets increases).
    ///           3. Call sagUSD.syncYield(netAgUSD) for event / optional fee-share.
    ///
    /// @param  usdcGross  Gross USDC yield to settle. Must be ≤ USDC balance
    ///                    of this contract minus any reserve needed for pending
    ///                    redemptions (operator responsibility to check off-chain).
    function settleYield(uint256 usdcGross) external onlyRole(OPERATOR_ROLE) nonReentrant {
        if (usdcGross == 0) revert ZeroAmount();

        // Guard: yield settlement must not consume USDC earmarked for pending redemptions.
        // Pending redemptions have priority; yield is only from surplus USDC.
        uint256 reserve = usdcReserve();
        if (reserve < usdcGross + pendingRedemptionUsdcOwed) {
            revert InsufficientReserve(reserve, usdcGross + pendingRedemptionUsdcOwed);
        }

        uint256 feeUsdc = (usdcGross * protocolFeeBps) / BPS_DENOM;
        uint256 netUsdc = usdcGross - feeUsdc;

        if (feeUsdc > 0) {
            usdc.safeTransfer(feeRecipient, feeUsdc);
        }

        // Mint agUSD for net yield directly to sagUSD.
        uint256 netAgUSD = netUsdc * SCALAR;
        agUSD.mint(address(sagUSD), netAgUSD);

        // Notify sagUSD so it can charge its optional fee-in-shares layer.
        sagUSD.syncYield(netAgUSD);

        totalYieldSettledUsdc += usdcGross;

        emit YieldSettled(usdcGross, feeUsdc, netAgUSD);
    }

    // ---- Governance --------------------------------------------------------

    /// @notice One-shot: records the lending pool this vault must never fund.
    function setForbiddenVault(address vault) external onlyRole(GOVERNOR_ROLE) {
        if (vault == address(0)) revert ZeroAddress();
        if (forbiddenVault != address(0)) revert ForbiddenVaultAlreadySet();
        if (isVault[vault]) revert ForbiddenVault(vault);
        forbiddenVault = vault;
        emit ForbiddenVaultSet(vault);
    }

    function addCreditVault(address vault) external onlyRole(GOVERNOR_ROLE) {
        if (vault == address(0)) revert ZeroAddress();
        if (vault == forbiddenVault) revert ForbiddenVault(vault);
        if (isVault[vault]) revert VaultAlreadyAdded(vault);
        isVault[vault] = true;
        _vaultList.push(vault);
        emit CreditVaultAdded(vault);
    }

    function removeCreditVault(address vault) external onlyRole(GOVERNOR_ROLE) {
        if (!isVault[vault]) revert VaultNotFound(vault);
        // Require operator to have recalled all funds before removing.
        if (vaultDeployed[vault] > 0) revert InsufficientReserve(0, vaultDeployed[vault]);
        isVault[vault] = false;
        // Remove from list (order not preserved: swap-and-pop).
        address[] storage list = _vaultList;
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == vault) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
        emit CreditVaultRemoved(vault);
    }

    function setReserveRatio(uint256 bps) external onlyRole(GOVERNOR_ROLE) {
        if (bps > MAX_RESERVE_RATIO_BPS) revert ReserveRatioTooHigh();
        emit ReserveRatioUpdated(reserveRatioBps, bps);
        reserveRatioBps = bps;
    }

    function setProtocolFee(uint256 bps) external onlyRole(GOVERNOR_ROLE) {
        if (bps > MAX_FEE_BPS) revert FeeTooHigh();
        emit ProtocolFeeUpdated(protocolFeeBps, bps);
        protocolFeeBps = bps;
    }

    function setFeeRecipient(address recipient) external onlyRole(GOVERNOR_ROLE) {
        if (recipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, recipient);
        feeRecipient = recipient;
    }

    /// @dev Enforces a hard floor of 1 USDC (1e6) to prevent dust spam.
    function setMinDeposit(uint256 amount) external onlyRole(GOVERNOR_ROLE) {
        if (amount < 1e6) revert BelowMinDeposit(amount, 1e6);
        emit MinDepositUpdated(minDeposit, amount);
        minDeposit = amount;
    }

    function setMaxInstantRedemption(uint256 amount) external onlyRole(GOVERNOR_ROLE) {
        emit MaxInstantRedemptionUpdated(maxInstantRedemption, amount);
        maxInstantRedemption = amount;
    }

    /// @notice Set the vault that receives auto-deployed USDC on every deposit.
    ///         Pass address(0) to disable auto-deployment.
    ///         The vault must be whitelisted (isVault[vault] == true) unless disabling.
    function setPrimaryVault(address vault) external onlyRole(GOVERNOR_ROLE) {
        if (vault != address(0) && !isVault[vault]) revert VaultNotFound(vault);
        emit PrimaryVaultUpdated(primaryVault, vault);
        primaryVault = vault;
    }

    // ---- Internal ----------------------------------------------------------

    /// @dev Deploy any USDC above the target reserve into primaryVault.
    ///      Called after every user deposit to keep capital working.
    ///
    ///      Reserve floor = max(targetReserve, pendingRedemptionUsdcOwed):
    ///        - targetReserve guarantees a cushion for instant redemptions.
    ///        - pendingRedemptionUsdcOwed ensures queued users are never
    ///          starved by a burst of fresh deposits that get auto-deployed.
    ///
    ///      No-ops silently when:
    ///        - primaryVault is address(0) (auto-deploy disabled)
    ///        - reserve is already at or below the floor
    ///        - excess is zero (nothing to deploy)
    function _autoDeployExcess() internal {
        address vault = primaryVault;
        if (vault == address(0)) return;

        uint256 reserve = usdcReserve();
        uint256 totalUsdc = reserve + totalUsdcDeployed;

        // Target reserve: reserveRatioBps % of total system USDC.
        uint256 targetReserve = (totalUsdc * reserveRatioBps) / BPS_DENOM;

        // Floor: must also cover all pending (queued) redemptions.
        uint256 floor = targetReserve > pendingRedemptionUsdcOwed ? targetReserve : pendingRedemptionUsdcOwed;

        if (reserve <= floor) return;
        uint256 excess = reserve - floor;

        // Deploy excess into primary vault.
        usdc.forceApprove(vault, excess);
        uint256 sharesOut = IERC4626(vault).deposit(excess, address(this));
        usdc.forceApprove(vault, 0);

        vaultDeployed[vault] += excess;
        totalUsdcDeployed += excess;

        emit DeployedToVault(vault, excess, sharesOut);
    }

    // ---- Pause -------------------------------------------------------------

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // ---- Views -------------------------------------------------------------

    /// @notice Current USDC balance held by this contract.
    function usdcReserve() public view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    /// @notice Total USDC value of the system: on-hand reserve + deployed to vaults.
    function totalUsdcInSystem() external view returns (uint256) {
        return usdcReserve() + totalUsdcDeployed;
    }

    function creditVaults() external view returns (address[] memory) {
        return _vaultList;
    }

    function redemptionRequest(uint256 requestId) external view returns (RedemptionRequest memory) {
        return _requests[requestId];
    }

    function queueTail() external view returns (uint256) {
        return nextRequestId;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IArrowPool} from "../interfaces/IArrowPool.sol";
import {IArrowAdapter} from "../arrow/adapters/IArrowAdapter.sol";
import {ArrowVaultShareAdapter} from "../arrow/adapters/ArrowVaultShareAdapter.sol";
import {IagUSDQueue} from "../vault/interfaces/IagUSDQueue.sol";

interface IAgamaAccountFactory {
    function isRouter(address router) external view returns (bool);
    function zapRouter() external view returns (address);
}

interface IAllowedSwapTargets {
    function allowedTarget(address target) external view returns (bool);
    function allowedSpender(address spender) external view returns (bool);
}

/// @title AgamaAccount
/// @notice One account per user (EIP-1167 clone). The account is the
///         borrower of record in the Arrow lending pool, so every position is
///         isolated per user and fully readable on-chain.
///
///         EARN ON YOUR STOCKS
///           stock in -> Arrow borrow USDC at the chosen LTV -> USDC into the
///           Agama vault. The vault shares stay in the account as a FREE
///           buffer (not pledged). If the stock falls, `softDeleverage`
///           (callable by anyone once HF < 1.15) redeems those shares and
///           repays debt back to HF 1.40. The stock is only touched if the
///           yield buffer is gone.
///
///         AMPLIFY
///           USDC in -> vault shares -> pledged in Arrow -> borrow USDC ->
///           vault -> pledge ... until the target leverage (max 3x). Close
///           unwinds in the same loop in reverse. `autoUnwind` (anyone) takes
///           the position back to 1x when the Arrow borrow rate plus a 1%
///           buffer exceeds the vault's realized APY: a loop with negative
///           carry is never left running.
///
/// @dev    Protocol addresses are immutables of the implementation, shared
///         by every clone. Entry points take `user` and accept calls from
///         the owner directly or from a router registered in the factory
///         that forwards its own `msg.sender`.
contract AgamaAccount is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 public constant SOFT_TRIGGER_HF = 1.15e27;
    uint256 public constant SOFT_TARGET_HF = 1.4e27;
    uint256 public constant MAX_LEVERAGE_BPS = 30_000;
    uint256 public constant SPREAD_BUFFER_RAY = 0.01e27;
    uint256 internal constant MAX_LOOPS = 24;
    /// @notice Drift around the target LTV the agents tolerate before acting.
    uint256 public constant REBALANCE_BAND_BPS = 100;
    /// @notice Worst execution a compound may accept, measured against the same
    ///         oracle price the pool uses for the collateral. The caller is not
    ///         the owner, so the owner's protection cannot be the caller's own
    ///         `minStockOut`: a griefer would simply pass 1.
    uint256 public constant MAX_COMPOUND_SLIPPAGE_BPS = 300;

    /// @notice One hop of a stock loop, with the swap that turns one side into
    ///         the other. An aggregator quote is built for one exact amount, so
    ///         a loop needs one quote per hop and the caller brings them all.
    /// @param amount Opening: USDC to borrow. Closing: wrapper shares to sell.
    /// @param minOut Opening: minimum wrapped stock. Closing: minimum USDC.
    struct Hop {
        uint256 amount;
        address swapTarget;
        address swapSpender;
        bytes swapData;
        uint256 minOut;
    }

    IArrowPool public immutable POOL;
    IERC20 public immutable USDC;
    IagUSDQueue public immutable QUEUE;
    IERC4626 public immutable VAULT; // sagUSD
    IERC20 public immutable AGUSD;
    ArrowVaultShareAdapter public immutable VAULT_ADAPTER;
    uint256 internal immutable AG_PER_USDC; // 1e12

    address public owner;
    address public factory;

    /// @notice Stock markets this account has used for Earn. Lets Amplify
    ///         know whether its equity is backing an Earn position.
    address[] public earnMarkets;
    mapping(address adapter => bool) public isEarnMarket;

    /// @notice LTV the owner picked per market, in bps. The agents keep the
    ///         position at that level: the user sets it once and never has to
    ///         come back.
    mapping(address adapter => uint256) public targetLtvBps;

    event EarnOpened(address indexed adapter, uint256 stockAmount, uint256 borrowed, uint256 shares);
    event EarnClosed(address indexed adapter, uint256 repaid, uint256 stockReturned);
    event SoftDeleveraged(address indexed caller, address indexed adapter, uint256 repaid, uint256 hfAfter);
    event Rebalanced(address indexed caller, address indexed adapter, int256 debtDelta, uint256 ltvBpsAfter);
    event CompoundedIntoStock(
        address indexed caller, address indexed adapter, uint256 usdcSpent, uint256 stockAdded
    );
    event AmplifyOpened(uint256 equityUsdc, uint256 debt, uint256 pledgedShares, uint256 loops);
    event AmplifyStockOpened(address indexed adapter, uint256 stockIn, uint256 debt, uint256 hops);
    event AmplifyStockClosed(address indexed adapter, uint256 hops);
    event AmplifyClosed(uint256 repaid, uint256 sharesOut, uint256 usdcOut, bool keptForEarn);
    event AutoUnwound(address indexed caller, uint256 borrowRateRay, uint256 vaultApyRay);

    error AlreadyInitialized();
    error NotAuthorized();
    error HealthFactorOk(uint256 hf);
    error NothingToDeleverage();
    error RedemptionQueued(uint256 requestId);
    error LeverageOutOfRange();
    error Underwater();
    error UnwindIncomplete(uint256 debtLeft);
    error SpreadPositive(uint256 borrowRateRay, uint256 vaultApyRay);
    error AlreadyOnTarget(uint256 ltvBps, uint256 targetBps);
    error NothingToCompound();
    error SwapTargetNotAllowed(address target);
    error SwapFailed(bytes reason);
    error TooLittleStockBought(uint256 got, uint256 minOut);
    error CompoundPriceTooBad(uint256 valueAdded, uint256 floor);
    error InsufficientToRepay(uint256 shortfall);
    error TooLittleUsdcOut(uint256 got, uint256 minOut);

    constructor(IArrowPool pool, IagUSDQueue queue, IERC4626 vault, ArrowVaultShareAdapter vaultAdapter) {
        POOL = pool;
        USDC = IERC20(pool.asset());
        QUEUE = queue;
        VAULT = vault;
        AGUSD = IERC20(vault.asset());
        VAULT_ADAPTER = vaultAdapter;
        AG_PER_USDC = vaultAdapter.ASSET_TO_POOL();
        owner = address(0xdead); // the implementation itself is unusable
    }

    function initialize(address owner_) external {
        if (owner != address(0)) revert AlreadyInitialized();
        owner = owner_;
        factory = msg.sender;
    }

    modifier auth(address user) {
        if (user != owner) revert NotAuthorized();
        if (msg.sender != owner && !IAgamaAccountFactory(factory).isRouter(msg.sender)) {
            revert NotAuthorized();
        }
        _;
    }

    // =====================================================================
    //                              EARN
    // =====================================================================

    /// @notice Stock tokens must already be in the account (the router moves them).
    function earnOpen(address user, address stockAdapter, uint256 stockAmount, uint256 borrowAmount)
        external
        nonReentrant
        auth(user)
    {
        _ensurePoolPosition();
        _recordEarnMarket(stockAdapter);
        IERC20 stock = IERC20(IArrowAdapter(stockAdapter).getAssetToken());
        stock.forceApprove(stockAdapter, stockAmount);
        POOL.depositAsset(stockAdapter, abi.encode(stockAmount));
        uint256 shares;
        if (borrowAmount > 0) {
            POOL.borrow(stockAdapter, "", borrowAmount);
            shares = _toVault(borrowAmount);
        }
        uint256 value = IArrowAdapter(stockAdapter).getAssetValue(address(this), "");
        uint256 debt = POOL.getPositionScaledDebt(stockAdapter, address(this), "");
        targetLtvBps[stockAdapter] = value == 0 ? 0 : (debt * BPS) / value;
        emit EarnOpened(stockAdapter, stockAmount, borrowAmount, shares);
    }

    /// @notice Add stock collateral (tokens already in the account).
    function earnAddCollateral(address user, address stockAdapter, uint256 amount)
        external
        nonReentrant
        auth(user)
    {
        _ensurePoolPosition();
        _recordEarnMarket(stockAdapter);
        IERC20(IArrowAdapter(stockAdapter).getAssetToken()).forceApprove(stockAdapter, amount);
        POOL.depositAsset(stockAdapter, abi.encode(amount));
    }

    /// @notice Repay everything on `stockAdapter` (USDC already in the
    ///         account first, then the free vault shares), return the stock,
    ///         and send leftovers to the owner. If the shares do not cover
    ///         the debt (after a soft deleverage, or when interest outran the
    ///         vault yield), reverts with the exact shortfall: the router's
    ///         `closeWithTopUp` brings it from the owner's wallet.
    /// @param unwrap Hand the base xStock back instead of the ERC-4626 wrapper.
    ///        That is the token an OKX deposit expects, so a user can send the
    ///        position straight back to the exchange.
    function earnClose(address user, address stockAdapter, bool unwrap) external nonReentrant auth(user) {
        _earnClose(stockAdapter, unwrap);
    }

    /// @dev Repay what is left, hand the stock back, sweep the rest. Shared
    ///      with the stock loop, whose hops bring the debt down to nothing
    ///      first and then end here.
    function _earnClose(address stockAdapter, bool unwrap) internal {
        uint256 debt = POOL.getPositionScaledDebt(stockAdapter, address(this), "");
        uint256 repaid;
        if (debt > 0) {
            uint256 have = USDC.balanceOf(address(this));
            if (have < debt) _redeemForUsdc(debt - have);
            uint256 cash = USDC.balanceOf(address(this));
            if (cash < debt) revert InsufficientToRepay(debt - cash);
            USDC.forceApprove(address(POOL), debt);
            repaid = POOL.repay(stockAdapter, "", type(uint256).max);
        }
        uint256 bal = IArrowAdapter(stockAdapter).getInternalBalance(address(this), "");
        if (bal > 0) POOL.withdrawAsset(stockAdapter, abi.encode(bal));
        IERC4626 wrapper = IERC4626(IArrowAdapter(stockAdapter).getAssetToken());
        uint256 held = IERC20(address(wrapper)).balanceOf(address(this));
        if (unwrap && held > 0) {
            wrapper.redeem(held, owner, address(this));
        } else if (held > 0) {
            IERC20(address(wrapper)).safeTransfer(owner, held);
        }
        // The buffer is the account's, not this market's. Sweeping it to the
        // owner while another market still owes USDC would leave that one with
        // nothing to repay from, and its close would then ask the owner for a
        // top-up of money they had just been handed.
        if (!hasEarnDebt()) _sweepFree();
        emit EarnClosed(stockAdapter, repaid, bal);
    }

    /// @notice Permissionless protection. Below HF 1.15 anyone can make the
    ///         account redeem its FREE vault shares to repay debt back to
    ///         HF 1.40. The stock is not sold.
    function softDeleverage(address stockAdapter) external nonReentrant returns (uint256 repaid) {
        uint256 hf = POOL.calculateHealthFactor(stockAdapter, address(this), "");
        if (hf >= SOFT_TRIGGER_HF) revert HealthFactorOk(hf);

        uint256 debt = POOL.getPositionScaledDebt(stockAdapter, address(this), "");
        uint256 value = IArrowAdapter(stockAdapter).getAssetValue(address(this), "");
        uint256 lt = IArrowAdapter(stockAdapter).LIQUIDATION_THRESHOLD();
        uint256 targetDebt = Math.mulDiv(value * lt, RAY, BPS * SOFT_TARGET_HF);
        uint256 wanted = debt > targetDebt ? debt - targetDebt : 0;

        uint256 freeValue = VAULT_ADAPTER.valueOf(VAULT.balanceOf(address(this)));
        uint256 cash = USDC.balanceOf(address(this));
        uint256 amount = Math.min(wanted, freeValue + cash);
        if (amount == 0) revert NothingToDeleverage();

        if (cash < amount) _redeemForUsdc(amount - cash);
        repaid = Math.min(amount, USDC.balanceOf(address(this)));
        USDC.forceApprove(address(POOL), repaid);
        POOL.repay(stockAdapter, "", repaid);
        emit SoftDeleveraged(
            msg.sender, stockAdapter, repaid, POOL.calculateHealthFactor(stockAdapter, address(this), "")
        );
    }

    /// @notice Keep the position at the LTV the owner picked, in both
    ///         directions. Permissionless, so the agents can run it:
    ///         the stock went up, borrow the difference and put it in the
    ///         vault; the stock went down, repay from the yield buffer. The
    ///         user deposits once and never has to manage the position.
    /// @dev    A 1% band around the target avoids churning on every tick.
    function rebalance(address stockAdapter) external nonReentrant returns (int256 debtDelta) {
        uint256 target = targetLtvBps[stockAdapter];
        if (target == 0) revert AlreadyOnTarget(0, 0);

        uint256 value = IArrowAdapter(stockAdapter).getAssetValue(address(this), "");
        uint256 debt = POOL.getPositionScaledDebt(stockAdapter, address(this), "");
        // Nothing pledged and nothing owed: say so, rather than dividing by zero
        // on the way out. The target survives a close, so an agent can land here.
        if (value == 0 && debt == 0) revert AlreadyOnTarget(0, target);
        uint256 wanted = (value * target) / BPS;
        uint256 band = (value * REBALANCE_BAND_BPS) / BPS;

        if (wanted > debt + band) {
            uint256 extra = wanted - debt;
            uint256 minBorrow = POOL.minBorrowAmount();
            if (extra < minBorrow) revert AlreadyOnTarget((debt * BPS) / value, target);
            POOL.borrow(stockAdapter, "", extra);
            _toVault(extra);
            debtDelta = int256(extra);
        } else if (debt > wanted + band) {
            uint256 repayWanted = debt - wanted;
            uint256 cash = USDC.balanceOf(address(this));
            uint256 available = cash + VAULT_ADAPTER.valueOf(VAULT.balanceOf(address(this)));
            uint256 amount = Math.min(repayWanted, available);
            if (amount == 0) revert NothingToDeleverage();
            if (cash < amount) _redeemForUsdc(amount - cash);
            uint256 paid = Math.min(amount, USDC.balanceOf(address(this)));
            USDC.forceApprove(address(POOL), paid);
            POOL.repay(stockAdapter, "", paid);
            debtDelta = -int256(paid);
        } else {
            revert AlreadyOnTarget((debt * BPS) / value, target);
        }

        uint256 newDebt = POOL.getPositionScaledDebt(stockAdapter, address(this), "");
        emit Rebalanced(msg.sender, stockAdapter, debtDelta, value == 0 ? 0 : (newDebt * BPS) / value);
    }

    /// @notice Turn the yield the vault produced into MORE STOCK: the surplus
    ///         above the debt is redeemed, swapped through an allowlisted
    ///         router, and added as collateral. This is what makes the
    ///         position a stock that grows in stock rather than in stablecoin.
    ///         Permissionless, and the swap route is whatever the zap router
    ///         allows, so the agents cannot send the money anywhere else.
    /// @param usdcIn      Exactly what the swap calldata spends. Must not
    ///        exceed the surplus over the debt: the caller and the contract
    ///        have to agree on the amount, or the router would pull USDC the
    ///        account does not have (interest accrues between the two).
    /// @param minStockOut Slippage guard, in wrapped stock units.
    function compoundIntoStock(
        address stockAdapter,
        uint256 usdcIn,
        address swapTarget,
        address swapSpender,
        bytes calldata swapData,
        uint256 minStockOut
    ) external nonReentrant returns (uint256 stockAdded) {
        // Only the surplus over the debt is profit: the rest is the buffer that
        // protects the stock from being liquidated first.
        uint256 debt = POOL.getPositionScaledDebt(stockAdapter, address(this), "");
        uint256 have = redeemableUsdc();
        if (have <= debt || usdcIn == 0 || usdcIn > have - debt) revert NothingToCompound();

        uint256 cash = USDC.balanceOf(address(this));
        if (cash < usdcIn) _redeemForUsdc(usdcIn - cash);
        uint256 spend = usdcIn;
        if (USDC.balanceOf(address(this)) < spend) revert NothingToCompound();

        IERC20 stock = IERC20(IArrowAdapter(stockAdapter).getAssetToken());
        stockAdded = _buyStock(stockAdapter, spend, swapTarget, swapSpender, swapData, minStockOut);
        stock.forceApprove(stockAdapter, stockAdded);
        POOL.depositAsset(stockAdapter, abi.encode(stockAdded));
        emit CompoundedIntoStock(msg.sender, stockAdapter, spend, stockAdded);
    }

    // =====================================================================
    //                             AMPLIFY
    // =====================================================================

    /// @notice Loop the vault up to `leverageBps` (10_000 = 1x, 30_000 = 3x).
    /// @param usdcAmount USDC already moved into the account by the router.
    /// @param useFreeShares Also pledge the account's free shares (Earn
    ///        buffer). Stacks Amplify on top of Earn; the Earn position then
    ///        loses its soft-deleverage buffer.
    function amplifyOpen(address user, uint256 usdcAmount, bool useFreeShares, uint256 leverageBps)
        external
        nonReentrant
        auth(user)
        returns (uint256 debt)
    {
        if (leverageBps < BPS || leverageBps > MAX_LEVERAGE_BPS) revert LeverageOutOfRange();
        _ensurePoolPosition();
        address va = address(VAULT_ADAPTER);

        uint256 toPledge = usdcAmount > 0 ? _toVault(usdcAmount) : 0;
        if (useFreeShares) toPledge = VAULT.balanceOf(address(this));
        _pledge(toPledge);

        debt = POOL.getPositionScaledDebt(va, address(this), "");
        uint256 fair = VAULT_ADAPTER.valueOf(VAULT_ADAPTER.balanceOf(address(this)));
        if (fair <= debt) revert Underwater();
        uint256 equity = fair - debt;
        uint256 targetDebt = (equity * (leverageBps - BPS)) / BPS;
        uint256 minBorrow = POOL.minBorrowAmount();

        uint256 loops;
        for (; loops < MAX_LOOPS && debt < targetDebt; ++loops) {
            uint256 cap = (VAULT_ADAPTER.getAssetValue(address(this), "") * VAULT_ADAPTER.MAX_LTV()) / BPS;
            if (cap <= debt) break;
            uint256 capacity = ((cap - debt) * 995) / 1000;
            uint256 b = Math.min(targetDebt - debt, capacity);
            if (b < minBorrow) break;
            POOL.borrow(va, "", b);
            _pledge(_toVault(b));
            debt += b;
        }
        debt = POOL.getPositionScaledDebt(va, address(this), "");
        emit AmplifyOpened(equity, debt, VAULT_ADAPTER.balanceOf(address(this)), loops);
    }

    /// @notice Unwind the loop and send the equity to the owner, as USDC if
    ///         `redeem` (needs instant liquidity in the vault reserve), as
    ///         vault shares otherwise.
    ///         If an Earn position is still open, the equity stays in the
    ///         account as free vault shares instead: it was the Earn buffer
    ///         before `openFromEarn`, and it goes back to being the buffer.
    function amplifyClose(address user, bool redeem) external nonReentrant auth(user) {
        uint256 repaid = _unwind();
        bool keep = hasEarnDebt();
        (uint256 sharesOut, uint256 usdcOut) = keep ? _unpledgeAll() : _releasePledge(redeem);
        emit AmplifyClosed(repaid, sharesOut, usdcOut, keep);
    }

    /// @notice Permissionless spread guard: if Arrow's borrow rate + 1% is
    ///         above the vault's realized APY, the loop is taken back to 1x.
    ///         Equity stays in the account as free vault shares.
    function autoUnwind() external nonReentrant {
        uint256 apy = VAULT_ADAPTER.realizedApyRay();
        uint256 borrowRate = POOL.getReserveState().currentBorrowRate;
        // apy == 0 means no measured yield yet: do not let anyone unwind blind.
        if (apy == 0 || borrowRate + SPREAD_BUFFER_RAY <= apy) revert SpreadPositive(borrowRate, apy);
        _unwind();
        uint256 bal = VAULT_ADAPTER.balanceOf(address(this));
        if (bal > 0) POOL.withdrawAsset(address(VAULT_ADAPTER), abi.encode(bal));
        emit AutoUnwound(msg.sender, borrowRate, apy);
    }

    // =====================================================================
    //                              OWNER
    // =====================================================================

    /// @notice Owner pulls free tokens (never pledged collateral) out of the account.
    function sweep(IERC20 token) external nonReentrant {
        if (msg.sender != owner) revert NotAuthorized();
        token.safeTransfer(owner, token.balanceOf(address(this)));
    }

    // =====================================================================
    //                              VIEWS
    // =====================================================================

    /// @notice True while any Earn market of this account carries debt.
    function hasEarnDebt() public view returns (bool) {
        for (uint256 i; i < earnMarkets.length; ++i) {
            if (POOL.getPositionScaledDebt(earnMarkets[i], address(this), "") > 0) return true;
        }
        return false;
    }

    function earnMarketCount() external view returns (uint256) {
        return earnMarkets.length;
    }

    function freeShares() external view returns (uint256) {
        return VAULT.balanceOf(address(this));
    }

    function freeSharesValue() external view returns (uint256) {
        return VAULT_ADAPTER.valueOf(VAULT.balanceOf(address(this)));
    }

    /// @notice USDC the account can raise right now for a repayment: cash plus
    ///         free shares at the live redemption rate (what the queue pays).
    function redeemableUsdc() public view returns (uint256) {
        uint256 shares = VAULT.balanceOf(address(this));
        uint256 fromShares = shares == 0 ? 0 : VAULT.convertToAssets(shares) / AG_PER_USDC;
        return USDC.balanceOf(address(this)) + fromShares;
    }

    // =====================================================================
    //                        SWAPS (shared)
    // =====================================================================

    /// @dev Only a venue the zap router allowlisted, and the result is measured
    ///      as a balance delta rather than trusted from the call.
    function _requireAllowedSwap(address target, address spender) internal view {
        IAllowedSwapTargets zap = IAllowedSwapTargets(IAgamaAccountFactory(factory).zapRouter());
        if (!zap.allowedTarget(target) || !zap.allowedSpender(spender)) revert SwapTargetNotAllowed(target);
    }

    /// @dev USDC in the account, stock out and in the account. `minOut` comes
    ///      from the caller, who for `compoundIntoStock` is anybody, so the
    ///      owner's real protection is the second check: what came back has to
    ///      be worth, at the pool's own price, nearly what was spent.
    function _buyStock(
        address stockAdapter,
        uint256 spend,
        address target,
        address spender,
        bytes calldata data,
        uint256 minOut
    ) internal returns (uint256 bought) {
        _requireAllowedSwap(target, spender);
        IERC20 stock = IERC20(IArrowAdapter(stockAdapter).getAssetToken());
        uint256 before = stock.balanceOf(address(this));
        USDC.forceApprove(spender, spend);
        (bool okCall, bytes memory reason) = target.call(data);
        if (!okCall) revert SwapFailed(reason);
        USDC.forceApprove(spender, 0);

        bought = stock.balanceOf(address(this)) - before;
        if (bought < minOut) revert TooLittleStockBought(bought, minOut);
        uint256 valueAdded = IArrowAdapter(stockAdapter).valueOf(bought);
        uint256 floor = (spend * (BPS - MAX_COMPOUND_SLIPPAGE_BPS)) / BPS;
        if (valueAdded < floor) revert CompoundPriceTooBad(valueAdded, floor);
    }

    /// @dev The other direction, for unwinding a stock loop. Same two guards:
    ///      the caller's own floor, and the oracle's, so a bad route cannot
    ///      dump the collateral.
    function _sellStock(
        address stockAdapter,
        uint256 shares,
        address target,
        address spender,
        bytes calldata data,
        uint256 minOut
    ) internal returns (uint256 got) {
        _requireAllowedSwap(target, spender);
        IERC20 stock = IERC20(IArrowAdapter(stockAdapter).getAssetToken());
        uint256 before = USDC.balanceOf(address(this));
        stock.forceApprove(spender, shares);
        (bool okCall, bytes memory reason) = target.call(data);
        if (!okCall) revert SwapFailed(reason);
        stock.forceApprove(spender, 0);

        got = USDC.balanceOf(address(this)) - before;
        if (got < minOut) revert TooLittleUsdcOut(got, minOut);
        uint256 worth = IArrowAdapter(stockAdapter).valueOf(shares);
        uint256 floor = (worth * (BPS - MAX_COMPOUND_SLIPPAGE_BPS)) / BPS;
        if (got < floor) revert CompoundPriceTooBad(got, floor);
    }

    // =====================================================================
    //                      AMPLIFY ON THE STOCK
    // =====================================================================

    /// @notice Leveraged stock. Deposit the stock, then borrow USDC against it,
    ///         buy more of the same stock, deposit that too, and again, for as
    ///         many hops as the caller brought quotes for.
    ///
    ///         What bounds this is not the hop count but the pool: it refuses a
    ///         borrow that would break the health factor. An equity here carries
    ///         a 30 to 50% LTV ceiling, so the series converges quickly, on 1.33x
    ///         for TSLA at a health factor of 1.6 and 1.6x for SPY. A loop that
    ///         promised more would be promising a higher LTV on a thin market.
    ///
    ///         The level reached becomes the target the agents hold, so the same
    ///         `rebalance` that runs an Earn position keeps this one where the
    ///         user left it.
    /// @param stockAmount Wrapped stock already in the account (the router moved it).
    function amplifyStockOpen(address user, address stockAdapter, uint256 stockAmount, Hop[] calldata hops)
        external
        nonReentrant
        auth(user)
        returns (uint256 debt)
    {
        if (hops.length > MAX_LOOPS) revert LeverageOutOfRange();
        _ensurePoolPosition();
        _recordEarnMarket(stockAdapter);
        IERC20 stock = IERC20(IArrowAdapter(stockAdapter).getAssetToken());
        if (stockAmount > 0) {
            stock.forceApprove(stockAdapter, stockAmount);
            POOL.depositAsset(stockAdapter, abi.encode(stockAmount));
        }

        for (uint256 i; i < hops.length; ++i) {
            Hop calldata h = hops[i];
            POOL.borrow(stockAdapter, "", h.amount);
            uint256 bought =
                _buyStock(stockAdapter, h.amount, h.swapTarget, h.swapSpender, h.swapData, h.minOut);
            stock.forceApprove(stockAdapter, bought);
            POOL.depositAsset(stockAdapter, abi.encode(bought));
        }

        debt = POOL.getPositionScaledDebt(stockAdapter, address(this), "");
        uint256 value = IArrowAdapter(stockAdapter).getAssetValue(address(this), "");
        targetLtvBps[stockAdapter] = value == 0 ? 0 : (debt * BPS) / value;
        emit AmplifyStockOpened(stockAdapter, stockAmount, debt, hops.length);
    }

    /// @notice Unwind it: withdraw stock, sell it, repay, repeat, then hand back
    ///         whatever the debt did not eat. Each hop withdraws collateral the
    ///         pool has to agree to release, so the health factor is never
    ///         broken on the way out.
    ///
    ///         If the hops leave debt behind, the close falls back to the Earn
    ///         path: the vault buffer pays, and if there is none it reverts with
    ///         the shortfall rather than half unwinding the position.
    function amplifyStockClose(address user, address stockAdapter, Hop[] calldata hops, bool unwrap)
        external
        nonReentrant
        auth(user)
    {
        for (uint256 i; i < hops.length; ++i) {
            uint256 debt = POOL.getPositionScaledDebt(stockAdapter, address(this), "");
            if (debt == 0) break;
            Hop calldata h = hops[i];
            POOL.withdrawAsset(stockAdapter, abi.encode(h.amount));
            _sellStock(stockAdapter, h.amount, h.swapTarget, h.swapSpender, h.swapData, h.minOut);
            uint256 cash = USDC.balanceOf(address(this));
            uint256 pay = cash < debt ? cash : debt;
            if (pay > 0) {
                USDC.forceApprove(address(POOL), pay);
                POOL.repay(stockAdapter, "", pay);
            }
        }
        targetLtvBps[stockAdapter] = 0;
        _earnClose(stockAdapter, unwrap);
        emit AmplifyStockClosed(stockAdapter, hops.length);
    }

    // =====================================================================
    //                            INTERNALS
    // =====================================================================

    function _ensurePoolPosition() internal {
        if (!POOL.vaultOpened(address(this))) POOL.openVaultPosition();
    }

    function _toVault(uint256 usdc) internal returns (uint256 shares) {
        USDC.forceApprove(address(QUEUE), usdc);
        uint256 agOut = QUEUE.deposit(usdc, address(this));
        AGUSD.forceApprove(address(VAULT), agOut);
        shares = VAULT.deposit(agOut, address(this));
    }

    function _pledge(uint256 shares) internal {
        if (shares == 0) return;
        IERC20(address(VAULT)).forceApprove(address(VAULT_ADAPTER), shares);
        POOL.depositAsset(address(VAULT_ADAPTER), abi.encode(shares));
    }

    /// @dev Redeem enough FREE shares to receive at least `usdcWanted`
    ///      (capped by what the account holds). Instant path only.
    function _redeemForUsdc(uint256 usdcWanted) internal returns (uint256 usdcOut) {
        uint256 shares = VAULT.previewWithdraw(usdcWanted * AG_PER_USDC);
        uint256 bal = VAULT.balanceOf(address(this));
        if (shares > bal) shares = bal;
        usdcOut = _redeemShares(shares);
    }

    function _redeemShares(uint256 shares) internal returns (uint256 usdcOut) {
        if (shares == 0) return 0;
        uint256 agOut = VAULT.redeem(shares, address(this), address(this));
        AGUSD.forceApprove(address(QUEUE), agOut);
        uint256 before = USDC.balanceOf(address(this));
        uint256 requestId = QUEUE.requestRedemption(agOut, address(this));
        if (requestId != 0) revert RedemptionQueued(requestId);
        usdcOut = USDC.balanceOf(address(this)) - before;
    }

    /// @dev Reverse loop: withdraw as many pledged shares as HF allows,
    ///      redeem, repay, repeat.
    function _unwind() internal returns (uint256 repaid) {
        address va = address(VAULT_ADAPTER);
        uint256 lt = VAULT_ADAPTER.LIQUIDATION_THRESHOLD();
        uint256 haircut = VAULT_ADAPTER.HAIRCUT_BPS();
        for (uint256 i; i < MAX_LOOPS; ++i) {
            uint256 debt = POOL.getPositionScaledDebt(va, address(this), "");
            if (debt == 0) return repaid;

            uint256 cash = USDC.balanceOf(address(this));
            if (cash > 0) {
                uint256 p = Math.min(cash, debt);
                USDC.forceApprove(address(POOL), p);
                repaid += POOL.repay(va, "", p);
                continue;
            }

            uint256 bal = VAULT_ADAPTER.balanceOf(address(this));
            uint256 v = VAULT_ADAPTER.getAssetValue(address(this), "");
            uint256 minCollat = Math.mulDiv(debt, BPS, lt, Math.Rounding.Ceil);
            if (v <= minCollat) revert Underwater();
            uint256 maxW = ((v - minCollat) * 99) / 100;
            // Haircut value needed to redeem `debt` USDC, plus 0.5% slack.
            uint256 needW = (debt * (BPS - haircut) * 1005) / (BPS * 1000);
            uint256 w = Math.min(maxW, needW);
            uint256 shares = Math.mulDiv(bal, w, v);
            if (shares == 0) revert Underwater();
            POOL.withdrawAsset(va, abi.encode(shares));
            _redeemShares(shares);
        }
        uint256 left = POOL.getPositionScaledDebt(va, address(this), "");
        if (left > 0) revert UnwindIncomplete(left);
    }

    function _recordEarnMarket(address adapter) internal {
        if (isEarnMarket[adapter]) return;
        isEarnMarket[adapter] = true;
        earnMarkets.push(adapter);
    }

    /// @dev Pledged shares back to the account as free shares (Earn buffer).
    function _unpledgeAll() internal returns (uint256 sharesKept, uint256 usdcKept) {
        uint256 bal = VAULT_ADAPTER.balanceOf(address(this));
        if (bal > 0) POOL.withdrawAsset(address(VAULT_ADAPTER), abi.encode(bal));
        sharesKept = VAULT.balanceOf(address(this));
        usdcKept = USDC.balanceOf(address(this));
    }

    function _releasePledge(bool redeem) internal returns (uint256 sharesOut, uint256 usdcOut) {
        uint256 bal = VAULT_ADAPTER.balanceOf(address(this));
        if (bal > 0) POOL.withdrawAsset(address(VAULT_ADAPTER), abi.encode(bal));
        if (redeem) {
            _redeemShares(bal);
        } else {
            sharesOut = bal;
            IERC20(address(VAULT)).safeTransfer(owner, bal);
        }
        usdcOut = USDC.balanceOf(address(this));
        if (usdcOut > 0) USDC.safeTransfer(owner, usdcOut);
    }

    function _sweepFree() internal {
        uint256 s = VAULT.balanceOf(address(this));
        if (s > 0) IERC20(address(VAULT)).safeTransfer(owner, s);
        uint256 u = USDC.balanceOf(address(this));
        if (u > 0) USDC.safeTransfer(owner, u);
    }
}

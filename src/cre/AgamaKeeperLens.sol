// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AgamaCREReceiver} from "./AgamaCREReceiver.sol";

interface ILensPool {
    function getPositionScaledDebt(address adapter, address user, bytes calldata data)
        external
        view
        returns (uint256);
    function calculateHealthFactor(address adapter, address user, bytes calldata data)
        external
        view
        returns (uint256);
}

interface ILensFactory {
    function accountCount() external view returns (uint256);
    function accounts(uint256 i) external view returns (address);
}

interface ILensAccount {
    function targetLtvBps(address adapter) external view returns (uint256);
    function redeemableUsdc() external view returns (uint256);
    function freeShares() external view returns (uint256);
}

interface ILensStockAdapter {
    function TICKER() external view returns (bytes32);
    function oracle() external view returns (address);
    function WRAPPER() external view returns (address);
    function wrapperPrice() external view returns (uint256);
    function getAssetValue(address user, bytes calldata data) external view returns (uint256);
}

interface ILensOracle {
    struct Feed {
        uint128 price;
        uint64 observedAt;
        bool marketOpen;
        bool exists;
    }

    function feed(bytes32 ticker) external view returns (Feed memory);
}

interface ILensVaultAdapter {
    function snapshotAt() external view returns (uint256);
}

interface IKuruVenueBuy {
    function buy(address wrapper, uint256 usdcIn, uint256 minWrapperOut) external returns (uint256);
}

/// @title AgamaKeeperLens
/// @notice What the `agama-monad` CRE workflow reads on Monad, in one call.
///         A CRE run may make a handful of chain reads with small payloads, so
///         instead of walking every account market by market from the DON,
///         the workflow asks this view for the answer: what each oracle holds,
///         and the agent jobs due right now, already shaped as the receiver's
///         `Job`s. The rules are the keeper's (`scripts/keeper.py`):
///
///           - liquidate a position under HF 1 (stocks, retired markets and
///             the Amplify vault position);
///           - soft-deleverage a stock position under HF 1.15 that has free
///             vault shares to repay with;
///           - rebalance an Earn position more than 1% off the LTV its owner
///             picked, when it can act on it;
///           - compound the vault yield above the debt into more stock through
///             Kuru (`KuruVenue.buy`), at least 1 USDC, floor 2% under the
///             oracle, one per account per run;
///           - the vault's daily NAV snapshot.
///
///         Read-only: nothing here can move funds. The DON still estimates each
///         job before writing, so a job that would revert is never sent.
contract AgamaKeeperLens {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant SOFT_TRIGGER = 115e25; // HF 1.15
    uint256 internal constant BAND_BPS = 100;
    uint256 internal constant MIN_COMPOUND = 1e6; // 1 USDC
    uint256 internal constant SNAPSHOT_EVERY = 1 days + 60;

    ILensPool public immutable POOL;
    ILensFactory public immutable FACTORY;
    address public immutable VAULT_ADAPTER;
    address public immutable VENUE;

    address[] internal _stocks;
    address[] internal _retired;

    struct FeedState {
        bytes32 ticker;
        address oracle;
        uint128 price;
        uint64 observedAt;
        bool marketOpen;
    }

    constructor(
        ILensPool pool,
        ILensFactory factory,
        address vaultAdapter,
        address venue,
        address[] memory stocks,
        address[] memory retired
    ) {
        POOL = pool;
        FACTORY = factory;
        VAULT_ADAPTER = vaultAdapter;
        VENUE = venue;
        _stocks = stocks;
        _retired = retired;
    }

    function stocks() external view returns (address[] memory) {
        return _stocks;
    }

    /// @notice What each stock adapter's oracle holds for its ticker.
    function feeds() public view returns (FeedState[] memory out) {
        out = new FeedState[](_stocks.length);
        for (uint256 i; i < _stocks.length; ++i) {
            ILensStockAdapter a = ILensStockAdapter(_stocks[i]);
            bytes32 ticker = a.TICKER();
            address oracle = a.oracle();
            ILensOracle.Feed memory f = ILensOracle(oracle).feed(ticker);
            out[i] = FeedState(ticker, oracle, f.price, f.observedAt, f.marketOpen);
        }
    }

    /// @notice The feeds, and up to `maxJobs` jobs due over the accounts
    ///         `[start, start + count)`, most urgent first.
    function scan(uint256 start, uint256 count, uint256 maxJobs)
        external
        view
        returns (FeedState[] memory feedStates, AgamaCREReceiver.Job[] memory jobs, uint256 accountCount)
    {
        feedStates = feeds();
        accountCount = FACTORY.accountCount();
        uint256 end = start + count > accountCount ? accountCount : start + count;

        // Four queues by urgency, joined at the end.
        AgamaCREReceiver.Job[][4] memory q;
        uint256[4] memory n;
        uint256 cap = (end > start ? end - start : 0) * (_stocks.length + _retired.length + 1) + 1;
        for (uint256 k; k < 4; ++k) {
            q[k] = new AgamaCREReceiver.Job[](cap);
        }

        for (uint256 i = start; i < end; ++i) {
            address acct = FACTORY.accounts(i);
            _protect(acct, q, n);
            _agents(acct, q, n);
        }

        bool snap = block.timestamp > ILensVaultAdapter(VAULT_ADAPTER).snapshotAt() + SNAPSHOT_EVERY;
        uint256 total = n[0] + n[1] + n[2] + n[3] + (snap ? 1 : 0);
        if (total > maxJobs) total = maxJobs;
        jobs = new AgamaCREReceiver.Job[](total);
        uint256 w;
        for (uint256 k; k < 4 && w < total; ++k) {
            for (uint256 j; j < n[k] && w < total; ++j) {
                jobs[w++] = q[k][j];
            }
        }
        if (snap && w < total) {
            jobs[w] = AgamaCREReceiver.Job(AgamaCREReceiver.Kind.Snapshot, address(0), VAULT_ADAPTER, "");
        }
    }

    /// Liquidations (queue 0) and soft deleverages (queue 1).
    function _protect(address acct, AgamaCREReceiver.Job[][4] memory q, uint256[4] memory n) internal view {
        uint256 total = _stocks.length + _retired.length + 1;
        for (uint256 j; j < total; ++j) {
            address adapter = j < _stocks.length
                ? _stocks[j]
                : j < total - 1 ? _retired[j - _stocks.length] : VAULT_ADAPTER;
            if (POOL.getPositionScaledDebt(adapter, acct, "") == 0) continue;
            uint256 hf;
            try POOL.calculateHealthFactor(adapter, acct, "") returns (uint256 h) {
                hf = h;
            } catch {
                continue;
            }
            if (hf < RAY) {
                q[0][n[0]++] = AgamaCREReceiver.Job(AgamaCREReceiver.Kind.Liquidate, acct, adapter, "");
            } else if (hf < SOFT_TRIGGER && adapter != VAULT_ADAPTER && ILensAccount(acct).freeShares() > 0) {
                q[1][n[1]++] = AgamaCREReceiver.Job(AgamaCREReceiver.Kind.SoftDeleverage, acct, adapter, "");
            }
        }
    }

    /// Rebalances (queue 2) and one compound per account (queue 3).
    function _agents(address acct, AgamaCREReceiver.Job[][4] memory q, uint256[4] memory n) internal view {
        uint256 have = ILensAccount(acct).redeemableUsdc();
        bool compounded;
        for (uint256 j; j < _stocks.length; ++j) {
            address adapter = _stocks[j];
            uint256 target = ILensAccount(acct).targetLtvBps(adapter);
            if (target == 0) continue;
            uint256 value = ILensStockAdapter(adapter).getAssetValue(acct, "");
            uint256 debt = POOL.getPositionScaledDebt(adapter, acct, "");
            if (value > 0) {
                uint256 wanted = (value * target) / 10_000;
                uint256 band = (value * BAND_BPS) / 10_000;
                if (wanted > debt + band || (debt > wanted + band && have > 0)) {
                    q[2][n[2]++] = AgamaCREReceiver.Job(AgamaCREReceiver.Kind.Rebalance, acct, adapter, "");
                    continue; // compound once it is back on target
                }
            }
            if (compounded || have <= debt) continue;
            // The surplus shrinks with interest before inclusion.
            uint256 profit = ((have - debt) * 999) / 1000;
            if (profit < MIN_COMPOUND) continue;
            q[3][n[3]++] = _compound(acct, adapter, profit);
            compounded = true;
        }
    }

    function _compound(address acct, address adapter, uint256 profit)
        internal
        view
        returns (AgamaCREReceiver.Job memory)
    {
        ILensStockAdapter a = ILensStockAdapter(adapter);
        address wrapper = a.WRAPPER();
        uint256 minOut = (((profit * 1e18) / a.wrapperPrice()) * 98) / 100;
        bytes memory swapData = abi.encodeCall(IKuruVenueBuy.buy, (wrapper, profit, minOut));
        return AgamaCREReceiver.Job(
            AgamaCREReceiver.Kind.Compound, acct, adapter, abi.encode(profit, VENUE, VENUE, swapData, minOut)
        );
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {agUSD} from "../src/vault/agUSD.sol";
import {sagUSD} from "../src/vault/sagUSD.sol";
import {agUSDQueue} from "../src/vault/agUSDQueue.sol";
import {IagUSDQueue} from "../src/vault/interfaces/IagUSDQueue.sol";

import {ArrowLendingPool} from "../src/arrow/ArrowLendingPool.sol";
import {ArrowStabilityPool, IagUSDQueueRedeem} from "../src/arrow/ArrowStabilityPool.sol";
import {ArrowXStockAdapter} from "../src/arrow/adapters/ArrowXStockAdapter.sol";
import {ArrowVaultShareAdapter} from "../src/arrow/adapters/ArrowVaultShareAdapter.sol";
import {StockOracle} from "../src/arrow/oracle/StockOracle.sol";
import {DataStreamsStockOracle, IVerifierProxy} from "../src/arrow/oracle/DataStreamsStockOracle.sol";
import {InterestRateModel as IRM} from "../src/arrow/libs/InterestRateModel.sol";

import {AgamaAccount} from "../src/agama/AgamaAccount.sol";
import {AgamaAccountFactory} from "../src/agama/AgamaAccountFactory.sol";
import {AgamaEarnRouter} from "../src/agama/AgamaEarnRouter.sol";
import {AgamaAmplifyRouter} from "../src/agama/AgamaAmplifyRouter.sol";
import {AgamaZapRouter} from "../src/agama/AgamaZapRouter.sol";
import {IArrowPool} from "../src/interfaces/IArrowPool.sol";

/// @title Deployer
/// @notice Single source of truth for the Monad deployment, shared by the
///         broadcast script and the tests (tests run the exact wiring that goes
///         to testnet).
abstract contract Deployer {
    /// Chainlink Data Streams v11 (RWA Advanced, US equities) on the testnet
    /// Data Engine: one stream per session, each believed only for its own.
    struct Streams {
        bytes32 regular;
        bytes32 extended;
        bytes32 overnight;
    }

    uint32 internal constant SESSION_REGULAR = (1 << 2) | (1 << 5); // regular, and the close
    uint32 internal constant SESSION_EXTENDED = (1 << 1) | (1 << 3); // pre and post market
    uint32 internal constant SESSION_OVERNIGHT = 1 << 4;

    function _streams(bytes32 ticker) internal pure returns (Streams memory) {
        if (ticker == "TSLA") {
            return Streams(
                0x000b08f5e1a8c355e9982cea5707cf7b60be8ef91c42bb8022fd63f1bd71f6ab,
                0x000b4642144cb2e2f0e38ba57cc15a6549fd1522da1e7560f3d9e198b23fbe50,
                0x000b2729962eb0c3e39d0778279004b52cdce9bc511a79c31c7f14516b2e3652
            );
        }
        if (ticker == "NVDA") {
            return Streams(
                0x000b1d444945231e44dd47736c6abe288b10cb1b53941c7c68012fbdd2b1755c,
                0x000bf689e4aa5c006c89c207eb155ae99184e433a518753eb745cc552391a743,
                0x000b99b86a91cc317e2db8370f1466844dd9460cb51c3bf12fcc8d19d53d97bb
            );
        }
        if (ticker == "SPY") {
            return Streams(
                0x000b220be6fe94b85d6d8e8d5d4d212f5b86a644cbcc1dbf28b9e77b6810a5ec,
                0x000b5197360a398d3fa52c25c43f2be1f782bba7f576373548b8414117e3a039,
                0x000b0daa3a35d1c7ebf68a29981b74e04051ba6515c5b60204b213e533009dc4
            );
        }
        // AAPL
        return Streams(
            0x000b61d6dec069be40efc5f21f0345142a827f42966a07fa4743773383a8dd7b,
            0x000bbff670f86a195158a347cb04693bdc7d475ab43c645448c8835268b1d099,
            0x000bc10943a8c16f49ccec18764dfbed0c8d367503caf3a6e8af2087e79e81b7
        );
    }

    /// @notice Token and infra addresses: the testnet stand-ins and Chainlink's
    ///         VerifierProxy on Monad testnet.
    struct Assets {
        address usdc;
        address wTsla;
        address wNvda;
        address wSpy;
        address wAapl;
        address verifierProxy;
    }

    struct Config {
        address admin; // governor of every contract
        address keeper; // oracle keeper + vault operator
        address guardian; // pause
        address treasury; // fee recipient
        uint256 supplyCapUsdc; // Arrow lending supply cap, in USDC units
        uint256 borrowCapUsdc; // Arrow lending borrow cap, in USDC units
        uint256 spCooldown;
        Assets assets;
    }

    struct Deployment {
        DataStreamsStockOracle oracle;
        agUSD ag;
        sagUSD vault;
        agUSDQueue queue;
        ArrowLendingPool pool;
        ArrowStabilityPool sp;
        ArrowXStockAdapter tsla;
        ArrowXStockAdapter nvda;
        ArrowXStockAdapter spy;
        ArrowXStockAdapter aapl;
        ArrowVaultShareAdapter vaultAdapter;
        AgamaAccountFactory factory;
        AgamaEarnRouter earn;
        AgamaAmplifyRouter amplify;
        AgamaZapRouter zap;
    }

    /// @dev Must be called with `address(this)` (script: the broadcaster)
    ///      acting as `cfg.admin`, since it wires roles right after deploying.
    function _deployAll(Config memory cfg) internal returns (Deployment memory d) {
        // 1. Oracle -----------------------------------------------------------------
        d.oracle = new DataStreamsStockOracle(cfg.admin, cfg.keeper, IVerifierProxy(cfg.assets.verifierProxy));
        bytes32[4] memory tickers = [bytes32("TSLA"), "NVDA", "SPY", "AAPL"];
        for (uint256 i; i < 4; ++i) {
            Streams memory st = _streams(tickers[i]);
            d.oracle.addFeed(tickers[i]);
            d.oracle.setStream(st.regular, tickers[i], 18, true, SESSION_REGULAR);
            d.oracle.setStream(st.extended, tickers[i], 18, true, SESSION_EXTENDED);
            d.oracle.setStream(st.overnight, tickers[i], 18, true, SESSION_OVERNIGHT);
        }

        // 2. Agama vault on USDC ------------------------------------------------------
        d.ag = new agUSD(cfg.admin, cfg.guardian);
        d.vault = new sagUSD(address(d.ag), cfg.admin, cfg.guardian, cfg.admin, 0, cfg.treasury);
        d.queue = new agUSDQueue(
            address(d.ag),
            cfg.assets.usdc,
            address(d.vault),
            cfg.admin,
            cfg.guardian,
            cfg.keeper,
            5_000, // 50% of the vault kept liquid (instant exits + liquidations)
            1_000, // 10% protocol fee on yield
            cfg.treasury,
            1e6, // 1 USDC min deposit
            1_000_000e6 // instant redemption ceiling per request
        );
        d.ag.grantRole(d.ag.MINTER_ROLE(), address(d.queue));
        d.vault.grantRole(d.vault.OPERATOR_ROLE(), address(d.queue));
        d.vault.revokeRole(d.vault.OPERATOR_ROLE(), cfg.admin);

        // 3. Arrow lending pool ----------------------------------------------------------
        IRM.Params memory irm = IRM.Params({
            baseRate: 0.01e27, // 1%
            slope1: 0.05e27, // 6% at the kink
            slope2: 0.75e27,
            optimalUtil: 0.9e27
        });
        d.pool = new ArrowLendingPool(IERC20(cfg.assets.usdc), cfg.admin, "Arrow USDC", "arUSDC", irm, false);
        // Lender shares carry a 6-decimal offset (12 decimals): cap in shares.
        d.pool.setSupplyCap(cfg.supplyCapUsdc * 1e6);
        d.pool.setBorrowCap(cfg.borrowCapUsdc);

        // 4. Collateral adapters -----------------------------------------------------------
        //                 (maxLtv, LT, bonus, weekend buffer)
        d.tsla = _stock(d, cfg, cfg.assets.wTsla, "TSLA", 3_000, 4_000, 1_000, 800);
        d.nvda = _stock(d, cfg, cfg.assets.wNvda, "NVDA", 3_000, 4_000, 1_000, 800);
        d.spy = _stock(d, cfg, cfg.assets.wSpy, "SPY", 5_000, 6_000, 600, 500);
        d.aapl = _stock(d, cfg, cfg.assets.wAapl, "AAPL", 3_500, 4_500, 800, 800);
        d.vaultAdapter = new ArrowVaultShareAdapter(
            address(d.pool),
            IERC4626(address(d.vault)),
            6,
            cfg.admin,
            7_000, // max LTV -> 3x reachable after the haircut
            8_000, // LT
            500, // bonus
            300, // 3% haircut on NAV
            1_500, // NAV may not grow faster than 15%/yr between snapshots
            200 // borrows pause if NAV drops 2% under the snapshot
        );
        d.pool.registerAdapter(address(d.vaultAdapter), true);

        // 5. Stability pool ----------------------------------------------------------------
        d.sp = new ArrowStabilityPool(IERC4626(address(d.pool)), cfg.admin, 300, cfg.spCooldown);
        d.pool.setStabilityPool(address(d.sp));
        d.sp.addAdapter(address(d.tsla));
        d.sp.addAdapter(address(d.nvda));
        d.sp.addAdapter(address(d.spy));
        d.sp.addAdapter(address(d.aapl));
        d.sp.addAdapter(address(d.vaultAdapter));
        d.sp.setVault(IERC4626(address(d.vault)), IagUSDQueueRedeem(address(d.queue)));
        d.queue.grantRole(d.queue.PRIORITY_ROLE(), address(d.sp));

        // 6. The vault may never fund the pool that takes its shares as collateral.
        d.queue.setForbiddenVault(address(d.pool));

        // 7. Agama accounts and routers ---------------------------------------------------
        AgamaAccount impl = new AgamaAccount(
            IArrowPool(address(d.pool)),
            IagUSDQueue(address(d.queue)),
            IERC4626(address(d.vault)),
            d.vaultAdapter
        );
        d.factory = new AgamaAccountFactory(address(impl), cfg.admin);
        d.earn = new AgamaEarnRouter(d.factory, IArrowPool(address(d.pool)), cfg.admin);
        d.amplify = new AgamaAmplifyRouter(d.factory, IArrowPool(address(d.pool)), d.vaultAdapter);
        d.factory.setRouter(address(d.earn), true);
        d.factory.setRouter(address(d.amplify), true);

        // 8. Buy and Earn in one transaction. The zap also holds the swap
        //    allowlist the accounts read: the venue is set by the deploy script.
        d.zap = new AgamaZapRouter(d.earn, cfg.admin);
        d.earn.setZap(address(d.zap), true);
        d.factory.setZapRouter(address(d.zap));
    }

    function _stock(
        Deployment memory d,
        Config memory cfg,
        address wrapper,
        bytes32 ticker,
        uint256 ltv,
        uint256 lt,
        uint256 bonus,
        uint256 weekendBuffer
    ) internal returns (ArrowXStockAdapter a) {
        a = new ArrowXStockAdapter(
            address(d.pool),
            IERC4626(wrapper),
            ticker,
            StockOracle(address(d.oracle)),
            6,
            cfg.admin,
            ltv,
            lt,
            bonus,
            weekendBuffer
        );
        d.pool.registerAdapter(address(a), true);
    }
}

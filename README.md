# Agama - make tokenized stocks productive on X Layer

Deposit a tokenized stock, get more of it back · **[Try the app](https://app.agama.finance/xlayer)**

X Layer has 928 tokenized equities and 1.5B$ of USDG, and no lending market that
accepts the first as collateral for the second. Agama builds that market: deposit
an xStock, the protocol borrows USDG against it, puts the USDG to work in a
private credit vault, and permissionless agents turn the yield back into **more
of the stock**. What grows is your share count, not a stablecoin balance.

Built for OKX Dev Day 2026, track **Build a Market**, on an Arrow Finance lending
pool ported and deployed by Agama as part of the Arrow x Agama partnership (Arrow
runs the same model on Robinhood Chain).

## Architecture

The wallet, the two products, the Agama account that borrows on your behalf, the
Arrow pool underneath, and the price layer X Layer does not have.

```mermaid
flowchart TB
    USER["Holder<br/>xStocks withdrawn from the OKX app"]

    subgraph app["AGAMA APP (app.agama.finance/xlayer)"]
        EARN["Earn<br/>deposit the stock, get more stock"]
        AMP["Amplify<br/>loop the stock to the LTV ceiling"]
        LEND["Lend<br/>supply USDG, earn the borrow rate"]
    end

    subgraph agama["AGAMA"]
        ER["AgamaEarnRouter"]
        AR["AgamaAmplifyRouter"]
        ZR["AgamaZapRouter<br/>Buy and Earn via the OKX aggregator"]
        AC["AgamaAccount<br/>one clone per user<br/>the borrower of record"]
        VAULT["Agama private credit vault<br/>agUSD queue / sagUSD (ERC-4626)"]
    end

    subgraph arrow["ARROW FINANCE ON X LAYER"]
        POOL["ArrowLendingPool<br/>ERC-4626 on USDG / isolated debt per market"]
        XA["ArrowXStockAdapter x4<br/>TSLAx / NVDAx / SPYx / AAPLx<br/>LTV and threshold, tighter out of session"]
        VA["ArrowVaultShareAdapter<br/>CAPO cap / NAV circuit breaker"]
        SP["ArrowStabilityPool<br/>partial liquidation / buyback at -3%"]
    end

    subgraph price["THE PRICE LAYER (X Layer has no equity feed)"]
        ORACLE["RedStoneStockOracle<br/>3 of 5 signers / session status"]
        RS["RedStone signed reports<br/>while the session trades"]
        CL["Chainlink SPY relay, from Arbitrum<br/>xStock price from Solana, out of session<br/>both bounded on chain"]
    end

    AGENTS["Agents<br/>anyone can run them"]
    LENDERS["USDG lenders"]

    USER --> app
    EARN --> ER
    AMP --> AR
    EARN --> ZR
    ER --> AC
    AR --> AC
    ZR --> AC
    AC -->|"stock as collateral"| XA
    AC -->|"vault shares as collateral"| VA
    AC -->|"borrowed USDG"| VAULT
    XA --> POOL
    VA --> POOL
    POOL -->|"borrow USDG"| AC
    LENDERS --> LEND --> POOL
    SP -->|"absorbs the debt"| POOL
    AGENTS -->|"hold the level / buy more stock<br/>deleverage before selling"| AC
    RS --> ORACLE
    CL --> ORACLE
    ORACLE -->|"price + session status"| XA

    classDef actor fill:#eff6ff,stroke:#2563eb,color:#1e40af
    classDef product fill:#f0fdf4,stroke:#22c55e,color:#15803d
    classDef core fill:#ffffff,stroke:#374151,color:#111827
    classDef oracle fill:#faf5ff,stroke:#a855f7,color:#7e22ce
    classDef bot fill:#fff7ed,stroke:#f97316,color:#c2410c

    class USER,LENDERS actor
    class EARN,AMP,LEND product
    class ER,AR,ZR,AC,VAULT,POOL,XA,VA,SP core
    class ORACLE,RS,CL oracle
    class AGENTS bot
```

## What it does

- **Earn.** One deposit, nothing to set. The protocol borrows USDG at a safe
  level it picks, vaults it, and the agents keep it there: the stock rises, they
  borrow the difference; it falls, they repay from the yield already earned,
  never by selling your stock; the yield itself is bought back as more stock.
- **Amplify.** Borrow against the stock, buy more of the same stock, deposit it,
  again. A loop at L times carries an LTV of `(L - 1) / L`, so the market's own
  ceiling is the limit: 1.43x on TSLA and NVDA, 1.54x on AAPL, 2x on SPY.
- **Straight from the OKX app.** A withdrawal delivers the base xStock, not the
  ERC-4626 wrapper the markets take. Deposits accept it as is and closing hands
  it back the same way, ready for an OKX deposit.
- **Open around the clock, on a price that moves.** The share behind an xStock
  keeps market hours; the token does not. Out of session the keeper relays the
  token's own price off Solana, where it trades continuously and has depth, so
  the weekend is priced rather than frozen. If that cannot be read either, the
  last close is held and the terms tighten by the weekend buffer on both sides
  at once. Only a stale price stops a borrow, never the clock.
- **The price layer is part of the build.** X Layer has no equity feed, from
  anyone. RedStone reports verified on-chain, a bounded Chainlink relay for SPY,
  session status, and no fallback price ever.
- **No buttons for the automation.** The position card says the agents are
  running and what they last did. Anyone can run them; we are one caller.

## Where it lives

| | |
|---|---|
| App | https://app.agama.finance/xlayer (X Layer Testnet, chain 1952) |
| Test funds | The Faucet tab mints USDG and the four stocks in one transaction. Gas at https://web3.okx.com/xlayer/faucet |
| Contracts | 26, all source-verified on OKLink. Every address: [`deployments/1952.json`](deployments/1952.json) |
| The detail | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |

The two to open first, because users call them directly and so they are the ones
with transactions to look at:

- **ArrowLendingPool** [`0x5Df7e6f67DBb4520e3c40e02E0a1fBC7a74E40E8`](https://www.oklink.com/xlayer-test/address/0x5Df7e6f67DBb4520e3c40e02E0a1fBC7a74E40E8)
- **AgamaEarnRouter** [`0x1b9e3de861C836e5aF729e2B1bDb4cc8839Fd78D`](https://www.oklink.com/xlayer-test/address/0x1b9e3de861C836e5aF729e2B1bDb4cc8839Fd78D)

## Run it

```bash
forge test                         # 83 tests, most on a fork of X Layer mainnet
./scripts/check.sh                 # the five steps CI runs, before pushing
python3 scripts/e2e.py testnet     # 18 steps, real transactions on testnet
python3 scripts/ui_e2e.py          # a headless browser on the live app, real signer
cd web && pnpm dev                 # http://localhost:3004/xlayer
```

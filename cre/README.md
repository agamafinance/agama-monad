# agama-monad: Agama's whole keeper as a Chainlink CRE workflow

Everything Agama does on its own on Monad testnet, the prices and every agent,
is one CRE workflow. Every minute the DON:

1. **Asks [`AgamaKeeperLens`](../src/cre/AgamaKeeperLens.sol) what is due**,
   in one chain read: what the stock and gold oracles hold, and the agent jobs
   owed to the positions, already shaped as the receiver's jobs:
   - liquidate a position under HF 1 (stocks, retired markets, the Amplify
     vault position);
   - soft-deleverage a stock position under HF 1.15 from its free vault shares;
   - rebalance an Earn position more than 1% off the LTV its owner picked;
   - compound the vault yield above the debt into **more of the same stock**,
     bought on Kuru's order book (`KuruVenue.buy`), floor 2% under the oracle;
   - the vault's daily NAV snapshot.

   A CRE run may make 15 chain reads of 5 KB each, so the lens does the walk
   on chain and the DON reads the answer.
2. **Fetches the latest Chainlink Data Streams reports** of the nine stocks
   (RWA Advanced v11, one stream per session: regular, extended, overnight)
   and gold (XAU/USD, v3) from the Data Engine REST API. The request is
   HMAC-signed with credentials from the Vault DON and pinned to the run's
   agreed time floored to the minute, so every node fetches the same signed
   bytes. Each node keeps only the reports worth a transaction: in their own
   session, newer than the oracle's, and moved 0.5%, changed session or older
   than 50 minutes on chain. The DON agrees on that short list as is
   (`consensusIdenticalAggregation`), which also keeps the observation under
   the 25 KB consensus cap.
3. **Estimates every job from the receiver**, as it will run. A job that would
   revert is dropped before it costs anything; the others get their estimate
   plus 30%. Monad bills the gas limit, not the gas used, so the limit of the
   write is the sum of what each part needs.
4. **Writes one report** through the Keystone Forwarder to
   [`AgamaCREReceiver`](../src/cre/AgamaCREReceiver.sol). The receiver hands
   each Data Streams report to its oracle (stocks or gold), where Chainlink's
   VerifierProxy checks the signatures on chain, then runs the jobs. A price
   therefore needs both DONs: the CRE DON agreeing it is the one to bring, the
   Data Streams DON having signed it. Each item runs on its own, so one that
   lost a race is skipped, not fatal.

The receiver holds no role in the protocol and no funds; every call it makes
is open to anyone. Nothing to do, nothing written.

## Addresses (Monad testnet, 10143)

| | |
|---|---|
| AgamaCREReceiver | [`0x72f80190452B8a5fE19e639cEBAc476bD28D9E14`](https://testnet.monadvision.com/address/0x72f80190452B8a5fE19e639cEBAc476bD28D9E14) |
| AgamaKeeperLens | [`0xF8D5361FbcBAfaa03281Ec925d385eE7476Ad9B4`](https://testnet.monadvision.com/address/0xF8D5361FbcBAfaa03281Ec925d385eE7476Ad9B4) |
| MockKeystoneForwarder (simulation) | `0xB9F79d863261869B234c481D1f9A7af84AeAd192` |
| KeystoneForwarder (DON) | `0xF8344CFd5c43616a4366C34E3EEE75af79a74482` |
| Stock oracle | `0xCd4186dF8b4A93A693Db4f9E6A80Ce7478131BC8` |
| Gold oracle | `0x5C2C5F19A17B62055221bD8b80783E86b802e9Eb` |

The first receiver (prices and rebalances only, four stocks) was
`0xec27460813bEB044DB01A1C1F28b91E69d8c95b8`.

## How it runs

The keeper (`.github/workflows/keeper.yml`, `scripts/keeper.py`) runs
`cre workflow simulate --broadcast` every minute, compiled once per job
(`--wasm`). That is the same workflow code, and every write goes through
Chainlink's MockKeystoneForwarder to the receiver. When a CRE run fails, that
tick falls back to the same jobs in Python, so a price never goes stale on a
CI hiccup. CRE deploy access for our organization is gated (requested on
Oct 6, 2026), so the DON deployment (`production-settings`, the
KeystoneForwarder above) waits on it.

## Run it

```bash
cd cre && cp .env.example .env    # a funded Monad testnet key, Data Streams credentials
cd agama-monad && bun install && cd ..
cre workflow simulate ./agama-monad -T staging-settings --trigger-index 0              # dry run
cre workflow simulate ./agama-monad -T staging-settings --trigger-index 0 --broadcast  # writes on Monad
```

The receiver and the lens are deployed by `script/DeployCREReceiver.s.sol` and
tested in `test/CREReceiver.t.sol`.

# agama-monad: Agama's keeper as a Chainlink CRE workflow

Every minute the DON runs Agama on Monad testnet:

1. **Fetches the latest Chainlink Data Streams reports** (RWA Advanced v11) for
   TSLA, NVDA, SPY and AAPL, all three session streams each, from the Data
   Engine REST API. The request is HMAC-signed with credentials from the Vault
   DON and pinned to the run's agreed time floored to the minute, so every node
   fetches the same signed bytes and the DON agrees on them as is
   (`consensusIdenticalAggregation`).
2. **Reads the oracle on Monad** (one Multicall3 call) and keeps, per stock,
   the report of the stream whose session is live (regular 2 or 5, extended 1
   or 3, overnight 4) when it is newer than the stored price.
3. **Reads every Agama account** and keeps the positions more than 1% off the
   LTV their owner picked.
4. **Writes one report** through the Keystone Forwarder to
   [`AgamaCREReceiver`](../src/cre/AgamaCREReceiver.sol). The receiver hands the
   Data Streams reports to the oracle, where Chainlink's VerifierProxy checks
   their signatures on chain, then runs the permissionless `rebalance` on each
   position. A price therefore needs both DONs: the CRE DON agreeing it is the
   one to bring, the Data Streams DON having signed it. Each item runs on its
   own, so one that lost a race to another keeper is skipped, not fatal.

The receiver holds no role in the protocol. Nothing to do, nothing written.

## Addresses (Monad testnet, 10143)

| | |
|---|---|
| AgamaCREReceiver | [`0xec27460813bEB044DB01A1C1F28b91E69d8c95b8`](https://testnet.monadvision.com/address/0xec27460813bEB044DB01A1C1F28b91E69d8c95b8) |
| MockKeystoneForwarder (simulation) | `0xB9F79d863261869B234c481D1f9A7af84AeAd192` |
| KeystoneForwarder (DON) | `0xF8344CFd5c43616a4366C34E3EEE75af79a74482` |
| Oracle | `0xCd4186dF8b4A93A693Db4f9E6A80Ce7478131BC8` |

## Proof

`cre workflow simulate --broadcast` on Monad testnet, Oct 12 2026:
[`0xfc11945c3afa72ab7298f08314934570bd1a98fd5c4a0a53b294518b59bc2858`](https://testnet.monadvision.com/tx/0xfc11945c3afa72ab7298f08314934570bd1a98fd5c4a0a53b294518b59bc2858).
The forwarder delivered the report, the receiver stored 4 of 4 prices (TSLA
378.95, NVDA 226.35, SPY 778.11, AAPL 339.96), each verified by Chainlink's
VerifierProxy in the same transaction.

## Run it

```bash
cd cre && cp .env.example .env    # a funded Monad testnet key, Data Streams credentials
cd agama-monad && bun install && cd ..
cre workflow simulate ./agama-monad -T staging-settings --trigger-index 0              # dry run
cre workflow simulate ./agama-monad -T staging-settings --trigger-index 0 --broadcast  # writes on Monad
```

The receiver is deployed by `script/DeployCREReceiver.s.sol` and tested in
`test/CREReceiver.t.sol`. CRE deploy access for our organization is gated, so
the DON deployment (`production-settings`, the KeystoneForwarder above) waits on
it; the simulation runs the same code and writes through Chainlink's mock
forwarder.

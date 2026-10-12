# web: the Agama app on Monad

The front for Agama on Monad Testnet (chain 10143), served at
[app.agama.finance/monad](https://app.agama.finance/monad). It started as the X Layer front
(`agamafinance/agama-xlayer`) and was cut down to one network: Next.js and viem, nothing else.

## Layout

```
lib/monad/
  config.ts          chain, RPCs, addresses, the four stocks, decimals
  useMonad.ts        public client, market and position reads, wallets, writes
  passkey.ts         sign in with a passkey (Mera)
  loop.ts            the hops of an Amplify loop, one quote each
  agents.ts          the last agent action, and the deposit baseline
  WalletProvider.tsx the wallet context
  generated/         ABIs and deployments, written by scripts/sync-monad.mjs
app/monad/
  page.tsx           Earn: deposit the stock, get more stock
  amplify/           loop the stock, one slider
  portfolio/         every position, and a net worth that nets the debt out
  lend/              supply USDC (linked from Portfolio: the lender side)
  faucet/            MON for gas, then test USDC and xStocks in one transaction
components/
  MonadConnectPill.tsx  passkey first, then MetaMask, Rabby, Phantom, Backpack
  PriceBadge.tsx        where the prices come from, and how fresh they are
```

## Wallets

**Passkey first.** [Mera](https://docs.monad.xyz/guides/mera) turns the passkey's PRF output into
a plain EVM account (BIP-39, then `m/44'/60'/0'/0/0`): no extension, no seed phrase, no custody
backend. Only the credential id is stored (no key material), and the key lives in memory until
sign out, so a full page reload asks for the passkey again. On desktop Chrome the passkey must be
saved to Google Password Manager, or the browser cannot evaluate PRF and the app says so. The
account pays gas in MON like any other, which is why the faucet page starts with MON.

Browser wallets are found through EIP-6963 announcements, and switched to (or told about) Monad
Testnet before anything is signed.

**Gas.** Monad charges the gas limit, not the gas used, so every write estimates first and sends
with the estimate plus a fifth. The estimate also surfaces a revert before anyone signs.

## Local dev

```bash
pnpm install
pnpm dev          # http://localhost:3004/monad
pnpm typecheck
pnpm build
```

`pnpm dev` and `pnpm build` first run `scripts/sync-monad.mjs`, which regenerates
`lib/monad/generated` from the Foundry artifacts in `../out` and `../deployments/10143.json`.
Without those (a fresh clone, CI, Vercel) the committed files are kept. Until a deployment exists
every page says so instead of reading addresses that are not there.

Against a local anvil (it needs Multicall3 at its canonical address, `anvil_setCode` copies it):

```bash
NEXT_PUBLIC_MONAD_CHAIN_ID=31337 NEXT_PUBLIC_MONAD_RPC=http://127.0.0.1:8545 \
  INCLUDE_FORK_DEPLOYMENTS=1 pnpm dev
```

## Deployment

Its own Vercel project, reached through a rewrite on app.agama.finance. Assets are served from
this deployment's own origin (`NEXT_PUBLIC_ASSET_PREFIX`), otherwise `/_next/*` would land on
app.agama.finance and collide with the product app's own bundle.

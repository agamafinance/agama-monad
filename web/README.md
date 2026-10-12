# web — the Agama app, with Monad in it

This is the production front of [app.agama.finance](https://app.agama.finance), forked whole into
this repo for OKX Dev Day and given one more network. It is served at
[app.agama.finance/monad](https://app.agama.finance/monad).

The fork landed in a single commit, untouched, so that everything after it reads as a diff. The
app was already multi-chain: Stellar, Sui, Starknet, MagicBlock and Arbitrum each plug into the
same shell as a platform, with the same navbar, the same cream panels on the same green frame and
the same connect pill. Monad became one more of them.

## What was added

```
lib/monad/
  config.ts          chain, addresses, the four stocks, decimals
  useMonad.ts       public client, market and position reads, wallet, writes
  agents.ts          the last agent action, and the deposit baseline
  WalletProvider.tsx the platform's wallet context
  generated/         ABIs and deployments, written by scripts/sync-monad.mjs
app/monad/
  page.tsx           Earn: deposit the stock, get more stock
  portfolio/         every position, and a net worth that nets the debt out
  amplify/           loop the vault, one slider
  lend/              supply USDG against tokenized stocks (linked from Portfolio,
                     not a tab: it is the lender side, not one of the products)
  faucet/            testnet stand-ins
app/api/zap/         OKX Onchain OS DEX aggregator, signed server side
components/MonadConnectPill.tsx
```

Touched in the fork: `lib/network/NetworkContext.tsx` and `components/Navbar.tsx` (the platform id,
its tabs and its entry in the network menu) and `app/providers.tsx` (one more wallet provider).

## Local dev

```bash
pnpm install
pnpm dev          # http://localhost:3004/monad
```

`pnpm dev` and `pnpm build` first run `scripts/sync-monad.mjs`, which regenerates
`lib/monad/generated` from the Foundry artifacts in `../out` and the deployments in
`../deployments`. Without those (a fresh clone, CI, Vercel) the committed files are kept, so the
build always works.

`pnpm typecheck` runs `tsconfig.monad.json`, which covers only what was added here. The app this
is forked from carries type errors of its own and its build ignores them; the Monad work does
not get that pass.

## Deployment

Its own Vercel project, reached through a rewrite on app.agama.finance. Two consequences, both
handled in `next.config.mjs` and `components/Navbar.tsx`:

- assets are served from this deployment's own origin (`NEXT_PUBLIC_ASSET_PREFIX`), otherwise
  `/_next/*` would land on app.agama.finance and collide with the product app's own bundle;
- the nav links opt out of prefetching, because Next 16 prefetches route segments with a header
  that the outer app matches against its own route tree first, answering 404.

## Design

Cream `#fdf8ed` panels on a `#254839` frame, Tailwind, Next 16 App Router, viem. No wagmi on the
Monad pages: the other EVM network here talks to the wallet through a plain EIP-1193 hook, and
following the house pattern was worth more than reusing our own hooks.

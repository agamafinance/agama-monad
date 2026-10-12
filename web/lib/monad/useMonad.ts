'use client';

import { useCallback, useEffect, useState } from 'react';
import {
  createPublicClient, createWalletClient, custom, encodeFunctionData, fallback, http, type Address,
} from 'viem';

import {
  ADAPTERS, ADDR, AG_PER_USDG, CHAIN_ID_HEX, RAY, READ_RPCS, STOCKS, TARGET_VAULT_APY_RAY, TOKENS,
  USDG_DECIMALS, xLayerTestnet, type Stock,
} from './config';
import {
  accountAbi, amplifyRouterAbi, earnRouterAbi, lendingPoolAbi, stockOracleAbi,
  vaultShareAdapterAbi, xStockAdapterAbi,
} from './generated/abis';

export const pub = createPublicClient({
  chain: xLayerTestnet,
  // Ranked by measured latency, and any endpoint that starts erroring is
  // dropped for the next call. Reads only: a write goes through the wallet's
  // own provider.
  transport: fallback(READ_RPCS.map((url) => http(url)), {
    rank: { interval: 30_000, sampleCount: 3 },
  }),
  // Every market read goes out as part of one Multicall3 call instead of on
  // its own. Four markets is about thirty reads a refresh, which a public RPC
  // answers unevenly.
  batch: { multicall: { wait: 16 } },
});

const erc20Abi = [
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'allowance', stateMutability: 'view', inputs: [{ type: 'address' }, { type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'approve', stateMutability: 'nonpayable', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'asset', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'convertToAssets', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'convertToShares', stateMutability: 'view', inputs: [{ type: 'uint256' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'faucet', stateMutability: 'nonpayable', inputs: [{ type: 'address' }, { type: 'uint256' }], outputs: [] },
] as const;

/// One market as the Earn page needs it: the oracle price, the risk knobs, and
/// what this wallet holds and owes on it.
export interface Market {
  stock: Stock;
  adapter: Address;
  wrapper: Address;
  price: bigint; // 18 decimals, USD
  observedAt: number;
  marketOpen: boolean;
  borrowAllowed: boolean;
  maxLtv: bigint; // bps
  liqThreshold: bigint; // bps, already lowered by the weekend buffer when closed
  baseLiqThreshold: bigint; // bps, market open
  wrapperPrice: bigint; // USDG (6 decimals) for one wrapped share
  balance: bigint; // wrapped, in the wallet
  baseBalance: bigint; // the token an OKX withdrawal delivers
  base?: Address;
}

export interface RouterPosition {
  account: Address;
  collateral: bigint;
  collateralValue: bigint;
  debt: bigint;
  healthFactorRay: bigint;
  freeShares: bigint;
  freeSharesValue: bigint;
  borrowAllowed: boolean;
  liquidationThresholdBps: bigint;
}

export interface Position extends RouterPosition {
  /// Not on chain: the router answers for every wallet, open or not.
  hasPosition: boolean;
  targetLtvBps: bigint;
  /// The collateral counted in the base token, which is the only one the app
  /// names: the pool holds ERC-4626 shares, the user deposited and will get
  /// back the thing OKX sends.
  collateralBase: bigint;
  /// The vault buffer at the rate it would actually be redeemed at, where
  /// `freeSharesValue` is the same shares at the CAPO-capped rate Arrow lends
  /// against. The cap is the right basis for a health factor and the wrong one
  /// for telling someone what they own.
  redeemable: bigint;
}

export interface Protocol {
  vaultApy: bigint; // ray
  vaultApyIsTarget: boolean;
  borrowRate: bigint; // ray
  usdg: bigint; // wallet balance
}

const ZERO = '0x0000000000000000000000000000000000000000' as Address;
/// Canonical Multicall3, same address on Monad as everywhere else.
const MULTICALL3 = '0xcA11bde05977b3631167028862bE2a173976CA11' as Address;

/// A counter that advances on its own, and that an action can advance early.
///
/// Every read here is keyed on it. Without the timer a value read from a node
/// that was a block behind would stay wrong until the user did something else:
/// the public RPC is load balanced, and right after a transaction one node in
/// the pool still answers with the old state.
export function useTick(everyMs = 12000): [number, () => void] {
  const [tick, setTick] = useState(0);
  const bump = useCallback(() => setTick((t) => t + 1), []);
  useEffect(() => {
    const id = setInterval(bump, everyMs);
    return () => clearInterval(id);
  }, [bump, everyMs]);
  // One re-read after an action is not enough: the node that answers first can
  // still be a block behind the transaction that just landed, and the next
  // timer tick is a long time to leave someone looking at a balance that says
  // their deposit did not happen. Chase it over the next few seconds instead.
  const bumpNow = useCallback(() => {
    bump();
    const ids = [1500, 4000, 8000].map((ms) => setTimeout(bump, ms));
    return () => ids.forEach(clearTimeout);
  }, [bump]);
  return [tick, bumpNow];
}

let bases: Promise<Record<string, Address>> | undefined;

/// The base xStock behind each wrapper, read once per page load.
///
/// The deployment file only carries the wrappers, and `asset()` cannot change,
/// so asking the chain on every render was a round trip spent on a constant.
export function baseTokens(): Promise<Record<string, Address>> {
  bases ??= Promise.all(STOCKS.map((st) => pub.readContract({
    address: TOKENS[st.wrapper], abi: erc20Abi, functionName: 'asset',
  }) as Promise<Address>)).then((out) => Object.fromEntries(STOCKS.map((st, i) => [st.key, out[i]])));
  return bases;
}

export function useMonadMarkets(address?: Address) {
  const [markets, setMarkets] = useState<Market[]>([]);
  const [tick, setTick] = useState(0);
  const refresh = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    const t = setInterval(refresh, 15000);
    return () => clearInterval(t);
  }, [refresh]);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        // Everything in one batch, so the page is one round trip to the RPC
        // rather than three: awaiting the balances after the risk knobs, and
        // the share rate after the price, is what made it arrive in pieces.
        const bases = await baseTokens();
        const out = await Promise.all(
          STOCKS.map(async (stock): Promise<Market> => {
            const adapter = ADAPTERS[stock.key];
            const wrapper = TOKENS[stock.wrapper];
            const base = bases[stock.key];
            const [
              feed, maxLtv, lt, baseLt, borrowAllowed, wrapperPrice, perShare, balance, baseBalance,
            ] = await Promise.all([
              pub.readContract({ address: ADDR.oracle, abi: stockOracleAbi, functionName: 'feed', args: [stock.ticker] }),
              pub.readContract({ address: adapter, abi: xStockAdapterAbi, functionName: 'MAX_LTV' }),
              pub.readContract({ address: adapter, abi: xStockAdapterAbi, functionName: 'LIQUIDATION_THRESHOLD' }),
              pub.readContract({ address: adapter, abi: xStockAdapterAbi, functionName: 'BASE_LIQUIDATION_THRESHOLD' }),
              pub.readContract({ address: adapter, abi: xStockAdapterAbi, functionName: 'borrowAllowed' }).catch(() => false),
              pub.readContract({ address: adapter, abi: xStockAdapterAbi, functionName: 'wrapperPrice' }).catch(() => 0n),
              pub.readContract({ address: wrapper, abi: erc20Abi, functionName: 'convertToAssets', args: [10n ** 18n] }).catch(() => 10n ** 18n),
              address ? pub.readContract({ address: wrapper, abi: erc20Abi, functionName: 'balanceOf', args: [address] }) : Promise.resolve(0n),
              address && base ? pub.readContract({ address: base, abi: erc20Abi, functionName: 'balanceOf', args: [address] }) : Promise.resolve(0n),
            ]);
            const f = feed as { price: bigint; observedAt: bigint; marketOpen: boolean };
            // `wrapperPrice` refuses to answer once the feed is past its
            // staleness window, which is the right call for a borrow and the
            // wrong one for a balance: a portfolio that reads $0.00 because a
            // price is an hour old is worse than one that reads the last price
            // anyone signed. Fall back to the feed and the wrapper's own rate.
            const price = (wrapperPrice as bigint) > 0n
              ? wrapperPrice as bigint
              : (f.price * (perShare as bigint)) / 10n ** 30n;
            return {
              stock, adapter, wrapper,
              price: f.price, observedAt: Number(f.observedAt), marketOpen: f.marketOpen,
              borrowAllowed: borrowAllowed as boolean,
              maxLtv: maxLtv as bigint,
              liqThreshold: lt as bigint,
              baseLiqThreshold: baseLt as bigint,
              wrapperPrice: price,
              balance: balance as bigint, baseBalance: baseBalance as bigint,
              base: base as Address | undefined,
            };
          }),
        );
        if (alive) setMarkets(out);
      } catch (e) {
        console.error('monad markets', e);
      }
    })();
    return () => { alive = false; };
  }, [address, tick]);

  return { markets, refresh };
}

export function useMonadPosition(
  address: Address | undefined,
  adapter: Address | undefined,
  wrapper: Address | undefined,
  tick: number,
) {
  const [position, setPosition] = useState<Position | null>(null);

  useEffect(() => {
    if (!address || !adapter || !wrapper) { setPosition(null); return; }
    let alive = true;
    (async () => {
      try {
        const p = (await pub.readContract({
          address: ADDR.earnRouter, abi: earnRouterAbi, functionName: 'position', args: [address, adapter],
        })) as RouterPosition;
        const [target, base, redeemable] = await Promise.all([
          p.account === ZERO ? Promise.resolve(0n) : pub.readContract({
            address: p.account, abi: accountAbi, functionName: 'targetLtvBps', args: [adapter],
          }).catch(() => 0n) as Promise<bigint>,
          p.collateral === 0n ? Promise.resolve(0n) : pub.readContract({
            address: wrapper, abi: erc20Abi, functionName: 'convertToAssets', args: [p.collateral],
          }).catch(() => p.collateral) as Promise<bigint>,
          p.account === ZERO ? Promise.resolve(0n) : pub.readContract({
            address: p.account, abi: accountAbi, functionName: 'redeemableUsdg',
          }).catch(() => p.freeSharesValue) as Promise<bigint>,
        ]);
        if (alive) {
          setPosition({
            ...p, targetLtvBps: target, collateralBase: base, redeemable,
            hasPosition: p.collateral > 0n || p.debt > 0n,
          });
        }
      } catch (e) {
        console.error('monad position', e);
      }
    })();
    return () => { alive = false; };
  }, [address, adapter, wrapper, tick]);

  return position;
}

export function useMonadProtocol(address: Address | undefined, tick: number) {
  const [proto, setProto] = useState<Protocol | null>(null);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const [apy, reserve, usdg] = await Promise.all([
          pub.readContract({ address: ADAPTERS.VAULT, abi: vaultShareAdapterAbi, functionName: 'realizedApyRay' }).catch(() => 0n),
          pub.readContract({ address: ADDR.pool, abi: lendingPoolAbi, functionName: 'getReserveState' }),
          address
            ? pub.readContract({ address: TOKENS.USDG, abi: erc20Abi, functionName: 'balanceOf', args: [address] })
            : Promise.resolve(0n),
        ]);
        const measured = apy as bigint;
        if (alive) {
          setProto({
            vaultApy: measured > 0n ? measured : TARGET_VAULT_APY_RAY,
            vaultApyIsTarget: measured === 0n,
            borrowRate: (reserve as { currentBorrowRate: bigint }).currentBorrowRate,
            usdg: usdg as bigint,
          });
        }
      } catch (e) {
        console.error('monad protocol', e);
      }
    })();
    return () => { alive = false; };
  }, [address, tick]);

  return proto;
}

export interface AmplifyPosition {
  account: Address;
  pledgedShares: bigint;
  exposure: bigint;
  debt: bigint;
  equity: bigint;
  leverageBps: bigint;
  healthFactorRay: bigint;
  borrowRateRay: bigint;
  vaultApyRay: bigint;
}

/// What the pledged shares are actually worth.
///
/// `position()` values them at the CAPO-capped rate, because that is the rate
/// Arrow lends against and the ceiling deliberately trails the vault while a
/// settled coupon amortises in. That is the right number for a health factor
/// and the wrong one for "your equity": closing the loop redeems the shares at
/// the live rate, so this is the number that comes back to the wallet. Health
/// and the borrow rate stay on the router's own figures.
export async function atLiveRate(p: AmplifyPosition): Promise<AmplifyPosition> {
  if (p.pledgedShares === 0n) return p;
  const assets = (await pub.readContract({
    address: ADDR.sagUSD, abi: erc20Abi, functionName: 'convertToAssets', args: [p.pledgedShares],
  }).catch(() => 0n)) as bigint;
  const exposure = assets / AG_PER_USDG;
  if (exposure <= p.debt) return p;
  const equity = exposure - p.debt;
  return { ...p, exposure, equity, leverageBps: (exposure * 10_000n) / equity };
}

export function useAmplifyPosition(address: Address | undefined, tick: number) {
  const [pos, setPos] = useState<AmplifyPosition | null>(null);

  useEffect(() => {
    if (!address) { setPos(null); return; }
    let alive = true;
    (async () => {
      try {
        const p = await pub.readContract({
          address: ADDR.amplifyRouter, abi: amplifyRouterAbi, functionName: 'position', args: [address],
        });
        const live = await atLiveRate(p as AmplifyPosition);
        if (alive) setPos(live);
      } catch (e) {
        console.error('monad amplify', e);
      }
    })();
    return () => { alive = false; };
  }, [address, tick]);

  return pos;
}

// ---- wallet -----------------------------------------------------------------

/// The wallets this page will talk to, in the order it offers them.
///
/// OKX first, because this is an OKX chain and the deposit path starts with a
/// withdrawal from the OKX app. Rabby and MetaMask next, because plenty of
/// people testing this have one of those and nothing else.
///
/// A wallet is found by its EIP-6963 announcement where it makes one, which is
/// the only way to tell two extensions apart when both are installed: sniffing
/// `window.ethereum` connects whichever one won the injection race, and its
/// flags lie (half the wallets on the market set `isMetaMask`).
export interface WalletKind {
  id: string;
  name: string;
  rdns: string[];
  download: string;
  /// Last resort when a wallet makes no announcement: its own global, or the
  /// flag it sets. Only trusted once the announcements have come up empty.
  legacy?: (w: any) => any;
}

export const WALLETS: WalletKind[] = [
  {
    id: 'okx',
    name: 'OKX Wallet',
    rdns: ['com.okex.wallet', 'com.okx.wallet'],
    download: 'https://web3.okx.com/download',
    legacy: (w) => w.okxwallet ?? pickInjected(w, (p) => p.isOkxWallet === true || p.isOKExWallet === true),
  },
  {
    id: 'rabby',
    name: 'Rabby',
    rdns: ['io.rabby'],
    download: 'https://rabby.io/',
    legacy: (w) => pickInjected(w, (p) => p.isRabby === true),
  },
  {
    id: 'metamask',
    name: 'MetaMask',
    rdns: ['io.metamask', 'io.metamask.flask'],
    download: 'https://metamask.io/download/',
    // `isMetaMask` on its own proves nothing, so this only answers when no
    // other wallet has claimed the provider.
    legacy: (w) => pickInjected(w, (p) => p.isMetaMask === true && !p.isRabby && !p.isOkxWallet),
  },
];

function pickInjected(w: any, match: (p: any) => boolean): any {
  const many: any[] = w.ethereum?.providers ?? [];
  const inList = many.find(match);
  if (inList) return inList;
  // A browser with no wallet extension has no `window.ethereum` at all, and
  // every matcher here reads a flag straight off the provider. Without this
  // guard that read throws, the render asking for the wallet list throws with
  // it, and the whole page becomes the global error screen: the app looked
  // dead to anyone who had not already installed a wallet, which is most of
  // the people being shown it.
  return w.ethereum && match(w.ethereum) ? w.ethereum : undefined;
}

interface Announced {
  info: { rdns: string; name: string; icon?: string };
  provider: any;
}

/// EIP-6963 announcements, collected as they arrive.
///
/// A wallet only announces when asked, and asking once at module load misses
/// any extension that finished injecting after this file ran. So the request
/// goes out again whenever anyone reads the list.
const discovered: Announced[] = [];
if (typeof window !== 'undefined') {
  window.addEventListener('eip6963:announceProvider', (e) => {
    const d = (e as CustomEvent).detail as Announced;
    if (d?.info?.rdns && !discovered.some((p) => p.info.rdns === d.info.rdns)) discovered.push(d);
  });
}

export function askWalletsToAnnounce() {
  if (typeof window !== 'undefined') window.dispatchEvent(new Event('eip6963:requestProvider'));
}
askWalletsToAnnounce();

export interface FoundWallet extends WalletKind {
  provider: any;
  /// The icon the wallet announced, a data URI. Nothing to ship ourselves.
  icon?: string;
}

/// Every wallet from the list that is actually installed.
///
/// Only the three we name. A browser with six extensions announced a list of
/// six, most of which have no business on Monad, and the chooser stopped
/// reading as a choice. These three are the ones we test against.
export function availableWallets(): FoundWallet[] {
  if (typeof window === 'undefined') return [];
  const w = window as any;
  const out: FoundWallet[] = [];

  for (const kind of WALLETS) {
    const announced = discovered.find(
      (p) => kind.rdns.includes(p.info.rdns)
        || p.info.name?.toLowerCase().includes(kind.name.toLowerCase()),
    );
    const provider = announced?.provider ?? kind.legacy?.(w);
    if (!provider) continue;
    out.push({ ...kind, provider, icon: announced?.info.icon });
  }
  return out;
}

/// Set once the user has disconnected, so the next page load does not put them
/// straight back. Without it `eth_accounts` would answer with the account the
/// wallet still has approved and the disconnect would last until the click.
const LEFT = 'agama.monad.disconnected';
/// Which wallet was chosen, so a reload talks to the same one and `send` does
/// not sign through a different extension than the one that connected.
const PICKED = 'agama.monad.wallet';

function remembered(): string | undefined {
  try {
    return window.sessionStorage.getItem(PICKED) ?? undefined;
  } catch {
    return undefined;
  }
}

/// The provider every call site uses: the one the user picked, or the only one
/// installed, or nothing.
function injectedProvider(): any {
  const found = availableWallets();
  const id = remembered();
  return (id && found.find((f) => f.id === id)?.provider) ?? found[0]?.provider;
}

export function useWallet() {
  const [address, setAddress] = useState<Address | undefined>();

  const disconnect = useCallback(() => {
    setAddress(undefined);
    try {
      window.sessionStorage.setItem(LEFT, '1');
    } catch {
      /* private mode: the disconnect lasts the session anyway */
    }
    // Not every wallet implements this, and none of them have to. Where it
    // exists it makes the wallet forget the site too, which is what the user
    // meant; where it does not, clearing our side is the whole of it.
    injectedProvider()?.request?.({ method: 'wallet_revokePermissions', params: [{ eth_accounts: {} }] })
      .catch(() => {});
  }, []);

  const connect = useCallback(async (walletId?: string) => {
    const found = availableWallets();
    if (found.length === 0) {
      window.open(WALLETS[0].download, '_blank');
      return;
    }
    const pick = found.find((f) => f.id === walletId) ?? found[0];
    try {
      window.sessionStorage.setItem(PICKED, pick.id);
    } catch {
      /* ignore */
    }
    const eth = pick.provider;

    // Switch first, then ask for the account. The other way round shows the
    // connect dialog on whatever chain the wallet happens to be sitting on,
    // which is how someone approves a connection to Monad while the wallet
    // says Coston2.
    await ensureMonad(eth);
    const [acc] = await eth.request({ method: 'eth_requestAccounts' });

    // And if the wallet was locked a moment ago, it can switch now.
    const on = await eth.request({ method: 'eth_chainId' }).catch(() => undefined);
    if (on !== CHAIN_ID_HEX) await ensureMonad(eth);

    try {
      window.sessionStorage.removeItem(LEFT);
    } catch {
      /* ignore */
    }
    setAddress(acc as Address);
  }, []);

  useEffect(() => {
    const eth = injectedProvider();
    if (!eth) return;
    let left = false;
    try {
      left = !!window.sessionStorage.getItem(LEFT);
    } catch {
      /* ignore */
    }
    if (!left) {
      eth.request({ method: 'eth_accounts' }).then((a: string[]) => {
        if (a[0]) setAddress(a[0] as Address);
      }).catch(() => {});
    }

    // The wallet can change the account or the chain without asking us.
    const onAccounts = (a: string[]) => setAddress(a[0] as Address | undefined);
    const onChain = () => setAddress((prev) => prev); // re-render; the guard in send() does the rest
    eth.on?.('accountsChanged', onAccounts);
    eth.on?.('chainChanged', onChain);
    return () => {
      eth.removeListener?.('accountsChanged', onAccounts);
      eth.removeListener?.('chainChanged', onChain);
    };
  }, []);

  return { address, connect, disconnect };
}

/// Send one transaction and wait for it, the way every other network page here
/// does: the wallet client is built on demand so no provider has to be mounted.
/// Put the wallet on Monad, adding the chain if it has never heard of it.
///
/// Shared by `connect` and by every write: a wallet that was on another chain
/// when the user pressed a button is the normal case, not the exception, and a
/// wallet that does not know chain 1952 (anything but OKX's, which ships it)
/// answers 4902 and needs to be told what it is.
///
/// The RPCs handed over are the ones this app measured as working, fastest
/// first. Giving a wallet only OKX's public endpoint is how Rabby ended up
/// added to a chain it could not reach.
export async function ensureMonad(eth: any): Promise<boolean> {
  try {
    const on = await eth.request({ method: 'eth_chainId' }).catch(() => undefined);
    if (on === CHAIN_ID_HEX) return true;
    await eth.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CHAIN_ID_HEX }] });
    return true;
  } catch (e: any) {
    // 4902 is "unknown chain". Some wallets nest it, hence the second look.
    if (e?.code !== 4902 && e?.data?.originalError?.code !== 4902) return false;
    try {
      await eth.request({
        method: 'wallet_addEthereumChain',
        params: [{
          chainId: CHAIN_ID_HEX,
          chainName: 'Monad Testnet',
          nativeCurrency: { name: 'OKB', symbol: 'OKB', decimals: 18 },
          rpcUrls: READ_RPCS,
          blockExplorerUrls: [xLayerTestnet.blockExplorers.default.url],
        }],
      });
      return true;
    } catch {
      return false;
    }
  }
}

/// Whatever went wrong, in words.
///
/// Wallets throw plain `{code, message}` objects as often as they throw
/// Errors, and `String(anObject)` is "[object Object]", which is what the
/// faucet showed someone whose wallet had refused to switch chain.
export function errorText(e: unknown): string {
  const any = e as any;
  const raw: string =
    any?.shortMessage
    || any?.details
    || any?.data?.message
    || any?.error?.message
    || any?.reason
    || (e instanceof Error ? e.message : '')
    || (typeof any?.message === 'string' ? any.message : '')
    || (() => { try { return JSON.stringify(e); } catch { return String(e); } })();
  if (/user rejected|user denied|rejected the request|4001/i.test(raw)) return 'Cancelled in the wallet';
  return raw.split('\n')[0].slice(0, 140) || 'Something went wrong';
}

export async function send(
  from: Address, to: Address, abi: readonly unknown[], functionName: string, args: readonly unknown[],
): Promise<`0x${string}`> {
  const eth = injectedProvider();
  // The wallet may have wandered off to another chain since connecting, or
  // never have been on this one. Ask it over before signing, rather than
  // letting viem refuse with a mismatch the user cannot act on.
  if (!(await ensureMonad(eth))) throw new Error('Switch your wallet to Monad Testnet to continue');
  const wallet = createWalletClient({ account: from, chain: xLayerTestnet, transport: custom(eth) });
  const hash = await wallet.writeContract({ address: to, abi: abi as never, functionName, args: args as never });
  await pub.waitForTransactionReceipt({ hash });
  return hash;
}

export async function ensureAllowance(owner: Address, token: Address, spender: Address, need: bigint) {
  const current = (await pub.readContract({
    address: token, abi: erc20Abi, functionName: 'allowance', args: [owner, spender],
  })) as bigint;
  if (current >= need) return;
  await send(owner, token, erc20Abi, 'approve', [spender, need]);
}

export async function faucet(owner: Address, token: Address, amount: bigint) {
  await send(owner, token, erc20Abi, 'faucet', [owner, amount]);
}

const multicall3Abi = [{
  type: 'function', name: 'aggregate3', stateMutability: 'payable',
  inputs: [{
    name: 'calls', type: 'tuple[]',
    components: [
      { name: 'target', type: 'address' },
      { name: 'allowFailure', type: 'bool' },
      { name: 'callData', type: 'bytes' },
    ],
  }],
  outputs: [{
    name: 'returnData', type: 'tuple[]',
    components: [{ name: 'success', type: 'bool' }, { name: 'returnData', type: 'bytes' }],
  }],
}] as const;

/// Every faucet token in one transaction, so the wallet asks once.
///
/// `faucet(to, amount)` mints to whoever is named, not to the caller, so
/// Multicall3 can make all of the calls on the user's behalf and the tokens
/// still land in the user's wallet. No faucet contract of our own to deploy.
export async function faucetAll(owner: Address, mints: { token: Address; amount: bigint }[]) {
  const calls = mints.map(({ token, amount }) => ({
    target: token,
    allowFailure: false,
    callData: encodeFunctionData({ abi: erc20Abi, functionName: 'faucet', args: [owner, amount] }),
  }));
  return send(owner, MULTICALL3, multicall3Abi, 'aggregate3', [calls]);
}

export { erc20Abi };
export const usdgDecimals = USDG_DECIMALS;
export const rayOne = RAY;

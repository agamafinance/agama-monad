'use client';

import { Loader2 } from 'lucide-react';
import { ReactNode, useEffect, useState } from 'react';
import { formatUnits, parseUnits, type Address } from 'viem';

import { TokenIcon } from '@/components/icons/TokenIcon';
import { MON_FAUCET, RAY, STOCK_DECIMALS, txUrl, USDC_DECIMALS } from '@/lib/monad/config';
import { ago } from '@/lib/monad/agents';
import { pub, type Market } from '@/lib/monad/useMonad';

// The Solana front's kit, spoken in Monad's units: USDC in 6 decimals, the
// stocks and the oracle price in 18, rates in ray.

export const card =
  'rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]';
export const primaryBtn =
  'w-full rounded-full bg-[#254839] px-5 py-3.5 text-[15px] font-medium text-[#fdf8ed] transition-colors hover:bg-[#1F3D31] disabled:opacity-45';
export const secondaryBtn =
  'w-full rounded-full border border-[#254839]/25 px-5 py-3.5 text-[15px] font-medium text-fg transition-colors hover:bg-[#254839]/[0.06] disabled:opacity-45';

const fmt = (v: bigint, decimals: number, dp: number) =>
  Number(formatUnits(v, decimals)).toLocaleString('en-US', { minimumFractionDigits: dp, maximumFractionDigits: dp });
export const usd = (v: bigint | undefined, dp = 2) => (v === undefined ? '-' : `$${fmt(v, USDC_DECIMALS, dp)}`);
export const qty = (v: bigint | undefined, dp = 4) => (v === undefined ? '-' : fmt(v, STOCK_DECIMALS, dp));
export const pct = (bps: bigint | number | undefined, dp = 2) =>
  bps === undefined ? '-' : `${(Number(bps) / 100).toFixed(dp).replace(/\.?0+$/, '')}%`;
export const rayPct = (v: bigint | undefined) => (v === undefined ? '-' : `${((Number(v) / Number(RAY)) * 100).toFixed(2)}%`);
/// The oracle price, 18 decimals.
export const price = (v: bigint | undefined) => (!v ? '-' : `$${fmt(v, 18, 2)}`);
export { ago };

/// Parse a decimal string into base units, or 0 when it is not a number.
export function parseAmount(s: string, decimals: number): bigint {
  try {
    return s.trim() ? parseUnits(s.trim(), decimals) : 0n;
  } catch {
    return 0n;
  }
}

export function Hero({ title, children, art }: { title: ReactNode; children: ReactNode; art?: string }) {
  return (
    <section className="px-6 md:px-24 pt-10 md:pt-14 pb-8">
      <div className="max-w-[1400px] mx-auto relative">
        {art && (
          <div aria-hidden className="pointer-events-none absolute right-0 -top-2 z-20 hidden lg:block">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img src={art} alt="" className="h-[300px] w-auto" />
          </div>
        )}
        <h1 className="mt-3 text-[34px] md:text-[44px] leading-[1.05] text-fg font-semibold">{title}</h1>
        {children}
      </div>
    </section>
  );
}

export function Panel({ children }: { children: ReactNode }) {
  return (
    <section className="vault-panel relative z-10 rounded-t-[20px] px-6 md:px-24 pt-10 md:pt-14 pb-24">
      <div className="max-w-[1400px] mx-auto space-y-5">{children}</div>
    </section>
  );
}

export function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div>
      <div className="text-[12px] uppercase tracking-wider text-fg-muted">{label}</div>
      <div className="text-[26px] text-fg font-semibold tabular-nums">{value}</div>
      {sub && <div className="text-[12px] text-fg-muted">{sub}</div>}
    </div>
  );
}

export function Row({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="flex items-center justify-between">
      <dt className="text-fg-muted">{label}</dt>
      <dd className="text-fg tabular-nums">{value}</dd>
    </div>
  );
}

/// A result line under the button that was pressed, with the explorer link
/// when there is a transaction to look at.
export function Status({ text, hash }: { text?: string; hash?: string }) {
  if (!text) return null;
  return (
    <p className="mt-2 text-[12px] text-fg-muted" data-testid="status" role="status" aria-live="polite">
      {text}
      {hash && (
        <>
          {' '}
          <a href={txUrl(hash)} target="_blank" rel="noreferrer" className="underline hover:text-fg">
            View on explorer
          </a>
        </>
      )}
    </p>
  );
}

export function MarketCards({
  markets, sel, onSelect, connected,
}: { markets: Market[]; sel: number; onSelect: (i: number) => void; connected: boolean }) {
  return (
    <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
      {markets.map((m, i) => (
        <button
          key={m.stock.key}
          onClick={() => onSelect(i)}
          className={
            i === sel
              ? 'rounded-2xl bg-[#254839] p-4 text-left text-[#fdf8ed]'
              : 'rounded-2xl bg-[#fdfaf1] p-4 text-left text-fg transition-colors hover:bg-white'
          }
        >
          <div className="flex items-center justify-between gap-2">
            <span className="flex items-center gap-2">
              <TokenIcon symbol={m.stock.base} size={22} />
              <span className="text-[15px] font-medium">{m.stock.base}</span>
            </span>
            <span className="text-[11px] opacity-70">{m.stock.name}</span>
          </div>
          <div className="mt-1 flex items-baseline gap-2">
            <span className="text-[22px] font-semibold tabular-nums">{price(m.price)}</span>
            {/* Chainlink streams every session (regular, extended,
                overnight), so its age is the honest thing to show. */}
            <span className="text-[11px] opacity-70">{m.observedAt ? ago(m.observedAt) : 'no price yet'}</span>
          </div>
          <div className="mt-1 text-[11px] opacity-70">
            Max LTV {pct(m.maxLtv)}
            {m.marketOpen ? '' : ' · last close'}
            {connected && m.baseBalance > 0n ? ` · ${qty(m.baseBalance, 2)} held` : ''}
          </div>
        </button>
      ))}
    </div>
  );
}

export function SessionBadge({ m }: { m: Market | undefined }) {
  if (!m) return null;
  if (!m.borrowAllowed)
    return <span className="rounded-full bg-[#b4571f]/10 px-3 py-1 text-[12px] text-[#b4571f]">Stale price</span>;
  return m.marketOpen ? (
    <span className="rounded-full bg-[#254839]/[0.06] px-3 py-1 text-[12px] text-fg">Market open</span>
  ) : (
    <span className="rounded-full bg-[#254839]/[0.06] px-3 py-1 text-[12px] text-fg">Market closed, last close</span>
  );
}

export function AgentsCard({ children, last }: { children: ReactNode; last: string }) {
  return (
    <div className="mt-4 rounded-2xl border border-[#254839]/12 bg-white/60 p-4">
      <div className="flex items-center gap-2">
        <span className="relative flex h-2 w-2" aria-hidden>
          <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-[#254839] opacity-60" />
          <span className="relative inline-flex h-2 w-2 rounded-full bg-[#254839]" />
        </span>
        <span className="text-[13px] font-medium text-fg">Agents running</span>
      </div>
      <p className="mt-1.5 text-[13px] text-fg-muted">{children}</p>
      <p className="mt-2 text-[12px] text-fg-muted">{last}</p>
    </div>
  );
}

export function AmountBox({
  label, balanceLabel, onMax, value, onChange, unit, hint,
}: {
  label: string;
  balanceLabel: string;
  onMax: () => void;
  value: string;
  onChange: (v: string) => void;
  unit: ReactNode;
  hint?: string;
}) {
  return (
    <div className="mt-4 rounded-2xl border border-[#254839]/12 bg-white/60 p-4">
      <div className="flex items-center justify-between text-[12px] text-fg-muted">
        <span>{label}</span>
        <button onClick={onMax} className="hover:text-fg">
          Balance {balanceLabel} · Max
        </button>
      </div>
      <div className="mt-1.5 flex items-center justify-between">
        <input
          inputMode="decimal"
          placeholder="0.00"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          className="w-full bg-transparent text-[28px] font-semibold text-fg tabular-nums outline-none placeholder:text-fg-muted/40"
        />
        <span className="shrink-0 rounded-full bg-[#254839]/[0.06] px-3 py-1.5 text-[14px] font-medium text-fg">
          {unit}
        </span>
      </div>
      {hint && <div className="mt-1 text-[12px] text-fg-muted">{hint}</div>}
    </div>
  );
}

/// A busy button says what the user is waiting on in one word, with a
/// spinner, whatever the progress line underneath says in full.
export function stepLabel(text?: string): string {
  const t = text ?? '';
  if (/approv/i.test(t)) return 'Approving';
  if (/pric|plan|prepar|build/i.test(t)) return 'Preparing';
  return 'Sending';
}

export function Step({ text }: { text?: string }) {
  return (
    <span className="inline-flex items-center justify-center gap-2">
      <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
      {stepLabel(text)}
    </span>
  );
}

/// The wallet's MON, for gas. Undefined until read, or with no wallet.
export function useMonBalance(address: Address | undefined, tick: number) {
  const [mon, setMon] = useState<bigint>();
  useEffect(() => {
    if (!address) { setMon(undefined); return; }
    let alive = true;
    pub.getBalance({ address }).then((b) => { if (alive) setMon(b); }).catch(() => {});
    return () => { alive = false; };
  }, [address, tick]);
  return mon;
}

/// Below this a wallet cannot pay for much: Monad charges the gas limit, and
/// a loop through Kuru is a big one.
export const LOW_MON = 10n ** 17n; // 0.1 MON

/// A connected wallet with next to no MON, which is every new passkey: say so
/// before the first transaction fails for it.
export function GasNotice({ address, mon }: { address: Address | undefined; mon: bigint | undefined }) {
  const [copied, setCopied] = useState(false);
  if (!address || mon === undefined || mon >= LOW_MON) return null;
  return (
    <div className="rounded-2xl border border-[#c98a2b]/40 bg-[#c98a2b]/10 px-4 py-3 text-[13px] text-fg" data-testid="testnet-notice">
      Agama runs on <b>Monad Testnet</b> and this wallet has little or no MON for gas. Get testnet MON at{' '}
      <a href={MON_FAUCET} target="_blank" rel="noreferrer" className="underline">faucet.monad.xyz</a> for{' '}
      <button
        onClick={() => {
          navigator.clipboard?.writeText(address);
          setCopied(true);
          setTimeout(() => setCopied(false), 1500);
        }}
        className="underline"
        title="Copy your address"
      >
        {address.slice(0, 6)}...{address.slice(-4)} ({copied ? 'copied' : 'copy'})
      </button>
      , then open the Faucet tab.
    </div>
  );
}

/// What is real on this testnet and what is a stand-in, under every page that
/// trades.
export function TestnetNote() {
  return (
    <p className="text-[12px] text-fg-muted">
      Testnet: the stocks and USDC are stand-ins from the Faucet tab, under the real xStocks&apos; tickers (TSLAx,
      NVDAx, SPYx and AAPLx, as on Monad mainnet); no xStock faucet exists on testnet. Prices are real: Chainlink
      Data Streams reports, verified on chain by Chainlink&apos;s Verifier. Trades fill on Kuru&apos;s order book.
    </p>
  );
}

'use client';

import { useEffect, useMemo, useState } from 'react';
import { formatUnits, parseUnits } from 'viem';

import { TokenIcon } from '@/components/icons/TokenIcon';
import { NotDeployed, PriceBadge } from '@/components/PriceBadge';
import { ADDR, asset, BPS, DEPLOYED, RAY, STOCK_DECIMALS, USDC_DECIMALS } from '@/lib/monad/config';
import { amplifyRouterAbi, lendingPoolAbi } from '@/lib/monad/generated/abis';
import { planClose, planOpen } from '@/lib/monad/loop';
import {
  ensureAllowance, erc20Abi, errorText, pub, send, useTick, useMonadMarkets, useMonadPosition, useMonadProtocol,
} from '@/lib/monad/useMonad';
import { useMonadWallet } from '@/lib/monad/WalletProvider';

const usd = (v: bigint | undefined) =>
  v === undefined ? '-' : `$${Number(formatUnits(v, USDC_DECIMALS)).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const qty = (v: bigint | undefined, dp = 2) =>
  v === undefined ? '-' : Number(formatUnits(v, STOCK_DECIMALS)).toFixed(dp);
const rayPct = (v: bigint | undefined) => (v === undefined ? '-' : `${(Number(v) / Number(RAY) * 100).toFixed(2)}%`);
const ONE = 10n ** 18n;

export default function MonadAmplifyPage() {
  const { address, connect } = useMonadWallet();
  const [tick, bumpTick] = useTick();
  const proto = useMonadProtocol(address, tick);
  const { markets, refresh } = useMonadMarkets(address);

  const [key, setKey] = useState<string>();
  const m = markets.find((x) => x.stock.key === key) ?? markets[0];
  const position = useMonadPosition(address, m?.adapter, m?.wrapper, tick);

  const [amount, setAmount] = useState('');
  // Undefined until the market says what it allows: the ceiling is a property
  // of the collateral, so there is no sensible default before it is known.
  const [picked, setPicked] = useState<number>();
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState('');
  const [pending, setPending] = useState<'open' | 'close'>('open');
  const [minBorrow, setMinBorrow] = useState(0n);

  useEffect(() => {
    if (!DEPLOYED) return;
    pub.readContract({ address: ADDR.pool, abi: lendingPoolAbi, functionName: 'minBorrowAmount' })
      .then((v) => setMinBorrow(v as bigint)).catch(() => {});
  }, []);

  // What the market allows, not what a slider would like to offer. An equity at
  // a 30% LTV cannot be looped past 1 / (1 - 0.30), and pretending otherwise
  // would be a slider that ends in a revert.
  const maxLeverage = useMemo(() => {
    if (!m || m.maxLtv === 0n) return 1;
    const ltv = Number(m.maxLtv) / 10_000;
    return Math.floor((1 / (1 - ltv * 0.995)) * 100) / 100;
  }, [m]);

  // Most of the way to the ceiling, which is what someone opening a leveraged
  // position came for, and still short of the edge. A slider the user has moved
  // is theirs; it only gets clamped if the market they switch to allows less.
  const leverage = Math.min(picked ?? Math.max(1.1, Math.floor(maxLeverage * 90) / 100), maxLeverage);

  const amt = useMemo(() => {
    try {
      return amount ? parseUnits(amount, STOCK_DECIMALS) : 0n;
    } catch {
      return 0n;
    }
  }, [amount]);

  const held = m?.baseBalance ?? 0n;
  const debt = position?.debt ?? 0n;
  const value = position?.collateralValue ?? 0n;
  const equity = value > debt ? value - debt : 0n;
  const has = !!position && position.collateral > 0n;
  const openLeverage = has && equity > 0n ? (Number(value) / Number(equity)) : 0;

  const bump = () => { bumpTick(); refresh(); };

  async function open() {
    if (!address || !m) return;
    setPending('open');
    setBusy(true);
    try {
      setStatus('Pricing the loop…');
      // The deposit is in the base token, which the router wraps on the way in,
      // so the plan is made in the wrapper shares that will come out of it.
      const shares = (await pub.readContract({
        address: m.wrapper, abi: erc20Abi, functionName: 'convertToShares', args: [amt],
      })) as bigint;
      const plan = await planOpen(m, shares, leverage, minBorrow);

      setStatus('Approving…');
      const base = m.base!;
      await ensureAllowance(address, base, ADDR.amplifyRouter, amt);
      setStatus(`Looping ${plan.hops.length} time${plan.hops.length === 1 ? '' : 's'}…`);
      await send(address, ADDR.amplifyRouter, amplifyRouterAbi, 'openStockWithBase',
        [m.adapter, amt, plan.hops]);
      setStatus('Done');
      setAmount('');
      bump();
    } catch (e: unknown) {
      setStatus(errorText(e));
    } finally {
      setBusy(false);
    }
  }

  async function close() {
    if (!address || !m || !position) return;
    setPending('close');
    setBusy(true);
    try {
      setStatus('Pricing the unwind…');
      const hops = await planClose(m, position.collateral, position.debt, position.liquidationThresholdBps);
      setStatus(`Selling back, ${hops.length} step${hops.length === 1 ? '' : 's'}…`);
      await send(address, ADDR.amplifyRouter, amplifyRouterAbi, 'closeStock', [m.adapter, hops, true]);
      setStatus('Done');
      bump();
    } catch (e: unknown) {
      setStatus(errorText(e));
    } finally {
      setBusy(false);
    }
  }

  const preview = useMemo(() => {
    if (!m || amt === 0n) return undefined;
    const start = (amt * m.wrapperPrice) / ONE;
    const exposure = (start * BigInt(Math.round(leverage * 10_000))) / BPS;
    return { start, exposure, borrowed: exposure - start, stock: (amt * BigInt(Math.round(leverage * 100))) / 100n };
  }, [m, amt, leverage]);

  return (
    <>
      <section className="px-6 md:px-24 pt-10 md:pt-14 pb-8">
        <div className="max-w-[1400px] mx-auto relative">
          <div aria-hidden className="pointer-events-none absolute right-0 -top-2 z-20 hidden lg:block">
            <img src={asset('/logos/coin-pair-amplify.svg')} alt="" className="h-[300px] w-auto" />
          </div>

          <h1 className="mt-3 text-[34px] md:text-[44px] leading-[1.05] text-fg font-semibold">
            More of the stock,
            <br />
            on one slider
          </h1>
          <p className="mt-4 max-w-[640px] text-[15px] text-fg-muted">
            Deposit a tokenized stock and the protocol borrows USDC against it, buys more of the same
            stock, and deposits that too, until the level you asked for. One transaction. How far it can
            go is the market&apos;s own LTV ceiling, not a number we chose.
          </p>
          <PriceBadge markets={markets} />

          <div className="mt-7 flex flex-wrap gap-8">
            <Stat label="Borrow APR" value={rayPct(proto?.borrowRate)} sub="USDC, variable" />
            <Stat label="Max leverage" value={`${maxLeverage.toFixed(2)}x`} sub={m ? `${m.stock.base} at ${Number(m.maxLtv) / 100}% LTV` : ''} />
            <Stat label="Your level" value={has ? `${openLeverage.toFixed(2)}x` : '-'} sub={has ? 'Held by the agents' : 'No loop open'} />
          </div>
        </div>
      </section>

      <section className="vault-panel relative z-10 rounded-t-[20px] px-6 md:px-24 pt-10 md:pt-14 pb-24">
        <div className="max-w-[1400px] mx-auto">
          <div className="mb-5 empty:hidden"><NotDeployed /></div>
          <div className="grid gap-3 md:grid-cols-2 lg:grid-cols-4">
            {markets.map((mk) => (
              <button
                key={mk.stock.key}
                type="button"
                onClick={() => setKey(mk.stock.key)}
                className={`rounded-2xl px-5 py-4 text-left transition-colors ${
                  mk.stock.key === m?.stock.key
                    ? 'bg-[#254839] text-[#fdf8ed]'
                    : 'bg-[#fdfaf1] text-fg hover:bg-[#fdfaf1]/70'
                }`}
              >
                <div className="flex items-center gap-2">
                  <TokenIcon symbol={mk.stock.base} size={22} />
                  <span className="text-[15px] font-medium">{mk.stock.base}</span>
                  <span className="ml-auto text-[11px] opacity-60">{mk.stock.name}</span>
                </div>
                <div className="mt-2 text-[22px] font-semibold tabular-nums">
                  {usd(mk.wrapperPrice)}
                </div>
                <div className="mt-1 text-[11px] opacity-70">
                  Up to {(Math.floor((1 / (1 - (Number(mk.maxLtv) / 10_000) * 0.995)) * 100) / 100).toFixed(2)}x
                </div>
              </button>
            ))}
          </div>

          <div className="mt-5 grid gap-5 lg:grid-cols-[1fr_1fr] items-start">
            <div className="rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
              <h2 className="text-[17px] font-semibold text-fg">Loop {m?.stock.base ?? ''}</h2>
              <p className="mt-1 text-[13px] text-fg-muted">
                The xStock itself. Closing hands it back the same way.
              </p>

              <div className="mt-4 rounded-2xl border border-[#254839]/12 bg-white/60 p-4">
                <div className="flex items-center justify-between text-[12px] text-fg-muted">
                  <span>Deposit</span>
                  <button onClick={() => setAmount(formatUnits(held, STOCK_DECIMALS))} className="hover:text-fg">
                    Balance {qty(held, 4)} · Max
                  </button>
                </div>
                <div className="mt-1.5 flex items-center justify-between">
                  <input
                    inputMode="decimal"
                    placeholder="0.00"
                    value={amount}
                    onChange={(e) => setAmount(e.target.value)}
                    className="w-full bg-transparent text-[28px] font-semibold text-fg tabular-nums outline-none placeholder:text-fg-muted/40"
                  />
                  <span className="shrink-0 rounded-full bg-[#254839]/[0.06] px-3 py-1.5 text-[14px] font-medium text-fg">
                    {m?.stock.base ?? ''}
                  </span>
                </div>
              </div>

              <div className="mt-4 rounded-2xl border border-[#254839]/12 bg-white/60 p-4">
                <div className="flex items-center justify-between text-[12px] text-fg-muted">
                  <span>Leverage</span>
                  <span className="text-fg">{leverage.toFixed(2)}x</span>
                </div>
                <input
                  type="range" min={1.1} max={maxLeverage} step={0.01} value={leverage}
                  onChange={(e) => setPicked(Number(e.target.value))}
                  className="mt-3 w-full accent-[#254839]"
                />
                <div className="mt-1 flex justify-between text-[11px] text-fg-muted">
                  <span>1.10x</span>
                  <span>{maxLeverage.toFixed(2)}x, the LTV ceiling</span>
                </div>
              </div>

              <dl className="mt-4 space-y-2 text-[13px]">
                <Row label="Stock you end up with" value={preview ? `${qty(preview.stock, 4)} ${m?.stock.base}` : '-'} />
                <Row label="Exposure" value={preview ? usd(preview.exposure) : '-'} />
                <Row label="Borrowed" value={preview ? usd(preview.borrowed) : '-'} />
              </dl>

              <button
                onClick={address ? open : () => connect()}
                disabled={busy || (!!address && (amt === 0n || amt > held || !m?.borrowAllowed))}
                className="mt-4 w-full rounded-full bg-[#254839] px-5 py-3.5 text-[15px] font-medium text-[#fdf8ed] transition-colors hover:bg-[#1F3D31] disabled:opacity-45"
              >
                {!address
                  ? 'Connect Wallet'
                  : busy
                    ? status || 'Working…'
                    : !m?.borrowAllowed
                      ? 'No fresh price'
                      : `Open at ${leverage.toFixed(2)}x`}
              </button>
              {status && !busy && pending === 'open' && (
                <p className="mt-2 text-[12px] text-fg-muted">{status}</p>
              )}
            </div>

            <div className="rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
              <h2 className="text-[17px] font-semibold text-fg">Your loop</h2>
              {!has ? (
                <p className="mt-4 text-[14px] text-fg-muted">
                  No loop open on {m?.stock.base ?? 'this stock'}. Deposit some and pick a level: the stock
                  the loop buys is the collateral for the USDC that bought it.
                </p>
              ) : (
                <>
                  <div className="mt-4 flex flex-wrap gap-8">
                    <Stat
                      label={m?.stock.base ?? 'Stock'}
                      value={qty(position!.collateralBase, 4)}
                      sub={`${usd(value)} at the oracle`}
                    />
                    <Stat
                      label="Health factor"
                      value={position!.healthFactorRay > 0n
                        ? (Number(position!.healthFactorRay) / Number(RAY)).toFixed(2)
                        : 'No debt'}
                      sub={`${openLeverage.toFixed(2)}x`}
                    />
                  </div>
                  <dl className="mt-5 space-y-2 text-[13px]">
                    <Row label="Your equity" value={usd(equity)} />
                    <Row label="Debt" value={usd(debt)} />
                    <Row label="Level the agents hold" value={`${Number(position!.targetLtvBps) / 100}% LTV`} />
                  </dl>
                  <button
                    onClick={close}
                    disabled={busy}
                    className="mt-4 w-full rounded-full border border-[#254839]/25 px-5 py-3.5 text-[15px] font-medium text-fg transition-colors hover:bg-[#254839]/[0.06] disabled:opacity-45"
                  >
                    Close, sell back and return the stock
                  </button>
                </>
              )}
              {/* Outside the branch on purpose: a successful close empties this
                  card, and a confirmation that unmounts with the thing it is
                  confirming is no confirmation at all. */}
              {status && !busy && pending === 'close' && (
                <p className="mt-3 text-[12px] text-fg-muted">{status}</p>
              )}
            </div>
          </div>
        </div>
      </section>
    </>
  );
}

function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div>
      <div className="text-[12px] uppercase tracking-wider text-fg-muted">{label}</div>
      <div className="text-[26px] text-fg font-semibold tabular-nums">{value}</div>
      {sub && <div className="text-[12px] text-fg-muted">{sub}</div>}
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between">
      <dt className="text-fg-muted">{label}</dt>
      <dd className="tabular-nums text-fg">{value}</dd>
    </div>
  );
}

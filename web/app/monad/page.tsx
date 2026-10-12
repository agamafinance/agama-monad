'use client';

import { useMemo, useState } from 'react';
import { encodeFunctionData, formatUnits, parseAbi, parseUnits } from 'viem';

import { ADDR, asset, BPS, RAY, STOCK_DECIMALS, TOKENS, USDC_DECIMALS } from '@/lib/monad/config';
import { earnRouterAbi, zapRouterAbi } from '@/lib/monad/generated/abis';
import {
  ensureAllowance, errorText, send, useTick, useMonadMarkets, useMonadPosition, useMonadProtocol,
  type Market,
} from '@/lib/monad/useMonad';
import { useMonadWallet } from '@/lib/monad/WalletProvider';
import { TokenIcon } from '@/components/icons/TokenIcon';
import { NotDeployed, PriceBadge } from '@/components/PriceBadge';
import { ago, useDepositBaseline, useLastAgentAction } from '@/lib/monad/agents';

/// The testnet stand-in DEX, priced at the Agama oracle and allowlisted on the zap.
const testDexAbi = parseAbi([
  'function swap(address wrapper, uint256 usdcIn, uint256 priceUsdc6) returns (uint256 out)',
]);

const pct = (bps: bigint | undefined) => (bps === undefined ? '-' : `${Number(bps) / 100}%`);
const usd = (v: bigint | undefined) =>
  v === undefined ? '-' : `$${Number(formatUnits(v, USDC_DECIMALS)).toLocaleString('en-US', { maximumFractionDigits: 2 })}`;
const qty = (v: bigint | undefined, dp = 4) =>
  v === undefined ? '-' : Number(formatUnits(v, STOCK_DECIMALS)).toFixed(dp);
const rayPct = (v: bigint | undefined) => (v === undefined ? '-' : `${(Number(v) / Number(RAY) * 100).toFixed(2)}%`);
const price = (v: bigint | undefined) =>
  v === undefined || v === 0n ? '-' : `$${Number(formatUnits(v, 18)).toFixed(2)}`;

export default function MonadEarnPage() {
  const { address, connect } = useMonadWallet();
  const { markets, refresh } = useMonadMarkets(address);
  const [tick, bumpTick] = useTick();
  const [sel, setSel] = useState(0);
  const m: Market | undefined = markets[sel];

  const proto = useMonadProtocol(address, tick);
  const position = useMonadPosition(address, m?.adapter, m?.wrapper, tick);

  const [amount, setAmount] = useState('');
  const [buying, setBuying] = useState(false);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState('');
  // Which card the running action belongs to, so its result is reported under
  // the button that was pressed and not in the card next to it.
  const [pending, setPending] = useState<'deposit' | 'close'>('deposit');

  // The app only ever speaks the base token: the xStock people hold, and what
  // closing hands back. The ERC-4626 wrapper the markets hold is wrapped and
  // unwrapped on the way through, and never named.
  const token = m?.base;
  const balance = m?.baseBalance;
  const symbol = m?.stock.base ?? '';

  const amt = useMemo(() => {
    try {
      return amount ? parseUnits(amount, buying ? USDC_DECIMALS : STOCK_DECIMALS) : 0n;
    } catch {
      return 0n;
    }
  }, [amount, buying]);

  const canBorrow = m ? m.borrowAllowed : true;

  // The level is not a question for the user. Every market is opened at the
  // same safety margin, a health factor of 1.60, which is the liquidation
  // threshold divided by 1.6, and never above what the market allows. On
  // TSLA's 40% threshold that is the 25% this used to default to; on SPY's
  // 60% it is 37.5%, because a broad index can carry more and should.
  const OPEN_HF = 16_000n; // 1.60 in bps
  const autoLtvBps = m
    ? (m.liqThreshold * BPS / OPEN_HF < m.maxLtv ? m.liqThreshold * BPS / OPEN_HF : m.maxLtv)
    : 0n;
  const ltvBps = canBorrow ? autoLtvBps : 0n;
  const borrowed = m && amt > 0n ? (amt * m.price / 10n ** 18n) * ltvBps / BPS : 0n;
  const borrowedUsdc = borrowed / 10n ** 12n; // 18 -> 6 decimals
  const spread = proto ? proto.vaultApy - proto.borrowRate : undefined;
  const extra = spread !== undefined ? (spread * ltvBps) / BPS : undefined;

  const bump = () => { bumpTick(); refresh(); };

  /// Buy the stock and open the position in one transaction, through the
  /// venue allowlisted on the zap.
  async function buyAndEarn() {
    if (!address || !m) return;
    setPending('deposit');
    const zap = ADDR.zapRouter;
    const dex = ADDR.testDexRouter;
    if (!zap || !dex) { setStatus('No swap venue on this network'); return; }
    setBusy(true);
    try {
      if (!m.wrapperPrice) throw new Error('No price yet');
      const data = encodeFunctionData({
        abi: testDexAbi, functionName: 'swap', args: [m.wrapper, amt, m.wrapperPrice],
      });
      const minOut = ((amt * 10n ** 18n) / m.wrapperPrice) * 98n / 100n;
      setStatus('Approving…');
      await ensureAllowance(address, TOKENS.USDC, zap, amt);
      setStatus('Buying and opening…');
      await send(address, zap, zapRouterAbi, 'buyAndEarn',
        [amt, dex, dex, data, m.adapter, minOut, ltvBps]);
      setStatus('Done');
      setAmount('');
      bump();
    } catch (e: unknown) {
      setStatus(errorText(e));
    } finally {
      setBusy(false);
    }
  }

  async function open() {
    if (!address || !m || !token) return;
    setPending('deposit');
    setBusy(true);
    try {
      setStatus('Approving…');
      await ensureAllowance(address, token, ADDR.earnRouter, amt);
      setStatus('Opening the position…');
      await send(address, ADDR.earnRouter, earnRouterAbi, 'openWithBase',
        [m.adapter, amt, ltvBps]);
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
    if (!address || !m) return;
    setPending('close');
    setBusy(true);
    try {
      setStatus('Closing…');
      // A few wei of interest can accrue between the read and the block, so the
      // router is allowed to pull a tiny top-up from the wallet.
      const topUp = parseUnits('1', USDC_DECIMALS);
      await ensureAllowance(address, TOKENS.USDC, ADDR.earnRouter, topUp);
      await send(address, ADDR.earnRouter, earnRouterAbi, 'closeToBaseWithTopUp', [m.adapter, topUp]);
      setStatus('Done');
      resetBaseline();
      bump();
    } catch (e: unknown) {
      setStatus(errorText(e));
    } finally {
      setBusy(false);
    }
  }

  const has = !!position?.hasPosition;
  const { grown, reset: resetBaseline } = useDepositBaseline(
    `agama.monad.deposited.${address ?? 'none'}.${m?.adapter ?? 'none'}`,
    position?.collateralBase,
  );
  const lastAction = useLastAgentAction(has ? position?.account : undefined, tick);

  return (
    <>
      <section className="px-6 md:px-24 pt-10 md:pt-14 pb-8">
        <div className="max-w-[1400px] mx-auto relative">
          {/* The house coin pair, struck with the stocks this page is about. */}
          <div aria-hidden className="pointer-events-none absolute right-0 -top-2 z-20 hidden lg:block">
            <img src={asset('/logos/coin-pair-earn.svg')} alt="" className="h-[300px] w-auto" />
          </div>

          <h1 className="mt-3 text-[34px] md:text-[44px] leading-[1.05] text-fg font-semibold">
            Deposit your stock,
            <br />
            get more stock
          </h1>
          <p className="mt-4 max-w-[640px] text-[15px] text-fg-muted">
            Deposit a tokenized stock. Agama borrows USDC against it at a safe level, puts it to work in
            the private-credit vault, and permissionless agents turn that yield back into more of your
            stock. Nothing to set, nothing to come back for. Live on Monad Testnet.
          </p>
          <PriceBadge markets={markets} />

          <div className="mt-7 flex flex-wrap gap-8">
            <Stat label="Vault APY" value={rayPct(proto?.vaultApy)} sub={proto?.vaultApyIsTarget ? 'Target, not yet measured' : 'Realized'} />
            <Stat label="Borrow APR" value={rayPct(proto?.borrowRate)} sub="USDC, variable" />
            <Stat label="Spread you earn" value={rayPct(spread)} sub="On every USDC borrowed" />
          </div>
        </div>
      </section>

      <section className="vault-panel relative z-10 rounded-t-[20px] px-6 md:px-24 pt-10 md:pt-14 pb-24">
        <div className="max-w-[1400px] mx-auto space-y-5">
          <NotDeployed />
          <MarketCards markets={markets} sel={sel} onSelect={setSel} connected={!!address} />

          <div className="grid gap-5 lg:grid-cols-[1fr_1fr] items-start">
            <div className="rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
              <div className="flex items-center justify-between">
                <h2 className="text-[17px] font-semibold text-fg">Deposit {m?.stock.base ?? ''}</h2>
                {m && (
                  <span className={m.marketOpen ? 'rounded-full bg-[#254839]/[0.06] px-3 py-1 text-[12px] text-fg' : 'rounded-full bg-[#b4571f]/10 px-3 py-1 text-[12px] text-[#b4571f]'}>
                    {m.marketOpen ? 'Live price' : 'No live price'}
                  </span>
                )}
              </div>

              <div className="mt-4 flex items-center gap-1 rounded-full bg-[#254839]/[0.06] p-1 w-fit">
                {([[false, 'Deposit'], [true, 'Buy and Earn']] as const).map(([v, label]) => (
                  <button
                    key={label}
                    onClick={() => { setBuying(v); setAmount(''); }}
                    className={
                      v === buying
                        ? 'rounded-full bg-[#254839] px-4 py-1.5 text-[13px] font-medium text-[#fdf8ed]'
                        : 'rounded-full px-4 py-1.5 text-[13px] text-fg-muted hover:text-fg'
                    }
                  >
                    {label}
                  </button>
                ))}
              </div>

              <p className="mt-2 text-[12px] text-fg-muted">
                {buying
                  ? 'Do not hold the stock yet? One transaction buys it and opens the position with it.'
                  : `Deposit ${symbol || 'your stock'} as it is. Closing hands the same token back.`}
              </p>

              <div className="mt-4 rounded-2xl border border-[#254839]/12 bg-white/60 p-4">
                <div className="flex items-center justify-between text-[12px] text-fg-muted">
                  <span>{buying ? 'Spend' : 'Deposit'}</span>
                  <button
                    onClick={() => setAmount(formatUnits(buying ? (proto?.usdc ?? 0n) : (balance ?? 0n), buying ? USDC_DECIMALS : STOCK_DECIMALS))}
                    className="hover:text-fg"
                  >
                    Balance {buying
                      ? Number(formatUnits(proto?.usdc ?? 0n, USDC_DECIMALS)).toFixed(2)
                      : qty(balance)} · Max
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
                    {buying ? 'USDC' : symbol}
                  </span>
                </div>
                <div className="mt-1 text-[12px] text-fg-muted">
                  {buying && amt > 0n && m?.wrapperPrice
                    ? `about ${qty((amt * 10n ** 18n) / m.wrapperPrice)} ${m.stock.base} at ${price(m?.price)}`
                    : `${price(m?.price)} per share`}
                </div>
              </div>

              <dl className="mt-4 space-y-2 text-[13px]">
                <Row
                  label="Borrowed into the vault"
                  value={borrowedUsdc > 0n ? `${usd(borrowedUsdc)} · ${pct(ltvBps)} of the stock` : '-'}
                />
                <Row label="Extra yield on the stock" value={extra !== undefined && ltvBps > 0n ? `${rayPct(extra)} a year` : '-'} />
                <Row label="Health factor at open" value={canBorrow ? '1.60' : 'No price'} />
              </dl>
              {m && !m.marketOpen && canBorrow && (
                <p className="mt-3 text-[12px] text-fg-muted">
                  The market for {m.stock.base} is closed, so this is its last close, signed by Chainlink.
                  Deposit and borrow all the same, at {pct(m.maxLtv)} rather than the usual level, which
                  leaves the position the same distance from liquidation until the session reopens.
                </p>
              )}
              {!canBorrow && (
                <p className="mt-3 text-[12px] text-[#b4571f]">
                  Nobody has priced this stock recently enough to lend against it. Your stock still goes in
                  as collateral, and the agents start borrowing the moment a fresh price lands.
                </p>
              )}

              <button
                onClick={address ? (buying ? buyAndEarn : open) : () => connect()}
                disabled={
                  busy ||
                  (!!address && (amt === 0n || amt > (buying ? (proto?.usdc ?? 0n) : (balance ?? 0n))))
                }
                className="mt-4 w-full rounded-full bg-[#254839] px-5 py-3.5 text-[15px] font-medium text-[#fdf8ed] transition-colors hover:bg-[#1F3D31] disabled:opacity-45"
              >
                {!address
                  ? 'Connect Wallet'
                  : busy
                    ? status || 'Working…'
                    : buying
                      ? 'Buy and earn'
                      : canBorrow
                        ? 'Deposit and start earning'
                        : 'Deposit as collateral'}
              </button>
              {status && !busy && pending === 'deposit' && (
                <p className="mt-2 text-[12px] text-fg-muted">{status}</p>
              )}
            </div>

            <div className="rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
              <h2 className="text-[17px] font-semibold text-fg">Your position</h2>

              {!has ? (
                <p className="mt-4 text-[14px] text-fg-muted">
                  Nothing here yet. Deposit a stock and the protocol does the rest: it borrows against it,
                  puts the USDC to work, and keeps the position where it should be.
                </p>
              ) : (
                <>
                  <div className="mt-4 flex flex-wrap gap-8">
                    <Stat
                      label={`Your ${m?.stock.base}`}
                      value={qty(position?.collateralBase)}
                      sub={grown !== undefined ? `+${qty(grown)} added by the agents` : usd(position?.collateralValue)}
                    />
                    <Stat
                      label="Health factor"
                      value={position && position.healthFactorRay > 0n ? (Number(position.healthFactorRay) / Number(RAY)).toFixed(2) : 'No debt'}
                      sub="Agents act at 1.15"
                    />
                  </div>
                  <dl className="mt-5 space-y-2 text-[13px]">
                    <Row label="Debt" value={usd(position?.debt)} />
                    <Row label="Yield buffer" value={usd(position?.redeemable)} />
                    <Row label="Target level" value={pct(position?.targetLtvBps)} />
                  </dl>
                  <div className="mt-4 rounded-2xl border border-[#254839]/12 bg-white/60 p-4">
                    <div className="flex items-center gap-2">
                      <span className="relative flex h-2 w-2" aria-hidden>
                        <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-[#254839] opacity-60" />
                        <span className="relative inline-flex h-2 w-2 rounded-full bg-[#254839]" />
                      </span>
                      <span className="text-[13px] font-medium text-fg">Agents running</span>
                    </div>
                    <p className="mt-1.5 text-[13px] text-fg-muted">
                      The stock moves, the debt follows it back to {pct(position?.targetLtvBps)}. The vault
                      yield above that debt is bought back as more stock. Nothing here is yours to do, and
                      nothing here is ours to control: the calls are open to anyone.
                    </p>
                    <p className="mt-2 text-[12px] text-fg-muted">
                      {lastAction
                        ? lastAction.kind === 'rebalance'
                          ? `Last action: debt ${(lastAction.debtDelta ?? 0n) >= 0n ? '+' : '-'}${usd(
                              (lastAction.debtDelta ?? 0n) < 0n ? -(lastAction.debtDelta ?? 0n) : lastAction.debtDelta ?? 0n,
                            ).replace('$', '')} USDC, ${ago(lastAction.at)}`
                          : `Last action: ${qty(lastAction.stockAdded)} ${m?.stock.base} bought with the yield, ${ago(lastAction.at)}`
                        : 'No action in the last few minutes. The position is on target.'}
                    </p>
                  </div>
                  <button
                    onClick={close}
                    disabled={busy}
                    className="mt-4 w-full rounded-full border border-[#254839]/25 px-5 py-3.5 text-[15px] font-medium text-fg transition-colors hover:bg-[#254839]/[0.06] disabled:opacity-45"
                  >
                    Close, get the stock back
                  </button>
                </>
              )}
              {/* Outside the branch on purpose: closing empties this card, and
                  a confirmation that unmounts with it confirms nothing. */}
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

function MarketCards({
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
            <span className="text-[11px] opacity-70">{ago(m.observedAt)}</span>
          </div>
          <div className="mt-1 text-[11px] opacity-70">
            Max LTV {pct(m.maxLtv)}{m.marketOpen ? '' : ' · last known price'}
            {connected && m.balance > 0n ? ` · ${qty(m.balance, 2)} held` : ''}
          </div>
        </button>
      ))}
    </div>
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
      <dd className="text-fg tabular-nums">{value}</dd>
    </div>
  );
}


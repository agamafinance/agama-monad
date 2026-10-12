'use client';

import { useEffect, useMemo, useState } from 'react';
import { formatUnits } from 'viem';

import { NotDeployed, PriceBadge } from '@/components/PriceBadge';
import { ADDR, asset, BPS, DEPLOYED, RAY, STOCK_DECIMALS } from '@/lib/monad/config';
import { amplifyRouterAbi, lendingPoolAbi } from '@/lib/monad/generated/abis';
import { planClose, planOpen } from '@/lib/monad/loop';
import { ago, useLastAgentAction } from '@/lib/monad/agents';
import {
  ensureAllowance, erc20Abi, errorText, pub, send, useTick, useMonadMarkets, useMonadPosition, useMonadProtocol,
  type Market,
} from '@/lib/monad/useMonad';
import { useMonadWallet } from '@/lib/monad/WalletProvider';
import {
  AgentsCard, AmountBox, card, GasNotice, Hero, MarketCards, Panel, parseAmount, pct, price, primaryBtn, qty, rayPct,
  Row, secondaryBtn, SessionBadge, Stat, Status, Step, TestnetNote, usd, useMonBalance,
} from '@/components/monad/ui';

/// What Kuru's book keeps around the oracle on a buy, as the loop planner
/// counts it.
const VENUE_SPREAD_BPS = 30n;

/// A loop at L carries an LTV of (L - 1) / L, so the market's LTV caps L at
/// 1 / (1 - LTV). The haircut keeps the slider just short of the edge rather
/// than ending in a revert.
const maxLeverageOf = (m: Market | undefined) =>
  !m || m.maxLtv === 0n ? 1 : Math.floor((1 / (1 - (Number(m.maxLtv) / 10_000) * 0.995)) * 100) / 100;

export default function MonadAmplifyPage() {
  const { address, connect } = useMonadWallet();
  const [tick, bumpTick] = useTick();
  const proto = useMonadProtocol(address, tick);
  const { markets, refresh } = useMonadMarkets(address);
  const mon = useMonBalance(address, tick);

  const [sel, setSel] = useState(0);
  // Open on the stock asked for (?s=NVDA, from Portfolio).
  const [opened, setOpened] = useState(false);
  useEffect(() => {
    if (opened || !markets.length) return;
    const want = new URLSearchParams(window.location.search).get('s');
    const i = want ? markets.findIndex((mk) => mk.stock.key === want) : -1;
    if (i >= 0) setSel(i);
    setOpened(true);
  }, [markets, opened]);
  const m: Market | undefined = markets[sel];
  const position = useMonadPosition(address, m?.adapter, m?.wrapper, tick);
  const symbol = m?.stock.base ?? '';

  const [amount, setAmount] = useState('');
  // Undefined until the market says what it allows: the ceiling is a property
  // of the collateral, so there is no sensible default before it is known.
  const [picked, setPicked] = useState<number>();
  useEffect(() => setPicked(undefined), [sel]);
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState<{ text: string; hash?: string; where: 'open' | 'close' }>();
  const [minBorrow, setMinBorrow] = useState(0n);

  useEffect(() => {
    if (!DEPLOYED) return;
    pub.readContract({ address: ADDR.pool, abi: lendingPoolAbi, functionName: 'minBorrowAmount' })
      .then((v) => setMinBorrow(v as bigint)).catch(() => {});
  }, []);

  const maxLeverage = maxLeverageOf(m);
  const canLoop = maxLeverage > 1.1;
  // Most of the way to the ceiling, which is what someone opening a leveraged
  // position came for, and still short of the edge. A slider the user has moved
  // is theirs; it only gets clamped if the market they switch to allows less.
  const leverage = Math.min(picked ?? Math.max(1.1, Math.floor(maxLeverage * 90) / 100), maxLeverage);

  const amt = parseAmount(amount, STOCK_DECIMALS);
  const held = m?.baseBalance ?? 0n;
  const enough = amt <= held;

  // The loop as the planner will build it: borrow (L - 1) times the deposit,
  // buy the stock on Kuru at the oracle less the book's spread, pledge it.
  const start = m ? (amt * m.price) / 10n ** 30n : 0n;
  const borrow = (start * BigInt(Math.round(leverage * 10_000) - 10_000)) / BPS;
  const boughtValue = (borrow * (BPS - VENUE_SPREAD_BPS)) / BPS;
  const bought = m && m.price > 0n ? (boughtValue * 10n ** 30n) / m.price : 0n;
  const ltvAfter = start + boughtValue > 0n ? (borrow * BPS) / (start + boughtValue) : 0n;

  const debt = position?.debt ?? 0n;
  const value = position?.collateralValue ?? 0n;
  const has = !!position?.hasPosition;
  const multiple = has && value > debt ? (Number(value) / Number(value - debt)).toFixed(2) : undefined;
  const target = position?.targetLtvBps ?? 0n;
  const targetMultiple = target > 0n && target < BPS ? (1 / (1 - Number(target) / 10_000)).toFixed(2) : undefined;
  const health = position && position.debt > 0n && position.healthFactorRay > 0n
    ? (Number(position.healthFactorRay) / Number(RAY)).toFixed(2)
    : undefined;
  const lastAction = useLastAgentAction(has ? position?.account : undefined, tick);

  const bump = () => { bumpTick(); refresh(); };

  async function run(where: 'open' | 'close', act: () => Promise<`0x${string}`>) {
    if (!address) return setStatus({ text: 'Connect a wallet first.', where });
    if (!m) return setStatus({ text: 'Markets are still loading.', where });
    setBusy(true);
    try {
      const hash = await act();
      setStatus({ text: 'Done.', hash, where });
      if (where === 'open') setAmount('');
    } catch (e: unknown) {
      setStatus({ text: errorText(e), where });
    } finally {
      setBusy(false);
      bump();
    }
  }

  const open = () =>
    run('open', async () => {
      setStatus({ text: 'Pricing the loop...', where: 'open' });
      // The deposit is in the base token, which the router wraps on the way in,
      // so the plan is made in the wrapper shares that will come out of it.
      const shares = (await pub.readContract({
        address: m!.wrapper, abi: erc20Abi, functionName: 'convertToShares', args: [amt],
      })) as bigint;
      const plan = await planOpen(m!, shares, leverage, minBorrow);
      setStatus({ text: `Approving ${symbol}...`, where: 'open' });
      await ensureAllowance(address!, m!.base!, ADDR.amplifyRouter, amt);
      setStatus({ text: `Looping ${plan.hops.length} time${plan.hops.length === 1 ? '' : 's'} through Kuru...`, where: 'open' });
      return send(address!, ADDR.amplifyRouter, amplifyRouterAbi, 'openStockWithBase', [m!.adapter, amt, plan.hops]);
    });

  const close = () =>
    run('close', async () => {
      setStatus({ text: 'Pricing the unwind...', where: 'close' });
      const hops = await planClose(m!, position!.collateral, position!.debt, position!.liquidationThresholdBps);
      setStatus({ text: `Selling back on Kuru, ${hops.length} step${hops.length === 1 ? '' : 's'}...`, where: 'close' });
      return send(address!, ADDR.amplifyRouter, amplifyRouterAbi, 'closeStock', [m!.adapter, hops, true]);
    });

  const lastText = useMemo(() => {
    if (!lastAction) return 'No agent action in the last few minutes. The loop is on target.';
    if (lastAction.kind === 'compound')
      return `Last action: ${qty(lastAction.stockAdded)} ${symbol} bought with the yield, ${ago(lastAction.at)}.`;
    const d = lastAction.debtDelta ?? 0n;
    return `Last action: debt ${d >= 0n ? '+' : '-'}${usd(d < 0n ? -d : d).replace('$', '')} USDC, ${ago(lastAction.at)}.`;
  }, [lastAction, symbol]);

  return (
    <>
      <Hero art={asset('/logos/coin-pair-amplify.svg')} title={<>Amplify your stock</>}>
        <p className="mt-4 max-w-[640px] text-[15px] text-fg-muted">
          One slider. Agama borrows USDC against your stock, buys more of the same stock on Kuru&apos;s on-chain order
          book and pledges it, in one transaction. How far it goes is the market&apos;s own LTV ceiling. The agents
          then hold the level as the price moves: a rise is borrowed into the vault as a buffer, a fall is repaid
          out of it.
        </p>
        <div className="mt-7 flex flex-wrap gap-8">
          <Stat label="Borrow APR" value={rayPct(proto?.borrowRate)} sub="USDC, variable" />
          <Stat label="Max multiple" value={m ? `${maxLeverage.toFixed(2)}x` : '-'} sub={`${symbol} at ${pct(m?.maxLtv)} LTV`} />
        </div>
      </Hero>

      <Panel>
        <NotDeployed />
        <GasNotice address={address} mon={mon} />
        <MarketCards markets={markets} sel={sel} onSelect={setSel} connected={!!address} />
        {markets.length > 0 && <PriceBadge markets={markets} />}

        <div className="grid gap-5 lg:grid-cols-[1fr_1fr] items-start">
          <div className={card}>
            <div className="flex items-center justify-between">
              <h2 className="text-[17px] font-semibold text-fg">Loop {symbol}</h2>
              <SessionBadge m={m} />
            </div>
            {has ? (
              <p className="mt-4 text-[14px] text-fg-muted">
                You already have a position on {symbol}. Close it to open a new loop at a different multiple.
              </p>
            ) : (
              <>
                <AmountBox
                  label="Deposit"
                  balanceLabel={qty(held)}
                  onMax={() => setAmount(formatUnits(held, STOCK_DECIMALS))}
                  value={amount}
                  onChange={setAmount}
                  unit={symbol}
                  hint={`${price(m?.price)} per share`}
                />
                <div className="mt-5">
                  <div className="flex items-center justify-between text-[13px]">
                    <span className="text-fg-muted">Multiple</span>
                    <span className="font-medium text-fg tabular-nums">{leverage.toFixed(2)}x</span>
                  </div>
                  <input
                    type="range"
                    min={1.1}
                    max={maxLeverage}
                    step={0.01}
                    value={leverage}
                    onChange={(e) => setPicked(Number(e.target.value))}
                    className="mt-2 w-full accent-[#254839]"
                    aria-label="Leverage"
                  />
                  <div className="flex justify-between text-[11px] text-fg-muted">
                    <span>1.10x</span>
                    <span>{maxLeverage.toFixed(2)}x max</span>
                  </div>
                </div>
                <dl className="mt-4 space-y-2 text-[13px]">
                  <Row label="Borrowed" value={borrow > 0n ? usd(borrow) : '-'} />
                  <Row label="Stock bought with it" value={bought > 0n ? `${qty(bought)} ${symbol}` : '-'} />
                  <Row label="Exposure" value={amt > 0n ? `${qty(amt + bought)} ${symbol}` : '-'} />
                  <Row label="LTV after" value={ltvAfter > 0n ? `${pct(ltvAfter)} of ${pct(m?.maxLtv)} max` : '-'} />
                </dl>
                <button
                  onClick={address ? open : () => connect()}
                  disabled={busy || (!!address && (!m || amt === 0n || !enough || !canLoop || !m.borrowAllowed))}
                  className={`mt-4 ${primaryBtn}`}
                >
                  {!address
                    ? 'Connect Wallet'
                    : busy && status?.where === 'open'
                      ? <Step text={status.text} />
                      : !m
                        ? 'Loading markets...'
                        : !m.borrowAllowed
                          ? `No fresh price for ${symbol}`
                          : !canLoop
                            ? 'No loop possible on this market right now'
                            : !enough
                              ? `Not enough ${symbol}, see the Faucet`
                              : amt === 0n
                                ? 'Enter an amount'
                                : `Amplify ${leverage.toFixed(2)}x`}
                </button>
              </>
            )}
            {!busy && status?.where === 'open' && <Status text={status.text} hash={status.hash} />}
          </div>

          <div className={card}>
            <h2 className="text-[17px] font-semibold text-fg">Your loop</h2>
            {!has ? (
              <p className="mt-4 text-[14px] text-fg-muted">No loop on {symbol || 'this stock'}.</p>
            ) : (
              <>
                <div className="mt-4 flex flex-wrap gap-8">
                  <Stat label={`Your ${symbol}`} value={qty(position?.collateralBase)} sub={`${usd(value)} at the oracle`} />
                  <Stat
                    label="Multiple"
                    value={multiple ? `${multiple}x` : '-'}
                    sub={targetMultiple ? `Target ${targetMultiple}x` : undefined}
                  />
                  <Stat label="Health factor" value={health ?? 'No debt'} sub="Liquidation below 1.00" />
                </div>
                <dl className="mt-5 space-y-2 text-[13px]">
                  <Row label="Value" value={usd(value)} />
                  <Row label="Debt" value={usd(debt)} />
                  <Row
                    label="Level now / target"
                    value={`${pct(value > 0n ? (debt * BPS) / value : 0n)} / ${pct(target)}`}
                  />
                </dl>
                <AgentsCard last={lastText}>
                  The price rises, the agents borrow the difference into the vault; it falls, they repay out of that
                  buffer. The level stays where you set it. A keeper makes the calls every minute, and anyone else
                  can too.
                </AgentsCard>
                <p className="mt-3 text-[12px] text-fg-muted">
                  Closing sells just enough {symbol} on Kuru to repay the debt and hands the rest back to your
                  wallet, in one transaction.
                </p>
                <button onClick={close} disabled={busy} className={`mt-4 ${secondaryBtn}`}>
                  {busy && status?.where === 'close' ? <Step text={status.text} /> : 'Close, sell what repays, keep the rest'}
                </button>
              </>
            )}
            {/* Outside the branch on purpose: a successful close empties this
                card, and a confirmation that unmounts with the thing it is
                confirming is no confirmation at all. */}
            {!busy && status?.where === 'close' && <Status text={status.text} hash={status.hash} />}
          </div>
        </div>

        <TestnetNote />
      </Panel>
    </>
  );
}

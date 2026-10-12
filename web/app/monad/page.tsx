'use client';

import { useEffect, useState } from 'react';
import { formatUnits, parseUnits } from 'viem';
import { swapCall } from '@/lib/monad/loop';

import { ADDR, asset, BPS, RAY, STOCK_DECIMALS, TOKENS, USDC_DECIMALS } from '@/lib/monad/config';
import { earnRouterAbi, zapRouterAbi } from '@/lib/monad/generated/abis';
import {
  ensureAllowance, errorText, send, useTick, useMonadMarkets, useMonadPosition, useMonadProtocol,
  type Market,
} from '@/lib/monad/useMonad';
import { useMonadWallet } from '@/lib/monad/WalletProvider';
import { NotDeployed, PriceBadge } from '@/components/PriceBadge';
import { ago, useDepositBaseline, useLastAgentAction } from '@/lib/monad/agents';
import {
  AgentsCard, AmountBox, card, GasNotice, Hero, MarketCards, Panel, parseAmount, pct, price, primaryBtn, qty,
  rayPct, Row, secondaryBtn, SessionBadge, Stat, Status, Step, TestnetNote, usd, useMonBalance,
} from '@/components/monad/ui';

export default function MonadEarnPage() {
  const { address, connect } = useMonadWallet();
  const { markets, refresh } = useMonadMarkets(address);
  const [tick, bumpTick] = useTick();
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

  const proto = useMonadProtocol(address, tick);
  const position = useMonadPosition(address, m?.adapter, m?.wrapper, tick);
  const mon = useMonBalance(address, tick);

  const [amount, setAmount] = useState('');
  const [buying, setBuying] = useState(false);
  // The slider is in bps of LTV. Undefined until the market says what it
  // allows, then a level that leaves the position well clear of liquidation.
  const [picked, setPicked] = useState<number>();
  useEffect(() => setPicked(undefined), [sel]);
  const [busy, setBusy] = useState(false);
  // Which card the running action belongs to, so its result is reported under
  // the button that was pressed and not in the card next to it.
  const [status, setStatus] = useState<{ text: string; hash?: string; where: 'deposit' | 'close' }>();

  // The app only ever speaks the base token: the xStock people hold, and what
  // closing hands back. The ERC-4626 wrapper the markets hold is wrapped and
  // unwrapped on the way through, and never named.
  const token = m?.base;
  const balance = m?.baseBalance ?? 0n;
  const symbol = m?.stock.base ?? '';
  const has = !!position?.hasPosition;

  const amt = parseAmount(amount, buying ? USDC_DECIMALS : STOCK_DECIMALS);
  const spendable = buying ? (proto?.usdc ?? 0n) : balance;
  const enough = amt <= spendable;

  // Nothing can be borrowed against a stale price, so the level is 0 until
  // the next one lands. Otherwise the market's ceiling, which is already
  // lowered while the session is closed, caps whatever the slider says.
  const canBorrow = m ? m.borrowAllowed : true;
  const maxLtv = m ? Number(m.maxLtv) : 0;
  const defaultLtv = Math.floor((maxLtv * 0.8) / 50) * 50;
  const target = position && position.targetLtvBps > 0n ? Number(position.targetLtvBps) : undefined;
  const ltv = canBorrow ? Math.min(picked ?? target ?? defaultLtv, maxLtv) : 0;
  const ltvBps = BigInt(ltv);

  // What the deposit is worth in USDC: what is spent on a buy, the stock at
  // the oracle otherwise (18 + 18 decimals down to 6).
  const value = buying ? amt : m ? (amt * m.price) / 10n ** 30n : 0n;
  const borrowed = (value * ltvBps) / BPS;
  const spread = proto ? proto.vaultApy - proto.borrowRate : undefined;
  const extra = spread !== undefined ? (spread * ltvBps) / BPS : undefined;
  const healthAtOpen = m && ltv > 0 ? (Number(m.liqThreshold) / ltv).toFixed(2) : '-';

  const bump = () => { bumpTick(); refresh(); };

  /// Every action reports under its own button, and ends with a re-read.
  async function run(where: 'deposit' | 'close', act: () => Promise<`0x${string}`>) {
    if (!address) return setStatus({ text: 'Connect a wallet first.', where });
    if (!m) return setStatus({ text: 'Markets are still loading.', where });
    setBusy(true);
    try {
      const hash = await act();
      setStatus({ text: 'Done.', hash, where });
      if (where === 'deposit') setAmount('');
      if (where === 'close') resetBaseline();
    } catch (e: unknown) {
      setStatus({ text: errorText(e), where });
    } finally {
      setBusy(false);
      bump();
    }
  }

  /// Buy the stock and open the position in one transaction, through the
  /// venue allowlisted on the zap.
  const buyAndEarn = () =>
    run('deposit', async () => {
      const zap = ADDR.zapRouter;
      if (!zap) throw new Error('No swap venue on this network');
      if (!m!.wrapperPrice) throw new Error('No price yet');
      const { target: dex, data, minOut } = swapCall(m!, 'buy', amt);
      setStatus({ text: 'Approving USDC...', where: 'deposit' });
      await ensureAllowance(address!, TOKENS.USDC, zap, amt);
      setStatus({ text: 'Buying on Kuru and opening...', where: 'deposit' });
      return send(address!, zap, zapRouterAbi, 'buyAndEarn', [amt, dex, dex, data, m!.adapter, minOut, ltvBps]);
    });

  const deposit = () =>
    run('deposit', async () => {
      setStatus({ text: `Approving ${symbol}...`, where: 'deposit' });
      await ensureAllowance(address!, token!, ADDR.earnRouter, amt);
      setStatus({ text: 'Depositing and borrowing...', where: 'deposit' });
      return send(address!, ADDR.earnRouter, earnRouterAbi, 'openWithBase', [m!.adapter, amt, ltvBps]);
    });

  const close = () =>
    run('close', async () => {
      // A few wei of interest can accrue between the read and the block, so the
      // router is allowed to pull a tiny top-up from the wallet.
      const topUp = parseUnits('1', USDC_DECIMALS);
      setStatus({ text: 'Approving the top-up...', where: 'close' });
      await ensureAllowance(address!, TOKENS.USDC, ADDR.earnRouter, topUp);
      setStatus({ text: 'Closing...', where: 'close' });
      return send(address!, ADDR.earnRouter, earnRouterAbi, 'closeToBaseWithTopUp', [m!.adapter, topUp]);
    });

  const { grown, reset: resetBaseline } = useDepositBaseline(
    `agama.monad.deposited.${address ?? 'none'}.${m?.adapter ?? 'none'}`,
    position?.collateralBase,
  );
  const lastAction = useLastAgentAction(has ? position?.account : undefined, tick);
  const health = position && position.healthFactorRay > 0n && position.debt > 0n
    ? (Number(position.healthFactorRay) / Number(RAY)).toFixed(2)
    : undefined;
  const levelNow = position && position.collateralValue > 0n ? (position.debt * BPS) / position.collateralValue : undefined;
  // There is no call that moves the target of an open position on its own:
  // adding to it is what does, at the blended level of the whole position.
  const sliderMoved = has && target !== undefined && picked !== undefined && ltv !== target;

  return (
    <>
      <Hero
        art={asset('/logos/coin-pair-earn.svg')}
        title={
          <>
            Deposit your stock,
            <br />
            get more stock
          </>
        }
      >
        <p className="mt-4 max-w-[640px] text-[15px] text-fg-muted">
          Deposit a tokenized stock. Agama pledges it as collateral in the Arrow lending pool, borrows USDC from the
          pool at the level you pick, and puts that USDC to work in the Agama private-credit vault. Permissionless
          agents hold the level and turn the vault yield back into more of your stock. Live on Monad Testnet, with
          stand-in tokens priced off the real xStocks.
        </p>
        <div className="mt-7 flex flex-wrap gap-8">
          <Stat
            label="Vault APY"
            value={rayPct(proto?.vaultApy)}
            sub={proto?.vaultApyIsTarget ? 'Private credit, target rate' : 'Private credit, realized'}
          />
          <Stat label="Borrow APR" value={rayPct(proto?.borrowRate)} sub="USDC, variable" />
          <Stat label="Spread you earn" value={rayPct(spread)} sub="On every USDC borrowed" />
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
              <h2 className="text-[17px] font-semibold text-fg">Deposit {symbol}</h2>
              <SessionBadge m={m} />
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
                ? `Do not hold ${symbol || 'the stock'} yet? One transaction buys it on Kuru's order book and opens the position with it.`
                : `Deposit ${symbol || 'your stock'} as it is. Closing hands the same token back.`}
            </p>

            <AmountBox
              label={buying ? 'Spend' : 'Deposit'}
              balanceLabel={buying ? usd(proto?.usdc).replace('$', '') : qty(balance)}
              onMax={() => setAmount(formatUnits(spendable, buying ? USDC_DECIMALS : STOCK_DECIMALS))}
              value={amount}
              onChange={setAmount}
              unit={buying ? 'USDC' : symbol}
              hint={
                buying && amt > 0n && m?.wrapperPrice
                  ? `about ${qty((amt * 10n ** 18n) / m.wrapperPrice)} ${symbol} at ${price(m.price)}`
                  : `${price(m?.price)} per share`
              }
            />

            <div className="mt-5">
              <div className="flex items-center justify-between text-[13px]">
                <span className="text-fg-muted">Level the agents hold</span>
                <span className="font-medium text-fg tabular-nums" data-testid="ltv">
                  {pct(ltv)} of the stock
                </span>
              </div>
              <input
                type="range"
                min={0}
                max={maxLtv}
                step={50}
                value={ltv}
                disabled={!canBorrow}
                onChange={(e) => setPicked(Number(e.target.value))}
                className="mt-2 w-full accent-[#254839] disabled:opacity-45"
                aria-label="Target LTV"
              />
              <div className="flex justify-between text-[11px] text-fg-muted">
                <span>0%</span>
                <span>{pct(maxLtv)} max{m && !m.marketOpen ? ', lowered while the market is closed' : ''}</span>
              </div>
            </div>

            <dl className="mt-4 space-y-2 text-[13px]">
              <Row label="Borrowed into the vault" value={borrowed > 0n ? usd(borrowed) : '-'} />
              <Row label="Extra yield on the stock" value={extra !== undefined && ltv > 0 ? `${rayPct(extra)} a year` : '-'} />
              <Row label="Health factor at open" value={healthAtOpen} />
            </dl>
            {m && !m.marketOpen && canBorrow && (
              <p className="mt-3 text-[12px] text-fg-muted">
                The market for {symbol} is closed, so this is its last close, signed by Chainlink. The max level and
                the liquidation threshold are both lowered until the session reopens, which keeps a position opened
                now the same distance from liquidation.
              </p>
            )}
            {m && !canBorrow && (
              <p className="mt-3 text-[12px] text-[#b4571f]">
                No fresh price for {symbol}: borrowing waits for the next one. A deposit now goes in as collateral
                with nothing borrowed.
              </p>
            )}

            <button
              onClick={address ? (buying ? buyAndEarn : deposit) : () => connect()}
              disabled={busy || (!!address && (!m || amt === 0n || !enough || (canBorrow && ltv === 0)))}
              className={`mt-4 ${primaryBtn}`}
            >
              {!address
                ? 'Connect Wallet'
                : busy && status?.where === 'deposit'
                  ? <Step text={status.text} />
                  : !m
                    ? 'Loading markets...'
                    : !enough
                      ? `Not enough ${buying ? 'USDC' : symbol}, see the Faucet`
                      : amt === 0n
                        ? 'Enter an amount'
                        : buying
                          ? 'Buy and earn'
                          : !canBorrow
                            ? 'Deposit as collateral'
                            : has
                              ? 'Add to the position'
                              : 'Deposit and start earning'}
            </button>
            {!busy && status?.where === 'deposit' && <Status text={status.text} hash={status.hash} />}
          </div>

          <div className={card}>
            <h2 className="text-[17px] font-semibold text-fg">Your position</h2>
            {!has ? (
              <p className="mt-4 text-[14px] text-fg-muted">
                Nothing here yet. Deposit a stock and the protocol does the rest: it pledges it in the Arrow lending
                pool, borrows USDC against it, puts the USDC in the private-credit vault, and keeps the position where
                you set it.
              </p>
            ) : (
              <>
                <div className="mt-4 flex flex-wrap gap-8">
                  <Stat
                    label={`Your ${symbol}`}
                    value={qty(position?.collateralBase)}
                    sub={grown !== undefined ? `+${qty(grown)} added by the agents` : usd(position?.collateralValue)}
                  />
                  <Stat label="Health factor" value={health ?? 'No debt'} sub="Liquidation below 1.00" />
                </div>
                <dl className="mt-5 space-y-2 text-[13px]">
                  <Row label="Debt" value={usd(position?.debt)} />
                  <Row label="Yield buffer in the vault" value={usd(position?.redeemable)} />
                  <Row label="Level now" value={pct(levelNow)} />
                  <Row label="Target level" value={pct(position?.targetLtvBps)} />
                </dl>
                {sliderMoved && (
                  <p className="mt-3 text-[12px] text-fg-muted">
                    The target of an open position moves when you add to it: the new {symbol} is borrowed against at{' '}
                    {pct(ltv)}, and the target becomes the level of the whole position.
                  </p>
                )}
                <AgentsCard
                  last={
                    lastAction
                      ? lastAction.kind === 'rebalance'
                        ? `Last action: debt ${(lastAction.debtDelta ?? 0n) >= 0n ? '+' : '-'}${usd(
                            (lastAction.debtDelta ?? 0n) < 0n ? -(lastAction.debtDelta ?? 0n) : lastAction.debtDelta ?? 0n,
                          ).replace('$', '')} USDC, ${ago(lastAction.at)}.`
                        : `Last action: ${qty(lastAction.stockAdded)} ${symbol} bought with the yield, ${ago(lastAction.at)}.`
                      : 'No agent action in the last few minutes. The position is on target.'
                  }
                >
                  The stock moves, the debt follows it back to {pct(position?.targetLtvBps)}. The vault yield above
                  that debt is bought back as more stock on Kuru. A keeper makes the calls every minute, and the
                  calls are open to anyone: nothing here is yours to do, and nothing here is ours to control.
                </AgentsCard>
                <p className="mt-3 text-[12px] text-fg-muted">
                  Closing repays the debt from the yield buffer and hands the {symbol} back to your wallet, in one
                  transaction. If the buffer falls short, up to 1 USDC of the difference comes from your wallet.
                </p>
                <button onClick={close} disabled={busy} className={`mt-4 ${secondaryBtn}`}>
                  {busy && status?.where === 'close' ? <Step text={status.text} /> : 'Close, get the stock back'}
                </button>
              </>
            )}
            {/* Outside the branch on purpose: closing empties this card, and a
                confirmation that unmounts with it confirms nothing. */}
            {!busy && status?.where === 'close' && <Status text={status.text} hash={status.hash} />}
          </div>
        </div>

        <TestnetNote />
      </Panel>
    </>
  );
}

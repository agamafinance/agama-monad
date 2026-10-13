'use client';

import { useEffect, useMemo, useState } from 'react';
import { formatUnits, parseUnits } from 'viem';

import { ADDR, DEPLOYED, TOKENS, USDC_DECIMALS } from '@/lib/monad/config';
import { lendingPoolAbi } from '@/lib/monad/generated/abis';
import {
  ensureAllowance, erc20Abi, errorText, pub, send, useTick, useMonadProtocol,
} from '@/lib/monad/useMonad';
import { useMonadWallet } from '@/lib/monad/WalletProvider';

const usd = (v: bigint | undefined) =>
  v === undefined ? '-' : `$${Number(formatUnits(v, USDC_DECIMALS)).toLocaleString('en-US', { maximumFractionDigits: 2 })}`;
const rayPct = (v: bigint | undefined) => (v === undefined ? '-' : `${(Number(v) / 1e27 * 100).toFixed(2)}%`);

export default function MonadLendPage() {
  const { address, connect } = useMonadWallet();
  const [tick, bumpTick] = useTick();
  const proto = useMonadProtocol(address, tick);

  const [pool, setPool] = useState<{ assets: bigint; supplyRate: bigint; shares: bigint; redeemable: bigint }>();
  const [tab, setTab] = useState<'supply' | 'withdraw'>('supply');
  const [amount, setAmount] = useState('');
  const [busy, setBusy] = useState(false);
  const [status, setStatus] = useState('');

  useEffect(() => {
    if (!DEPLOYED) return;
    let alive = true;
    (async () => {
      try {
        const [assets, reserve, shares] = await Promise.all([
          pub.readContract({ address: ADDR.pool, abi: lendingPoolAbi, functionName: 'totalAssets' }),
          pub.readContract({ address: ADDR.pool, abi: lendingPoolAbi, functionName: 'getReserveState' }),
          address
            ? pub.readContract({ address: ADDR.pool, abi: erc20Abi, functionName: 'balanceOf', args: [address] })
            : Promise.resolve(0n),
        ]);
        const redeemable = (shares as bigint) > 0n
          ? ((await pub.readContract({
              address: ADDR.pool, abi: lendingPoolAbi, functionName: 'convertToAssets', args: [shares],
            })) as bigint)
          : 0n;
        if (alive) {
          setPool({
            assets: assets as bigint,
            supplyRate: (reserve as { currentLiquidityRate: bigint }).currentLiquidityRate,
            shares: shares as bigint,
            redeemable,
          });
        }
      } catch (e) {
        console.error('monad lend', e);
      }
    })();
    return () => { alive = false; };
  }, [address, tick]);

  const amt = useMemo(() => {
    try {
      return amount ? parseUnits(amount, USDC_DECIMALS) : 0n;
    } catch {
      return 0n;
    }
  }, [amount]);

  const max = tab === 'supply' ? (proto?.usdc ?? 0n) : (pool?.redeemable ?? 0n);

  async function submit() {
    if (!address) return;
    setBusy(true);
    try {
      if (tab === 'supply') {
        setStatus('Approving…');
        await ensureAllowance(address, TOKENS.USDC, ADDR.pool, amt);
        setStatus('Supplying…');
        await send(address, ADDR.pool, lendingPoolAbi, 'deposit', [amt, address]);
      } else {
        setStatus('Withdrawing…');
        await send(address, ADDR.pool, lendingPoolAbi, 'withdraw', [amt, address, address]);
      }
      setStatus('Done');
      setAmount('');
      bumpTick();
    } catch (e: unknown) {
      setStatus(errorText(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <section className="px-6 md:px-24 pt-10 md:pt-14 pb-8">
        <div className="max-w-[1400px] mx-auto">
          <h1 className="mt-3 text-[34px] md:text-[44px] leading-[1.05] text-fg font-semibold">
            Lend USDC
            <br />
            against tokenized stocks
          </h1>
          <p className="mt-4 max-w-[640px] text-[15px] text-fg-muted">
            Supply USDC to the Arrow lending pool, the market Agama borrows from. Every borrower is
            overcollateralized by a tokenized stock or by Agama vault shares pledged in the pool, priced by
            Chainlink Data Streams, and liquidations are absorbed by a stability pool rather than by a thin
            DEX. The USDC Earn borrows here goes into the Agama private-credit vault, and the agents turn
            its yield into more stock.
          </p>

          <div className="mt-7 flex flex-wrap gap-8">
            <Stat label="Supply APR" value={rayPct(pool?.supplyRate)} sub="Paid by borrowers" />
            <Stat label="Pool size" value={usd(pool?.assets)} sub="USDC supplied" />
            <Stat label="Your supply" value={usd(pool?.redeemable)} sub="Redeemable now" />
          </div>
        </div>
      </section>

      <section className="vault-panel relative z-10 rounded-t-[20px] px-6 md:px-24 pt-10 md:pt-14 pb-24">
        <div className="max-w-[1400px] mx-auto grid gap-5 lg:grid-cols-[1fr_1fr] items-start">
          <div className="rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
            <div className="flex items-center gap-1 rounded-full bg-[#254839]/[0.06] p-1 w-fit">
              {(['supply', 'withdraw'] as const).map((t) => (
                <button
                  key={t}
                  onClick={() => { setTab(t); setAmount(''); }}
                  className={
                    t === tab
                      ? 'rounded-full bg-[#254839] px-4 py-1.5 text-[13px] font-medium text-[#fdf8ed] capitalize'
                      : 'rounded-full px-4 py-1.5 text-[13px] text-fg-muted hover:text-fg capitalize'
                  }
                >
                  {t}
                </button>
              ))}
            </div>

            <div className="mt-4 rounded-2xl border border-[#254839]/12 bg-white/60 p-4">
              <div className="flex items-center justify-between text-[12px] text-fg-muted">
                <span>{tab === 'supply' ? 'Supply' : 'Withdraw'}</span>
                <button onClick={() => setAmount(formatUnits(max, USDC_DECIMALS))} className="hover:text-fg">
                  {tab === 'supply' ? 'Wallet' : 'Supplied'} {Number(formatUnits(max, USDC_DECIMALS)).toFixed(2)} · Max
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
                <span className="shrink-0 rounded-full bg-[#254839]/[0.06] px-3 py-1.5 text-[14px] font-medium text-fg">USDC</span>
              </div>
            </div>

            <button
              onClick={address ? submit : () => connect()}
              disabled={busy || (!!address && (amt === 0n || amt > max))}
              className="mt-4 w-full rounded-full bg-[#254839] px-5 py-3.5 text-[15px] font-medium text-[#fdf8ed] transition-colors hover:bg-[#1F3D31] disabled:opacity-45"
            >
              {!address ? 'Connect Wallet' : busy ? status || 'Working…' : tab === 'supply' ? 'Supply USDC' : 'Withdraw USDC'}
            </button>
            {status && !busy && <p className="mt-2 text-[12px] text-fg-muted">{status}</p>}
          </div>

          <div className="rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
            <h2 className="text-[17px] font-semibold text-fg">What backs your USDC</h2>
            <dl className="mt-4 space-y-2 text-[13px]">
              <Row label="Collateral" value="Nine xStocks, XAUt0, vault shares" />
              <Row label="Price" value="Chainlink Data Streams, verified on chain by Chainlink's Verifier" />
              <Row label="Liquidation" value="Partial, absorbed by the stability pool" />
              <Row label="Keeper" value="A Chainlink CRE workflow: prices, protection and the agents, every minute" />
              <Row label="Always open" value="Priced in every session Chainlink streams: regular, extended and overnight" />
            </dl>
            <p className="mt-4 rounded-2xl border border-[#254839]/12 bg-white/60 p-4 text-[13px] text-fg-muted">
              A borrower is never liquidated on the first dip: under a health factor of 1.15 anyone can
              soft deleverage them, which spends the yield buffer before it ever touches the stock.
            </p>
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
    <div className="flex items-center justify-between gap-6">
      <dt className="shrink-0 text-fg-muted">{label}</dt>
      <dd className="text-right text-fg">{value}</dd>
    </div>
  );
}

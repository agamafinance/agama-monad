'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';
import { formatUnits, type Address } from 'viem';

import { TokenIcon } from '@/components/icons/TokenIcon';
import { ADAPTERS, ADDR, EXPLORER, RAY, STOCK_DECIMALS, STOCKS, TOKENS, USDG_DECIMALS } from '@/lib/monad/config';
import { accountAbi, amplifyRouterAbi, earnRouterAbi, lendingPoolAbi, stockOracleAbi } from '@/lib/monad/generated/abis';
import {
  atLiveRate, baseTokens, erc20Abi, pub, useTick, useMonadProtocol,
  type AmplifyPosition, type RouterPosition,
} from '@/lib/monad/useMonad';
import { useMonadWallet } from '@/lib/monad/WalletProvider';

const usd = (v: bigint) =>
  `$${Number(formatUnits(v, USDG_DECIMALS)).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const qty = (v: bigint, dp = 2) => Number(formatUnits(v, STOCK_DECIMALS)).toFixed(dp);

const ZERO = '0x0000000000000000000000000000000000000000';

interface StockRow {
  key: string;
  symbol: string;
  name: string;
  /// Held: in the wallet plus deposited as collateral. It is one holding.
  amount: bigint;
  value: bigint;
  deposited: bigint;
  debt: bigint;
  hf: bigint;
}

export default function MonadPortfolioPage() {
  const { address, connect } = useMonadWallet();
  const [tick] = useTick();
  const proto = useMonadProtocol(address, tick);

  const [stocks, setStocks] = useState<StockRow[]>([]);
  const [amp, setAmp] = useState<AmplifyPosition | null>(null);
  const [supplied, setSupplied] = useState(0n);
  const [buffer, setBuffer] = useState(0n);
  // The page paints once, with everything on it. Filling it in as each read
  // lands is how it came to appear in pieces, a row at a time.
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    if (!address) { setStocks([]); setAmp(null); setSupplied(0n); setBuffer(0n); setLoaded(false); return; }
    let alive = true;
    (async () => {
      try {
        const base = await baseTokens();
        // Everything that depends on nothing, in one go. viem batches the reads
        // issued in the same tick into a single Multicall3 call, so this whole
        // block is one round trip: awaiting them one after the other is what
        // made the page arrive in pieces.
        const [positions, feeds, wrapped, held, amp0, poolShares] = await Promise.all([
          Promise.all(STOCKS.map((st) => pub.readContract({
            address: ADDR.earnRouter, abi: earnRouterAbi, functionName: 'position',
            args: [address, ADAPTERS[st.key]],
          }) as Promise<RouterPosition>)),
          Promise.all(STOCKS.map((st) => pub.readContract({
            address: ADDR.oracle, abi: stockOracleAbi, functionName: 'feed', args: [st.ticker],
          }) as Promise<{ price: bigint }>)),
          Promise.all(STOCKS.map((st) => pub.readContract({
            address: TOKENS[st.wrapper], abi: erc20Abi, functionName: 'balanceOf', args: [address],
          }) as Promise<bigint>)),
          Promise.all(STOCKS.map((st) => pub.readContract({
            address: base[st.key], abi: erc20Abi, functionName: 'balanceOf', args: [address],
          }) as Promise<bigint>)),
          pub.readContract({
            address: ADDR.amplifyRouter, abi: amplifyRouterAbi, functionName: 'position', args: [address],
          }) as Promise<AmplifyPosition>,
          pub.readContract({
            address: ADDR.pool, abi: erc20Abi, functionName: 'balanceOf', args: [address],
          }) as Promise<bigint>,
        ]);
        // The Agama account is one per wallet, so its vault buffer is counted
        // once, not once per stock, and at the rate it would be redeemed at
        // rather than the capped rate Arrow lends against.
        const acct = positions.find((p) => p.account !== ZERO)?.account;
        // Second and last round trip: the reads that needed an answer above.
        const [inBase, buf, lent, a] = await Promise.all([
          Promise.all(STOCKS.map((st, i) => {
            const shares = positions[i].collateral + wrapped[i];
            return shares === 0n ? Promise.resolve(0n) : pub.readContract({
              address: TOKENS[st.wrapper], abi: erc20Abi, functionName: 'convertToAssets', args: [shares],
            }).catch(() => shares) as Promise<bigint>;
          })),
          acct ? pub.readContract({
            address: acct, abi: accountAbi, functionName: 'redeemableUsdg',
          }).catch(() => 0n) as Promise<bigint> : Promise.resolve(0n),
          poolShares > 0n ? pub.readContract({
            address: ADDR.pool, abi: lendingPoolAbi, functionName: 'convertToAssets', args: [poolShares],
          }) as Promise<bigint> : Promise.resolve(0n),
          atLiveRate(amp0),
        ]);
        // One holding, wherever it sits: pledged as collateral, wrapped in the
        // wallet, or in the base token OKX sends. Said and priced in the base
        // token, the one the app names.
        const rows = STOCKS.map((st, i) => {
          const amount = inBase[i] + held[i];
          return {
            key: st.key, symbol: st.base, name: st.name,
            amount, value: (amount * feeds[i].price) / 10n ** 30n,
            deposited: positions[i].collateral, debt: positions[i].debt, hf: positions[i].healthFactorRay,
          };
        });
        if (alive) {
          setStocks(rows.filter((r) => r.amount > 0n || r.debt > 0n));
          setAmp(a.exposure > 0n ? a : null);
          // A rounding of pool shares survives a full withdrawal; a row that
          // says 0.00 is noise, not a position.
          setSupplied(lent > 10_000n ? lent : 0n);
          setBuffer(buf);
          setLoaded(true);
        }
      } catch (e) {
        console.error('monad portfolio', e);
      }
    })();
    return () => { alive = false; };
  }, [address, tick]);

  const wallet = proto?.usdg ?? 0n;
  // The USDG row comes from another hook, so wait for that one too rather than
  // paint a wallet of zero next to real positions.
  const ready = loaded && !!proto;
  // What the wallet would be worth if everything were unwound right now: the
  // stock at the oracle, plus the vault buffer behind it, less what is owed.
  const netWorth =
    wallet + supplied + buffer + (amp?.equity ?? 0n)
    + stocks.reduce((t, r) => t + r.value - r.debt, 0n);

  return (
    <section className="px-6 md:px-24 pt-10 md:pt-14 pb-24">
      <div className="max-w-[1400px] mx-auto">
        <h1 className="mt-2 text-[34px] text-fg font-semibold">Portfolio</h1>

        {!address ? (
          <div className="mt-8 rounded-2xl bg-[#fdfaf1] p-8 text-center shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
            <p className="text-[15px] text-fg-muted">Connect your wallet to view your positions.</p>
            <button
              type="button"
              onClick={() => connect()}
              className="mt-4 h-11 rounded-full bg-[#254839] px-6 text-[14px] font-medium text-[#fdf8ed] hover:bg-[#1F3D31]"
            >
              Connect Wallet
            </button>
          </div>
        ) : (
          <>
            <div className="mt-6 rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
              <div className="text-[12px] uppercase tracking-wider text-fg-muted">Net worth</div>
              <div className="text-[34px] font-semibold tabular-nums text-fg">
                {ready ? usd(netWorth) : <span className="text-fg-muted/40">$0.00</span>}
              </div>
              <a
                href={`${EXPLORER}/address/${address}`}
                target="_blank"
                rel="noreferrer"
                className="mt-1 block break-all text-[12px] text-fg-muted underline-offset-2 hover:text-fg hover:underline"
              >
                {address}
              </a>
            </div>

            <div className={`mt-4 space-y-3 transition-opacity duration-200 ${ready ? 'opacity-100' : 'opacity-0'}`}>
              {stocks.map((r) => (
                <Row
                  key={r.key}
                  icon={r.symbol}
                  title={r.symbol}
                  name={`${r.name} · ${
                    r.debt > 0n
                      ? `${usd(r.debt)} borrowed`
                      : r.deposited > 0n ? 'deposited, nothing borrowed' : 'in your wallet'
                  }`}
                  amount={qty(r.amount)}
                  sub={
                    r.debt > 0n
                      ? `${usd(r.value)} · health ${(Number(r.hf) / Number(RAY)).toFixed(2)}`
                      : usd(r.value)
                  }
                  href="/monad"
                />
              ))}

              {amp && (
                <Row
                  icon="sagUSD"
                  title="Amplify"
                  name={`Vault loop at ${(Number(amp.leverageBps) / 10_000).toFixed(2)}x`}
                  amount={Number(formatUnits(amp.exposure, USDG_DECIMALS)).toFixed(2)}
                  sub={`${usd(amp.equity)} of equity · ${usd(amp.debt)} borrowed`}
                  href="/monad/amplify"
                />
              )}

              {supplied > 0n && (
                <Row
                  icon="USDG"
                  title="Supplied to Arrow"
                  name="Lending USDG against tokenized stocks"
                  amount={Number(formatUnits(supplied, USDG_DECIMALS)).toFixed(2)}
                  sub={`${usd(supplied)} · redeemable now`}
                  href="/monad/lend"
                />
              )}

              <Row
                icon="USDG"
                title="USDG"
                name="Global Dollar"
                amount={Number(formatUnits(wallet, USDG_DECIMALS)).toFixed(2)}
                sub={usd(wallet)}
                href="/monad/faucet"
              />

              {stocks.length === 0 && !amp && supplied === 0n && wallet === 0n && (
                <p className="rounded-2xl bg-[#fdfaf1] px-5 py-4 text-[14px] text-fg-muted shadow-[0_1px_3px_rgba(20,50,35,0.06)]">
                  No position yet. Deposit a stock on{' '}
                  <Link href="/monad" className="underline underline-offset-2">Earn</Link> and the agents take it
                  from there, or lend USDG on{' '}
                  <Link href="/monad/lend" className="underline underline-offset-2">Arrow</Link>.
                </p>
              )}
            </div>
          </>
        )}
      </div>
    </section>
  );
}

function Row({
  icon, title, name, amount, sub, href,
}: { icon: string; title: string; name: string; amount: string; sub?: string; href: string }) {
  return (
    <Link
      href={href}
      className="flex items-center gap-4 rounded-2xl bg-[#fdfaf1] px-5 py-4 shadow-[0_1px_3px_rgba(20,50,35,0.06)]"
    >
      <TokenIcon symbol={icon} size={36} />
      <div>
        <div className="text-[15px] font-medium text-fg">{title}</div>
        <div className="text-[13px] text-fg-muted">{name}</div>
      </div>
      <div className="ml-auto text-right">
        <div className="text-[16px] font-semibold tabular-nums text-fg">{amount}</div>
        {sub && <div className="text-[12px] text-fg-muted">{sub}</div>}
      </div>
    </Link>
  );
}

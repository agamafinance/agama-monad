'use client';

import { useState } from 'react';
import Link from 'next/link';
import { ArrowRight, Check, Copy, ExternalLink } from 'lucide-react';

import { TokenIcon } from '@/components/icons/TokenIcon';
import { formatUnits, parseUnits, type Address } from 'viem';

import { asset, OKB_FAUCET, STOCKS, TOKENS, USDG_DECIMALS } from '@/lib/monad/config';
import { erc20Abi, errorText, faucetAll, pub, useTick, useMonadProtocol } from '@/lib/monad/useMonad';
import { useMonadWallet } from '@/lib/monad/WalletProvider';

const USDG_AMOUNT = parseUnits('5000', USDG_DECIMALS);
const STOCK_AMOUNT = parseUnits('10', 18);

export default function MonadFaucetPage() {
  const { address, connect } = useMonadWallet();
  const [tick, bumpTick] = useTick();
  const proto = useMonadProtocol(address, tick);
  const [copied, setCopied] = useState(false);
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState('');

  const copyAddress = async () => {
    if (!address) return;
    await navigator.clipboard.writeText(address);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  /// One transaction for the lot: Multicall3 makes every `faucet(you, amount)`
  /// call in a single batch, so the wallet asks to sign once instead of five
  /// times. The stocks come in the base form, the one an OKX withdrawal
  /// delivers and the only one the app ever asks for.
  async function mintEverything() {
    if (!address) return;
    setBusy(true);
    setNote('');
    try {
      const bases = await Promise.all(STOCKS.map((s) => pub.readContract({
        address: TOKENS[s.wrapper], abi: erc20Abi, functionName: 'asset',
      }) as Promise<Address>));
      await faucetAll(address, [
        { token: TOKENS.USDG, amount: USDG_AMOUNT },
        ...bases.map((token) => ({ token, amount: STOCK_AMOUNT })),
      ]);
      setNote('5,000 USDG and 10 of each stock, in one transaction');
      bumpTick();
    } catch (e: unknown) {
      setNote(errorText(e));
    } finally {
      setBusy(false);
    }
  }

  const usdg = proto?.usdg;

  return (
    <>
      <section className="px-6 md:px-24 pt-10 md:pt-14 pb-8">
        <div className="max-w-[1400px] mx-auto relative">
          <div aria-hidden className="pointer-events-none absolute right-4 top-2 z-20 hidden lg:block">
            <img
              src={asset('/monad.svg')}
              alt=""
              className="h-[170px] w-[170px] drop-shadow-[0_18px_30px_rgba(20,50,35,0.25)]"
            />
          </div>

          <h1 className="mt-3 text-[34px] md:text-[44px] leading-[1.05] text-fg font-semibold">Get testnet funds</h1>
          <p className="mt-4 max-w-[640px] text-[15px] text-fg-muted">
            Grab OKB for gas, then take the stand-in USDG and xStocks in one transaction. Monad Testnet
            carries neither, so these are ours: same decimals, same ERC-4626 wrapper shape, and the Arrow
            and Agama contracts they meet are the real ones.
          </p>

          <div className="mt-7 flex flex-wrap gap-8">
            <Stat label="Network" value="Monad Testnet" sub="Chain 1952" />
            <Stat label="Asset" value="xStocks" sub="TSLAx, NVDAx, SPYx, AAPLx" />
            <Stat
              label="USDG"
              value={!address || usdg === undefined
                ? '—'
                : Number(formatUnits(usdg, USDG_DECIMALS)).toFixed(2)}
              sub={address ? 'Global Dollar, in your wallet' : 'Global Dollar'}
            />
          </div>
        </div>
      </section>

      <section className="vault-panel relative z-10 rounded-t-[20px] px-6 md:px-24 pt-10 md:pt-14 pb-24">
        <div className="max-w-[1400px] mx-auto space-y-3">
          <h2 className="mb-2 text-[13px] uppercase tracking-wider text-fg-muted">Get funded</h2>

          <StepRow
            icon={<img src={asset('/monad.svg')} alt="" className="h-10 w-10 shrink-0 rounded-full" />}
            title="OKB for gas"
            blurb="Monad Testnet transactions are paid in OKB. Grab some from the OKX faucet, it is the one thing here nobody can mint for you."
          >
            <FaucetLink href={OKB_FAUCET} label="Open OKB faucet" />
          </StepRow>

          <StepRow
            icon={
              <div className="flex shrink-0 -space-x-2">
                <TokenIcon symbol="USDG" size={40} />
                <TokenIcon symbol="TSLAx" size={40} />
                <TokenIcon symbol="NVDAx" size={40} />
              </div>
            }
            title="USDG and the four stocks"
            blurb="5,000 USDG, and 10 each of TSLAx, NVDAx, SPYx and AAPLx in the form an OKX withdrawal delivers. One transaction, one signature."
          >
            <MintButton
              onClick={address ? mintEverything : () => connect()}
              busy={busy}
              label={address ? 'Get the test tokens' : 'Connect a wallet'}
              disabled={busy}
            />
          </StepRow>

          <p className="pt-2 text-[12px] text-fg-muted">
            {!address ? (
              <button type="button" onClick={() => connect()} className="underline hover:text-fg">
                Connect a wallet
              </button>
            ) : (
              'Paste your address into the OKB faucet above.'
            )}
            <button
              type="button"
              onClick={copyAddress}
              disabled={!address}
              className="ml-3 inline-flex items-center gap-1.5 rounded-full bg-[#254839]/[0.08] px-3 py-1 text-[12px] text-[#254839] hover:bg-[#254839]/[0.16] disabled:opacity-40"
            >
              {copied ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
              {copied ? 'Copied!' : 'Copy address'}
            </button>
            {note && <span className="ml-3">{note}</span>}
          </p>

          <Link
            href="/monad"
                  className="group mt-6 flex items-center gap-4 rounded-2xl bg-[#254839] px-5 py-4"
          >
            <img src="/agama-logo-circle.svg" alt="" className="h-10 w-10" />
            <div>
              <div className="text-[15px] font-medium text-[#fdf8ed]">Funded? Deposit your stock</div>
              <div className="text-[13px] text-[#fdf8ed]/70">Borrow against it and let the agents grow it</div>
            </div>
            <ArrowRight className="ml-auto h-5 w-5 text-[#fdf8ed]/80 transition-transform group-hover:translate-x-0.5" />
          </Link>
        </div>
      </section>
    </>
  );
}

function FaucetLink({ href, label }: { href: string; label: string }) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer"
      className="inline-flex h-11 items-center gap-1.5 whitespace-nowrap rounded-full bg-[#254839] px-6 text-[14px] font-medium text-[#fdf8ed] hover:bg-[#1F3D31]"
    >
      {label} <ExternalLink className="h-3.5 w-3.5" />
    </a>
  );
}

function MintButton({
  onClick, busy, label, disabled,
}: { onClick: () => void; busy: boolean; label: string; disabled?: boolean }) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className="inline-flex h-11 items-center gap-1.5 whitespace-nowrap rounded-full bg-[#254839] px-6 text-[14px] font-medium text-[#fdf8ed] hover:bg-[#1F3D31] disabled:opacity-45"
    >
      {busy ? 'Minting…' : label}
    </button>
  );
}

function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div>
      <div className="text-[12px] uppercase tracking-wider text-fg-muted">{label}</div>
      <div className="text-[26px] font-semibold tabular-nums text-fg">{value}</div>
      {sub && <div className="text-[12px] text-fg-muted">{sub}</div>}
    </div>
  );
}

function StepRow({
  title, blurb, children, icon,
}: { title: string; blurb: string; children: React.ReactNode; icon?: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-4 rounded-2xl bg-[#fdfaf1] px-5 py-4 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)] md:flex-row md:items-center">
      {icon}
      <div className="min-w-0">
        <div className="text-[15px] font-medium text-fg">{title}</div>
        <div className="text-[13px] text-fg-muted">{blurb}</div>
      </div>
      <div className="shrink-0 md:ml-auto">{children}</div>
    </div>
  );
}

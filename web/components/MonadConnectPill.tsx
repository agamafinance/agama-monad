'use client';

import { useEffect, useRef, useState } from 'react';

import AnimatedButton from './AnimatedButton';
import {
  askWalletsToAnnounce, availableWallets, errorText, WALLETS, type FoundWallet,
} from '@/lib/monad/useMonad';
import { useMonadWallet } from '@/lib/monad/WalletProvider';

// Same pill as the other networks: dark-green AnimatedButton, address shortened
// and centred inside a "Connect Wallet" footprint so the navbar never reflows.
const pillProps = {
  variant: 'primary' as const,
  fillColor: 'rgba(20, 39, 31, 0.55)',
  borderColor: 'rgba(20, 39, 31, 0.55)',
  textRestColor: '#fff',
  textHoverColor: '#fff',
  className: 'h-10 px-[17px] text-[14px] font-medium whitespace-nowrap',
};

const shorten = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

export function MonadConnectPill() {
  const { address, connect, disconnect } = useMonadWallet();
  const [open, setOpen] = useState(false);
  const [found, setFound] = useState<FoundWallet[]>([]);
  const [trouble, setTrouble] = useState('');
  const [working, setWorking] = useState('');
  const box = useRef<HTMLDivElement>(null);

  // An announcement can land at any time, so the list is rebuilt on every one
  // of them rather than read once. Reading it once was how a wallet that
  // finished injecting late ended up offered as "Install".
  useEffect(() => {
    if (!open) return;
    const refresh = () => setFound(availableWallets());
    refresh();
    askWalletsToAnnounce();
    window.addEventListener('eip6963:announceProvider', refresh);
    const late = setTimeout(refresh, 400);
    const onAway = (e: MouseEvent) => {
      if (box.current && !box.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('mousedown', onAway);
    return () => {
      window.removeEventListener('eip6963:announceProvider', refresh);
      clearTimeout(late);
      document.removeEventListener('mousedown', onAway);
    };
  }, [open]);

  if (address) {
    return (
      <AnimatedButton {...pillProps} onClick={disconnect}>
        <span className="relative inline-block" title={`${address} (click to sign out)`} data-address={address}>
          <span className="invisible whitespace-nowrap">Connect Wallet</span>
          <span className="absolute inset-0 flex items-center justify-center whitespace-nowrap">
            {shorten(address)}
          </span>
        </span>
      </AnimatedButton>
    );
  }

  const pick = async (id: string) => {
    setTrouble('');
    setWorking(id);
    try {
      await connect(id);
      setOpen(false);
    } catch (e: unknown) {
      // Whatever the wallet said. Closing the menu on a failure would leave
      // someone clicking a button that looks like it did nothing.
      setTrouble(errorText(e));
    } finally {
      setWorking('');
    }
  };

  return (
    <div className="relative" ref={box}>
      <AnimatedButton {...pillProps} onClick={() => setOpen((v) => !v)}>
        Connect Wallet
      </AnimatedButton>

      {open && (
        <div className="absolute right-0 top-[calc(100%+8px)] z-50 w-[264px] overflow-hidden rounded-2xl bg-[#fdfaf1] p-1.5 shadow-[0_1px_3px_rgba(20,50,35,0.10),0_16px_40px_rgba(20,50,35,0.22)]">
          {/* A passkey first: no extension, no seed phrase, an account made
              from the device's own lock. Mera derives a plain address from
              it, so the rest of the app cannot tell the difference. */}
          <button
            type="button"
            onClick={() => pick('passkey')}
            disabled={!!working}
            className="flex w-full items-center gap-3 rounded-xl bg-[#254839] px-3 py-2.5 text-left text-[14px] font-medium text-[#fdf8ed] hover:bg-[#1F3D31] disabled:opacity-60"
          >
            <PasskeyMark />
            <span className="flex flex-col">
              <span>{working === 'passkey' ? 'Waiting for the passkey…' : 'Continue with a passkey'}</span>
              <span className="text-[11px] font-normal text-[#fdf8ed]/70">Yours if you have one, a new one if not</span>
            </span>
          </button>
          <div className="mx-3 my-1.5 border-t border-[#254839]/10" />
          {found.map((w) => (
            <button
              key={w.id}
              type="button"
              onClick={() => pick(w.id)}
              className="flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left text-[14px] text-fg hover:bg-[#254839]/[0.07]"
            >
              <WalletMark wallet={w} />
              {w.name}
            </button>
          ))}

          {/* Only when none of them is here. Offering to install a wallet
              beside two the user already has is noise in a chooser: they
              came to pick one, not to shop. With nothing installed the
              download page is the only way out, so then it is the menu. */}
          {found.length === 0 && WALLETS.map((k) => (
            <a
              key={k.id}
              href={k.download}
              target="_blank"
              rel="noreferrer"
              className="flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-[14px] text-fg-muted hover:bg-[#254839]/[0.07]"
            >
              <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-[#254839]/[0.35] text-[11px] font-semibold text-[#fdf8ed]">
                {k.name[0]}
              </span>
              {k.name}
              <span className="ml-auto text-[12px]">Install</span>
            </a>
          ))}

          {trouble && <p className="px-3 py-2 text-[12px] text-fg-muted">{trouble}</p>}
        </div>
      )}
    </div>
  );
}

function PasskeyMark() {
  return (
    <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-[#fdf8ed]/15">
      <svg viewBox="0 0 24 24" className="h-4 w-4" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden>
        <circle cx="9" cy="8" r="4" />
        <path d="M2 21c0-3.3 3.1-6 7-6 1.3 0 2.5.3 3.5.8" />
        <circle cx="18" cy="14" r="2.5" />
        <path d="M18 16.5V22l1.5-1.2M18 19.5h1.5" />
      </svg>
    </span>
  );
}

/// The icon the wallet announced over EIP-6963, so there is no wallet artwork
/// of ours to keep up to date. A wallet found the legacy way announced none.
function WalletMark({ wallet }: { wallet: FoundWallet }) {
  if (!wallet.icon) {
    return (
      <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-[#254839] text-[11px] font-semibold text-[#fdf8ed]">
        {wallet.name[0]}
      </span>
    );
  }
  // eslint-disable-next-line @next/next/no-img-element
  return <img src={wallet.icon} alt="" className="h-6 w-6 shrink-0 rounded-full" />;
}

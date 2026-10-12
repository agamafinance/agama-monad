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

const shorten = (a: string) => `${a.slice(0, 4)}…${a.slice(-4)}`;

export function MonadConnectPill() {
  const { address, connect, disconnect } = useMonadWallet();
  const [open, setOpen] = useState(false);
  const [found, setFound] = useState<FoundWallet[]>([]);
  const [trouble, setTrouble] = useState('');
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
        <span className="relative inline-block">
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
    try {
      await connect(id);
      setOpen(false);
    } catch (e: unknown) {
      // Whatever the wallet said. Closing the menu on a failure would leave
      // someone clicking a button that looks like it did nothing.
      setTrouble(errorText(e));
    }
  };

  return (
    <div className="relative" ref={box}>
      <AnimatedButton {...pillProps} onClick={() => setOpen((v) => !v)}>
        Connect Wallet
      </AnimatedButton>

      {open && (
        <div className="absolute right-0 top-[calc(100%+8px)] z-50 w-[232px] overflow-hidden rounded-2xl bg-[#fdfaf1] p-1.5 shadow-[0_1px_3px_rgba(20,50,35,0.10),0_16px_40px_rgba(20,50,35,0.22)]">
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

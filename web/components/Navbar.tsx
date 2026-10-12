'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import clsx from 'clsx';
import { MonadConnectPill } from './MonadConnectPill';
import { useNetwork, type Platform } from '@/lib/network/NetworkContext';

const NAV: Record<Platform, { href: string; label: string }[]> = {
  monad: [
    { href: '/monad/portfolio', label: 'Portfolio' },
    { href: '/monad', label: 'Earn' },
    { href: '/monad/amplify', label: 'Amplify' },
    { href: '/monad/faucet', label: 'Faucet' },
  ],
};

// The official Monad mark, cropped out of their wordmark, served from this
// deployment's own origin: app.agama.finance proxies this app and has every
// other network's logo but not this one.
const XLAYER_MARK = `${process.env.NEXT_PUBLIC_ASSET_PREFIX ?? ''}/monad.svg`;

const NETWORKS: { id: Platform; label: string; logo: string; home: string }[] = [
  { id: 'monad', label: 'Monad', logo: XLAYER_MARK, home: '/monad' },
];

export function Navbar() {
  const pathname = usePathname() || '/';
  const { platform } = useNetwork();

  const current = NETWORKS.find((n) => n.id === platform) ?? NETWORKS[0];

  const navItems = (mobile: boolean) =>
    NAV[platform].map((item) => {
      // "Earn" (/monad) owns every Monad page no more specific tab claims,
      // so /monad/lend keeps the Earn pill active rather than none of them.
      const siblings = NAV[platform].filter((n) => n.href !== item.href).map((n) => n.href);
      const active =
        pathname === item.href ||
        (item.href !== '/' &&
          pathname.startsWith(item.href) &&
          !siblings.some((s) => s.length > item.href.length && pathname.startsWith(s)));
      return (
        <Link
          key={item.href}
          href={item.href}
          // Explicit, because the default only warms what a route renders on
          // the server, and every page here is a client component with no
          // loading boundary: there was nothing to warm, so the first click on
          // each tab paid for the payload. Four links, fetched once on idle.
          prefetch
          className={clsx(
            'flex items-center rounded-full text-white transition-colors',
            mobile ? 'h-7 flex-1 justify-center text-[13px]' : 'h-10 px-4 md:px-5 text-[14px]',
            active ? 'pill-active' : 'hover:bg-white/10'
          )}
        >
          {item.label}
        </Link>
      );
    });

  return (
    <>
      <header className="relative z-50 bg-[#1F3D31] md:bg-transparent px-4 md:pl-6 md:pr-[24px] py-3 md:py-[11px]">
        <div className="flex items-center justify-between gap-3">
          <Link href={current.home} className="flex items-center group shrink-0">
            <img src="/agama-logo-beige.svg" alt="Agama" className="h-[32.8px] w-auto" />
          </Link>

          {/* Desktop nav (inline) */}
          <nav className="hidden md:flex pill-bar items-center gap-1 rounded-full h-[47px] -mb-[3px] px-[3.5px] mr-auto ml-10">
            {navItems(false)}
          </nav>

          {/* Right cluster */}
          <div className="flex items-center gap-2 shrink-0">
            {/* One network here, so this is a badge rather than a chooser. */}
            <span
              className="pill-outline flex h-10 items-center gap-2 rounded-full pl-[6px] pr-3 text-[13px] text-white"
              title={`${current.label} Testnet`}
            >
              <span className="flex h-[20px] w-[20px] shrink-0 items-center justify-center overflow-hidden rounded-full">
                <img src={current.logo} alt={current.label} className="h-[20px] w-[20px] object-cover" />
              </span>
              <span className="hidden sm:inline">{current.label}</span>
            </span>

            <MonadConnectPill />
          </div>
        </div>
      </header>

      {/* Mobile nav */}
      <div className="md:hidden bg-[#fdf8ed] px-2 pt-3 pb-3 border-b border-[#254839]/20">
        <nav className="pill-bar flex items-center gap-1 rounded-full h-[32px] px-[3.5px]">
          {navItems(true)}
        </nav>
      </div>
    </>
  );
}

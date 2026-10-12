'use client';

import { useEffect, useState } from 'react';

import { DEPLOYED } from '@/lib/monad/config';
import type { Market } from '@/lib/monad/useMonad';

/// Where the prices come from, and how fresh the newest one is.
export function PriceBadge({ markets }: { markets: Market[] }) {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(id);
  }, []);
  const last = markets.reduce((t, m) => Math.max(t, m.observedAt), 0);
  const age = Math.max(0, now - last);
  const ageText = last === 0 ? 'none yet' : age < 90 ? `${age} s ago` : `${Math.round(age / 60)} min ago`;
  return (
    <div className="mt-3 flex flex-wrap items-center gap-x-2 gap-y-1 text-[12px] text-fg-muted" data-testid="price-badge">
      <span className="inline-flex items-center gap-1.5 rounded-full bg-[#375BD2]/10 px-2.5 py-1 font-medium text-[#375BD2]">
        <svg viewBox="0 0 24 24" className="h-3.5 w-3.5" aria-hidden>
          <path fill="currentColor" d="M12 1.5 3 6.75v10.5L12 22.5l9-5.25V6.75L12 1.5Zm0 4.6 4.95 2.9v5.8L12 17.9l-4.95-2.9V9L12 6.1Z" />
        </svg>
        Chainlink Data Streams
      </span>
      <span>
        Every price is a signed Chainlink Data Streams report, verified on chain by Chainlink&apos;s Verifier. Last price {ageText}.
      </span>
    </div>
  );
}

/// Shown in place of the numbers until the contracts are on this chain.
export function NotDeployed() {
  if (DEPLOYED) return null;
  return (
    <div className="rounded-2xl border border-[#b4571f]/30 bg-[#b4571f]/[0.06] p-4 text-[13px] text-[#b4571f]">
      The contracts are being deployed to Monad Testnet. This page fills in as soon as they are live.
    </div>
  );
}

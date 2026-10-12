'use client';

import { ReactNode } from 'react';

import { NetworkProvider } from '@/lib/network/NetworkContext';
import { MonadWalletProvider } from '@/lib/monad/WalletProvider';

/// One network, one provider. The pages talk to a browser wallet through a
/// plain EIP-1193 hook, or sign with a passkey account, so this is the whole
/// of it.
export function Providers({ children }: { children: ReactNode }) {
  return (
    <NetworkProvider>
      <MonadWalletProvider>{children}</MonadWalletProvider>
    </NetworkProvider>
  );
}

'use client';

import { ReactNode } from 'react';

import { NetworkProvider } from '@/lib/network/NetworkContext';
import { MonadWalletProvider } from '@/lib/monad/WalletProvider';

/// One network, one provider.
///
/// The app this is forked from stacks a wallet provider per platform, and with
/// them wagmi, RainbowKit and the Stellar, Sui, Starknet and Solana SDKs. None
/// of that is reachable from a deployment that serves only /monad, and all of
/// it was in the bundle every page had to parse before it could ask the chain
/// anything. The Monad pages talk to the wallet through a plain EIP-1193
/// hook, so this is the whole of it.
export function Providers({ children }: { children: ReactNode }) {
  return (
    <NetworkProvider>
      <MonadWalletProvider>{children}</MonadWalletProvider>
    </NetworkProvider>
  );
}

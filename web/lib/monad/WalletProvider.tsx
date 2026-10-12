'use client';

import { createContext, useContext, ReactNode } from 'react';
import { useWallet } from './useMonad';

const Ctx = createContext<ReturnType<typeof useWallet>>({
  address: undefined,
  connect: async () => {},
  disconnect: () => {},
});

export function MonadWalletProvider({ children }: { children: ReactNode }) {
  const wallet = useWallet();
  return <Ctx.Provider value={wallet}>{children}</Ctx.Provider>;
}

export function useMonadWallet() {
  return useContext(Ctx);
}

'use client';

import {SignoChat} from '@/components/SignoChat';
import {useWallet} from '@/lib/monad/useMonad';

/// Every Monad page gets the agent in the corner. It sits in a layout rather
/// than in each page so it survives navigation between Earn, Amplify and the
/// rest without losing the thread.
export default function MonadLayout({children}: {children: React.ReactNode}) {
  const {address} = useWallet();
  return (
    <>
      {children}
      <SignoChat wallet={address ?? undefined} />
    </>
  );
}

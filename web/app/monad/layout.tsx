import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Monad',
  description: 'Deposit a tokenized stock, get more of it back. Agama on Monad Testnet.',
};

export default function MonadLayout({ children }: { children: React.ReactNode }) {
  return children;
}

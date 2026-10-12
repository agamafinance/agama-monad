import type { Metadata } from 'next';
import { Inter } from 'next/font/google';
import './globals.css';
import { AppFrame } from '@/components/AppFrame';
import { Providers } from './providers';

const inter = Inter({
  subsets: ['latin'],
  variable: '--font-sans',
  display: 'swap',
});

export const metadata: Metadata = {
  title: {
    default: 'Agama',
    template: 'Agama | %s',
  },
  description: 'Earn yield backed by RWA.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`dark ${inter.variable}`} suppressHydrationWarning>
      <body className="min-h-screen bg-bg text-fg antialiased" suppressHydrationWarning>
        <Providers>
          <AppFrame>{children}</AppFrame>
        </Providers>
      </body>
    </html>
  );
}

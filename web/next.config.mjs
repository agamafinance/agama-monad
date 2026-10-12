import {dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));

// This deployment is reached through app.agama.finance/monad, which rewrites
// that path here. The pages live at /monad so the rewrite is a straight pass
// through, but the assets would land on app.agama.finance/_next and collide
// with the product app's own bundle. Serving them from this deployment's own
// origin keeps the two apart.
const assetPrefix = process.env.NEXT_PUBLIC_ASSET_PREFIX || undefined;

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Inherited from the app this is forked from: dapp-kit and @mysten ship
  // mismatched types across packages, and blocking the build on them would
  // stop work that has nothing to do with them.
  eslint: { ignoreDuringBuilds: true },
  typescript: { ignoreBuildErrors: true },
  assetPrefix,
  // The Foundry repo sits one level up and has its own lockfile; pin the root
  // so Next does not walk up and pick it.
  outputFileTracingRoot: root,
  turbopack: { root },
  // Every page here is a client component that reads the chain on mount, so the
  // server payload is the same shell whichever tab you are on. Without this the
  // router treats it as dynamic, throws it away immediately and refetches it on
  // every tab click, which is a round trip in front of a page that has all of
  // its real data still to fetch.
  experimental: { staleTimes: { dynamic: 120, static: 300 } },
  async headers() {
    return [
      {
        // Needed so the Google zkLogin (Enoki) popup can post its result back.
        source: '/:path*',
        headers: [{ key: 'Cross-Origin-Opener-Policy', value: 'same-origin-allow-popups' }],
      },
    ];
  },
};

export default nextConfig;

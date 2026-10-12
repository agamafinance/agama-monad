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
  assetPrefix,
  // The Foundry repo sits one level up and has its own lockfile; pin the root
  // so Next does not walk up and pick it.
  outputFileTracingRoot: root,
  turbopack: { root },
  // Every page here is a client component that reads the chain on mount, so the
  // server payload is the same shell whichever tab you are on. Without this the
  // router treats it as dynamic and refetches it on every tab click.
  experimental: { staleTimes: { dynamic: 120, static: 300 } },
};

export default nextConfig;

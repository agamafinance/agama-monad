import clsx from 'clsx';

type Tranche = 'Senior' | 'Junior';
type TokenInfo = {
  bg: string;
  fg: string;
  symbol: string;
  logo?: string;
  /// Issuer mark applied as a mask on a Senior-or-Junior styled disc
  /// (Senior = solid dark-green w/ cream mark; Junior = cream w/ dark-green
  /// outline + dark-green mark). Mirrors the agYLD/sagYLD inversion pattern.
  issuerMask?: string;
  tranche?: Tranche;
};

const TOKENS: Record<string, TokenInfo> = {
  // Agama V3 — protocol tokens
  USDr: { bg: '#254839', fg: '#fdf8ed', symbol: '₿' },
  agYLD: { bg: '#2E5944', fg: '#fdf8ed', symbol: 'Y', logo: '/logos/agyld.svg' },
  sagYLD: { bg: '#1F3D31', fg: '#fdf8ed', symbol: 'S', logo: '/logos/sagyld.svg' },
  // Agama on Stellar — coin marks from the Stellar grant banner artwork
  agUSD: { bg: '#3c4c42', fg: '#ece6db', symbol: 'a', logo: '/logos/agusd.svg' },
  sagUSD: { bg: '#ece6db', fg: '#3c4c42', symbol: 's', logo: '/logos/sagusd.svg' },
  // Confidential variants (Sui) — reuse the agUSD/sagUSD coin marks.
  cagUSD: { bg: '#3c4c42', fg: '#ece6db', symbol: 'c', logo: '/logos/agusd.svg' },
  csagUSD: { bg: '#ece6db', fg: '#3c4c42', symbol: 'c', logo: '/logos/sagusd.svg' },
  Kiro: { bg: '#C97A40', fg: '#fdf8ed', symbol: 'K' },
  // Senior tranches — solid green disc with cream issuer mark
  sRESOLV: { bg: '#3D6B52', fg: '#fdf8ed', symbol: 'R', issuerMask: '/logos/resolvvi.png', tranche: 'Senior' },
  sDIGCAP: { bg: '#3D6B52', fg: '#fdf8ed', symbol: 'D', issuerMask: '/logos/digcap.png', tranche: 'Senior' },
  sCONDO: { bg: '#3D6B52', fg: '#fdf8ed', symbol: 'C', issuerMask: '/logos/sectorcondo.svg', tranche: 'Senior' },
  // Junior tranches — cream disc with green outline + green issuer mark
  jRESOLV: { bg: '#A85A2C', fg: '#fdf8ed', symbol: 'R', issuerMask: '/logos/resolvvi.png', tranche: 'Junior' },
  jDIGCAP: { bg: '#A85A2C', fg: '#fdf8ed', symbol: 'D', issuerMask: '/logos/digcap.png', tranche: 'Junior' },
  jCONDO: { bg: '#A85A2C', fg: '#fdf8ed', symbol: 'C', issuerMask: '/logos/sectorcondo.svg', tranche: 'Junior' },
  XRP: { bg: '#254839', fg: '#FFFFFF', symbol: 'X', logo: '/logos/xrp.svg' },
  // Official Circle USDC mark
  USDC: { bg: '#2775CA', fg: '#FFFFFF', symbol: '$', logo: '/logos/usdc.svg' },
  USDT: { bg: '#26A17B', fg: '#FFFFFF', symbol: 'T' },
  ETH: { bg: '#627EEA', fg: '#FFFFFF', symbol: 'E' },
  BTC: { bg: '#F7931A', fg: '#FFFFFF', symbol: 'B' },
  // Monad: USDG and the Backed xStock wrappers. Cream discs with a dark
  // green letter, the same inversion the vault share tokens use, so a stock
  // reads as collateral rather than as another stablecoin.
  USDG: { bg: '#314012', fg: '#C7E36C', symbol: 'G', logo: '/usdg.svg' },
  // Backed's own xStock marks. Two of the four are only published as PNG,
  // which is why the set is mixed.
  TSLAx: { bg: '#E82127', fg: '#fff', symbol: 'T', logo: '/stocks/tslax.svg' },
  NVDAx: { bg: '#76B900', fg: '#fff', symbol: 'N', logo: '/stocks/nvdax.png' },
  SPYx: { bg: '#1B1BFF', fg: '#fff', symbol: 'S', logo: '/stocks/spyx.png' },
  AAPLx: { bg: '#000000', fg: '#fff', symbol: 'A', logo: '/stocks/aaplx.svg' },
  wTSLAx: { bg: '#E82127', fg: '#fff', symbol: 'T', logo: '/stocks/tslax.svg' },
  wNVDAx: { bg: '#76B900', fg: '#fff', symbol: 'N', logo: '/stocks/nvdax.png' },
  wSPYx: { bg: '#1B1BFF', fg: '#fff', symbol: 'S', logo: '/stocks/spyx.png' },
  wAAPLx: { bg: '#000000', fg: '#fff', symbol: 'A', logo: '/stocks/aaplx.svg' },
};

const FALLBACK = { bg: '#3B4256', fg: '#FFFFFF', symbol: '?' };

export function TokenIcon({
  symbol,
  size = 24,
  className,
}: {
  symbol: string;
  size?: number;
  className?: string;
}) {
  const info = TOKENS[symbol] ?? {
    ...FALLBACK,
    symbol: symbol.slice(0, 1).toUpperCase(),
  };
  if (info.logo) {
    return (
      <img
        // From this deployment's own origin: app.agama.finance proxies this app
        // and serves its own public/ on that path, so a logo only we have would
        // 404 there.
        src={`${process.env.NEXT_PUBLIC_ASSET_PREFIX ?? ''}${info.logo}`}
        alt={symbol}
        width={size}
        height={size}
        className={clsx('rounded-full select-none block', className)}
        style={{ width: size, height: size, flexShrink: 0 }}
      />
    );
  }
  if (info.issuerMask && info.tranche) {
    const isSenior = info.tranche === 'Senior';
    const discBg = isSenior ? '#254839' : '#fdf8ed';
    const markColor = isSenior ? '#fdf8ed' : '#254839';
    const border = isSenior ? 'none' : '1.5px solid #254839';
    return (
      <span
        className={clsx('inline-flex items-center justify-center rounded-full select-none', className)}
        style={{ width: size, height: size, background: discBg, border }}
        aria-label={symbol}
      >
        <span
          aria-hidden
          style={{
            width: size * 0.62,
            height: size * 0.62,
            backgroundColor: markColor,
            WebkitMaskImage: `url(${info.issuerMask})`,
            WebkitMaskRepeat: 'no-repeat',
            WebkitMaskSize: 'contain',
            WebkitMaskPosition: 'center',
            maskImage: `url(${info.issuerMask})`,
            maskRepeat: 'no-repeat',
            maskSize: 'contain',
            maskPosition: 'center',
            display: 'block',
          }}
        />
      </span>
    );
  }
  return (
    <span
      className={clsx(
        'inline-flex items-center justify-center rounded-full ring-1 ring-[#254839]/15 select-none',
        className
      )}
      style={{
        width: size,
        height: size,
        background: info.bg,
        color: info.fg,
        fontSize: size * 0.5,
        fontWeight: 700,
        lineHeight: 1,
      }}
      aria-label={symbol}
    >
      {info.symbol}
    </span>
  );
}

export function TokenStack({
  symbols,
  more,
  size = 24,
}: {
  symbols: string[];
  more?: number;
  size?: number;
}) {
  return (
    <div className="flex items-center">
      <div className="flex -space-x-2">
        {symbols.map((s, i) => (
          <span key={`${s}-${i}`} style={{ zIndex: symbols.length - i }}>
            <TokenIcon symbol={s} size={size} className="ring-2 ring-[#fdf8ed]" />
          </span>
        ))}
      </div>
      {typeof more === 'number' && more > 0 && (
        <span className="ml-2 text-[13px] text-fg-muted">+{more}</span>
      )}
    </div>
  );
}

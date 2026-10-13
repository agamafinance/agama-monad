import clsx from 'clsx';

type TokenInfo = {
  bg: string;
  fg: string;
  symbol: string;
  logo?: string;
};

const TOKENS: Record<string, TokenInfo> = {
  // Agama's vault tokens
  agUSD: { bg: '#3c4c42', fg: '#ece6db', symbol: 'a', logo: '/logos/agusd.svg' },
  sagUSD: { bg: '#ece6db', fg: '#3c4c42', symbol: 's', logo: '/logos/sagusd.svg' },
  // Official Circle USDC mark
  USDC: { bg: '#2775CA', fg: '#FFFFFF', symbol: '$', logo: '/logos/usdc.svg' },
  MON: { bg: '#836EF9', fg: '#FFFFFF', symbol: 'M' },
  // The xStocks' own marks. Two of the four are only published as PNG, which
  // is why the set is mixed.
  TSLAx: { bg: '#E82127', fg: '#fff', symbol: 'T', logo: '/stocks/tslax.svg' },
  NVDAx: { bg: '#76B900', fg: '#fff', symbol: 'N', logo: '/stocks/nvdax.png' },
  SPYx: { bg: '#1B1BFF', fg: '#fff', symbol: 'S', logo: '/stocks/spyx.png' },
  AAPLx: { bg: '#000000', fg: '#fff', symbol: 'A', logo: '/stocks/aaplx.svg' },
  wTSLAx: { bg: '#E82127', fg: '#fff', symbol: 'T', logo: '/stocks/tslax.svg' },
  wNVDAx: { bg: '#76B900', fg: '#fff', symbol: 'N', logo: '/stocks/nvdax.png' },
  wSPYx: { bg: '#1B1BFF', fg: '#fff', symbol: 'S', logo: '/stocks/spyx.png' },
  wAAPLx: { bg: '#000000', fg: '#fff', symbol: 'A', logo: '/stocks/aaplx.svg' },
  QQQx: { bg: '#0e7a5f', fg: '#fff', symbol: 'Q', logo: '/stocks/qqqx.png' },
  GOOGLx: { bg: '#4285F4', fg: '#fff', symbol: 'G', logo: '/stocks/googlx.png' },
  MSFTx: { bg: '#737373', fg: '#fff', symbol: 'M', logo: '/stocks/msftx.png' },
  AMZNx: { bg: '#FF9900', fg: '#000', symbol: 'A', logo: '/stocks/amznx.png' },
  METAx: { bg: '#0866FF', fg: '#fff', symbol: 'M', logo: '/stocks/metax.png' },
  wQQQx: { bg: '#0e7a5f', fg: '#fff', symbol: 'Q', logo: '/stocks/qqqx.png' },
  wGOOGLx: { bg: '#4285F4', fg: '#fff', symbol: 'G', logo: '/stocks/googlx.png' },
  wMSFTx: { bg: '#737373', fg: '#fff', symbol: 'M', logo: '/stocks/msftx.png' },
  wAMZNx: { bg: '#FF9900', fg: '#000', symbol: 'A', logo: '/stocks/amznx.png' },
  wMETAx: { bg: '#0866FF', fg: '#fff', symbol: 'M', logo: '/stocks/metax.png' },
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

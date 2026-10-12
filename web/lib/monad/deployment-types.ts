import type {Address} from "viem";

export type StockKey = "TSLA" | "NVDA" | "SPY" | "AAPL";

export type Deployment = {
  chainId: number;
  contracts: {
    oracle: Address;
    agUSD: Address;
    sagUSD: Address;
    queue: Address;
    pool: Address;
    stabilityPool: Address;
    factory: Address;
    earnRouter: Address;
    amplifyRouter: Address;
    /// Buy and Earn zap (OKX DEX aggregator on 196, stand-in router on testnet).
    zapRouter?: Address;
    /// Testnet only: stand-in DEX priced at the Agama oracle, allowlisted in the zap.
    testDexRouter?: Address;
  };
  adapters: Record<StockKey | "VAULT", Address>;
  tokens: {
    USDG: Address;
    wTSLAx: Address;
    wNVDAx: Address;
    wSPYx: Address;
    wAAPLx: Address;
  };
  admin: Address;
  keeper: Address;
  deployedAtBlock: number;
};

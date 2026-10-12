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
    /// Buy and Earn zap; also holds the swap allowlist the accounts read.
    zapRouter?: Address;
    /// Stand-in venue priced at the Agama oracle, allowlisted in the zap.
    testDexRouter?: Address;
    /// Chainlink Data Streams VerifierProxy the oracle verifies reports against.
    verifierProxy?: Address;
    creReceiver?: Address;
    /// Kuru venue (buys and sells the xStock on its order book), when deployed.
    kuruVenue?: Address;
  };
  adapters: Record<StockKey | "VAULT", Address>;
  tokens: {
    USDC: Address;
    wTSLAx: Address;
    wNVDAx: Address;
    wSPYx: Address;
    wAAPLx: Address;
  };
  /// Kuru order book per stock (base xStock / USDC), when deployed.
  kuru?: Partial<Record<StockKey, Address>>;
  admin: Address;
  keeper: Address;
  deployedAtBlock: number;
};

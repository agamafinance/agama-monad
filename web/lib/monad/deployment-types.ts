import type {Address} from "viem";

export type StockKey = "TSLA" | "NVDA" | "SPY" | "AAPL" | "QQQ" | "GOOGL" | "MSFT" | "AMZN" | "META" | "XAUT";

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
    /// Where the Chainlink CRE workflow's reports land (prices and agent jobs).
    creReceiver?: Address;
    creReceiverV1?: Address;
    /// What the CRE workflow reads: the oracles and the jobs due, in one call.
    creLens?: Address;
    /// Gold's own oracle: Chainlink's XAU/USD stream, schema v3.
    goldOracle?: Address;
    /// Each wallet's journal, sealed by its passkey, stored as ciphertext.
    journal?: Address;
  };
  adapters: Record<StockKey | "VAULT", Address>;
  /// Markets replaced when the terms were raised, kept so old positions close.
  adaptersRetired?: Partial<Record<StockKey, Address>>;
  tokens: {
    USDC: Address;
    wTSLAx: Address;
    wNVDAx: Address;
    wSPYx: Address;
    wAAPLx: Address;
    wQQQx: Address;
    wGOOGLx: Address;
    wMSFTx: Address;
    wAMZNx: Address;
    wMETAx: Address;
    wXAUt0: Address;
  };
  /// Kuru: the venue every swap goes through, and the order book per stock
  /// (base xStock / USDC), when deployed.
  kuru?: Partial<Record<StockKey | 'venue' | 'router' | 'marginAccount', Address>>;
  admin: Address;
  keeper: Address;
  deployedAtBlock: number;
};

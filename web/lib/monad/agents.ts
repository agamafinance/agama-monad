'use client';

import { useEffect, useState } from 'react';
import { parseAbi, type Address } from 'viem';

import { pub } from './useMonad';

/// What an account emits when an agent acts on it. Nobody has to be watching:
/// the keeper Agama runs is one caller among others, and the events are the
/// only thing the page needs to show that the position is being looked after.
const agentEvents = parseAbi([
  'event Rebalanced(address indexed caller, address indexed adapter, int256 debtDelta, uint256 ltvBpsAfter)',
  'event CompoundedIntoStock(address indexed caller, address indexed adapter, uint256 usdgSpent, uint256 stockAdded)',
]);

export interface AgentAction {
  kind: 'rebalance' | 'compound';
  /// USDG of debt moved, signed, for a rebalance.
  debtDelta?: bigint;
  /// Stock added to the collateral, for a compound.
  stockAdded?: bigint;
  at: number; // unix seconds
}

/// The public RPC caps `eth_getLogs` at a 100 block range, so this is a recent
/// window, not a history. That is enough for the only question the page asks:
/// is something still happening on this position?
export function useLastAgentAction(account: Address | undefined, tick: number) {
  const [action, setAction] = useState<AgentAction>();

  useEffect(() => {
    if (!account) { setAction(undefined); return; }
    let alive = true;
    (async () => {
      try {
        const head = await pub.getBlockNumber();
        const fromBlock = head > 99n ? head - 99n : 0n;
        const logs = await pub.getLogs({ address: account, events: agentEvents, fromBlock, toBlock: head });
        const last = logs[logs.length - 1];
        if (!last || !alive) return;
        const block = await pub.getBlock({ blockNumber: last.blockNumber });
        const args = last.args as { debtDelta?: bigint; stockAdded?: bigint };
        if (alive) {
          setAction({
            kind: last.eventName === 'Rebalanced' ? 'rebalance' : 'compound',
            debtDelta: args.debtDelta,
            stockAdded: args.stockAdded,
            at: Number(block.timestamp),
          });
        }
      } catch {
        /* a pruned window or a rate limited node just means no action to show */
      }
    })();
    return () => { alive = false; };
  }, [account, tick]);

  return action;
}

/// The chain keeps no record of what a user originally deposited, and the log
/// window is too short to reconstruct it, so the browser remembers it. It is
/// only used to say how much stock the agents have added since.
export function useDepositBaseline(key: string, current: bigint | undefined) {
  const [baseline, setBaseline] = useState<bigint>(0n);

  useEffect(() => {
    try {
      const raw = window.localStorage.getItem(key);
      setBaseline(raw ? BigInt(raw) : 0n);
    } catch {
      setBaseline(0n);
    }
  }, [key]);

  useEffect(() => {
    if (baseline !== 0n || current === undefined || current === 0n) return;
    try {
      window.localStorage.setItem(key, current.toString());
    } catch {
      /* private mode: the growth line just stays hidden */
    }
    setBaseline(current);
  }, [baseline, current, key]);

  const grown = current !== undefined && baseline > 0n && current > baseline ? current - baseline : undefined;
  return { baseline, grown, reset: () => { try { window.localStorage.removeItem(key); } catch {} setBaseline(0n); } };
}

export function ago(at: number): string {
  const s = Math.max(0, Math.floor(Date.now() / 1000) - at);
  if (s < 60) return `${s}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)} min ago`;
  return `${Math.floor(s / 3600)} h ago`;
}

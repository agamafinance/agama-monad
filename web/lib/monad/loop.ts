'use client';

import { encodeFunctionData, type Address, type Hex } from 'viem';

import { ADDR, BPS, KURU_VENUE } from './config';
import { type Market } from './useMonad';

/// One hop of a stock loop, the shape `AgamaAccount.Hop` takes.
export interface Hop {
  amount: bigint;
  swapTarget: Address;
  swapSpender: Address;
  swapData: Hex;
  minOut: bigint;
}

const testDexAbi = [
  {
    type: 'function', name: 'swap', stateMutability: 'nonpayable',
    inputs: [{ type: 'address' }, { type: 'uint256' }, { type: 'uint256' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function', name: 'sell', stateMutability: 'nonpayable',
    inputs: [{ type: 'address' }, { type: 'uint256' }, { type: 'uint256' }],
    outputs: [{ type: 'uint256' }],
  },
] as const;

const kuruVenueAbi = [
  {
    type: 'function', name: 'buy', stateMutability: 'nonpayable',
    inputs: [{ type: 'address' }, { type: 'uint256' }, { type: 'uint256' }],
    outputs: [{ type: 'uint256' }],
  },
  {
    type: 'function', name: 'sell', stateMutability: 'nonpayable',
    inputs: [{ type: 'address' }, { type: 'uint256' }, { type: 'uint256' }],
    outputs: [{ type: 'uint256' }],
  },
] as const;

const ONE = 10n ** 18n;
/// What the venue keeps (Kuru's book spread around the oracle, or the
/// stand-in's fee), and the slack a quote is sized with.
const VENUE_SPREAD_BPS = 30n;
const SLIPPAGE_BPS = 200n;

/// One swap through the deployment's venue: a market order on Kuru's book via
/// KuruVenue when the deployment has it, else the oracle-priced stand-in.
/// `amount` is USDC on a buy, wrapped stock on a sell.
export function swapCall(m: Market, side: 'buy' | 'sell', amount: bigint): { target: Address; data: Hex; minOut: bigint } {
  const out = side === 'buy'
    ? (amount * ONE) / m.wrapperPrice
    : (amount * m.wrapperPrice) / ONE;
  const minOut = (out * (BPS - SLIPPAGE_BPS)) / BPS;
  if (KURU_VENUE) {
    return {
      target: KURU_VENUE,
      data: encodeFunctionData({ abi: kuruVenueAbi, functionName: side, args: [m.wrapper, amount, minOut] }),
      minOut,
    };
  }
  const dex = ADDR.testDexRouter;
  if (!dex) throw new Error('No swap venue in this deployment');
  return {
    target: dex,
    data: encodeFunctionData({
      abi: testDexAbi,
      functionName: side === 'buy' ? 'swap' : 'sell',
      args: [m.wrapper, amount, m.wrapperPrice],
    }),
    minOut,
  };
}

/// A quote for one exact amount. A loop needs one per hop, because a market
/// order is sized for one exact input.
async function quote(m: Market, side: 'buy' | 'sell', amount: bigint): Promise<Hop> {
  const { target, data, minOut } = swapCall(m, side, amount);
  return { amount, swapTarget: target, swapSpender: target, swapData: data, minOut };
}

export interface OpenPlan {
  hops: Hop[];
  /// USDC the loop will owe, and the stock it should end up holding.
  debt: bigint;
  shares: bigint;
  leverageBps: bigint;
}

/// Borrow to the market's ceiling, buy stock, deposit, repeat.
///
/// The series converges because the ceiling is an LTV: at 30% every pass adds
/// 30% of what the last one added, and the limit is 1 / (1 - LTV). Asking for
/// more than that simply runs out of room, which is the honest behaviour and
/// what the contract does too.
export async function planOpen(
  m: Market,
  shares: bigint,
  leverage: number,
  minBorrow: bigint,
): Promise<OpenPlan> {
  const start = (shares * m.wrapperPrice) / ONE;
  const target = (start * BigInt(Math.round(leverage * 10_000))) / BPS;

  const hops: Hop[] = [];
  let value = start;
  let debt = 0n;
  let held = shares;

  // Six is past the point where another pass is worth its gas: at a 30% LTV
  // the sixth adds under a thousandth of the position.
  while (hops.length < 6 && value < target) {
    const room = (value * m.maxLtv) / BPS;
    if (room <= debt) break;
    // Half a percent under the ceiling, so interest accruing between the quote
    // and the block does not turn the borrow into a revert.
    let borrow = ((room - debt) * 995n) / 1000n;
    const need = target - value;
    if (borrow > need) borrow = need;
    if (borrow < minBorrow) break;

    hops.push(await quote(m, 'buy', borrow));
    const bought = (borrow * (BPS - VENUE_SPREAD_BPS)) / BPS;
    value += bought;
    held += (bought * ONE) / m.wrapperPrice;
    debt += borrow;
  }

  return {
    hops,
    debt,
    shares: held,
    leverageBps: start === 0n ? 0n : (value * BPS) / start,
  };
}

/// Withdraw what the health factor allows, sell it, repay, repeat.
///
/// Each hop asks the pool to release collateral, and the pool only agrees while
/// the position stays healthy, so an unwind can never break it on the way out.
export async function planClose(
  m: Market,
  shares: bigint,
  debt: bigint,
  liqThresholdBps: bigint,
): Promise<Hop[]> {
  const hops: Hop[] = [];
  let value = (shares * m.wrapperPrice) / ONE;
  let left = debt;

  while (hops.length < 6 && left > 0n) {
    const floorValue = (left * BPS + liqThresholdBps - 1n) / liqThresholdBps;
    if (value <= floorValue) break;
    const room = ((value - floorValue) * 99n) / 100n;
    // A little over the debt, so the last hop clears it rather than leaving
    // dust that the close would then have to find a buffer for.
    const need = (left * 1005n) / 1000n;
    const sellValue = room < need ? room : need;
    const sellShares = (sellValue * ONE) / m.wrapperPrice;
    if (sellShares === 0n) break;

    hops.push(await quote(m, 'sell', sellShares));
    const got = (sellValue * (BPS - VENUE_SPREAD_BPS)) / BPS;
    left = got >= left ? 0n : left - got;
    value -= sellValue;
  }

  return hops;
}

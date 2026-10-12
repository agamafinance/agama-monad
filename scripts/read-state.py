#!/usr/bin/env python3
"""Whole public surface of a deployment, eth_call only: no key, no writes.

    python3 scripts/read-state.py [1952|1961|196]
"""
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHAIN = sys.argv[1] if len(sys.argv) > 1 else "1952"
RPC = {"1952": "https://testrpc.xlayer.tech/terigon",
       "1961": "http://127.0.0.1:8545",
       "196": "https://rpc.xlayer.tech"}[CHAIN]
D = json.load(open(os.path.join(ROOT, "deployments", f"{CHAIN}.json")))
C, A, T = D["contracts"], D["adapters"], D["tokens"]
TICKERS = ["TSLA", "NVDA", "SPY", "AAPL"]


def call(to, sig, *args):
    r = subprocess.run(["cast", "call", to, sig, *args, "--rpc-url", RPC], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""


def num(to, sig, *args):
    out = call(to, sig, *args)
    return int(out.split()[0]) if out else 0


def tup(to, sig, *args):
    out = call(to, sig, *args)
    return [p.split()[0] for p in out.strip("()").split(", ")] if out else []


def b32(t):
    return "0x" + t.encode().hex().ljust(64, "0")


def usd(x, dec=6):
    return f"{x / 10 ** dec:,.2f}"


debt_token = call(C["pool"], "DEBT_TOKEN()(address)")
reserve = tup(C["pool"], "getReserveState()((uint256,uint256,uint256,uint256,uint256))")

print(f"Arrow lending pool   {C['pool']}")
print(f"   supplied          {usd(num(C['pool'], 'totalAssets()(uint256)'))} USDG")
print(f"   borrowed          {usd(num(debt_token, 'totalSupply()(uint256)'))} USDG")
print(f"   idle              {usd(num(T['USDG'], 'balanceOf(address)(uint256)', C['pool']))} USDG")
if reserve:
    print(f"   borrow APR        {int(reserve[3]) / 1e25:.2f}%")
    print(f"   supply APR        {int(reserve[2]) / 1e25:.2f}%")

sp_assets = num(C["stabilityPool"], "totalAssets()(uint256)")
print(f"\nStability pool       {C['stabilityPool']}")
print(f"   staked            {usd(num(C['pool'], 'convertToAssets(uint256)(uint256)', str(sp_assets)))} USDG")
print(f"   seized inventory  {usd(num(C['stabilityPool'], 'inventoryValue()(uint256)'))} USDG at the buyer discount")

print(f"\nAgama vault          {C['sagUSD']}")
print(f"   vault assets      {usd(num(C['sagUSD'], 'totalAssets()(uint256)'), 18)} agUSD")
print(f"   instant reserve   {usd(num(C['queue'], 'usdcReserve()(uint256)'))} USDG")

print(f"\nOracle               {C['oracle']}")
now = int(time.time())
for t in TICKERS:
    f = tup(C["oracle"], "feed(bytes32)((uint128,uint64,bool,bool))", b32(t))
    rs = call(C["oracle"], "redStoneFeedId(bytes32)(bytes32)", b32(t))
    src = "keeper relay" if not rs or int(rs, 16) == 0 else "RedStone signed"
    if f:
        print(f"   {t:<5} {int(f[0]) / 1e18:>9,.2f} USD   open={f[2]:<5} age={now - int(f[1]):>5}s   ({src})")

print("\nMarkets")
for t in TICKERS:
    a = A[t]
    print(f"   {t:<5} LTV {num(a, 'MAX_LTV()(uint256)') / 100:>4.0f}%  LT {num(a, 'LIQUIDATION_THRESHOLD()(uint256)') / 100:>4.0f}%"
          f"  bonus {num(a, 'LIQUIDATION_BONUS()(uint256)') / 100:>3.0f}%  borrows {call(a, 'borrowAllowed()(bool)')}")
va = A["VAULT"]
print(f"   VAULT LTV {num(va, 'MAX_LTV()(uint256)') / 100:>4.0f}%  LT {num(va, 'LIQUIDATION_THRESHOLD()(uint256)') / 100:>4.0f}%"
      f"  haircut {num(va, 'HAIRCUT_BPS()(uint256)') / 100:.0f}%  borrows {call(va, 'borrowAllowed()(bool)')}")

print(f"\nAgama accounts       {C['factory']}")
print(f"   accounts opened   {num(C['factory'], 'accountCount()(uint256)')}")
print(f"   zap router        {C['zapRouter']}")
print(f"   vault may never fund the pool: forbidden = {call(C['queue'], 'forbiddenVault()(address)')}")

#!/usr/bin/env python3
"""Quotes the four Agama stock markets on Kuru around the oracle price.

The books are new and nobody else trades test xStocks, so somebody has to
give them depth or Amplify has nothing to buy from. This is that somebody:
each tick it reads the price the protocol itself uses (our Chainlink-verified
oracle), and when the mid has moved, or the resting orders were taken, it
cancels its orders and quotes LEVELS bids and asks around it, in one
`batchUpdate` per market. Funds sit in Kuru's MarginAccount; when they run low
the test tokens are minted from their faucets and deposited.

A testnet market maker, not a strategy: it never holds a view, only the mid.

  python3 scripts/kuru_mm.py          one tick (ONCE semantics, for the keeper)
  LOOP=1 python3 scripts/kuru_mm.py   every INTERVAL seconds

The keeper can also `import kuru_mm; kuru_mm.tick()`.

Env:
  RPC_URL (default https://testnet-rpc.monad.xyz), DEPLOYMENT (deployments/10143.json),
  MM_KEY (else KEEPER_KEY), LEVEL_USD (default 5000, the size of each level),
  REQUOTE_BPS (default 10), INTERVAL (default 30), STATE (default .keys/kuru_mm.json).
"""
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RPC = os.environ.get("RPC_URL", "https://testnet-rpc.monad.xyz")
KEY = os.environ.get("MM_KEY") or os.environ.get("KEEPER_KEY", "")
DEPLOYMENT = os.environ.get("DEPLOYMENT", os.path.join(ROOT, "deployments", "10143.json"))
STATE = os.environ.get("STATE", os.path.join(ROOT, ".keys", "kuru_mm.json"))
LEVEL_USD = float(os.environ.get("LEVEL_USD", "5000"))
REQUOTE_BPS = float(os.environ.get("REQUOTE_BPS", "10"))
INTERVAL = int(os.environ.get("INTERVAL", "30"))

TICKERS = ["TSLA", "NVDA", "SPY", "AAPL"]
# Distance of each level from the mid, in basis points: a tight top of book,
# then depth further out for a loop's larger hops.
LEVELS_BPS = [5, 15, 30, 60]

# The book's grid, as listed by src/venues/KuruListing.sol.
PRICE_PRECISION = 10**4
TICK_SIZE = 100
SIZE_PRECISION = 10**4

USDC_FAUCET_CAP = 10_000 * 10**6
STOCK_FAUCET_CAP = 100 * 10**18

# Monad charges the gas limit, not the gas used.
GAS_QUOTE = 4_000_000
GAS_SMALL = 300_000


def log(*a):
    print(datetime.now(timezone.utc).strftime("%H:%M:%S"), "[kuru]", *a, flush=True)


TRANSIENT = ("error sending request", "timed out", "connection reset", "502", "503", "504", "EOF", "429")


def cast(*args):
    for attempt in range(5):
        out = subprocess.run(["cast", *args], capture_output=True, text=True)
        if out.returncode == 0:
            return out.stdout.strip()
        if attempt < 4 and any(t in out.stderr for t in TRANSIENT):
            time.sleep(2 + 2 * attempt)
            continue
        raise RuntimeError(out.stderr.strip().splitlines()[-1] if out.stderr else "cast failed")


def call(to, sig, *args):
    return cast("call", to, sig, *args, "--rpc-url", RPC)


def send(to, sig, *args, gas=GAS_SMALL):
    if not KEY:
        raise RuntimeError("MM_KEY (or KEEPER_KEY) not set")
    for attempt in range(6):
        try:
            out = cast("send", to, sig, *args, "--private-key", KEY, "--gas-limit", str(gas),
                       "--json", "--rpc-url", RPC)
            receipt = json.loads(out)
            if receipt.get("status") not in ("0x1", 1, "1"):
                raise RuntimeError(f"reverted: {receipt.get('transactionHash')}")
            return receipt
        except RuntimeError as e:
            if attempt < 5 and ("nonce too low" in str(e) or "already known" in str(e)):
                time.sleep(2)
                continue
            raise


def first_int(s):
    return int(s.split()[0])


def me():
    return cast("wallet", "address", "--private-key", KEY)


def load_state():
    try:
        return json.load(open(STATE))
    except (OSError, ValueError):
        return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    json.dump(state, open(STATE, "w"), indent=2)


def oracle_mid(oracle, ticker):
    """The price the protocol uses, in USDC with 6 decimals, or None when stale."""
    try:
        out = call(oracle, "getPrice(bytes32)(uint256,uint256,bool)", cast("format-bytes32-string", ticker))
    except RuntimeError as e:
        log(ticker, "no fresh oracle price, left as quoted:", e)
        return None
    return first_int(out.splitlines()[0]) // 10**12


def book_price(usdc6, up=False):
    """A 6-decimal USDC price on the book's grid, rounded away from the mid."""
    p = usdc6 * PRICE_PRECISION // 10**6
    down = p - p % TICK_SIZE
    return down + TICK_SIZE if up and down < p else down


def live_orders(market, ids, owner):
    """The ids still resting: filled ones are deleted, their owner reads zero."""
    alive = []
    for i in ids:
        out = call(market, "s_orders(uint40)(address,uint96,uint40,uint40,uint40,uint32,uint32,bool)", str(i))
        lines = out.splitlines()
        if lines[0].lower() == owner.lower() and first_int(lines[1]) > 0:
            alive.append(i)
    return alive


def ensure_margin(margin, token, owner, need, faucet_cap):
    """Top the MarginAccount up to `need`, minting from the test faucet."""
    have = first_int(call(margin, "getBalance(address,address)(uint256)", owner, token))
    if have >= need:
        return
    short = need - have
    left = short
    while left > 0:
        step = min(left, faucet_cap)
        send(token, "faucet(address,uint256)", owner, str(step))
        left -= step
    send(token, "approve(address,uint256)", margin, str(short))
    send(margin, "deposit(address,address,uint256)", owner, token, str(short), gas=GAS_SMALL)
    log("deposited", short, "of", token)


def order_ids(receipt):
    topic = cast("keccak", "OrderCreated(uint40,address,uint96,uint32,bool)")
    ids = []
    for lg in receipt.get("logs", []):
        if lg.get("topics") and lg["topics"][0].lower() == topic.lower():
            data = bytes.fromhex(lg["data"][2:])
            ids.append(int.from_bytes(data[0:32], "big"))
    return ids


def quote(ticker, market, base, usdc, margin, mid6, old_ids, owner):
    shares = LEVEL_USD / (mid6 / 1e6)
    size = max(1, int(shares * SIZE_PRECISION))
    bids, asks = [], []
    for bps in LEVELS_BPS:
        bids.append(book_price(mid6 * (10_000 - bps) // 10_000))
        asks.append(book_price(-(-mid6 * (10_000 + bps) // 10_000), up=True))

    # What resting at these levels draws: quote for the bids, base for the asks.
    usdc_need = sum(p * size // SIZE_PRECISION for p in bids) * 10**6 // PRICE_PRECISION + 10**6
    base_need = size * len(asks) * 10**18 // SIZE_PRECISION
    ensure_margin(margin, usdc, owner, usdc_need * 2, USDC_FAUCET_CAP)
    ensure_margin(margin, base, owner, base_need * 2, STOCK_FAUCET_CAP)

    arr = lambda xs: "[" + ",".join(str(x) for x in xs) + "]"
    sizes = arr([size] * len(LEVELS_BPS))
    receipt = send(market, "batchUpdate(uint32[],uint96[],uint32[],uint96[],uint40[],bool)",
                   arr(bids), sizes, arr(asks), sizes, arr(old_ids), "true", gas=GAS_QUOTE)
    ids = order_ids(receipt)
    log(f"{ticker} quoted {len(ids)} orders around {mid6 / 1e6:.2f}, "
        f"{bids[0] / PRICE_PRECISION:.2f} / {asks[0] / PRICE_PRECISION:.2f}, {receipt['transactionHash']}")
    return ids


def tick():
    d = json.load(open(DEPLOYMENT))
    kuru = d.get("kuru")
    if not kuru:
        log("no .kuru in", DEPLOYMENT, "(run script/KuruMarkets.s.sol first)")
        return
    owner = me()
    oracle = d["contracts"]["oracle"]
    usdc = d["tokens"]["USDC"]
    margin = kuru["marginAccount"]
    state = load_state()
    for ticker in TICKERS:
        market = kuru[ticker]
        try:
            mid6 = oracle_mid(oracle, ticker)
            if mid6 is None:
                continue
            s = state.get(market, {"mid": 0, "ids": []})
            alive = live_orders(market, s["ids"], owner)
            moved = s["mid"] == 0 or abs(mid6 - s["mid"]) * 10_000 > REQUOTE_BPS * s["mid"]
            if not moved and len(alive) == len(s["ids"]) and alive:
                continue
            base = call(d["tokens"][f"w{ticker}x"], "asset()(address)")
            ids = quote(ticker, market, base, usdc, margin, mid6, alive, owner)
            state[market] = {"mid": mid6, "ids": ids}
            save_state(state)
        except Exception as e:  # one market's trouble must not stop the others
            log(ticker, "failed:", e)


def main():
    if os.environ.get("LOOP"):
        while True:
            tick()
            time.sleep(INTERVAL)
    tick()


if __name__ == "__main__":
    sys.exit(main())

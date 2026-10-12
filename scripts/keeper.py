#!/usr/bin/env python3
"""Agama keeper for Monad: prices, protection, agents.

Every job is permissionless except none: the keeper holds no role the protocol
needs. Prices are signed Chainlink Data Streams reports (RWA Advanced, v11),
fetched from the testnet Data Engine and handed to `pushReports`, which has
Chainlink's VerifierProxy check the signatures before anything is stored.
Chainlink runs one stream per session (regular, extended, overnight); the
oracle believes each only for its own session, so the keeper sends the
reports of all three and the ones out of their session are simply left out.

Jobs, every INTERVAL seconds:
  prices      the latest report of each stream, when newer than the stored one
  snapshot    the vault adapter's daily NAV snapshot
  protection  liquidate under HF 1, soft-deleverage under 1.15
  agents      hold each position on its target, buy stock with the yield
  kuru        re-quote the Kuru books around the oracle (scripts/kuru_mm.py)

Env:
  RPC_URL (default https://testnet-rpc.monad.xyz), DEPLOYMENT (deployments/10143.json),
  KEEPER_KEY (any funded key), DATASTREAMS_API_KEY and DATASTREAMS_API_SECRET
  (else .keys/datastreams.env), DS_HOST (default the testnet Data Engine),
  INTERVAL (default 60), ONCE=1 for one tick, JOBS=prices,kuru,snapshot,protection,agents.
"""
import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RPC = os.environ.get("RPC_URL", "https://testnet-rpc.monad.xyz")
KEY = os.environ.get("KEEPER_KEY", "")
DEPLOYMENT = os.environ.get("DEPLOYMENT", os.path.join(ROOT, "deployments", "10143.json"))
DS_HOST = os.environ.get("DS_HOST", "https://api.testnet-dataengine.chain.link")
INTERVAL = int(os.environ.get("INTERVAL", "60"))
# A verified push costs about 0.03 MON on Monad testnet: send one when a price
# moved, the session changed, or the stored one is getting old, not every tick.
MOVE_BPS = int(os.environ.get("MOVE_BPS", "50"))
MAX_AGE = int(os.environ.get("MAX_AGE", "3000"))  # the oracle allows an hour
RUN_MINUTES = float(os.environ.get("RUN_MINUTES", "0"))  # 0 = forever

# Monad charges the gas limit, not the gas used: keep each one close to need.
GAS_PRICE_PUSH = 1_500_000     # snapshot() cap
# A push measured on a fork: 87k gas for one report, 226k for four.
GAS_PUSH_BASE = 80_000
GAS_PUSH_PER_REPORT = 60_000
GAS_AGENT = 3_000_000          # rebalance, compound (a swap through Kuru)
GAS_PROTECTION = 6_000_000     # soft deleverage and liquidation walk positions
DEFAULT_GAS = GAS_PROTECTION

TICKERS = ["TSLA", "NVDA", "SPY", "AAPL"]
STREAMS = json.load(open(os.path.join(ROOT, "scripts", "datastreams-feeds.json")))

SOFT_TRIGGER = 115 * 10**25  # 1.15 RAY
RAY = 10**27


def log(*a):
    print(datetime.now(timezone.utc).strftime("%H:%M:%S"), *a, flush=True)


TRANSIENT = ("error sending request", "timed out", "connection reset", "502", "503", "504", "EOF", "429")


def cast(*args, rpc=RPC):
    # Retry transient transport errors of public RPCs (not reverts).
    for attempt in range(5):
        out = subprocess.run(["cast", *args, "--rpc-url", rpc], capture_output=True, text=True)
        if out.returncode == 0:
            return out.stdout.strip()
        if attempt < 4 and any(t in out.stderr for t in TRANSIENT):
            time.sleep(2 + 2 * attempt)
            continue
        raise RuntimeError(out.stderr.strip().splitlines()[-1] if out.stderr else "cast failed")


def call(to, sig, *args, rpc=RPC):
    return cast("call", to, sig, *args, rpc=rpc)


def send(to, sig, *args, gas=DEFAULT_GAS, estimate=True):
    """`sig` may be a signature plus args, or a full calldata hex blob.

    Always checks the receipt: a mined-but-reverted transaction must never be
    reported as a success. Gas is set per call, since Monad bills the limit.
    """
    if not KEY:
        raise RuntimeError("KEEPER_KEY not set")
    # Estimated first: a revert costs nothing, and the limit billed is the
    # estimate plus a margin, never more than the cap for this kind of call.
    # Not for price pushes: a report observed after the last block would read
    # as from the future there, though it is fine in the block it lands in.
    if estimate:
        est = first_int(cast("estimate", to, sig, *args, "--from", keeper_address()))
        gas = min(gas, est * 13 // 10)
    for attempt in range(6):
        try:
            out = cast("send", to, sig, *args, "--private-key", KEY,
                       "--gas-limit", str(gas), "--json")
            receipt = json.loads(out)
            if receipt.get("status") not in ("0x1", 1, "1"):
                raise RuntimeError(f"reverted: {receipt.get('transactionHash')}")
            return out
        except RuntimeError as e:
            if attempt < 5 and ("nonce too low" in str(e) or "already known" in str(e)):
                time.sleep(2)
                continue
            raise


def first_int(s):
    return int(s.split()[0])


_address = None


def keeper_address():
    global _address
    if _address is None:
        _address = subprocess.run(["cast", "wallet", "address", "--private-key", KEY],
                                  capture_output=True, text=True, check=True).stdout.strip()
    return _address


def credentials():
    key = os.environ.get("DATASTREAMS_API_KEY", "")
    secret = os.environ.get("DATASTREAMS_API_SECRET", "")
    if not (key and secret):
        try:
            env = dict(l.strip().split("=", 1) for l in open(os.path.join(ROOT, ".keys", "datastreams.env"))
                       if "=" in l)
            key, secret = env.get("DATASTREAMS_API_KEY", ""), env.get("DATASTREAMS_API_SECRET", "")
        except OSError:
            pass
    return key, secret


def ds_get(path):
    key, secret = credentials()
    if not (key and secret):
        raise RuntimeError("no Data Streams credentials")
    ts = str(int(time.time() * 1000))
    body_hash = hashlib.sha256(b"").hexdigest()
    sig = hmac.new(secret.encode(), f"GET {path} {body_hash} {key} {ts}".encode(), hashlib.sha256).hexdigest()
    req = urllib.request.Request(DS_HOST + path, headers={
        "Authorization": key, "X-Authorization-Timestamp": ts, "X-Authorization-Signature-SHA256": sig,
        "User-Agent": "agama-keeper/1.0"})
    return json.load(urllib.request.urlopen(req, timeout=15))


def decode(full_hex):
    """(feedId, observedAt, marketStatus, mid) from a v11 fullReport."""
    b = bytes.fromhex(full_hex[2:] if full_hex.startswith("0x") else full_hex)
    off = int.from_bytes(b[96:128], "big")
    n = int.from_bytes(b[off:off + 32], "big")
    blob = b[off + 32:off + 32 + n]
    word = lambda i: int.from_bytes(blob[32 * i:32 * i + 32], "big")
    return "0x" + blob[:32].hex(), word(2), word(13), word(6) / 1e18


def latest_reports():
    ids = [sid for t in TICKERS for sid in STREAMS[t].values()]
    path = f"/api/v1/reports/bulk?feedIDs={','.join(ids)}&timestamp={int(time.time()) - 2}"
    return [r["fullReport"] for r in ds_get(path).get("reports", [])]


# Which marketStatus each stream is believed for (mirrors script/Deployer.sol).
SESSIONS = {"regular": (2, 5), "extended": (1, 3), "overnight": (4,)}


def tick_prices(dep):
    """Every stream's latest report that is in its own session and newer than
    what the oracle holds, in one transaction."""
    oracle = dep["contracts"]["oracle"]
    by_id = {sid.lower(): (t, kind) for t in TICKERS for kind, sid in STREAMS[t].items()}
    fresh, seen = [], {}
    for full in latest_reports():
        feed, observed, status, mid = decode(full)
        ticker, kind = by_id[feed.lower()]
        if status not in SESSIONS[kind]:
            continue
        fresh.append((ticker, observed, status, mid, full))
    # One report per ticker: the newest in-session one.
    best = {}
    for r in fresh:
        if r[0] not in best or r[1] > best[r[0]][1]:
            best[r[0]] = r
    reports, summary = [], []
    now = time.time()
    for ticker, observed, status, mid, full in best.values():
        price, stored_at, was_open = stored(oracle, ticker)
        if observed <= stored_at:
            continue
        moved = price == 0 or abs(mid * 1e18 - price) * 10_000 >= MOVE_BPS * price
        session_changed = was_open != (status in (1, 2, 3, 4))
        if not (moved or session_changed or now - stored_at >= MAX_AGE):
            continue
        reports.append(full)
        summary.append(f"{ticker} {mid:.2f} ({['?', 'pre', 'regular', 'post', 'overnight', 'closed'][status]})")
    if not reports:
        log("prices: nothing newer")
        return
    send(oracle, "pushReports(bytes[])", "[" + ",".join(reports) + "]",
         gas=GAS_PUSH_BASE + GAS_PUSH_PER_REPORT * len(reports), estimate=False)
    log("prices verified on chain:", ", ".join(summary))


def stored(oracle, ticker):
    """(price 1e18, observedAt, marketOpen) as the oracle holds them."""
    out = call(oracle, "feed(bytes32)((uint128,uint64,bool,bool))", b32(ticker))
    parts = [x.strip().split(" ")[0] for x in out.strip("()").split(",")]
    return int(parts[0]), int(parts[1]), parts[2] == "true"


def b32(ticker):
    return "0x" + ticker.encode().hex().ljust(64, "0")


def tick_protection(dep):
    factory = dep["contracts"]["factory"]
    pool = dep["contracts"]["pool"]
    sp = dep["contracts"]["stabilityPool"]
    stocks = [dep["adapters"][t] for t in TICKERS]
    for i, acct in accounts_from(factory, "protection"):
        if out_of_time("protection"):
            CURSOR["protection"] = i
            return
        for adapter in stocks + [dep["adapters"]["VAULT"]]:
            debt = first_int(call(pool, "getPositionScaledDebt(address,address,bytes)(uint256)", adapter, acct, "0x"))
            if debt == 0:
                continue
            try:
                hf = first_int(call(pool, "calculateHealthFactor(address,address,bytes)(uint256)", adapter, acct, "0x"))
            except RuntimeError as e:
                log(f"{acct[:10]} HF unreadable ({e})")
                continue
            if hf < RAY:
                send(sp, "liquidate(address,address)", adapter, acct)
                log(f"liquidated {acct[:10]} on {adapter[:10]} (HF {hf / RAY:.3f})")
            elif hf < SOFT_TRIGGER and adapter in stocks:
                free = first_int(call(acct, "freeShares()(uint256)"))
                if free > 0:
                    send(acct, "softDeleverage(address)", adapter)
                    log(f"soft-deleveraged {acct[:10]} (HF {hf / RAY:.3f})")


def _swap_calldata(dep, ticker, usdc_amount, account):
    """Calldata that buys `ticker` with `usdc_amount`, and the minimum out:
    a market buy on Kuru's order book when the deployment has its venue, else
    the stand-in router priced at the oracle."""
    wrapper = dep["tokens"]["w" + ticker + "x"]
    adapter = dep["adapters"][ticker]
    price = first_int(call(adapter, "wrapperPrice()(uint256)"))
    min_out = (usdc_amount * 10**18 // price) * 98 // 100
    venue = dep.get("kuru", {}).get("venue")
    if venue:
        data = subprocess.check_output(
            ["cast", "calldata", "buy(address,uint256,uint256)", wrapper, str(usdc_amount), str(min_out)],
            text=True).strip()
        return venue, venue, data, min_out
    test_dex = dep["contracts"].get("testDexRouter")
    if not test_dex:
        raise RuntimeError("no swap venue on this deployment")
    data = subprocess.check_output(
        ["cast", "calldata", "swap(address,uint256,uint256)", wrapper, str(usdc_amount), str(price)],
        text=True).strip()
    return test_dex, test_dex, data, min_out


def tick_agents(dep):
    """Keep every position on its target, and grow the stock with the yield."""
    factory = dep["contracts"]["factory"]
    pool = dep["contracts"]["pool"]
    for i, acct in accounts_from(factory, "agents"):
        if out_of_time("agents"):
            CURSOR["agents"] = i
            return
        for ticker in TICKERS:
            adapter = dep["adapters"][ticker]
            target = first_int(call(acct, "targetLtvBps(address)(uint256)", adapter))
            if target == 0:  # the user never opened an Earn position on this stock
                continue
            # Only send when the position is actually off target and the
            # account can act on it: a keeper that fires blind wastes gas and
            # fills the log with reverts.
            value = first_int(call(adapter, "getAssetValue(address,bytes)(uint256)", acct, "0x"))
            debt = first_int(call(pool, "getPositionScaledDebt(address,address,bytes)(uint256)",
                                  adapter, acct, "0x"))
            if value:
                wanted = value * target // 10_000
                band = value // 100
                buffer_ = first_int(call(acct, "redeemableUsdc()(uint256)"))
                actionable = (wanted > debt + band) or (debt > wanted + band and buffer_ > 0)
                if actionable:
                    try:
                        send(acct, "rebalance(address)", adapter, gas=GAS_AGENT)
                        log(f"rebalanced {acct[:10]} on {ticker}: {debt / 1e6:.2f} -> "
                            f"{first_int(call(pool, 'getPositionScaledDebt(address,address,bytes)(uint256)', adapter, acct, '0x')) / 1e6:.2f} USDC")
                    except RuntimeError as e:
                        log(f"rebalance {acct[:10]} {ticker}: {str(e)[:90]}")

            debt = first_int(call(pool, "getPositionScaledDebt(address,address,bytes)(uint256)",
                                  adapter, acct, "0x"))
            have = first_int(call(acct, "redeemableUsdc()(uint256)"))
            profit = have - debt if have > debt else 0
            profit = profit * 999 // 1000  # the surplus shrinks with interest before inclusion
            if profit < 10**6:  # under 1 USDC, not worth the gas
                continue
            try:
                target_, spender, data, min_out = _swap_calldata(dep, ticker, profit, acct)
            except RuntimeError as e:
                log(f"compound skipped: {e}")
                continue
            try:
                send(acct, "compoundIntoStock(address,uint256,address,address,bytes,uint256)",
                     adapter, str(profit), target_, spender, data, str(min_out), gas=GAS_AGENT)
                log(f"compounded {profit / 1e6:.2f} USDC of yield into {ticker} for {acct[:10]}")
            except RuntimeError as e:
                log(f"compound {acct[:10]} {ticker}: {str(e)[:90]}")


def tick_kuru(dep):
    """Keep depth on the Kuru books the swaps go through, at the oracle's mid."""
    sys.path.insert(0, os.path.join(ROOT, "scripts"))
    import kuru_mm  # noqa: E402

    kuru_mm.tick()


def tick_snapshot(dep):
    va = dep["adapters"]["VAULT"]
    last = first_int(call(va, "snapshotAt()(uint256)"))
    if time.time() > last + 86400 + 60:
        send(va, "snapshot()", gas=GAS_PRICE_PUSH)
        log("vault CAPO snapshot")


PRICE_JOBS = ("prices",)
# Seconds a tick may spend on anything other than a price push.
HEAVY_BUDGET = int(os.environ.get("HEAVY_BUDGET", "150"))
# Where the account walk stopped last time, so cutting it short still makes
# progress round the list rather than rechecking the same head every tick.
CURSOR = {"protection": 0, "agents": 0}
# When the current tick has to be out of the heavy jobs. Set by main.
DEADLINE = [float("inf")]


def out_of_time(job):
    if time.time() < DEADLINE[0]:
        return False
    log(f"{job} paused, out of budget; it resumes where it stopped")
    return True


def accounts_from(factory, job):
    """Every account, starting where `job` left off."""
    n = first_int(call(factory, "accountCount()(uint256)"))
    if n == 0:
        return []
    start = CURSOR[job] % n
    order = [(start + k) % n for k in range(n)]
    CURSOR[job] = (start + n) % n
    return [(i, call(factory, "accounts(uint256)(address)", str(i))) for i in order]


STARTED = time.time()


def main():
    dep = json.load(open(DEPLOYMENT))
    log("keeper on chain", dep["chainId"], "prices: Chainlink Data Streams, verified on chain")
    jobs = {"prices": tick_prices, "kuru": tick_kuru, "protection": tick_protection, "agents": tick_agents,
            "snapshot": tick_snapshot}
    selected = os.environ.get("JOBS", "prices,kuru,snapshot,protection,agents").split(",")
    once = bool(os.environ.get("ONCE"))
    heavy = [j for j in selected if j not in PRICE_JOBS]

    while True:
        started = time.time()
        # The budget belongs to the heavy jobs, so it starts when they do, not
        # when the tick does: a price push that took twenty seconds must not
        # come out of the share meant for walking the accounts.
        heavy_started = None
        for name in selected:
            # Prices first and always. The rest walks every account against
            # every market, which grows with the deployment and slows down
            # further when a read reverts, and a tick that overruns is a tick
            # that did not refresh a price: the oracle then holds nothing
            # fresher than an hour and the whole app stops quoting. This is
            # what took the market offline on 2026-09-28. The heavy jobs get
            # what is left of the budget and pick up where they stopped.
            if once or name in PRICE_JOBS:
                DEADLINE[0] = float("inf")
            else:
                # A share of the budget each, in order, so the first heavy job
                # cannot eat the whole tick and leave the others never run.
                if heavy_started is None:
                    heavy_started = time.time()
                k = heavy.index(name)
                DEADLINE[0] = heavy_started + HEAVY_BUDGET * (k + 1) / len(heavy)
                if time.time() > DEADLINE[0]:
                    log(f"{name} skipped, its share of the tick is gone")
                    continue
            try:
                jobs[name](dep)
            except Exception as e:  # keep ticking
                log(f"{name} failed: {e}")
        if once:
            return
        if RUN_MINUTES and time.time() - STARTED > RUN_MINUTES * 60:
            log("run time reached, handing over to the next job")
            return
        # Measured from the start of the tick, so a slow one shortens the wait
        # instead of pushing the next price out by its own length.
        time.sleep(max(15, INTERVAL - (time.time() - started)))


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Arrow x Agama keeper for X Layer.

One tick does three jobs:

1. Prices. Writes TSLA / NVDA / SPY / AAPL into the StockOracle.
   - RedStone (default for TSLA, NVDA, AAPL): a signed data package is fetched
     from the public gateway, appended to the calldata of `pushRedStone`, and
     the signatures of three of five authorised signers are checked on-chain.
     RedStone stops publishing when the US market closes, so a failed push
     outside trading hours is expected, and the relay below keeps the market
     status up to date. RedStone does not publish SPY.
   - Preferred: Chainlink Data Streams. If DS_API_KEY and DS_API_SECRET are set,
     the keeper fetches the latest signed v11 reports and calls
     `pushReports(bytes[])`. The oracle verifies them on-chain against the X Layer
     VerifierProxy, so the keeper is only a carrier.
   - Fallback: relay of the Chainlink push feeds on Arbitrum (TSLA/USD, NVDA/USD,
     SPY/USD, AAPL/USD) through `pushMany`, bounded on-chain by the deviation cap.
     A value is relayed as current only while it is inside the feed heartbeat.
   Market status follows the xStocks 24/5 schedule (Sunday 20:00 to Friday 20:00
   New York time, NYSE holidays closed) unless Data Streams says otherwise.

2. Protection. For every Agama account: HF < 1.15 with free vault shares ->
   `softDeleverage`; HF < 1 -> `ArrowStabilityPool.liquidate`.

3. Agents. The user deposits a stock and never touches it again:
   - `rebalance` keeps every position at the LTV its owner picked (the stock
     went up: borrow more and put it in the vault; it went down: repay from the
     yield buffer, never from the stock).
   - `compoundIntoStock` turns the vault yield above the debt into MORE STOCK
     and adds it as collateral, through the swap venue the zap allowlists.
   Both are permissionless: the keeper is convenience, not control.

4. Vault CAPO snapshot, once a day (permissionless `snapshot()`).

Requires Foundry's `cast` on PATH. Config via env:
  RPC_URL (default https://xlayerrpc.okx.com), DEPLOYMENT (deployments/196.json),
  KEEPER_KEY (private key with KEEPER_ROLE), ARB_RPC_URL, DS_API_KEY, DS_API_SECRET,
  DS_HOST (default https://api.dataengine.chain.link), INTERVAL (seconds, default 300),
  ONCE=1 to run a single tick, JOBS=redstone,prices,snapshot,protection,agents to pick jobs.
"""

import hashlib
import hmac
import json
import os
import subprocess
import sys
import time
import urllib.request
from datetime import date, datetime, timezone
from zoneinfo import ZoneInfo

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RPC = os.environ.get("RPC_URL", "https://xlayerrpc.okx.com")
ARB_RPC = os.environ.get("ARB_RPC_URL", "https://arb1.arbitrum.io/rpc")
KEY = os.environ.get("KEEPER_KEY", "")
DEPLOYMENT = os.environ.get("DEPLOYMENT", os.path.join(ROOT, "deployments", "196.json"))
DS_KEY = os.environ.get("DS_API_KEY", "")
DS_SECRET = os.environ.get("DS_API_SECRET", "")
DS_HOST = os.environ.get("DS_HOST", "https://api.dataengine.chain.link")
INTERVAL = int(os.environ.get("INTERVAL", "300"))
# Gas ceilings per kind of call, each several times what it actually burns.
GAS_PRICE_PUSH = 400_000      # one oracle push, signed payload included
GAS_AGENT = 3_000_000         # rebalance, compound (a swap through a router)
GAS_PROTECTION = 6_000_000    # soft deleverage and liquidation walk positions
DEFAULT_GAS = GAS_PROTECTION

TICKERS = ["TSLA", "NVDA", "SPY", "AAPL"]
# Tickers RedStone publishes (no SPY, no ETFs).
REDSTONE_TICKERS = ["TSLA", "NVDA", "AAPL"]

# Chainlink push feeds on Arbitrum One (8 decimals), used for the relay fallback.
ARB_FEEDS = {
    "TSLA": "0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3",
    "NVDA": "0x4881A4418b5F2460B21d6F08CD5aA0678a7f262F",
    "SPY": "0x46306F3795342117721D8DEd50fbcF6DF2b3cc10",
    "AAPL": "0x8d0CC5f38f9E802475f2CFf4F9fc7000C2E1557c",
}
ARB_HEARTBEAT = 26 * 3600  # 24h heartbeat plus margin

# The xStock itself, on Solana, where it trades around the clock and where it
# has depth: about 1.4M$ of routable liquidity on TSLAx against a few dollars
# on X Layer. The share behind it keeps market hours; the token does not, and
# it does not wait for Monday to price the weekend's news.
#
# This is a keeper relay rather than an oracle read because X Layer has
# neither. Chainlink is the xStocks alliance's official oracle and publishes
# none of these here, its Data Streams verifier was never initialised on this
# chain, and the local DEX depth is too thin to read as a price. So the token's
# own market is relayed in, bounded on-chain by the same 15% per-update
# deviation cap as the Chainlink SPY feed relayed from Arbitrum. The day an
# oracle lands on X Layer, this becomes one line pointing at it.
XSTOCK_MINTS = {
    "TSLA": "XsDoVfqeBukxuZHWhdvWHBhgEHjGNst4MLodqsJHzoB",
    "NVDA": "Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh",
    "SPY": "XsoCS1TfEyfFhfvj8EtZ528L3CaKBDBRqRapnBbDF2W",
    "AAPL": "XsbEhLAtcf6HdfpFZ5xEMdqW8nfAvcsP5bdudRLJzJp",
}
JUPITER_PRICE = "https://lite-api.jup.ag/price/v3"
# Under this much routable USD, a quote is a number rather than a market price.
MIN_XSTOCK_LIQUIDITY = 100_000

# Chainlink Data Streams v11 feed IDs (US equities, regular hours).
DS_FEEDS = {
    "TSLA": "0x000b2dbed1640ead18d37338b75e4755630a900649261baf4ed79d9a749be13d",
    "NVDA": "0x000b6aa036224454037bab103184565f6aa9ea589c3b349f6d8471ee753524b9",
    "SPY": "0x000bc7e431fcd497f06b9e1dea869bcda3d05049d0601f3d1e56e64c8cdd05ac",
    "AAPL": "0x000bbd87a23775b4c11092ae9a1fc7b3393636ae1dbb9f1ef460f845c0f4cff1",
}

NYSE_HOLIDAYS_2026 = {
    date(2026, 1, 1), date(2026, 1, 19), date(2026, 2, 16), date(2026, 4, 3),
    date(2026, 5, 25), date(2026, 6, 19), date(2026, 7, 3), date(2026, 9, 7),
    date(2026, 11, 26), date(2026, 12, 25),
}

SOFT_TRIGGER = 115 * 10**25  # 1.15 RAY
RAY = 10**27


def log(*a):
    print(datetime.now(timezone.utc).strftime("%H:%M:%S"), *a, flush=True)


TRANSIENT = ("error sending request", "timed out", "connection reset", "502", "503", "504", "EOF")


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


def send(to, sig, *args, gas=DEFAULT_GAS):
    """`sig` may be a signature plus args, or a full calldata hex blob.

    Always checks the receipt: a mined-but-reverted transaction must never be
    reported as a success (a keeper that lies about a liquidation is worse than
    one that stops).

    Gas is set explicitly because estimation is tight on the loop-heavy paths,
    but the limit is per call rather than one blanket number. A node requires
    the sender to cover `gasLimit * gasPrice` up front even when the call burns
    a fraction of it, so a 6M limit on a 60k price push means a keeper with a
    faucet-sized balance cannot push a price at all.
    """
    if not KEY:
        raise RuntimeError("KEEPER_KEY not set")
    for attempt in range(6):
        try:
            out = cast("send", to, sig, *args, "--private-key", KEY,
                       "--gas-limit", str(gas), "--json")
            receipt = json.loads(out)
            if receipt.get("status") not in ("0x1", 1, "1"):
                raise RuntimeError(f"reverted: {receipt.get('transactionHash')}")
            return out
        except RuntimeError as e:
            # Load-balanced public RPCs can serve a stale nonce: wait and retry.
            if attempt < 5 and ("nonce too low" in str(e) or "already known" in str(e)):
                time.sleep(3)
                continue
            raise


def first_int(s):
    return int(s.split()[0])


def market_open_24_5(now_utc=None):
    """Whether the US equity session is trading: Sunday 20:00 to Friday 20:00 New York.

    `SESSION=closed` forces the answer, which is the only way to rehearse a
    weekend on a Tuesday: everything downstream of this, the xStock relay and
    the tightened terms, is unreachable the rest of the week. It picks a price
    source and never loosens anything, so a flag left set is a safe mistake.
    """
    forced = os.environ.get("SESSION")
    if forced:
        return forced == "open"
    ny = (now_utc or datetime.now(timezone.utc)).astimezone(ZoneInfo("America/New_York"))
    if ny.date() in NYSE_HOLIDAYS_2026:
        return False
    wd, hour = ny.weekday(), ny.hour  # Monday = 0
    if wd == 5:
        return False
    if wd == 6:
        return hour >= 20
    if wd == 4:
        return hour < 20
    return True


def b32(ticker):
    return "0x" + ticker.encode().hex().ljust(64, "0")


# ---- price sources ------------------------------------------------------------------


def ds_headers(method, path, body=b""):
    ts = str(int(time.time() * 1000))
    body_hash = hashlib.sha256(body).hexdigest()
    msg = f"{method} {path} {body_hash} {DS_KEY} {ts}"
    sig = hmac.new(DS_SECRET.encode(), msg.encode(), hashlib.sha256).hexdigest()
    return {
        "Authorization": DS_KEY,
        "X-Authorization-Timestamp": ts,
        "X-Authorization-Signature-SHA256": sig,
    }


def data_streams_reports():
    reports = []
    for t in TICKERS:
        path = f"/api/v1/reports/latest?feedID={DS_FEEDS[t]}"
        req = urllib.request.Request(DS_HOST + path, headers=ds_headers("GET", path))
        with urllib.request.urlopen(req, timeout=10) as r:
            reports.append(json.load(r)["report"]["fullReport"])
    return reports


def arbitrum_prices():
    now = int(time.time())
    prices = {}
    for t, feed in ARB_FEEDS.items():
        out = call(feed, "latestRoundData()(uint80,int256,uint256,uint256,uint80)", rpc=ARB_RPC).splitlines()
        answer, updated = first_int(out[1]), first_int(out[3])
        if now - updated > ARB_HEARTBEAT:
            log(f"{t}: Arbitrum feed outside heartbeat ({now - updated}s), skipped")
            continue
        prices[t] = answer * 10**10  # 8 -> 18 decimals
    return prices



def xstock_prices():
    """What the xStocks themselves trade at on Solana, in 1e18 USD.

    Only the ones with real depth behind the quote: a price nobody could fill
    is not a price, and it is exactly the mistake that reading the X Layer
    pools would be.
    """
    ids = ",".join(XSTOCK_MINTS.values())
    # Declaring a browser agent, because the gateway answers 403 to the one
    # urllib sends by default.
    req = urllib.request.Request(f"{JUPITER_PRICE}?ids={ids}", headers={
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                      "(KHTML, like Gecko) Chrome/140.0 Safari/537.36",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            quotes = json.load(r)
    except Exception as e:
        log(f"xStock quotes unavailable ({str(e)[:80]})")
        return {}

    prices = {}
    for ticker, mint in XSTOCK_MINTS.items():
        q = quotes.get(mint) or {}
        usd, depth = q.get("usdPrice"), q.get("liquidity") or 0
        if not usd:
            continue
        if depth < MIN_XSTOCK_LIQUIDITY:
            log(f"{ticker}: only {depth:,.0f}$ behind the quote, skipped")
            continue
        prices[ticker] = int(usd * 1e18)
    return prices


def tick_redstone(dep):
    """Signed RedStone prices, verified on-chain by the oracle."""
    oracle = dep["contracts"]["oracle"]
    if not market_open_24_5():
        log("market closed, RedStone does not publish: skipped")
        return
    payload = subprocess.run(["node", os.path.join(ROOT, "scripts", "redstone_payload.js"),
                              ",".join(REDSTONE_TICKERS)], capture_output=True, text=True)
    if payload.returncode != 0:
        log(f"redstone payload failed: {payload.stdout.strip()[:120]}{payload.stderr.strip()[:120]}")
        return
    tickers = "[" + ",".join(b32(t) for t in REDSTONE_TICKERS) + "]"
    calldata = subprocess.check_output(["cast", "calldata", "pushRedStone(bytes32[])", tickers], text=True).strip()
    send(oracle, calldata + payload.stdout.strip(), gas=GAS_PRICE_PUSH)
    time.sleep(2)  # load-balanced RPCs lag a block; read after they catch up
    prices = {t: round(first_int(call(oracle, "feed(bytes32)((uint128,uint64,bool,bool))", b32(t))
                                  .strip("()").split(", ")[0]) / 1e18, 2) for t in REDSTONE_TICKERS}
    log("redstone:", prices, "(signed, verified on-chain)")


def _feed(oracle, ticker):
    f = call(oracle, "feed(bytes32)((uint128,uint64,bool,bool))", b32(ticker)).strip("()").split(", ")
    return {"price": int(f[0].split()[0]), "observedAt": int(f[1].split()[0]), "open": f[2] == "true"}


def _relay_needed(oracle, ticker, now_ts, half_window):
    """Whether the relay has to carry a ticker RedStone normally owns.

    Two cases. It is marked closed, and only the keeper can lift that. Or its
    last observation is halfway to expiry: the RedStone gateway is a public
    service that goes quiet, and a price nobody refreshes stops being a price
    the markets can borrow against.
    """
    f = _feed(oracle, ticker)
    if f["price"] == 0:
        return False
    return not f["open"] or (now_ts - f["observedAt"]) > half_window


def tick_prices(dep):
    oracle = dep["contracts"]["oracle"]
    if DS_KEY and DS_SECRET:
        reports = data_streams_reports()
        send(oracle, "pushReports(bytes[])", "[" + ",".join(reports) + "]", gas=GAS_PRICE_PUSH)
        log("Data Streams: pushed", len(reports), "verified reports")
        return
    session = market_open_24_5()

    # Out of session the equity feeds stop moving: RedStone keeps publishing,
    # on a fresh timestamp, the number it published at the last trade. The
    # xStock itself does not stop, so that is what gets relayed instead, and
    # the ticker stays OPEN because a live price from a real market is exactly
    # what "open" is supposed to mean. Freezing at the close is the fallback
    # for when Solana cannot be read either, not the normal weekend.
    if not session:
        tokens = xstock_prices()
        if tokens:
            _push_prices(oracle, tokens, is_open=True, source="xStocks on Solana")
            return
        log("no xStock quote either, holding the last close")

    prices = arbitrum_prices()
    if not prices:
        return
    is_open = session
    # While the market trades, RedStone signs TSLA, NVDA and AAPL, so the relay
    # only carries SPY. At the close it carries every ticker once, to flip the
    # market status and freeze the last price for the weekend.
    names = [t for t in TICKERS if t in prices and (not is_open or t not in REDSTONE_TICKERS)]
    # Observation time = chain time (a fork's clock may lag the wall clock).
    ts = first_int(cast("block", "latest", "-f", "timestamp"))
    if is_open:
        # And at the reopen it has to carry them once more. `pushRedStone`
        # refuses to write a ticker whose stored status says closed, by design:
        # RedStone keeps publishing out of session and the close must stay
        # frozen. So RedStone cannot lift its own freeze. Only the keeper can,
        # and if it never does, those three tickers stay shut for good. The
        # same carry covers a gateway that has simply gone quiet.
        half = first_int(call(oracle, "maxOpenStaleness()(uint256)")) // 2
        names += [t for t in REDSTONE_TICKERS
                  if t in prices and t not in names and _relay_needed(oracle, t, ts, half)]
    if not names:
        return
    _push_prices(oracle, {t: prices[t] for t in names}, is_open,
                 source="Chainlink relay", ts=ts)


def _push_prices(oracle, prices, is_open, source, ts=None):
    """One bounded relay push, whatever the source was."""
    if not prices:
        return
    # Observation time = chain time (a fork's clock may lag the wall clock).
    if ts is None:
        ts = first_int(cast("block", "latest", "-f", "timestamp"))
    # The oracle refuses an observation that is not newer than the one it holds,
    # per ticker, so the whole batch has to clear the NEWEST of them. Checking
    # only the first one sends a push that reverts on the second.
    newest = max(_feed(oracle, t)["observedAt"] for t in prices)
    if ts <= newest:
        log("prices already current for this block, skipped")
        return
    tick_arr = "[" + ",".join(b32(t) for t in prices) + "]"
    px_arr = "[" + ",".join(str(prices[t]) for t in prices) + "]"
    send(oracle, "pushMany(bytes32[],uint256[],uint64,bool)", tick_arr, px_arr, str(ts),
         "true" if is_open else "false", gas=GAS_PRICE_PUSH)
    log(f"{source}:", {t: round(p / 1e18, 2) for t, p in prices.items()},
        "open" if is_open else "frozen at the close")


# ---- protection -----------------------------------------------------------------------


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


def _swap_calldata(dep, ticker, usdg_amount, account):
    """Calldata that buys `ticker` with `usdg_amount`, and the minimum out.

    Testnet has no aggregator, so the deployment carries a stand-in router
    priced at the oracle; mainnet uses the OKX DEX aggregator.
    """
    wrapper = dep["tokens"]["w" + ticker + "x"]
    adapter = dep["adapters"][ticker]
    price = first_int(call(adapter, "wrapperPrice()(uint256)"))
    test_dex = dep["contracts"].get("testDexRouter")
    if not test_dex and dep["chainId"] != 196:
        # A chain-1961 fork keeps mainnet state but not its chain id, and the
        # aggregator signs its routes for 196: no venue the swap can use.
        raise RuntimeError("no swap venue on this deployment")
    if test_dex:
        data = subprocess.check_output(
            ["cast", "calldata", "swap(address,uint256,uint256)", wrapper, str(usdg_amount), str(price)],
            text=True).strip()
        return test_dex, test_dex, data, (usdg_amount * 10**18 // price) * 98 // 100
    sys.path.insert(0, os.path.join(ROOT, "scripts"))
    import okx_dex  # noqa: E402

    swap = okx_dex.swap(dep["tokens"]["USDG"], wrapper, str(usdg_amount), account)
    spender = okx_dex.approve(dep["tokens"]["USDG"], str(usdg_amount))["dexContractAddress"]
    return swap["tx"]["to"], spender, swap["tx"]["data"], int(swap["tx"]["minReceiveAmount"])


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
                buffer_ = first_int(call(acct, "redeemableUsdg()(uint256)"))
                actionable = (wanted > debt + band) or (debt > wanted + band and buffer_ > 0)
                if actionable:
                    try:
                        send(acct, "rebalance(address)", adapter, gas=GAS_AGENT)
                        log(f"rebalanced {acct[:10]} on {ticker}: {debt / 1e6:.2f} -> "
                            f"{first_int(call(pool, 'getPositionScaledDebt(address,address,bytes)(uint256)', adapter, acct, '0x')) / 1e6:.2f} USDG")
                    except RuntimeError as e:
                        log(f"rebalance {acct[:10]} {ticker}: {str(e)[:90]}")

            debt = first_int(call(pool, "getPositionScaledDebt(address,address,bytes)(uint256)",
                                  adapter, acct, "0x"))
            have = first_int(call(acct, "redeemableUsdg()(uint256)"))
            profit = have - debt if have > debt else 0
            profit = profit * 999 // 1000  # the surplus shrinks with interest before inclusion
            if profit < 10**6:  # under 1 USDG, not worth the gas
                continue
            try:
                target_, spender, data, min_out = _swap_calldata(dep, ticker, profit, acct)
            except RuntimeError as e:
                log(f"compound skipped: {e}")
                continue
            try:
                send(acct, "compoundIntoStock(address,uint256,address,address,bytes,uint256)",
                     adapter, str(profit), target_, spender, data, str(min_out), gas=GAS_AGENT)
                log(f"compounded {profit / 1e6:.2f} USDG of yield into {ticker} for {acct[:10]}")
            except RuntimeError as e:
                log(f"compound {acct[:10]} {ticker}: {str(e)[:90]}")


def tick_snapshot(dep):
    va = dep["adapters"]["VAULT"]
    last = first_int(call(va, "snapshotAt()(uint256)"))
    if time.time() > last + 86400 + 60:
        send(va, "snapshot()", gas=GAS_PRICE_PUSH)
        log("vault CAPO snapshot")


PRICE_JOBS = ("redstone", "prices")
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


def main():
    dep = json.load(open(DEPLOYMENT))
    log("keeper on chain", dep["chainId"], "source:", "Data Streams" if DS_KEY else "Chainlink Arbitrum relay")
    jobs = {"redstone": tick_redstone, "prices": tick_prices, "protection": tick_protection,
            "agents": tick_agents, "snapshot": tick_snapshot}
    selected = os.environ.get("JOBS", "redstone,prices,snapshot,protection,agents").split(",")
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
        # Measured from the start of the tick, so a slow one shortens the wait
        # instead of pushing the next price out by its own length.
        time.sleep(max(15, INTERVAL - (time.time() - started)))


if __name__ == "__main__":
    sys.exit(main())

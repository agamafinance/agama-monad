#!/usr/bin/env python3
"""End-to-end run of Arrow x Agama with real transactions.

    python3 scripts/e2e.py fork [a|b|all]      # local X Layer mainnet fork (anvil, chain 1961)
    python3 scripts/e2e.py testnet [a|b|all]   # X Layer testnet (chain 1952), deployer in .keys/

Scenario (every step asserted on-chain state):
  1. keeper relays real Chainlink prices
  2. Alice: Earn on 10 wTSLAx at 25% LTV (keeps her vault shares as buffer)
  3. Carol: Earn on 10 wTSLAx at 30% LTV, then pulls her vault shares out (no buffer)
  4. Bob: Amplify 1,000 USDG at 3x
  5. vault yield settled by the operator -> Bob's equity grows
  6. TSLA crash to ~71% in steps inside the oracle deviation cap
  7. keeper protection tick: Alice soft-deleveraged (stock untouched),
     Carol partially liquidated by the stability pool (keeps the rest)
  8. a buyer takes the SP inventory at the 3% discount
  9. TSLA recovers, Bob closes Amplify to USDG, Alice closes Earn and gets her 10 wTSLAx back

Part B (the remaining paths):
  10. Dave supplies 1,000 USDG to Arrow as a lender
  11. Erin stakes 500 USDG in the stability pool; an exit before the cooldown is refused
  12. Equity session closed: TSLA frozen, terms tightened both sides (LTV 30->22, threshold
      40->32), borrowing still open at the tighter level, then the relay reopens the session
  13. Frank: Earn, soft deleverage, recovery, close with a wallet top-up (closeWithTopUp)
  14. Grace: Earn, Amplify stacked on the Earn shares, close Amplify (equity goes back to the Earn
      buffer, not the wallet), close Earn on that buffer
  15. Buy and Earn: one transaction buys the stock and opens the position
  16. Agents: the stock rises, `rebalance` borrows the difference and vaults it;
      `compoundIntoStock` turns the vault yield into more stock
  17. OKX rail: a stock withdrawn from the OKX app (the base xStock) is deposited
      directly, and the position closes back into that same token
  18. Dave withdraws his supply with the interest paid by the borrowers
"""

import atexit
import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODE = sys.argv[1] if len(sys.argv) > 1 else "fork"
PART = sys.argv[2] if len(sys.argv) > 2 else "all"
RPC = {"fork": "http://127.0.0.1:8545", "testnet": "https://testrpc.xlayer.tech/terigon"}[MODE]
DEP = json.load(open(os.path.join(ROOT, "deployments", {"fork": "1961", "testnet": "1952"}[MODE] + ".json")))
C, A, T = DEP["contracts"], DEP["adapters"], DEP["tokens"]
RAY = 10**27
E18 = 10**18
E6 = 10**6

ANVIL_KEYS = [
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
    "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
    "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
    "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
    "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356",
    "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97",
    "0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6",
]
ACTORS = ("alice", "carol", "bob", "buyer", "dave", "erin", "frank", "grace")


def keys():
    if MODE == "fork":
        return {"admin": ANVIL_KEYS[0], **{n: ANVIL_KEYS[i + 2] for i, n in enumerate(ACTORS)}}
    dep = json.load(open(os.path.join(ROOT, ".keys", "deployer.json")))
    dep = dep[0] if isinstance(dep, list) else dep
    path = os.path.join(ROOT, ".keys", "e2e.json")
    # Fresh actors by default: a shared testnet keeps positions between runs, and
    # the scenario assumes everyone starts flat. E2E_REUSE=1 keeps the old keys.
    reuse = os.environ.get("E2E_REUSE") == "1"
    ks = json.load(open(path)) if (reuse and os.path.exists(path)) else {}
    for name in ACTORS:
        if name not in ks:
            w = json.loads(subprocess.check_output(["cast", "wallet", "new", "--json"]))
            w = w[0] if isinstance(w, list) else w
            ks[name] = w["private_key"]
    if reuse:
        json.dump(ks, open(path, "w"))
        os.chmod(path, 0o600)
    ks["admin"] = dep["private_key"]
    return ks


K = keys()
ADDR = {n: subprocess.check_output(["cast", "wallet", "address", k], text=True).strip() for n, k in K.items()}


TRANSIENT = ("error sending request", "timed out", "connection reset", "502", "503", "504", "EOF")


def cast(*args):
    # Retry transient transport errors of the public RPC (not reverts).
    for attempt in range(5):
        r = subprocess.run(["cast", *args, "--rpc-url", RPC], capture_output=True, text=True)
        if r.returncode == 0:
            return r.stdout.strip()
        if attempt < 4 and any(t in r.stderr for t in TRANSIENT):
            time.sleep(2 + 2 * attempt)
            continue
        raise RuntimeError(f"cast {args[0]} {args[1] if len(args) > 1 else ''}: {r.stderr.strip()[-400:]}")


LAST_BLOCK = [0]  # block of our last mined tx: reads never go below it


def call(to, sig, *args):
    # Public testnet RPC nodes are load-balanced and can lag a block or two:
    # read at (at least) the block of our last transaction, retry until served.
    if not LAST_BLOCK[0]:
        return cast("call", to, sig, *args)
    for attempt in range(20):
        try:
            return cast("call", to, sig, *args, "--block", str(LAST_BLOCK[0]))
        except RuntimeError:
            if attempt == 19:
                raise
            time.sleep(1)


def num(s):
    return int(s.split()[0])


def send(who, to, sig, *args, value=None):
    extra = ["--value", str(value)] if value else []
    call_args = [sig, *args] if sig else []  # plain value transfer: no calldata
    # Gas estimation is tight on the loop-heavy paths (a vault deposit inside an
    # open can tip it into OutOfGas), and blocks here hold 200M+.
    if sig:
        extra += ["--gas-limit", "6000000"]
    for attempt in range(6):
        try:
            out = cast("send", to, *call_args, "--private-key", K[who], "--json", *extra)
            break
        except RuntimeError as e:
            # The public testnet RPC is load-balanced: a node can lag one block
            # behind and hand out a stale nonce. Wait and retry.
            if attempt < 5 and ("nonce too low" in str(e) or "already known" in str(e)):
                time.sleep(3)
                continue
            raise
    tx = json.loads(out)
    if tx.get("status") not in ("0x1", 1, "1"):
        h = tx.get("transactionHash", "")
        trace = ""
        try:
            trace = cast("run", h).strip().splitlines()[-6:]
            trace = "\n      " + "\n      ".join(trace)
        except RuntimeError:
            pass
        raise RuntimeError(f"tx reverted: {sig} ({h}){trace}")
    bn = tx.get("blockNumber")
    if bn is not None:
        LAST_BLOCK[0] = max(LAST_BLOCK[0], int(bn, 16) if isinstance(bn, str) else int(bn))
    return tx["transactionHash"]


def step(msg):
    print(f"\n\033[1m== {msg}\033[0m", flush=True)


def ok(cond, msg):
    if not cond:
        raise SystemExit(f"   FAIL: {msg}")
    print(f"   ok  {msg}", flush=True)


def b32(t):
    return "0x" + t.encode().hex().ljust(64, "0")


def park_keeper():
    """Stop a keeper for the length of the run, and put it back.

    It acts on the same positions this script is posing: a soft deleverage and
    a rebalance landing on one account produce a health factor nobody asked
    for, and the failure reads like a contract bug rather than two callers each
    doing their job. Putting it back matters just as much: a testnet whose
    prices nobody refreshes goes stale in an hour and the app stops quoting.

    It runs under launchd with KeepAlive, so killing the process is not enough,
    launchd would put it straight back. The tmux path is kept for a keeper
    started by hand.
    """
    if MODE != "testnet":
        return

    plist = os.path.expanduser("~/Library/LaunchAgents/com.agama.xlayer.keeper.plist")
    under_launchd = os.path.exists(plist) and subprocess.run(
        ["launchctl", "list", "com.agama.xlayer.keeper"], capture_output=True).returncode == 0
    in_tmux = subprocess.run(["tmux", "has-session", "-t", "agama-keeper"],
                             capture_output=True).returncode == 0
    if not under_launchd and not in_tmux:
        return

    if under_launchd:
        subprocess.run(["launchctl", "unload", plist], capture_output=True)
    if in_tmux:
        subprocess.run(["tmux", "kill-session", "-t", "agama-keeper"], capture_output=True)
    print("   ..  keeper parked for the run, it will be restarted at the end", flush=True)

    def restart():
        if under_launchd:
            subprocess.run(["launchctl", "load", plist], capture_output=True)
        else:
            subprocess.run(["tmux", "new", "-d", "-s", "agama-keeper",
                            "./scripts/run-keeper.sh testnet > /tmp/agama-keeper.log 2>&1"],
                           cwd=ROOT, capture_output=True)
        print("   ..  keeper restarted", flush=True)

    atexit.register(restart)


def fund():
    park_keeper()
    step("0. funding actors")
    if MODE == "fork":
        for n in ACTORS:
            cast("rpc", "anvil_setBalance", ADDR[n], hex(10 * E18))
        def setbal(token, slot, who, amount):
            key = subprocess.check_output(["cast", "index", "address", who, str(slot)], text=True).strip()
            cast("rpc", "anvil_setStorageAt", token, key, "0x" + format(amount, "064x"))
        for n in ("alice", "carol", "frank", "grace"):
            setbal(T["wTSLAx"], 101, ADDR[n], 10 * E18)
        for n in ("bob", "buyer", "dave", "erin", "frank", "grace"):
            setbal(T["USDG"], 1, ADDR[n], 5_000 * E6)
        setbal(T["USDG"], 1, ADDR["admin"], 100_000 * E6)
    else:
        for n in ACTORS:
            if num(cast("balance", ADDR[n])) < 2 * 10**15:
                send("admin", ADDR[n], "", value=2 * 10**15)  # 0.002 OKB of gas
        for n in ("alice", "carol", "frank", "grace"):
            if num(call(T["wTSLAx"], "balanceOf(address)(uint256)", ADDR[n])) < 10 * E18:
                send(n, T["wTSLAx"], "faucet(address,uint256)", ADDR[n], str(10 * E18))
        for n in ("bob", "buyer", "admin", "dave", "erin", "frank", "grace"):
            send(n, T["USDG"], "faucet(address,uint256)", ADDR[n], str(5_000 * E6))
    ok(num(call(T["wTSLAx"], "balanceOf(address)(uint256)", ADDR["alice"])) >= 10 * E18, "alice holds 10 wTSLAx")
    ok(num(call(T["USDG"], "balanceOf(address)(uint256)", ADDR["bob"])) >= 1_000 * E6, "bob holds USDG")


def keeper(jobs):
    env = dict(os.environ, RPC_URL=RPC, DEPLOYMENT=os.path.join(ROOT, "deployments", str(DEP["chainId"]) + ".json"),
               KEEPER_KEY=K["admin"], ONCE="1", JOBS=jobs)
    out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "keeper.py")], env=env,
                         capture_output=True, text=True)
    for line in out.stdout.strip().splitlines():
        print("   keeper |", line)
    # The keeper mined its own txs: move the read floor past them.
    time.sleep(3)
    LAST_BLOCK[0] = max(LAST_BLOCK[0], num(cast("block-number")))


def feed(ticker):
    out = call(C["oracle"], "feed(bytes32)((uint128,uint64,bool,bool))", b32(ticker))
    parts = out.strip("()").split(", ")
    return int(parts[0].split()[0]), int(parts[1].split()[0]), parts[2] == "true"


def push(ticker, price, is_open=True):
    _, last_obs, _ = feed(ticker)
    while True:
        now = num(cast("block", "latest", "-f", "timestamp"))
        if now > last_obs:
            break
        if MODE == "fork":
            cast("rpc", "evm_mine")  # anvil only advances time when a block is mined
        else:
            time.sleep(1)
    send("admin", C["oracle"], "push(bytes32,uint256,uint64,bool)", b32(ticker), str(price), str(now),
         "true" if is_open else "false")


def walk(ticker, target):
    cur, _, _ = feed(ticker)
    while cur != target:
        nxt = max(target, cur * 86 // 100) if target < cur else min(target, cur * 114 // 100)
        push(ticker, nxt)
        cur = nxt
        print(f"   {ticker} -> {cur / E18:.2f}")


def reverts(who, to, sig, *args):
    """Simulate `who` calling `to`; True if the call reverts."""
    try:
        cast("call", to, sig, *args, "--from", ADDR[who])
        return False
    except RuntimeError:
        return True


def usdg(who):
    return num(call(T["USDG"], "balanceOf(address)(uint256)", ADDR[who]))


def wtsla(who):
    return num(call(T["wTSLAx"], "balanceOf(address)(uint256)", ADDR[who]))


def earn_pos(user):
    out = call(C["earnRouter"], "position(address,address)((address,uint256,uint256,uint256,uint256,uint256,uint256,bool,uint256))",
               ADDR[user], A["TSLA"])
    f = [x.split()[0] for x in out.strip("()").split(", ")]
    return {"account": f[0], "collateral": int(f[1]), "value": int(f[2]), "debt": int(f[3]), "hf": int(f[4]),
            "free": int(f[5]), "freeValue": int(f[6])}


def amp_pos(user):
    out = call(C["amplifyRouter"], "position(address)((address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))",
               ADDR[user])
    f = [x.split()[0] for x in out.strip("()").split(", ")]
    return {"account": f[0], "shares": int(f[1]), "exposure": int(f[2]), "debt": int(f[3]), "equity": int(f[4]),
            "lev": int(f[5]), "hf": int(f[6])}


def capo():
    """(live rate, capped rate) of the vault share, assets per ONE_SHARE.

    Their ratio is how much of a share the CAPO ceiling lets Arrow lend against:
    1.0 in steady state, below it for as long as a settled coupon is amortising
    in at the adapter's growth cap. Every Amplify number is measured on it.
    """
    return num(call(A["VAULT"], "liveRate()(uint256)")), num(call(A["VAULT"], "cappedRate()(uint256)"))


def main():
    print(f"Arrow x Agama e2e on {MODE} (chain {DEP['chainId']}), part {PART}")
    for n, a in ADDR.items():
        print(f"   {n:6s} {a}")
    fund()
    if PART in ("a", "all"):
        part_a()
    if PART in ("b", "all"):
        part_b()
    print("\n\033[1mE2E PASSED\033[0m")


def part_a():
    step("1. keeper relays Chainlink prices")
    keeper("redstone,prices")
    p0, _, is_open = feed("TSLA")
    ok(p0 > 0 and is_open, f"TSLA {p0 / E18:.2f} USD, market open")

    step("2. Alice: Earn on 10 wTSLAx at 25% LTV")
    send("alice", T["wTSLAx"], "approve(address,uint256)", C["earnRouter"], str(10 * E18))
    send("alice", C["earnRouter"], "open(address,uint256,uint256)", A["TSLA"], str(10 * E18), "2500")
    a = earn_pos("alice")
    # Relative: on a shared testnet the actor may carry a position (and its
    # accrued interest) from an earlier run.
    ok(abs(a["debt"] - a["value"] // 4) <= max(2, a["value"] // 4000),
       f"borrowed {a['debt'] / E6:.2f} USDG = 25% of {a['value'] / E6:.2f}")
    ok(abs(a["hf"] - 16 * RAY // 10) < RAY // 1000, f"HF {a['hf'] / RAY:.3f}")
    # "The borrowed USDG went into the vault" is a question about the shares the
    # account holds, so ask the vault: `redeemableUsdg` converts them at the
    # ERC-4626 rate. `freeSharesValue` answers a different question, what those
    # shares are worth AS COLLATERAL, and the CAPO ceiling deliberately holds
    # that under the live rate while a settled yield is amortised. Comparing it
    # to the debt was comparing a haircut to the thing it discounts.
    redeemable = num(call(a["account"], "redeemableUsdg()(uint256)"))
    ok(a["debt"] * 999 // 1000 <= redeemable <= a["debt"] + 2,
       f"{redeemable / E6:.2f} USDG parked in the Agama vault (debt {a['debt'] / E6:.2f})")
    ok(a["freeValue"] <= redeemable,
       f"counted as collateral at the capped rate: {a['freeValue'] / E6:.2f} USDG, "
       f"{(redeemable - a['freeValue']) / E6:.2f} still held back by the CAPO ceiling")

    step("3. Carol: Earn at 30% LTV, then withdraws her vault shares (no buffer)")
    send("carol", T["wTSLAx"], "approve(address,uint256)", C["earnRouter"], str(10 * E18))
    send("carol", C["earnRouter"], "open(address,uint256,uint256)", A["TSLA"], str(10 * E18), "3000")
    c = earn_pos("carol")
    send("carol", c["account"], "sweep(address)", C["sagUSD"])
    ok(earn_pos("carol")["free"] == 0, f"Carol debt {c['debt'] / E6:.2f} USDG, buffer removed")

    step("4. Bob: Amplify 1,000 USDG at 3x")
    send("bob", T["USDG"], "approve(address,uint256)", C["amplifyRouter"], str(1_000 * E6))
    send("bob", C["amplifyRouter"], "open(uint256,uint256)", str(1_000 * E6), "30000")
    b = amp_pos("bob")
    # 3x is a target on the valuation Arrow lends against, and that valuation is
    # the CAPO-capped vault rate, not the live one: a coupon that just settled is
    # not borrowable collateral until the ceiling has amortised it in. So the
    # loop's debt target is 2x the CAPO value of the deposit, and it stops one hop
    # short when the remainder falls under `minBorrow`. Asserting a 3.00x reading
    # instead would be asserting that the cap is never behind, which is the one
    # thing CAPO exists to allow.
    live, capped = capo()
    target = 2 * 1_000 * E6 * capped // live
    # 3x is a target, not a promise. What the loop can actually reach is the
    # pool's ceiling: 70% of the HAIRCUT value of what it holds, which is the
    # capped value less the adapter's 3%. Once the CAPO ceiling sits far enough
    # behind the vault, that lands under 2x the deposit and the loop stops
    # early, correctly. So the check is that it stopped for the right reason,
    # with less than one minimum borrow left on the table.
    haircut = num(call(A["VAULT"], "getAssetValue(address,bytes)(uint256)", b["account"], "0x"))
    max_ltv = num(call(A["VAULT"], "MAX_LTV()(uint256)"))
    min_borrow = num(call(C["pool"], "minBorrowAmount()(uint256)"))
    ceiling = haircut * max_ltv // 10_000
    room = ceiling - b["debt"] if ceiling > b["debt"] else 0
    reached = b["debt"] >= target * 99 // 100
    ok(b["debt"] <= target * 1005 // 1000 and (reached or room < min_borrow),
       f"borrowed {b['debt'] / E6:.2f} USDG on 1,000 deposited, "
       + ("the 2x target at the capped rate"
          if reached else
          f"all the {max_ltv // 100}% ceiling allowed: {room / E6:.2f} USDG of room left, "
          f"under the {min_borrow / E6:.2f} minimum borrow"))
    fair = (1_000 * E6 + b["debt"]) * capped // live
    ok(abs(b["exposure"] - fair) <= fair // 500,
       f"exposure {b['exposure'] / E6:.2f} USDG, everything in the vault at that same rate, "
       f"so the position reads {b['lev'] / 10_000:.2f}x at HF {b['hf'] / RAY:.3f}")

    step("5. vault yield settled (0.5% of vault assets)")
    vault_assets = num(call(C["sagUSD"], "totalAssets()(uint256)")) // 10**12
    y = vault_assets // 200
    shares_b = num(call(A["VAULT"], "balanceOf(address)(uint256)", b["account"]))
    live_before = num(call(C["sagUSD"], "convertToAssets(uint256)(uint256)", str(shares_b))) // 10**12
    send("admin", T["USDG"], "transfer(address,uint256)", C["queue"], str(y))
    send("admin", C["queue"], "settleYield(uint256)", str(y))
    live_after = num(call(C["sagUSD"], "convertToAssets(uint256)(uint256)", str(shares_b))) // 10**12
    ok(live_after > live_before, f"Bob's exposure {live_before / E6:.2f} -> {live_after / E6:.2f} USDG (+{(live_after - live_before) / E6:.2f}, 3x the yield of his equity)")

    step("6. TSLA crash to ~71.5% (steps inside the 15% deviation cap)")
    walk("TSLA", p0 * 715 // 1000)
    a, c = earn_pos("alice"), earn_pos("carol")
    ok(a["hf"] < 115 * RAY // 100, f"Alice HF {a['hf'] / RAY:.3f} < 1.15 (soft-deleverage zone)")
    ok(c["hf"] < RAY, f"Carol HF {c['hf'] / RAY:.3f} < 1 (liquidatable)")

    step("7. keeper protection tick")
    sp_inv_before = num(call(T["wTSLAx"], "balanceOf(address)(uint256)", C["stabilityPool"]))
    keeper("protection")
    a, c = earn_pos("alice"), earn_pos("carol")
    ok(abs(a["hf"] - 14 * RAY // 10) < RAY // 100, f"Alice HF back to {a['hf'] / RAY:.3f}")
    ok(a["collateral"] == 10 * E18, "Alice still holds all 10 wTSLAx: the vault shares paid")
    seized = num(call(T["wTSLAx"], "balanceOf(address)(uint256)", C["stabilityPool"])) - sp_inv_before
    ok(c["debt"] == 0 and 0 < c["collateral"] < 10 * E18,
       f"Carol liquidated partially: SP seized {seized / E18:.3f} wTSLAx, Carol keeps {c['collateral'] / E18:.3f}")

    step("8. buyer takes the SP inventory at a 3% discount")
    inv = num(call(T["wTSLAx"], "balanceOf(address)(uint256)", C["stabilityPool"]))
    fair = num(call(A["TSLA"], "valueOf(uint256)(uint256)", str(inv)))
    max_cost = fair * 9_700 // 10_000 + 2
    send("buyer", T["USDG"], "approve(address,uint256)", C["stabilityPool"], str(max_cost))
    send("buyer", C["stabilityPool"], "buyCollateral(address,uint256,uint256,address)", A["TSLA"], str(inv), str(max_cost), ADDR["buyer"])
    ok(num(call(T["wTSLAx"], "balanceOf(address)(uint256)", ADDR["buyer"])) >= inv,
       f"buyer paid ~{max_cost / E6:.2f} USDG for {inv / E18:.3f} wTSLAx worth {fair / E6:.2f}")

    step("9. recovery and exits")
    walk("TSLA", p0)
    usdg_before = num(call(T["USDG"], "balanceOf(address)(uint256)", ADDR["bob"]))
    send("bob", C["amplifyRouter"], "close(bool)", "true")
    got = num(call(T["USDG"], "balanceOf(address)(uint256)", ADDR["bob"])) - usdg_before
    ok(got > 1_000 * E6, f"Bob closed Amplify: {got / E6:.2f} USDG back for 1,000 in")
    send("alice", C["earnRouter"], "close(address)", A["TSLA"])
    ok(num(call(T["wTSLAx"], "balanceOf(address)(uint256)", ADDR["alice"])) >= 10 * E18, "Alice closed Earn: 10 wTSLAx back")


def part_b():
    keeper("redstone,prices")
    p0, _, _ = feed("TSLA")

    step("10. Dave supplies 1,000 USDG to Arrow")
    send("dave", T["USDG"], "approve(address,uint256)", C["pool"], str(1_000 * E6))
    send("dave", C["pool"], "deposit(uint256,address)", str(1_000 * E6), ADDR["dave"])
    dave_shares = num(call(C["pool"], "balanceOf(address)(uint256)", ADDR["dave"]))
    ok(dave_shares > 0, f"Dave holds {dave_shares / 10**12:.2f} arUSDG")

    step("11. Erin stakes 500 USDG in the stability pool")
    send("erin", T["USDG"], "approve(address,uint256)", C["stabilityPool"], str(500 * E6))
    send("erin", C["stabilityPool"], "depositUSDG(uint256,address)", str(500 * E6), ADDR["erin"])
    erin_sp = num(call(C["stabilityPool"], "balanceOf(address)(uint256)", ADDR["erin"]))
    ok(erin_sp > 0, f"Erin holds {erin_sp / 10**12:.2f} aSP-USDG (SP share price above 1 after part A's liquidation gain)")
    ok(reverts("erin", C["stabilityPool"], "redeem(uint256,address,address)", str(erin_sp), ADDR["erin"], ADDR["erin"]),
       "instant exit refused (cooldown protects liquidations in flight)")
    send("erin", C["stabilityPool"], "requestExit(uint256)", str(erin_sp))
    req = call(C["stabilityPool"], "exitRequests(address)(uint128,uint64)", ADDR["erin"]).splitlines()
    ok(num(req[0]) == erin_sp, f"exit requested, unlocks at {num(req[1])}")

    step("12. equity session closed: price frozen, terms tightened, market still open")
    push("TSLA", p0, is_open=False)
    ok(call(A["TSLA"], "borrowAllowed()(bool)") == "true",
       "borrowAllowed stays true: a shut session is not a shut market")
    lt = num(call(A["TSLA"], "LIQUIDATION_THRESHOLD()(uint256)"))
    ml = num(call(A["TSLA"], "MAX_LTV()(uint256)"))
    ok(lt == 3_200 and ml == 2_200,
       f"terms tightened on both sides: max LTV {ml / 100:.0f}%, liquidation at {lt / 100:.0f}% "
       f"(each 8% under the weekday figure)")
    send("frank", T["wTSLAx"], "approve(address,uint256)", C["earnRouter"], str(10 * E18))
    ok(reverts("frank", C["earnRouter"], "open(address,uint256,uint256)", A["TSLA"], str(10 * E18), "2500"),
       "the weekday 25% is refused out of session")
    send("frank", C["earnRouter"], "open(address,uint256,uint256)", A["TSLA"], str(10 * E18), "2200")
    f12 = earn_pos("frank")
    ok(f12["debt"] > 0 and f12["hf"] > 14 * RAY // 10,
       f"but 22% goes through, at HF {f12['hf'] / RAY:.3f}: the same cushion as a weekday open")
    # Put Frank back to flat for step 13. A close on the buffer alone lands a
    # rounding short once interest has accrued, which is what `closeWithTopUp`
    # is for; step 13 exercises that path on purpose, this is only cleanup.
    short12 = num(call(C["earnRouter"], "closeShortfall(address,address)(uint256)", ADDR["frank"], A["TSLA"]))
    if short12 == 0:
        send("frank", C["earnRouter"], "close(address)", A["TSLA"])
    else:
        cap12 = short12 + short12 // 100 + 10_000
        send("frank", T["USDG"], "approve(address,uint256)", C["earnRouter"], str(cap12))
        send("frank", C["earnRouter"], "closeWithTopUp(address,uint256)", A["TSLA"], str(cap12))
    # The reopen has to come from the keeper, not from us. `pushRedStone`
    # refuses to write a ticker whose status says closed, so RedStone cannot
    # lift its own freeze; if the relay skips it here the market stays shut
    # for good. Reopening by hand in this test is what hid that for a while.
    if MODE == "fork":
        # The relay has to carry an observation newer than the close, and on a
        # fork the clock only moves when told to.
        cast("rpc", "evm_increaseTime", "30")
        cast("rpc", "evm_mine")
    keeper("prices")
    ok(num(call(A["TSLA"], "MAX_LTV()(uint256)")) == 3_000,
       "the keeper relay reopened the session on its own, weekday terms are back")
    push("TSLA", p0, is_open=True)  # back to the scenario's baseline price

    step("13. Frank: Earn, soft deleverage, recovery, close with a wallet top-up")
    # Its own approval rather than whatever step 12 happened to leave behind.
    send("frank", T["wTSLAx"], "approve(address,uint256)", C["earnRouter"], str(10 * E18))
    send("frank", C["earnRouter"], "open(address,uint256,uint256)", A["TSLA"], str(10 * E18), "2500")
    f = earn_pos("frank")
    ok(f["debt"] > 0, f"Frank borrowed {f['debt'] / E6:.2f} USDG")
    walk("TSLA", p0 * 715 // 1000)
    keeper("protection")
    f = earn_pos("frank")
    ok(abs(f["hf"] - 14 * RAY // 10) < RAY // 100 and f["collateral"] == 10 * E18,
       f"soft-deleveraged to HF {f['hf'] / RAY:.3f}, stock untouched")
    walk("TSLA", p0)
    short = num(call(C["earnRouter"], "closeShortfall(address,address)(uint256)", ADDR["frank"], A["TSLA"]))
    cap = short + short // 100 + 10_000  # 1% + 0.01 USDG of slack for accrual
    before = usdg("frank")
    send("frank", T["USDG"], "approve(address,uint256)", C["earnRouter"], str(cap))
    send("frank", C["earnRouter"], "closeWithTopUp(address,uint256)", A["TSLA"], str(cap))
    ok(wtsla("frank") >= 10 * E18, f"Frank closed: 10 wTSLAx back, topped up {short / E6:.4f} USDG "
       f"(wallet {before / E6:.2f} -> {usdg('frank') / E6:.2f})")

    step("14. Grace: Earn, Amplify stacked on it, unstack, close")
    send("grace", T["wTSLAx"], "approve(address,uint256)", C["earnRouter"], str(10 * E18))
    send("grace", C["earnRouter"], "open(address,uint256,uint256)", A["TSLA"], str(10 * E18), "2500")
    g = earn_pos("grace")
    send("grace", C["amplifyRouter"], "openFromEarn(uint256)", "20000")
    amp = amp_pos("grace")
    # Same arithmetic as step 4: the loop borrows the buffer's CAPO value, and
    # what it borrows is counted at that rate too once it is back in the vault.
    live, capped = capo()
    fair = g["freeValue"] + amp["debt"] * capped // live
    ok(g["freeValue"] * 97 // 100 <= amp["debt"] <= g["freeValue"] * 1005 // 1000
       and abs(amp["exposure"] - fair) <= fair // 200,
       f"stacked 2x: borrowed {amp['debt'] / E6:.2f} on a {g['freeValue'] / E6:.2f} buffer, "
       f"exposure {amp['exposure'] / E6:.2f}")
    send("grace", C["amplifyRouter"], "close(bool)", "true")
    acct = g["account"]
    buffer_back = num(call(acct, "redeemableUsdg()(uint256)"))
    ok(num(call(C["sagUSD"], "balanceOf(address)(uint256)", ADDR["grace"])) == 0 and buffer_back > g["debt"] * 99 // 100,
       f"Amplify closed, equity back in the Earn buffer ({buffer_back / E6:.2f} USDG), nothing leaked to the wallet")
    short = num(call(C["earnRouter"], "closeShortfall(address,address)(uint256)", ADDR["grace"], A["TSLA"]))
    if short == 0:
        send("grace", C["earnRouter"], "close(address)", A["TSLA"])
    else:
        cap = short + short // 100 + 10_000
        send("grace", T["USDG"], "approve(address,uint256)", C["earnRouter"], str(cap))
        send("grace", C["earnRouter"], "closeWithTopUp(address,uint256)", A["TSLA"], str(cap))
    ok(wtsla("grace") >= 10 * E18, f"Grace closed Earn on her own buffer: 10 wTSLAx back (top-up {short / E6:.4f})")

    step("15. Buy and Earn: one transaction buys the stock and opens the position")
    dex = C.get("testDexRouter")
    if not dex:
        ok(True, "skipped: no swap router on this deployment")
    else:
        price = num(call(A["TSLA"], "wrapperPrice()(uint256)"))
        spend = 300 * E6
        wtsla_before = wtsla("erin")
        send("erin", T["USDG"], "faucet(address,uint256)", ADDR["erin"], str(spend))
        send("erin", T["USDG"], "approve(address,uint256)", C["zapRouter"], str(spend))
        # calldata the app would get from the OKX aggregator on mainnet; on
        # testnet the stand-in router prices at the oracle minus 0.3%.
        data = subprocess.check_output(
            ["cast", "calldata", "swap(address,uint256,uint256)", T["wTSLAx"], str(spend), str(price)],
            text=True).strip()
        min_out = (spend * 10**18 // price) * 99 // 100
        send("erin", C["zapRouter"], "buyAndEarn(uint256,address,address,bytes,address,uint256,uint256)",
             str(spend), dex, dex, data, A["TSLA"], str(min_out), "2500")
        p = earn_pos("erin")
        ok(p["collateral"] >= min_out and p["debt"] > 0 and wtsla("erin") == wtsla_before,
           f"bought {p['collateral'] / E18:.6f} wTSLAx with {spend / E6:.0f} USDG and opened at 25% LTV "
           f"(debt {p['debt'] / E6:.2f}, HF {p['hf'] / RAY:.3f}), nothing left in the wallet")

    step("16. Agents: the stock goes up, the position follows, the yield becomes stock")
    acct = earn_pos("frank")["account"] if earn_pos("frank")["debt"] else None
    # Frank closed his position in step 13, so use a fresh one for the agents.
    send("frank", T["wTSLAx"], "faucet(address,uint256)", ADDR["frank"], str(10 * E18)) if MODE == "testnet" else None
    send("frank", T["wTSLAx"], "approve(address,uint256)", C["earnRouter"], str(10 * E18))
    send("frank", C["earnRouter"], "open(address,uint256,uint256)", A["TSLA"], str(10 * E18), "2500")
    f = earn_pos("frank")
    acct = f["account"]
    target = num(call(acct, "targetLtvBps(address)(uint256)", A["TSLA"]))
    ok(2_450 <= target <= 2_550, f"the account remembers the level the user picked ({target / 100:.0f}% LTV)")

    p0_now, _, _ = feed("TSLA")
    walk("TSLA", p0_now * 12 // 10)  # the stock gains 20%
    debt_before = f["debt"]
    send("buyer", acct, "rebalance(address)", A["TSLA"])  # anyone can run the agent
    f = earn_pos("frank")
    ok(f["debt"] > debt_before and abs(f["debt"] - f["value"] // 4) < f["value"] // 200,
       f"agent borrowed the difference: debt {debt_before / E6:.2f} -> {f['debt'] / E6:.2f} USDG, back at 25%")

    dex = C.get("testDexRouter")
    if dex:
        stock_before = f["collateral"]
        _fund_yield = 200 * E6
        send("admin", T["USDG"], "faucet(address,uint256)", ADDR["admin"], str(_fund_yield))
        send("admin", T["USDG"], "transfer(address,uint256)", C["queue"], str(_fund_yield))
        send("admin", C["queue"], "settleYield(uint256)", str(_fund_yield))
        profit = (num(call(acct, "redeemableUsdg()(uint256)")) - earn_pos("frank")["debt"]) * 999 // 1000
        if profit > E6:
            price = num(call(A["TSLA"], "wrapperPrice()(uint256)"))
            data = subprocess.check_output(
                ["cast", "calldata", "swap(address,uint256,uint256)", T["wTSLAx"], str(profit), str(price)],
                text=True).strip()
            send("buyer", acct, "compoundIntoStock(address,uint256,address,address,bytes,uint256)",
                 A["TSLA"], str(profit), dex, dex, data, str(profit * 10**18 // price * 98 // 100))
            grown = earn_pos("frank")["collateral"]
            ok(grown > stock_before,
               f"the vault yield came back as stock: {stock_before / E18:.6f} -> {grown / E18:.6f} wTSLAx")
        else:
            ok(True, f"no yield surplus to compound yet ({profit / E6:.2f} USDG)")
    walk("TSLA", p0_now)

    step("17. OKX rail: deposit the base xStock, close back to it")
    base = call(T["wTSLAx"], "asset()(address)")
    if MODE == "testnet":
        send("buyer", base, "faucet(address,uint256)", ADDR["buyer"], str(5 * E18))
    else:
        # The base xStock keeps balances at slot 263 (the wrappers use 101).
        key = subprocess.check_output(["cast", "index", "address", ADDR["buyer"], "263"], text=True).strip()
        cast("rpc", "anvil_setStorageAt", base, key, "0x" + format(5 * E18, "064x"))
    base_before = num(call(base, "balanceOf(address)(uint256)", ADDR["buyer"]))
    send("buyer", base, "approve(address,uint256)", C["earnRouter"], str(5 * E18))
    send("buyer", C["earnRouter"], "openWithBase(address,uint256,uint256)", A["TSLA"], str(5 * E18), "2500")
    p = earn_pos("buyer")
    ok(p["collateral"] > 0 and p["debt"] > 0,
       f"deposited 5 base xStock straight from the OKX rail: {p['collateral'] / E18:.6f} wrapped, "
       f"debt {p['debt'] / E6:.2f} USDG")
    short = num(call(C["earnRouter"], "closeShortfall(address,address)(uint256)", ADDR["buyer"], A["TSLA"]))
    if short:
        cap = short + short // 100 + 10_000
        send("buyer", T["USDG"], "approve(address,uint256)", C["earnRouter"], str(cap))
        send("buyer", C["earnRouter"], "closeToBaseWithTopUp(address,uint256)", A["TSLA"], str(cap))
    else:
        send("buyer", C["earnRouter"], "closeToBase(address)", A["TSLA"])
    back = num(call(base, "balanceOf(address)(uint256)", ADDR["buyer"]))
    ok(back >= base_before - 10,
       f"closed back into the base token ({back / E18:.6f}), the form an OKX deposit takes")

    step("18. Dave withdraws with interest")
    before = usdg("dave")
    send("dave", C["pool"], "redeem(uint256,address,address)", str(dave_shares), ADDR["dave"], ADDR["dave"])
    got = usdg("dave") - before
    ok(got >= 1_000 * E6, f"Dave redeemed {got / E6:.6f} USDG for 1,000 supplied")


if __name__ == "__main__":
    main()

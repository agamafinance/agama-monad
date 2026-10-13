#!/usr/bin/env python3
"""The user path on Monad testnet itself, with real transactions and real prices.

    python3 scripts/live_check.py

A fresh wallet, funded with a little MON by the deployer (.keys/deployer.json),
goes through what the app offers, at the live Chainlink price, and every step is
asserted on chain:

  1. faucet: USDC and the stocks, from the stand-ins' own faucets
  2. Lend: 1,000 USDC supplied to the Arrow pool
  3. Earn: 5 wTSLAx pledged in the Arrow pool, USDC borrowed into the vault
  4. Agents: a position on target, `rebalance` refuses to move it
  5. Earn closed: the 5 wTSLAx back
  6. Buy and Earn: USDC buys NVDAx on Kuru's book, the position opens in the same tx
  7. Amplify: 10 AAPLx, USDC borrowed and spent on Kuru's book for more AAPLx
  8. Amplify closed: stock sold on Kuru to repay, AAPLx back in the wallet
  9. Lend withdrawn

No price is written: the crash, liquidation and closed-session paths need
prices moved at will, and run on a fork (scripts/e2e.py fork), never here.
"""

import json
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RPC = os.environ.get("RPC_URL", "https://testnet-rpc.monad.xyz")
EXPLORER = "https://testnet.monadvision.com/tx/"
DEP = json.load(open(os.path.join(ROOT, "deployments", "10143.json")))
C, A, T, K = DEP["contracts"], DEP["adapters"], DEP["tokens"], DEP["kuru"]
E18, E6, BPS = 10**18, 10**6, 10_000
HOP = "(uint256,address,address,bytes,uint256)[]"

checks = 0


def cast(*args):
    out = subprocess.run(["cast", *args, "--rpc-url", RPC], capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip().splitlines()[-1] if out.stderr else "cast failed")
    return out.stdout.strip()


def calldata(sig, *args):
    return subprocess.run(["cast", "calldata", sig, *args], capture_output=True, text=True,
                          check=True).stdout.strip()


def num(s):
    return int(s.split()[0])


def call(to, sig, *args):
    return cast("call", to, sig, *args)


def send(key, to, sig, *args, value=None):
    """Estimated first (Monad bills the gas limit), then sent and checked."""
    frm = subprocess.run(["cast", "wallet", "address", "--private-key", key], capture_output=True,
                         text=True, check=True).stdout.strip()
    extra = ["--value", str(value)] if value else []
    sig = [sig] if sig else []
    est = num(cast("estimate", to, *sig, *args, "--from", frm, *extra))
    for attempt in range(10):
        try:
            r = json.loads(cast("send", to, *sig, *args, *extra, "--private-key", key,
                                "--gas-limit", str(est * 13 // 10), "--json"))
            break
        except RuntimeError as e:
            # Monad checks fees against a balance a few blocks old: MON that
            # just arrived is not spendable for a second or two.
            if attempt < 9 and ("insufficient balance" in str(e) or "nonce too low" in str(e)):
                time.sleep(1)
                continue
            raise
    if r.get("status") not in ("0x1", 1, "1"):
        raise RuntimeError(f"reverted: {r.get('transactionHash')}")
    return r["transactionHash"]


def step(t):
    print(f"\n\033[1m== {t}\033[0m", flush=True)


def ok(cond, msg, tx=None):
    global checks
    if not cond:
        print(f"   \033[31mFAIL\033[0m {msg}")
        sys.exit(1)
    checks += 1
    print(f"   ok  {msg}" + (f"\n       {EXPLORER}{tx}" if tx else ""), flush=True)


def bal(token, who):
    return num(call(token, "balanceOf(address)(uint256)", who))


def price(adapter):
    """USDC (6 decimals) per wrapped share, the Chainlink price the pool uses."""
    return num(call(adapter, "wrapperPrice()(uint256)"))


def earn_pos(user, adapter):
    out = call(C["earnRouter"], "position(address,address)((address,uint256,uint256,uint256,uint256,uint256,uint256,bool,uint256))",
               user, adapter)
    f = out.strip("()").split(", ")
    return {"collateral": num(f[1]), "value": num(f[2]), "debt": num(f[3]), "hf": num(f[4])}


def main():
    deployer = json.load(open(os.path.join(ROOT, ".keys", "deployer.json")))[0]["private_key"]
    w = json.loads(subprocess.run(["cast", "wallet", "new", "--json"], capture_output=True, text=True,
                                  check=True).stdout)[0]
    key, user = w["private_key"], w["address"]
    print(f"Agama on Monad testnet, live check with a fresh wallet {user}")

    step("0. MON for gas")
    tx = send(deployer, user, "", value=2 * E18)
    ok(num(cast("balance", user)) == 2 * E18, "2 MON from the deployer", tx)

    step("1. Faucet")
    tx = send(key, T["USDC"], "faucet(address,uint256)", user, str(5_000 * E6))
    ok(bal(T["USDC"], user) == 5_000 * E6, "5,000 USDC", tx)
    tx = send(key, T["wTSLAx"], "faucet(address,uint256)", user, str(5 * E18))
    ok(bal(T["wTSLAx"], user) == 5 * E18, "5 wTSLAx, backed by the base TSLAx in the wrapper", tx)
    tx = send(key, T["wAAPLx"], "faucet(address,uint256)", user, str(10 * E18))
    ok(bal(T["wAAPLx"], user) == 10 * E18, "10 wAAPLx", tx)

    step("2. Lend: supply USDC to the Arrow pool")
    send(key, T["USDC"], "approve(address,uint256)", C["pool"], str(1_000 * E6))
    tx = send(key, C["pool"], "deposit(uint256,address)", str(1_000 * E6), user)
    lp = bal(C["pool"], user)
    ok(lp > 0, f"1,000 USDC supplied, {lp} pool shares", tx)

    step("3. Earn: pledge 5 wTSLAx in the Arrow pool, borrow USDC into the vault")
    p = price(A["TSLA"])
    send(key, T["wTSLAx"], "approve(address,uint256)", C["earnRouter"], str(5 * E18))
    tx = send(key, C["earnRouter"], "open(address,uint256,uint256)", A["TSLA"], str(5 * E18), "2000")
    pos = earn_pos(user, A["TSLA"])
    want = 5 * p * 20 // 100
    ok(pos["collateral"] == 5 * E18, f"5 wTSLAx pledged at ${p / E6:.2f} (Chainlink)", tx)
    ok(abs(pos["debt"] - want) * 100 <= want, f"borrowed {pos['debt'] / E6:.2f} USDC at 20% LTV, health {pos['hf'] / 1e27:.2f}")
    account = call(C["factory"], "accountOf(address)(address)", user)

    step("4. Agents: on target, nothing to do")
    try:
        call(account, "rebalance(address)(int256)", A["TSLA"])
        moved = True
    except RuntimeError:
        moved = False
    ok(not moved, "rebalance refuses a position already on target (anyone may call it)")

    step("5. Earn closed")
    send(key, T["USDC"], "approve(address,uint256)", C["earnRouter"], str(10 * E6))
    tx = send(key, C["earnRouter"], "closeWithTopUp(address,uint256)", A["TSLA"], str(10 * E6))
    ok(bal(T["wTSLAx"], user) == 5 * E18 and earn_pos(user, A["TSLA"])["debt"] == 0,
       "the 5 wTSLAx back, no debt left", tx)

    step("6. Buy and Earn: USDC buys NVDAx on Kuru, the position opens in the same tx")
    pn = price(A["NVDA"])
    spend = 300 * E6
    min_out = spend * E18 // pn * 97 // 100
    data = calldata("buy(address,uint256,uint256)", T["wNVDAx"], str(spend), str(min_out))
    book = K["NVDA"]
    before = call(book, "bestBidAsk()(uint256,uint256)").split()
    send(key, T["USDC"], "approve(address,uint256)", C["zapRouter"], str(spend))
    tx = send(key, C["zapRouter"], "buyAndEarn(uint256,address,address,bytes,address,uint256,uint256)",
              str(spend), K["venue"], K["venue"], data, A["NVDA"], str(min_out), "2000")
    pos = earn_pos(user, A["NVDA"])
    ok(pos["collateral"] >= min_out, f"bought {pos['collateral'] / E18:.4f} wNVDAx on the book "
       f"(ask {int(before[2]) / E18:.2f}, oracle {pn / E6:.2f}) and borrowed {pos['debt'] / E6:.2f} USDC", tx)
    send(key, T["USDC"], "approve(address,uint256)", C["earnRouter"], str(10 * E6))
    tx = send(key, C["earnRouter"], "closeWithTopUp(address,uint256)", A["NVDA"], str(10 * E6))
    ok(earn_pos(user, A["NVDA"])["debt"] == 0 and bal(T["wNVDAx"], user) >= min_out,
       f"closed, {bal(T['wNVDAx'], user) / E18:.4f} wNVDAx in the wallet", tx)

    step("7. Amplify: 10 AAPLx, borrow and buy more on Kuru")
    pa = price(A["AAPL"])
    borrow = 10 * pa * 25 // 100
    min_out = borrow * E18 // pa * 97 // 100
    data = calldata("buy(address,uint256,uint256)", T["wAAPLx"], str(borrow), str(min_out))
    send(key, T["wAAPLx"], "approve(address,uint256)", C["amplifyRouter"], str(10 * E18))
    tx = send(key, C["amplifyRouter"], f"openStock(address,uint256,{HOP})", A["AAPL"], str(10 * E18),
              f"[({borrow},{K['venue']},{K['venue']},{data},{min_out})]")
    pos = earn_pos(user, A["AAPL"])
    ok(pos["collateral"] >= 10 * E18 + min_out,
       f"{pos['collateral'] / E18:.4f} wAAPLx pledged, {pos['debt'] / E6:.2f} USDC owed, "
       f"exposure {pos['collateral'] / (10 * E18):.2f}x, health {pos['hf'] / 1e27:.2f}", tx)

    step("8. Amplify closed: sell on Kuru, repay, the stock back")
    sell = pos["debt"] * 1015 // 1000 * E18 // pa
    min_usdc = sell * pa // E18 * 97 // 100
    data = calldata("sell(address,uint256,uint256)", T["wAAPLx"], str(sell), str(min_usdc))
    tx = send(key, C["amplifyRouter"], f"closeStock(address,{HOP},bool)", A["AAPL"],
              f"[({sell},{K['venue']},{K['venue']},{data},{min_usdc})]", "false")
    left = bal(T["wAAPLx"], user)
    ok(earn_pos(user, A["AAPL"])["debt"] == 0 and left > 9 * E18,
       f"no debt, {left / E18:.4f} wAAPLx back (10 in, the spread and the interest paid)", tx)

    step("9. Lend withdrawn")
    before = bal(T["USDC"], user)
    tx = send(key, C["pool"], "redeem(uint256,address,address)", str(lp), user, user)
    got = bal(T["USDC"], user) - before
    ok(got >= 1_000 * E6 - 1, f"{got / E6:.6f} USDC back for 1,000 supplied", tx)

    print(f"\n\033[1mLIVE CHECK PASSED\033[0m, {checks} checks, wallet {user}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Compound vault yield into stock with REAL OKX aggregator calldata, on a fork.

    anvil --fork-url https://xlayerrpc.okx.com --chain-id 196 --port 8546 &
    SUPPLY_CAP_USDG=1000000 BORROW_CAP_USDG=500000 DEPLOY_FILE=196-fork.json \
      forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8546 --broadcast --private-key <anvil #0>
    python3 scripts/compound_check.py [usdg_of_yield]

The agent path that the testnet cannot prove: on testnet the swap venue is a
stand-in priced at our own oracle, so it can never disagree with us. Here the
yield is spent into the real xStock liquidity on X Layer, which is thin, and
the account's on-chain floor (stock worth at least 97% of the USDG spent, at
the pool's own price) either holds or does not.

A revert here is a result, not a failure: it would mean real execution is
worse than the floor allows and the constant needs to move.
"""

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import okx_dex  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RPC = os.environ.get("RPC_URL", "http://127.0.0.1:8546")
DEP = json.load(open(os.path.join(ROOT, "deployments", os.environ.get("DEPLOY_FILE", "196-fork.json"))))
C, T, A = DEP["contracts"], DEP["tokens"], DEP["adapters"]

ANVIL0 = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
USER_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"  # anvil #3
AGENT_KEY = "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"  # anvil #4, a stranger
YIELD = int(float(sys.argv[1]) * 10**6) if len(sys.argv) > 1 else 500 * 10**6
STOCK_IN = 10 * 10**18
# The Backed wrappers keep balances at storage slot 101 (the base xStocks use 263).
WRAPPER_SLOT = "101"


def cast(*args):
    r = subprocess.run(["cast", *args, "--rpc-url", RPC], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"cast {args[0]} {args[1] if len(args) > 1 else ''}: {r.stderr.strip()[-400:]}")
    return r.stdout.strip()


def num(s):
    return int(s.split()[0])


def addr_of(key):
    return subprocess.check_output(["cast", "wallet", "address", key], text=True).strip()


def set_token(token, holder, amount, slot):
    key = subprocess.check_output(["cast", "index", "address", holder, slot], text=True).strip()
    cast("rpc", "anvil_setStorageAt", token, key, "0x" + format(amount, "064x"))


def ensure_prices():
    feed = cast("call", C["oracle"], "feed(bytes32)((uint128,uint64,bool,bool))",
                "0x" + b"TSLA".hex().ljust(64, "0"))
    if int(feed.strip("()").split(", ")[0].split()[0]) > 0:
        return
    env = dict(os.environ, RPC_URL=RPC,
               DEPLOYMENT=os.path.join(ROOT, "deployments", os.environ.get("DEPLOY_FILE", "196-fork.json")),
               KEEPER_KEY=ANVIL0, ONCE="1", JOBS="redstone,prices")
    out = subprocess.run([sys.executable, os.path.join(ROOT, "scripts", "keeper.py")], env=env,
                         capture_output=True, text=True)
    print("   keeper |", out.stdout.strip().splitlines()[-1] if out.stdout.strip() else out.stderr[-200:])


def ensure_liquidity(admin):
    if num(cast("call", T["USDG"], "balanceOf(address)(uint256)", C["pool"])) >= 20_000 * 10**6:
        return
    set_token(T["USDG"], admin, 20_000 * 10**6, "1")
    cast("send", T["USDG"], "approve(address,uint256)", C["pool"], str(20_000 * 10**6), "--private-key", ANVIL0)
    cast("send", C["pool"], "deposit(uint256,address)", str(20_000 * 10**6), admin, "--private-key", ANVIL0)
    print("   seeded Arrow with 20,000 USDG of lender liquidity")


def main():
    admin, user, agent = addr_of(ANVIL0), addr_of(USER_KEY), addr_of(AGENT_KEY)
    print(f"user {user}\nagent (a stranger) {agent}\nyield to compound {YIELD / 1e6:.2f} USDG")
    ensure_prices()
    ensure_liquidity(admin)

    # 1. a real Earn position on real wTSLAx
    set_token(T["wTSLAx"], user, STOCK_IN, WRAPPER_SLOT)
    cast("send", T["wTSLAx"], "approve(address,uint256)", C["earnRouter"], str(STOCK_IN), "--private-key", USER_KEY)
    cast("send", C["earnRouter"], "open(address,uint256,uint256)", A["TSLA"], str(STOCK_IN), "2500",
         "--private-key", USER_KEY, "--gas-limit", "4000000")
    account = cast("call", C["factory"], "accountOf(address)(address)", user).split()[0]
    before = num(cast("call", T["wTSLAx"], "balanceOf(address)(uint256)", A["TSLA"]))
    print(f"   position open, account {account}")

    # 2. the vault earns, which is what the agent is allowed to spend
    set_token(T["USDG"], admin, YIELD, "1")
    cast("send", T["USDG"], "transfer(address,uint256)", C["queue"], str(YIELD), "--private-key", ANVIL0)
    cast("send", C["queue"], "settleYield(uint256)", str(YIELD), "--private-key", ANVIL0, "--gas-limit", "2000000")

    debt = num(cast("call", C["pool"], "getPositionScaledDebt(address,address,bytes)(uint256)",
                    A["TSLA"], account, "0x"))
    have = num(cast("call", account, "redeemableUsdg()(uint256)"))
    profit = (have - debt) * 999 // 1000  # interest accrues before inclusion
    print(f"   buffer {have / 1e6:.2f} USDG against {debt / 1e6:.2f} of debt, surplus {profit / 1e6:.2f}")
    if profit < 10**6:
        raise SystemExit("no surplus to compound, raise the yield argument")

    # 3. real aggregator calldata, built for the ACCOUNT: it is the account that
    #    holds the USDG and receives the stock, not the zap.
    q = okx_dex.quote(T["USDG"], T["wTSLAx"], str(profit))
    unit = float(q["toToken"]["tokenUnitPrice"])
    print(f"   quote: {int(q['toTokenAmount']) / 1e18:.6f} wTSLAx at ${unit:.2f}")
    spender = okx_dex.approve(T["USDG"], str(profit))["dexContractAddress"]
    tx = okx_dex.swap(T["USDG"], T["wTSLAx"], str(profit), account)["tx"]
    min_out = int(tx["minReceiveAmount"])

    # 4. anyone runs the agent
    receipt = json.loads(cast("send", account,
                              "compoundIntoStock(address,uint256,address,address,bytes,uint256)",
                              A["TSLA"], str(profit), tx["to"], spender, tx["data"], str(min_out),
                              "--private-key", AGENT_KEY, "--gas-limit", "6000000", "--json"))
    if receipt["status"] != "0x1":
        print(cast("run", receipt["transactionHash"])[-1500:])
        raise SystemExit("compoundIntoStock reverted")
    print(f"   compounded in {int(receipt['gasUsed'], 16):,} gas: {receipt['transactionHash']}")

    after = num(cast("call", T["wTSLAx"], "balanceOf(address)(uint256)", A["TSLA"]))
    added = after - before
    value = num(cast("call", A["TSLA"], "valueOf(uint256)(uint256)", str(added)))
    slippage = (profit - value) * 10_000 // profit if profit else 0
    print(f"\ncollateral grew by {added / 1e18:.6f} wTSLAx, worth {value / 1e6:.2f} USDG "
          f"for {profit / 1e6:.2f} spent ({slippage / 100:.2f}% off the oracle)")
    assert added > 0, "no stock was added"
    assert value * 10_000 >= profit * 9_700, "the on-chain floor should have refused this"
    print("\033[1mCOMPOUND CHECK PASSED (real OKX liquidity, agent run by a stranger)\033[0m")


if __name__ == "__main__":
    main()

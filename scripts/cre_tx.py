#!/usr/bin/env python3
"""What the CRE workflow did on Monad: the oracles now, and what a tx carried.

  python3 scripts/cre_tx.py          the ten oracles, read through AgamaKeeperLens
  python3 scripts/cre_tx.py <tx>     a report delivered to AgamaCREReceiver, decoded

RPC_URL picks the chain (default Monad testnet, an anvil fork works too).
"""
import json, os, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RPC = os.environ.get("RPC_URL", "https://testnet-rpc.monad.xyz")
DEP = json.load(open(os.path.join(ROOT, "deployments", "10143.json")))
C = DEP["contracts"]
NAMES = {C["oracle"].lower(): "stock oracle", C["goldOracle"].lower(): "gold oracle"}
KINDS = ["liquidate", "soft-deleverage", "rebalance", "compound", "snapshot"]


def cast(*a):
    return subprocess.run(["cast", *a, "--rpc-url", RPC], capture_output=True, text=True, check=True).stdout.strip()


def topic(sig):
    return subprocess.run(["cast", "keccak", sig], capture_output=True, text=True, check=True).stdout.strip()


def oracles():
    out = cast("call", C["creLens"], "feeds()((bytes32,address,uint128,uint64,bool)[])")
    now = time.time()
    print(f"  {'market':<8}{'price (USD)':>14}{'stored':>14}   session")
    for t, _o, p, at, op in re.findall(r"\((0x[0-9a-f]+), (0x[0-9a-fA-F]+), (\d+)[^,]*, (\d+)[^,]*, (true|false)\)", out):
        age = int(now - int(at))
        name = bytes.fromhex(t[2:]).rstrip(b"\0").decode()
        print(f"  {name:<8}{int(p) / 1e18:>14,.2f}{f'{age // 60}m{age % 60:02d}s ago':>14}   {'open' if op == 'true' else 'closed'}")


def tx(h):
    r = json.loads(cast("receipt", h, "--json"))
    ps, jd, rh = topic("PriceStored(address,uint256)"), topic("JobDone(uint8,address,address)"), \
        topic("ReportHandled(bytes32,uint256,uint256,uint256,uint256)")
    print("  status   ", "success" if r["status"] in ("0x1", 1) else "reverted")
    print("  from     ", r["from"], "(any funded key, no role)")
    print("  to       ", r["to"], "(Chainlink forwarder)")
    for l in r["logs"]:
        if l["address"].lower() != C["creReceiver"].lower():
            continue
        t = l["topics"][0]
        if t == ps:
            o = "0x" + l["topics"][1][-40:]
            print("  PriceStored  ", NAMES.get(o, o), "(verified by Chainlink's VerifierProxy)")
        elif t == jd:
            print("  JobDone      ", KINDS[int(l["topics"][1], 16)], "on", "0x" + l["topics"][3][-40:])
        elif t == rh:
            d = l["data"][2:]
            v = [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]
            print(f"  ReportHandled prices={v[0]} stored={v[1]} jobs={v[2]} done={v[3]}")


if __name__ == "__main__":
    tx(sys.argv[1]) if len(sys.argv) > 1 else oracles()

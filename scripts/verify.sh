#!/usr/bin/env bash
# Verify every contract of a deployment on the OKLink X Layer explorer.
#   ./scripts/verify.sh 1952   (testnet)   |   ./scripts/verify.sh 196   (mainnet)
# Constructor arguments are recovered from the broadcast (creation input minus
# the compiled bytecode), which OKLink needs explicitly.
set -uo pipefail
cd "$(dirname "$0")/.."
CHAIN=${1:-1952}
case $CHAIN in
  196) SHORT=XLAYER; SCRIPT=Deploy.s.sol ;;
  1952) SHORT=XLAYER_TESTNET; SCRIPT=DeployTestnet.s.sol ;;
  *) echo "unknown chain $CHAIN"; exit 1 ;;
esac
URL="https://www.oklink.com/api/v5/explorer/contract/verify-source-code-plugin/$SHORT"
RUN="broadcast/$SCRIPT/$CHAIN/run-latest.json"
forge build >/dev/null

python3 - "$RUN" <<'PY' > /tmp/verify_targets.txt
import glob, json, sys
run = json.load(open(sys.argv[1]))
for tx in run["transactions"]:
    name = tx.get("contractName")
    if tx["transactionType"] != "CREATE" or not name:
        continue
    art = glob.glob(f"out/*/{name}.json")
    if not art:
        continue
    code = json.load(open(art[0]))["bytecode"]["object"].removeprefix("0x")
    init = tx["transaction"]["input"].removeprefix("0x")
    args = init[len(code):] if init.startswith(code[:200]) else ""
    print(tx["contractAddress"], name, args or "-")
PY

pass=0; fail=0
while read -r addr name args; do
  path=$(grep -rlE "^contract $name( |$)" src | head -1)
  [ -z "$path" ] && { echo "skip $name"; continue; }
  extra=(--compiler-version 0.8.26); [ "$args" != "-" ] && extra+=(--constructor-args "0x$args")
  if forge verify-contract "$addr" "$path:$name" --verifier oklink --verifier-url "$URL" \
       --chain "$CHAIN" "${extra[@]}" --watch 2>&1 | grep -qE "successfully verified|already verified"; then
    echo "verified  $name $addr"; pass=$((pass+1))
  else
    echo "FAILED    $name $addr"; fail=$((fail+1))
  fi
done < /tmp/verify_targets.txt
echo "done: $pass verified, $fail failed"

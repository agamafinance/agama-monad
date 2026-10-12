#!/usr/bin/env bash
# Put X Layer Testnet back in step with the source, in one command.
#
#   ./scripts/testnet-refresh.sh
#
# Redeploys the whole stack, seeds it, pushes a first price, verifies every
# contract on OKLink, regenerates the front's ABIs and addresses, and leaves
# the keeper running. Deploying costs around 0.02 OKB, so top the deployer up
# at https://web3.okx.com/xlayer/faucet first; the script refuses to start
# otherwise rather than dying halfway through.
#
# After it finishes: deploy the front (cd web && npx vercel --prod --yes) and
# run the two end-to-end suites.
set -uo pipefail
cd "$(dirname "$0")/.."

RPC=${RPC_URL:-https://testrpc.xlayer.tech/terigon}
NEED_WEI=20000000000000000 # 0.02 OKB
KEY=$(python3 -c "import json;d=json.load(open('.keys/deployer.json'));d=d[0] if isinstance(d,list) else d;print(d['private_key'])")
ME=$(cast wallet address "$KEY")

say() { printf "\n\033[1m== %s\033[0m\n" "$1"; }

say "deployer $ME"
BAL=$(cast balance "$ME" --rpc-url "$RPC")
printf "OKB %s (need %s)\n" "$(cast from-wei "$BAL")" "$(cast from-wei $NEED_WEI)"
if [ "$BAL" -lt "$NEED_WEI" ]; then
  echo "not enough gas. Faucet: https://web3.okx.com/xlayer/faucet"
  exit 1
fi

say "stopping the keeper while the addresses move"
# It runs under launchd with KeepAlive, so killing the process is not enough:
# launchd would put it straight back, pushing prices to the old oracle.
PLIST=~/Library/LaunchAgents/com.agama.xlayer.keeper.plist
launchctl unload "$PLIST" 2>/dev/null || true
tmux kill-session -t agama-keeper 2>/dev/null || true

say "deploying"
forge script script/DeployTestnet.s.sol --rpc-url "$RPC" --broadcast --slow \
  --private-key "$KEY" | grep -E "written|ONCHAIN|Error" || true
[ -f deployments/1952.json ] || { echo "no deployments/1952.json, deploy failed"; exit 1; }

say "first prices"
RPC_URL="$RPC" DEPLOYMENT=deployments/1952.json KEEPER_KEY="$KEY" ONCE=1 \
  JOBS=redstone,prices python3 -u scripts/keeper.py

say "verifying on OKLink"
./scripts/verify.sh 1952 | tail -3

say "regenerating the front's ABIs and addresses"
(cd web && node scripts/sync-xlayer.mjs)

say "keeper"
launchctl load "$PLIST" 2>/dev/null || tmux new -d -s agama-keeper \
  "./scripts/run-keeper.sh testnet > /tmp/agama-keeper.log 2>&1"
sleep 25
tail -3 /tmp/agama-keeper.log 2>/dev/null || echo "(keeper starting)"

cat <<'NEXT'

Next, in order:
  cd web && npx vercel --prod --yes     # the front, with the new addresses
  python3 scripts/e2e.py testnet        # 18 steps, real transactions
  python3 scripts/ui_e2e.py             # the browser, on the live app
  git add deployments web/lib/xlayer/generated broadcast && git commit
NEXT

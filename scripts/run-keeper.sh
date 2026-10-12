#!/usr/bin/env bash
# Long-running keeper for a deployment. Reads the key from .keys/ at runtime
# (never on the command line). Meant to run in tmux:
#   tmux new -d -s agama-keeper './scripts/run-keeper.sh testnet'
set -euo pipefail
cd "$(dirname "$0")/.."
NET=${1:-testnet}
case $NET in
  testnet) export RPC_URL=https://testrpc.xlayer.tech/terigon DEPLOYMENT=deployments/1952.json ;;
  mainnet) export RPC_URL=https://xlayerrpc.okx.com DEPLOYMENT=deployments/196.json ;;
  *) echo "usage: $0 testnet|mainnet"; exit 1 ;;
esac
KEEPER_KEY=$(python3 -c "import json;d=json.load(open('.keys/deployer.json'));d=d[0] if isinstance(d,list) else d;print(d['private_key'])")
export KEEPER_KEY INTERVAL=${INTERVAL:-300}
[ -f .env ] && set -a && . ./.env && set +a   # DS_API_KEY / DS_API_SECRET when available
exec python3 -u scripts/keeper.py

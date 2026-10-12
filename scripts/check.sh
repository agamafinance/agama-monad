#!/usr/bin/env bash
# Everything CI runs, in the same order, before pushing.
#
#   ./scripts/check.sh
#
# CI is the wrong place to find out that `forge fmt` had an opinion, and a red
# run mails everyone. These are the same five steps as
# .github/workflows/test.yml, so a green run here is a green run there.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
log=$(mktemp)

run() {
  local name=$1
  shift
  printf "%-18s" "$name"
  if "$@" >"$log" 2>&1; then
    printf "\033[32mok\033[0m\n"
  else
    printf "\033[31mFAILED\033[0m\n"
    sed 's/^/   | /' "$log" | tail -30
    fail=1
  fi
}

# `forge fmt`, not `--check`: formatting is not a decision worth a round trip.
# It rewrites in place and what it touched goes in the same commit as the code.
run "forge fmt" forge fmt
run "forge build" forge build --sizes
run "forge test" forge test
run "typecheck" bash -c 'cd web && pnpm typecheck'
run "front build" bash -c 'cd web && pnpm build'
rm -f "$log"

dirty=$(git status --porcelain)
if [ -n "$dirty" ]; then
  printf "\nuncommitted (forge fmt rewrites in place, so this can be its work):\n%s\n" "$dirty"
fi

if [ "$fail" = 0 ]; then
  printf "\n\033[1mall green, safe to push\033[0m\n"
else
  printf "\n\033[1;31mred, do not push\033[0m\n"
fi
exit "$fail"

#!/usr/bin/env bash
# What CI will see, before it sees it: clones the committed HEAD (nothing
# uncommitted, nothing ignored), installs the front from its lockfile and runs
# scripts/check.sh there. Green here is green on GitHub.
#
#   ./scripts/prepush.sh && git push
set -euo pipefail
src=$(cd "$(dirname "$0")/.." && pwd)
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
git clone -q --recurse-submodules "$src" "$dir"
cd "$dir"
(cd web && pnpm install --frozen-lockfile >/dev/null)
forge fmt --check
./scripts/check.sh

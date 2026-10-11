#!/usr/bin/env bash
# build_configs.sh [outroot] -- export each qualification configuration from its git commit
# (git archive: no worktree is touched) and build the production image + packages + budget.
# Usage: tools/qual/build_configs.sh ~/2068-Leap-study/qual-builds
set -euo pipefail
root="${1:-$HOME/2068-Leap-study/qual-builds}"
repo="$(git -C "$(dirname "$0")" rev-parse --git-common-dir)/.."
declare -A CFG=( [baseline]=7ae0599 [essential]=study/combined-essential [enhanced]=study/combined-enhanced )
# extra configurations: name=ref arguments after the root (e.g. costs-ess=study/qualification-costs)
shift || true
if [ $# -gt 0 ]; then unset CFG; declare -A CFG; for kv in "$@"; do CFG[${kv%%=*}]=${kv#*=}; done; fi
for name in "${!CFG[@]}"; do
  [ -n "${ONLY:-}" ] && [ "$ONLY" != "$name" ] && continue
  ref="${CFG[$name]}"
  sha=$(git -C "$repo" rev-parse --short "$ref")
  d="$root/$name"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$repo" archive "$ref" | tar -x -C "$d"
  echo "$sha $ref" > "$d/QUAL_COMMIT"
  ( cd "$d" && mkdir -p build && make build v2-packages > build/qual_build.log 2>&1 && make budget > build/qual_budget.log 2>&1 ) \
     || { echo "BUILD FAILED $name"; tail -20 "$d/build/qual_build.log"; exit 1; }
  echo "== $name ($sha $ref)"; grep -E "^(Home|EXROM|HOME)" "$d/build/qual_budget.log" | head -4
done

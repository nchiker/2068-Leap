#!/bin/bash
# Apply one Phase 2B prototype to a SCRATCH worktree and print the ROM budget.
#   usage: WT=/path/to/scratch/worktree tools/spikes/r10_9_phase2b/build.sh mk_fullopt.py copt
# The worktree is reset first (git checkout / clean of rom include tools), so give it a
# disposable `git worktree add --detach <dir> 2aff9b2`.  Never point WT at the real tree.
set -e
: "${WT:?set WT to a disposable git worktree}"
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$WT"
git checkout -q -- .
git clean -fdq rom include tools 2>/dev/null || true
[ -n "$1" ] && python3 "$HERE/$1" "$WT" "${@:2}"
make budget 2>&1 | grep -E "error|Error|free:|arrstore|HOME ROM|EXROM" | grep -v "^Pass"

#!/usr/bin/env bash
# measure.sh <srcdir>: rsync tree (no .git/build) to a scratch dir, build, print HOME/EXROM free bytes.
src="$1"; scratch="${2:-$CLAUDE_JOB_DIR/tmp/scratch-measure}"
mkdir -p "$scratch"; rsync -a --delete --exclude .git --exclude build "$src"/ "$scratch"/ 
cd "$scratch" && mkdir -p build && make budget 2>&1 | grep -E "^(Home|EXROM)|rror"

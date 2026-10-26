#!/usr/bin/env bash
# Reproducible build check (docs/V2_LEAPC_BACKPORT_PLAN.md item 0.9; after 2068-Leap-C's
# tools/check_repro.sh). Builds the working tree twice, in two fresh copies at different paths, and
# requires identical hashes for the release ROM images and the package images and tapes. The working
# tree's own build/ is never touched.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for n in 1 2; do
    mkdir "$tmp/tree$n"
    rsync -a --exclude .git --exclude build ./ "$tmp/tree$n/"
    ( cd "$tmp/tree$n" && make build v2-packages >"$tmp/build$n.log" 2>&1 ) \
        || { echo "reproducible: build $n FAILED (log follows)" >&2; tail -20 "$tmp/build$n.log" >&2; exit 1; }
    ( cd "$tmp/tree$n/build" && sha256sum test_basic.bin exrom.bin exrom.dck ts2068rom_zesarux.bin \
        v2_package_*.bin extensions/*.tzx ) >"$tmp/sums$n"
done
if cmp -s "$tmp/sums1" "$tmp/sums2"; then
    echo "reproducible: OK ($(wc -l <"$tmp/sums1") files)"; cat "$tmp/sums1"
else
    echo "reproducible: FAILED" >&2; diff "$tmp/sums1" "$tmp/sums2" >&2 || true; exit 1
fi

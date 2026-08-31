#!/usr/bin/env bash
set -euo pipefail

log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

set +e
sjasmplus "$@" 2>&1 | tee "$log_file"
assembler_rc=${PIPESTATUS[0]}
set -e

if [ "$assembler_rc" -ne 0 ]; then
    exit "$assembler_rc"
fi

if grep -Eq 'warning: Negative BLOCK|warning\[shortblock\]' "$log_file"; then
    echo "sjasmplus_strict: refusing truncated/overflowed image" >&2
    exit 1
fi

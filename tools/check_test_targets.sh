#!/usr/bin/env bash
# Guard: the default `make test` (and `make check`) must never launch Fuse or
# any X11-window test. Inspects the dry-run dependency graph only; launches nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
bad='fuse|run_editor_auto_test|run_storage_named_load_test|run_demo|run_suite_test|run_all_tests\.sh|validate_showcase|run_stack_audit'
# Each dry run is captured before it is searched: piping `make -n` into `grep -q` under pipefail
# fails the pipeline whenever grep exits early and make dies of SIGPIPE (a false "lost the V1
# tests", or a missed Fuse test in the loop below).
for t in check test; do
    plan="$(make -n "$t" 2>/dev/null | grep -Eiv '^\s*#' || true)"
    if grep -Eiq "$bad" <<<"$plan"; then
        echo "check_test_targets: 'make $t' reaches a Fuse/X11 test:" >&2
        grep -Ei "$bad" <<<"$plan" >&2
        exit 1
    fi
done
legacy="$(make -n test-legacy 2>/dev/null || true)"
grep -q run_editor_auto_test <<<"$legacy" || { echo "check_test_targets: test-legacy lost the V1 tests" >&2; exit 1; }
echo "check_test_targets: ok (make test / make check are headless; V1 tests live in make test-legacy)"

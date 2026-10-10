#!/usr/bin/env bash
# Guard: the default `make test` (and `make check`) must never launch Fuse or
# any X11-window test. Inspects the dry-run dependency graph only; launches nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
bad='fuse|run_editor_auto_test|run_storage_named_load_test|run_demo|run_suite_test|run_all_tests\.sh|validate_showcase|run_stack_audit'
for t in check test; do
    if make -n "$t" 2>/dev/null | grep -Eiv '^\s*#' | grep -Eiq "$bad"; then
        echo "check_test_targets: 'make $t' reaches a Fuse/X11 test:" >&2
        make -n "$t" 2>/dev/null | grep -Eiv '^\s*#' | grep -Ei "$bad" >&2
        exit 1
    fi
done
make -n test-legacy 2>/dev/null | grep -q run_editor_auto_test || { echo "check_test_targets: test-legacy lost the V1 tests" >&2; exit 1; }
echo "check_test_targets: ok (make test / make check are headless; V1 tests live in make test-legacy)"

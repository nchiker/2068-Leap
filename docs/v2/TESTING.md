# Test targets (read before running anything)

| Command | What it runs | Launches Fuse / X11? |
|---|---|---|
| `make check` | assemble/lint of every build, doc and fixture checks, `tools/check_test_targets.sh` | **No** |
| `make test` | **default, fully headless** (ts2068-debug/ZEsarUX, no display): kernel smoke ROMs, V2 standalone component tests (`tools/run_v2_standalone_tests.sh`), production-ROM checks (`tools/v2_production_checks.py`) | **No** |
| `make test-legacy` | the V1 tests that drive a real Fuse window under X11: `run_editor_auto_test.sh` (wrap, insert) and the `run_storage_named_load_test.sh` family | **Yes** |
| `make test-all` | `test` then `test-legacy` | Yes |

**Why this exists.** `make test` used to run the V1 editor_auto and storage tests, which
open a real Fuse window. Every session that ran `make test` for V2 work therefore launched
Fuse. The fix is structural: those tests moved, unchanged, to `test-legacy`, and
`tools/check_test_targets.sh` (part of `make check`) fails if `make -n test` or
`make -n check` ever reaches a Fuse/X11 script again. Verify by hand without running
anything: `make -n test | grep -i fuse` must print nothing.

**Rules for sessions.** Use `make test` (or `tools/run_v2_standalone_tests.sh`,
`python3 tools/v2_production_checks.py`) for V2 work. Never run `make test-legacy` /
`test-all` or any `run_editor_auto_test.sh` / `run_storage_named_load_test.sh` unless the
user asks. Do not use `pkill -f` (it kills the invoking shell).

# Test targets (read before running anything)

| Command | What it runs | Launches Fuse / X11? |
|---|---|---|
| `make check` | assemble/lint of every build, doc and fixture checks, `tools/check_test_targets.sh` | **No** |
| `make test` | **default, fully headless** (ts2068-debug/ZEsarUX, no display): kernel smoke ROMs, V2 standalone component tests (`tools/run_v2_standalone_tests.sh`), production-ROM checks (`tools/v2_production_checks.py`), FILL checks, and (R10.9) the production-ROM regression gate + strict known-defect suite (`tools/run_v2_prod_tests.sh`) | **No** |
| `make test-prod` | only the last item above | **No** |
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

## Production-ROM regression gate and known-defect suite (R10.9 Phase 1)

`tools/run_v2_prod_tests.sh` (`make test-prod`, also part of `make test`) runs two suites
concurrently on the **real production image** (`build/ts2068rom_zesarux.bin`, HOME + EXROM as
shipped) and prints both logs. Library: `tools/v2_prod.py`; tape synthesiser:
`tools/tape_synth.py`; package-ABI reader: `tools/v2_abi.py`.

| Suite | File | Meaning of a result |
|---|---|---|
| **Gate** | `tools/v2_prod_regress.py` | every case must `PASS`. Editor key path, command dispatch, real tape LOAD/VERIFY/SAVE, all five packages, display-mode return, package ABI 2.0 (`abi-*`) |
| **Known defects** | `tools/v2_known_defects.py` | each case asserts the *correct* behaviour. `XFAIL` = a documented R10.8 defect reproduced (expected, exit 0). `PASS` = a positive control. `FAIL` = unexpected failure (exit 1). `XPASS` = a case marked as a known defect now behaves correctly (exit 1): the defect was fixed, so drop the `xfail=` marker and the case becomes a gate test |

An XFAIL line is **not** a pass: the summary line counts them separately, and `docs/v2/
R10_9_PHASE1_REPORT.md` lists each with the R10.8 finding it demonstrates.

**What is real, what is substituted.** Real production code: the ISR key latch
(`KBD_LASTK/KBD_KEYHIT`) → `IO_READ_KEY` → editor → `V2_COMMAND_LOOP` → `V2_DISPATCH` →
compiler → VM; `STORAGE_LOAD`/`STORAGE_RECEIVE_BLOCK` reading the EAR line through port `$FE`;
`V2_SAVE` up to the transport; the package entry and `OP_CALL_EXT` with EXROM paged out.
Substituted: (1) the EAR signal is a synthesised pulse train played through ZEsarUX "real tape"
(raw 8-bit samples at 15,600 Hz, ±226 T edge quantisation) — not analogue cassette audio;
(2) `STORAGE_SEND_BLOCK` is intercepted at its call site (arguments captured, the call skipped) —
SAVE's *output pulses* are not generated; (3) SPACE during LOAD is injected by forcing bit 0 of the
single `in a,($FE)` at the receiver's edge sampler to read low; (4) the key latch is poked
directly, so physical matrix scanning/debounce/auto-repeat are not exercised; (5) packages are
usually installed by copying the image to `$F400` and calling the real entry (the tape path is
tested separately by `abi-pkg-*`); (6) tests call `V2_RUN_STORED`/`V2_DISPATCH`/`V2_LOAD`
directly with state in RAM where typing would only add time. **Never** substituted: HOME/EXROM
code, banking, the compiler/VM, the storage state machine.

**Cannot be tested without hardware** (see the Phase 1 report §6 for the full list): analogue
cassette levels/dropouts/wow, real recorder SAVE→LOAD, physical keyboard feel and key loss,
BREAK keycap matrix position, display contention timing and flicker, ULAplus/hi-res on a real
machine, AY audio, printer output, EXROM/Dock paging on real hardware.

**Adding a case.** Gate: `@case("id", "title")` in `tools/v2_prod_regress.py`, returning
`(ok, detail)`. Known defect: the same with `xfail="Dn: reason"` — write the *correct* behaviour as
the assertion, never the broken one. Use `P.boot()`, `P.key()/type_text()`, `P.put_store()`,
`P.call_prompt(routine)`, `P.tape_op(tape, …)`; each case boots a fresh machine (≈ 2 s).
Isolate a manual run from `make test` with `TS2068_DEBUG_STATE_DIR=<dir> TS2068_V2_PORT=<port>`.

**Package ABI.** `make check` runs `tools/check_package_abi.py` (see `docs/v2/PACKAGE_ABI.md` §8).

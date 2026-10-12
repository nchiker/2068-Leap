# Test targets (read before running anything)

| Command | What it runs | Launches Fuse / X11? |
|---|---|---|
| `make check` | assemble/lint of every build, doc and fixture checks, `tools/check_test_targets.sh` | **No** |
| `make test` | **default, fully headless** (ts2068-debug/ZEsarUX, no display): kernel smoke ROMs, V2 standalone component tests (`tools/run_v2_standalone_tests.sh`), production-ROM checks (`tools/v2_production_checks.py`), FILL checks, (R10.9) the production-ROM regression gate + strict known-defect suite (`tools/run_v2_prod_tests.sh`), `make qual`, and the maintenance suites (`make qual-maint`) | **No** |
| `make qual-maint` | the maintenance-release suites (`tools/maint/run_maint_qual.sh`): AY `BEEP`, `SOUND` 0..16, the shared frame wait (BREAK during `BEEP`/`PAUSE`, the `PAUSE` rollover), the cbeep package (pitch/length model, timing, border, errors, real tape LOAD) and `PAUSE`/`BEEP`/`CBEEP` with the frame interrupt unavailable; also the last step of `make test` | **No** |
| `make test-prod` | only the last item above (production gate, Array Store gate and known-defect suite, concurrently) | **No** |
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

`tools/run_v2_prod_tests.sh` (`make test-prod`, also part of `make test`) runs three suites
concurrently on the **real production image** (`build/ts2068rom_zesarux.bin`, HOME + EXROM as
shipped) and prints both logs. Library: `tools/v2_prod.py`; tape synthesiser:
`tools/tape_synth.py`; package-ABI reader: `tools/v2_abi.py`.

| Suite | File | Meaning of a result |
|---|---|---|
| **Gate** | `tools/v2_prod_regress.py` | every case must `PASS`. Editor key path, command dispatch, real tape LOAD/VERIFY/SAVE, cassette failure semantics (`D1-*`, `D2-*`, R10.9 Phase 2A), all five packages, display-mode return, package ABI 2.0 (`abi-*`), strict compilation and compile-error line (`D3-*`, `D4-*`, R10.9 Phase 2D) |
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
`in a,($FE)` at the receiver's edge sampler to read low and again at STORAGE_LOAD's own
abort-classification read (`P.press_space()`), standing in for a key that stays down for
milliseconds; (4) the key latch is poked
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

## Cassette failure semantics and array defects (R10.9 Phase 2A)

* `D1-*` / `D2-*` (LOAD / VERIFY failure semantics) were known defects in Phase 1 and are **fixed**; they are now
  gate cases in `tools/v2_prod_regress.py` and cover: dropout, truncation, wrong flag, bad checksum, SPACE abort
  (data block and header search), wrong name, wrong type, truncated header, VERIFY mismatch / prefix tape / longer
  tape / bad checksum / abort, and package-tape failure. Each asserts the message *and* the resulting state (program
  intact, or the known-safe empty state, `STORAGE_VERIFY_MODE` cleared). Policy: `docs/v2/R10_9_PHASE2A_REPORT.md` §3.
* `D12`–`D15` (DIM zero-fill, `SAVE ... ARRAY` header type, array names > 8 characters, `LOAD ... ARRAY`
  descriptor validation) were strict expected failures in Phase 2A and are **repaired in Phase 2C**: they are gate cases in
  `tools/v2_prod_arrays.py` now (see the Array Store section below).
* `P.press_space()`, `P.capture_save()` and `tape_op(prepare=...)` are the new harness helpers (`tools/v2_prod.py`).


## Array Store (R10.9 Phase 2C)

`tools/v2_prod_arrays.py` is a third production-image suite (run by `tools/run_v2_prod_tests.sh` next to the gate and the
known-defect suite, on its own ZEsarUX port/state dir). All its cases are **gate** cases (each must `PASS`). It holds the
former known defects D6, D8, D12, D13, D14, D15 and D16 as fixed behaviour, plus the lifecycle, boundary, replacement and
banking cases of the Phase 2B proposal (`docs/v2/R10_9_PHASE2B_REPORT.md` §3, §11). It exercises the **real** EXROM Array Store
service (`rom/exrom_v2_arrstore.asm`): bind at `RUN`, the EXROM `DIM`/`DIM$` handlers, the validating loader, the saver and the
repaired `CLEAR`. Stores are either hand-built in RAM (`PAS_END` + entries at `$E000`) or created by `LOAD ... ARRAY` from a
synthesised tape; run one case with `TS2068_DEBUG_STATE_DIR=<dir> TS2068_V2_PORT=<port> python3 tools/v2_prod_arrays.py <substring>`.

**Component tests vs production DIM.** The standalone component tests (`tools/run_v2_standalone_tests.sh`) assemble a
private HOME with a private EXROM that has no Array Store service. They bind opcodes 63/64 to the **test-only** handlers in
`rom/test_v2_local_dim.inc` (the pre-2C allocate-only handlers plus the D12 zero-fill). Those tests therefore still cover the
compiler, the VM and the allocator, but **not** the production `DIM` code, the adopt/bind logic or the store; that is
`v2_prod_arrays.py`'s job. The two sets overlap only in the allocator (`ARENA_ALLOC_*`), which both use unchanged.

Known synthetic limits (unchanged from above): the tape path is a synthesised EAR stream, not a recorder; the
`ARRAY STORE FULL` / capacity cases poke `PAS_END` directly to place the store boundary.


## Strict compilation and compile-error line (R10.9 Phase 2D)

`D3` (the compiler silently stopped at the first token it did not recognise) and `D4` (the error cursor landed on the lexer's look-ahead
record) were strict expected failures in Phase 1 and are **repaired in Phase 2D**. Their cases are production **gate** cases in
`tools/v2_prod_regress.py` (the sections "strict compilation" and "compile-error line"); `tools/v2_known_defects.py` no longer holds any D3/D4 case.

* `D3-*` (18 malformed-program families) assert the **exact compile error code** (64 unexpected token, 65 `FOR` without `NEXT`, 66 missing `)`) *and* that the
  program did not execute (`x = 1`, the first statement of the program, must not have run). `D3-ok-*` are the positive controls (the two cases that were already errors,
  a valid colon line, a valid program using every closer — block `IF`/`ELSE`/`ENDIF`, `PROC`/`ENDP`, `DEF FN`, `FOR ... STEP`, a label sharing a line with a statement,
  a line ending in `:`, `REM ...:`, `:` inside a string — and a `:`/keywords-in-a-string case).
* `D4-*`: the original 15-case matrix (20 lines of 5/29/69 characters, error on line 0, 2, 5, 10, 19: the 69-character cases cross the 264-byte chunk window repeatedly) plus
  boundary cases: lines that end in `:` (the lexer's LF continuation marker) before and on the failing line, trailing junk on the first/last line, an expression cut off at
  the end of its line, blank and `REM` lines, a label line, a stray `ENDIF` late in the program, an unclosed `(`, the four end-of-source errors (cursor on the append position),
  and a typed `run` through the real editor key path (cursor *and* loaded edit line).
* A failed compile followed by a good one in the same session (`D3-failed-compile-then-good`) proves the line counter and compiler state restart cleanly.
* `rom/test_v2_chunk_refill_boundary.asm` (standalone) TEST3/TEST4 were rewritten for the new mechanism (`LEX_LINE` instead of `CHUNK_CUR_REC_PTR`).


## Emulators for release preparation (ZEsarUX qualifies; EightyOne and Fuse are courtesy)

**ZEsarUX is the only qualification emulator.** A release is accepted on ZEsarUX results (the suites
above, `ts2068-debug`, the release gates); nothing here changes that. EightyOne and Fuse are courtesy
alternatives: try the release images there if you like, but there is no matrix, no automated gate and
no qualification requirement for them.

| Emulator | Local install | Images |
|---|---|---|
| **ZEsarUX (qualified)** | `~/Applications/ZEsarUX-13.0/zesarux` (13.0, EXROM-mirroring patch applied; required for this ROM, see `patches/README.md`) | `build/ts2068rom_zesarux.bin` (HOME + EXROM) via `--romfile` |
| EightyOne | `wine ~/EightyOne/EightyOne.exe` (1.41) | `build/test_basic.bin` as ROM File + `build/exrom.dck` as the Timex ROM Cartridge |
| Fuse | `/usr/local/bin/fuse` (1.9.1) | `fuse --machine ts2068 --rom-ts2068-0 build/test_basic.bin --rom-ts2068-1 build/exrom.bin` |

The step-by-step commands for running **any** custom TS2068 HOME/EXROM ROM (not only this one) in all
three are in the shared skill reference
[`z80-skills/skills/ts2068-debug/references/emulators.md`](https://github.com/nchiker/z80-skills/blob/main/skills/ts2068-debug/references/emulators.md)
(local: `~/z80-skills/skills/ts2068-debug/references/emulators.md`), reusable by the Forth, Pascal and
other TS2068 ROM projects. The release-asset form of the same instructions for end users is
[`docs/emulator_setup.md`](../emulator_setup.md) and [`docs/eightyone_setup.md`](../eightyone_setup.md).

## Debugging tools in this workflow

Two independent tools are shared with the other TS2068 projects; neither is part of `make test`'s
gates, and both are optional aids:

| Tool | Where | Use it for |
|---|---|---|
| `ts2068-debug` | `~/ts2068-debug` (own repository; `pip install -e .`) | live runs on the real ROM in ZEsarUX: `diagnose` (registers, symbolised stack, interrupt/banking state, trace in one call), `mem-snapshot`/`mem-diff`, `sessions`/`stop --port` for stray emulators |
| `z80sim` | `tools/z80sim` (this tree; see its README for the upstream/version note) | replaying one routine's own source from a captured state with per-instruction source-line tracing |

Versions this tree is verified against (update with the commit that changes them):

| Tool | Repository | Commit |
|---|---|---|
| `ts2068-debug` | https://github.com/nchiker/2068-Debug (local `~/ts2068-debug`) | `1c5e2a2` (`master`); full `make test` passed with it |
| `z80sim` | https://github.com/nchiker/z80sim (local `~/z80sim`), vendored in `tools/z80sim/` | `9963857` (`main`); see `tools/z80sim/UPSTREAM.md` |
| shared skills | https://github.com/nchiker/z80-skills (fork of `ignacioMonge/z80-skills`), plugin 0.9.5 | `14a4b7b` (`main`) |

They meet in `tools/sim_from_debugger.py`: stop a live session at a routine's entry, capture its registers
and the memory ranges that matter, then replay that exact state in the simulator with source and listing
correlation:

```sh
ts2068-debug --json start --rom build/ts2068rom_zesarux.bin --symbols build/test_basic.sym
ts2068-debug --json run --until MATH_UMUL16 --max-instructions 3000000     # reproduce, stop at the entry
python3 tools/sim_from_debugger.py --symbols build/test_basic.sym --entry MATH_UMUL16 \
    --range 0xF100:64 --out /tmp/case.json
python3 tools/z80sim/extract_routine.py kernel/math/math.asm MATH_UMUL16 MATH_UDIV16 \
    --with-locations > /tmp/routine.asm
python3 tools/z80sim/replay_snapshot.py /tmp/routine.asm /tmp/case.json \
    --symbols build/test_basic.sym --listing build/test_basic.lst -o /tmp/replay.json
ts2068-debug --json stop
```

The simulator is an instruction-subset interpreter (see `tools/z80sim/README.md`); the real emulator
remains the arbiter of behaviour. Run `ts2068-debug sessions` before choosing a port when other suites
may be running; use an isolated `TS2068_DEBUG_STATE_DIR` and `--port` for your own session.

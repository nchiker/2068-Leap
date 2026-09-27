# Post-R9 test-infrastructure milestone

Status: **complete** (2026-09-27). Starts from the post-R9 semantic-completion
milestone commit (887a3ce). This milestone touches test scaffolding only —
**no BASIC semantic behavior changed**, and R10 has not begun.

## Why this milestone exists

Two problems, both explicitly test-infrastructure, not language-semantic:

1. The project owner had personally observed what looked like the OLD V1
   BASIC editor appearing during some `make test` Fuse/ZEsarUX runs, even
   though production has been V1-free since the R9 cutover (commit 9fc3890).
2. 14 of the standalone `rom/test_v2_*.asm` hardware-regression harnesses had
   exceeded their flat-16K single-bank capacity: the post-R9 semantic
   milestone added ~850 bytes to `rom/exrom_v2_compiler.asm` +
   `rom/exrom_v2_vm_core.asm` alone (real, necessary production growth —
   `make budget` still shows a comfortable free reserve in both real
   production banks), plus further growth in `rom/exrom_v2_decompiler.asm`.

## Part 1 — why the V1 editor was visible, root-caused

**Root cause: two `make test` targets deliberately, correctly boot the OLD
V1 command loop as legitimate component tests of shared kernel primitives.
This was not a bug** — but it was under-labeled, risking exactly the
confusion the owner reported.

| Target | ROM(s) booted | Built by | V1 or V2 | Component or integration |
|---|---|---|---|---|
| `tools/run_editor_auto_test.sh` | `test_editor_auto.bin` (`rom/test_editor_auto.asm`, `INCLUDE "basic/basic.asm"`) + `exrom_editor_test.bin` (`rom/exrom_build.asm -DEDITOR_TEST_EXROM`) | itself, via `sjasmplus` | **V1** | Component (generic editor engine) |
| `tools/run_storage_named_load_test.sh` (11 `make test` invocations) | one of `test_storage_named_load.bin` / `test_storage_extension_roundtrip.bin` / `test_storage_autorun_roundtrip.bin` (all `INCLUDE "basic/basic.asm"`) + `exrom_storage_test.bin`/`exrom_editor_test.bin` (`rom/exrom_build.asm`, various `-D`) | itself | **V1** | Component (`kernel/storage/storage.asm` transport) |

Both scripts launch a **real, visible Fuse window** (under Xvfb/X11, not
headless) — that is exactly what the owner saw. It is the OLD V1
`BASIC_COMMAND_LOOP` (`basic/basic.asm`), not a stale path or a Makefile bug:
`rom/test_editor_auto.asm`'s own header already says "calls
`BASIC_COMMAND_LOOP` directly." These two scripts are real, useful
regression tests of the shared editor engine and the generic
`STORAGE_SAVE`/`STORAGE_LOAD` transport (both genuinely still used — V2's
own `rom/test_v2_save_load.asm` reuses the same transport) — legitimate
component tests, not stale fixtures.

**Fix applied:** both scripts' headers, and the ledger's own storage-results
paragraph (`docs/v2/R9_CUTOVER_LEDGER.md`), now say explicitly that a PASS
here does **not** prove `rom/v2_home.asm`/`rom/v2_exrom.asm` (the real V2
production ROM) boots or works.

### A second, separate stale-path bug found and fixed while auditing

`tools/run_smoke_rom_tests.sh` concatenated its 9 images with a **root-level,
git-ignored `exrom.bin`** that is not produced by any Makefile target at all
— a leftover from some earlier ad hoc `sjasmplus rom/exrom_build.asm` run.
Investigating this in depth found it is a two-way split, not one bug:

- `test_memory`/`test_math`/`test_editor_ops` never touch EXROM at all (pure
  HOME-side kernel unit tests); any EXROM image just pads the combined
  ZEsarUX image to size.
- The six `test_calc_smoke_*` images are a genuinely **pre-V2** component
  test: they use `RST $28 -> CALC_ENTRY_TRAMPOLINE` and
  `include/exrom_jumptable.inc`'s OLD `KTAB_BASE`/`KTAB_LIST`/`KTAB_MAGIC`
  table — a completely separate, older mechanism from
  `include/v2_ktab.inc`'s `V2_KTAB_*` used by real production. Their own
  file headers already document `sjasmplus rom/exrom_build.asm` (no defines)
  as the intended pairing. **Pairing them with the real production
  `build/exrom.bin` was tried during this audit and confirmed (not
  assumed) to fail**: the real EXROM's `V2_VERIFY_KTAB` guard reads a magic
  byte these images' HOME layout never writes, and correctly traps rather
  than running — proof the guard works, not a test bug.

**Fix applied:** `run_smoke_rom_tests.sh` now rebuilds a fresh
`exrom.bin` deterministically (`sjasmplus rom/exrom_build.asm`, no defines)
at the start of each run instead of depending on a stale leftover file, and
its header now states plainly that this is intentionally the pre-V2 EXROM
layout for the calc-smoke images specifically, not the V2 production one.

## Part 2 — standalone V2 harness capacity fix

**Fix:** all 14 over-capacity `rom/test_v2_*.asm` files were rebuilt on a
new, shared, production-shaped two-bank test harness instead of one flat
16K image:

- `rom/test_v2_harness_addrs.inc` — shared fixed EXROM entry addresses.
- `rom/test_v2_harness_home_head.inc` / `_tail.inc` — the HOME-side image:
  real `RST $00/$28/$38` vectors, a real, unbalanced
  `call BANK_PAGE_EXROM_IN` at cold start (mirroring `V2_COLD_START`'s own
  real pattern), `kernel/bank/bank.asm` + `kernel/math/math.asm` +
  `rom/exrom_v2_vm_core.asm` + `rom/exrom_v2_compiler.asm` always resident.
  A driving test file defines `TEST_V2_NEEDS_DECOMPILE` and/or
  `TEST_V2_NEEDS_CALC` and either supplies `SOURCE_TEXT` +
  `TEST_CHECK_RESULT` (+ optionally `TEST_CHECK_DECOMPILED`), or defines
  `TEST_V2_CUSTOM_CHECKS` + supplies `TEST_CUSTOM_MAIN`.
- `rom/test_v2_harness_exrom.asm` — the EXROM-side image: real
  `BANK_PAGE_EXROM_IN`/`BANK_PAGE_EXROM_OUT` trampolines at fixed
  addresses, `rom/exrom_calc.asm` (only if `TEST_V2_NEEDS_CALC`) and
  `rom/exrom_v2_decompiler.asm` (only if `TEST_V2_NEEDS_DECOMPILE`) — every
  test in this migrated set only needs `TEST_V2_NEEDS_DECOMPILE`, so ONE
  shared EXROM build (`-DTEST_V2_NEEDS_DECOMPILE`) covers all 14.

This gives ~24K combined capacity (real 16K HOME + real 8K EXROM) instead of
16K, without shrinking any production file or omitting any check. Migrated:
`arrays`, `block_if`, `decompiler`, `for_nested`, `for_step`, `group6_math`,
`input`, `mode_module`, `printer_module`, `proc_recursion`, `relational`,
`save_load`, `sqr_decomp`, `strfuncs`. Three more (`deffn`, `ext_demo`,
`vm_milestone01`) already fit the old flat-16K convention and were left
unchanged. `tools/run_v2_standalone_tests.sh` was rewritten to build and run
all 17 under `ts2068-debug` (`--json run --max-instructions 3000000` +
border check). All 17/17 PASS in real ZEsarUX.

Two genuine, previously-undetected bugs in `rom/exrom_v2_decompiler.asm`
(from the prior semantic milestone, not from this one) were found and fixed
while validating the new harness — the fuller, combined testing the new
harness enables exercised code paths the old cramped harnesses' narrower
programs never reached together:

1. `DECOMP_SKIP_OPERAND`'s opcode-width table was missing entries for
   `JMP` (6) and `JMPZ` (12) — any program decompiled through
   `DECOMP_COLLECT_ARRAY_SIZES` containing an `IF`/`EXIT FOR` (which compile
   to `JMP`/`JMPZ`) mis-walked the bytecode stream.
2. `DECOMP_EMIT_ARRAY_DIMS` used `DECOMP_TMP_LEN` to park an array's declared
   size across `DECOMP_EMIT_CHAR` calls, but `DECOMP_EMIT_CHAR` itself
   clobbers `DECOMP_TMP_LEN` internally — every declared array size
   rendered as whatever the last-emitted digit run happened to leave behind
   (observed: `DIM A0(5)` rendering as `DIM A0(40)`). Fixed by switching to
   `DECOMP_ARG_LEN0`, already established elsewhere in the file as safe for
   this exact purpose.

Neither bug affects production BASIC semantics: `exrom_v2_decompiler.asm` is
not linked into the shipping EXROM build (`make budget`'s production figures
are unaffected).

## Full test-target classification

| Target (`make test`/`check`/`budget`/`v2-packages`) | Boots | Component or integration | Notes |
|---|---|---|---|
| `tools/run_smoke_rom_tests.sh` (test_memory/math/editor_ops) | HOME-only, any EXROM | Component | Never touches EXROM |
| `tools/run_smoke_rom_tests.sh` (6 calc-smoke images) | pre-V2 HOME + `rom/exrom_build.asm` EXROM (no defines) | Component (pre-V2) | Own headers document this pairing; confirmed incompatible with real V2 EXROM (KTAB magic guard) |
| `tools/run_editor_auto_test.sh` (both cases) | V1 `basic/basic.asm` HOME + `rom/exrom_build.asm -DEDITOR_TEST_EXROM` | Component (V1 editor engine) | Real, visible Fuse window — this is what the owner saw |
| `tools/run_storage_named_load_test.sh` (11 cases) | V1 `basic/basic.asm` HOME + `rom/exrom_build.asm` (various `-D`) | Component (storage transport) | Same real, visible Fuse window |
| `tools/run_v2_standalone_tests.sh` (17 cases) | Two-bank V2-shaped test harness (not the real production build) | Component (VM/compiler/decompiler/extension semantics) | Real `BANK_PAGE_EXROM_IN/OUT`, real fixed EXROM addresses, but not `rom/v2_home.asm`/`rom/v2_exrom.asm` themselves |
| `make budget` (`tools/report_budget.py`/`report_rom_map.py`) | N/A — static analysis of `build/test_basic.lst`/`build/exrom.lst` | Integration-adjacent (real production build artifacts) | Does not boot anything |
| `make v2-packages` | N/A — assembles + TZX-packages the 4 loadable extensions | Component | Assembly-only, no boot check |
| `rom/zesarux_combined.asm` → `build/ts2068rom_zesarux.bin` | The **real** combined V2 production image | — | Built by `make build`, copied into release assets, but **not booted by any automated test** (see below) |

### Known gap, not fixed this milestone

No automated target boots `build/ts2068rom_zesarux.bin` (the real combined
production image) and checks any observable state. A prototype cold-boot
check (confirm `PC` settles into `kernel/io/io.asm`'s `IO_READ_KEY.wait_hit`
idle loop) was attempted during this milestone; it did not reach that state
within a very large bounded instruction count under headless `ts2068-debug`
in a way that could be reliably distinguished from `docs/v2/
R9_CUTOVER_LEDGER.md`'s own already-documented "known open discrepancy:
ZEsarUX headless/GUI reproduction" limitation, so it was not committed
rather than ship an inconclusive check under a "production-integration"
label. Real interactive cold-boot behavior IS separately verified (manually,
in real ZEsarUX, per the R9 ledger's own "Production interactive tests
already exercised" section) — this gap is specifically about *automating*
that check. Recommended for R10: instrument this properly (e.g. a
lower-instruction-count checkpoint mid-`MEM_INIT`, or resolving the
headless/GUI discrepancy first).

## Obsolete V1 test assumptions flagged for R10 cleanup

- `tools/run_editor_auto_test.sh`/`tools/run_storage_named_load_test.sh`
  boot the real, visible Fuse/X11 path (not `ts2068-debug`) — the only two
  targets in `make test` still doing so. Worth porting to headless
  `ts2068-debug` the way `tools/run_smoke_rom_tests.sh` already was
  (see that script's own header for the precedent), independent of the
  V1-vs-V2 question.
- The six `test_calc_smoke_*` images' own file headers still say `Run: fuse
  --machine ts2068 ...` (the old real-Fuse instructions) even though
  `run_smoke_rom_tests.sh` now runs them under `ts2068-debug` — harmless
  (docs only) but stale.
- `rom/exrom_build.asm`'s default (no-`-D`) EXROM build has no Makefile
  target of its own; it is currently only ever produced as a side effect of
  running one of the above test scripts. Not wrong, but worth a real
  `smoke-build`-style target if it grows more consumers.
- Root-level `exrom.bin` remains git-ignored and gets regenerated by
  `tools/run_smoke_rom_tests.sh` on every run; other manual dev scripts
  (`tools/run_demo.sh`, `tools/run_demo_cursor_test.sh`,
  `tools/run_stack_audit.sh`, `tools/validate_showcase.sh`) also expect it
  to exist at repo root and were left untouched (out of scope — none of
  them are part of `make test`/`check`/`budget`/`v2-packages`).

## Test results after this milestone

- `make check`: pass.
- `make test`: pass — 9/9 smoke (including the corrected calc-smoke EXROM
  pairing), 2/2 editor flows, 11/11 storage/package/autorun cases, 17/17 V2
  standalone regressions (14 migrated + 3 unchanged).
- `make budget`: pass — production ROM/RAM figures unchanged by this
  milestone (only `rom/exrom_v2_decompiler.asm`, not production-resident,
  changed).
- `make v2-packages`: pass — MODE/SPRITE/PRINTER/SHAPES TZX packages
  generated as before.

No BASIC semantic behavior changed. R10 has not begun.

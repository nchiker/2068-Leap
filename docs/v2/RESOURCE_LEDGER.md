# 2068-Leap V2 — Resource Ledger

Running, cumulative record of every Phase 0 (and later) milestone's measured
ROM/RAM/performance effect. Populated only from real measurements taken
after implementation, never from planning-stage estimates — those live in
`ROM_BUDGET.md`/`RAM_BUDGET.md`/`PERFORMANCE_BASELINE.md` and are explicitly
superseded here once a milestone actually lands.

## V1 baseline (pre-Phase-0) — `VERIFIED`, real measurement, 2026-09-19

- **Build**: clean, 0 errors, 0 warnings.
- **`make check`**: all static checks pass (duplicate-label/scope/early-pop
  checks, doc checks, RAM-alias checks, storage-contract/tape-fixture
  checks, `check_basic_source.py` against all 91 test/demo fixtures, both
  z80sim tests, 15 standalone smoke ROMs).
- **`make test` (real ZEsarUX/Fuse execution)**: **95/95 fixture tests
  PASS, 0 FAIL**; 9/9 smoke-ROM run PASS; all storage/editor-integration
  tests PASS. Exit code 0, zero real failures.
- **ROM**: HOME 16,379/16,384 used, **5 bytes free**; EXROM 8,165/8,192
  used, **27 bytes free** — unchanged from both planning phases.
- **RAM**: no dedicated RAM-budget tool exists in this project (confirmed
  by inspecting `tools/`); figures remain source-derived from
  `include/sysvars.inc`, consistent with `RAM_BUDGET.md`.
- **Editor/interpreter live verification** (real ZRCP session): clean boot
  (PC at the normal keyboard-idle state, not a hang); a 5-line program
  (assignment, `PRINT`, `FOR`/`NEXT`, `PLOT`) entered correctly with
  expected keyword bolding; navigation and insert/backspace responded
  correctly; `RUN` produced correct output (`PRINT x` → `4`; the
  `FOR`/`PLOT`/`NEXT` loop correctly plotted three pixels at
  (10,10)/(20,20)/(30,30)).
- **Existing performance benchmarks**: intentionally not re-run in this
  task (out of scope — being handled by the parallel P0.1 task to avoid
  duplication).

**This is the authoritative "before" state every subsequent Phase 0
milestone's gate is measured against.**

## Milestone ledger

| Milestone | ROM Saved | ROM Added | Net ROM | RAM Saved | RAM Added | Net RAM | Performance Effect | Status |
|---|---:|---:|---:|---:|---:|---:|---|---|
| V1 baseline | — | — | 0 (reference point) | — | — | 0 (reference point) | 95/95 regressions pass; editor/interpreter verified live | **PASS** |
| M00 (Fuse→ts2068-debug test infra migration + 4 ts2068-debug fixes) | 0 | 0 | 0 | 0 | 0 | 0 | Suite runtime cut from ~20min (Fuse/X11) to 703s/7.4s-per-fixture (harness-grouped Python API, 4 ZEsarUX restarts for 95 fixtures instead of 95) | **95/95 PASS** — see `docs/v2/milestones/MILESTONE_00_RESULTS.md` for the full root-cause writeup (persistent-breakpoint + border-hardware-latch bugs, both fixed) — **COMPLETE** |
| P0.1 (benchmark authoring) | 0 | 0 | 0 | 0 | 0 | 0 | N/A (no 2068-Leap code touched) | **COMPLETE** — 6 new isolated benchmarks (add/mul/div/ifbranch/varaccess/fornext) + string re-verified past its old N=3/N=4 cap, all real/reproducible; major finding: GOTO-based label loops are catastrophically expensive (existing sieve/pixel benchmarks may be stale/non-reproducible as a result) — see `~/2068-rom-benchmarks/results/2026-09-19-p01-isolated-benchmarks.md` |
| P0.3 (`HIT()` sprite-function-to-loadable-extension conversion) | EXROM 89 | HOME 3 | EXROM -89, HOME +3 | 0 | 0 | 0 | Not separately measured — one new fixed per-expression-evaluation dispatch check (`BASIC_EVAL_PRIMARY`), unmeasured in frames | **98/98 PASS** — see `docs/v2/milestones/MILESTONE_01_RESULTS.md`; scope narrowed mid-implementation from the full `SHOW`/`MOVE`/`HIDE`/`HIT()` candidate to `HIT()` alone once `SPRITE`'s sub-verb grammar was found not to fit the extension ABI's canned statement shapes — **COMPLETE** |

## Cumulative summary (updated after every milestone)

- **Original V1 size**: HOME 16,379/16,384 (5 free), EXROM 8,165/8,192 (27
  free) — `VERIFIED`, fresh `make budget`, 2026-09-19, confirmed by the
  real baseline measurement above.
- **Current consolidated size** (after P0.3): HOME 16,382/16,384 (2
  free), EXROM 8,076/8,192 (116 free) — `VERIFIED`, fresh `make budget`,
  2026-09-19.
- **Total ROM recovered**: 89 bytes EXROM; HOME went the other way (-3
  bytes) — the function-slot extension ABI's fixed Home dispatch cost.
  Net across both banks: +86 bytes of combined free space, but HOME's
  own margin (the tighter of the two) is now thinner, not thicker — a
  real tradeoff, not a pure win, and worth weighing before another
  Home-costing ABI expansion is attempted.
- **Total RAM recovered**: 0 bytes so far.
- **Current HOME reserve**: 2 bytes (was 5) — **critically thin**; any
  future Home-resident addition needs a Home-shrink pass first, or must
  itself be EXROM-resident from the start (this milestone's own
  `BASIC_TRY_EXTENSION_FUNCTION_EXROM_BODY` precedent, see MILESTONE_01_
  RESULTS.md, is the template for how to do that).
- **Current EXROM reserve**: 116 bytes (was 27).
- **Projected V2 feature budget**: unresolved — this is exactly what Phase 0
  exists to establish. See `ROM_BUDGET.md`'s Phase 2 shortfall analysis for
  the gap this ledger needs to close.

This document is updated after every milestone's PASS, per the autonomous
progression protocol — never edited to retroactively "smooth over" a result.

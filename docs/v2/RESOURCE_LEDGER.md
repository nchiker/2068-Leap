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
| M00 (Fuse→ts2068-debug test infra migration + 2 ts2068-debug fixes) | 0 | 0 | 0 | 0 | 0 | 0 | Suite runtime cut from ~20min (Fuse/X11) to 665s/7.0s-per-fixture (harness-grouped Python API, 4 ZEsarUX restarts for 95 fixtures instead of 95) | 87/95 PASS, 8 FAIL (real, disclosed verdict-logic ambiguity for the `*_unloaded`/`*_new_clear` family — see `docs/v2/milestones/MILESTONE_00_RESULTS.md`) — **PARTIAL, follow-up required** |
| P0.1 (benchmark authoring) | 0 | 0 | 0 | 0 | 0 | 0 | N/A (no 2068-Leap code touched) | STOPPED — real execution-timing mystery hit, not resolved; see MILESTONE_00_RESULTS.md-adjacent fork report |

## Cumulative summary (updated after every milestone)

- **Original V1 size**: HOME 16,379/16,384 (5 free), EXROM 8,165/8,192 (27
  free) — `VERIFIED`, fresh `make budget`, 2026-09-19, confirmed by the
  real baseline measurement above.
- **Current consolidated size**: unchanged from V1 (no Phase 0 production
  change has landed yet).
- **Total ROM recovered**: 0 bytes so far.
- **Total RAM recovered**: 0 bytes so far.
- **Current HOME reserve**: 5 bytes (unchanged).
- **Current EXROM reserve**: 27 bytes (unchanged).
- **Projected V2 feature budget**: unresolved — this is exactly what Phase 0
  exists to establish. See `ROM_BUDGET.md`'s Phase 2 shortfall analysis for
  the gap this ledger needs to close.

This document is updated after every milestone's PASS, per the autonomous
progression protocol — never edited to retroactively "smooth over" a result.

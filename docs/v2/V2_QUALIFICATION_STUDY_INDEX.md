# 2068-Leap V2 — Qualification study: index and next step

Emulator evidence only (headless ZEsarUX through `tools/qual/`); nothing is hardware-qualified. Nothing is integrated: `~/2068-Leap` /
`v2-development` remain at `7ae0599`, nothing was pushed, and the overnight `study/*` prototype branches were not modified.

## Deliverables

| # | What | Where |
|---|---|---|
| 1 | Language conformance report (Phase A) | `docs/v2/V2_LANGUAGE_CONFORMANCE_REPORT.md` |
| 2 | Coverage matrix: per feature / per case | `docs/v2/V2_LANGUAGE_COVERAGE.csv`, `docs/v2/V2_LANGUAGE_CASES.csv` |
| 3 | Independent Z80 audit and shrink review (Phase B) | `docs/v2/V2_INDEPENDENT_Z80_AUDIT.md` |
| 4 | Remaining completion budget (Phase C) | `docs/v2/V2_REMAINING_COMPLETION_BUDGET.md` |
| 5 | Test tools | `tools/qual/` on `study/qualification-a` (harness, 619-case corpus, runners, merge, coverage, gate and study-tool battery scripts) |
| 5 | Measured prototype branches | below |
| 6 | Next step | below |

## Study branches (all local, worktrees under `~/2068-Leap-study/`)

| Branch | Head | Base | Content | Measured |
|---|---|---|---|---|
| `study/qualification-a` | (this commit) | `study/report` | reports, `tools/qual/` | — |
| `study/qualification-b` | `c655564` | `study/combined-enhanced` | `chunk_refill_boundary` on the two-bank harness; strict harness EXROM builds (T-1) | standalone 38/38 |
| `study/qualification-costs` | `b1463c7` | `study/combined-essential` | fixes for 22 defect ids (Q-01 … Q-09, Q-11 … Q-14, Q-17 partial, Q-18 … Q-20, Q-27 … Q-31) | HOME 196 / EXROM 482 |
| `study/qualification-shrink` | `ff7f0be` | `study/combined-essential` | RST vectors for the five hottest call targets | HOME 912 / EXROM 488 |
| `study/qualification-final` | `b716d4e` | `study/qualification-costs` | the fixes + the RST shrink | **HOME 741 / EXROM 482** |
| `study/qualification-enh-final` | `162dd59` | `study/qualification-b` | the same fixes (`c461d7c`: HOME 23 / EXROM 233) + the RST shrink, on Enhanced | **HOME 578 / EXROM 233** |

Builds are reproduced by `tools/qual/build_configs.sh` (`git archive` exports, no worktree is built in place). Run logs: `~/2068-Leap-study/qual-runs/`.

## Next step (recommendation)

1. **Fix before anything else.** No configuration is release-quality. Six critical defects (string compare, temporaries, `AND/OR` crash, large `DIM`,
   rejected array store, 31-character string) silently corrupt data or erase the program in all three builds. Take the commits of `study/qualification-costs`;
   the critical set alone frees 9 B net.
2. **Take the RST shrink with them** (`study/qualification-final` / `study/qualification-enh-final`): +545 / +555 HOME, +0.1–0.3 % run time, all suites
   unchanged. In Enhanced the fixes leave only 23 B of HOME without it.
3. **Decide:** integer-only `FOR` (Q-08), the storage-goal-2 semantics (what `RUN` does to restored variables), L-A vs L-C literals, and the release reserve
   (proposed ≥ 200 HOME / ≥ 150 EXROM).
4. **Place goal 2 by configuration.** Enhanced + fixes + RST is measured at 578 / 233. Its EXROM cannot take goal 2 at the pessimistic estimate, so goal 2
   goes into HOME (with further shrink) or into a package there.
5. Then implement the open required items (Q-10, `INPUT` numbers, `VAL`/D11 extremes, D10 rounding), then the spec gaps (string ordering, short-circuit), then goal 2,
   re-measuring the budget after each.
6. Add `tools/qual` to the project's test flow (or port its cases into the project's suites). Retire or run the 15 never-run component tests (T-3).
   Wire the `audit-z80` pattern scanners and the study's error-raise-site scanner into the build as a report step. Q-29 (a register not reloaded after a call)
   and Q-03/Q-18 (errors raised from called routines) are exactly the classes they flag.

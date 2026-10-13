# 2068-Leap V2 — First Implementation Milestone

Per the Phase 2 brief: identify the smallest sensible first milestone. Given
Phase 2's central finding — V2.0's language core does not fit either ROM
bank, and there is no consolidation saving to close the gap — **the first
milestone comes from Phase 0, not from any language feature.** This
document does not implement it; it specifies it for explicit authorization.

## OBJECTIVE

Author the six missing isolated performance benchmarks and re-run the
string-concat benchmark (Phase 0, milestone P0.1 in `IMPLEMENTATION_PLAN.md`)
— establishing the first real, trustworthy performance baseline this
project has ever had for integer addition, multiplication, division,
`FOR`/`NEXT` overhead, `IF`/branching, and variable access. No 2068-Leap
ROM/ASM source is touched.

## RATIONALE

Every later Phase 0/V2.0 milestone's completion criteria in
`V2_IMPLEMENTATION_GATES.md` depend on comparing against these benchmarks.
`PERFORMANCE_BASELINE.md`'s Phase 2 audit found that most of the isolated
categories the task brief itself names have **no existing fixture at all**
— not a stale number, an *absent* one. Doing the HOME/EXROM relocation
SPIKE (P0.2) or any language milestone (M1-M6) before this exists means
every later "did this regress performance" gate would be judged against
nothing. This is the one piece of Phase 0 that is pure addition (new
benchmark fixtures in a sibling repo), touches no 2068-Leap product code at
all, and therefore carries the lowest possible risk of any candidate first
milestone — it validates an important assumption (that the missing
benchmarks are worth having, and confirms exactly how sparse the existing
data is) with essentially zero downside.

## EXACT FILES AFFECTED

- `~/2068-rom-benchmarks/*.bas` (or equivalent fixture format) — six new
  files: `bench_add.bas`, `bench_mul.bas`, `bench_div.bas`,
  `bench_fornext.bas`, `bench_ifbranch.bas`, `bench_varaccess.bas`.
- `~/2068-rom-benchmarks/harness/` — reuse existing `inject_leap.py`/
  `build_leap_tzx.py`/`build_leap_tape.py` unchanged; no new tooling
  expected, but confirm during implementation rather than assuming.
- `~/2068-rom-benchmarks/results/` — one new results file, dated, following
  the existing `2026-09-15-consolidated-three-rom-comparison.md` format and
  the already-documented 5-run statistical protocol.
- **Not affected**: any file in `~/2068-Leap`.

## ROUTINES AFFECTED

None in 2068-Leap itself — the benchmarks exercise existing, unmodified
2068-Leap BASIC statements (`+`, `*`, `/`, `FOR`/`NEXT`, `IF`, variable
reads/writes) exactly as V1 executes them today.

## DEPENDENCIES

None — this is the first milestone; nothing in the revised
`IMPLEMENTATION_PLAN.md` precedes it.

## TESTS TO ADD

Not applicable in the usual sense (no product code changes) — the
"test" for this milestone is that each new fixture runs to completion under
ZEsarUX ZRCP and produces a screenshot/memory-verified `FRAMES` result,
matching the existing methodology's verification standard.

## EXISTING REGRESSIONS TO RUN

None required (no 2068-Leap product code touched) — optionally, re-confirm
the existing sieve and pixel benchmarks still reproduce their documented
numbers on current `main`, as a sanity check that the harness itself still
works correctly before trusting any new fixture's output.

## EXPECTED ROM DELTA

Zero. No 2068-Leap ROM image changes.

## EXPECTED RAM DELTA

Zero. No 2068-Leap RAM layout changes.

## BENCHMARKS TO RUN

This milestone's entire output *is* the benchmark set:
addition/multiplication/division/`FOR`-`NEXT`/`IF`-branching/variable-access
(new), plus the string-concat re-run (repair of an existing, currently
invalid number).

## SUCCESS CRITERIA

- All six new fixtures execute successfully under the existing ZRCP-driven
  harness and produce screenshot/memory-verified `FRAMES` numbers.
- The string-concat benchmark runs past its old N=3 cap and produces a
  valid throughput number (not a "correctness check" caveat).
- All seven numbers are captured in a new, dated results file following
  the existing format, with the 5-run statistical protocol actually
  applied (a first — every existing number to date is a single run).

## STOP CONDITIONS

- If a new fixture cannot be isolated cleanly from confounding factors
  (e.g. an "addition-only" loop that the interpreter's dispatch overhead
  dominates so heavily that the addition signal is unmeasurable) — stop and
  document the limitation explicitly in `PERFORMANCE_BASELINE.md` rather
  than publishing a misleading number.
- If the string-concat fix (`9f67fee`) turns out not to actually resolve
  the underlying `STR_FUNC_POOL` issue when pushed past N=3 in practice —
  stop, this is a real 2068-Leap bug re-opening, and it should be handled
  as its own bug-fix task before any milestone that depends on a working
  string benchmark proceeds.

## ROLLBACK CRITERIA

Trivial — this milestone only adds files to `~/2068-rom-benchmarks`. If any
new fixture or result proves wrong or misleading, delete or correct the
specific file; there is no 2068-Leap product-code state to roll back.

## What happens next

On completion, `PERFORMANCE_BASELINE.md` is updated with the new real
numbers, and Phase 0's P0.2 (the HOME/EXROM relocation SPIKE) becomes the
next milestone — it explicitly depends on this one, since P0.2's own
completion criteria require checking relocation candidates against these
now-available benchmarks before finalizing which routines are safe to move.

**This document specifies the milestone; it does not authorize starting
it.** Per the project dossier's mutation boundary, explicit authorization —
even for this low-risk, non-2068-Leap-touching first step — should be
given before work begins.

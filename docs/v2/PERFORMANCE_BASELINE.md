# 2068-Leap V2 — Performance Baseline (Phase 2 revision)

**This document supersedes the Phase 1 version.** Phase 2 explicitly
required using only real, already-measured data and forbade inventing
benchmark numbers. A dedicated fork inventoried exactly what real data
exists; the result is materially sparser than Phase 1 implicitly assumed.
This revision states plainly what is and is not known.

## What real, measured data actually exists (`VERIFIED`)

Source: `~/2068-rom-benchmarks/results/2026-09-15-consolidated-three-rom-
comparison.md`, git commit `5d42db5` (2026-09-17), still the newest results
file as of this Phase 2 pass — confirmed no later run exists.

| Category | Data exists? | Number | Source/confidence |
|---|---|---|---|
| Integer sieve (composite: arithmetic + array + branch) | Yes | ~6.3 frames/work-unit (2068-Leap) vs. ~33.0 stock TS2068 | Real ZEsarUX ZRCP run, screenshot/memory-verified, single run |
| Pixel/graphics (chaos-game) | Yes | ~4.7 frames/unit (2068-Leap) vs. ~55.8 stock | Same, real, single run |
| String operations | **Data exists but is invalid** | `N=3, FRAMES=13` — the results doc's own words: *"a correctness check, not a throughput result"* | Capped at N=3 by a real defect (Issue #2); the fix appears to have landed (`9f67fee`) but **has not been re-run since** — no post-fix number exists |
| Integer addition loop (isolated) | **No** | — | No isolated fixture exists; sieve conflates addition with array/branch cost |
| Integer multiplication loop (isolated) | **No** | — | No isolated fixture; sieve doesn't multiply |
| Integer division (isolated) | **No** | — | No isolated fixture |
| `FOR`/`NEXT` overhead (isolated) | **No** | — | No isolated fixture in any of the four existing composite benchmarks |
| `IF`/branching (isolated) | **No** | — | No isolated fixture |
| Variable lookup/access (isolated) | **No** | — | No isolated fixture |
| Procedure/function call | **No V1 baseline possible** | — | Confirmed, not assumed: V1 has no procedures beyond single-parameter `DEF FN`; there is nothing to benchmark |
| Interpreter dispatch overhead (isolated) | **No** | — | Sieve's ~6.3 frames/unit is the closest proxy but conflates dispatch with everything else the loop does |

**This corrects an implicit assumption in Phase 1's `PERFORMANCE_BASELINE.md`**,
which listed "benchmarks required" for several of these categories as
though a baseline number was one re-run away. In most cases **no isolated
fixture exists at all** — building one is new benchmark-authoring work, not
a re-run.

## Methodology that exists and can be reused

`~/2068-rom-benchmarks/harness/METHODOLOGY.md` defines a repeatable,
already-used `FRAMES`-based stopwatch protocol (fixed setup untimed,
`BORDER` markers, `t0`/`t1` capture) and a documented (but never yet
applied) 5-run statistical protocol — every existing number above is a
single run, per the results doc's own caveats. `harness/inject_leap.py`/
`build_leap_tzx.py`/`build_leap_tape.py` already handle 2068-Leap program
injection and can be reused for new fixtures without new tooling. No
benchmark or timing capability exists in `~/ts2068-debug` (it is the ZRCP
debugging controller itself, not a benchmark harness) or in `~/2068-Leap/
tests` (functional correctness fixtures only).

## Revised action plan (replaces Phase 1's M0)

Building the missing isolated benchmarks is real, scoped work, not a
one-line re-run:

1. Re-run the existing string benchmark past N=3 now that Issue #2 appears
   fixed — a re-run, not new authoring.
2. Author new isolated `.bas` fixtures for: integer addition, integer
   multiplication, integer division, `FOR`/`NEXT` overhead, `IF`/branching,
   variable-access. None of these exist today.
3. Apply the already-documented 5-run statistical protocol to both the new
   fixtures and the two existing valid composite benchmarks (sieve, pixel),
   since every current number is a single run.
4. Defer authoring an isolated interpreter-dispatch benchmark — genuinely
   hard to isolate cleanly from everything else the interpreter does; treat
   the sieve number as the best available proxy rather than inventing an
   artificial isolation.

## Design-change risk analysis (updated with Phase 2's numeric-design correction)

### `/` already pays the calculator round-trip cost today — a pre-existing condition, not a V2 regression

`ARCHITECTURE_VALIDATION.md` Correction 2 found that BASIC's `/` operator
*already* always round-trips through the calculator
(`CALC_INT_TO_FP_HOME` → `CALC_OP_DIV` → `CALC_FP_TO_INT_HOME`) even for
plain integer division — V1 itself already violates the "integer programs
shouldn't pay the full float cost" principle for this one operator, today,
independent of any V2 change. This must be measured honestly: **the new
integer-division isolated benchmark (item 2 above) should be run against
current V1** to quantify exactly how expensive this pre-existing round-trip
already is, before V2's `/`-inexact-check addition (`NUMERIC_DESIGN.md`)
is assessed for its *incremental* cost, which should be small (a
comparison against an already-computed result) rather than the cost of
the round-trip itself (which V2 does not add — it already exists).

### Numeric tag-check dispatch (`+`/`-`/`*`)

Unchanged risk assessment from Phase 1: `LOW` risk, one tag-compare added
per operation, gated on the new isolated addition/multiplication
benchmarks (which don't exist yet — see action plan above) confirming the
actual regression stays small.

### Symbol-table name-field widening

Unchanged risk assessment from Phase 1 in kind, revised in mechanism: V1's
`BASIC_VAR_FIND_OR_CREATE`/`BASIC_ARRAY_FIND` scan is already a linear
scan-by-name-and-kind over pool records (not, as Phase 1 assumed, an O(1)
indexed table) — so widening the name field from 1 byte to 8 bytes changes
the *comparison cost per candidate* (up to 8 byte-compares instead of 1),
not the fundamental access pattern (which was already a scan, not a direct
index). This is a smaller performance change than Phase 1's framing
implied ("O(1) becomes a scan") because V1 was never O(1) for scalar access
in the first place. `MEDIUM` risk is downgraded to `LOW-MEDIUM`
accordingly, still gated on the new isolated variable-access benchmark.

### Procedures/functions

Unchanged from Phase 1: `LOW` risk to hot loops (cost paid once per call).
Not independently re-validated in Phase 2 — flagged for its own pass.

### Direct-execute-from-source interpretation

Unchanged from Phase 1: no V2.0 change committed; a future statement-
boundary-caching REFINE remains a deferred stretch item.

## What this means for `IMPLEMENTATION_PLAN.md`

The plan's former M0 ("benchmark harness hardening") is now honestly a
larger, multi-fixture authoring task, not a quick repair-and-re-run. See the
revised `IMPLEMENTATION_PLAN.md` and `FIRST_MILESTONE.md`.

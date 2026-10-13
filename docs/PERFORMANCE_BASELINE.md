# 2068-Leap V2 — Performance Baseline (Phase 2 revision, updated after P0.1)

**This document supersedes the Phase 1 version.** Phase 2 explicitly
required using only real, already-measured data and forbade inventing
benchmark numbers. P0.1 (2026-09-19) subsequently authored and ran the
isolated benchmarks this document originally found missing — see
`~/2068-rom-benchmarks/results/2026-09-19-p01-isolated-benchmarks.md`
for the full writeup; this section is updated with those real results.

## Major finding from P0.1: GOTO-based label loops are catastrophically expensive

The single most important performance discovery this study has made.
A GOTO-based loop (`loop: A=A+1 : I=I+1 : IF I<N THEN GOTO loop`, N=2000)
did **not complete even after 20,000,000 Z80 opcodes (54.7 real
seconds)**. The functionally-identical loop rewritten as
`FOR I=1 TO N ... NEXT I` completed the same N=2000 in under 5,000,000
opcodes. This was independently reproduced with the existing `sieve.bas`
benchmark (GOTO-based inner-loop control flow): it did not complete
within 10,000,000 opcodes/27.4 seconds either, meaning **the
2026-09-15 sieve/pixel numbers below may not be reproducible/reliable as
currently written** — flagged, not silently trusted. Likely cause
(consistent with, not yet independently re-confirmed against,
`CURRENT_LIMITATIONS.md`'s direct-execute-from-source finding): `GOTO`
almost certainly re-scans the program's own source text for its target
label on every jump, since there is no tokenizer and no pre-resolved
jump table — `FOR`/`NEXT` has no such cost since its stack frame already
holds the loop body's address directly. This is real, load-bearing
evidence that any future statement-boundary/dispatch-caching REFINE
(already a deferred stretch item) should prioritize `GOTO` target
resolution specifically, not just general per-statement re-parse cost.

## What real, measured data actually exists (`VERIFIED`)

Composite benchmarks source: `~/2068-rom-benchmarks/results/2026-09-15-
consolidated-three-rom-comparison.md`, commit `5d42db5`. Isolated
benchmarks source: `~/2068-rom-benchmarks/results/2026-09-19-p01-
isolated-benchmarks.md`, all via direct-memory-injection through
`ts2068-debug` (not typing), 2-3 runs each, every run within a set
identical (not the full 5-run protocol — time-boxed, see that doc's
own follow-up list).

| Category | Data exists? | Number | Source/confidence |
|---|---|---|---|
| Integer sieve (composite) | **Flagged unreliable** | ~6.3 frames/work-unit (2026-09-15) | Real ZEsarUX run, but P0.1 found this exact fixture's GOTO-based control flow does not complete within 10M opcodes on a fresh re-run — the original number's measurement conditions are now in question, not confirmed reproducible |
| Pixel/graphics (chaos-game) | Yes, not re-checked | ~4.7 frames/unit vs. ~55.8 stock | 2026-09-15, single run; not re-verified in P0.1 (not checked for GOTO usage) |
| String operations | **Yes — fixed and reproducible** | N=2000, FRAMES=5344, RESULT=2000 (correct) | 2026-09-19, direct injection, 3 identical runs. Confirms Issue #2 (STR_FUNC_POOL leak) is genuinely fixed — the old N=3/N=4 cap is gone |
| Integer addition loop (isolated) | **Yes** | N=2000, FRAMES=1496, RESULT=2000 (correct) | 2026-09-19, direct injection, 2 identical runs |
| Integer multiplication loop (isolated) | **Yes** | N=2000, FRAMES=1370, RESULT=91 (correct, 7×13) | 2026-09-19, direct injection, 3 identical runs |
| Integer division (isolated) | **Yes** | N=2000, FRAMES=1912, RESULT=14 (correct, 100÷7 truncated) | 2026-09-19, direct injection, 3 identical runs |
| `FOR`/`NEXT` overhead (isolated) | **Yes** | N=2000, FRAMES=529, RESULT=2001 (correct) | 2026-09-19, direct injection, 3 identical runs |
| `IF`/branching (isolated) | **Yes** | N=2000, FRAMES=2966, RESULT=1000 (correct, ~50% taken) | 2026-09-19, direct injection, 3 identical runs |
| Variable lookup/access (isolated) | **Yes** | N=2000, FRAMES=1445, RESULT=0 (correct, self-assignment) | 2026-09-19, direct injection, 3 identical runs |
| Procedure/function call | **No V1 baseline possible** | — | Confirmed, not assumed: V1 has no procedures beyond single-parameter `DEF FN`; there is nothing to benchmark |
| Interpreter dispatch overhead (isolated) | **No** | — | Still judged too hard to isolate cleanly; unchanged from Phase 2 |

**Derived per-iteration costs** (subtracting the FOR/NEXT baseline of 529
frames, ÷2000): addition ≈9.7ms, multiplication ≈8.4ms, division
≈13.8ms (confirms the calculator round-trip cost `NUMERIC_DESIGN.md`
predicts is real, not just architectural inference), IF/branching
≈24.4ms (notably the most expensive of the four — worth scrutiny before
trusting further), variable access ≈9.2ms (comparable to addition,
consistent with scalar lookup being a short linear scan for a
single-letter name, not separately expensive), string concatenation
≈48.2ms (dramatically the most expensive operation measured).

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

## Action plan status (P0.1, 2026-09-19)

1. ~~Re-run the existing string benchmark past N=3~~ — **done**, confirmed
   fixed at N=2000.
2. ~~Author new isolated `.bas` fixtures~~ — **done** for addition,
   multiplication, division, `FOR`/`NEXT`, `IF`/branching, variable-access.
3. **Not done**: the full 5-run statistical protocol (2-3 runs used
   instead, time-boxed); re-measuring sieve/pixel (both need a GOTO-free
   rewrite first per the major finding above, not just a re-run).
4. Still deferred: an isolated interpreter-dispatch benchmark — unchanged,
   still judged too hard to isolate cleanly.
5. **New, added by this pass's own finding**: rewrite `sieve.bas`/
   `pixel.bas`'s inner-loop control flow to use `FOR`/`NEXT` instead of
   `GOTO` where the algorithm allows it, before trusting their numbers
   for any V2 comparison.

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

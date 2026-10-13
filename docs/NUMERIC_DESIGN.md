# 2068-Leap V2 — Numeric Architecture (Phase 2 revision)

**This document supersedes the Phase 1 version.** Phase 2 found that the
promotion infrastructure Phase 1 proposed building from scratch mostly
already exists. See `ARCHITECTURE_VALIDATION.md` Correction 2 for the full
evidence trail; this document specifies the resulting, smaller design.

## Corrected baseline (all `VERIFIED` against current `main`)

- **Integer core**: unchanged, 16-bit signed, `MATH_UMUL16`/`MATH_UDIV16`
  for `*` (multiply only — see below). `*` raises `NUMERIC OVERFLOW` on
  16-bit overflow.
- **`/` already always round-trips through the calculator**
  (`basic.asm:2547-2612`): `CALC_INT_TO_FP_HOME` on both operands →
  `CALC_OP_DIV` → `CALC_FP_TO_INT_HOME`, truncating toward zero. This is
  true for *every* integer division today, not just float-producing calls
  — V1 already pays the calculator round-trip cost unconditionally for
  this one operator. A divisor-zero check happens first in HOME
  specifically because the calculator's raw divide has no error-reporting
  path of its own and would hang.
- **`CALC_INT_TO_FP`/`CALC_FP_TO_INT` already exist**
  (`rom/exrom_calc.asm:664,707`), with HOME-callable veneers, already used
  by `/` and by `SQR`'s Newton's-method implementation
  (`basic.asm:3704-3755`).
- **A per-expression float/int discriminator already exists and is
  already threaded through every combine site**: `FUNC_RESULT_IS_FLOAT`
  (`include/sysvars.inc:2126`) plus a 5-byte packed result float
  (`FUNC_RESULT_FLOAT`) and a sign flag. It is read/cleared at `.do_add`/
  `.do_sub` (`basic.asm:2428,2447`), `.do_mul`/`.do_div` (`:2539,2612`),
  and unary negate (`:2651`) — **deliberately cleared** at every combine
  step except the narrow "whole printed expression is one bare call" case.
  This is the exact mechanism identified in `CURRENT_LIMITATIONS.md` §1 as
  a "non-composable special case" — but it is a policy applied to an
  existing mechanism, not a missing mechanism.
- **The calculator's literal opcode set already includes add/sub/mul/div**
  (8 literals wired: exchange, delete, sub, mul, div, add, dup, end-calc —
  per Phase 1's audit, re-confirmed unchanged in Phase 2). `+`, `-`, `*`
  today never reach these calculator literals — they use plain 16-bit Z80
  ops (`add hl,de` etc.) and always clear the float flag.
- **`BASIC_PARSE_NUMBER` (`basic.asm:6301-6345`) has no decimal-point
  branch at all.** `X = 10.5` is `LIKELY` (not live-run-confirmed in this
  pass) a syntax error today — the digit scanner stops at `10`, leaving
  `.5` unconsumed, and statement-level code expects end-of-statement.
  **No V1 program can be relying on any particular behavior for a decimal
  literal**, since none succeeds today.

## Revised V2 design

The design goal is unchanged: integer fast path untouched, float available
on demand, no float-representation invention. What changes from Phase 1 is
*how much new code this actually requires*.

### 1. Decimal literal recognition (new)

Extend `BASIC_PARSE_NUMBER` to recognize a `.` followed by digits, tag the
result FLOAT, and hand the digit string to the calculator's existing
literal-encoding path rather than the integer accumulator. This is
genuinely new code (nothing today parses a fractional literal) — the
smallest new piece in this design.

### 2. `+`/`-`/`*`: wire to the calculator's already-existing literals, gated by the already-existing tag

Today these three operators never look at `FUNC_RESULT_IS_FLOAT` except to
clear it. V2 changes the policy at exactly these three combine sites:

1. Check both operands' type tag (read, not computed — the tag already
   travels with each value once decimal literals and FLOAT-typed pool
   records exist).
2. **Both INT**: unchanged 16-bit Z80 op, unchanged speed, unchanged
   `NUMERIC OVERFLOW` behavior on overflow *unless* auto-promotion is
   enabled per item 4 below.
3. **Either FLOAT**: promote the INT side via the already-existing
   `CALC_INT_TO_FP_HOME`, then invoke the calculator's already-wired
   add/sub/mul literal (the same literals `/` already uses for div), tag
   the result FLOAT via the already-existing `FUNC_RESULT_IS_FLOAT`
   mechanism — but *propagated* to the pool record on assignment instead
   of cleared at the next combine step.

This is the central design change from Phase 1: **stop clearing the flag,
start propagating it, and give `+`/`-`/`*` the same calculator-literal
access `/` already has.** No new float representation, no new arithmetic
routines in the calculator — only new *dispatch* at three HOME call sites
and one new EXROM entry point bundling "promote-and-invoke-literal" for the
cases where the existing per-operator HOME code doesn't already do this
(unlike `/`, which does).

### 3. `/`: add a "stay FLOAT when inexact" path (new, small)

Today `/` always calls `CALC_FP_TO_INT_HOME` and discards any fractional
part — this is *why* `5/2` prints `2` today. V2 adds a check on the
calculator's exact result before truncating: if the division was exact
(remainder zero), truncate to INT as today (no behavior change, no cost
added for the common exact-division case); if inexact, skip the truncation
and keep the FLOAT tag. Because the calculator has already computed the
correct float quotient by this point (it always did, per the corrected
baseline above), this is nearly free — the new cost is a comparison, not a
new arithmetic path.

### 4. Overflow auto-promotion (unchanged in spirit from Phase 1, cheaper in practice)

`*`'s existing overflow check (added by `52467de`) becomes the trigger for
auto-promotion instead of raising `NUMERIC OVERFLOW`: on overflow, redo the
operation through the calculator (already reachable per item 2) and tag
FLOAT instead of erroring. `+`/`-` gain the same overflow check (they
currently have none — a pre-existing gap, not new work created by this
design) wired to the same promotion path.

## Traced examples (Phase 2 execution-trace validation)

| Example | V1 today | V2 |
|---|---|---|
| `A=10 / B=20 / C=A+B` | Plain `add hl,de`, INT, flag cleared | Identical — both operands INT, fast path unchanged |
| `X = 10.5` | `LIKELY` syntax error (unconfirmed live) | Parses: `BASIC_PARSE_NUMBER` recognizes `.5`, tags FLOAT, stores a 5-byte calculator float in `X`'s (now wider, see `STRING_AND_SYMBOL_DESIGN.md`) pool record |
| `A=10 / X=A+0.5` | `LIKELY` syntax error | `A` is INT, `0.5` is FLOAT; `+` promotes `A` via existing `CALC_INT_TO_FP_HOME`, invokes calculator's `add` literal, result FLOAT `10.5` |
| `X = 5/2` | Already round-trips through calculator; truncated to `2` | Same round-trip (no new cost — it already happened); new inexact-check keeps it as FLOAT `2.5` instead of truncating |

## Revised cost estimate (`LIKELY`, still pending a SPIKE — see `IMPLEMENTATION_PLAN.md`)

| Item | Estimated cost | Bank | Notes |
|---|---:|---|---|
| Decimal literal recognition + float-literal encoding | ~30 HOME (detect) + ~70 EXROM (encode, off hot path) | mixed | Genuinely new; no existing code to reuse |
| `+`/`-`/`*` tag-check dispatch | ~40 HOME | HOME | Hot path — must stay HOME; single compare per op |
| `+`/`-`/`*` promote-and-invoke-literal helper | ~140 EXROM | EXROM | Off the fast-int path by construction; reuses existing calculator literals and converters |
| `/` inexact-check (skip truncation) | ~20 HOME | HOME | Small; the float computation already happened |
| Overflow auto-promotion for `+`/`-` (new overflow check) + wiring `*`'s existing check to promote instead of error | ~40 HOME | HOME | |
| **Total** | **~90 HOME (hot) + ~250 mixed (mostly EXROM, cold path)** | | Materially smaller than Phase 1's ~330-430 byte estimate, and with far less of it sitting on the hot path |

This revision directly improves the ROM budget crisis identified in
`ARCHITECTURE_VALIDATION.md` — see `ROM_BUDGET.md` for how the reduced,
mostly-EXROM cost here interacts with the retracted checker-consolidation
saving.

## What this design still deliberately does not do

Unchanged from Phase 1: no per-element array float tags (`DIM AS FLOAT`
remains deferred), no attempt to make FLOAT as fast as INT, no changes to
the calculator's internal float format or its known truncate-not-round
`CALC_PACK` gap.

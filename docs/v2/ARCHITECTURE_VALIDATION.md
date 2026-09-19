# 2068-Leap V2 — Phase 2 Architecture Validation

This document records where Phase 1's proposals were challenged against the
actual current source and what changed as a result. Per the Phase 2 brief:
"attempt to disprove or improve" every Phase 1 conclusion. Three findings
below are corrections of fact, not refinements of judgment — Phase 1's
authors (a set of research forks reading source) missed a real architectural
migration that had already landed on the exact commit they audited.

## Correction 1 (`VERIFIED`): scalars are not in fixed 26-slot tables — Phase 1's central string/symbol premise was stale

Phase 1's `CURRENT_LIMITATIONS.md` and `STRING_AND_SYMBOL_DESIGN.md` state
that the single-character restriction is caused by a fixed 26-slot
`VAR_TABLE`/`STR_TABLE` addressed by letter. **This was true through "Phase
3" of V1's own development and was retired in "Phase 4" (2026-08-23) — before
commit `942facb`, the exact commit both Phase 1 and Phase 2 audited.**
`include/sysvars.inc:323-328,2292-2297` state this directly: the fixed tables
"lived here through Phase 3 — retired in Phase 4." Scalars are now records in
the *same dynamic pool* that holds arrays: `[kind:1][name:1][count:2]
[data...]` — 6 bytes for a numeric scalar, 36 bytes for a string scalar,
auto-vivified via `BASIC_VAR_FIND_OR_CREATE` (shared with
`BASIC_ARRAY_FIND`'s linear scan, `basic/basic.asm:5741-5866`). Scalars grow
down from `PROG_AREA_MAX`; arrays grow up from `PROG_END`; the pool
exhausting is reported via `MSG_ARRAY_OUT_OF_MEMORY`.

**Why this happened**: Phase 1's research forks cited "26 fixed slots" as a
confirmed fact, evidently reading stale comments, an older doc, or an
incomplete source pass, without catching the Phase 4 migration note sitting
in the same header they were reading from. This is exactly the kind of
error Phase 2 exists to catch.

**What actually causes the restriction today**: the pool record's `name`
field is exactly **1 byte**, and the scan compares it with a single `cp b`
(`basic/basic.asm:5835`) — an exact-match, not a prefix match. The fix is
narrower than Phase 1 proposed: widen the name field and change the compare
to a bounded byte-by-byte loop in the *already-generalized, already-tested*
scan routine — not build a new symbol-table subsystem from scratch. See the
revised `STRING_AND_SYMBOL_DESIGN.md`.

## Correction 2 (`VERIFIED`): numeric promotion infrastructure already exists and is already load-bearing

Phase 1's `NUMERIC_DESIGN.md` treats `CALC_INT_TO_FP` as new code to write
and treats `/` as running through `kernel/math`'s integer divide. Both are
wrong on current `main`:

- `CALC_INT_TO_FP` (`rom/exrom_calc.asm:664`) and `CALC_FP_TO_INT`
  (`:707`) already exist, with HOME-callable veneers.
- **BASIC's `/` operator already always round-trips through the calculator**
  (`basic/basic.asm:2547-2612`: `CALC_INT_TO_FP_HOME` on both operands →
  `CALC_OP_DIV` → `CALC_FP_TO_INT_HOME`), not `MATH_DIVIDE16`. The source's
  own comment (`:2373-2377`) states this outright and notes both approaches
  "truncate toward zero identically" — meaning this was a deliberate,
  already-made design choice, not an oversight Phase 1 could have known
  about without tracing the actual call.
- A per-expression float/int discriminator, `FUNC_RESULT_IS_FLOAT`
  (`include/sysvars.inc:2126`), plus a 5-byte packed result float, already
  exists and is already threaded through every arithmetic combine site
  (`.do_add`/`.do_sub` in `basic.asm:2428,2447`; `.do_mul`/`.do_div` in
  `:2539,2612`; unary negate `:2651`). It is *deliberately cleared* at every
  combine step except the narrow bare-function-call case — the source
  comment at `sysvars.inc:2114-2125` confirms this is by design, matching
  exactly the composability gap Phase 1 identified, but as an existing,
  already-wired mechanism whose *policy* needs to change, not a missing
  mechanism that needs to be built.

**Consequence**: Phase 1's numeric hybrid design is directionally correct
but overstates the build cost. V2's real numeric work is closer to "stop
clearing this flag on every combine step, and wire `+`/`-`/`*` to the
calculator the way `/` already is" than "invent tagging and promotion from
scratch." A second consequence, worth flagging explicitly: **`/` today
already pays the full calculator round-trip cost for every integer division,
unconditionally** — the non-negotiable "don't make integer programs pay the
full float cost" requirement is already being violated by V1 itself for this
one operator. V2 should treat this as a pre-existing condition to be aware
of when benchmarking, not something V2 introduces. See the revised
`NUMERIC_DESIGN.md` and `PERFORMANCE_BASELINE.md`.

## Correction 3 (`LIKELY`, one live-run gap noted): decimal literals produce a syntax error today, not silent truncation

Tracing `BASIC_PARSE_NUMBER` (`basic.asm:6301-6345`) shows it has no branch
for `.` at all — it consumes only digits and returns with the scan position
sitting on the unconsumed `.`. Statement-level code then expects end-of-
statement and finds `.5` (or similar) left over. This is `LIKELY` a syntax
error, not the silent-truncation-to-integer behavior that might have been
assumed. The exact error message was not independently confirmed by a live
run in this pass (a cheap, one-line check the `2068-debug` skill could do
before this is asserted as settled fact in a future spec). **No Phase 1
document made an incorrect claim here** — this is new ground truth, not a
correction of an existing error, but it matters for `V2_LANGUAGE_SPEC.md`'s
literal-recognition milestone (M4 in the revised plan): today, `X = 10.5`
already fails loudly, so making it work is purely additive from a
compatibility standpoint — no program that runs successfully today relies on
any particular behavior for a decimal-point literal.

## Correction 4 (`VERIFIED`): the checker-consolidation ROM saving in Phase 1's budget does not exist

Phase 1's `ROM_BUDGET.md` counted on consolidating the whole-program static
checker's dispatch table with the runtime execution dispatch table for a
~150-byte EXROM saving. The dedicated Phase 2 consolidation audit
(`CONSOLIDATION_AUDIT.md`) traced both tables and found they already share
their keyword-matching primitive (`KTAB_BASIC_MATCH_KEYWORD_BOUNDARY`); only
the per-keyword *handler pointers* differ, because one table validates
syntax and the other executes semantics — genuinely different behavior, not
copy-paste duplication. **This saving is retracted.** See
`CONSOLIDATION_AUDIT.md` for the full evidence and `ROM_BUDGET.md`'s revision
for the budget consequence, which is severe: without this saving (and
without the more general "de-duplicate basic.asm's monolith" saving Phase 1
also assumed, which the same audit found no evidence for), **V2.0's
committed scope as originally scoped does not fit HOME ROM.** See below.

## Correction 5 (`VERIFIED`): the generic editor engine is already cleanly separated; the real coupling is a same-compilation-unit issue

Phase 1 treated "editor/interpreter separation" as an open question. Phase 2
found the answer is split: `rom/exrom_editor.asm` (the generic line-buffer
engine — insert/delete/cursor/scan) has **zero direct calls into any
`BASIC_*` routine** and communicates only through two zero-initialized
callback-hook sysvars (`EDITOR_REDRAW_HOOK`/`EDITOR_NAV_HOOK`, read via
`jp (hl)`) — this is already a clean, narrow, already-existing boundary, not
a gap to close. The actual coupling is that `basic/editor_integration.asm`
(2,291 lines, the BASIC-specific glue that *sets* those hooks) is compiled
into the same unit as the interpreter and shares globals
(`CUR_EDIT_POS`/`CUR_EDIT_INDEX`/`VIEW_TOP_INDEX`/`CHECK_ERROR_COUNT`) with
it — because it's literally the same file family, not because it reaches
into variable/expression internals (it doesn't — confirmed by grep, zero
references to `VAR_TABLE`/`CALC_`/`RST $28`/`FOR_STACK`/`GOSUB_STACK`). See
`SUBSYSTEM_BOUNDARIES.md` and `V1_DEPENDENCY_MAP.md` for the full trace.

## What Phase 1 got right and remains unchanged

- The overall rejection of structured-basic-poc's architecture wholesale
  (`ARCHITECTURE_COMPARISON.md`'s Alternative C rejection) stands —
  nothing in Phase 2's research contradicts the ROM/RAM/perf cost evidence
  for its numeric ABI, descriptor heap, or VM-guard layer.
- The five ROM/EXROM byte-count figures Phase 1 cited for `kernel/math`,
  the calculator, string funcs, the DIM allocator, and arrays were
  independently re-verified against a fresh `make budget` and are still
  exactly accurate (403 / 1,931 / 383 / 210 / 71 bytes respectively; HOME
  16,379/16,384, EXROM 8,165/8,192, unchanged from Phase 1).
- The decision to convert LPRINT/LLIST to a loadable extension as the one
  confirmed EXROM-freeing move stands — no Phase 2 finding contradicts it.
- Procedures/functions were not independently re-validated in Phase 2 (no
  fork specifically traced call/parameter-binding mechanics); the Phase 1
  cost estimate for this item is carried forward unchanged but flagged as
  still needing its own dedicated validation pass before being locked in.

## The central, hard conclusion of Phase 2

Two corrections compound into a genuine budget crisis that Phase 1 did not
see: (1) the numeric/symbol *feature* costs are now known to be **smaller**
than Phase 1 estimated (infrastructure reuse), but (2) the ROM-freeing
*consolidation* Phase 1 counted on to make room for them **does not exist**.
Net effect, worked through in `ROM_BUDGET.md`: even after pushing every
piece of new logic that can tolerate EXROM-call overhead out of HOME, the
portion of V2.0's revised (smaller) feature set that must stay in HOME
because it sits on a genuinely hot execution path (identifier parsing,
symbol-table scan, arithmetic tag-dispatch, `AND`/`OR` short-circuit,
divide-by-zero check, and half of procedure call/return) totals
approximately 365 bytes — against **5 bytes of actual, real HOME headroom**,
because there is no consolidation saving to add to it.

**This means V2.0 cannot proceed as scoped without either cutting committed
features or genuinely relocating existing HOME content to EXROM** — not
cleaning up duplication (there isn't any worth taking), but moving some
currently-HOME-resident, not-actually-hot code into the paged bank. No fork
in this phase was tasked with finding and sizing specific relocation
candidates (e.g. within `kernel/graphics`'s 2,761 HOME bytes, some of which
— `CIRCLE`/`FILL`/mode-setup — are called rarely per program, unlike
`PLOT`/`LINE` in a tight loop, and might tolerate EXROM's paging cost). This
is why Phase 2 concludes **Phase 0 is required, not optional**, and why the
first milestone (`FIRST_MILESTONE.md`) is a measurement SPIKE to find and
quantify that relocation opportunity, rather than an assumed number. See
`V2_ARCHITECTURE.md`'s revised recommendation and `IMPLEMENTATION_PLAN.md`'s
revised milestone order for the full consequence.

## Answers to the Phase 2 brief's specific challenge questions

- **Incorrect assumptions about V1**: yes — Corrections 1-3 above.
- **Incorrect assumptions about structured-basic-poc**: none found; Phase
  1's cost figures for that project were independently re-confirmed against
  its own docs in the Phase 2 editor-separation fork and were not contradicted.
- **Underestimated ROM costs**: the checker-consolidation saving was
  overestimated (claimed a saving that doesn't exist); the general
  "de-duplicate basic.asm" saving was likewise unsupported. Conversely, the
  numeric/symbol feature costs were *overestimated* in the other direction
  (too expensive, not too cheap) — Phase 2 nets this out in `ROM_BUDGET.md`.
- **Underestimated RAM costs**: yes, for symbols — see the revised
  `RAM_BUDGET.md`. Phase 1's claimed RAM *savings* from replacing a fixed
  table that no longer exists is invalid; the honest comparison is a modest
  RAM *increase* per variable (wider name field on an already-lean pool
  record), not a saving.
- **Hidden subsystem dependencies**: one real one found — `kernel/memory`
  calling up into `BASIC_RESET_TEXT_ATTR` (guarded by
  `IFDEF FULL_ENGINE_PRESENT`). See `V1_DEPENDENCY_MAP.md`.
- **Unnecessary abstractions / excessive complexity**: none found in V1
  itself (the consolidation audit's verdict is that V1 is already lean);
  Phase 1's *proposed* string-heap design (`STRING_AND_SYMBOL_DESIGN.md`'s
  original pool-allocator-with-in-place-reuse-mitigation) is more complex
  than necessary given Correction 1 — see the revised document for a
  smaller alternative.
- **Performance regressions**: the division-already-pays-float-cost finding
  (Correction 2) is a pre-existing condition, not a V2-introduced
  regression, but must be accounted for honestly in benchmarking.
- **Disproportionately expensive features**: procedures remain the single
  largest committed item and are explicitly flagged as needing further
  validation before being locked in.
- **Greater V1 code reuse opportunities**: found and exploited —
  `BASIC_VAR_FIND_OR_CREATE`/`BASIC_ARRAY_FIND`, `FUNC_RESULT_IS_FLOAT`,
  `CALC_INT_TO_FP`/`CALC_FP_TO_INT`, and the calculator's already-wired
  add/sub/mul/div literals all reduce V2's real build cost versus Phase 1's
  estimate.
- **Simpler solutions to the same problems**: yes — a name-field-widening
  change to the existing pool record is simpler than a new descriptor-lite
  allocator for the *identifier-length* half of the string problem (see
  revised `STRING_AND_SYMBOL_DESIGN.md`); the *string-length-cap* half of
  the problem (31 bytes today) is now explicitly deferred rather than
  solved in V2.0, since solving it well still requires real allocator work
  that the ROM budget cannot currently absorb alongside everything else.
- **Choices that make sense on a modern computer but not a 48K Z80**: the
  original reference-counted string heap comparison from Phase 1 remains
  the clearest example; nothing new found in this phase beyond that.

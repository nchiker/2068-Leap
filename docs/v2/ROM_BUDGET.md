# 2068-Leap V2 — ROM Budget (Phase 2 revision)

**This document supersedes the Phase 1 version.** Phase 2 found that the
Phase 1 budget's EXROM-freeing plan relied on a saving that does not exist,
and that its HOME-freeing plan relied on a general refactor with no
supporting evidence. See `ARCHITECTURE_VALIDATION.md` Correction 4 and
`CONSOLIDATION_AUDIT.md`. This revision presents the honest, corrected
picture: **V2.0 as originally scoped does not fit HOME ROM**, and explains
what changes as a result.

## Baseline (`VERIFIED`, re-confirmed fresh in Phase 2, unchanged from Phase 1)

HOME ROM: 16,379/16,384 used, **5 bytes free**. EXROM: 8,165/8,192 used,
**27 bytes free**. Per-subsystem breakdown unchanged from Phase 1's tables
(re-verified: `kernel/math` 403B, calculator 1,931B EXROM, string funcs
383B EXROM, DIM allocator 210B EXROM, arrays 71B EXROM — all confirmed
identical on current `main`).

## Retraction: the checker-consolidation saving does not exist

Phase 1 counted on a ~150-byte EXROM saving from consolidating the
checker's dispatch table with the runtime's execution dispatch table. The
Phase 2 consolidation audit traced both tables in detail and found they
already share their keyword-matching primitive; only the per-keyword
handler pointers differ, because the two tables validate and execute
respectively — genuinely different behavior, not duplicated code.
**Retracted, in full.** See `CONSOLIDATION_AUDIT.md`.

## Retraction: the "de-duplicate basic.asm's monolith" HOME saving does not exist

Phase 1 also counted on a ~1,150-byte HOME saving from a general
"split/de-duplicate `basic.asm`'s dispatch, share identifier-parsing/
promotion code across statement handlers." The Phase 2 consolidation audit
swept the *entire* source tree for exactly this class of opportunity
(duplicate routines, repeated validation, repeated bounds checks, etc.)
and found, across six specifically-checked candidate areas, that V1 is
already well-consolidated, with only one marginal ~40-60 byte candidate
identified and explicitly recommended against. **There is no evidence this
saving exists, and it is retracted.**

## Good news: the feature costs themselves are smaller than Phase 1 estimated

Phase 2's numeric/string validation found that much of the infrastructure
Phase 1 costed as new work already exists (the dynamic-pool scalar
records, the `FUNC_RESULT_IS_FLOAT` tag, `CALC_INT_TO_FP`/`CALC_FP_TO_INT`,
and the calculator's already-wired add/sub/mul/div literals). The revised
`NUMERIC_DESIGN.md` and `STRING_AND_SYMBOL_DESIGN.md` bring the combined
numeric+symbol cost down from Phase 1's ~770-940 bytes to roughly
**~340-390 bytes**, most of it now placed off the hot path in EXROM.

## The honest arithmetic

### EXROM

| | Bytes |
|---|---:|
| Free today | 27 |
| Freed: LPRINT/LLIST → 7th loadable extension (unaffected by any Phase 2 finding, still a real, confirmed move) | +253 |
| **EXROM available for new committed features** | **280** |

| New EXROM-resident item | Cost |
|---|---:|
| Numeric: promote-and-invoke-calculator-literal helper (`NUMERIC_DESIGN.md`) | ~140 |
| Numeric: decimal-literal float encoding (off hot path) | ~70 |
| String/symbol: ordering comparisons | ~40-60 |
| Checker `IF`/`FOR` balance validation (independent addition, not reliant on the retracted consolidation) | ~20-30 |
| Multi-dimensional array revival (already-built, already-verified code) | ~70 |
| Procedures: parameter binding + local-scope resolution against the widened symbol table (pushed to EXROM per the hot/cold placement discipline) | ~350 |
| **Total EXROM committed spend** | **~690-720** |

**EXROM shortfall: 280 available vs. ~700 needed ≈ -420 bytes.** Even after
the one confirmed freeing move, EXROM does not have room for the full
committed scope either, once procedures' EXROM-resident half is included.

### HOME

| | Bytes |
|---|---:|
| Free today | 5 |
| Freed by any confirmed consolidation | **0** (per `CONSOLIDATION_AUDIT.md` — nothing found worth taking) |
| **HOME available for new committed features** | **5** |

| New HOME-resident item (must stay HOME — genuinely hot execution path) | Cost |
|---|---:|
| `AND`/`OR` short-circuit | ~20 |
| Identifier charset widen (shared across scalars/labels/DEF FN) | ~30 |
| Divide-by-zero raise | ~15 |
| Symbol-table name-field widening in `BASIC_VAR_FIND_OR_CREATE`/`BASIC_ARRAY_FIND` (every variable access) | ~80 |
| Numeric tag-check dispatch at `+`/`-`/`*`/`/` combine sites (every arithmetic op) | ~40 |
| `/` inexact-check | ~20 |
| Overflow auto-promotion wiring | ~40 |
| Decimal-literal detection (the "is there a `.` here" check, kept HOME since it's part of the hot number-scanner) | ~30 |
| Procedures: `CALL`/`RETURN` dispatch + `GOSUB_STACK`-shaped frame push/pop (must interact with the existing hot call/return path) | ~150 |
| **Total HOME committed spend** | **~425** |

**HOME shortfall: 5 available vs. ~425 needed ≈ -420 bytes.**

## Conclusion: V2.0 as scoped does not fit, in either bank

This is not a rounding error or a estimation-margin problem — both banks
are short by roughly the same order of magnitude (~420 bytes) as their
entire committed feature cost, because there is no consolidation saving in
either bank to offset it. Per the task's own rule ("if the proposed
architecture does not plausibly fit with reserve, reduce scope now"),
**this document does not paper over the shortfall with optimistic
rounding.** Two honest paths forward, both required, are specified in
`V2_ARCHITECTURE.md`'s revised recommendation and `IMPLEMENTATION_PLAN.md`:

1. **Cut committed scope.** The single largest, least-validated item is
   procedures/functions (~500 bytes combined) — Phase 2 did not
   independently re-validate this estimate, and it is the natural first
   candidate for deferral to V2.1 if HOME/EXROM relocation (below) doesn't
   find enough room. Removing it alone reduces the EXROM shortfall to
   roughly -70 and the HOME shortfall to roughly -270 — still short, but
   far closer.
2. **Find and relocate genuinely-cold HOME/EXROM content.** Not
   consolidation (foreclosed by `CONSOLIDATION_AUDIT.md`) — *relocation*:
   identifying currently-resident code that is called rarely enough to
   tolerate the EXROM paging cost (a few instructions, DI/EI'd) and moving
   it into the paged bank, or identifying EXROM content that could itself
   become a loadable extension (as LPRINT/LLIST already will). No Phase 2
   fork was tasked with finding and sizing specific candidates for this
   (e.g., within `kernel/graphics`'s 2,761 HOME bytes, `CIRCLE`/`FILL`/
   mode-setup routines are called far less often per program than `PLOT`/
   `LINE` and are plausible candidates, but this needs measurement, not
   assumption).

**This is why Phase 2 concludes Phase 0 is required, not optional** — see
`V2_ARCHITECTURE.md` and `FIRST_MILESTONE.md`, which define the first
concrete step as a measurement SPIKE to find this relocatable headroom,
rather than assuming a number.

## Maintain a safety reserve — restated

Once Phase 0's relocation SPIKE produces a real, measured number, this
document must be revised again before any milestone past M0 is accepted,
per the Change Control process in the project dossier. No milestone in
`IMPLEMENTATION_PLAN.md` past the Phase 0 SPIKE is authorized to proceed
against the numbers in this document as they stand — they are known to be
short.

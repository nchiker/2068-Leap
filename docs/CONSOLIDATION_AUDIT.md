# 2068-Leap V2 — Consolidation Audit

A deep, source-level audit of the entire `~/2068-Leap` tree for duplicate,
near-duplicate, or conceptually-duplicated functionality with real ROM
recovery potential. Read-only research; no source was modified in producing
this document.

## Headline finding: V1 is already well-consolidated

This is not a codebase full of easy wins. It already has its own documented
"code-size review" discipline (e.g. `basic.asm:8939-8946`: 24 wrapper call
sites already consolidated onto a shared 5-byte trampoline shape, a
measured 74-byte HOME recovery already banked). Six areas that looked like
plausible duplication candidates on paper were checked in depth and found
to already be correctly unified — reported below as verified negatives, so
this audit reads as thorough rather than superficial.

## Areas checked and found already consolidated (no action needed)

| Area | Verdict | Evidence |
|---|---|---|
| Decimal formatting (`DIV10`, number-to-string, float-to-string, string append) | Already unified. HOME copies are 5-byte trampolines into `rom/exrom_format.asm`'s single real implementation. | `basic.asm:6380,6409,11394`; `rom/exrom_format.asm:1-3` |
| Keyboard scanning | Already unified. `IO_READ_KEY`/`IO_READ_KEY_NONBLOCK` (`kernel/io/io.asm`) is the single scanner, called by both the editor and `INKEY$`/`INPUT`. | `kernel/io/io.asm:41-54,483-542` |
| Identifier parsing | Already unified. One `BASIC_PARSE_IDENTIFIER` (`basic.asm:2318`), called from the checker's label scan, `GOTO`/`GOSUB` resolution, and `DEF FN` parsing alike. | `basic.asm:2318`; `rom/exrom_checker.asm:688,1361` |
| Character-print primitives | Already unified. `GFX_PUTCHAR`/`GFX_PUTCHAR_BOLD` (`kernel/graphics`) is called directly by the editor's highlighted-line renderer — no separate editor print path exists. | `kernel/graphics/graphics.asm:637,689`; `basic/editor_integration.asm:788-790` |
| Array allocation vs. program-line insert/delete "shift" logic | **Genuinely different patterns, correctly not sharing code.** `MEM_SHIFT_UP`/`MEM_SHIFT_DOWN` exist only for program-line edits, which must move existing bytes. Array space is append-only at a stable pool position — nothing to shift. Confirmed by grep: zero `MEM_`/`LDIR`/`SHIFT` references in the DIM/array modules. | `kernel/memory/memory.asm:212,251`; `rom/exrom_dim.asm:1-40` |
| Static-checker dispatch table vs. runtime-exec dispatch table | **Structurally necessary duplication, not fixable.** Both enumerate the same keyword set and already share the keyword-matching primitive (`KTAB_BASIC_MATCH_KEYWORD_BOUNDARY`); only the per-keyword handler pointers legitimately differ (one validates, one executes). Two tables are the direct, unavoidable cost of having a separate static-check pass at all. | `rom/exrom_checker.asm:936-1000,1530`; `basic.asm:10043-10055,10222` |

**This directly retracts the ~150-byte "checker table consolidation" saving
Phase 1's `ROM_BUDGET.md` counted on** — see `ARCHITECTURE_VALIDATION.md`
Correction 4.

## The one real, marginal candidate — evaluated and recommended against

`BASIC_CHECK_STR_ASSIGNMENT`/`BASIC_CHECK_ARRAY_ASSIGNMENT`/
`BASIC_CHECK_ASSIGNMENT` (checker, EXROM) share their LHS-recognition
*shape* with `BASIC_TRY_STR_ASSIGNMENT`/`BASIC_TRY_ARRAY_ASSIGNMENT`/
`BASIC_TRY_ASSIGNMENT` (runtime, HOME).

- **Current sizes** (computed from `build/exrom.sym`/`build/test_basic.sym`
  address deltas): check-side 146 EXROM bytes total (STR 58 + ARRAY 53 +
  ASSIGNMENT 35); exec-side ≈293 HOME bytes total (STR 150 + ARRAY 78 +
  ASSIGNMENT ≈65).
- **Why NOT to consolidate**: the divergence is semantic, not cosmetic.
  `BASIC_CHECK_ARRAY_ASSIGNMENT`'s own header explains it deliberately never
  calls `BASIC_ARRAY_FIND`, because during a static whole-program pre-pass
  the referenced array may not be `DIM`'d yet — checking existence here
  would be a false rejection. Unifying would require threading a
  check/exec mode flag through code whose two paths already diverge in
  *what they're allowed to validate*, not just *what they mutate*.
- **Estimated savings if attempted**: ~40-60 bytes total, after accounting
  for the branching needed to preserve current DIM-timing-safe behavior.
- **Risk**: `MEDIUM` — this exact bug class (check-time vs. run-time timing
  mismatch) is one the project has already hit and fixed once
  (`CURRENT_LIMITATIONS.md`'s Issue #4).
- **Verdict: do not pursue.** Savings this small don't justify re-opening a
  bug class the project has already paid down.

## Old architectural workarounds — searched, none found still costing ROM

Grepped all source for `workaround|temporary|for now|TODO|FIXME|obsolete|
superseded|dead code|unused`.

- `include/checker_keywords.inc:14`: "ORIGINAL APPROACH (superseded)" —
  fully replaced already; the comment is a historical note over no live
  code.
- `include/hardware.inc:67`: an ink/paper constant pair "unused now that
  [the old 64-column] mode was removed" — dead *data*, not dead code.
  Worth a follow-up to confirm nothing still references it before deleting
  (a few bytes, `LOW` priority, not separately costed here).
- Every other hit is a genuinely open, honestly-labeled `TODO` for future
  work (per-procedure scopes, multi-row scrolling past 24 lines, printer
  attribute tightening) — not a stale shim masking removable code.

**Conclusion: no old workaround currently costs live ROM bytes.**

## Bottom line

Across the full source tree, there is **no consolidation opportunity worth
committing to a V2.0 milestone**. The one marginal candidate found (≤60
bytes) is explicitly recommended against on risk grounds. This is a real,
evidence-backed finding: six independent areas that looked like plausible
duplication on this audit's own checklist turned out to already be
correctly unified, and the old-workaround search came back empty.

**Consequence for the ROM budget**: any headroom for V2 language features
has to come from EXROM/HOME *restructuring* — moving currently-resident,
genuinely-cold code into the paged bank, or converting rarely-used features
to loadable extensions — not from removing duplicate code, because there
isn't meaningful duplicate code left to remove. See `ROM_BUDGET.md`'s
revision and `V2_ARCHITECTURE.md`'s Phase 0 recommendation for how this
reshapes the plan.

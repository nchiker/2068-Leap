# 2068-Leap V2 — Proposed Subsystem Dependency Map

Built directly against `V1_DEPENDENCY_MAP.md`'s findings. V1's dependency
structure is already close to the desired shape — the map below preserves
almost everything and makes only the changes justified by evidence.

## What stays exactly as-is

- **Generic editor engine → callback hooks**: unchanged. Already a clean,
  narrow, one-directional boundary (editor calls out through
  `EDITOR_REDRAW_HOOK`/`EDITOR_NAV_HOOK`; nothing calls into the generic
  engine's internals). No V2 work needed here.
- **`GFX_*`/`MEM_*`/`IO_*`/`SOUND_*`/`BANK_*` APIs**: unchanged. Already
  narrow, already documented, already the right shape.
- **`KTAB_*` EXROM jump table**: unchanged. Already the correct single
  indirection layer for HOME↔EXROM calls; V2 adds new entries to it as
  needed (for the numeric/symbol/procedure additions) but does not change
  its structure.
- **Runtime → editor reuse** (`BASIC_HANDLE_NAV` called directly by
  `basic.asm`'s non-editor code): kept. This is genuine, working code
  reuse, not an architectural smell — removing it would cost ROM to
  duplicate logic that already exists in a callable form.

## What changes

- **`kernel/memory` → `BASIC_RESET_TEXT_ATTR` upward call**: this is the
  one real circular/upward dependency found in V1. **REFINE, not remove**:
  keep the `IFDEF FULL_ENGINE_PRESENT` guard (it already correctly makes
  this call disappear in kernel-only standalone builds), but document it
  explicitly as an accepted, intentional exception in
  `SUBSYSTEM_BOUNDARIES.md` rather than leaving it as an undocumented
  dependency-map surprise. No ROM cost either way; this is a documentation
  fix.
- **Editor-integration layer (`basic/editor_integration.asm`) ↔
  interpreter core (`basic.asm`)**: this pair is the one place V2 makes a
  real (if narrow) architectural change. V1 shares four sysvars between
  them because they're one compilation unit. V2 formally documents these
  four sysvars (`CUR_EDIT_POS`, `CUR_EDIT_INDEX`, `VIEW_TOP_INDEX`,
  `CHECK_ERROR_COUNT`) as the *complete* shared-state surface between the
  two layers, and requires any new V2 feature that touches editor state to
  go through `BASIC_RESET_EDIT_STATE` or an equivalent named entry point
  rather than adding a fifth ad hoc shared variable. This is a **process
  rule enforced by convention and code review, not a rewrite** — the two
  layers remain compiled together (splitting them into separate ROM
  regions would cost real bytes for no measured benefit, since neither
  fork found evidence that the current arrangement causes bugs or wastes
  ROM). See `SUBSYSTEM_BOUNDARIES.md`'s EDITOR row for the resulting
  interface contract.
- **New: symbol table (`BASIC_VAR_FIND_OR_CREATE`/`BASIC_ARRAY_FIND`)**:
  gains callers from three new V2 subsystems that don't exist in V1 —
  procedure parameter binding (needs to resolve parameter names), the
  widened identifier parser (feeds longer names into the same scan), and
  the numeric tag-check dispatch (reads the type tag now stored per
  record). All three are new *callers* of an *existing* routine, not new
  dependency edges into new subsystems — the routine's own internal
  behavior changes (wider name field, byte-by-byte compare) but its
  position in the dependency graph does not.
- **New: numeric promotion glue**: sits between `basic.asm`'s arithmetic
  combine sites (HOME, hot path — unchanged callers) and
  `rom/exrom_calc.asm`'s already-existing `CALC_INT_TO_FP`/`CALC_FP_TO_INT`/
  add/sub/mul/div literals (EXROM — unchanged callee). The only new edge is
  HOME's tag-check dispatch calling into a new, small EXROM helper for the
  actual promotion-and-arithmetic work when a FLOAT operand is present —
  this follows the *existing* pattern (HOME hot-path check, EXROM cold-path
  work) already used for `CALC_INT_TO_FP_HOME`-style veneers, not a new
  pattern.
- **New: procedures/functions**: introduces a new dependency edge from
  `basic.asm`'s `CALL`/`RETURN` dispatch (HOME, reusing the existing
  `GOSUB_STACK` shape) into a new EXROM parameter-binding routine that
  itself calls into the (now-widened) symbol table. This is the one
  genuinely new subsystem in the V2 dependency graph — everything else is
  an extension of an existing edge.

## No new dependency into the editor from any V2 language feature

None of the numeric, string, symbol, or procedure work touches the editor
(neither layer) at all. This directly answers the Phase 2 brief's question
5/6 (can numeric/string representation change without another editor
rewrite?): **yes** — the editor's only two touchpoints with the rest of the
system (the checker and the line-wrap calculator) are unaffected by any
value-representation change, because neither of them inspects variable
values or types; they operate on program *text*.

## Resulting shape

```
editor (generic engine)  --hooks-->  editor-integration (in basic.asm unit)
                                            |
                                    (checker, wrap-calc only)
                                            v
basic.asm (interpreter/dispatch, HOME)  ---owns---  symbol table (pool, HOME)
    |                                                      ^
    |--GFX_*/MEM_*/IO_*/SOUND_*/BANK_*-->  kernel/*        |
    |                                                      |
    |--KTAB_* jump table-->  EXROM (calculator, checker,   |
    |                          strfuncs, DIM, sprites,     |
    |                          storage, editor engine)-----+
    |
    |--new: CALL/RETURN-->  procedure param-binding (EXROM)
```

One-directional throughout except the single documented, guarded
`kernel/memory → BASIC_RESET_TEXT_ATTR` exception. No new circular
dependency is introduced by any V2 addition.

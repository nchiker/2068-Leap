# 2068-Leap V2 — Subsystem Boundaries

Explicit responsibilities, entry points, and dependency rules for each V2
subsystem. Interfaces are kept small and are extensions of what V1 already
has proven, per `V1_DEPENDENCY_MAP.md`/`V2_DEPENDENCY_MAP.md` — this is not
a from-scratch architecture, it is a documentation and light-refinement
pass over a structure that is already mostly correct.

## EDITOR

- **Responsibility**: keyboard-driven editing, cursor movement,
  insertion/deletion, line manipulation, viewport management, invoking
  program operations (RUN/NEW/SAVE/etc. via a reason code).
- **Two layers, one contract**: the generic engine
  (`rom/exrom_editor.asm`) exposes `EDITOR_INSERT_CHAR`,
  `EDITOR_DELETE_CHAR`, `EDITOR_BACKSPACE`, `EDITOR_MOVE_CURSOR`,
  `EDITOR_SCAN_LEN`, `EDITOR_LOOP`/`ENTER`/`EXIT`, and two callback slots
  (`EDITOR_REDRAW_HOOK`, `EDITOR_NAV_HOOK`). The BASIC-integration layer
  (`basic/editor_integration.asm`) fills those hooks and owns exactly four
  shared sysvars: `CUR_EDIT_POS`, `CUR_EDIT_INDEX`, `VIEW_TOP_INDEX`,
  `CHECK_ERROR_COUNT`, reset via `BASIC_RESET_EDIT_STATE`.
- **Allowed dependencies**: the checker (`BASIC_FULL_CHECK_EXROM`,
  `BASIC_CHECK_STATEMENT_EXROM`, read-only, status-bar display use only),
  `BASIC_EDITOR_WRAP_CALC_EXROM`, `BASIC_DETOKENIZE_TO_BUF`, `GFX_*`
  display primitives, `IO_*` keyboard primitives.
- **Forbidden dependencies**: variable/array storage, the calculator, the
  expression evaluator, `FOR_STACK`/`GOSUB_STACK`, procedure call frames.
  (Already true in V1 for both layers, confirmed by grep; V2 keeps it true
  by convention, not by physical separation, since splitting the
  compilation unit has no measured benefit.)
- **Entry points into the editor**: `EDITOR_ENTER` (from BASIC's top-level
  command loop only).
- **Entry points out of the editor**: the reason-code-style return from
  the editor's run loop back to `basic.asm`'s command dispatcher (RUN/NEW/
  SAVE/etc.) — already exists in V1's control flow; V2 does not change it.
- **Memory ownership**: the edit line buffer, viewport state, and the four
  shared sysvars above. Program storage itself (see below) is *not* owned
  by the editor — it is owned by Program Storage and merely displayed by
  the editor.
- **Error behavior**: displays checker results in the status bar; never
  raises a runtime `BASIC_RAISE_*` error itself.

## PROGRAM STORAGE

- **Responsibility**: owning the native-source-text program buffer,
  position-addressed (no line numbers stored), label resolution
  (`MEM_LABEL_LOOKUP`).
- **Representation decision (Phase 2, see `V1_V2_COMPATIBILITY.md`)**:
  **KEEP** plain, non-tokenized source text, unchanged from V1. Evaluated
  against structured-basic-poc's NUL-separated-statement-record model
  (also plain text, per the Phase 2 editor-separation fork) — the two are
  functionally equivalent in spirit; V1's position-addressed model is
  already tested and has no identified deficiency that a different
  representation would fix, so there is no reason to change it. See the
  Phase 2 "program representation" analysis below.
- **Allowed dependencies**: `kernel/memory` (`MEM_SHIFT_UP`/`_DOWN` for
  line insert/delete).
- **Forbidden dependencies**: the calculator, variable storage, the VM
  (there is no VM), the editor's viewport/cursor state.
- **Entry points**: label lookup, position-to-display-line mapping,
  insert/delete-at-position.
- **Memory ownership**: the program-text region of the dynamic pool
  (`$8455` upward, shared with scalars/arrays per `RAM_BUDGET.md`).

## LANGUAGE FRONT END (parser/checker)

- **Responsibility**: recognizing statement grammar, both for the static
  whole-program checker (pre-`RUN`) and for per-execution parsing (there is
  no separate compile step — see Interpreter/VM below).
- **Known, accepted duplication** (per `CONSOLIDATION_AUDIT.md`): the
  checker's per-keyword grammar table and the runtime's per-keyword
  execution table are separate, both sharing only the keyword-match
  primitive. **This is an explicit, documented process rule for V2**: any
  new statement type added in a future milestone must be added to *both*
  tables, and a regression test must exist proving the checker's
  acceptance/rejection matches the runtime's actual behavior for that
  statement. This is the direct mitigation for the "two places to update"
  risk `V1_DEPENDENCY_MAP.md` flags.
- **Allowed dependencies**: `BASIC_PARSE_IDENTIFIER` (shared, unchanged),
  the expression evaluator (shared, unchanged), program storage (read-only
  access to statement text).
- **Forbidden dependencies**: the editor's viewport/cursor state, the
  calculator's *runtime* operand stack (the checker never executes
  expressions, only recognizes their shape — this is already true in V1
  and must remain true, since it's a documented safety invariant: the
  checker never runs module/user code).

## INTERPRETER / VM

- **Responsibility**: there is no bytecode VM (by design, per
  `V2_ARCHITECTURE.md`'s rejection of Alternative C) — this subsystem is
  the direct-execute-from-source statement dispatcher
  (`BASIC_EXEC_STATEMENT`/`BASIC_EXEC_DISPATCH_TABLE`).
- **Allowed dependencies**: the language front end's statement-recognition
  logic (shared parsing primitives only, not the checker's validation
  pass), the runtime (variables/arrays/calculator), display, input,
  sound, storage, extensions.
- **Forbidden dependencies**: the editor (either layer) — confirmed zero
  dependency exists today; V2 preserves this.
- **Entry points**: `BASIC_EXEC_STATEMENT` (called once per statement,
  once per execution — no caching of parse results in V2.0; a future
  statement-boundary-caching REFINE, deferred per
  `IMPLEMENTATION_PLAN.md`, would live entirely inside this subsystem
  without changing its external boundary).
- **Memory ownership**: none directly — delegates to Runtime.

## RUNTIME

- **Responsibility**: variable/array/string value storage (the dynamic
  pool records), the calculator bridge, `FOR_STACK`/`GOSUB_STACK`, and (new
  in V2) procedure call frames and parameter binding.
- **Allowed dependencies**: `kernel/memory` (pool allocation), the
  calculator (EXROM, via `KTAB_*`).
- **Forbidden dependencies**: the editor, the language front end's
  checker (the runtime must never be reachable from static analysis —
  this is the safety invariant behind "a program with errors never
  half-runs").
- **Entry points**: `BASIC_VAR_ADDR`/`BASIC_VAR_FIND_OR_CREATE` (widened in
  V2 for multi-character names, same call shape), `BASIC_ARRAY_FIND`
  (unchanged call shape), new procedure-frame push/pop (reusing
  `GOSUB_STACK`'s shape).
- **Memory ownership**: the scalar/array region of the dynamic pool, the
  procedure-frame region carved from stack headroom (`RAM_BUDGET.md`).
- **Error behavior**: raises via `BASIC_RAISE_*` (unchanged mechanism;
  divide-by-zero now routed through it per `V2_LANGUAGE_SPEC.md`).

## DISPLAY / VIDEO

- **Responsibility**: `kernel/graphics` — pixel/character primitives,
  screen modes, scrolling. Unchanged in V2.
- **Allowed dependencies**: none outward (a leaf subsystem).
- **Called by**: interpreter (PLOT/LINE/etc. statement handlers), editor
  (character rendering), runtime (none directly).

## INPUT

- **Responsibility**: `kernel/io` — keyboard scanning. Unchanged in V2.
- **Allowed dependencies**: none outward (a leaf subsystem).
- **Called by**: editor, interpreter (`INKEY$`/`INPUT`).

## STORAGE

- **Responsibility**: tape SAVE/LOAD framing. Unchanged in V2.
- **Allowed dependencies**: program storage (to serialize/deserialize
  program text), runtime (for autorun line numbers — read-only).

## EXTENSIONS

- **Responsibility**: the single-slot, tape-loadable extension mechanism.
  Unchanged in V2 except for the LPRINT/LLIST-as-7th-extension conversion
  (`ROM_BUDGET.md`).
- **Allowed dependencies**: the fixed extension ABI's four JP veneers only
  (`REGISTER`, `PRINT_ATTR`, `WRITE_PIXEL`, `READ_OVER`) — unchanged,
  intentionally narrow, and explicitly not widened in V2.0 (a third
  grammar shape is evaluated but not committed — see
  `V2_LANGUAGE_SPEC.md`).

## The one accepted exception

`kernel/memory → BASIC_RESET_TEXT_ATTR`, guarded by
`IFDEF FULL_ENGINE_PRESENT`. Documented here as intentional: kernel-only
standalone test builds correctly skip it; full-engine builds need it for a
display-attribute reset that has no cheaper equivalent inside `kernel/memory`
itself. Not worth the ROM cost of duplicating a HOME-side attribute-reset
routine inside the kernel module just to avoid one guarded upward call.

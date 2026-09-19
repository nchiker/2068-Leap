# 2068-Leap V1 — Subsystem Dependency Map

Ground truth only, from source. No recommendations here — see
`SUBSYSTEM_BOUNDARIES.md` and `V2_DEPENDENCY_MAP.md` for the proposed V2
shape.

## The "editor" is three layers, not one module

1. **Generic editor engine** (`rom/exrom_editor.asm`, 930 lines, EXROM-
   resident): `EDITOR_INSERT_CHAR`, `EDITOR_DELETE_CHAR`,
   `EDITOR_BACKSPACE`, `EDITOR_MOVE_CURSOR`, `EDITOR_SCAN_LEN`,
   `EDITOR_LOOP`/`EDITOR_ENTER`/`EDITOR_EXIT`. **Zero calls into any
   `BASIC_*` routine** (confirmed by grep). Its only escape hatches are two
   zero-initialized function-pointer sysvars, `EDITOR_REDRAW_HOOK` and
   `EDITOR_NAV_HOOK` (`include/sysvars.inc:345,435`), invoked via
   `jp (hl)` (`rom/exrom_editor.asm:211,293,614`).
2. **BASIC's editor integration** (`basic/editor_integration.asm`, 2,291
   lines): explicitly headed *"BASIC-owned full-screen editor
   integration... expanded at their historical positions in basic.asm"*
   and `INCLUDE`d into `basic.asm` under `IFDEF EMIT_BASIC_EDITOR_*` guards
   — i.e. **compiled into the same unit as the interpreter**. This is where
   `BASIC_HANDLE_NAV` (line 175, installed as `EDITOR_NAV_HOOK`) and
   `BASIC_REDRAW_PROGRAM` (line 1214, installed as `EDITOR_REDRAW_HOOK`)
   live. Zero references to `VAR_TABLE`/`STR_TABLE`/`CALC_`/`RST $28`/
   `FOR_STACK`/`GOSUB_STACK` anywhere in this file. It **does** call:
   - the checker, directly and repeatedly (`BASIC_FULL_CHECK_EXROM` on every
     edit commit, line 428; `BASIC_CHECK_STATEMENT_EXROM`, line 2025,
     result-cached via `STATUS_CHECK_VALID`/`_CACHED_POS`/`_CACHED_MSG`,
     lines 1980-2043) purely to keep the live status-bar error message
     current;
   - `BASIC_EDITOR_WRAP_CALC_EXROM` (7 call sites, e.g. lines 259, 287,
     668, 1296) for line-wrap-position math;
   - `BASIC_DETOKENIZE_TO_BUF` (line 35) to render program-position text
     into the edit buffer.
3. **`basic/basic.asm`** (11,689 lines): the interpreter/dispatch core,
   which installs the two hooks and owns `CUR_EDIT_POS`, `CUR_EDIT_INDEX`,
   `VIEW_TOP_INDEX`, `CHECK_ERROR_COUNT` (reset together via
   `BASIC_RESET_EDIT_STATE`, `editor_integration.asm:9-17`) as globals
   shared between layers 2 and 3 — because they're literally the same
   compilation unit.

## Specific dependency findings

| Pair | Finding |
|---|---|
| editor (generic engine) → VM/interpreter internals | None. |
| editor (BASIC integration layer) → VM/interpreter internals | Partial: calls the static checker and line-wrap calculator; never touches expression evaluation or variable state. |
| editor → variable representation | None found in either layer. |
| tokenizer-equivalent → editor state | No tokenizer exists. The closest analog, keyword-highlight detection (`rom/exrom_highlight.asm:97,228`), is invoked *from* `BASIC_REDRAW_PROGRAM` (display-side), not the reverse. |
| display → parser | `kernel/graphics/graphics.asm:234-235,968` documents a scroll-optimization routine written "deliberately general" whose only real caller is `BASIC_REDRAW_PROGRAM` — display code is parser-agnostic; the dependency runs interpreter-layer → display, not the reverse. |
| runtime → editor | Real, intentional reuse: `basic.asm:754,762` calls `BASIC_HANDLE_NAV` directly (outside the hook mechanism) as a generic single-step-down primitive, with a comment noting it's "reusing `BASIC_HANDLE_NAV`, already proven to keep..." |
| interpreter → screen implementation directly | Expected and fine: `basic.asm` calls `GFX_*` (25 sites) and `MEM_*` (29 sites) directly — these are the designated display/memory APIs, not internals-reaching. |
| kernel → BASIC (upward call) | **Real finding**: `kernel/memory/memory.asm:129` calls `BASIC_RESET_TEXT_ATTR` (defined `basic.asm:6801`), guarded by `IFDEF FULL_ENGINE_PRESENT` (`memory.asm:126,132`) so kernel-only standalone builds skip it. This is the one clear low-level-module-calls-upward-into-BASIC dependency found. |
| shared global state | `CUR_EDIT_POS`, `CUR_EDIT_INDEX`, `VIEW_TOP_INDEX`, `CHECK_ERROR_COUNT`, `STATUS_CHECK_VALID`/`_CACHED_POS`/`_CACHED_MSG`, `NAV_TOTAL` — all read/written by both the editor-integration layer and the interpreter, because they are one compilation unit. |

## Checker vs. runtime dispatch duplication (architectural, not byte-level)

`rom/exrom_checker.asm:11-14` states its grammar-validation routines
(`BASIC_CHECK_STATEMENT`, `BASIC_CHECK_STATEMENT_CONTENT`,
`BASIC_CHECK_MULTI_STATEMENT`, `BASIC_CHECK_ASSIGNMENT`) were "cut verbatim
from `basic/basic.asm`, not rewritten" — the checker is architecturally a
**second, separate per-keyword grammar walker**, parallel to
`BASIC_EXEC_STATEMENT_CONTENT`'s own per-keyword handling. Both
independently call the same real expression evaluator
(`KTAB_BASIC_EVAL_EXPR`/`BASIC_EVAL_EXPR` — 15 call sites in the checker, 5+
in `basic.asm`), so expression parsing is genuinely shared; only the
"which keyword takes which argument shape" logic is duplicated across two
1,000+-line bodies. Per `CONSOLIDATION_AUDIT.md`, this is judged structurally
necessary (the two tables serve different purposes and only their handler
pointers differ) rather than a removable defect — but it remains a real
**process risk**: a new statement type must be added correctly in two
places, not one. See `V1_V2_COMPATIBILITY.md` and `SUBSYSTEM_BOUNDARIES.md`
for how V2 should treat this.

## Subsystem → subsystem call summary (sample sweep from `basic.asm`)

| Target | Calls from `basic.asm` | Notes |
|---|---:|---|
| `GFX_*` | 25 | Clean, narrow API surface |
| `MEM_*` | 29 | Clean, narrow API surface |
| `IO_*` | 5 | Clean, narrow API surface |
| `SOUND_*` | 1 | Minimal, clean |
| `BANK_*` | 7 | Clean paging trampoline |
| `STORAGE_*` | 0 (direct) | Storage is reached via differently-named EXROM wrappers — not individually traced in this pass; flagged as a gap for a future full-coverage pass if sprites/sound/tape/extensions need their own dependency detail |

All EXROM↔HOME calls go through the fixed-address `KTAB_*` jump table
(`include/exrom_jumptable.inc`) — a single, documented indirection layer,
not ad hoc address-poking. This is already a clean, narrow boundary and is
preserved unchanged in the V2 dependency map.

## Circular dependencies found

One: `kernel/memory` → `BASIC_RESET_TEXT_ATTR` (kernel/memory.asm:129,
guarded) is the only case where a lower-level module calls upward into a
higher-level one. No other circular or upward dependency was found in this
pass's scope (editor/interpreter/display/memory/io; sprites, sound, tape,
and extensions were not individually re-traced here — see the gap note
above).

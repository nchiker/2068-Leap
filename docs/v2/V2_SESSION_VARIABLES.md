# V2 session variables (owner decision 2, final semantics)

Status: implemented in the V2 Enhanced release (`integration/v2-final-rom`, commits `f8042ab`,
`d404b57`). Tests: `tools/qual/qlifecycle.py` (23 scenarios), `tools/study_break_matrix.py`
(`brk-session-vars`, real CAPS SHIFT+SPACE), `tools/v2_prod_arrays.py` (`arr-session-*`),
`tools/v2_saveall_checks.py` (SAVE ... ALL).

## The rules

| Event | Ordinary variables (scalars, strings, ordinary arrays) | Array Store |
|---|---|---|
| `RUN` | start fresh (zero / empty) | kept; `DIM` adopts a stored array as before |
| program ends (`END`, last line), `STOP`, `BREAK`, runtime error | **kept** -- they become the session | kept |
| immediate statement `: stmt` | runs in the session: reads and writes its variables | kept |
| immediate statement creating a new name | the variable is added to the session, zero / empty | -- |
| `: GOTO label` | runs from the program label with the session's values (not a continuation of the stopped statement: FOR/PROC frames are gone) | kept |
| `CLEAR` (statement or immediate) | reset to zero / empty; program kept | kept |
| any edit of the program (ENTER of a line, delete...) | **session ends** (variables discarded) | kept |
| `NEW` | session ends, program cleared | cleared (as before) |
| `LOAD "name"` (program), `LOAD ... ARRAY`, package `LOAD ... EXT` | session ends | `LOAD ... ARRAY` changes it; otherwise kept |
| `LOAD` of a `SAVE ... ALL` tape | the saved session becomes the current one | replaced by the saved one |

Variable preservation across edits is explicitly deferred (owner decision): V2 may invalidate the
session on any edit, and does.

If no session exists (no `RUN` since the last edit), the first immediate statement compiles the
stored program and starts a fresh session for it, so `: x = 3` then `: PRINT x` prints 3 even
before any `RUN`. If the stored program does not compile, the immediate statement runs alone, in a
scope of its own, as in earlier V2 builds (its variables are not kept).

## What an immediate statement may and may not do

* It may use every variable, array, `PROC` and `DEF FN` of the program, create scalars and string
  variables, and `DIM` new arrays (a new name whose declared size differs from a stored array of
  the same name is refused with error 65, and the statement has no effect).
* It may not define a label, `PROC` or `DEF FN` (compile error **71**): its code is overwritten by
  the next immediate statement, so such a definition would point into garbage.
* New names come out of a fixed gap of `SESS_GAP` = 80 bytes after the program's symbol table
  (about ten short names per session, fewer with long names; an immediate `FOR` also uses it while
  it compiles). When the gap is full the statement is a compile error ("OUT OF MEMORY"), and the
  session is unchanged -- the existing variables keep working.
* A statement that fails to compile leaves the session exactly as it was (symbol table and tables
  are rolled back -- `V2_SESSION_UNDO`).

## How it works (for maintainers)

* `VM_INIT` (every `RUN`) places the array arena `SESS_GAP` bytes above the compile symbol table and
  records it in `SESS_ARENA_BASE`; the gap is where immediate statements' new symbols go
  (`COMPILER_INIT_SESSION` sets `SYM_LIMIT_V` and `CSTK_BASE` to `SESS_ARENA_BASE`).
* `V2_SESSION_START` marks the program just compiled as the session (`SESS_VALID`, `SESS_CODE_END` =
  the end of its bytecode). `SYM_RESET` clears `SESS_VALID`, which is why every edit, `LOAD`, `NEW`
  and every compile of the stored program ends the session (it is flag-neutral on purpose:
  `V2_STORE_EDIT` passes its PROGRAM FULL carry through `V2_CLEAR_ARRAYS`).
* An immediate statement in a session (`V2_RUN_IMMEDIATE.session`): the cells `$B800..$B816` are
  copied to `SESS_SAVE`; the statement is compiled after `SESS_CODE_END`; a label definition is
  refused (71); `ARR_RUN_CHECK` compares any new array name with the Array Store *before* anything
  moves; `VM_INIT_SESSION` re-carves the run-time tables for the grown symbol counts, moving each
  table's existing slots down (lowest table first, every base only moves down) and zeroing only
  the new slots and the temporaries; `ARR_RUN_BIND` binds stored arrays for new names; the
  statement runs from `SESS_CODE_END`.
* Errors raised while binding unwind through `VM_RUN_SP` to the `call` that started them; the
  binding calls therefore sit at the same stack level as `VM_INIT` / `VM_INIT_SESSION` (a tail
  `jp` would leave the unwind slot to be overwritten -- found by the Array Store gate).

## RAM cost

`SESS_GAP` costs 80 bytes of the main pool on every `RUN` (FREE() is 80 lower than without
sessions); the session cells use `$B82A..$B84A` of the fixed V2 area. See `V2_ROM_RAM_BUDGET.md`.

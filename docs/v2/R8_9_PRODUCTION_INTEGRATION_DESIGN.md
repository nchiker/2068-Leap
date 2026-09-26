# R8.9 — V2 Production Integration: design

Status: design pass complete, implementation starting. This document
records the architecture decisions for connecting Architecture B (V2
compiler + VM + decompiler) to the real production ROM, replacing V1's
language-execution role while reusing every piece of mature platform
machinery that isn't intrinsically V1-interpreter-specific, per the
project rule: **preserve capability and intended semantics, not obsolete
V1 mechanism — and reuse mature platform/editor/storage machinery when it
is not intrinsically coupled to the obsolete V1 interpreter.**

R8.9's success gate (unchanged from the decision that created this
milestone): a user can boot the actual production ROM, enter and edit a
multi-line V2 BASIC program, navigate its lines, LIST/decompile it, run it
through the V2 compiler/VM, edit it again, SAVE it, LOAD it, and run it
again, without the V1 interpreter executing any language-level logic.

## 1. What V1's production loop actually does (evidence)

`BASIC_COMMAND_LOOP` (`basic/basic.asm:171`): cold-boot setup, then per
iteration: reset border, clear `EDIT_LINE_BUF`, install
`EDITOR_REDRAW_HOOK`/`EDITOR_NAV_HOOK`, load current line's text into
`EDIT_LINE_BUF` from `CUR_EDIT_POS`, call the shared editor
(`EDITOR_ENTER`), then on return: blank = no-op; editing an existing
statement always commits as a statement (never reinterpreted as a
command); otherwise keyword-match RUN/NEW/HELP/LIST/EDIT/DELETE in
sequence, falling through to "store as a new statement."

**Key discovery, changes the whole design for the better**: program
storage is **not** V1-language-specific. `basic.asm` itself documents "NO
KEYWORD COMPRESSION... stores plain text, matched by string comparison at
run time instead," and `BASIC_TOKENIZE_LINE` (`basic.asm:47-96`) is
confirmed, by direct read, to be a straight copy of `EDIT_LINE_BUF`'s text
into a length-prefixed record — no real transformation at all. The actual
storage engine is `kernel/memory/memory.asm`'s line-store
(`MEM_LINE_FIRST/NEXT/STORE/INSERT/DELETE_RANGE`), whose own header
explicitly frames itself as reusable kernel infrastructure ("one
implementation, several callers"), storing
`[length:2][content][terminator:$0D]` records with **no BASIC-specific
parsing whatsoever**. This is genuinely classification B (mature,
reusable platform code), not V1 language-core, and it is the single
biggest reuse opportunity in this whole milestone.

`EDITOR_NAV_HOOK`'s contract (`rom/exrom_editor.asm:142`) is confirmed
fully generic: called with `A = EDIR_UP/DOWN/DELETE_LINE/INSERT_LINE/
NEXT_ERROR/PREV_ERROR`, must `RET` normally, decides what each means.
`BASIC_HANDLE_NAV` (`basic/editor_integration.asm:175`) is V1's
*implementation* of this hook — it manipulates `CUR_EDIT_POS`/
`CUR_EDIT_INDEX` and calls `MEM_LINE_*` directly, then reloads
`EDIT_LINE_BUF` via `BASIC_LOAD_EDIT_LINE` (a trivial copy, per the
tokenize finding above — there is no real detokenization to replicate).

`STORAGE_SAVE`/`STORAGE_LOAD` (`kernel/storage/storage.asm:591,708`) are
confirmed to be pure byte-block transport (pointer + length, no language
assumption). V1's real callers pass `PROG_AREA_START` and
`PROG_END - PROG_AREA_START` — i.e., they save/load the line-store's own
raw contiguous bytes directly.

## 2. V2's proven contracts (evidence, not assumption)

- `COMPILE_PROGRAM` reads from a fixed sysvar `SRC_PTR` ($8B00) via
  `LEX_NEXT_TOKEN`, not from `EDIT_LINE_BUF` specifically — any
  caller-populated null-terminated buffer works.
- `LEX_SKIP_SPACES` only skips literal space; it does **not** treat
  `$0D`/`$0A` as whitespace. Statements must be `:`-joined for
  `COMPILE_PROGRAM` to treat a multi-statement span as one program — this
  is why `test_v2_editor_integration.asm`'s own comment describes
  "V2's own colon-statement-separator syntax." A raw multi-line buffer
  with CR/LF between lines would NOT compile as one program without
  conversion.
- `DECOMPILE_PROGRAM` writes to a **fixed** buffer, `DECOMP_OUT_BUF`
  ($8D00, ~400-560 bytes), CR-terminated per reconstructed line — genuine
  multi-line output. Requires `DECOMP_END_ADDR`, which `COMPILE_PROGRAM`
  already sets automatically (R8.5 fix).
- V2's own RAM footprint (`FLOATTAB_BASE $8500` → `CSYMTAB_BASE $8900`+,
  `VM_STACK` $8704-$87FF, `SRC_PTR` $8B00, `DECOMP_OUT_BUF` $8D00) sits
  entirely inside V1's `PROG_AREA_START ($8455)..PROG_AREA_MAX ($C000)`
  range. This has been harmless only because V1 and V2 never run in the
  same image simultaneously today.

## 3. The central architecture decision

**Decision (mine, evidence-based, not a V1-compatibility requirement):
the durable, live production program representation is plain V2 source
text, stored one line per record in the existing, unmodified
`kernel/memory` line-store. Compiled bytecode is never stored durably —
it is recompiled fresh from the full current line-store content every
time the program actually runs.**

Reasoning, weighed against the plan's own "bytecode-primary" framing
(`ARCHITECTURE_B_IMPLEMENTATION_PLAN.md:1343-1344`) and the four options
posed for this decision:

- **Editing behavior**: inserting/deleting/replacing a *line of source
  text* is exactly what `kernel/memory`'s line-store already does,
  correctly, today, for free. Inserting/deleting a *line's worth of
  compiled bytecode* is a fundamentally harder problem — forward jump
  targets, fixups, and label positions all shift, and nothing in this
  project has ever built or tested incremental bytecode editing. Every
  V2 milestone to date (R1-R8.5, all 14 passing regression tests) proves
  exactly one pattern: compile the *entire* program text as one unit,
  run it, decompile the *entire* bytecode as one unit. Reusing that
  exact, already-hardware-validated shape is the smallest architecture;
  inventing incremental bytecode splicing is not.
- **RAM**: keeping only source text durably (no parallel bytecode copy)
  costs no more RAM than V1's own equivalent line-store already costs,
  and avoids reserving space for a second durable copy of the program.
- **ROM**: this reuses `kernel/memory`'s line-store, `EDITOR_NAV_HOOK`'s
  existing contract, and `STORAGE_SAVE`/`LOAD` completely unchanged — the
  new code needed is a thin NAV-hook implementation, a
  buffer-concatenation routine (line-store → colon-joined `SRC_PTR`
  buffer), and a small interactive command loop. This is markedly cheaper
  than building a bytecode-native storage/editing layer from scratch.
- **SAVE/LOAD**: reusing `STORAGE_SAVE`/`LOAD` unchanged on
  `PROG_AREA_START..PROG_END` means the saved format is the same plain
  line-store bytes V1 already produces — SAVE files remain small,
  human-plausible, and (as a side effect, not a goal) happen to stay
  readable by existing tooling that expects that format.
- **The decompiler's real production role, honestly stated**: it is not
  on the critical path for ordinary LIST/EDIT under this decision, since
  the source is already kept as text. Its production value is as a
  round-trip verification/debugging capability (confirming compiled
  bytecode faithfully represents the stored source) and as the
  mechanism that would be needed if a future feature ever saves
  bytecode-only for compactness. This is a smaller role than the
  "bytecode-primary" plan note anticipated, and is recorded here
  explicitly rather than silently reinterpreted — see §8.

This is a genuine engineering judgment call with real trade-offs, not a
forced conclusion from evidence alone. I am proceeding on it rather than
pausing, because it is decisively lower-risk and reuses more proven
machinery than the alternative, and because the four-option framing this
milestone was given explicitly asked me to determine it from measured
RAM/ROM/editing/SAVE-LOAD/decompiler evidence — which is what the
reasoning above does. It is documented here in full so it can be
challenged directly if this reasoning turns out wrong once implemented.

## 4. RAM collision resolution

V2's own fixed tables/sysvars overlap V1's `PROG_AREA` range. This is
resolved, not by relocating anything, by construction: **R8.9's new
production entry point never calls `BASIC_COMMAND_LOOP`**, so V1's own
runtime `PROG_AREA` usage never happens in the new path. V1's source files
remain compiled into the image (dormant, unreachable — pending R9's actual
deletion), but nothing they contain executes, so there is no real
concurrent claim on that RAM region. V2's production program continues to
use `PROG_AREA_START`/`PROG_AREA_MAX` for the line-store exactly as V1
did, and V2's own small fixed tables continue to live at their existing
addresses within that same range — this only works because only one
"language core" is ever actually running data through that memory at a
time, which is now true by construction rather than by coincidence.

## 5. Concrete plan

New file: `rom/exrom_v2_production.asm` (or split further if size
warrants) — the V2-native production shell. Contents:

1. **`V2_HANDLE_NAV`** — the V2-native `EDITOR_NAV_HOOK` implementation.
   Same shape as `BASIC_HANDLE_NAV`: tracks current line position via
   `MEM_LINE_*`, loads/stores `EDIT_LINE_BUF` at that position. No new
   low-level mechanics — cursor movement, redraw, and row-shadow tracking
   are generic and untouched.
2. **`V2_BUILD_SOURCE_BUFFER`** — walks `MEM_LINE_FIRST/NEXT`, copies each
   line's content bytes into a buffer at `SRC_PTR`, emitting `:` in place
   of each line's stored `$0D` terminator (not copying it), and a
   trailing null. This is new code with zero changes to the
   already-proven compiler/lexer.
3. **`V2_COMMAND_LOOP`** — replaces `BASIC_COMMAND_LOOP`'s role.
   Simpler than V1's: no tokenization step needed (store `EDIT_LINE_BUF`
   text directly via `MEM_LINE_STORE`, matching what V1 effectively did
   anyway). Distinguishes immediate commands (RUN/LIST/NEW/SAVE/LOAD)
   from ordinary line storage using the same "are we editing an existing
   line" guard V1 already established as correct.
   - **RUN**: `V2_BUILD_SOURCE_BUFFER` → `COMPILE_PROGRAM` → `VM_RUN`.
   - **LIST**: walk `MEM_LINE_FIRST/NEXT`, print each line's raw stored
     text directly (already source; no decompile needed for this path).
   - **SAVE/LOAD**: call `STORAGE_SAVE`/`STORAGE_LOAD` unchanged on
     `PROG_AREA_START`/`PROG_END`.
   - **NEW**: clear the line-store (reuse whatever generic "reset"
     primitive `kernel/memory` already exposes, or the equivalent of
     `PROG_END := PROG_AREA_START`).
4. Reuse, unmodified: `EDITOR_ENTER`/`EDITOR_LOOP` (`rom/exrom_editor.asm`),
   `BASIC_REDRAW_PROGRAM`/`BASIC_PRINT_LINE_WRAPPED_COMMON`
   (`basic/editor_integration.asm` — confirmed by the dependency-mapping
   fork to be generic display/wrap logic despite the `BASIC_` prefix; if
   implementation reveals a real V1-language coupling inside these that
   wasn't caught by that read, this document will be corrected rather than
   silently worked around), `kernel/memory/memory.asm`'s line-store API,
   `kernel/storage/storage.asm`'s `STORAGE_SAVE`/`LOAD`.
5. New production build entry point: a new cold-start (replacing
   `rom/test_basic.asm`'s role of calling `BASIC_COMMAND_LOOP`) that
   initializes the same way and calls `V2_COMMAND_LOOP` instead. Exact
   file/Makefile wiring to be finalized during implementation — V1's own
   files stay in the tree and in the build (dormant) until R9 actually
   removes them, per the coexistence discipline already used through
   R1-R8.5.

## 6. Editor-integration classification (as requested)

- **A (generic, reusable, unconditionally kept)**: `EDITOR_ENTER`/
  `EDITOR_LOOP`/cursor movement/redraw dispatch (`rom/exrom_editor.asm`);
  `kernel/memory/memory.asm`'s entire line-store API; `STORAGE_SAVE`/
  `LOAD`; `BASIC_PRINT_LINE_WRAPPED_COMMON`/`BASIC_REDRAW_PROGRAM`'s
  generic wrapping/redraw mechanics (pending the caveat in §5.4).
- **B (V1 source/program-storage representation)**: none found —the
  storage representation itself turned out to already be generic (§1);
  there is no V1-specific representation to replace, only a V1-specific
  *hook implementation* (`BASIC_HANDLE_NAV`) to write a V2-native sibling
  for.
- **C (V1 interpreter-specific glue, not reused)**: `BASIC_TOKENIZE_LINE`
  (a no-op wrapper not worth reusing even though harmless);
  `BASIC_COMMAND_LOOP`'s own keyword-match dispatch table (RUN/NEW/HELP/
  LIST/EDIT/DELETE string matching) — V2 needs its own, since V2's
  command surface and error handling differ.
- **D (directly reusable by V2, as-is)**: `EDITOR_NAV_HOOK`'s contract
  itself; `MEM_LINE_*`; `STORAGE_SAVE`/`LOAD`.
- **E (needs a V2 adapter)**: the NAV hook *implementation*
  (`V2_HANDLE_NAV`, new, small, same shape as `BASIC_HANDLE_NAV`); the
  top-level command loop (`V2_COMMAND_LOOP`, new).

## 7. V1 extension packages — capability disposition

All six (`cplot`/`block`/`frame`/`invert`/`sprite`/`shapes`) use V1's old
register-passed extension ABI, none use R7.5's `ext_registry.asm` — all
six "need rebuilding for R7.5," confirmed, not "already representable."
Their actual drawing/collision primitives are already resident,
EXROM-independent kernel code (`kernel/graphics/graphics.asm`'s
`GFX_PLOT_CLIPPED`/`GFX_CIRCLE`/`GFX_FILL`, confirmed directly for
`sprite`/`shapes`; `cplot`/`block`/`frame`/`invert` are plain
rectangle/pixel operations of the same shape, not individually traced to
their exact kernel calls in this pass) — **no capability is lost**, only
the registration/dispatch wrapper needs migrating, which is R7.5-scope
work, not R8.9 or R9 scope. This is recorded here for the eventual R9
completion report, not actioned in R8.9.

## 8. What this design deliberately does NOT do

- Does not implement any of the four semantic-audit corrections (FLOAT
  operand handling, FOR/NEXT nesting, DIM round-trip, PROC/DEF-FN
  recursion) as part of R8.9, per explicit instruction — none of them are
  structurally required to make production integration possible. The one
  interaction worth noting: since this design keeps source text as the
  durable representation rather than bytecode, the DIM/decompiler
  round-trip defect (audit §14/§25 row 4) is **naturally sidestepped for
  the interactive LIST/EDIT path** (LIST shows stored source directly,
  never decompiles), but is **not resolved** — the decompiler itself is
  still incomplete for DIM, and anything that does rely on decompiling
  (round-trip verification, a future bytecode-only SAVE path) still hits
  the same gap. This is a sidestep, not a fix, and is recorded as such
  rather than presented as resolving that audit item.
- Does not touch `rom/exrom_checker.asm`, `rom/exrom_strfuncs.asm`,
  `rom/exrom_dim.asm`, `rom/exrom_arrays.asm`, or `basic/basic.asm`
  themselves — those stay exactly as they are, compiled but unreachable
  from the new entry point, pending R9.
- Does not attempt to make V2's SAVE files V1-compatible as a goal (they
  happen to share a byte format as a side effect of reusing the same
  storage layer, not because compatibility was required).

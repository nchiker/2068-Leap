# R8.9 handoff — design/dependency work complete, implementation not started

## Post-checkpoint update (after `e6fa96c`)

The RAM-map investigation and V2 workspace relocation have now been carried
out. Read `docs/R8_9_RAM_LEDGER.md` for the assembled sizes, selected
layout, 14-case standalone ZEsarUX regression result, and the newly measured
ROM integration gate. The historical state and next-step list below describe
the earlier `e6fa96c` handoff and are superseded for completed RAM work.
Production V2 boot, source staging, bounds enforcement, and interactive
hardware validation are still outstanding; R8.9 is not complete and R9 has
not begun.

**This is a handoff checkpoint, not an implementation checkpoint.** No
production code has been changed in this session. Read this file first,
then `docs/R8_9_PRODUCTION_INTEGRATION_DESIGN.md` (the design document
this session wrote, still current), then `docs/V2_SEMANTIC_CAPABILITY_
AUDIT.md`'s §0 correction, before doing any R8.9 implementation work.

## Repository state at handoff

- Current commit: `c8e7feb` ("R8.9 design: V2 production integration
  architecture").
- Working tree: clean (`git status` confirmed).
- Full commit chain this session, oldest to newest:
  `10a5a14` (prior baseline) → `588e63e` (unauthorized fork commit,
  reverted) → `eae2efa` (the revert) → `06f98ba` (semantic audit) →
  `8a316e7` (audit correction: R9 superseded, R8.9 mandated) → `c8e7feb`
  (R8.9 design document — this session's last commit).
- ROM: unchanged from baseline throughout this session — no production
  assembly file was touched. Last confirmed measurement (§2 of the audit
  doc, re-verified this session by exact `git diff 10a5a14` producing zero
  difference across all production files): **24,294 / 24,576 bytes used,
  282 bytes free.**
- RAM: no new allocation has been made. The RAM *problem* below is a
  pre-existing condition in the current committed source (V2's fixed
  tables were placed at literal addresses without checking V1's
  `PROG_AREA_START`), not something this session introduced. It was
  latent and harmless only because no test today exercises V2 running
  through the real multi-line program-storage path with a program long
  enough to trigger it.
- Regression status: unchanged from the audit's own baseline — 14/14
  currently-buildable `rom/test_v2_*.asm` tests pass on real ZEsarUX; 7
  excluded by flat-16K harness capacity (not product regressions);
  `test_v2_compiler_r2`-`r7` stale (confirmed missing-decompiler-include
  root cause, not a regression). Nothing in this session changed this —
  no test was run or re-run, since no code changed. This will need
  **re-confirming**, not assuming, once RAM relocation actually happens
  next session (see §6 below).

## What this session established, in order

### 1. The R9 audit was incomplete; R8.9 now exists because of it

The original semantic/capability audit's "READY FOR R9" verdict checked
V2 *language-component* completeness and *standalone-test* integration,
but never checked whether V2 was actually wired into the real production
ROM as an interactive environment. It is not. See `V2_SEMANTIC_
CAPABILITY_AUDIT.md`'s §0 for the full correction (already committed,
`8a316e7`). The one-sentence version: `grep` for `COMPILE_PROGRAM`/
`VM_RUN`/`DECOMPILE_PROGRAM`/`EDITOR_ENTER` in the real production build
targets (`rom/exrom_build.asm`, `rom/test_basic.asm`) returns zero
matches — V2 is only ever exercised by standalone test drivers.

### 2. `kernel/memory/memory.asm` is generic, reusable, and NOT V1-specific

This is the single most important, most reuse-enabling discovery of this
session. Confirmed by direct read, not assumption:

- Its own file header states it explicitly: "line storage, no line
  numbers," framed as reusable kernel infrastructure ("one
  implementation, several callers, per this project's 'kernel modules
  stay reusable' rule").
- Record format: `[length:2, little-endian, counts content+terminator]
  [content][terminator: $0D]` — no BASIC-specific parsing, no keyword
  compression.
- **V1's own program storage turns out not to be meaningfully
  "tokenized" at all.** `basic.asm`'s own header says so directly: "NO
  KEYWORD COMPRESSION... stores plain text, matched by string
  comparison at run time instead." `BASIC_TOKENIZE_LINE`
  (`basic/basic.asm:47-96`, read in full, hand-traced against the
  routine's own worked example) does a straight length-prefixed copy of
  `EDIT_LINE_BUF`'s text into `TOKEN_BUF` — no real transformation.
  `BASIC_DETOKENIZE_TO_BUF` (`basic/basic.asm:2234`) is the exact
  inverse: copy bytes until `$0D`, then null-terminate. Neither
  function does anything V1-language-specific.
- The public API — `MEM_LINE_FIRST`/`MEM_LINE_NEXT`/`MEM_LINE_STORE`/
  `MEM_LINE_INSERT`/`MEM_LINE_DELETE_RANGE`/`MEM_INIT`/`MEM_FITS_CHECK`
  — is addressed by **program position, not line number** ("there are
  no line numbers to store" — the file's own header), and every
  input/output contract was read directly (not inferred) from each
  routine's own header comment. Full read notes are in this session's
  conversation history if a future session needs the exact call
  signatures again; the short version: `MEM_LINE_STORE`/`INSERT` take
  `HL=position`, `DE=pointer to a length-prefixed record`, and return
  carry-set-on-overflow; `MEM_LINE_FIRST`/`NEXT` walk by position,
  returning `HL=0` at end-of-program.

**Consequence**: V2 does not need to invent a new multi-line program
storage/navigation layer. It can reuse this one, unmodified.

### 3. `basic/editor_integration.asm` is mature, reusable editor machinery — NOT V1 interpreter code, despite its name and location

Confirmed by direct caller check: `rom/exrom_editor.asm` — the same file
V2's own proven `EDITOR_ENTER`→`EDIT_LINE_BUF` path already uses —
directly calls `BASIC_HANDLE_NAV`, `BASIC_EDITOR_ENTER_EXROM`,
`BASIC_PRINT_LINE_WRAPPED_COMMON`, all defined only in this file. Its
`BASIC_` prefix is misleading; two independent research passes flagged
this explicitly as an easy-accidental-deletion trap for whoever eventually
does R9's actual file removal.

Read in more depth this session:

- `EDITOR_NAV_HOOK`'s contract (`rom/exrom_editor.asm:142`) is confirmed
  fully generic: called with `A = EDIR_UP/DOWN/DELETE_LINE/INSERT_LINE/
  NEXT_ERROR/PREV_ERROR`, must end in a normal `RET`. Nothing in the
  contract itself is V1-specific.
- `BASIC_HANDLE_NAV` (`basic/editor_integration.asm:175`) and
  `BASIC_LOAD_EDIT_LINE` (`:21`) are the V1 *implementation* of that
  hook — they only touch `CUR_EDIT_POS`/`CUR_EDIT_INDEX`/`VIEW_TOP_INDEX`
  (generic position/scroll sysvars) and call `MEM_LINE_*`/
  `BASIC_DETOKENIZE_TO_BUF` (itself trivial, per §2). Nothing about
  moving between statements or reloading the edit buffer is
  V1-language-specific.
- `BASIC_GOTO_EDIT_INDEX` (`basic/basic.asm:1238`), `BASIC_DO_SAVE`
  (`:1769`), `BASIC_IS_SENTINEL` (`:816`) were each individually read
  and confirmed generic (position/count/pointer arithmetic and a
  `STORAGE_SAVE` call with `PROG_AREA_START`/computed length — no
  language-specific logic in any of them).
- The full body of `BASIC_COMMAND_LOOP` (`basic/basic.asm:171` onward)
  was read end to end. Its overall *shape* — cold-boot setup, install
  redraw/nav hooks, load current line, enter editor, on return
  distinguish "committing an existing line" (never reinterpreted as a
  command — a real historical bug fix already lives here) from
  "immediate command" (RUN/NEW/LIST/HELP/EDIT/DELETE/SAVE/LOAD/LLIST,
  keyword-matched in sequence) from "store as a new line" — is directly
  reusable as the shape for a V2-native replacement loop. The only
  genuinely V1-language-specific pieces inside it are: the call to
  `BASIC_RUN` (V1's interpreter entry — needs a V2-native `RUN`
  replacement calling `COMPILE_PROGRAM`→`VM_RUN`), and the call to
  `BASIC_FULL_CHECK_EXROM` (V1's own live syntax-checker, run after every
  commit — V2 has no equivalent and does not obviously need one for
  R8.9's own gate, since V2 reports errors at RUN time instead).

**Consequence**: a V2-native production loop can reuse nearly everything
in `BASIC_COMMAND_LOOP`'s shape, `BASIC_HANDLE_NAV`, `BASIC_LOAD_EDIT_
LINE`, `BASIC_GOTO_EDIT_INDEX`, `BASIC_DO_SAVE`/`BASIC_DO_LOAD`, and
`BASIC_TOKENIZE_LINE`/`MEM_LINE_STORE` **completely unchanged, by calling
the existing labels directly** (these files stay compiled into the image
throughout R8.9 — only the *cold-start entry point* changes to call a new
V2 loop instead of `BASIC_COMMAND_LOOP`). The only genuinely new code
needed is: a V2-native command dispatcher (RUN/LIST/NEW/SAVE/LOAD, at
minimum) and a source-buffer-assembly routine (see §5).

### 4. `rom/exrom_checker.asm` is a mixed-purpose container, not a single-purpose V1 file

Confirmed (this finding predates this session slightly — from the R9
dependency-mapping fork — but is restated here since it is directly
relevant to what R8.9 must NOT touch): only 3 of its 12 fixed EXROM entry
stubs are checker-specific. The other 9 belong to SAVE/LOAD, HELP, and —
critically — **the calculator engine** (`EXROM_ENTRY_CALCULATE`,
`CALC_FP_TO_INT`, etc.), which V2's own `SQR`/`SIN` already depend on and
the semantic audit's own correction matrix cites for the still-pending
`INT()` fix. **R8.9 must not touch this file at all** — it isn't in
R8.9's scope (R8.9 adds a new entry point and new V2-native command-loop
code; it doesn't remove or restructure existing EXROM services). This is
recorded here only so a future session doesn't accidentally conflate
R8.9 work with R9 file-removal work.

### 5. V2's own proven compile/run/decompile contracts (exact, read from the real driver, not inferred)

From `rom/test_v2_editor_integration.asm`'s actual working code (already
hardware-validated, the ONLY currently-proven end-to-end path):

```
call COMPILER_INIT
ld   hl, <source text address>
ld   (SRC_PTR), hl
ld   hl, VM_CODE_BASE
ld   (EMIT_PTR), hl
call COMPILE_PROGRAM
ld   a, (COMPILE_ERROR_CODE)   ; 0 = ok
...
call VM_INIT
ld   hl, VM_CODE_BASE
ld   (VM_IP), hl
call VM_RUN
ld   a, (VM_ERROR_CODE)        ; 0 = ok
...
ld   hl, (EMIT_PTR)
ld   (DECOMP_END_ADDR), hl     ; required before DECOMPILE_PROGRAM
call DECOMPILE_PROGRAM
ld   a, (DECOMP_ERROR_CODE)    ; 0 = ok
```

Confirmed separately, by direct source read (not inferred from this
driver): `LEX_SKIP_SPACES` only skips literal space (`$20`) — it does
**not** skip `$0D`/`$0A`. This means a multi-line source buffer with raw
CR/LF between lines will NOT compile as one program; statements must be
`:`-joined. Any routine that assembles the line-store's separate records
into one buffer for `COMPILE_PROGRAM` must substitute `:` for each
record's stored `$0D` terminator (not copy it), and append a trailing
null.

`DECOMPILE_PROGRAM` writes to a **fixed** buffer, `DECOMP_OUT_BUF`
($8D00), CR-terminated per line — genuinely multi-line output, not
colon-joined. It is not parameterized to target a caller-supplied buffer.

### 6. The RAM collision — the actual blocking problem for implementation

This is the reason this session stopped before writing code, per your
explicit instruction. Documented precisely, with every address VERIFIED
this session (see the RAM map in §7 for full citations):

- `PROG_AREA_START` is currently **`$8455`** — this is a sysvars.inc
  sequentially-laid-out label (its value is a consequence of everything
  defined before it in that file, not an independently chosen constant;
  its own comment documents an extensive history of being moved down
  repeatedly over many prior sessions specifically to maximize program
  space: `$BC01`→`$B8B1`→...→`$8521`→`$8434`→`$84B4`→...→`$8455`).
- `FLOATTAB_BASE` (V2's own float-value table) begins at **`$8500`** —
  **only 171 bytes above `PROG_AREA_START`.**
- `MEM_FITS_CHECK` (the growth-ceiling check inside `MEM_LINE_STORE`/
  `MEM_LINE_INSERT`) compares the projected program size against
  `VARS_START`, a separate RAM cell that `MEM_INIT` defaults to
  `PROG_AREA_MAX` (`$C000`) — **it has no awareness whatsoever of V2's
  tables sitting at `$8500`+.**
- **Consequence, confirmed, not hypothetical**: as committed today, if
  V2's program-storage were wired to reuse this line-store unmodified,
  a program whose total stored text exceeds 171 bytes would not error —
  `MEM_LINE_STORE`/`INSERT` would report success and silently begin
  overwriting `FLOATTAB` (and beyond).
- `PROG_AREA_MAX = $C000` is a **deliberate, documented, hard platform
  reservation** — confirmed by its own comment in `include/sysvars.inc`:
  moved to `$C000` specifically "to formally reserve chunk 6
  ($C000-$DFFF) for EXROM paging." This is a real hardware-paging
  boundary, not a soft budget line — **do not raise it.**
- Reference measurements taken this session for other V2 tables (all
  confirmed by direct `equ` read, not estimated): `ARRTAB_BASE $8560`;
  `STRTAB_BASE $8600` (4 named vars × 32B = 128B, plus 2 temp slots);
  `VM_STACK` operand region `$8704`-`$877F`; `VM_CALL_STACK`
  `$8794`-`$879F` (6 return addresses); `CSYMTAB_BASE $8900` (16×9B=144B,
  ends `$8990`); `ARRSYMTAB_BASE $8990` (butts exactly against
  `CSYMTAB`'s own end); `LABELTAB_BASE $8A00`; `FIXUPTAB_BASE $8A60`;
  `SRC_PTR $8B00`/`EMIT_PTR $8B02`; `STRSYMTAB_BASE $8B60`;
  `DECOMP_OUT_BUF $8D00` (~400-560B); `DECOMP_END_ADDR $8E9F`;
  `VM_CODE_BASE $9000` (bytecode buffer — **no explicit size constant
  found**; the next allocation above it, `EXT2_TABLE $9820`, implies an
  unenforced assumption that compiled bytecode never exceeds ~2080
  bytes, which is itself worth flagging to whoever relocates things next
  — this ceiling is currently as informal/unverified as the 171-byte one
  was); `EXT2_TABLE $9820` (12×14B=168B, R7.5 extension registry, ends
  `$98C8`).

### 7. Architectural conclusion this session reached (see design doc §3 for full reasoning) — restated here because you asked for it to be explicitly evaluated, not assumed

**Preferred architecture, based on the evidence gathered**: the plain-
text generic line store (§2) is the authoritative, durable, editable BASIC
program representation. V2 bytecode is a derived, compiled-on-demand
execution representation, recompiled from the full current line-store
content every time the program actually runs (matching the exact
"compile the whole program as one unit" pattern every V2 milestone to
date has already proven — no V2 milestone has ever built or tested
incremental bytecode editing, and inserting/deleting a *line's worth of
compiled bytecode* is a materially harder problem than inserting/deleting
a *line of text*, since jump targets and fixups would need to shift).

This is **not** forced by the evidence alone — it is a real engineering
judgment call, made explicit in `R8_9_PRODUCTION_INTEGRATION_DESIGN.md`
§3, weighed against the earlier plan's own "bytecode-primary" framing
(`ARCHITECTURE_B_IMPLEMENTATION_PLAN.md:1343-1344`). No evidence gathered
this session contradicts it; nothing found this session should be read as
overturning this conclusion, but it is recorded as a judgment call, not a
proof, exactly as you asked.

One direct interaction with the RAM problem in §6: this architecture
means the *durable* representation (source text in the line-store) needs
substantially more room than a few hundred bytes to be a real production
capability — the 171-byte ceiling is a much more acute problem under this
architecture than it would be under a bytecode-primary architecture where
`VM_CODE_BASE`'s own (also currently unbounded) region would be the
binding constraint instead. This sharpens, rather than changes, the
recommendation in §9 below.

## 8. Integrated RAM map — VERIFIED vs. PROPOSED, clearly separated

**All entries in this table are VERIFIED (read directly from current
source this session or the immediately preceding session) unless
explicitly marked PROPOSED. No new addresses have been chosen — per your
explicit instruction, this session does not select relocation targets
without completing the analysis first.**

| Region | Address range | Size | Classification | Status |
|---|---|---|---|---|
| Screen/system area, ROM, stack, etc. below `$8455` | `$0000`-`$8454` | — | Reserved/platform | VERIFIED to exist (not re-audited byte-by-byte this session — out of scope) |
| `PROG_AREA_START` (line-store, program text) | `$8455`-`$84FF` (only 171 bytes before collision) | 171B usable today | Source/program storage | **VERIFIED — and VERIFIED UNSAFE at its current size** (see §6) |
| `FLOATTAB_BASE` | `$8500`-`$8556`(approx, 18×5B) | ~90B | Runtime variables (V2 float table) | VERIFIED |
| `ARRTAB_BASE` | `$8560`-? | not fully sized this session | Runtime variables (V2 arrays) | VERIFIED base only |
| `STRTAB_BASE` | `$8600`-`$8680`+temps | ~128B+temps | Runtime variables (V2 strings) | VERIFIED |
| VM operand stack | `$8704`-`$877F` | ~124B | Stack | VERIFIED |
| VM call stack | `$8794`-`$879F` | 12B (6 frames) | Stack | VERIFIED |
| `CSYMTAB_BASE` | `$8900`-`$8990` | 144B | Compiler scratch (numeric symbols) | VERIFIED |
| `ARRSYMTAB_BASE` | `$8990`-? | not fully sized this session | Compiler scratch (array symbols) | VERIFIED base only — **butts directly against CSYMTAB's end, no gap** |
| `LABELTAB_BASE` | `$8A00`-`$8A58` (8×11B) | 88B | Compiler scratch (labels) | VERIFIED |
| `FIXUPTAB_BASE` | `$8A60`-`$8AB8` (8×11B) | 88B | Compiler scratch (fixups) | VERIFIED |
| `SRC_PTR`/`EMIT_PTR` | `$8B00`-`$8B03` | 4B | Compiler scratch (pointers) | VERIFIED |
| `STRSYMTAB_BASE` | `$8B60`-? | not fully sized this session | Compiler scratch (string symbols) | VERIFIED base only |
| `DECOMP_OUT_BUF` | `$8D00`-~`$8F34` | ~400-560B | Decompiler/editor workspace | VERIFIED (approximate size per its own header comment) |
| `DECOMP_END_ADDR` | `$8E9F`-`$8EA1` | 2B | Decompiler scratch | VERIFIED |
| `VM_CODE_BASE` | `$9000`-? | **no size constant found** | Compiled bytecode | VERIFIED base only — **unbounded, informally capped by EXT2_TABLE's position** |
| `EXT2_TABLE` | `$9820`-`$98C8` (12×14B) | 168B | Extension/package RAM | VERIFIED |
| `PROG_AREA_MAX` | `$C000` | — | **Reserved/hardware-sensitive — EXROM paging boundary, chunk 6** | VERIFIED, documented, hard constraint, do not raise |
| Everything above `$C000` in this discussion | `$C000`-`$DFFF` (chunk 6) | — | Reserved/hardware (EXROM paging) | VERIFIED — not usable RAM while EXROM is paged in |

**No PROPOSED entries exist in this table.** This session deliberately
stopped short of choosing new addresses, per your explicit instruction
("Do not select new addresses merely to complete the handoff if the
evidence is incomplete"). What IS clear from the verified data: there is
real, contiguous free room between `EXT2_TABLE`'s end (`$98C8`) and
`PROG_AREA_MAX` (`$C000`) — roughly `0xC000 - 0x98C8 = 0x3738` = **14,136
bytes**, entirely unallocated by anything found this session. This is the
most promising candidate region for relocating V2's fixed tables to, but
this session does not commit to that conclusion — the next session should
verify nothing else already claims part of that range before treating it
as free (this session did not check, e.g., whether sprite buffers, the
label table `kernel/memory` itself maintains, or other kernel state also
live somewhere in that span).

## 9. The RAM-layout decision for the next session

**Explicit instruction, not a suggestion**: R8.9 must solve this properly.
The 171-byte ceiling (or any hand-picked small cap) is a **temporary
development-time corruption guard only** (e.g., `LD HL,$8500 / LD
(VARS_START),HL` immediately after `MEM_INIT`, so that overflow is a
caught, safe failure instead of silent corruption while the real fix is
designed) — it must not ship as R8.9's completed design.

**Recommended first task for the next session** (see exact framing in
§10): establish the complete integrated RAM map (verify the gaps this
session left open — `ARRTAB`'s real size, `ARRSYMTAB`'s real size,
`STRSYMTAB`'s real size, `VM_CODE_BASE`'s real maximum reasonable size,
whether anything else lives in the `$98C8`-`$C000` candidate region), THEN
decide where V2's fixed tables should actually live, THEN relocate them
by changing only their `equ` values (every reference in the current
source uses symbolic names, confirmed by inspection during this session —
no hardcoded literal addresses were found referencing these tables
elsewhere), THEN rerun the full currently-buildable regression suite (14
tests) on real ZEsarUX via `ts2068-debug`/the `2068-debug` skill to
confirm the relocation is behavior-preserving. **A test that fails after
relocation because it hardcoded an absolute address is a real bug to fix
(remove the hardcoding), not a reason to revert the relocation.**

Only after that relocation is validated should the next session write
the actual new production code (`V2_HANDLE_NAV`-equivalent reuse,
`V2_BUILD_SOURCE_BUFFER`, `V2_COMMAND_LOOP`, the new cold-start entry
point) described in `R8_9_PRODUCTION_INTEGRATION_DESIGN.md` §5.

## 10. Exact next steps for the next coding session, in order

1. **Read this file, then `R8_9_PRODUCTION_INTEGRATION_DESIGN.md` in
   full, then `V2_SEMANTIC_CAPABILITY_AUDIT.md`'s §0.** Verify
   `git log -1` shows `c8e7feb` or later and the working tree is clean.
2. **Close the RAM-map gaps §8 left open**: read `ARRTAB_BASE`'s real
   sizing (`ARRAY_MAX_ELEMS` × entries × element size), `ARRSYMTAB_BASE`'s
   and `STRSYMTAB_BASE`'s real sizes, and grep the whole repo for any
   other allocation between `$98C8` and `$C000` before treating that
   range as free.
3. **Decide the new addresses** for V2's fixed tables (FLOATTAB/ARRTAB/
   STRTAB/VM stack/CSYMTAB/ARRSYMTAB/LABELTAB/FIXUPTAB/SRC_PTR+EMIT_PTR/
   STRSYMTAB/DECOMP_OUT_BUF+DECOMP_END_ADDR/VM_CODE_BASE/EXT2_TABLE),
   moving them as a block into the freed region near `$C000`, leaving
   `PROG_AREA_START` (`$8455`) through wherever the relocated tables now
   begin as the program-text line-store's real, adequately-sized growth
   room. Update each `equ` value only — do not restructure any routine's
   logic.
4. **Rebuild and rerun all 14 currently-buildable `rom/test_v2_*.asm`
   tests on real ZEsarUX** (`z80-skills`/`2068-debug` skill workflow) to
   confirm the relocation is behavior-preserving. Fix any hardcoded-
   address bug this exposes; do not revert the relocation to make a
   bug disappear.
5. **Only then** implement `R8_9_PRODUCTION_INTEGRATION_DESIGN.md` §5's
   new production code (source-buffer assembly, V2-native command loop
   reusing `BASIC_HANDLE_NAV`/`BASIC_LOAD_EDIT_LINE`/`BASIC_GOTO_EDIT_
   INDEX`/`BASIC_DO_SAVE`/`BASIC_DO_LOAD`/`BASIC_TOKENIZE_LINE`/
   `MEM_LINE_STORE` unchanged, new cold-start entry point), building and
   hardware-validating incrementally, per the 15-scenario validation list
   already agreed for R8.9's own success gate.
6. **Do not begin R9, implement the four semantic-audit corrections, or
   implement DEF FN** — all explicitly out of scope until R8.9's own
   success gate is demonstrated and you review it.

## 11. Files/symbols expected to change vs. must be preserved

**Expected to change next session** (values only, not logic, for the
relocation step): the `equ` lines for `FLOATTAB_BASE`, `ARRTAB_BASE`,
`STRTAB_BASE`, `VM_STACK_TOP`/`FLOOR`, `VM_CALL_STACK_TOP`/`FLOOR`,
`CSYMTAB_BASE`, `ARRSYMTAB_BASE`, `LABELTAB_BASE`, `FIXUPTAB_BASE`,
`SRC_PTR`/`EMIT_PTR`, `STRSYMTAB_BASE` (all in `rom/exrom_v2_compiler.asm`
or `rom/exrom_v2_vm_core.asm` — exact file per each symbol, see §8's
citations), `DECOMP_OUT_BUF`/`DECOMP_END_ADDR` (`rom/
exrom_v2_decompiler.asm`), `EXT2_TABLE` (`kernel/extensions/
ext_registry.asm`). Then, new files: a V2 production shell (name TBD,
`R8_9_PRODUCTION_INTEGRATION_DESIGN.md` §5 suggests `rom/
exrom_v2_production.asm`) and a new production cold-start entry point.

**Must be preserved, unmodified**: `kernel/memory/memory.asm` (§2),
`basic/editor_integration.asm` (§3), `rom/exrom_editor.asm`,
`rom/exrom_checker.asm` (§4 — not R8.9 scope at all), `kernel/storage/
storage.asm`, every currently-passing test's own logic (only rebuild+
rerun them, don't edit their expectations to force a pass).

## 12. Unresolved questions for the next session (not decided here)

- Exact new addresses for the relocated V2 tables (§9/§10 step 3 — needs
  the gap-closing in step 2 first).
- Whether `VM_CODE_BASE`'s bytecode buffer needs an explicit, enforced
  size limit (it currently has none — the `$9820` `EXT2_TABLE` placement
  only *implies* an unenforced ~2080-byte assumption).
- Whether anything currently lives in the `$98C8`-`$C000` candidate
  region that this session didn't check for.
- Whether `BASIC_PRINT_LINE_WRAPPED_COMMON`/`BASIC_REDRAW_PROGRAM` (relied
  on for display reuse in the design doc) have any hidden V1-keyword-
  highlighting dependency that would need a V2-side adjustment (not
  verified this session — flagged as a design-doc caveat already, repeated
  here for visibility).
- Whether V2 needs an equivalent of `BASIC_FULL_CHECK_EXROM` (V1's live
  post-commit syntax checker) for a good editing experience, or whether
  "errors surface at RUN time only" is an acceptable, deliberate V2
  simplification for R8.9's own gate (leaning toward the latter, not
  decided).

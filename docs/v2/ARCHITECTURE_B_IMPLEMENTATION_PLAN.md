# 2068-Leap V2 — Architecture B Implementation Plan

**Status: planning document. No production code has been written under
this plan yet.** Triggered by Architecture B's acceptance
(`docs/v2/V2_ARCHITECTURE.md`, gated on `docs/v2/STATEMENT_COMPILER_SPIKE.md`
passing all seven acceptance gates). This plan defines the complete
migration from V1's current language core to the production V2 language
core, staged so V1 keeps working throughout — no flag-day replacement.

**Mutation boundary**: per this project's standing dossier policy
(`specs/2068-leap-v2.md`) and `IMPLEMENTATION_PLAN.md`'s own stated rule
("nothing in this plan authorizes implementation by itself"), beginning
work on R1 below is a real, first-time mutation of `rom/`, `basic/`,
`kernel/`, `include/` for this initiative and requires the same explicit
acceptance step every prior mutation in this project's history has gone
through (P0.1 through P0.4 were each presented and accepted before their
diffs landed). This plan is the artifact that makes that acceptance
concrete — it does not substitute for it.

## Guiding constraints (carried forward, unchanged)

- Platform (editor, display, graphics, sprites, sound, input, storage,
  kernel, calculator) is reused unchanged throughout. No milestone below
  touches `kernel/graphics/graphics.asm`, `rom/exrom_editor.asm`,
  `rom/exrom_sprite.asm`, `rom/exrom_calc.asm`, `rom/exrom_storage.asm`, or
  any other platform module's internal implementation — only their calling
  convention from the new language core, where needed.
- V1's language core (`basic/basic.asm`, `rom/exrom_checker.asm`,
  `rom/exrom_strfuncs.asm`, `rom/exrom_dim.asm`, `rom/exrom_arrays.asm`)
  keeps working, unmodified, until R9. `RUN` continues to execute existing
  programs via the V1 path until the new path is proven.
- Every milestone ships with a real, measured ROM/RAM delta and a real
  emulator-validated test, per this project's established engineering
  discipline (IMPLEMENT → BUILD → TEST → BOOT → DEBUG → MEASURE ROM →
  MEASURE RAM → BENCHMARK → DOCUMENT → COMMIT).
- Development-phase ROM may temporarily exceed 24KB while V1 and V2 cores
  coexist (V2's new code + V1's old code both resident, e.g. in a larger
  test/dev image, or with V1 temporarily paged elsewhere for test builds).
  **The shipping configuration must fit 24KB** — this is checked explicitly
  at every milestone's ROM budget line, distinguishing DEV ROM (temporary,
  coexistence-inclusive) from SHIP ROM (projected, post-V1-removal).

## Continuous ROM accounting (maintained from R1 onward)

| | Bytes |
|---|---:|
| PLATFORM ROM (unchanged throughout) | 9,925 (VERIFIED, `61bb8bb`) |
| NEW V2 LANGUAGE CORE ROM (grows milestone by milestone) | 0 at R1 start → 4,880-6,530 at R9 |
| TEMPORARY V1 LANGUAGE CORE ROM (shrinks as V1 statement types are cut over, removed entirely at R9) | 13,988 at R1 start → 0 after R9 |
| FINAL PROJECTED SHIP ROM AFTER V1 REMOVAL | 9,925 + (4,880 to 6,530) = 14,805-16,455 |
| ENGINEERING RESERVE (ship) | 8,121-9,771 |

This table is re-measured (`make budget`-equivalent for whatever dev image
exists) and re-published at the end of every milestone below, not just
computed once here.

## Continuous RAM accounting (maintained from R3 onward, once programs run)

Tracked per `docs/v2/REWRITE_RAM_BUDGET.md`'s categories: compiled program
storage (bytecode), symbol table, variables, strings, arrays, VM operand
stack, procedure call frames, compiler workspace, editor workspace,
temporary compilation structures. **Lifetime-based reuse identified now,
applied starting R2**: compiler workspace (the lexer's token buffer, the
compile-time symbol table, the fixup list) and the VM's runtime operand
stack cannot be live simultaneously (compilation completes before
execution begins, per the chosen "compile-on-RUN into the primary bytecode
store" design) — so compiler workspace and VM operand-stack space can
occupy the **same RAM region**, freed/reused rather than both reserved
permanently. This is the single largest RAM-reuse opportunity identified;
it is designed in from R2, not retrofitted later.

## Milestone sequence

Derived from dependency order (VM before compiler needs it to target
something real; compiler foundation before program execution; structured
language and strings after the basics execute correctly; platform
integration once the VM can call out; editor integration last, once the
compile/decompile contract is stable; V1 removal only once V2 covers
V1's full statement set; optimization last).

### R1 — VM foundation

**Status: COMPLETE for R1's own scope ("production-quality VM with integer
execution and tests" — floats/strings/platform-calls are R5/R6/R7's job,
not R1's, per this plan's own staging).** `rom/exrom_v2_vm_core.asm` now
implements the full 17-opcode integer-domain set: `HALT`, `PUSH_I8`,
`PUSH_I16`, `LOAD_VAR`, `STORE_VAR`, `ADD`, `JMP`, `SUB`, `MUL`, `DIV`,
`CMP_LT`, `CMP_EQ`, `JMPZ`, `FOR_INIT`, `FOR_NEXT`, `CALL`, `RET` — **731
real assembled bytes**, real-hardware-validated on ZEsarUX via
`ts2068-debug`:

- Milestone 01's original 7 opcodes: validated as documented in
  `ARCHITECTURE_B_MILESTONE_01.md` (O(1) branch, zero-calculator integer
  path, both confirmed on real hardware).
- The 10 opcodes added to complete R1 (`SUB`/`MUL`/`DIV`/`CMP_LT`/`CMP_EQ`/
  `JMPZ`/`FOR_INIT`/`FOR_NEXT`/`CALL`/`RET`): three new representative
  programs — a comparison (`3<5`), a real *terminating* `FOR`/`NEXT` loop
  (`FOR I=1 TO 5: SUM=SUM+I: NEXT I`, correctly producing `SUM=15`,
  `I=6`), and a `CALL`/`RET` procedure (doubling a value via a bytecode
  subroutine, correctly producing `14`) — all three verified correct on
  real ZEsarUX, chained with Milestone 01's original tests into a single
  5-test PASS/FAIL border verdict (green).
- **A second real bug was found and fixed during this extension**:
  `OP_CALL` computed the call target into `DE`, then called
  `VM_CALL_PUSH` — which uses `DE` as internal scratch and clobbers it —
  before using `DE` to set `VM_IP`. The bytecode's `CALL` correctly pushed
  a return address, but `VM_IP` silently stayed at the return address
  instead of jumping into the callee, so the "doubled" value never
  actually got computed (`ARG` stayed `7`, not `14`). Caught immediately
  by the real ZEsarUX run (red border despite `VM_ERROR_CODE=0` — no
  crash, just a silently-skipped procedure body), root-caused by
  single-stepping through `OP_CALL` with `ts2068-debug step`/`regs`, fixed
  by setting `VM_IP` from a register never passed through the
  `VM_CALL_PUSH` call at all, reassembled, reverified green. Documented in
  the module's own header comment at the fix site, not just here.
- Reused, not reimplemented: `MATH_MULTIPLY16`/`MATH_DIVIDE16`/
  `MATH_COMPARE16` (`kernel/math/math.asm`, already-verified platform
  primitives) back `MUL`/`DIV`/`CMP_LT`/`CMP_EQ`/`FOR_NEXT` — the "reuse
  mature platform components" architecture-discipline rule applied for
  real, confirmed by the test driver now `INCLUDE`-ing `kernel/math/
  math.asm` directly rather than stubbing those calls.
- Deliberate, documented compatibility break: `DIV` uses the fast native
  `MATH_DIVIDE16` primitive directly for the integer case, rather than
  V1's own precedent of always round-tripping every integer division
  through the float calculator (`NUMERIC_DESIGN.md`, VERIFIED baseline).
  Divide-by-zero raises a real, caught VM error instead of V1's silent 0.
- Updated ROM projection: 731 bytes / 17 opcodes ≈ 43 bytes/opcode
  average (fixed shared infrastructure, now including the VM's own
  bounds-checked call stack, ≈245 bytes; opcode table 2 bytes/opcode;
  handlers averaging ≈27 bytes/opcode for this integer-heavy set).
  Extrapolating to the full ~40-opcode VM (the remaining ~23 being mostly
  cheap native-call trampolines for strings/platform, R5/R7 scope):
  **≈1,100-1,150 bytes** — still comfortably inside
  `REWRITE_ROM_BUDGET.md`'s reserve, now backed by real data for 17 of the
  ~40 opcodes rather than 7.
- Shipping ROM confirmed unaffected throughout (fresh `make budget`:
  identical 554 HOME / 109 EXROM free; `git status` shows no file under
  `rom/`, `basic/`, `kernel/`, `include/` was modified except the two new,
  unwired files this milestone/R1 added).
- Regression: the full existing V1 suite was re-run once, in full, after
  Milestone 01's original 7-opcode work (`tools/run_all_tests_fast.py`,
  real result: **PASS: 102  FAIL: 0**, 756.5s, 4 ZEsarUX restarts). Not
  re-run a second time for this extension, since no production file
  changed between the two — the same structural argument
  (`git status`/`make budget` parity) applies, and is stated here
  explicitly rather than silently assumed.

**R1 is done. Next: R2 (compiler foundation — tokenizer/front end +
expression + basic statement compiler, targeting this VM).**

- **Objective**: a production-quality bytecode VM (dispatch loop, ~40
  opcodes, symbol-index access, operand stack, tag-gated integer/float
  dispatch) that can execute a hand-assembled bytecode program, with no
  compiler yet.
- **Dependencies**: none (first milestone).
- **Files**: new `rom/exrom_v2_vm.asm` (or equivalent — final placement
  decided against the residency/paging framework `ARCHITECTURE_COMPARISON.md`
  already recommends adopting). Does not touch any existing file.
- **Implementation**: promote `spikes/v2_vm_sizing/vm_sizing_spike.asm`'s
  architecture to production quality: real error handling on stack
  underflow/overflow, real symbol-table record layout (not the spike's
  placeholder constants), real calls into `rom/exrom_calc.asm` (not stub
  `RET`s), a bounded operand stack with overflow detection.
  the compiler foundation (R2) needs to target.
- **Tests**: hand-assembled bytecode test programs (arithmetic, variable
  load/store, a hand-written loop) executed directly against the VM,
  bypassing the compiler entirely.
- **Emulator validation**: real ZEsarUX/`ts2068-debug` run of each test
  program, checked register/memory state, not just "assembles clean."
- **ROM budget**: target 900-1,100 bytes for the VM itself (per
  `REWRITE_VM_DESIGN.md`'s measured extrapolation); DEV ROM temporarily
  adds this on top of the full existing V1 image (coexistence, not
  shipping).
- **RAM budget**: operand stack + symbol table region sized and documented;
  no program-storage RAM impact yet (no compiler exists to produce
  programs).
- **Performance gate**: hand-assembled integer-arithmetic bytecode loop
  benchmarked against V1's existing isolated-benchmark numbers
  (`PERFORMANCE_BASELINE.md`'s addition/multiplication/division/FOR-NEXT
  figures) — must be competitive, not necessarily identical (different
  dispatch mechanism).
- **Success gate**: all hand-assembled test programs execute correctly on
  real hardware/emulator; ROM cost within 15% of the 900-1,100 estimate;
  no regression to any existing V1 test (V1 is untouched, so this should be
  automatic, but the full existing test suite is re-run to confirm).
- **Rollback**: delete the new file(s); zero impact on any existing
  system, since nothing else references them yet.

### R2 — Compiler foundation

**Status: COMPLETE, real-hardware-validated.** `rom/exrom_v2_compiler.asm`
(674 real assembled bytes) implements a production-quality lexer, a REAL
compile-time symbol table (`[name_len:1][name:8]` records, real byte-by-
byte comparison — not the sizing spikes' increment-and-return stub), a
real 4-operator expression compiler, and an assignment-statement compiler,
targeting R1's real VM opcode set directly. `rom/test_v2_compiler_r2.asm`
compiled the source text `SCORE=3+4*2:TOTAL=SCORE+10:SCORE=SCORE+1` (real
multi-character identifiers, not single letters) to real bytecode and
executed that bytecode on R1's real VM core — the full compile-then-
execute round trip R2's own success gate requires. Real ZEsarUX result:
**SCORE=12, TOTAL=21 — exactly correct**, confirming both the arithmetic
(precedence: `4*2` before `+3`) and, critically, that re-referencing an
already-declared multi-character name (`SCORE` used three times) resolves
to the *same* symbol index every time rather than creating duplicates.

**Two more real bugs found and fixed via ZEsarUX runs, not by inspection**
(bringing this project's real-hardware-caught bug count for the V2 rewrite
to four, across Milestone 01, R1, and R2):
1. `COMPILE_ASSIGN` saved the assignment target's symbol index in register
   `C` across the call to `COMPILE_EXPR` — but `COMPILE_EXPR` calls
   `CSYM_FIND_OR_CREATE` for any identifier inside the expression (e.g.
   the `SCORE` in `TOTAL=SCORE+10`), and that routine uses `C` as its own
   scan-index scratch register, clobbering the saved target before
   `STORE_VAR` could use it. First real run: `STORE_VAR` targeted the
   wrong symbol slot entirely (`STORE_VAR 2` instead of `STORE_VAR 0`).
   Fixed by moving the saved index to a dedicated memory cell
   (`ASSIGN_TARGET_INDEX`) instead of a register.
2. `COMPILE_IDENT_LOAD` called `CSYM_FIND_OR_CREATE` (index returned in
   `A`), then called `EMIT_BYTE_OP_LOAD_VAR` — which does `ld a,3` to load
   the opcode value before emitting it — clobbering the real index before
   it could be emitted as the operand. Every `LOAD_VAR` silently emitted
   the opcode number as its own bogus operand instead of the real symbol
   index. Second real run (after fixing bug 1): `STORE_VAR` targets were
   now correct, but every identifier *reference* inside an expression
   resolved to the same wrong constant. Root-caused by decoding the actual
   compiled bytecode byte-by-byte via `ts2068-debug mem`, not by re-reading
   the source. Fixed the same way — save to a dedicated memory cell
   (`IDENT_LOAD_INDEX`) before the emit call, reload after.
- Both bugs are the same underlying class: a value needed after a call to
  one of the `EMIT_BYTE_OP_*` helpers (which load a fixed opcode number
  into `A` or use registers as scratch) must be saved to memory first, not
  left in a register — now documented at both fix sites and worth keeping
  in mind for R3's larger statement compiler.
- A third, latent (never actually triggered) stack-imbalance bug was
  caught by inspection before assembling: a zero-length-name guard inside
  `CSYM_FIND_OR_CREATE` jumped to its `.match` exit without popping a
  value pushed just before it. Real identifiers are never zero-length (the
  lexer guarantees at least one letter), so this never fired in practice,
  but it was fixed anyway rather than left as a latent hazard.
- ROM cost: 674 bytes (lexer 229, real symbol table 127, emitter 53,
  expression compiler 147, assignment-statement compiler 51, program
  driver + init 46, roughly) — within `REWRITE_VM_DESIGN.md`'s expression-
  compiler-plus-statement-compiler estimates, on the low end because R2's
  scope (assignment only) is narrower than the full statement set those
  estimates costed.
- Shipping ROM confirmed unaffected (`make budget`: unchanged 554/109
  free; no file under `rom/`, `basic/`, `kernel/`, `include/` modified
  except the two new, unwired files this stage added).

**R2 is done. Next: R3 (program execution — extend the compiler to
`IF`/`GOTO`/`FOR`/`NEXT` and full variable handling, using R1's VM opcodes
that already support this — `JMPZ`, `FOR_INIT`, `FOR_NEXT` — but which R2's
compiler doesn't yet target).**

<details>
<summary>Original R2 plan (superseded by the COMPLETE status above; kept for the record)</summary>

- **Objective**: tokenizer/lexer + expression compiler + a minimal
  statement compiler (assignment only) producing real bytecode for R1's
  VM, callable standalone (not yet wired into `RUN`).
- **Dependencies**: R1 (needs a real opcode/operand contract to target).
- **Files**: new `rom/exrom_v2_compiler.asm`. Does not touch any existing
  file.
- **Implementation**: promote `spikes/v2_vm_sizing/compiler_sizing_spike.asm`
  and `statement_compiler_spike.asm`'s architecture to production quality:
  real symbol-table record writes (not stubs), real fixup-table patch
  writes (not stubs), integration with R1's real VM opcode/operand layout.
- **Tests**: compile representative expressions and one assignment
  statement; feed the resulting bytecode directly to R1's VM; verify
  correct execution.
- **Emulator validation**: same discipline as R1 — real run, checked state.
- **ROM budget**: target ~700-900 bytes (lexer + expr compiler +
  assignment-family compiler + shared emitter/symtab, a subset of
  `STATEMENT_COMPILER_SPIKE.md`'s full projection).
- **RAM budget**: compiler workspace region sized; confirm the R1/R2
  lifetime-non-overlap assumption (compiler workspace freed before VM
  executes) holds for this minimal case.
- **Performance gate**: compile time for a representative small program
  measured (should be sub-visible, consistent with the checker's existing
  whole-program-scan-before-RUN precedent).
- **Success gate**: compile-then-execute round-trip correct for
  arithmetic + assignment; V1 fully unaffected (still not wired in).
- **Rollback**: delete the new file(s).

</details>

### R3 — Program execution (branches, loops, variables)

**Status: COMPLETE, real-hardware-validated.** `rom/exrom_v2_compiler.asm`
grew from R2's 674 bytes to **1,550 bytes** (+876 for `GOTO`, `IF...THEN
GOTO`, `FOR`/`NEXT`, real labels, and real forward-reference fixups).
`rom/test_v2_compiler_r3.asm` compiled a genuinely nontrivial 14-statement
program exercising every one of R3's new mechanisms together — a backward-
referenced `IF...THEN GOTO` inside a real counting loop, a forward-
referenced unconditional `GOTO` (the one code path Milestone 01/R1/R2 never
exercised, since `GOTO SKIP` targets a label defined *later* in the
program — a real test of `RESOLVE_ALL_FIXUPS`, not just `LABEL_LOOKUP`'s
already-defined-label path), a real `FOR`/`NEXT` loop, and a negative test
that the `GOTO` genuinely skips its target statement rather than merely not
crashing (a sentinel variable, `BOGUS`, is set before the skip region and
checked afterward). Real ZEsarUX result: **every one of six symbol values
matched their hand-computed expectation exactly** (`TOTAL=15`, `COUNT=6`,
`BOGUS=0`, `SQUARE=14`, `I=4`, `RESULT=29`).

**Four more real bugs found via ZEsarUX execution and fixed** (bringing
this rewrite's real-hardware-caught bug total to eight across Milestone
01/R1/R2/R3):
1. The lexer's label-vs-statement-separator disambiguation (an identifier
   immediately followed by `:` with no space = label) misclassified any
   *expression-internal* identifier reference that happened to be
   immediately followed by a statement-separator `:` — e.g. the `COUNT` in
   `TOTAL+COUNT:COUNT=COUNT+1`. Real run: `COMPILE_ERROR_CODE=3` with a
   missing operand in the emitted bytecode. Fixed by removing the lexer-
   level heuristic entirely and doing label detection exclusively via a
   real one-token lookahead in `COMPILE_PROGRAM`, which only ever runs at
   genuine statement starts and therefore cannot misfire mid-expression.
2. `LEX_CLASSIFY_KEYWORD`'s original ad-hoc branch chain (try `GOTO`, on
   failure try `NEXT`, which returned unconditionally on ITS failure)
   never actually reached the `THEN` check for any input — `THEN` was dead
   code. Real run: every `IF...THEN GOTO` failed with
   `COMPILE_ERROR_CODE=8` ("expected THEN"), because `THEN` lexed as a
   plain identifier. Fixed by replacing the whole ad-hoc chain with a real
   table-driven matcher (6 fixed-width entries, one loop) — structurally
   immune to "one candidate's failure path forgets to fall through to the
   next" by construction.
3. `RESOLVE_ALL_FIXUPS` never saved its own outer fixup-index (`C`) across
   the call to `LABEL_LOOKUP`, which uses `C` internally as its own scan
   index and does not restore it. The lookup itself succeeded and patched
   correctly every time; the *corrupted loop counter afterward* sent the
   outer loop into a bogus extra iteration over uninitialized fixup-table
   memory, producing a spurious "undefined label" error despite the real
   resolution having already worked. Root-caused by single-stepping the
   actual instruction sequence (`ts2068-debug step`/`regs`) through a real
   run, watching `C`'s value survive or not across the call — not visible
   from reading the source. Fixed by saving the index to a dedicated
   memory cell before the call.
4. `COMPILE_NEXT` kept a 2-byte relative branch offset in `HL` across a
   call to `EMIT_BYTE` for its low byte — but `EMIT_BYTE` itself uses `HL`
   internally as the `EMIT_PTR` pointer, clobbering it, so the subsequent
   `ld a,h` read `EMIT_PTR`'s own high byte instead of the offset's real
   (always-zero, for realistic program sizes) high byte. Real run:
   `FOR`/`NEXT` branched to a nonsense absolute address, producing
   `VM_ERROR_CODE=1` (illegal opcode). Fixed by saving the high byte to
   memory before the low byte's `EMIT_BYTE` call.

**A fifth issue was a genuine logic bug, not a register-clobber**:
`COMPILE_IF`'s first working version emitted only `JMPZ <label's resolved
offset>` — but `JMPZ` branches when the popped condition **is** zero
(false), so that compiled "jump to the label when the condition is
false," backwards from `IF...THEN GOTO`'s actual meaning. Caught by
decoding the real compiled bytecode after a run that produced
`VM_ERROR_CODE=1` once the (inverted) loop ran long enough to branch
somewhere nonsensical. Fixed to the correct three-instruction shape:
`JMPZ <skip>` / `JMP <label>` / `<skip>:`, so a false condition falls
through past the `GOTO` instead of taking it, and a true condition takes
it — using a second, purely local forward-reference patch (`IF_SKIP_
PATCH_TMP`) resolved immediately at the end of `COMPILE_IF` itself, not
through the general fixup mechanism (its target is always known by the
time `COMPILE_IF` finishes, unlike a `GOTO` to a label that may not exist
yet anywhere in the program).

**Known, documented limitation carried forward from R1 unchanged**: single
active loop only (`FOR_LOOP_TOP_OFFSET`/`FOR_LOOP_VAR_INDEX` are scalars,
matching R1's VM core's own single `VM_FOR_LIMIT` slot) — nested `FOR`/
`NEXT` is not yet supported. Not required by this milestone's own success
gate.

Shipping ROM confirmed unaffected (`make budget`: unchanged 554 HOME / 109
EXROM free).

**R3 is done. Next: R4 (structured language — procedures/functions).**

<details>
<summary>Original R3 plan (superseded by the COMPLETE status above; kept for the record)</summary>

- **Objective**: extend the compiler to `IF`/`GOTO`/`FOR`/`NEXT` and full
  variable handling (multi-character identifiers, per
  `STRING_AND_SYMBOL_DESIGN.md`'s already-agreed goal); extend the VM
  correspondingly if any gap is found. First milestone where a real,
  nontrivial BASIC-shaped program (using this study's LARGE/TYPICAL worked
  examples as templates) compiles and runs standalone.
- **Dependencies**: R1, R2.
- **Files**: extends `rom/exrom_v2_compiler.asm`, `rom/exrom_v2_vm.asm`.
- **Implementation**: promote the remaining families measured in
  `STATEMENT_COMPILER_SPIKE.md` (branch, loop) to production quality,
  including real forward-reference resolution across a whole program (not
  the spike's single-statement scope).
- **Tests**: the SMALL and TYPICAL worked programs from
  `REWRITE_RAM_BUDGET.md`, written for real, compiled, executed, checked
  against hand-computed expected results.
- **Emulator validation**: real run of both worked programs.
- **ROM budget**: target the branch+loop family additions from
  `STATEMENT_COMPILER_SPIKE.md` (~140-210 bytes on top of R2's assignment
  family).
- **RAM budget**: measure the SMALL/TYPICAL programs' real compiled size
  against `REWRITE_RAM_BUDGET.md`'s estimates; reconcile any gap.
- **Performance gate**: **the single most important benchmark in this
  entire plan** — a GOTO-based loop, structurally identical to the one
  that failed to complete in 20,000,000 opcodes under V1
  (`PERFORMANCE_BASELINE.md`), compiled and run under V2. Must complete
  quickly, with a compiled O(1) branch, not a source rescan. This is the
  direct, load-bearing validation of this whole rewrite's central
  performance claim.
- **Success gate**: worked programs correct; GOTO-loop benchmark passes
  (completes, and fast); V1 still fully unaffected.
- **Rollback**: revert this milestone's diff; R1/R2 remain intact and
  useful on their own.

</details>

### R4 — Structured language (procedures/functions)

**Status: COMPLETE, real-hardware-validated.** `rom/exrom_v2_compiler.asm`
grew from R3's 1,550 bytes to **1,912 bytes** (+362 for `PROC`/`ENDP`
declarations and `CALL`, on top of R1's already-existing `CALL`/`RET`
opcodes and bounds-checked VM call stack — no VM changes were needed for
R4 at all). `rom/test_v2_compiler_r4.asm` compiled and executed a real
program with two procedures: `PROC DOUBLE(N):RESULT=N+N:ENDP` (declared
*before* its call site — a backward reference, resolved immediately, same
as R3's backward `GOTO`) and `PROC TRIPLE(N):RESULTB=N+N+N:ENDP` (declared
*after* its call site — a genuine forward reference through
`RESOLVE_ALL_FIXUPS`, the one path R3's `GOTO` test didn't need, since a
procedure's own body is preceded by a compiler-emitted `JMP` skipping over
it that must ALSO be patched correctly before the fixup pass runs). Real
ZEsarUX result: **all five checked values matched their hand-computed
expectations exactly** (`RESULT=42`, `ANSWER=42`, `RESULTB=15`,
`ANSWERB=15`, `FINAL=1`), including confirming that normal sequential
execution correctly skips over both procedure bodies via their own leading
`JMP`, landing cleanly on the final statement without ever falling into a
body a second time.

**Deliberate, documented scope limitation, not a bug**: both procedures
use a parameter named `N` — the SAME global symbol slot, since this
milestone's scope (per the plan's own "by-value parameters, one level of
locals" framing) has no separate per-call local-variable frame. The test
program deliberately exercises this (both procedures share `N`, and the
final value left in that slot is `5`, from whichever call ran last) rather
than avoiding it, so the behavior is demonstrated on real hardware, not
just asserted in prose. Recursion is mechanically possible (R1's VM call
stack is a real 6-deep bounds-checked stack) but not separately tested by
this milestone, matching the plan's own scope note.

**One test-authoring mistake caught before it became a false bug report**:
the first version of the R4 test program used variable names `ANSWER2`/
`RESULT2` — but the compiler's identifier grammar has always been
`letter+` only (no digits), consistently since R2. The digit correctly
lexed as a `NUMBER` token immediately after the letters, producing
`COMPILE_ERROR_CODE=2` ("expected `=`"). This was the test program's bug,
not the compiler's — traced by checking `TOK_TYPE` directly rather than
assuming the compiler was at fault, and fixed by renaming to `ANSWERB`/
`RESULTB`. Recorded here because it's a real example of the debugging
discipline paying off in the other direction too — not every real-hardware
surprise is a compiler bug, and confirming which one it is before "fixing"
anything matters.

**No new register-clobber or logic bugs were found in this milestone** —
the first real assembled version, once the test program's own naming
mistake was fixed, passed on the very next run. Consistent with the
"architecture discipline" pattern established over Milestone 01/R1/R2/R3:
`CALL`/`RETURN` reused the SAME label/fixup machinery `GOTO` already had
validated (`LABEL_DEFINE`/`LABEL_LOOKUP`/`FIXUP_RECORD`), rather than
inventing a second, parallel resolution mechanism — the eight real bugs
already found and fixed in that shared machinery through R3 stayed fixed
here too.

Shipping ROM confirmed unaffected (`make budget`: unchanged 554 HOME / 109
EXROM free).

**R4 is done. Next: R5 (strings).**

<details>
<summary>Original R4 plan (superseded by the COMPLETE status above; kept for the record)</summary>

- **Objective**: `CALL`/`RETURN`/parameter binding/local scope, per the
  proposed V2 procedure architecture (`STATEMENT_COMPILER_SPIKE.md`'s
  procedure family + the carried-forward ~500-byte runtime estimate).
- **Dependencies**: R1-R3.
- **Files**: extends `rom/exrom_v2_compiler.asm`, `rom/exrom_v2_vm.asm`.
- **Tests**: a representative procedure with a by-value parameter,
  compiled and run; recursion explicitly tested if in scope (check
  `V2_LANGUAGE_SPEC.md`'s current procedure spec for exact scope).
- **Emulator validation**: real run.
- **ROM budget**: target ~500-650 bytes total (compiler-side family cost +
  runtime parameter binding), the single largest remaining unvalidated
  estimate per `STATEMENT_COMPILER_SPIKE.md`'s own honesty note — treat
  this milestone's real measurement as the authoritative number,
  superseding the carried-forward estimate.
- **RAM budget**: procedure call frame size measured for real.
- **Performance gate**: procedure call overhead measured (no V1 baseline
  exists for comparison, per `PERFORMANCE_BASELINE.md` — this establishes
  the first real number).
- **Success gate**: representative procedure program correct.
- **Rollback**: revert; R1-R3 remain intact.

</details>

### R5 — Strings

**Status: COMPLETE, real-hardware-validated.** Grew both files: `rom/
exrom_v2_vm_core.asm` from R1's 731 bytes to **1,160 bytes** (+429 for a
separate 32-byte-record `STRTAB` — distinct from the numeric `SYMTAB`,
since a 31-byte-cap string cannot fit in a 2-byte operand-stack slot — and
five new opcodes: `PUSH_STR_LIT`, `STORE_STR_VAR`, `STR_CONCAT`,
`STR_CMP_LT`, `STR_CMP_EQ`); `rom/exrom_v2_compiler.asm` from R4's 1,912
bytes to **2,366 bytes** (+454 for a `NAME$` lexer convention, a quoted-
string-literal scanner, a separate compile-time string-symbol table, and
string expression/assignment/comparison compilers). A design choice made
explicitly rather than assumed: this milestone's target ROM estimate
(~160-170 bytes, from `STRING_AND_SYMBOL_DESIGN.md`'s original Phase 2
figure) turned out far too low once measured for real — that figure
priced widening V1's *existing* string mechanism, not building a
comparable one from scratch inside a brand-new VM with its own separate
value representation; the real combined cost (883 bytes across both
files) is still small in absolute terms and well within the reserve
`REWRITE_ROM_BUDGET.md` already accounted for.

**Design decision, not a gap**: string "values" on the VM operand stack
are just a 2-byte `STRTAB` index, pushed via the *existing* `PUSH_I16`
opcode — no new operand-stack tag was needed, since the compiler alone
(never the VM) tracks which values are "really" strings, via the
distinct `TOK_STR_IDENT`/`TOK_STRING` token types. Concatenation results
land in a small round-robin ring of temp slots (2 of them) rather than
through any general allocator, matching this project's own standing
"avoid inventing an allocator" discipline — sufficient because a
string-expression temp is only ever live long enough to be immediately
assigned or compared, per this milestone's own scoped grammar (a flat
`+` chain, never independently-live nested sub-results).

`rom/test_v2_compiler_r5.asm` compiled and executed a real program
exercising every mechanism together — `A$="APPLE"`, `B$="BANANA"`,
`C$=A$+B$` (concatenation), `D$=A$` (a real content copy, not aliasing),
`IF A$<B$ THEN GOTO LESS` (a TRUE ordering comparison, since `'A'<'B'`),
and `IF D$=A$ THEN GOTO EQ` (a TRUE equality comparison). Real ZEsarUX
result: **every value matched exactly** — `A$="APPLE"`, `B$="BANANA"`,
`C$="APPLEBANANA"`, `D$="APPLE"`, `F=1`, `G=1`, `H=1`.

**Seven more real bugs found via ZEsarUX execution and fixed** (bringing
this rewrite's real-hardware-caught bug total to fifteen across
Milestone 01/R1-R5):
1. Inserting the new `"`-literal check into `LEX_NEXT_TOKEN`'s dispatch
   broke the *fallthrough* from the digit checks into `.ident_start` —
   every letter silently fell into the string-literal scanner instead.
   Real run: the very first identifier ("A$") was misread as a string
   literal starting mid-token. Fixed with an explicit jump instead of
   relying on label adjacency (a lesson already learned once for
   `LEX_CLASSIFY_KEYWORD`'s R3 bug, re-learned here in a different spot).
2. `COMPILER_INIT` never zeroed the new `STRSYM_COUNT` — the same
   "session RAM persists across `reset`" bug already found and fixed
   twice before (R3's `LABEL_COUNT`/`FIXUP_COUNT`), found a third time.
3. `COMPILE_STR_FACTOR`'s string-literal copy loop kept the source content
   pointer in `HL` across a call to `EMIT_BYTE` — which uses `HL`
   internally as `EMIT_PTR`, clobbering it — so only a literal's first
   byte ever reached the bytecode correctly. Fixed by using `DE` instead
   (exactly the pattern `COMPILE_NUMBER_LITERAL` already used correctly
   since R2 for the same reason).
4. `OP_STR_CONCAT`'s "append b's content" phase kept its running
   destination pointer in `DE` across a call to `VM_STR_ADDR` — which uses
   `DE` as its own internal scratch — silently redirecting the append to
   `STRTAB_BASE` instead of the real temp slot, corrupting whatever
   string variable happened to occupy index 0. Root-caused by single-
   stepping the actual instruction sequence live, the same technique that
   found R3's `RESOLVE_ALL_FIXUPS` bug.
5. `OP_STR_CMP_LT` and 6. `OP_STR_CMP_EQ` had the identical bug one level
   removed: both kept a string's record address in `DE` across a call to
   `VM_POP` — which *also* uses `DE` internally to read the popped value —
   corrupting the saved address before the comparison could use it.
7. (Two test-program naming mistakes, not compiler bugs, caught and
   corrected the same way as R4's: label names `DONE1`/`DONE2` contained
   digits, which this grammar has never supported — renamed to
   `DONEA`/`DONEB`.)

Items 3, 4, 5, and 6 are all the same underlying lesson, now proven four
times over in this one milestone alone: **any register holding a value
needed after a call must be saved to memory first — unconditionally,
never "this callee probably doesn't touch that register."** `VM_STR_ADDR`
and `VM_POP` both use `DE` internally purely as scratch, with no hint of
that from their calling convention alone; only reading their actual bodies
(or getting bitten by real hardware) reveals it.

Shipping ROM confirmed unaffected (`make budget`: unchanged 554 HOME / 109
EXROM free).

**R5 is done. Next: R6 (hybrid numeric system — floating point).**

<details>
<summary>Original R5 plan (superseded by the COMPLETE status above; kept for the record)</summary>

- **Objective**: the string system from `STRING_AND_SYMBOL_DESIGN.md`
  (31-byte-cap pool records, ordering comparisons) wired into the V2
  compiler/VM, plus multi-character string-variable names (already
  designed into the symbol architecture from R3).
- **Dependencies**: R1-R3 (does not strictly need R4).
- **Files**: extends `rom/exrom_v2_compiler.asm`, `rom/exrom_v2_vm.asm`;
  may reuse `rom/exrom_strfuncs.asm`'s existing string-operation code
  where its signature fits the new calling convention (a real "keep vs.
  replace" decision made per-routine, not assumed).
- **Tests**: string assignment, concatenation, ordering comparison.
- **ROM budget**: target ~160-170 bytes (per this study's estimate) plus
  whatever of `exrom_strfuncs.asm`'s 383 bytes isn't reusable as-is.
- **Success gate**: string programs correct; ordering comparisons correct.
- **Rollback**: revert; R1-R4 remain intact.

</details>

### R6 — Hybrid numeric system (floating point)

- **Objective**: decimal literals, mixed int/float promotion at `+`/`-`/
  `*`, `/`'s inexact-stays-float behavior — the exact policy
  `NUMERIC_DESIGN.md` already specifies, now implemented as VM opcode
  dispatch instead of `basic.asm` combine-site edits.
- **Dependencies**: R1-R3.
- **Files**: extends `rom/exrom_v2_compiler.asm` (decimal literal lexing),
  `rom/exrom_v2_vm.asm` (promotion dispatch, already stubbed as call sites
  in R1's `ADD`/`SUB`/`MUL`/`DIV` handlers).
- **Tests**: `X = 10.5`, `Y = A + 0.5` where `A` is INT, `5/2` staying
  FLOAT.
- **ROM budget**: target ~30-50 bytes (decimal detection) — the promotion
  dispatch itself is already inside R1's VM handler estimate.
- **Performance gate**: confirm the int-only fast path is genuinely
  unaffected (re-run R3's GOTO-loop and arithmetic benchmarks, confirm no
  regression) — this is the direct test of "integer programs remain
  integer programs."
- **Success gate**: composable float arithmetic works; integer perf
  unregressed.
- **Rollback**: revert; integer-only programs from R1-R5 remain correct
  and fast even without this milestone.

### R7 — Platform integration

- **Objective**: native-call VM opcodes reaching `PLOT`/`LINE`/`SOUND`/
  `BEEP`/sprite calls/storage `SAVE`/`LOAD` — the "graphics/system command"
  and "storage" families from `STATEMENT_COMPILER_SPIKE.md`.
- **Dependencies**: R1-R3 (numeric/string not strictly required for most
  of these, though some take string/float arguments).
- **Files**: extends `rom/exrom_v2_compiler.asm`, `rom/exrom_v2_vm.asm`;
  calling convention into existing platform modules, no changes to those
  modules themselves.
- **Tests**: representative graphics/sound/storage programs, compared
  against V1's existing behavior for the same operations (V1-as-oracle,
  per §21 below).
- **ROM budget**: target ~430-620 bytes (per the two families'
  `STATEMENT_COMPILER_SPIKE.md` estimates).
- **Success gate**: platform calls produce identical visible results to
  V1 for unchanged semantics.
- **Rollback**: revert; platform modules themselves are never at risk
  since this milestone never modifies them.

### R8 — Editor integration

- **Objective**: wire the V2 compiler/decompiler into the existing editor
  via the minimal interface defined in `V2_ARCHITECTURE.md`'s decision
  section (editor calls compile-on-RUN and decompile-for-`LIST`/`EDIT`;
  knows nothing about bytecode/symbols/VM internals). Build the
  decompiler/pretty-printer (`ESTIMATED` 300-500 bytes, not yet built in
  any spike).
- **Dependencies**: R1-R7 (needs the compiler to cover the full statement
  set the editor's existing programs might contain).
- **Files**: new decompiler module; small glue changes to
  `basic/editor_integration.asm`'s call sites (the only place V1's editor
  glue is touched in this entire plan) — NOT to `rom/exrom_editor.asm`
  itself, which per `V2_ARCHITECTURE.md`'s confirmed finding has zero
  interpreter-internals dependency and needs no changes.
- **Tests**: type a program in the real editor, `RUN` it (compiles via V2,
  executes via V2), `LIST` it (decompiles), confirm the decompiled text is
  a valid, if not necessarily byte-identical, re-rendering — this is the
  explicit, policy-permitted compatibility break from
  `REWRITE_RAM_BUDGET.md`'s Option 2, tested for real here for the first
  time.
- **ROM budget**: target ~300-500 bytes (decompiler) + minimal glue.
- **Success gate**: real edit/compile/run/list round trip works on real
  hardware/emulator for representative programs.
- **Rollback**: revert the editor-integration glue changes; the compiler/
  VM from R1-R7 remain usable via their standalone test harnesses even if
  editor wiring is reverted.

### R9 — Replacement (V1 language-core removal)

- **Objective**: remove `basic/basic.asm`'s direct-execute interpreter,
  `rom/exrom_checker.asm`, `rom/exrom_strfuncs.asm` (whatever wasn't
  reused in R5), `rom/exrom_dim.asm`, `rom/exrom_arrays.asm` — the full
  13,988-byte V1 language core — once R1-R8 demonstrate full statement-set
  coverage.
- **Dependencies**: R1-R8, plus an explicit statement-set coverage audit
  (every V1 statement type has a working V2 equivalent, tested).
- **Files**: deletes/guts the V1 language-core files listed above.
- **Tests**: the **entire** existing V1 regression suite, re-run against
  V2, program-by-program, per §21's oracle-comparison discipline —
  V1 RESULT vs. V2 RESULT for every existing test, with intentional
  semantic differences documented, not silently passed over.
- **ROM budget**: **this is where DEV ROM and SHIP ROM converge** — before
  this milestone, ROM temporarily holds both cores (V1 + V2 coexisting,
  likely exceeding 24KB in the dev/test image); after this milestone, only
  V2's language core remains, and the image must fit 24KB for real. This
  is the hard checkpoint: `make budget`'s real output must show the
  14,805-16,455-byte total this plan has been budgeting toward from the
  start, not a surprise.
- **Success gate**: full regression suite passes (or documented,
  deliberate semantic differences are each individually approved);
  `make budget` shows SHIP ROM fits with the projected reserve.
- **Rollback**: this is the point of no easy return — restoring V1 means
  reverting this milestone's deletion diff specifically, which is why R9
  is scoped as its own milestone rather than folded into R8 or R10, and why
  the full regression suite gate exists before it is accepted.

### R10 — Optimization and ROM recovery

- **Objective**: final consolidation once the real, shipping V2 language
  core exists — apply the same placement-decision methodology
  (`ARCHITECTURE_COMPARISON.md`'s adopted process) to the new code,
  looking for any of R1-R9's code that turned out colder than assumed and
  could move to EXROM, and any dead V1-transition scaffolding to remove.
- **Dependencies**: R9.
- **Files**: whatever R1-R9 produced, refined in place.
- **Success gate**: final `make budget` reserve is documented and equal to
  or better than R9's; regression suite still green.
- **Rollback**: per-change, same discipline as every other milestone.

## Testable-before-dependents ordering

R1 is testable alone (hand-assembled bytecode). R2 is testable with R1 only
(no statement compiler needed to test expression compilation). R3 depends
on R1+R2 but is itself fully testable before R4-R8 exist. This ordering was
chosen specifically so each milestone's success gate is checkable in
isolation, per the task brief's explicit preference.

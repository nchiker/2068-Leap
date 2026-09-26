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

|                                                                                                     | Bytes                                    |
| --------------------------------------------------------------------------------------------------- | ----------------------------------------:|
| PLATFORM ROM (unchanged throughout)                                                                 | 9,925 (VERIFIED, `61bb8bb`)              |
| NEW V2 LANGUAGE CORE ROM (grows milestone by milestone)                                             | 0 at R1 start → 4,880-6,530 at R9        |
| TEMPORARY V1 LANGUAGE CORE ROM (shrinks as V1 statement types are cut over, removed entirely at R9) | 13,988 at R1 start → 0 after R9          |
| FINAL PROJECTED SHIP ROM AFTER V1 REMOVAL                                                           | 9,925 + (4,880 to 6,530) = 14,805-16,455 |
| ENGINEERING RESERVE (ship)                                                                          | 8,121-9,771                              |

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
6. (Two test-program naming mistakes, not compiler bugs, caught and
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

**Status: COMPLETE, real-hardware-validated.** Grew `rom/
exrom_v2_vm_core.asm` from R5's 1,160 bytes to **1,698 bytes** (+538 for
`FLOATTAB` — a 16-record, 5-bytes/record table, one dedicated slot per
possible `SYMTAB` index plus a 2-slot round-robin ring for arithmetic
temporaries — a new opcode `PUSH_FLOAT_LIT`, and int/float-promotion
logic added to `ADD`/`SUB`/`MUL`, plus an inexact-stays-float fast/slow
split added to `DIV`); `rom/exrom_v2_compiler.asm` from R5's 2,366 bytes
to **2,494 bytes** (+128 for decimal-point recognition in
`LEX_SCAN_NUMBER` and the `PUSH_FLOAT_LIT` emitter). Combined +666 bytes,
well inside `REWRITE_ROM_BUDGET.md`'s reserve — and, critically, this
milestone does **not** reimplement float arithmetic: every actual
computation is a real, unmodified call into `rom/exrom_calc.asm`'s
existing calculator engine via its documented `RST $28` literal-stream
mechanism (the same entry points `basic.asm`'s own `/` operator already
uses in production), exactly as `NUMERIC_DESIGN.md`'s reuse decision
specifies.

**Design decision, not a gap**: a float "value" on the VM's 3-byte
operand-stack record is always a 2-byte `FLOATTAB` index (`TAG_FLOAT`),
mirroring R5's string design — but with one real, load-bearing
difference from strings, caught during design review *before* any
hardware test: strings have their own lexically-distinct (`$`-suffix)
symbol-table index space, so a small round-robin temp pool plus a
separate named-variable pool was sufficient; floats share the *same*
`SYMTAB` index space as plain ints (no lexical marker distinguishes
`X = 10.5` from `X = 10`), so a float variable's storage must be keyed
1:1 by its `SYMTAB` index (`FLOATTAB_MAX_VARS = 16`, matching
`CSYMTAB_MAX_ENTRIES`) rather than allocated from a small pool — a
round-robin scheme would have let a later float computation silently
overwrite an earlier variable's own stored value. `OP_STORE_VAR` now
branches on the popped tag: an INT value stores as before; a FLOAT value
gets a real 5-byte content copy (via `VM_FLOAT_ADDR` + `ldir`) from
whatever transient slot produced it into the variable's own dedicated
slot — not just a copy of the (possibly soon-reused) index.

`OP_DIV` keeps the existing fast native-`MATH_DIVIDE16` int path as the
*first* attempt even under R6: it divides, then reconstructs
`quotient*divisor` via `MATH_MULTIPLY16` and compares against the
original dividend; an exact match stays on the int fast path (e.g.
`6/2` stores as `TAG_INT`, zero calculator/`FLOATTAB` involvement); a
mismatch (e.g. `5/2`) falls back to a real float divide through the
calculator. This preserves the "integer programs remain integer
programs" performance guarantee for the common case while still
satisfying the inexact-stays-float requirement. A documented, deferred
edge case: when either `/` operand is already `FLOAT`-tagged, a
`FLOAT`-tagged zero divisor is not caught by this milestone's cheap
zero-check (only a plain-`INT` zero divisor is) — `NUMERIC_DESIGN.md`
already flagged the calculator's own raw divide as having no
error-reporting path of its own for this case; this is not a new gap
R6 introduced.

`rom/test_v2_compiler_r6.asm` compiled and executed a real program
exercising every R6 mechanism together — `X=10.5` (plain decimal
literal), `A=3` (plain int), `Y=A+0.5` (int-operand promoted to float,
added to a float literal), `Z=5/2` (inexact division, calculator
fallback), `W=6/2` (exact division, fast int path, no calculator
involvement at all). Real ZEsarUX result: **every value matched
exactly** — confirmed not by hand-decoding the calculator's internal
5-byte float format, but by asking the real calculator itself: the test
driver copies each variable's own `FLOATTAB` record onto the real
`CALC_STACK`, multiplies by the real int 2 via `RST $28`, converts back
to int via `CALC_FP_TO_INT`, and compares the truncated result against
`expected*2` (exact for every value in this test: `10.5*2=21`,
`3.5*2=7`, `2.5*2=5`) — genuine end-to-end verification through the same
engine the interpreter itself uses, not a mock. Final hand-verified
`FLOATTAB`/`SYMTAB` state, read live off real hardware: `X=10.5`
(`84 28 00 00 00`), `A=3` (`TAG_INT`), `Y=3.5` (`82 60 00 00 00`),
`Z=2.5` (`82 20 00 00 00`), `W=3` (`TAG_INT`).

**Three more real bugs found via ZEsarUX execution and fixed** (bringing
this rewrite's real-hardware-caught bug total to eighteen across
Milestone 01/R1-R6) — all three the *same* underlying lesson, now proven
a fifth time in this rewrite alone:

1. `OP_STORE_VAR`'s new `.float_store` branch held the source `FLOATTAB`
   address in `DE` across a second call to `VM_FLOAT_ADDR` (to compute
   the destination address) — but `VM_FLOAT_ADDR` uses `DE` as its own
   scratch (`ld d,h / ld e,l ... ld de,FLOATTAB_BASE`), silently
   destroying the source address before the `ldir` ever ran. Every
   variable's dedicated `FLOATTAB` slot came back all-zero as a result —
   caught by direct `mem` reads before writing a single test-program
   line, not by a failed run. Fixed by parking the source address in
   memory across the second call instead of a register the callee
   touches.
2. `VM_FLOAT_PUSH_OPERAND`'s `.is_float` branch had the *identical* bug
   one level up: it held the source address in `HL` across a call to
   `CALC_SP_TO_NEXT_FREE_PTR` — whose own header explicitly documents
   "Destroys: AF, BC, DE, HL" — which returns via `ex de,hl`, handing
   back whatever `HL`/`DE` happened to hold on entry (here: `DE`, left
   over from the *first* operand's own already-completed `ldir` a moment
   earlier) instead of the real source address computed just above. Real
   effect: `Y = A + 0.5` (`A` = int 3) came back as `6.0`, because the
   second operand's `ldir` silently copied the *first* operand's own
   just-pushed bytes over itself instead of the literal `0.5`'s real
   float data (`3 + 3 = 6`, not `3 + 0.5 = 3.5`) — root-caused by
   single-stepping the exact instruction sequence live and reading
   `CALC_STACK` at each step, the same technique that found R3's and
   R5's clobber bugs. Fixed with a dedicated new scratch cell
   (`VM_FLOAT_SRC_ADDR_TMP`) rather than reusing `VM_FLOAT_A_VAL`/
   `VM_FLOAT_B_VAL` — deliberately *not* reusing `VM_FLOAT_B_VAL` (as
   bug 1's own fix pattern would suggest), since this routine is called
   twice per opcode and the caller still needs `VM_FLOAT_B_TAG`/`VAL`
   intact when operand A happens to be the float one.
3. The R6 test driver's own `CHECK_RESULT.check_float` verification
   helper had the same bug a third time, independently, in test code
   rather than production code: it held the source address in `HL`
   across the same `CALC_SP_TO_NEXT_FREE_PTR` call. Fixed the same way.

All three are the same standing lesson from R2-R5, proven again: **any
register holding a value needed after a call must be saved to memory
first — unconditionally, never "this callee probably doesn't touch that
register."** `VM_FLOAT_ADDR` and `CALC_SP_TO_NEXT_FREE_PTR` both use
`DE`/`HL` internally purely as scratch (the latter's own header even
says so explicitly), with no hint of that from a casual read of the call
site alone.

**Retrospective register-clobber audit, done proactively before R7**: the
same bug class above has now recurred five times across R2/R3/R5/R6.
Before writing R7's platform-call trampolines — which will call a lot of
existing, register-heavy graphics/sprite/sound/input routines, exactly
the shape of code this bug thrives in — two things were done:

1. Added an explicit, prominent standing-convention block near the top of
   both `rom/exrom_v2_vm_core.asm` and `rom/exrom_v2_compiler.asm`: never
   keep a value live in a register across a `call`; save it to memory
   first; check the callee's own "Destroys:" header before assuming any
   register survives a call.
2. Manually audited every `call` site in both files against each known
   register-clobbering helper's actual documented/read behavior
   (`VM_POP`, `VM_SYM_ADDR`, `VM_STR_ADDR`, `VM_FLOAT_ADDR`, `EMIT_BYTE`,
   `CALC_SP_TO_NEXT_FREE_PTR`, the `MATH_*`/`CALC_*` primitives),
   specifically prioritizing opcodes/branches no existing test program had
   ever exercised — `OP_SUB`'s and `OP_MUL`'s own `.float_path` branches,
   and `OP_DIV`'s *other* `.float_path` (dividend already `FLOAT`-tagged,
   not just the divisor), none of which R6's original test program
   touched. All three already route through `VM_FLOAT_PUSH_OPERAND`
   (fixed above), and manual inspection of every other call site in both
   files (`OP_FOR_INIT`/`OP_FOR_NEXT`'s `C`-held-across-`VM_POP` — safe,
   `VM_POP` never touches `BC`; every R5 string opcode — already fixed
   and re-verified; `OP_CMP_LT`/`OP_CMP_EQ` — safe, uses the Z80 stack via
   `push`/`pop`, not a bare register) found no sixth instance. Rather than
   leave that "probably fine" as an assertion, `rom/test_v2_compiler_r6.asm`
   was extended with three new statements (`V=A-0.5`, `Q=8.0`, `U=Q/2`,
   `T=X*2`) specifically targeting those three previously-unexercised
   paths, re-assembled, and re-run on real ZEsarUX hardware: **PASS**,
   confirming the `VM_FLOAT_PUSH_OPERAND` fix genuinely generalizes to
   all three call sites, not just the one (`OP_ADD`) that happened to
   surface it. Byte deltas above already reflect the final, audited
   state (the convention comments themselves add zero bytes — pure
   documentation in a standalone test image).

Shipping ROM confirmed unaffected (`make budget`: unchanged 554 HOME /
109 EXROM free).

**R6 is done. Next: R7 (platform integration).**

<details>
<summary>Original R6 plan (superseded by the COMPLETE status above; kept for the record)</summary>

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

</details>

### R7 — Platform integration

**Status: COMPLETE, real-hardware-validated — with one honest, deliberate
exception (SAVE/LOAD, explicitly deferred to R8 by coordinator decision;
see below), not a silent gap.** Per this project's own standing
discipline (never silently claim more scope than was actually built and
tested — the same discipline R5's "160-170 bytes was too low" correction
and R6's "FLOAT-tagged zero divisor deferred" note already established),
this pass built and validated the CORE MECHANISM plus a real, representative
subset of the graphics/system command family — `CLS`/`BORDER`/`INK`/
`PAPER`/`PLOT` — rather than attempting all ~14 graphics/system statements
plus all ~10 storage statements in one pass. The remaining statements
(`LINE`/`CIRCLE`/`FILL`/`DRAW`/`SOUND`/`BEEP`/`PAUSE`/`OUT`/`POKE`/
`RANDOMIZE`, and the entire storage/program-control family — `SAVE`/
`LOAD`/`RUN`/`LIST`/`EDIT`/`NEW`/`CLEAR`/`STOP`/`END`/`REM`) are each a
mechanical repeat of the SAME proven pattern (parse N numeric/string args
via the already-real `COMPILE_EXPR`, emit one native-call opcode that
calls straight into the matching existing platform primitive) for the
graphics family — `LINE`/`CIRCLE`/`FILL`/`DRAW` call `kernel/graphics`'s
own existing line/circle/fill primitives the same way `PLOT` calls
`GFX_WRITE_PIXEL` here — but storage (`SAVE`/`LOAD`) specifically was
deferred for a real, non-mechanical reason found during investigation:
`BASIC_DO_SAVE`/`BASIC_DO_LOAD` (`basic/basic.asm`) take a raw TEXT
pointer (the editor's own line-buffer position right after the keyword)
as their real calling convention, not a string VALUE the R5 string
mechanism could hand over as a `STRTAB` index — they are, today, an
interactive EDITOR command intercepted before ordinary statement
tokenization even runs, not a `RUN`-time program statement V1's own
interpreter ever executes at all. Wiring V2's compiler into that requires
either a real adapter (copying a compile-time string literal's content
back into a text buffer `BASIC_DO_SAVE`/`LOAD` can walk) or confirming
whether V1 even has a genuine in-program `SAVE`/`LOAD` statement path
worth matching — neither was resolved this pass, so it is being reported
as a real, deliberately unresolved question rather than quietly worked
around.

- **Files touched**: `rom/exrom_v2_vm_core.asm` (5 new opcodes: `OP_CLS`
  23, `OP_BORDER` 24, `OP_INK` 25, `OP_PAPER` 26, `OP_PLOT` 27, plus two
  new self-contained helpers, `VM_COMPUTE_PRINT_ATTR`/`VM_CLAMP_Y191`);
  `rom/exrom_v2_compiler.asm` (new `TOK_COMMA` — the first multi-argument
  statement, `PLOT x,y`, needed it — and the `KEYWORD_TABLE`'s entry width
  widened from 4 to 6 text bytes to fit `BORDER`, the longest keyword so
  far).
- **Design decision, not a gap**: `OP_CLS`/`OP_PLOT` do NOT call into
  `basic/basic.asm`'s own `BASIC_STMT_CLS`/`BASIC_STMT_PLOT`/
  `BASIC_COMPUTE_PRINT_ATTR`, even though those already exist and do the
  same job for V1. `basic.asm` is V1's language core, which R9 removes
  outright once V2 covers everything — depending on it now would just
  create a dependency R9 has to unwind later. Instead, `VM_COMPUTE_
  PRINT_ATTR`/`VM_CLAMP_Y191` are a small, self-contained REWRITE of that
  language-level logic (ink/paper/inverse/bright/flash bit-packing,
  y-clamping) — genuinely part of the language core this whole project
  is rewriting, not the platform being reused — transcribed from
  `BASIC_COMPUTE_PRINT_ATTR`/`BASIC_CLAMP_Y191`'s real algorithm so the
  VISIBLE result matches V1 bit-for-bit, which is this milestone's own
  success gate. `OP_CLS`/`OP_BORDER`/`OP_INK`/`OP_PAPER`/`OP_PLOT`
  themselves DO call straight into the real, unmodified `kernel/graphics`
  primitives (`GFX_CLS`/`GFX_SET_BORDER`/`GFX_PAINT_ATTR`/
  `GFX_WRITE_PIXEL`) — the actual "platform integration," reused exactly
  as `PLOT`/`BORDER` and friends already reuse them today.
- **Test**: `rom/test_v2_compiler_r7.asm` compiles and executes
  `INK 6:PAPER 1:CLS:BORDER 2:PLOT 10,20` on real ZEsarUX hardware —
  **PASS on the first real hardware attempt** (the register-clobber
  audit and standing-convention block added at the end of R6, applied
  proactively to every new call site here, appears to have paid off —
  no register-clobber bug this time). Verified directly against
  hand-computed V1-oracle values: `CURRENT_INK=6`, `CURRENT_PAPER=1`,
  the whole attribute area repainted to `$0E` (`paper<<3|ink`, matching
  V1's own `BASIC_COMPUTE_PRINT_ATTR` formula), `PORT_FE_SHADOW`'s low 3
  bits `=2`, and pixel (10,20) set while pixel (0,0) stays clear —
  the pixel check itself asks the real `GFX_READ_PIXEL` primitive
  directly rather than hand-decoding the real (non-linear) Spectrum-style
  bitmap address formula, the same "ask the real engine" verification
  discipline R5/R6 already established for strings/floats.
- **ROM budget**: `rom/exrom_v2_vm_core.asm` grew 1,698 → **1,855 bytes**
  (+157); `rom/exrom_v2_compiler.asm` grew 2,494 → **2,705 bytes** (+211).
  Combined +368 bytes for this real subset — well under the original
  ~430-620 byte estimate for the FULL graphics/system family alone,
  consistent with only 5 of ~14 statements being built so far.
- Shipping ROM confirmed unaffected (`make budget`: unchanged 554 HOME /
  109 EXROM free). Full V1 regression suite re-run: see below.
- **No new register-clobber bug found** in this pass, and none is
  expected to have been hiding here either: every new call site in this
  phase saves any value needed past a call to its own dedicated
  `VM_PLOT_*_TMP` cell first, per the standing convention added at R6's
  close — self-applied here rather than discovered via a failed run.

**R7 Phase 2 — the real remainder of the graphics/system family, per
coordinator judgment call**: SAVE/LOAD stays explicitly deferred to R8
(the editor-integration milestone is where that real editor/compiler/
runtime boundary question belongs, per the coordinator's own reasoning —
not invented around here), but every OTHER statement named in the
original plan text was mechanically finished this same pass, using
Phase 1's proven pattern. First, real investigation corrected the plan's
own stale statement list: checked against `include/checker_keywords.inc`
(this ROM's real, current dialect, not the plan's original aspirational
text), `CIRCLE`/`FILL` were removed from this ROM entirely on
2026-09-19 for ROM budget (`rom/extensions/shapes.asm` now carries `FILL`
as a loadable extension instead), `DRAW`/`OUT` never existed here at
all, and the real keyword is `RANDOMISE`, not `RANDOMIZE`. The real
remainder is exactly six statements: `LINE`/`BEEP`/`SOUND`/`POKE`/
`PAUSE`/`RANDOMISE`.

- **Files touched**: `rom/exrom_v2_vm_core.asm` (6 new opcodes: `OP_LINE`
  28, `OP_BEEP` 29, `OP_SOUND` 30, `OP_POKE` 31, `OP_PAUSE` 32,
  `OP_RANDOMISE` 33, plus a new VM error code, 8, for an out-of-range
  `SOUND` register); `rom/exrom_v2_compiler.asm` (6 new statement
  compilers; the keyword table widened a SECOND time, this time from 6
  to 9 text bytes, to fit `RANDOMISE`).
- **What each opcode actually calls**: `OP_LINE` writes the real
  `GFX_LINE_X0/Y0/X1/Y1/ATTR/OVER` sysvars (the SAME ones V1's own
  `BASIC_PARSE_LINE_ARGS` writes) then calls the real, unmodified
  `GFX_LINE`. `OP_BEEP` calls the real, unmodified `SOUND_BEEP` (kernel/
  sound). `OP_SOUND` calls the real `SOUND_EXROM` (`rom/exrom_sound.asm`)
  DIRECTLY — bypassing `basic.asm`'s own `BASIC_SOUND_EXROM` Home/EXROM
  paging wrapper, the same reasoning already established for `RST $28`
  in R6: a flat, single-bank test image has no banks to page, so the
  real EXROM module's real entry point can be called straight through.
  `OP_POKE` is a direct memory write, matching V1's own inline
  `BASIC_STMT_POKE` body exactly (no separate primitive to call — there
  never was one). `OP_PAUSE` transcribes `BASIC_STMT_PAUSE`'s own
  algorithm (0 waits for a keypress via `IO_READ_KEY`; >0 waits exactly
  n real interrupt-driven `FRAMES` ticks) — genuinely language-level
  control flow, not a platform primitive, same reasoning as
  `VM_COMPUTE_PRINT_ATTR`. `OP_RANDOMISE` calls the real, unmodified
  `MATH_RND_SEED`.
- **A second, real interrupt-handling bug found and fixed** (this
  milestone's fourth real hardware bug overall, and a genuinely NEW bug
  class for this rewrite — not another register-clobber): the test
  driver's first `RST $38` vector was a plain `jp KBD_ISR_TICK`. `KBD_
  ISR_TICK`'s own real body (`kernel/interrupt/interrupt.asm`) ends in a
  plain `ret`, never executes `ei` itself, and is a SUBROUTINE meant to
  be `call`ed by the real vector, not the vector's own entry point — the
  real production ROM's own `RST_38` (confirmed against `rom/
  test_basic.asm`'s already-correct wiring) is `call KBD_ISR_TICK / ei /
  reti`. A Z80's interrupt hardware clears `IFF1` automatically the
  instant it accepts a maskable interrupt; nothing re-enables it without
  an explicit `ei` somewhere in the path. The bug's real, live signature:
  `OP_PAUSE`'s wait loop parked forever after exactly ONE interrupt ever
  fired (`FRAMES` stuck at 2, `regs`' own `IFF1` field reporting
  "clear") — caught by reading real registers/memory at the exact
  address the bounded run stopped at, not by guessing. Fixed by copying
  `rom/test_basic.asm`'s own real vector pattern verbatim rather than
  assuming a bare jump was an equivalent shortcut.
- **Test**: `rom/test_v2_compiler_r7.asm` was extended (not replaced) to
  also compile and run `LINE 30,30 TO 35,30:BEEP 0,100:SOUND 8,10:
  POKE 38912,77:PAUSE 2:RANDOMISE 42` after Phase 1's own program — real
  ZEsarUX PASS after the interrupt-vector fix above. Verified directly:
  pixels (30,30) and (35,30) SET (LINE's own endpoints), pixel (40,30)
  still CLEAR (just past the line); AY chip register 8 read back 10 via
  a real hardware register read (`OUT`/`IN`, not a hand-decoded guess);
  byte at RAM address $9800 (a plain, otherwise-unused RAM address —
  deliberately NOT `VM_CODE_BASE`, which would have meant `POKE`
  self-modifying the running program) reads back 77; `RND_STATE` reads
  back 42. `BEEP 0,100` is honestly NOT independently runtime-verified —
  its own header comment explains why (duration=0 is an unconditional
  no-op per `SOUND_BEEP`'s own real, documented contract, checked before
  pitch is ever read, so no runtime observation can distinguish a
  correct argument order from an accidentally-swapped one at these
  values) and how its argument order was verified instead (direct
  comparison against V1's real `BASIC_STMT_BEEP` source).
- **ROM budget**: `rom/exrom_v2_vm_core.asm` grew 1,855 → **2,013 bytes**
  (+158); `rom/exrom_v2_compiler.asm` grew 2,705 → **3,095 bytes** (+390).
  Combined Phase 1 + Phase 2 total: vm_core +315, compiler +601 —
  comfortably inside `REWRITE_ROM_BUDGET.md`'s reserve for the full
  graphics/system family.
- Shipping ROM confirmed unaffected (`make budget`: unchanged 554 HOME /
  109 EXROM free). Full V1 regression suite re-run after Phase 2: 102/102
  pass (unsurprising — this milestone touches no V1 file — but genuinely
  re-run, not assumed, per this project's own standing discipline).

**R7 is done (SAVE/LOAD explicitly deferred to R8 by coordinator
decision, not by omission). Next: R8 (editor integration)**, which is
also where the SAVE/LOAD editor/compiler/runtime boundary question
above belongs — `BASIC_DO_SAVE`/`BASIC_DO_LOAD` take a raw text-buffer
pointer and are today an interactive editor command intercepted before
ordinary statement tokenization, not a `RUN`-time statement; R8's own
job of defining the new editor/compiler/runtime interface is exactly
where that boundary gets redefined.

<details>
<summary>Original R7 plan (superseded by the COMPLETE status above; kept for the record)</summary>

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

</details>

### R7.5 — V2-native loadable-extension mechanism

**Status: REDESIGNED FROM FIRST PRINCIPLES per explicit user direction,
then implemented and real-hardware-validated.** Raised mid-R8: does
V1's loadable-RAM-package capability survive under V2? First pass
investigated whether V1's OWN mechanism (`BASIC_EXTENSION_REGISTER`,
the `EXT_SERVICE_*` veneer table, register-passed arguments, text-based
per-run keyword rematching) could be preserved or adapted. The user then
explicitly overrode that framing: **the requirement is the CAPABILITY
(load optional code into RAM that extends the system without permanent
ROM cost), not compatibility with V1's specific ABI, package format,
registration mechanism, or calling convention** — every one of those is
explicitly replaceable, to be redesigned for what fits Architecture B
best, compared quantitatively (ROM, RAM, runtime performance, compiler
complexity, robustness, usefulness, architectural fit), not preserved
for compatibility's own sake. The user also settled `HIT()` specifically
by direct decision: it moves back into the resident sprite subsystem
(V1's own P0.3 move of it into an extension "wasn't the best decision"),
not into either V1's or V2's extension mechanism at all — a resident
sprite-subsystem function/opcode, same shape as R7's other native-call
opcodes, is a separate, later platform-integration item, not part of
this design.

**Two alternatives compared, quantitatively, before choosing:**

| Criterion           | Alt A — runtime name-rescan (dispatch by re-matching the keyword's text against the registry on every call, V1-shaped)                                                                     | Alt B — compile-time-resolved ID + runtime generation-checked table (SYMTAB/STRTAB/FLOATTAB-shaped)                                                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ROM cost            | Compiler: one name-scan at compile time (~80B, same as B). VM opcode: a string-compare loop against every registered name, every call (~60B handler)                                       | Compiler: same one-time name-scan (~80B). VM opcode: index a fixed-stride table + one byte compare + one indirect call (~30B handler) — smaller, because there's no comparison LOOP at runtime                                                                                                                                                                                                                                                                                                      |
| RAM cost            | A registry is still needed for the compiler's own compile-time scan (name+exec_ptr+argcount per slot) — same table either way                                                              | Identical table, same cost — B adds nothing here; the ID is just which ROW the compiler already found                                                                                                                                                                                                                                                                                                                                                                                               |
| Runtime perf        | O(registered-slot-count × name-length) string comparisons on EVERY call site execution (a statement inside a loop pays this every iteration)                                               | O(1): one table index, one byte compare, one indirect call — no string comparison at runtime at all                                                                                                                                                                                                                                                                                                                                                                                                 |
| Compiler complexity | Identical — both need the exact same compile-time name-scan; the only difference is what gets baked into the bytecode operand afterward (name text vs. a 1-byte slot id)                   | Identical to A                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Robustness          | Always correct: a mismatched/unloaded/swapped module is caught by name, every call, with no false positive possible                                                                        | Slightly weaker in theory (an ID could point at a DIFFERENT module if slots get reused) — closed with a cheap generation counter: each (re)registration into a slot bumps a byte; the compiled operand carries the generation value seen at compile time; a mismatch at call time is treated exactly like "not found." This reduces the gap to "another module reusing the exact same slot AND getting the exact same generation value by coincidence," not a real practical risk for this platform |
| Usefulness          | Full, for statements. Functions (arbitrary-arity, expression-position) need a call-expression grammar V2 has never had — true for BOTH alternatives equally, not a difference between them | Same                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| Architectural fit   | Foreign to V2's own established shape — nothing else in this VM does a runtime name comparison; V1-shaped, not Architecture-B-shaped                                                       | **Exact match to the pattern already used everywhere else in V2**: `SYMTAB`/`STRTAB`/`FLOATTAB` are all "resolve a name to a small index at compile time, index a fixed-stride RAM table at runtime." This is the SAME idea, applied to extensions instead of variables/strings/floats                                                                                                                                                                                                              |

Alt B dominates on ROM, runtime performance, and architectural fit,
matches A on RAM and compiler complexity, and gives up only a
theoretical sliver of robustness that a one-byte generation counter
closes back up almost entirely. **Chosen: Alt B.**

**Concrete design, implemented**:

- A fresh, V2-native, NEVER-`basic.asm`-resident registry (`kernel/
  extensions/ext_registry.asm`, so it needs no relocation before R9 the
  way reusing V1's own gateway would have) — 8 slots, each `[magic/
  generation:1][name_len:1][name:8][exec_ptr:2][argcount:1]` = 13 bytes
  (104 bytes total). Registration: `EXT2_REGISTER` (name ptr, exec ptr,
  argcount) — finds a free or reusable slot, writes the fields, and
  sets the generation byte to a rolling never-0 counter that is bumped
  on every registration into that slot (closing the "stale ID" gap
  above).
- Argument passing is DELIBERATELY not register-based (V1's own
  register-passed ABI is exactly the kind of historical-implementation
  detail the user said not to preserve for its own sake, and Z80's 4
  general registers don't scale to an arbitrary argument count anyway):
  a small fixed memory block, `EXT_CALL_ARG0..3` (2 bytes each — full
  16-bit, not V1's 1-byte `EXTENSION_ARG0..3`), holds up to 4 arguments
  in call order. This scales uniformly to 0-4 args with ONE compiler
  code path (an ordinary comma-separated `COMPILE_EXPR` loop, no more
  V1-shaped "grammar 0/1/3" special-casing at all) and ONE VM handler.
- Compiler: when an identifier fails the built-in keyword table AND the
  assignment/label grammar, scan the registry by name (linear, 8 slots);
  on a match, compile `argcount` comma-separated expressions (reading
  `argcount` from the matched slot), then emit `OP_CALL_EXT` with a
  3-byte operand `[slot_id:1][generation:1][argcount:1]`.
- VM: `OP_CALL_EXT` pops `argcount` values into `EXT_CALL_ARG0..
  (argcount-1)`, indexes the registry by `slot_id`, compares the stored
  generation to the operand's own, and — on a match — calls `exec_ptr`
  (which reads its own args from `EXT_CALL_ARG0..3` and may write a
  result into `EXT_CALL_RESULT`, unused by statements for now, reserved
  for a later function-extension design); a mismatch is a real, caught
  `VM_ERR_EXTENSION_NOT_FOUND`.
- Functions (arbitrary-arity, expression-position calls, `HIT()`'s own
  former shape) are explicitly OUT of this design's scope, same as
  before — they need call-expression grammar V2 doesn't have for ANY
  identifier yet, extension or built-in, and per the user's own
  decision `HIT()` itself doesn't need this mechanism at all (resident
  sprite-subsystem opcode instead, tracked as a separate future
  platform-integration item, not R7.5's problem).
- V1's own extension mechanism is UNTOUCHED (per the standing "V1 stays
  completely unaffected until R9" isolation discipline) — this registry
  is purely additive. A module wanting to be usable from BOTH a V1
  program and a V2 program during the R7.5-R9 coexistence window would
  call both registration APIs from its own install routine; once R9
  removes V1, only the V2 registry remains, and modules simplify back
  down to one registration call. V1's own `BASIC_EXTENSION_REGISTER`
  needs no relocation for THIS design (it's simply deleted along with
  the rest of `basic.asm` at R9, since V2 never depended on it) —
  **this design also fully resolves the earlier investigation's own
  "Problem A" (registry survival) by construction, not by relocating
  the old one.**

**Files**: `kernel/extensions/ext_registry.asm` (new: `EXT2_REGISTER`,
the descriptor table); `rom/exrom_v2_vm_core.asm` (new opcode `OP_CALL_
EXT`, 34, plus `VM_ERR_EXTENSION_NOT_FOUND`, error code 9);
`rom/exrom_v2_compiler.asm` (registry name-scan fallback in
`COMPILE_STATEMENT_LIST` plus `COMPILE_EXT_CALL`); `rom/
test_v2_ext_demo.asm` (new: a small, fresh V2-native demo extension,
`TRIADD <a>,<b>,<destaddr>` — writes `(a+b)`'s low byte to `destaddr`,
deliberately a 3-argument statement, a shape V1's own grammar-0
`expr,expr` ABI could never express in one uniform code path — plus a
standalone compiler+VM test driver, same shape as every other `rom/
test_v2_compiler_rN.asm`). Deliberately NOT an adapted V1 extension, per
the user's own explicit "existing V1 extensions may require
rebuilding... that is acceptable" direction.

**Real hardware result: PASS**, after finding and fixing two real bugs
during implementation (both caught by direct memory/register
inspection, not by inspection alone, and both before the docs below were
finalized):

1. `EXT2_NAME_LEN` returned the just-read NULL byte's own value (0)
   instead of the accumulated character count on hitting the
   terminator — every registered extension's own `name_len` came out 0
   regardless of its real name's length, confirmed via a direct
   registry-table memory read after a real run.
2. The demo's first chosen name, `SUM3`, is not a valid identifier in
   THIS compiler's own lexer at all — `LEX_SCAN_IDENT` (`rom/
   exrom_v2_compiler.asm`) only accepts `A`-`Z`, no digits (an existing,
   documented R2-era design choice, not something this milestone
   changed) — so `SUM3` tokenized as `SUM` followed by a separate
   number token `3`, never reaching the extension-lookup fallback at
   all. Renamed the demo to `TRIADD` (letters only); real hardware run
   then passed. Also surfaces a real, honest note for a LATER milestone
   (not fixed here): `rom/exrom_v2_decompiler.asm`'s own synthesized
   variable names (`V0`, `V1`, ...) are letters-then-digits too, so
   decompiled text containing them is not yet re-lexable by this same
   compiler without also widening `LEX_SCAN_IDENT` to accept trailing
   digits — a real, tracked gap for R8's own decompile-then-recompile
   round-trip claim, not silently glossed over.
3. Real, end-to-end confirmation, independent of the border-color pass/
   fail signal: the registry table at `EXT2_TABLE` read back exactly
   `[generation=1][name_len=6]["TRIADD",padded][exec_ptr=SUM3_EXEC's
   real address][argcount=3]`, and the target RAM byte at `$9800` read
   back `7` (`3+4`, computed for real by the extension's own exec
   routine, not hand-decoded).

**ROM/RAM measured, real, on the actual assembled test image** (not
estimated): `kernel/extensions/ext_registry.asm` (new file) — **~250
bytes** (`EXT2_CLEAR_ALL` through `EXT2_LOOKUP`, including the 104-byte
fixed 8-slot descriptor table). `rom/exrom_v2_vm_core.asm` grew 2,013 ->
**2,119 bytes** (+106: `OP_CALL_EXT`, `VM_CALL_INDIRECT`, one new error
code). `rom/exrom_v2_compiler.asm` grew 3,095 -> **3,208 bytes** (+113:
the registry-fallback check in `COMPILE_STATEMENT_LIST` plus
`COMPILE_EXT_CALL`). **Combined ~469 bytes for the whole mechanism** —
registration, compile-time resolution, generation-checked runtime
dispatch, and uniform 0-4-argument support — comfortably cheap for what
it buys, and consistent with the R7.5 comparison table's own prediction
that Alt B would cost about the same at compile time and less at
runtime than a name-rescanning alternative. Shipping ROM confirmed
unaffected (`make budget`: unchanged 554 HOME / 109 EXROM free). Full
V1 regression suite re-run: see below.

**This is a genuine R9 precondition, not an R8 dependency**: R8's own
editor-integration/decompiler work does not touch extensions at all and
proceeds independently. **R9's own "statement-set coverage audit" must
explicitly include "the V2-native extension registry and `OP_CALL_EXT`
dispatch are real, tested, and cover every capability a V1 loadable
extension module needs going forward"** as a named, checked item.

### R8 — Editor integration

**Status: R8 COMPLETE — decompiler (Phases 1+2), the identifier
cleanup, editor-integration, and the SAVE/LOAD hard gate are all
complete and real-hardware-validated.** `rom/exrom_v2_decompiler.asm`'s
`DECOMPILE_PROGRAM` covers the compiler's ENTIRE current statement set:
R1-R3's numeric/control-flow core, R4's PROC/CALL/RET (pattern-matched
from `COMPILE_PROC`'s own fixed bytecode shape), R5's strings, R6's
floats (reconstructing decimal text directly from the compiler's own
value/divisor encoding), and R7/R7.5's native-call/platform family
including `CALL_EXT` (reading the real registered name straight out of
the live extension registry). Tested end to end by `rom/
test_v2_decompiler.asm` and `rom/test_v2_decompiler_phase2.asm`
(compile a real program, decompile it, byte-compare the reconstructed
text against a real captured-then-verified rendering). Real hardware
result: PASS on both. `rom/exrom_v2_compiler.asm`'s `LEX_SCAN_IDENT`
now accepts digits after a leading letter (the R7.5-flagged letters-
only gap), needed for the decompiler's own synthesized names ("V0",
"P3") to be re-lexable by this same compiler -- R8's own decompile-
then-recompile round-trip claim. See these milestones' own commits for
eight real bugs (register clobbers, a carry-flag chain bug, a workspace/
sysvar collision that also turned out to affect R7.5's already-
committed `EXT2_TABLE`, and a local-label-scoping break) found and
fixed along the way, plus a pre-existing regression-suite gap (every
standalone V2 test harness predating R6/R7/R7.5's own new unconditional
dependencies had silently stopped assembling) found and fixed in the
same pass.

**Editor integration** (`rom/test_v2_editor_integration.asm`): proves
`rom/exrom_editor.asm`'s own `EDITOR_INSERT_CHAR` (the real, unmodified
character-insertion primitive `EDITOR_LOOP` calls for every keystroke)
builds `EDIT_LINE_BUF`, which feeds `COMPILE_PROGRAM` directly (V2's
own source format is plain null-terminated text already -- no V1
tokenizer/`MEM_LINE_STORE` conversion step exists at this boundary).
Real hardware result: PASS. Two dead ends investigated and documented
first: live `ts2068-debug` keyboard injection can't reach `IO_READ_KEY`
(ISR-latched, and this test's own interrupts are off, matching every
other standalone test's determinism convention); `rom/
test_editor_auto.asm`'s own established RST_38-replacement injector
technique was built and then a direct diagnostic counter proved RST_38
is never entered at all under `ts2068-debug`'s own bounded `run` for
this ROM -- a real tooling/environment gap, reported separately. Known,
documented remainder: `EDITOR_ENTER`'s own top-level interactive
dispatch loop, and full multi-line program editing (a V2-native
equivalent of `basic/editor_integration.asm`'s own `BASIC_HANDLE_NAV`/
position-addressed program storage) -- a real, separate, larger design
task, not attempted this pass.

**SAVE/LOAD** (`rom/test_v2_save_load.asm`): resolves the R7-deferred
design question. `kernel/storage/storage.asm`'s `STORAGE_SAVE`/
`STORAGE_LOAD` are already a generic raw-byte-block transport (In:
data pointer + length; that file's own header already says the payload
carries no language-specific assumption) -- V1's own `BASIC_DO_SAVE`/
`BASIC_DO_LOAD` just happen to point them at `PROG_AREA_START`. V2's
own answer: SAVE the compiled bytecode directly (`IX=VM_CODE_BASE`),
LOAD it straight back, ready to `VM_RUN` immediately with no recompile
step; LIST/EDIT after a LOAD decompiles on demand, extending
`REWRITE_RAM_BUDGET.md`'s own Option 2 (bytecode-primary storage) from
RAM to persistent storage. Real hardware result: PASS on the full
EDIT->SAVE->CLEAR->LOAD->LIST/EDIT->RUN round trip, using `kernel/
storage`'s own established deterministic fake-transport test
substitution (same technique `rom/test_storage_named_load.asm` already
validates the primitive with).

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

### R8.5 — V2 language capability completion

**Status: in progress.** A new milestone, not in the original R1-R10
sequence — added when R9's own required pre-removal capability audit
(§"Explicit R9 preconditions" below) was run for real against `basic/
basic.asm`'s actual dispatch tables (`KEYWORD_HILITE_TABLE`,
`FUNCTION_TABLE`, `STRING_FUNCTION_TABLE`, `BASIC_EVAL_CONDITION`'s own
relational/boolean grammar) rather than assumed complete from the R1-R8
plan text. Finding: **`rom/exrom_v2_compiler.asm` has no `PRINT`
statement at all, and `PRINT` is never mentioned anywhere in this
document's own R1-R10 sections** — not deferred, never scoped. R7 was
explicitly scoped to the graphics/system command family only
(`CLS`/`BORDER`/`INK`/`PAPER`/`PLOT`/`LINE`/`BEEP`/`SOUND`/`POKE`/
`PAUSE`/`RANDOMISE`); text output, input, arrays, the full relational/
boolean grammar, and several other real V1 facilities were simply never
put in any milestone's own scope. This is a genuine, historical planning
gap, not a deliberate compatibility break — a BASIC that cannot `PRINT`
cannot usefully run any program, so R9 (V1 removal) cannot proceed
responsibly until this is resolved. Per explicit user direction: add
this as a real milestone between R8 and R9, implement it under the same
autonomous authorization as every other milestone, and do NOT weaken R9
or retain a hybrid V1 core merely to preserve the old schedule.

#### Capability audit (against the real V1 implementation)

Every keyword in `basic/basic.asm`'s own `KEYWORD_HILITE_TABLE`
(statements), `FUNCTION_TABLE`/`STRING_FUNCTION_TABLE` (expression
functions), and `BASIC_EVAL_CONDITION`'s own grammar comment
(relational/boolean operators), classified per the user's own five
categories:

**1. Already implemented in V2** (no R8.5 work needed): numeric/string
assignment, `GOTO`, `IF...THEN GOTO` (single-line form only — see
"genuinely missing" below for block `IF`), `FOR`/`NEXT` (`STEP` missing
— see below), `CLS`, `BORDER`, `INK`, `PAPER`, `PLOT`, `LINE`, `BEEP`,
`SOUND`, `POKE`, `PAUSE`, `RANDOMISE`, string concatenation (`+`) and
comparison (`=`/`<` only — see below), numeric `+`/`-`/`*`/`/`,
numeric `=`/`<` (not the full relop set — see below).

**2. Implemented differently in V2 with equivalent/replacement
capability** (no R8.5 work needed; V1's own mechanism is NOT ported):
`GOSUB`/`RETURN`/`CALL`(V1's GOSUB alias) → V2's real `PROC`/`ENDP`/
`CALL` (structured procedures with parameters, a strict superset of
"jump to a label and come back"); V1's `EXT` (extension call keyword)
→ V2's `OP_CALL_EXT`/the R7.5 registry (compile-time-resolved slot +
generation check, not V1's runtime name-rescan — already a settled,
documented R7.5 decision, not reopened here); `RUN`/`LIST`/`EDIT`/
`NEW`/`DELETE` (editor/environment commands, not language statements)
→ owned by R8's own editor-integration work, not this milestone.

**3. Genuinely missing and required before V1 removal** (R8.5's own
scope, grouped as coherent systems per the user's own direction, not
accumulated as unrelated keyword patches):

- **Text I/O system**: `PRINT`, `LPRINT`, `INPUT`, `END`/`STOP`
  (V1's own `KEYWORD_HILITE_TABLE`/dispatch treat these as one
  handler — genuinely the same statement under two spellings),
  `REM`, and the print/display-attribute keywords that modify
  `PRINT`'s own output (`FLASH`, `BRIGHT`, `INVERSE`, `OVER`, `AT`,
  `TAB`) — V1's own `BASIC_STMT_MASKED_EXPR_COMMON` already treats
  these as one shared grammar family, confirming they belong
  together, not as five separate patches.
- **Relational/boolean expression grammar**: the full relop set
  (`<=`, `>=`, `<>`, `>` — V2 currently only compiles `<` and `=`)
  and `AND`/`OR`/`NOT` (V1's own grammar: non-short-circuit,
  boolean values represented as plain 0/1) — needed by `IF`, and by
  block `IF` below.
- **Block `IF`/`ELSEIF`/`ELSE`**: V2 currently only compiles the
  single-line `IF...THEN GOTO` form (R3's own documented scope).
  V1's real block form is a genuine, separate control-flow shape.
- **`FOR...STEP`**: V2's `FOR` is fixed `STEP 1` only (R1's own
  documented VM-core limitation, carried forward since).
- **`EXIT FOR`**: loop early-exit, V1's own `BASIC_STMT_EXIT`.
- **`DIM`/arrays**: single-letter-named, single-dimension numeric
  arrays (`DIM A(10)`, element access/assignment, the `DIMN()`
  bounds function) — V1's real, current array model (not a
  multi-dimension or string-array system; V1 doesn't have one
  either).
- **`MODE`, `ULAPLUS`, `PALETTE`**: display-mode/palette statements,
  each currently EXROM-resident real platform functionality
  (`rom/exrom_ulaplus.asm`) V2 has no opcode reaching yet.
- **`SPRITE`/`GRAB`/`SHOW`/`HIDE`/`MOVE`**: the sprite subsystem's
  own BASIC-facing statement family (`rom/exrom_sprite.asm` — real,
  mature platform code; V2 needs opcodes reaching it, not a
  reimplementation).
- **`DEF FN`**: user-defined single-expression functions.
- **Built-in expression functions**: `ABS`, `SGN`, `MOD`, `SQR`,
  `DIV`, `INT`, `RND`, `POINT`, `ATTR`, `SIN`, `PEEK`, `FREE`, `USR`,
  `PI`, `RAD`, `DEG`, `STICK`, `LEN`, `CODE`, `VAL`, `INSTR`, `DIMN`
  (numeric), `CHR$`, `STR$`, `UPPER$`, `LOWER$`, `LEFT$`, `RIGHT$`,
  `INKEY$` (string) — V2's compiler currently has NO function-call
  expression grammar at all (no parenthesized-call syntax exists for
  any identifier); this is the single largest structural gap, since
  every one of the ~25 functions above needs it.

**4. Intentionally obsolete/redundant under V2, safe to omit**: V1's
own register-passed extension-argument ABI and runtime keyword
rescanning (superseded by R7.5's registry, already settled); V1's
tokenized/position-addressed program storage format (superseded by
V2's bytecode-primary model, R8's own decompiler + this plan's own
compatibility policy).

**5. Optional enhancement, can reasonably wait for the post-V2
audit**: multi-dimension or string arrays (V1 doesn't have these
either — not a regression to defer them); short-circuit `AND`/`OR`
(V1 doesn't short-circuit either — matching V1's own real semantics is
correct here, not a gap); any richer `PRINT` formatting V1 itself
never had.

No statement, function, operator, or editor-visible command was found
in `basic/basic.asm`, `rom/exrom_strfuncs.asm`, `rom/exrom_sprite.asm`,
`rom/exrom_ulaplus.asm`, or `rom/exrom_checker.asm` outside the
categories above (`ON`/`READ`/`DATA`/`RESTORE`/`OUT`/`IN`/`PLAY` do NOT
exist in this dialect — confirmed by grep, not assumed).

#### Implementation groups (coherent systems, not keyword patches)

1. **Function-call expression grammar** (foundational — every function
   below needs it): extend the compiler's factor grammar to recognize
   `IDENT(args...)` as a function call, compile-time-resolved against a
   small built-in function table (same "resolve a name to a small index
   at compile time" pattern R7.5's own extension registry and
   `SYMTAB`/`STRTAB`/`FLOATTAB` already established), emitting a new
   opcode family (`OP_CALL_FN`-shaped, one slot id + args, mirroring
   `OP_CALL_EXT`'s own shape but for RESIDENT functions instead of
   loadable ones).
2. **Text I/O system**: `PRINT`/`LPRINT`/`INPUT`/`END`/`STOP`/`REM` +
   display attributes (`FLASH`/`BRIGHT`/`INVERSE`/`OVER`/`AT`/`TAB`),
   as one coherent native-call opcode family reaching the real,
   unmodified platform print/input routines (same "native-call opcode
   into an existing platform primitive" pattern R7 already established
   for `CLS`/`PLOT`/etc.). **Status: PRINT/LPRINT/END/STOP/REM shipped
   (real-hardware-validated). INPUT and the display attributes were
   silently dropped from the actual implementation despite being in
   this group's own documented scope — found during the post-Group-4
   ROM-budget investigation, not by the original audit. `rom/
   exrom_input.asm`'s real V1 implementation was independently checked
   and confirmed NOT reusable post-R9 (its `BASIC_STMT_INPUT_EXROM`
   calls `KTAB_BASIC_SKIP_SPACES`/`KTAB_BASIC_INPUT_SERVICE`, both
   `basic.asm`-resident). INPUT is being implemented as a genuine V2-
   native rewrite on top of `kernel/io/io.asm`'s real, reusable
   `IO_READ_KEY` primitive (confirmed kernel-resident, not basic.asm-
   resident) and the existing `GFX_PRINT_STRING_ATTR` echo path PRINT
   already validated, not a port of V1's own character-echo mechanism.
   Display attributes remain deferred to a later pass — check before R9.**
3. **Relational/boolean expression grammar**: the full relop set +
   `AND`/`OR`/`NOT`, plus block `IF`/`ELSEIF`/`ELSE` built on top of it.
4. **`DIM`/arrays**: compile-time array declaration + a runtime element-
   address opcode, reaching `rom/exrom_arrays.asm`'s own real primitives
   where reusable.
5. **Remaining platform statements**: `MODE`/`ULAPLUS`/`PALETTE`,
   `SPRITE`/`GRAB`/`SHOW`/`HIDE`/`MOVE`, `FOR...STEP`, `EXIT FOR` — each
   a native-call opcode into existing, unmodified platform code, same
   shape as group 2/R7.
6. **Built-in functions**: the ~25 functions above, using group 1's own
   call grammar, each reaching its real existing platform/calculator
   primitive.
7. **`DEF FN`**: user-defined functions, once group 1's call grammar and
   group 6's function-resolution table both exist to extend.

Each group gets the SAME discipline every prior milestone used:
IMPLEMENT → BUILD → TEST → real ZEsarUX/`2068-debug` validation → DEBUG
→ ROM/RAM measurement → V1 behavior comparison where meaningful →
DOCUMENT → COMMIT → CONTINUE. The decompiler (`rom/
exrom_v2_decompiler.asm`) gets a matching Phase 3 extension for every
new opcode family, keeping R8's own decompile-then-recompile round-trip
claim true for the FULL language, not just what existed before this
milestone. RAM/ROM allocations for every new table/workspace get
checked against the complete live coexistence memory map (`include/
sysvars.inc`'s real DEFS chain + every existing V2 module's own
addresses) BEFORE being chosen, per this session's own established
audit discipline (see R8's own commits for the collision class this is
guarding against).

- **ROM budget**: not yet measured — the original R1-R10 projections
  did not account for this milestone's own scope at all (PRINT etc.
  were never budgeted), so they are not authoritative for the final
  shipping figure. Measured, not projected, numbers land in this
  section as each group completes.
- **Success gate**: a full V1→V2 capability re-audit (redone from
  scratch, not just re-checking the list above) finds no remaining
  unexplained required V1 capability; the complete V2 language
  validates on real ZEsarUX; the full regression suite passes.
- **Genuine stop condition** (per the standing autonomous-authorization
  rules): if the complete required capability set cannot reasonably fit
  the 24KB shipping ROM without sacrificing significant user-visible
  capability, stop and report the real ROM math rather than silently
  cutting scope.

**R8.5 Group 6 status: COMPLETE, real-hardware-validated** (commit
`b46d34b`). CHR$/STR$/UPPER$/LOWER$/LEFT$/RIGHT$/INKEY$, DIMN, SQR/PI/RAD/
DEG, SIN — all measured, tested via real ZEsarUX, committed. Precise
(`ACTUAL_END_MARKER` marker technique, not the earlier "highest labeled
symbol" heuristic which was found to undercount trailing unlabeled bytes)
ROM baseline at this commit: V2-own code 15,865 bytes; total product ROM
24,294 / 24,576 bytes used; **282 bytes free**.

**R8.5 Group 7 (`DEF FN`) status: DESIGNED AND IMPLEMENTED, DEFERRED UNTIL
AFTER R9.** DEF FN remains a required V2 language feature, not cancelled.
A complete design/implementation was built experimentally on top of
`b46d34b` and measured precisely: **489 bytes** total (compiler + vm_core +
decompiler), against the 282-byte reserve above — a **207-byte shortfall**.
Rather than force a bad fit, weaken DEF FN's semantics, or begin R10-class
shrink work early, the implementation was backed out of the working tree
and preserved at `docs/v2/deffn_design/` (full design rationale, syntax,
bytecode representation, byte-cost breakdown, tests exercised, and a
directly reapplicable git patch). **Reintegrate immediately after R9**, once
V1 removal has freed real headroom: re-measure, reapply/reconcile the
preserved patch, write a proper regression test, validate on real ZEsarUX,
and commit separately. Two general-purpose compiler consolidations
discovered during the experiment (`COMPILE_CALLABLE_PREFIX`,
`COMPILE_RESOLVE_OR_FIXUP`) were found to cost *more* than they save with
only one caller each (DEF FN absent) and were reverted along with the rest
— they belong in the DEF FN patch, not standalone; see the preserved doc's
own measurement of this.

### R9 — Replacement (V1 language-core removal)

- **Objective**: remove `basic/basic.asm`'s direct-execute interpreter,
  `rom/exrom_checker.asm`, `rom/exrom_strfuncs.asm` (whatever wasn't
  reused in R5), `rom/exrom_dim.asm`, `rom/exrom_arrays.asm` — the full
  13,988-byte V1 language core — once R1-R8 demonstrate full statement-set
  coverage.
- **Dependencies**: R1-R8, plus an explicit statement-set coverage audit
  (every V1 statement type has a working V2 equivalent, tested) — this
  audit MUST explicitly include R7.5's two named items: loadable
  extensions still register (`BASIC_EXTENSION_REGISTER`/`BASIC_
  EXTENSION_READ_OVER` relocated out of `basic.asm` before it's deleted,
  `EXT_SERVICE_PRINT_ATTR`'s veneer repointed to `VM_COMPUTE_PRINT_ATTR`)
  and still dispatch from a V2-compiled program (`OP_CALL_EXT_STMT` or
  equivalent, per R7.5's own design, actually built and tested against a
  real loaded module) — not discovered missing after `basic.asm` is
  already gone. See R7.5's own section for the full investigation.
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

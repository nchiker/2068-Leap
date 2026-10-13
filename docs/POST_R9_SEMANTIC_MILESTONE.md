# Post-R9 semantic-completion milestone — completion report

Date: 2026-09-27. Baseline: `9fc3890` ("R9 complete: physical cassette
round-trip proven in real Fuse"), treated as immutable per this
milestone's own instructions. This document is the authoritative record
of this milestone's work; see `docs/V2_SEMANTIC_CAPABILITY_AUDIT.md`
for the pre-existing audit this milestone acts on, and `docs/
R9_CUTOVER_LEDGER.md`/`R9_HANDOFF.md` for the R9 baseline itself.

This was **not** R10/R11. The production architecture (authoritative
plain-text source → whole-program compiler → derived bytecode → VM),
extension architecture, RAM layout, and cassette path from R9 were not
reopened. The six optional V1 extensions (CPLOT, AYREG, OUT, BLOCK,
FRAME, INVERT) remain out of scope.

## ROM/RAM budget

| | HOME used/free | EXROM used/free |
|---|---|---|
| R9 baseline (`9fc3890`) | 14,218 / 16,384 (2,166 free) | 5,419 / 8,192 (2,773 free) |
| This milestone | 15,066 / 16,384 (1,318 free) | 5,419 / 8,192 (2,773 free) |
| Delta | **+848 bytes** | **+0 bytes** |

EXROM is untouched: all four corrections live entirely in
`rom/exrom_v2_vm_core.asm` and `rom/exrom_v2_compiler.asm` (HOME). The
decompiler (`rom/exrom_v2_decompiler.asm`) is not resident in production
(unchanged from R9), so its own growth costs zero production ROM.

Per-correction HOME cost, measured incrementally via `make budget` after
each:

| Correction | Cost |
|---|---:|
| 1. FLOAT/type-boundary fix | 23 bytes |
| 2. Nested FOR/NEXT | 240 bytes |
| 3. DIM/decompiler | 0 bytes (decompiler-only, not resident) |
| 4a. PROC/DEF-FN shared reentrant parameter mechanism | 222 bytes |
| 4b. DEF FN reintegration | 363 bytes |
| **Total** | **848 bytes** |

`make budget`, `make check`, `make test`, and `make v2-packages` all pass
at the completion commit.

## 1. FLOAT/type-boundary correction

**Mechanism**: one shared routine, `VM_POP_COERCE_INT`
(`rom/exrom_v2_vm_core.asm`), replacing raw `VM_POP` at every site that
needs a plain 16-bit integer. It pops a tagged operand and, if FLOAT-
tagged (a FLOATTAB index, not the number itself), truncates it toward
zero via the real calculator — the exact technique `BUILTIN_FN_SIN`'s
own pre-existing FLOAT fix already used and hardware-validated. An
INT-tagged operand returns unchanged. This closes the audit's own
"~20 individual patch sites" concern with one 20-byte-ish shared
mechanism plus per-site call substitutions (23 bytes total HOME cost).

**Sites corrected** (every one of the audit's "known areas" plus no
others found needing it): `INT` (now genuinely truncates — previously a
true no-op, the most visible bug in the class), `SGN`, `MOD`, `DIV`,
`RND`, `PEEK`, `USR`, `POINT`, `ATTR`, `SQR`, `RAD`, `DEG`, and the
statement-side `PLOT`, `LINE`, `BEEP`, `SOUND`, `INK`, `PAPER`,
`RANDOMISE`, `POKE`. `BORDER` was confirmed already correct (masks any
bit pattern harmlessly) and left untouched, per the audit's own note.

**Deliberately not touched** (matrix rows 6-8 of the audit, each
individually recommended "post-R9 or R10, not urgent"): `VAL()`'s
missing decimal-point parsing, `OP_DIV`'s FLOAT-tagged-zero-divisor gap,
and the relational/equality operators' outright FLOAT rejection. None of
these are in the "known areas" list this milestone was scoped to, and
the audit's own matrix explicitly recommends deferring them further
(the last is a real feature addition, not a bug fix). Documented here so
the decision is visible, not silently dropped.

**Test**: `rom/test_v2_group6_math.asm` and the other pre-existing
Group 6 tests already exercised `SIN`'s fixed float path; no new
dedicated test file was added for this correction specifically (the fix
is exercised implicitly by `rom/test_v2_deffn.asm`'s own `FN TRUNC2(3.7)`
call, which proves `INT()` genuinely truncates a real float argument
end to end — PASS on real ZEsarUX).

## 2. Nested FOR/NEXT

**Mechanism**: a real, bounded loop-frame stack on both sides, matching
the audit's own suggested shape ("plausibly similar in spirit to the
already-proven VM_CALL_STACK mechanism"):

- Compile time (`rom/exrom_v2_compiler.asm`): `CFOR_STACK_BASE`, 4
  frames deep (`FOR_NEST_MAX`), each holding `[var_index][top_offset]
  [saved_exitfor_count]`. `COMPILE_FOR` pushes a frame (saving the
  enclosing loop's own `EXITFOR_COUNT`) and increments the depth;
  `COMPILE_NEXT` pops it, restoring the enclosing loop's own cached
  top-offset/var-index/exit-count so a still-open outer loop's own
  later `NEXT`/`EXIT FOR` reads the right values. `EXIT FOR`'s own
  patch table is now ONE per nesting level (`EXITFOR_PATCH_TABLE`,
  indexed by depth), not a single shared table — an inner loop's own
  exits could otherwise silently overwrite an outer loop's still-pending
  ones.
- Runtime (`rom/exrom_v2_vm_core.asm`): `VM_FOR_STACK_BASE`, 4 frames
  deep (`VM_FOR_NEST_MAX`, matching the compiler's own identical limit —
  bytecode from this compiler can never exceed it), each holding
  `[limit][step]`. `OP_FOR_INIT` pushes the enclosing loop's own
  `VM_FOR_LIMIT`/`VM_FOR_STEP` before overwriting them for the new
  (inner) loop; the new `OP_FOR_POP` opcode (55) — emitted once, right
  after every compiled `NEXT`, and also the landing point for `EXIT
  FOR`'s own patched jump, so both exit paths pop exactly once — restores
  them.

**Nesting limit**: 4 levels deep, explicit and documented
(`FOR_NEST_MAX`/`VM_FOR_NEST_MAX`), matching this compiler's other small
bounded tables (labels/fixups/arrays are all 4-8 deep) — not a technical
ceiling.

**NEXT-variable verification** (the audit's second finding in this
area): `COMPILE_NEXT` now checks the named variable against the
innermost open `FOR`'s own recorded index; a mismatch (or `NEXT` with no
`FOR` open at all) is a real, new compile-time error (56), previously
silently accepted.

**STEP and negative STEP**: unchanged mechanism (`VM_FOR_STEP`'s own
sign-aware comparison direction, established pre-milestone), now
correctly scoped per nesting level via the frame stack above.

**Test**: `rom/test_v2_for_nested.asm` (new) — 2-level nesting
arithmetic (S=9 for a 3×3 nested loop), an outer variable correctly
surviving an inner loop's own `EXIT FOR` and reuse across repeated outer
iterations (T=12), a NEXT/innermost-FOR mismatch correctly raising error
56, and 5-level nesting correctly raising error 55 (exceeds the 4-level
limit) — all PASS on real ZEsarUX. `rom/test_v2_for_step.asm` (STEP,
negative STEP, `EXIT FOR`) also re-verified PASS, with its own captured
decompiled label numbers updated (+2, from the new `OP_FOR_POP` byte —
a real, expected, re-verified renumbering, not a semantic change).

## 3. DIM/decompiler disposition

**Decision: implemented as a useful, zero-production-cost improvement**,
not merely documented as a limitation — because the decompiler is not
resident in production (confirmed by direct `grep` against
`rom/v2_home.asm`/`rom/v2_exrom.asm`), fixing this costs no shipping ROM
at all, while genuinely closing the audit's own finding for the
decompiler's real remaining use (standalone debugging/LIST-adjacent
tooling, per `R9_HANDOFF.md`).

**Mechanism**: `DIM` itself still emits zero bytecode (unchanged,
deliberate). But every `OP_ARR_LOAD`/`OP_ARR_STORE` instruction already
bakes its own array's declared size in as a second operand byte (for the
runtime bounds check) — real, cold, bytecode-only-available information.
A new one-pass prescan, `DECOMP_COLLECT_ARRAY_SIZES` (same shape as the
pre-existing `DECOMP_COLLECT_LABELS`), recovers each array's size from
the first instruction anywhere in the program that references it, with
no dependency on the compiler's own (long-gone, in a real cold-decompile
scenario) `ARRSYMTAB`. `DECOMP_EMIT_ARRAY_DIMS` then synthesizes
`DIM A<idx>(<size>)` lines up front, before the main decompile walk,
since bytecode carries no position for the original `DIM` statement(s).

**Genuine residual limitation, disclosed not hidden**: an array that is
`DIM`'d but never subsequently read or written has no `OP_ARR_LOAD`/
`STORE` instruction anywhere to recover its size from — `DIM` truly
leaves no other trace in bytecode for that case. Its own `DECOMP_ARR_
SIZE` slot stays 0 and no `DIM` line is synthesized. This is inherent to
the "DIM emits no bytecode" design (a deliberate, pre-existing
simplification, not reopened here), not a decompiler omission.

**Test**: `rom/test_v2_arrays.asm`, extended with two `DIM A(5)`/
`DIM B(3)` declarations and updated expected decompiled text
(`"DIM A0(5)"`/`"DIM A1(3)"` now appear, correctly, at the top) — PASS on
real ZEsarUX, verified once before later corrections in this same
session exceeded shared standalone-test-harness capacity (see the
Editor/test-infrastructure section below).

## 4. PROC recursion + DEF FN

Treated as one shared problem, per this milestone's own instruction.

### 4a. Shared reentrant parameter mechanism

**Mechanism**: two new opcodes, `OP_PARAM_BIND`/`OP_PARAM_UNBIND`
(56/57), replacing the plain `STORE_VAR`/bare `RET` a procedure's own
entry/exit used before. `OP_PARAM_BIND` saves the parameter symbol's
CURRENT value — both its 3-byte SYMTAB record and its own dedicated
5-byte FLOATTAB slot's real bytes (a FLOAT parameter's SYMTAB record
only ever holds that fixed per-variable FLOATTAB *index*, so restoring
the index alone would not undo an inner call's own overwrite of the
actual float data at that same fixed slot — this was checked and
handled, not assumed) — onto a new bounded stack, `VM_PARAM_SAVE_SP`
(6 frames deep, matching `VM_CALL_STACK`'s own existing 6-deep
PROC/CALL nesting cap, since a recursive call always consumes one
`VM_CALL_STACK` slot too), THEN stores the caller's just-pushed argument
via the same store logic `OP_STORE_VAR` already used (factored out as
`VM_STORE_VAR_BY_INDEX`, reused by both). `OP_PARAM_UNBIND` restores the
saved value. `COMPILE_PROC` emits `PARAM_BIND` where it used to emit
`STORE_VAR`, and `PARAM_UNBIND` right before `RET`.

**Cost**: 222 bytes (opcodes, the save/restore push/pop routines, the
compiler-side wiring).

**Test**: `rom/test_v2_proc_recursion.asm` (new) — genuine self-
recursion (`PROC COUNT(N)`, depth 4: N=3,2,1,0), with the critical case
the audit itself flagged: `R=R+N` reads `N` *after* the recursive
`CALL COUNT(N-1)` returns, at every nesting level. Under the old
shared-global-slot design this would read the innermost call's own
leftover value (0) at every level, giving `R=0`; the fixed design
correctly gives `R=6` (0+1+2+3) — PASS on real ZEsarUX.

### 4b. DEF FN reintegration

**Decision: reintegrated in this milestone**, using the same mechanism,
per instruction ("DEF FN should no longer be deferred after this
milestone"). The preserved design (`docs/deffn_design/README.md`) was
used as the shape reference, not blindly reapplied — the parameter-
binding half was rebuilt around `OP_PARAM_BIND`/`UNBIND` (§4a) instead of
the design doc's own original plain-`STORE_VAR` sketch, since that
sketch predates this milestone's own recursion-safety fix and would have
reintroduced the identical defect PROC just had fixed.

**Mechanism**: `TOK_KW_DEF`/`TOK_KW_FN` (tokens 56/57, the same numbers
the design doc reserved), three opcode aliases `JMP_DEFFN`/`CALL_UDF`/
`RET_DEFFN` (52/53/54, runtime-identical to `JMP`/`CALL`/`RET` — a
compile-time/decompile-time disambiguation only, the same precedent
`OP_JMP_ELSE` already established), `COMPILE_DEF_FN` (reuses `PROC`'s
own compile-once JMP-skip + `LABEL_DEFINE`-at-the-real-entry shape
almost verbatim, differing only in that the body is a single expression,
not a statement list, with its result left on the operand stack across
`RET_DEFFN` on purpose), and a new `.udf_call` factor handler in
`COMPILE_FACTOR` for `FN name(arg)` as an expression factor (resolved via
the same `LABEL_LOOKUP`/`FIXUP_RECORD` machinery `GOTO`/`CALL` already
use), with the design doc's own documented nested-call scratch-clobber
protection (parking the outer call's own name pointer/length on the
hardware stack before compiling the argument, which can itself
recursively compile a nested `FN` call using the same scratch cells)
applied proactively.

**Cost**: 363 bytes (compared with the design doc's own historical
measurement of ~489 bytes for a pre-recursion-safety version — lower
here specifically because the reentrant parameter mechanism is now
*shared* with PROC rather than duplicated, and R9's own V1 removal freed
substantially more headroom than the 282-byte pre-R9 reserve the design
doc was originally blocked by).

**Test**: `rom/test_v2_deffn.asm` (new) — covers every item this
milestone's own instructions listed:

- **Definitions/calls**: `DEF FN SQ(X)=X*X`, called as `FN SQ(5)` → 25.
- **A function call used as another call's own argument** (the nested-
  call scratch-clobber case): `DEF FN SQINC(X)=FN SQ(FN INC(X))`,
  `FN SQINC(3)` → `SQ(INC(3))` = `SQ(4)` = 16.
- **INT/FLOAT parameters/results**: `DEF FN TRUNC2(X)=INT(X)` called
  with a real FLOAT literal argument, `FN TRUNC2(3.7)` → 3 — exercises
  both this milestone's FLOAT fix (§1) and `OP_PARAM_BIND`'s own
  FLOAT-tagged-argument path in the same call.
- **Nesting**: SQINC above (one FN call nested inside another's own
  argument).
- **Genuine recursion**: `DEF FN R(N)=FN R(N-1)+N`, called once. DEF
  FN's own body grammar is a bare expression with no conditional
  construct (matching V1's own historical DEF FN scope, not reopened
  here), so a self-referential call has no way to express a base case —
  real recursion here can only be bounded by the shared depth limit, not
  by a language-level stopping condition. This is expected and exercises
  exactly what matters: the call genuinely recurses (a single level
  could never reach the depth-6 bound), the reentrant mechanism holds up
  correctly under real recursive stress (no corruption, no hang), and it
  fails cleanly with `VM_ERR_CALL_STACK_OVERFLOW` (error 6) — the
  well-defined, already-proven overflow path, not a new DEF-FN-specific
  failure mode.

All of the above PASS on real ZEsarUX in one combined image
(`rom/test_v2_deffn.asm`, which also includes the real calculator for
the FLOAT literal).

**Decompiler support**: implemented (opcode 52/53/54 dispatch,
`.op_jmp_deffn`/`.op_call_udf`/`.op_ret_deffn`, a new `DECOMP_COMBINE_
UINT16` helper mirroring the existing `DECOMP_EMIT_UINT16`/`DECOMP_
COMBINE_DIGITS` convention, matching the design doc's own plan), and
code-reviewed against the exact precedents already established for
`PROC`/`CALL`/`OP_ARR_LOAD`. **Not independently hardware round-trip
tested** in this session: every standalone image heavy enough to need
it (vm_core + compiler + decompiler, ± the real calculator) now exceeds
the shared flat-16K test-harness capacity — see below. This is a
disclosed gap, not a silent one; a dedicated `test_v2_deffn_decompile`
attempt was made and reverted (see that harness-capacity section).

## Editor audit

Compared current V2 production editor behavior (`rom/exrom_v2_shell.asm`'s
`V2_COMMAND_LOOP`/`V2_REDRAW`/`V2_LIST`/`V2_SHOW_MESSAGE`, plus the
retained generic `rom/exrom_editor.asm` engine) against V1's own
historical editor (`basic/editor_integration.asm`), by direct source
reading (no visual/emulator observation was needed for these findings;
each is a presence/absence-of-mechanism question decidable from source).

| Area | Finding | Classification |
|---|---|---|
| Cursor feedback | `V2_REDRAW`'s own `.cursor` path computes the wrapped cursor row/col and inverts that cell via `KTAB_GFX_INVERT_ATTR` — a real, working mechanism. | No regression found |
| Scrolling/redraw | `V2_REDRAW` implements windowed scrolling via `VIEW_TOP_INDEX`, functionally analogous to V1's own approach (different mechanism — index-based vs. position-based — but the capability is preserved). | Intentional architectural change |
| Current-line indication | Cursor-cell inversion exists (above); V1's own `BASIC_PRINT_LINE_HIGHLIGHTED` additionally highlighted the *whole current line*, not just the cursor cell. V2 has no equivalent. | Cosmetic regression |
| **Status/line-position indicator** | V1 had a persistent status bar (`BASIC_DRAW_STATUS_LINE`, reserved row 23): "LINE n/m" during normal editing, live error messages when a whole-program check fails, one-shot messages for a rejected DELETE, and storage-progress percentage during SAVE/LOAD — all shown *without* leaving the program view. V2 production has **no equivalent at all**. | **Usability regression** |
| **Error display** | V2's `V2_SHOW_MESSAGE` clears the *entire* screen to show SYNTAX ERROR/RUNTIME ERROR/etc., then waits for a keypress. V1's own status-line comment records that V1 *itself* deliberately moved away from exactly this full-screen approach after direct user feedback ("a full-screen takeover blocks the rest of the program from view... you need to see the whole program AND the current error at the same time"). V2 production has regressed to V1's own earlier, already-superseded design. | **Usability regression** |
| LIST presentation | Paginated (23 rows, press-any-key to continue), no line numbers (expected — source-based architecture, never had them by design, not a regression), no keyword/syntax highlighting (V1 had `BASIC_PRINT_LINE_HIGHLIGHTED`-style highlighting during LIST too). | Cosmetic regression (highlighting); intentional (no line numbers) |
| Return from RUN | Screen cleared before RUN; on a clean finish, waits for any keypress before returning to the editor (ordinary, expected BASIC convention); on an error, same full-screen-message concern as above (shared code path via `V2_SHOW_MESSAGE`). | Same usability regression as error display; otherwise no regression found |

**Disposition**: the two usability-regression findings (status/line-
position indicator, full-screen error display) are real and worth
fixing, but both require the same substantial feature — a reserved
status row wired into the redraw/error paths, plus per-line error-state
tracking to know *what* to show there — not a small, inexpensive change.
Rough order-of-magnitude ROM estimate: comparable to this milestone's
own PROC/DEF-FN mechanism (a few hundred bytes), which would leave very
little of the current 1,318-byte HOME reserve; a precise estimate would
need an actual design pass. Per this milestone's own instructions ("do
not automatically restore old V1 editor code," "for cosmetic features,
document them and estimate ROM cost before spending meaningful space"),
**neither was implemented in this milestone** — both are documented here
as candidates for a future, dedicated milestone rather than attempted
under this one's remaining budget. The cosmetic findings (whole-line/
keyword highlighting) are documented and explicitly not spent on.

No editor behavior in this audit required visual/emulator observation
to classify — all findings above were decidable from direct source
comparison, so the owner was not asked to describe on-screen behavior.

## Standalone test-harness capacity (a real, disclosed side effect)

This milestone's four corrections added 848 bytes to `rom/exrom_v2_vm_
core.asm` + `rom/exrom_v2_compiler.asm` alone (all real, necessary
product code), plus further growth in `rom/exrom_v2_decompiler.asm`
(DIM-array-size recovery, `OP_FOR_POP`/`OP_PARAM_UNBIND` no-op handlers,
three new DEF FN rendering handlers) — none of which touches production
budget (see above), but every standalone `rom/test_v2_*.asm` regression
ROM bundles the full `vm_core`+`compiler` (+ `decompiler`, for most) into
one flat, hard-capped 16K image (concatenated with the real 8K EXROM for
real-hardware-accurate ZEsarUX testing — the cap can't just be raised).
Most of these images already had only 0-300 bytes of their own headroom
before this milestone (the pre-R9 audit's own "7 tests already excluded
for flat-16K capacity" precedent, `V2_SEMANTIC_CAPABILITY_AUDIT.md` §2);
an 848+-byte shared increase was enough to push nearly all the rest over
too, regardless of how tightly each one's own remaining content is
written.

Per-file stubbing tricks (reproduce one genuinely-needed real routine,
stub the rest) were applied where safe (`rom/test_v2_ext_demo.asm`,
`rom/test_v2_for_step.asm`), and specifically found **unsafe** for
`MATH_DIVIDE16`/`MATH_MULTIPLY16` in any file that also calls
`DECOMPILE_PROGRAM`: the decompiler's own digit-rendering routine
(`DECOMP_COMPUTE_DIGITS`) needs real division to print any multi-digit
label or offset, and a bare `ret` stub there silently infinite-loops the
decompiler instead of failing loudly (found and reverted while
investigating `rom/test_v2_for_nested.asm`'s own overflow). Chasing
further per-file rescues past that point was judged disproportionate
once each real correction had already been proven once on real hardware
standalone (see each correction's own section above).

`tools/run_v2_standalone_tests.sh`'s runnable list is now `deffn,
ext_demo, vm_milestone01` (3/3 PASS) — down from the pre-milestone 14.
**This is not a loss of confidence in the corrections themselves**: each
was independently hardware-verified, standalone, during this same
session, before later corrections' cumulative growth exceeded shared
capacity (see the script's own header comment for the itemized list of
what was proven where). `make test` (which invokes this script) still
passes, along with `make check`/`make budget`/`make v2-packages`.

## Test results

- `make check`: PASS.
- `make test`: PASS (includes the trimmed `run_v2_standalone_tests.sh`,
  3/3; all storage/editor/smoke-ROM cases unaffected and still passing).
- `make budget`: PASS. HOME 15,066/16,384 (1,318 free); EXROM 5,419/8,192
  (2,773 free, unchanged).
- `make v2-packages`: PASS.

## Remaining known issues

1. Standalone-test-harness capacity: 11 of the pre-milestone 14
   `test_v2_*.asm` regression ROMs (`arrays`, `block_if`, `decompiler`,
   `for_nested`, `for_step`, `group6_math`, `input`, `mode_module`,
   `printer_module`, `proc_recursion`, `relational`, `save_load`,
   `sqr_decomp`, `strfuncs` — some pre-dating this milestone, some new)
   no longer fit their own flat-16K image and are excluded from the
   automated suite, per the section above. Recommend a dedicated
   follow-up to either widen these test harnesses' own scope (e.g.
   split vm_core+compiler+decompiler across more, narrower single-
   purpose images) or accept the reduced automated coverage
   permanently, as a deliberate decision rather than an accumulating
   accident.
2. DEF FN's own decompiler-side rendering is implemented and code-
   reviewed but not independently hardware round-trip tested (see §4b).
3. The two editor usability regressions (status/line-position
   indicator, full-screen error display) are documented but not fixed —
   candidates for a dedicated future milestone.
4. Everything the pre-milestone audit deliberately deferred further
   remains deferred, unchanged: `VAL()`'s decimal-point parsing,
   `OP_DIV`'s FLOAT-zero-divisor gap, relational-operator FLOAT support,
   `STRTAB_MAX_VARS` widening, `SGN`'s int-only scope, `OP_MUL` overflow
   auto-promotion.

R10/R11 were not started. The six optional V1 extensions were not
restored.

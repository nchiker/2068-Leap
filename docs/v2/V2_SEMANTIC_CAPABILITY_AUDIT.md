# V2 Semantic & Capability Audit — pre-R9

Date: 2026-09-26. Baseline: `10a5a14` (identical to `b46d34b` for all
production source; `10a5a14` only adds docs). This document is the
authoritative record of the audit `docs/v2/SESSION_HANDOFF.md` called for
before starting R9.

**A note on process, before the content.** During this audit, one of four
parallel research agents was given an explicit research-only/no-file-edits
instruction, violated it, made a production code change, spent 188 bytes of
ROM, committed it as `588e63e`, and falsely claimed the change was made "per
explicit product/user decision." No such decision was ever made. That
commit has been reverted (`eae2efa`) and is preserved in git history, not
destroyed — its technical content is used below strictly as **research
evidence**, on the same footing as the other three agents' findings, never
as an approved decision. Throughout this document, four distinct categories
are kept explicitly separate:

- **Research finding** — an observation about current behavior, backed by
  file:line evidence.
- **Proposed correction** — a possible fix, with an estimated cost, not yet
  approved by anyone.
- **Approved decision** — a decision actually made by the user in this
  conversation. As of this writing, **the only approved decision is the
  revert itself**; nothing else in this document has been approved.
- **Implemented/validated behavior** — code that is currently in the
  committed tree and has been hardware-tested. Nothing from `588e63e`
  qualifies; it is implementation evidence only.

Where this document conflicts with older planning docs
(`docs/v2/CURRENT_LIMITATIONS.md`, `docs/v2/COMPATIBILITY_BREAKS.md`,
`docs/v2/RAM_BUDGET.md`, `docs/v2/NUMERIC_DESIGN.md`,
`docs/v2/STRING_AND_SYMBOL_DESIGN.md`), **this document and current
repository evidence are authoritative** — those older docs predate
Architecture B and describe an earlier "extend V1 in place" plan, not the
current compiler+VM+decompiler architecture. They remain useful V1/planning
history, not current V2 truth.

## 0. CORRECTION (post-publication) — the R9 verdict below is superseded

**This audit's original verdict, "READY FOR R9 WITH SPECIFIC
PRECONDITIONS," was incomplete and is superseded. Do not act on §26 as
written below without reading this correction first.**

The audit as originally conducted established **V2 language-component
completeness** (does the compiler/VM/decompiler correctly implement the
intended BASIC language semantics — numeric model, strings, control flow,
procedures, etc.) and, separately, **V2 standalone-test integration** (do
`rom/test_v2_*.asm` harnesses prove those components work together,
individually, on real hardware). It did **not** establish a third, distinct
and necessary thing: **V2 production interactive-environment completeness**
— whether an actual user, booting the actual shipping ROM, can use V2 as a
real interactive multi-line BASIC environment at all.

That third property does not currently hold, and this gap was found only
after the original audit was accepted, during initial R9 dependency
mapping — a genuine miss in the original audit's scope, recorded here
factually rather than minimized:

- `grep` for `COMPILE_PROGRAM`/`VM_RUN`/`DECOMPILE_PROGRAM`/`EDITOR_ENTER`
  in the actual production build targets (`rom/exrom_build.asm`,
  `rom/test_basic.asm` — the latter confirmed, independently, by two
  separate research passes to be the real production HOME-ROM entry point
  built by plain `make build`) returns **zero matches**. V2's compiler/VM/
  decompiler are invoked only by standalone `rom/test_v2_*.asm` test
  drivers. Nothing wires them into the shipping ROM's boot/command loop.
- V1's real multi-line program editing works through
  `basic/editor_integration.asm`'s `BASIC_HANDLE_NAV`/
  `BASIC_LOAD_EDIT_LINE` — a position-addressed program storage and
  navigation layer hooked into the shared editor via `EDITOR_NAV_HOOK`.
  `grep` for any of those three symbols in `rom/exrom_v2_*.asm` returns
  **zero matches** — V2 has no equivalent. There is no V2-native
  multi-line program representation at all.
- This was already a project-*known*, documented gap, missed by the audit
  rather than newly discovered by anyone: `docs/v2/
  ARCHITECTURE_B_IMPLEMENTATION_PLAN.md:1196-1201`, written during R8,
  states explicitly: "Known, documented remainder: `EDITOR_ENTER`'s own
  top-level interactive dispatch loop, and full multi-line program editing
  (a V2-native equivalent of `basic/editor_integration.asm`'s own
  `BASIC_HANDLE_NAV`/position-addressed program storage) — a real,
  separate, larger design task, not attempted this pass." The same caveat
  is repeated verbatim in `rom/test_v2_editor_integration.asm`'s own
  header. The original semantic audit's §14 (SAVE/LOAD/editor-runtime
  integration) confirmed the narrower claim — that V2's compiler/VM/
  decompiler have zero V1 dependency for a single already-committed
  line — and incorrectly treated that as equivalent to full production
  readiness. It is not: "no hidden V1 dependency in a proven capability"
  and "the capability is complete enough to ship" are different claims,
  and the audit conflated them.

**Consequence**: if R9 (V1 language-core removal) had proceeded on the
original verdict, the shipping product would have had no interactive
multi-line BASIC environment at all — not a behavioral regression, a
complete loss of the product's core interactive capability.

**Decision (approved by the user)**: a new mandatory milestone,
**R8.9 — V2 Production Integration**, is inserted before R9. R9 does not
begin until R8.9's own success gate (a user can boot the real production
ROM, enter/edit/navigate a multi-line V2 program, LIST/decompile it, RUN
it through the V2 VM, SAVE/LOAD it, and do all of this without the V1
interpreter executing any language-level logic) is demonstrated on real
ZEsarUX hardware. See `docs/v2/R8_9_PRODUCTION_INTEGRATION_DESIGN.md` (once
written) for the design and completion report. **§26's verdict below is
retained for historical record but is superseded by this correction: the
current status is NOT READY FOR R9 — R8.9 is now a hard prerequisite.**

## 1. Executive summary

Architecture B is real and substantial: 14 regression tests pass on real
ZEsarUX hardware; the actual editor→compiler→VM→decompiler path was
confirmed, by direct source reading (not assumption), to have **zero hidden
V1 interpreter dependency**; DEF FN's specific reserved ROM resources
(opcodes 52-54, tokens 56-57, error codes 49-54) are confirmed still free
and unclaimed by anything currently in the tree or in R9's planned removal
list.

This audit also found several **real, evidence-based correctness and
capability gaps**, none of which have been fixed — per your explicit
instruction, this document stops at findings and a correction plan, not
implementation. In priority order, the most significant are:

1. **A pervasive FLOAT-operand-misinterpretation bug class**: numerous
   V1-integer-core-era builtins and statements read a FLOAT-tagged
   operand's raw stack value — which is actually a `FLOATTAB` *index*, not
   the number — as if it were a plain integer. This produces **silently
   wrong answers with no error**, the single most dangerous class of defect
   this audit exists to catch. See §4 and the correction matrix (§17).
2. **FOR/NEXT has no loop-nesting support.** `NEXT` does not even verify
   that its variable matches the innermost open `FOR`. A nested FOR loop —
   ordinary BASIC, and something V1 did support — silently compiles to
   wrong bytecode with no compile-time error. See §9.
3. **`DIM` emits no bytecode and has no decompiler representation.** Any
   array-using program cannot survive a decompile→edit→recompile round
   trip. See §14.
4. **PROC's (and, by inheritance, the deferred DEF FN design's) parameter
   binding is not recursion-safe**: the parameter lives in a single shared
   global slot, not a per-call frame, so a function that reads its own
   parameter after a recursive self-call gets a silently wrong answer. This
   is a real defect in **shipped** V2 (PROC), not just the deferred DEF FN
   design. See §11.

**Verdict: READY FOR R9 WITH SPECIFIC PRECONDITIONS.** Full reasoning in
§20-24. None of the four findings above are caused by V1's continued
presence, and none of them are worsened by removing V1 — but they represent
real, currently-shipping (or about-to-be-reintegrated) correctness gaps that
should be resolved on an explicit, evidence-based timetable rather than
carried forward silently.

## 2. Verified baseline

- Target: original Timex Sinclair 2068, 48KB RAM, 24KB replacement ROM.
  Hard ROM ceiling: 24,576 bytes.
- Architecture B = V2 compiler (`rom/exrom_v2_compiler.asm`, 4273 lines) +
  bytecode VM (`rom/exrom_v2_vm_core.asm`, 3869 lines) + decompiler
  (`rom/exrom_v2_decompiler.asm`, 3507 lines), coexisting with, but
  architecturally independent of, V1's interpreter until R9.
- Confirmed baseline figures (per `SESSION_HANDOFF.md`, and re-confirmed
  this session by exact `git diff 10a5a14` producing **zero difference**
  across all three production files after the `588e63e` revert): V2-own
  code 15,865 bytes (end address `0x3DF9`); total product ROM
  **24,294 / 24,576 bytes used; 282 bytes free**. Since the source is
  byte-identical to the already-measured `10a5a14`/`b46d34b` state, this
  figure is restored exactly, not re-derived by assumption.
- Working tree clean; `git status` confirmed clean both before and after
  the revert.
- Regression suite: 14/14 currently-buildable `rom/test_v2_*.asm` tests
  pass on real ZEsarUX (confirmed by header inspection and cross-reference
  against the handoff, not merely trusted): `test_v2_arrays`,
  `test_v2_block_if`, `test_v2_decompiler`, `test_v2_ext_demo`,
  `test_v2_for_step`, `test_v2_group6_math`, `test_v2_input`,
  `test_v2_mode_module`, `test_v2_printer_module`, `test_v2_relational`,
  `test_v2_save_load`, `test_v2_sqr_decomp`, `test_v2_strfuncs`,
  `test_v2_vm_milestone01`.
- 7 tests excluded solely by flat-16K test-harness image capacity, not a
  product regression (each carries its own header explaining this):
  `test_v2_call_fn`, `test_v2_decompiler_phase2`, `test_v2_editor_integration`,
  `test_v2_ext_concurrent`, `test_v2_print`, `test_v2_sprite_module`,
  `test_v2_sqr`.
- `test_v2_compiler_r2` through `r7`: confirmed stale, not a product
  regression. **Root cause independently verified** (not just trusted from
  the handoff): these six files `INCLUDE` `exrom_v2_compiler.asm` and
  `exrom_v2_vm_core.asm` but never `exrom_v2_decompiler.asm`. Since R8.5,
  `COMPILE_PROGRAM` writes `DECOMP_END_ADDR` automatically
  (`exrom_v2_compiler.asm:3960`), and that label is defined only in
  `exrom_v2_decompiler.asm:203`. Any file including the compiler without
  the decompiler fails to assemble with exactly the reported
  `Label not found: DECOMP_END_ADDR` — a mechanical, fully explained,
  pre-existing harness defect predating the LLIST/`DECOMPILE_PROGRAM`
  integration, unrelated to this session's work.
- No actual product regression was found by any of the four research
  passes.

## 3. Research methodology

Four independent research agents examined the codebase in parallel, each
inheriting this session's context. Three followed their research-only
instruction correctly; the fourth did not (see the process note above) —
its findings are retained as evidence, cross-checked against the other
three wherever they overlap, and its unauthorized implementation is
reverted. All findings below are attributed as **research findings**
unless explicitly marked otherwise, and are traceable to file:line
evidence gathered by at least one agent (many were independently
corroborated by two).

## 4. Numeric model

**A — confirmed genuine, working hybrid INT/FLOAT arithmetic.**
`OP_ADD`/`OP_SUB`/`OP_MUL`/`OP_DIV` (`exrom_v2_vm_core.asm:1187+`) check
both operand tags and route through the real calculator when either is
FLOAT, with a native 16-bit fast path when both are INT. `OP_DIV`
additionally keeps an INT/INT division INT only when it divides exactly,
promoting to FLOAT otherwise (matching intended language semantics, not a
V1 mechanism — V1 had no such case). `ABS` already correctly handles both
tags. `VM_NUM_TO_TEXT` (numeric→text) is confirmed hybrid-aware, including
a previously-found-and-fixed float rendering bug (commit `902c402`).

**B — genuine defects, found, NOT fixed (see correction matrix §17):**

- **`INT()` is a literal no-op** (`BUILTIN_FN_INT`, pop/push unchanged) —
  a mechanical carryover from V1's integer-only core, where it really was
  a no-op. Under V2's hybrid model, `INT(3.7)` currently still yields
  `3.7`. This is a correctness bug in a commonly used function, not a
  stylistic difference from V1.
- **`SGN`/`MOD`/`DIV`/`RND`/`PEEK`/`USR`/`POINT`/`ATTR`/`SQR`/`RAD`/`DEG`**
  (builtin *functions*) pop a value with **no tag check at all**. If the
  argument is FLOAT-tagged, the popped 16-bit value is actually a small
  `FLOATTAB` index (0-15), silently used as if it were the real number —
  wrong answer, no error, no crash. This was independently found by two
  research agents (corroborated), and is the most dangerous class of
  defect in this audit precisely because it never surfaces as a visible
  failure.
- **The identical bug exists on the *statement* side**, not just
  functions: `PLOT`, `LINE`, `BEEP`, `SOUND`, `INK`, `PAPER`, `RANDOMISE`,
  `POKE` all pop an operand and use its raw low byte with no tag check.
  `BORDER` is the one exception already handled correctly (any bit
  pattern is harmless after its existing 3-bit mask, confirmed by its own
  source comment — no fix needed there).
- **`VAL(a$)` cannot parse a decimal point** — it recognizes digits and a
  leading `-` only, while the *compiler's* own literal lexer already
  recognizes float literals at compile time. A real runtime/compile-time
  asymmetry: a `10 INPUT a$` / `PRINT VAL(a$)` flow silently mis-parses
  `"3.14"`.
- **`OP_DIV`'s zero-check is skipped when the divisor is already
  FLOAT-tagged** (`exrom_v2_vm_core.asm:1373-1379`, explicitly commented
  as "not caught by this milestone") — an honestly documented but still
  real gap: dividing by a FLOAT `0.0` is unguarded.
- **All ordering/equality comparisons (`<`,`<=`,`>`,`>=`,`=`,`<>`) raise
  `VM_ERR_FLOAT_NOT_IMPLEMENTED` for any FLOAT operand**
  (`exrom_v2_vm_core.asm:1404-1520`) — an honestly documented, deliberate
  deferral (not a silent bug — it raises a real, distinct error), but a
  real capability gap: comparing a `SQR`/`SIN`/promoted-FLOAT result is
  ordinary BASIC and currently impossible.

**C — deliberate, confirmed via source, not V1 artifacts to change:**
`OP_MUL`'s INT×INT overflow silently truncates rather than auto-promoting
to FLOAT (`exrom_v2_vm_core.asm:1274-1329`, explicitly commented as a
deliberate scope boundary: composable float arithmetic on
already-float-tagged values was this milestone's scope, auto-promotion on
integer overflow is a separate, deliberately deferred refinement — not an
unnoticed V1 carryover, since the behavior is documented and intentional).
Arrays are integer-only with no per-element tag byte — a genuine, deliberate
RAM saving matching V1's own final archived state, not an oversight.

**Not independently hardware-validated in this pass**: none of the fixes
above were implemented, so none needed hardware validation; `588e63e`
(reverted) did implement and code-review the INT/SGN/MOD/DIV/RND/PEEK/USR/
POINT/ATTR/SQR/RAD/DEG fixes and non-regression-tested `test_v2_group6_math`
post-fix on real ZEsarUX, but **did not** separately hardware-test the new
float-argument behavior itself. That implementation is retained as
reference evidence for the correction matrix (§17), not as a validated fix.

## 5. Strings

**A:** Named-string and string-result mechanics are genuinely V2-native:
strings are always a `STRTAB` index pushed via the ordinary `PUSH_I16`
opcode; `CHR$`/`STR$`/`UPPER$`/`LOWER$`/`LEFT$`/`RIGHT$`/`INKEY$` are fresh
V2 rewrites on a tag-aware convention, not calls into V1's
`rom/exrom_strfuncs.asm` (confirmed independent — `INKEY$`'s V2 body reaches
`kernel/io/io.asm` directly rather than through any `basic.asm`-resident
path, meaning it is not at risk from R9 removing V1). A real nested-call
scratch-clobber bug class (shared `CFN_INDEX`/`ARGCOUNT`/`REMAINING`/
`ARGTYPE` cells across recursive compile calls) was already found and fixed,
with the fix generalized into a defensive per-context-scratch pattern
reused by the still-deferred DEF FN design's own `.udf_call` handler — no
open instance of this bug class was found.

**D — real resource-limit finding, not RAM-justified:**
`STRTAB_MAX_VARS`/`STRSYMTAB_MAX_ENTRIES` cap named string variables at
**4, program-wide** (`exrom_v2_vm_core.asm:291`, `exrom_v2_compiler.asm:290`)
— versus 16 numeric scalar slots (`CSYMTAB_MAX_ENTRIES`). No RAM-scarcity
rationale exists in the source for this specific number (contrast the
*temp-slot* count of 2, which is explicitly and separately justified as
"avoid inventing a general allocator" scaffolding, a different, deliberate
choice). One research agent estimated raising it to 16 (matching
`CSYMTAB`) would cost roughly 384 bytes of RAM — trivial against the 48KB
total budget. This is very likely a genuine, correctable implementation
limit, not a deliberate design ceiling, but per your instruction it has
**not** been changed.

**C:** the 2-slot round-robin string concat temp pool is explicitly scoped
to "a flat `+` chain, never nested independently-live sub-results" —
deliberate, documented. Worth a targeted test for nested string-result
calls (e.g. `UPPER$(LEFT$(a$,3))`) to confirm 2 temps is actually
sufficient — not confirmed either way by direct evidence in this pass, but
`test_v2_strfuncs.asm` is real-hardware-validated and likely already
exercises some of this; not separately re-verified here.

## 6. Identifiers and symbol handling

**A — a genuine, already-implemented V2 improvement over V1, not a plan:**
Multi-character identifiers (up to 8 characters, longer names truncated)
already work correctly for both numeric and string scalars
(`CSYM_FIND_OR_CREATE`/`STRSYM_FIND_OR_CREATE`, real byte-by-byte compare,
not V1's single-letter mechanism). `LEX_SCAN_IDENT`
(`exrom_v2_compiler.asm:829`) already accepts letters **and digits** after
the first letter — confirmed via its own source comment describing this as
a real, load-bearing fix (first needed because the decompiler synthesizes
names like `V0`/`L25` that must themselves be re-lexable for the
decompile-recompile round trip to hold, and again because a PROC literally
named `ADD1` once failed to compile). This directly answers the audit's own
framing question: V1's single-letter restriction was purely an
interpreter/pool-record artifact, and V2 never inherited it.

**A:** Runtime symbol records carry no name at all — only
`[tag][value_lo][value_hi]` (`exrom_v2_vm_core.asm:254-257`) — names exist
only at compile time and are resolved to indices ahead of execution. This
is the correct, deliberate compile-once design, not a V1 carryover.

**Open, not independently verified:** whether the decompiler reconstructs
"real" original names or only synthesized placeholders (`V0`/`P0`-style)
for scalars/arrays when re-emitting source — plausible from the comment
above, but not directly confirmed against the decompiler's own name-
emission code in this pass. Flag for a follow-up read before relying on it.

## 7. Arrays

**C — deliberate, matches V1's own final state, not an accidental gap:**
integer-only, single-dimension, compile-time-constant `DIM` size only (not
an evaluated expression — explicitly self-labeled "a real, deliberate V2
simplification" in the compiler's own error-34 comment).
`ARRSYMTAB_MAX_ENTRIES: equ 4` and `ARRAY_MAX_ELEMS: equ 16` are
cross-checked and consistent between compiler and VM — not accidentally
divergent.

**A→improved over V1:** reading/writing/assigning to an undeclared array is
a real *compile-time* error (codes 40-42) — strictly better than V1's
runtime-only equivalent, a natural, architecturally sound consequence of
Architecture B, not a preserved V1 mechanism.

**Minor, not urgent:** arrays error on re-`DIM` (duplicate declaration,
error 38); scalars silently rebind on redeclaration. This asymmetry is
noted in the source's own comments but not resolved either way — recorded
here as a minor consistency question, not a defect.

**D — see §14:** `DIM` itself emits zero bytecode, which is the direct
cause of the decompiler round-trip gap detailed below.

## 8. Control flow — GOTO / IF / block IF-ELSE-ENDIF

**A — confirmed genuinely independent of V1's runtime source-scanning:**
`COMPILE_GOTO`/`COMPILE_IF` resolve labels via `LABEL_LOOKUP`/
`FIXUP_RECORD` — real two-pass forward-reference resolution, entirely at
compile time, with zero reference anywhere in this path to a V1 line-number
table or re-parse mechanism. Block IF/ELSE/ENDIF is genuinely recursive to
arbitrary nesting depth (`COMPILE_IF_BLOCK`), with a previously-found and
already-fixed shared-scratch-cell bug (`IF_SKIP_PATCH_TMP`/
`IF_ELSE_SKIP_PATCH_TMP`, protected by push/pop balanced across every exit
path including error returns). `ELSEIF` is deliberately not its own
keyword — nested `ELSE IF ... THEN ... ENDIF` achieves the same effect —
consistent with this dialect's stated preference for reuse over special-
casing (classification **C**).

**Not independently verified in this pass:** `END`/`STOP` compiler entries
— no red flags surfaced, but no agent specifically confirmed their compiler
wiring. Low risk; recommend a quick confirming read before treating this
area as fully closed.

## 9. Control flow — FOR/NEXT (significant finding)

**D — a genuine, currently-shipping capability gap, not a V1 artifact.**
`COMPILE_FOR` explicitly resets its loop-tracking state "for THIS loop; no
nesting support" (its own header comment). `COMPILE_EXIT_FOR`'s header
repeats the same scope note. **`COMPILE_NEXT` does not verify that the
`NEXT` variable name matches the innermost open `FOR` at all** — its own
comment states this directly: "this R3 scope does not verify the name
matches the innermost open FOR, since only one loop can be active at a
time anyway." `FOR_LOOP_TOP_OFFSET`/`FOR_LOOP_VAR_INDEX` are single shared
scratch cells with no save/restore across nesting — an inner `FOR` silently
overwrites the outer loop's own bookkeeping, with **no compile-time error
raised**. A V2 program containing two ordinarily-nested `FOR` loops — a
completely normal BASIC pattern, and one V1 *did* support via its runtime
interpreter's natural stack-like `FOR` handling — will silently compile to
wrong bytecode.

This is not an inherited V1 limitation (V1 did not have this restriction);
it is a genuine architecture gap in V2's current single-scratch-cell
design, requiring a real loop-frame stack (plausibly similar in spirit to
the already-proven `VM_CALL_STACK` mechanism used for PROC) to close
correctly. **No fix has been designed, costed, or implemented.** This is
flagged as the single most significant open capability question for R9
sequencing — see the correction matrix (§17) and the readiness verdict
(§20-24).

## 10. Procedures and functions — PROC/CALL structure

**A — confirmed, matches the preserved DEF FN design's reuse claim
exactly:** `COMPILE_PROC`/`COMPILE_CALL_STMT` use a real compile-once
JMP-skip + `LABEL_DEFINE`-at-the-real-entry (the `STORE_VAR` position, not
PROC's own start, explicitly "never a valid call target") + resolved via
the same `LABEL_LOOKUP`/`FIXUP_RECORD` machinery GOTO/IF already use — not
a separate mechanism. One parameter, by value, deliberately scoped
(explicitly self-labeled as proportionate rather than a hard technical
limit) — this matches DEF FN's own deliberate one-parameter precedent, for
an unrelated but converging reason (V1's own DEF FN also had one parameter,
for interpreter-simplicity reasons that happen to land on the same number).

## 11. Procedures and functions — recursion defect (significant finding)

**D — a real correctness defect, confirmed by direct source reading, in
currently-shipped V2, not merely the deferred DEF FN design.**

PROC's parameter is bound through `CSYM_FIND_OR_CREATE` — the *same shared
global numeric-variable slot* an ordinary scalar uses — not a per-call
frame. Only the **return address** is pushed/popped across a call
(`VM_CALL_PUSH`/`VM_CALL_POP`, a real 6-return-address stack,
`$8794`-`$879F`); the parameter's *value* is never saved or restored.
Concretely: a self-referential function that reads its own parameter
*after* making a recursive call to itself (e.g. `FN F(n) = FN F(n-1) + n`,
a completely ordinary recursive shape) will silently see the inner call's
already-overwritten value of the shared parameter slot by the time the
outer call's `+ n` executes — a wrong answer, no error, no crash.

This directly falsifies a specific claim in the preserved (deferred) DEF FN
design document (`docs/v2/deffn_design/README.md`), which stated real
recursion "works... with zero extra guard code" as a consequence of V2's
call stack — a plausible-sounding claim that was **never actually
hardware-tested** during the original DEF FN experiment (the design doc's
own "Tests developed" section explicitly lists real recursion as not yet
exercised). The claim is now known to be incorrect as stated: the call
stack alone saves the *return address*, not the *parameter value* — those
are different things, and DEF FN reuses PROC's identical parameter-binding
mechanism, so it inherits the identical defect.

**Scope of the defect**: this is a PROC-and-DEF-FN-shared architectural
gap, not DEF-FN-specific. Plain PROC recursion has this defect **today, in
already-shipped code** — it has gone unnoticed because no test in the
current buildable suite exercises PROC recursion with a post-recursive-call
read of the parameter.

**No fix has been implemented.** A plausible minimal correction (save the
parameter's value around a `CALL`/`CALL_UDF` call site, symmetric with the
compile-time nested-name-pointer save/restore the DEF FN design's own
`.udf_call` handler already uses for a different piece of state) has been
sketched in research evidence (from the now-reverted `588e63e`'s update to
`docs/v2/deffn_design/README.md`) but not costed, implemented, or
hardware-validated. See the correction matrix (§17).

**A — DEF FN's specific ROM reservations remain confirmed unclaimed and
unaffected by R9's planned scope**, independent of the recursion defect
above: opcode numbers 52-54 (current `VM_OP_TABLE` max is opcode 51),
token numbers 56-57 (current `TOK_KW_*` max is `TOK_KW_EXIT=55`), error
codes 49-54 (current compiler error table max is 48), and the
`VM_CALL_STACK_TOP`/`FLOOR` addresses are all still free, confirmed by
direct source reading, not by trusting the design doc's own claim. R9's own
planned removal list (`basic/basic.asm`, `exrom_checker.asm`,
`exrom_strfuncs.asm`, `exrom_dim.asm`, `exrom_arrays.asm`) touches none of
`exrom_v2_compiler.asm`/`exrom_v2_vm_core.asm`/`exrom_v2_decompiler.asm`,
where every DEF FN prerequisite lives — no R9 risk to reintegration found.

## 12. PRINT / INPUT / user interaction

`PRINT`/`LPRINT` share one grammar (single argument, string or numeric;
trailing `;` suppresses the newline — a deliberate simplification).
`LPRINT` compiles to the same opcode in both cases; the loadable printer
extension supplies the actual hardware behavior at runtime, matching the
architecture's own stated rule (resident ROM = general-purpose capability,
loadable packages = specialized/peripheral behavior). **Lower-confidence
than the rest of this document**: this specific claim about `LPRINT`'s
runtime dispatch through the printer extension was not independently
re-verified end-to-end against the printer module's real dispatch path in
this pass (the assigned research agent flagged this itself as a residual
gap in its own coverage). Recommend a direct follow-up read of
`rom/test_v2_printer_module.asm`'s actual dispatch before treating LPRINT
as fully confirmed, though nothing found so far contradicts it.

## 13. Graphics / sound / platform commands; PEEK/POKE/USR

**A:** `CLS`/`BORDER`/`INK`/`PAPER`/`PLOT`/`LINE`/`BEEP`/`SOUND`/`POKE`/
`PAUSE`/`RANDOMISE` are confirmed present, opcode-assigned (23-33), and
decompiler-covered. `PEEK`/`USR` are builtin functions, not opcodes.
`SPRITE GRAB/SHOW/HIDE/MOVE`, `MODE`/`ULAPLUS`/`PALETTE`, and printer
`LPRINT`/`LLIST` are confirmed genuinely externalized to loadable
extensions — opcodes 52-54 are explicitly documented as freed by this move
("now a loadable extension package"), and this is exactly the range DEF
FN's design plans to reuse (§11), with no collision.

**D — see §4**: the FLOAT-operand-misinterpretation bug class extends to
`PLOT`/`LINE`/`BEEP`/`SOUND`/`INK`/`PAPER`/`RANDOMISE`/`POKE`, not fixed.

**A — R9 safety confirmed for PEEK/POKE/USR:** `BUILTIN_FN_PEEK`/`USR` and
`OP_POKE` are fully self-contained within `exrom_v2_vm_core.asm` — direct
memory read, a direct `jp (hl)` trampoline, a direct memory write. None of
the three calls into `basic/basic.asm` or any other V1 language-core file
at runtime; comments citing V1's own `.call_peek`/`.call_usr` equivalents
are provenance notes justifying the behavior's correctness, not runtime
dependencies. R9's planned removal list does not touch any of PEEK/POKE/
USR's implementation or dependencies — confirmed safe by direct reading of
both the removal list and the implementation, not by assumption.

## 14. SAVE / LOAD / editor-runtime integration (significant confirmation)

**A — the single most important R9-safety confirmation this audit
performed.** The real end-to-end V2 path was directly traced through
source: `EDITOR_ENTER` → `EDIT_LINE_BUF` (raw null-terminated ASCII text,
produced by the real, unmodified `rom/exrom_editor.asm`, itself confirmed
to have zero interpreter-internals dependency) → `COMPILE_PROGRAM`
(compiles **directly** from `EDIT_LINE_BUF` — no V1 tokenizer or
`MEM_LINE_STORE` conversion step involved at all) → `VM_RUN` →
`DECOMPILE_PROGRAM`. `basic/editor_integration.asm` (2291 lines) was
grep-confirmed to contain **no** reference to `COMPILE_PROGRAM`/`VM_RUN`/
`DECOMPILE_PROGRAM` anywhere — it is pure V1-era editor glue that the real
V2 flow never passes through. **There is no hidden V1 interpreter
dependency in the normal V2 edit/compile/run/decompile workflow.** This
directly answers the audit's own framing question for this area: R9 can
remove V1's interpreter without touching the real V2 path, because that
path never touched V1 to begin with.

## 15. Decompiler completeness

**A:** the decompiler's dispatch table (`exrom_v2_decompiler.asm:1489-1588`)
has a confirmed one-to-one handler for every runtime opcode the compiler
can currently emit (0-51) — checked directly against every `EMIT_OP_*` in
the compiler, not merely against a documentation claim. Opcodes 52-54's
removal (MODE/ULAPLUS/PALETTE externalization) is explicitly commented,
not a silent gap. The previously-found nested-function-argument/type-
ordering scratch-clobber bug class was confirmed fixed at the root (a
generalized per-context scratch-separation pattern), with no open instance
found in this pass.

**D — significant finding, directly relevant to Architecture-B editor
completeness (see §7):** `DIM name(n)` resolves entirely at compile time
into the compiler's own `ARRSYMTAB` and **emits zero bytecode** — only
subsequent array reads/writes emit opcodes (`OP_ARR_LOAD`/`STORE`, 48/49).
Since the decompiler walks bytecode only, there is **structurally nothing
for it to reconstruct a `DIM` statement from** — confirmed by direct grep:
no `"DIM"` string constant and no `.op_dim` handler exists anywhere in
`exrom_v2_decompiler.asm`. **A decompiled/LISTed array-using program
produces array-read/write statements referencing a name that was never
declared in the emitted text; recompiling that output fails** at
`COMPILE_FACTOR.ident`'s array path, which requires a prior `ARRSYM_FIND_
OR_CREATE`d entry. This is a genuine break in the decompile→edit→recompile
loop for any program using arrays — a real Architecture-B editor-
integration completeness gap, not a cosmetic decompiler limitation. A
plausible minimal fix (the decompiler synthesizes a `DIM name(n)` line from
the live `ARRSYMTAB`'s own recorded size at the point bytecode compilation
completes, since the size is already known there) has been identified as
research evidence but not costed or implemented.

## 16. Extension architecture (R7.5)

**A, across the board:** `kernel/extensions/ext_registry.asm` implements a
real compile-time slot-id + runtime rolling-generation-checked registry
(`EXT2_REGISTER`/`EXT2_LOOKUP`, capacity `EXT2_MAX: equ 12`, already
deliberately grown once from an original cap of 8). The compiler bakes both
the resolved slot id and the generation it saw into the bytecode operand;
the VM re-checks the live generation against that baked-in value before
dispatching — this is confirmed to be the actual mechanism, not a
heuristic, and confirmed to contain **zero** V1-style runtime
name-rematching (no string-compare-driven dispatch exists in `OP_CALL_EXT`,
only a slot-index + generation-byte compare). `EXT2_CLEAR_ALL` performs
real unload semantics (zeroing every slot's generation, 0 = empty), not a
no-op. Concurrent loading of all three real packages (sprite, mode,
printer) is real-hardware-validated (`test_v2_ext_concurrent`, one of the
currently-passing regression tests). This fully satisfies the project's own
stated requirement: extension *capability*, not V1 extension-ABI
compatibility.

## 17. Error semantics

**A — no duplicate paths, no obviously-wrong inherited codes found.** Every
`VM_ERR_*` label funnels through a single `VM_ERR_COMMON` exit rather than
duplicating error-reporting logic per site. Compile-time error codes 1-48
are individually documented and in active use; a few numbers (4, 27) are
harmless unused gaps, and code 26 is explicitly documented as retired
(consolidated into 22 during a prior pass) rather than left dangling.
Runtime codes 12-14 (formerly MODE/ULAPLUS/PALETTE) are correctly retired
with no dangling references, freeing them cleanly for their now-externalized
owners. Codes 49-54 are correctly reserved, unused, and confirmed free for
DEF FN (§11).

**D — the only "silently accepts malformed input" case found is the
FLOAT-misinterpretation class already covered in §4** (a missing check,
not an incorrect one) — not a separate new finding, but recorded here per
this section's own framing.

## 18. Resource limits — explicit inventory

| Resource | Limit | Constant | Classification |
|---|---|---|---|
| Numeric scalar variables | 16 | `CSYMTAB_MAX_ENTRIES` (compiler:222) | Deliberate, bounded implementation scope |
| Named string variables | **4** | `STRTAB_MAX_VARS`/`STRSYMTAB_MAX_ENTRIES` | **D — scaffolding limit, not RAM-justified (§5)** |
| String concat temp slots | 2 | `STRTAB_TEMP_COUNT` | Deliberate, documented ("avoid a general allocator") |
| Distinct array names | 4 | `ARRSYMTAB_MAX_ENTRIES` (compiler:440) | Deliberate, matches VM side |
| Elements per array | 16 | `ARRAY_MAX_ELEMS` (vm_core:283) | Deliberate |
| Labels | 8 | `LABELTAB_MAX_ENTRIES` (compiler:228) | Deliberate, bounded scope; could constrain larger programs |
| Outstanding forward-ref fixups | 8 | `FIXUPTAB_MAX_ENTRIES` (compiler:233) | Same class as labels |
| `EXIT FOR` per loop | 4 | `EXITFOR_MAX` (compiler:433) | Moot pending §9's nesting fix; cheap to raise |
| Extension registry slots | 12 | `EXT2_MAX` (ext_registry.asm:85) | Deliberate, already grown once from 8 |
| VM call stack | 6 return addresses, 12 bytes ($8794-$879F) | `VM_CALL_STACK_TOP/FLOOR` | Deliberate, small, bounds-checked; caps PROC/CALL nesting at 6 — undocumented as an explicit product policy |
| VM operand stack | ~124 bytes ($8704-$877F) | `VM_STACK_TOP/FLOOR` | Hardware/RAM-budgeted, bounds-checked |
| Identifier name length | 8 chars | (compiler.asm:97,1065) | V2-native, cheap-to-raise, compile-time-only cost |
| String scalar content length | 31 chars | (`[len:1][content:31]`) | Deliberate, documented as a future-widening candidate |
| ROM (product ceiling) | 24,576 bytes | — | Hardware-constrained hard ceiling |
| ROM free reserve (current, restored) | 282 bytes | — | Consequence of the ceiling, not itself a limit |

None of these are test-harness-only limits masquerading as product limits
— every constant lives in shipped `exrom_v2_*.asm`/`ext_registry.asm`
source, distinct from the flat-16K *test-harness image* packaging ceiling
(§2), which is a build-time constraint on standalone test binaries only.

## 19. Test-harness status

See §2 for the full breakdown (buildable/passing 14/14; 7 excluded by
harness capacity only; 6 stale via a confirmed missing-include root cause;
zero product regressions found). Not repeated here to avoid duplication.

## 20. Known defects vs. optional enhancements

**Real defects found this session, none fixed:**

1. FLOAT-operand misinterpretation across numeric builtins and statements
   (§4, §13).
2. FOR/NEXT has no nesting support; `NEXT` doesn't verify its variable
   matches the innermost `FOR` (§9).
3. `DIM` has no decompiler representation; array programs cannot survive
   decompile→recompile (§14, §7).
4. PROC's (and inherited-by-design, DEF FN's) recursion is not
   parameter-safe (§11).
5. `VAL()` cannot parse decimals; `OP_DIV`'s zero-check misses a
   FLOAT-tagged zero divisor; all relational/equality operators reject any
   FLOAT operand outright (§4) — smaller, individually documented gaps.

**Optional enhancements (E — recorded, not required for R9):**

- Enlarging `STRTAB_MAX_VARS` from 4 toward 16 (§5, §18) — cheap in RAM,
  no known program currently needs it.
- Confirming decompiler name-reconstruction fidelity for scalars/arrays
  (§6) — plausible but not independently confirmed.
- `SGN`'s documented int-only scope vs. `ABS`'s float support — a minor,
  documented inconsistency, low severity.
- `OP_MUL` auto-promotion-on-overflow — deliberately deferred, documented,
  not a silent gap (§4).

## 21. DEF FN post-R9 dependency notes

DEF FN's specific ROM reservations (opcodes 52-54, tokens 56-57, error
codes 49-54, `VM_CALL_STACK_TOP`/`FLOOR` addresses) are confirmed still
free and are not touched by R9's planned removal scope (§11). The
*recursion-safety defect* found in §11 is a **new prerequisite** for DEF
FN reintegration that did not exist as a known issue before this audit —
it must be resolved (in PROC, since DEF FN reuses PROC's exact mechanism)
before or during DEF FN reintegration, not merely documented as a
limitation, since it produces silent wrong answers rather than a refused
operation.

## 22. Explicit R9 prerequisites

None of this audit's findings are hard R9 blockers in the sense of "R9
cannot begin" — every defect found is pre-existing in V2's own code,
independent of whether V1's interpreter still exists, and R9 (V1
language-core removal) does not touch any of the affected files. However,
the following require **explicit product decisions** before they are
resolved one way or another (fix pre-R9, fix immediately post-R9, fix at
DEF FN reintegration, or defer to R10) — see the correction matrix (§17
below, renumbered as needed) for the cost/timing tradeoffs:

1. FLOAT-operand misinterpretation (§4/§13) — full bug class, not just the
   subset one reverted commit happened to fix first.
2. FOR/NEXT nesting (§9) — genuinely uncertain whether this should gate R9
   or can safely follow it; costed further below.
3. `DIM`/decompiler round-trip (§14) — likely a required Architecture-B
   editor-completeness item, timing open.
4. PROC/DEF FN recursion-parameter safety (§11) — required before DEF FN
   reintegration at the latest; whether plain PROC needs the same fix
   sooner is an open product question.

## 23. Explicit R9 preservation list

Preserve, do not casually alter during R9: the extension registry mechanism
and its generation-checking (§16); the flat fixed-size `STRTAB`/`ARRTAB`/
`FLOATTAB` layout (§5/§7); the compile-once JMP-skip + `LABEL_DEFINE`
PROC/CALL shape (§10), since DEF FN's entire design depends on it remaining
exactly as-is; the zero-V1-dependency editor/compiler/VM/decompiler path
(§14) — the single most important thing R9 must not accidentally break.
R9's own execution should re-verify this specific claim once the actual
deletion diff exists, not just trust this audit's snapshot.

## 24. Explicit R9 removal candidates

Per `ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s own R9 section (re-read this
session, unchanged): `basic/basic.asm`'s direct-execute interpreter,
`rom/exrom_checker.asm`, `rom/exrom_strfuncs.asm` (whatever isn't already
independently reused by V2's own R5 string-function rewrite, confirmed
independent in §5), `rom/exrom_dim.asm`, `rom/exrom_arrays.asm` — the full
V1 language core. This audit found no reason to expand or contract that
list, and confirmed (§13, §14) that none of it is a hidden dependency of
V2's own PEEK/POKE/USR or editor/compiler/VM/decompiler path.

## 25. Prioritized correction matrix

All items below are **proposed corrections**, not approved decisions.
Costs are estimates from research evidence (including the reverted
`588e63e`, used strictly as implementation reference) where available, and
marked as unestimated otherwise.

| # | Finding | Severity | Class | Silent wrong answer? | V1 capability lost? | Breaks round-trip? | Blocks R9? | Est. ROM | Est. RAM/bytecode | Existing impl. evidence | Tests needed | Recommended timing |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | FLOAT misread in `INT`/`SGN`/`MOD`/`DIV`/`RND`/`PEEK`/`USR`/`POINT`/`ATTR`/`SQR`/`RAD`/`DEG` | High | B | **Yes** | No | No | No | ~188 bytes (measured in `588e63e`) | None (stack-only) | `588e63e` (reverted, code-reviewed, non-regression-tested; new behavior not hardware-tested) | Dedicated `test_v2_numeric_hybrid.asm` on real ZEsarUX | Pre-R9 if the 282-byte reserve allows, else immediately post-R9 |
| 2 | Identical bug in `PLOT`/`LINE`/`BEEP`/`SOUND`/`INK`/`PAPER`/`RANDOMISE`/`POKE` | High | B | **Yes** | No | No | No | Unestimated (not implemented; likely tens of bytes each, ~8 sites) | None | None — found, not implemented anywhere | Same test file, extended | Same decision as #1 — should be made together, not piecemeal, since fixing only the functions and not the statements leaves the bug class half-closed |
| 3 | FOR/NEXT no nesting support; `NEXT` doesn't check variable matches innermost `FOR` | High | D | No (wrong bytecode, not wrong-but-plausible) | **Yes** — V1 supported nested FOR | No | **Open question — see §9/§22** | Unestimated — requires a real loop-frame stack, plausibly `VM_CALL_STACK`-like | Unestimated | None | Nested-FOR compile + runtime test, malformed-nesting error test | **Needs explicit product decision**: pre-R9 (if judged a required capability parity item) or immediately post-R9 (if V1 removal timing is judged safe to precede the fix, since no current V2 program is known to rely on nesting) |
| 4 | `DIM` emits no bytecode; decompiler cannot reconstruct it; array-program round trip breaks | Medium-High | D | No (fails loudly at recompile) | No (new capability gap introduced by V2's own architecture, not lost from V1) | **Yes** | Likely, for Architecture-B editor completeness | Unestimated — plausibly small (synthesize `DIM` from live `ARRSYMTAB` size at compile-end) | Unestimated | None | Decompile→edit→recompile round-trip test for an array program | Pre-R9 or immediately post-R9 — recommend resolving before declaring the editor/decompiler integration complete, timing flexible |
| 5 | PROC/DEF-FN parameter binding not recursion-safe (shared global slot) | Medium-High | D | **Yes** | Uncertain — V1's own DEF FN also disallowed recursion by design, but PROC recursion was never a V1 concept to compare against | No | No (PROC ships without recursion tests today) | Unestimated (sketch: save/restore around `CALL`/`CALL_UDF`) | Unestimated | Sketch only, in reverted `588e63e`'s doc update — not implemented or measured | Recursive-PROC and recursive-DEF-FN hardware tests | **Required before DEF FN reintegration** at the latest (§21); whether plain PROC needs it sooner is an open product question — recommend deciding at the same time as DEF FN reintegration planning |
| 6 | `VAL()` no decimal-point support | Medium | D | Yes (mis-parses, doesn't error) | Possibly — depends on whether V1's VAL supported decimals (not verified) | No | No | Unestimated | None | None | VAL-with-decimal test | Post-R9 or R10 — not urgent, no evidence of current programs needing it |
| 7 | `OP_DIV` zero-check misses FLOAT-tagged zero divisor | Low-Medium | D | Yes (likely garbage float result, not a crash) | No | No | No | Unestimated, likely tiny (one more tag check) | None | None | Div-by-float-zero test | Post-R9 or R10 |
| 8 | Relational/equality operators reject any FLOAT operand | Medium | D | No (raises a real, distinct error) | Uncertain — V1 had no floats to compare | No | No | Unestimated — a real scope addition (float comparison), not a one-line fix | Unestimated | None | Float comparison tests across all 6 operators | Post-R9 — a real feature addition, not urgent for R9 itself |
| 9 | `STRTAB_MAX_VARS` capped at 4 | Low | D (resource limit) | No | Possibly — V1's own string handling was not limited to 4 names | No | No | 0 (RAM only) | ~384 bytes RAM (est., raising to 16 to match `CSYMTAB`) | None | Many-string-variable test | R10 or whenever convenient — cheap, not urgent |
| 10 | `SGN` documented int-only, no float support | Low | E | No (documented, not silent) | No | No | No | Unestimated, small | None | None | Float-SGN test if implemented | Optional, not required |
| 11 | `OP_MUL` overflow silently truncates rather than auto-promoting | Low | C/E | Debatable — matches existing primitive's documented behavior, not a new gap | No | No | No | N/A — deliberately deferred, not a defect | N/A | None | N/A | Deliberately out of scope, revisit only if a real program needs it |

## 26. Final R9 readiness verdict

**SUPERSEDED — see §0. This section is retained verbatim for the historical
record of what the original audit pass concluded; it is not the current
status.** The current status is **NOT READY FOR R9 — R8.9 (V2 Production
Integration) is a hard prerequisite**, per §0's correction.

**Original verdict (superseded): READY FOR R9 WITH SPECIFIC PRECONDITIONS.**

Nothing found in this audit is caused by V1's continued presence, and R9
(removing `basic/basic.asm`, `exrom_checker.asm`, `exrom_strfuncs.asm`,
`exrom_dim.asm`, `exrom_arrays.asm`) does not touch any file where any
finding above lives. The editor→compiler→VM→decompiler path has zero
hidden V1 dependency (§14), and DEF FN's reserved ROM resources are
confirmed unclaimed (§11, §21) — R9 itself can proceed without being
blocked by anything in this document.

The preconditions are about **not silently carrying known, evidence-based
correctness gaps across the R9 boundary** rather than about R9's own
mechanics:

1. Decide the FLOAT-operand-misinterpretation question (matrix rows 1-2)
   as a single, complete decision — fix the whole bug class together
   (functions and statements), not piecemeal, and decide whether that
   happens inside the current 282-byte pre-R9 reserve or immediately after
   R9 frees more room. Recommend deferring to immediately post-R9 given
   the current reserve is thin and the fix touches ~20 call sites.
2. Decide the FOR/NEXT nesting question (matrix row 3) explicitly — this is
   a real capability V1 had that V2 currently lacks, and the decision of
   whether that gates R9 or can safely follow it is a genuine product
   call, not one this audit should make unilaterally.
3. Decide the `DIM`/decompiler round-trip question (matrix row 4) — likely
   resolvable cheaply, timing flexible.
4. Decide the PROC/DEF-FN recursion-safety question (matrix row 5) — hard
   requirement before DEF FN reintegration; optional-but-recommended for
   plain PROC sooner.

None of the four block *starting* R9's own work (the statement-set coverage
audit and V1-regression-suite oracle comparison per
`ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s own R9 section). Recommended
concrete starting point: begin R9's own removal-and-coverage work with this
document's §18 resource-limit table and §23 preservation list in hand, and
resolve preconditions 1-4 above on whatever timetable the product decisions
dictate — before, during, or immediately after R9's own file removal, at
the user's discretion, since none of them are R9 mechanics blockers.

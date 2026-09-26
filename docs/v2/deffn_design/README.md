# DEF FN — deferred design and implementation (R8.5 → post-R9)

**Status: DEFERRED, NOT CANCELLED.** DEF FN is a required V2 language
feature. A complete, real-implementation, real-measured design exists and is
preserved here as a git patch (`deffn_experiment_full.patch`), plus this
document. It does not fit in the current pre-R9 ROM (see "Why deferred"
below) and was deliberately backed out of the working tree rather than
forced in. **Do not rediscover this design from scratch** — apply the patch,
reconcile it with whatever R9 changed, and validate.

## Baseline this was designed and measured against

- Commit: `b46d34b` (R8.5 Group 6 complete: SIN, real-hardware-validated)
- Pre-DEF-FN ROM baseline (precise `ACTUAL_END_MARKER` measurement,
  scratch-image technique against `rom/test_v2_group6_math.asm` enlarged to
  a $4100 target): end address `0x3DF9` = 15,865 bytes of V2-own code.
- Total product ROM accounting at that baseline: 24,294 / 24,576 bytes used,
  **282 bytes free**.

## How to reapply

```
git apply docs/v2/deffn_design/deffn_experiment_full.patch
```

This patch was captured against `b46d34b` and applies cleanly on top of it
(verified with `git apply --check` at the time this doc was written). If R9
has since changed `rom/exrom_v2_compiler.asm`, `rom/exrom_v2_vm_core.asm`,
or `rom/exrom_v2_decompiler.asm` enough that the patch no longer applies
cleanly, reconcile it by hand using this document as the design reference —
the *shape* of the design (below) should still be directly transferable even
if exact line numbers have moved or V1-era scaffolding referenced nearby has
been removed by R9.

**Important**: the patch includes two general-purpose compiler
consolidations (`COMPILE_CALLABLE_PREFIX`, `COMPILE_RESOLVE_OR_FIXUP`) that
were extracted *because* DEF FN gave PROC/CALL's existing near-duplicate
logic a second caller each. Measured directly: with only one caller each
(i.e. DEF FN absent), these two consolidations cost **15 bytes more** than
leaving PROC/CALL's original inline code alone — a shared routine with one
caller is pure overhead. They were reverted from the clean pre-R9 baseline
for exactly this reason. They should be reapplied **together with** DEF FN,
not standalone.

## Why deferred

Measured (precise end-of-code marker technique) total ROM cost of the full
DEF FN implementation (compiler + vm_core + decompiler, *after* the above
consolidation): **489 bytes**, against a **282-byte** free reserve at the
`b46d34b` baseline — a **207-byte shortfall**. Closing that gap would
require restructuring shared subsystems (unifying PROC's statement-list body
path with DEF FN's expression-body path, or reworking the error-code/table
representation) — real R10-shrink-class work, explicitly out of scope before
R9. Rather than force a bad fit or start shrink-z80 early, DEF FN is deferred
to immediately after R9, when V1 removal is expected to free substantially
more than 207 bytes.

Component breakdown of the 489 bytes (approximate, post-consolidation):
compiler ≈ 420B (COMPILE_DEF_FN + `.udf_call` + keyword/error-code
plumbing), vm_core ≈ 6B (3 opcode-table aliases), decompiler ≈ 63B (3
handlers + `DECOMP_COMBINE_UINT16` + 4 string constants).

## Design

### Source syntax

```
DEF FN name(param) = expr      ; definition
FN name(arg)                   ; call, usable inside any expression
```

Single letter or multi-character identifier names (same rules as any V2
identifier — this is a genuine, deliberate improvement over V1, see
"V1 restrictions not preserved" below). Exactly one parameter, matching
`PROC`'s own already-established single-parameter scope decision.

### Design principle applied

**Preserve capability and intended language semantics, not V1 mechanism.**
V1's DEF FN (`basic.asm` → `BASIC_PARSE_DEF_FN_SHARED`,
`rom/exrom_checker.asm:1424`) uses a single global scalar slot
(`DEF_FN_NAME`/`PARAM`/`EXPR_PTR`/`ARG`/`ACTIVE`, `include/sysvars.inc`
$F3A8-$F3AE) — only ONE DEF FN can exist in an entire program at once, and
recursion is explicitly disabled via a `DEF_FN_ACTIVE` guard (V1's own
comment: "recursive FN calls are not [supported]"). Both restrictions are
real V1 INTERPRETER-architecture artifacts (a single slot re-parsed from
source text on every call), not real classic-BASIC language restrictions.
V2's compile-once bytecode model and genuine multi-level call stack
(`VM_CALL_PUSH`/`VM_CALL_POP`, `rom/exrom_v2_vm_core.asm`) support multiple
distinct named functions and real recursion "for free," simply by *not*
adding the guard V1 needed. This design does not replicate V1's limitations.

The one V1 restriction kept deliberately: single parameter per function —
this matches `COMPILE_PROC`'s own established single-parameter precedent
(not a technical limit, a proportionate minimal-footprint scope decision)
and V1's own real "one numeric parameter" scope.

### Compile-time representation / reuse

DEF FN reuses V2's existing PROC/CALL machinery almost entirely — the
compile-once JMP-skip + LABEL_DEFINE-at-the-real-entry-position +
STORE_VAR-binds-the-parameter shape `COMPILE_PROC`/`COMPILE_CALL_STMT`
already established, resolved via the same `LABEL_LOOKUP`/`FIXUP_RECORD`
forward-reference machinery GOTO/CALL already use (not a new resolution
mechanism). No new compiler scratch cells: reuses
`PROC_SKIP_PATCH_TMP`, `PROC_PARAM_INDEX_TMP`, `STMT_IDENT_NAME_PTR`,
`STMT_IDENT_NAME_LEN`, `BRANCH_PATCH_TMP`, `LABEL_LOOKUP_RESULT` verbatim.

Two new compiler keywords: `TOK_KW_DEF` (56), `TOK_KW_FN` (57) — reusing
token numbers vacated by the MODE/ULAPLUS/PALETTE-to-loadable-module move.

### Bytecode representation

Three new opcode *numbers* (52=JMP_DEFFN, 53=CALL_UDF, 54=RET_DEFFN) that
are runtime-IDENTICAL to JMP/CALL/RET (literally the same `VM_OP_TABLE`
handler at those slots — zero new runtime logic) — purely a compile-
time/decompile-time disambiguation mechanism, following the exact
precedent already established by `OP_JMP_ELSE` (opcode 47, see that
routine's own header in `rom/exrom_v2_compiler.asm`): "runtime-identical to
JMP...but a DISTINCT opcode number so the decompiler can tell it apart... no
heuristic byte-pattern guessing needed." Reuses the opcode-number range
52-54 vacated by the earlier MODE/ULAPLUS/PALETTE removal.

### Argument binding / evaluation / return value handling

`DEF FN name(param) = expr` compiles as:
```
JMP_DEFFN <skip>        ; sequential fall-through skips the body
<label: name>           ; defined HERE, at the STORE_VAR position —
STORE_VAR param         ;   the real call-entry point, matching PROC
<body: expr>             ; result left on the VM operand stack on purpose
RET_DEFFN
<skip>:
```
`FN name(arg)` (as an expression factor) compiles as:
```
<arg expr>               ; pushed onto the operand stack
CALL_UDF <name's address> ; resolved via LABEL_LOOKUP/FIXUP_RECORD
```
The calling convention needs zero new runtime logic: V2's real
`VM_CALL_PUSH`/`VM_CALL_POP` (`VM_CALL_STACK_TOP=$87A0`/`FLOOR=$8794`, 6
slots) already leaves a function's own computed result on the operand stack
across `RET` — exactly what a value-returning function needs, "for free."

### INT/FLOAT behavior

The function body is compiled via the ordinary `COMPILE_EXPR` path — full
hybrid INT/FLOAT typing exactly as any other V2 expression, no special
casing. The argument likewise flows through the normal `STORE_VAR`
path.

### Nesting / reentrancy

`FN` calls compile via a new `.udf_call` factor handler inside
`COMPILE_FACTOR`. Because compiling the argument expression
(`COMPILE_EXPR`) can itself recursively compile a *nested* `FN othername(...)`
call using the SAME shared `STMT_IDENT_NAME_PTR`/`LEN` scratch cells, the
handler proactively parks the outer call's name pointer+length on the
hardware stack (`push hl` / `push bc`) before the recursive `COMPILE_EXPR`
call, restoring them afterward — applying, *before* any bug manifested, the
same nested-call scratch-clobber lesson Group 6's `CFN_INDEX`/`ARGCOUNT`/
`REMAINING`/`ARGTYPE` fix taught this project the hard way (see
`docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s own bug log). At runtime,
real recursion (a function calling itself) works with zero extra guard code,
because V2's call stack is genuinely multi-level.

### Decompilation

Three new decompiler handlers (`.op_jmp_deffn`, `.op_call_udf`,
`.op_ret_deffn`) render `DEF FN Pn(Vp) = <expr>` and `FN Pn(<arg>)`. A new
`DECOMP_COMBINE_UINT16` helper (mirrors the existing
`DECOMP_EMIT_UINT16`/`DECOMP_COMBINE_DIGITS` EMIT-vs-COMBINE convention)
renders the numeric label part into a composable fragment, needed because
`FN`'s call site — unlike `CALL`'s own statement-level rendering — must
produce a fragment usable inside a larger expression.

### Error handling

New error codes 49 ("expected FN after DEF"), 50 ("expected a function
name" — shared between definition and call-site contexts), 51 ("expected
'(' after a name"), 52 ("expected a parameter name"), 53 ("expected ')'"),
54 ("expected '=' before body"). In the clean pre-R9 baseline these code
numbers are unused/reserved (documented in `rom/exrom_v2_compiler.asm`'s own
error-code table) and will be reclaimed on reintegration.

### RAM / workspace impact

None beyond what PROC/CALL already reserve — no new compiler scratch cells,
no new VM sysvars. DEF FN is, by design, free on the RAM side.

## Tests developed during the experiment

The experiment's own scratch-build validation exercised (informally, not
yet captured as a committed `test_v2_deffn.asm` test file — that should be
written fresh at reintegration time against R9's post-removal state):
simple single-argument function definition and call; repeated calls;
expression arguments; a function call used inside a larger expression;
negative argument values; float/int argument interaction; multiple distinct
defined functions (proving V2 does NOT inherit V1's single-slot limit);
nested-call scratch-clobber stress (the proactive stack-parking fix above);
decompile-recompile round trip for the `DEF FN`/`FN` rendering.
**Not yet exercised**: real recursion (a function calling itself) end to
end on real hardware — the design supports it "for free" via the call
stack, but this specific case was not separately hardware-validated during
the experiment and should be added to the reintegration test list.

## Bugs / issues discovered during the experiment

None in the DEF FN logic itself. One naming collision caught by inspection
before building: the new `.udf_call` factor-handler label collided with the
pre-existing internal label `.fn_call` used by `COMPILE_FACTOR.ident`'s
BUILTIN function dispatch chain — resolved by naming the new handler
`.udf_call` throughout.

## Exact new components (for quick recovery reference)

- `rom/exrom_v2_compiler.asm`: `TOK_KW_DEF`/`TOK_KW_FN`; two `KEYWORD_TABLE`
  rows; error codes 49-54; `EMIT_OP_CALL_UDF`/`EMIT_OP_RET_DEFFN` (and the
  JMP-skip opcode emitted directly by `COMPILE_CALLABLE_PREFIX`);
  `COMPILE_DEF_FN`; the `.udf_call` factor handler; dispatch hooks in
  `COMPILE_STATEMENT_LIST` and `COMPILE_FACTOR`; the
  `COMPILE_CALLABLE_PREFIX`/`COMPILE_RESOLVE_OR_FIXUP` shared helpers (see
  the "important" note above about their one-caller-cost).
- `rom/exrom_v2_vm_core.asm`: three `VM_OP_TABLE` entries (52-54) aliasing
  `OP_JMP`/`OP_CALL`/`OP_RET`; `cp 52` → `cp 55` bound-check bump.
- `rom/exrom_v2_decompiler.asm`: dispatch entries for opcodes 52-54; width-
  table entries; three new handlers; `DECOMP_COMBINE_UINT16`; four new
  `STR_*` constants.

## Known design defect found during the V2 semantic/capability audit (pre-R9)

**Real self-referential recursion is not actually correct as designed,
despite this document's earlier claim that it "works... for free."**

The parameter is bound via the same shared, single global `CSYMTAB` slot
`COMPILE_PROC` already uses (`CSYM_FIND_OR_CREATE`) — a plain numeric
variable, not a per-call stack slot. Only the return address is pushed/
popped across a call (`VM_CALL_PUSH`/`VM_CALL_POP`); the parameter's
*value* is not saved/restored. So a genuinely recursive `FN` body that
reads its own parameter **after** making a recursive self-call — e.g.
`DEF FN F(n) = FN F(n-1) + n` — will silently see the inner call's
already-overwritten value of `n`, not the outer call's own, producing a
wrong result with no error. This was never hardware-tested during the
original experiment (see "Tests developed" above, which explicitly flags
real recursion as untested) — it was a plausible-sounding but unverified
claim, not a confirmed one.

**Decision (explicit product decision, 2026-09-26 semantic audit
session): fix this before reintegration**, not ship with it as a
documented limitation. The fix: park the parameter's value on the stack
(hardware stack or a small dedicated save area) around a `CALL_UDF` call
site, symmetrically with how `.udf_call`'s existing nested-call fix
already parks `STMT_IDENT_NAME_PTR`/`LEN` across a recursive
`COMPILE_EXPR` call at *compile* time — this is the same lesson applied
to the *runtime* parameter binding instead. Concretely: emit a save of
the parameter's current value immediately before the argument-evaluation
`CALL_UDF` sequence and a restore immediately after it returns, OR give
each call frame its own parameter slot on `VM_CALL_STACK` itself (more
invasive, more correct, more expensive) — evaluate both against real
ROM cost during reintegration; the save/restore-around-the-call-site
approach is the minimal one and should be tried first.

## Reintegration checklist (do this after R9)

1. Re-measure the ROM baseline precisely (`ACTUAL_END_MARKER` technique).
2. Apply `deffn_experiment_full.patch` (or reconcile by hand against R9's
   changes using this document).
3. **Fix the recursion defect above** (save/restore the parameter's value
   around a `CALL_UDF` site) before considering DEF FN complete — this is
   a required correctness fix, not optional polish.
4. Write/extend a proper `test_v2_deffn.asm` regression test covering the
   full list under "Tests developed" above, plus real recursion end to
   end (specifically: a recursive function that reads its own parameter
   *after* the recursive call, e.g. a naive factorial or Fibonacci —
   the exact shape the defect above breaks).
5. Test malformed definitions/calls and error paths (49-54) explicitly.
6. Run the complete buildable regression suite via real ZEsarUX, guarding
   against stale binaries/emulator processes.
7. Measure the exact ROM delta and final free space.
8. Commit DEF FN separately from any R9 changes.

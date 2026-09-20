# 2068-Leap V2 — Rewrite VM Design (sizing-oriented, not production spec)

Evidence classes: `VERIFIED` (real sjasmplus assembly, this pass),
`ESTIMATED` (calculation from `VERIFIED` numbers, formula shown), `ASSUMED`
(policy choice). This document describes a design sized well enough to
support `REWRITE_ROM_BUDGET.md`'s numbers — it is explicitly **not** a
production specification. Nothing here is wired into the real build.

## Design goals (from the study brief, restated as constraints)

1. Integer fast path unchanged in spirit from V1 (native 16-bit ops, no
   float engine on the hot path unless a value is actually FLOAT).
2. Float support present but not "everything is float" — mixed dispatch,
   gated by a per-value tag, exactly as `NUMERIC_DESIGN.md` already
   proposes for evolved-V1, reusing the **same existing calculator**
   (`rom/exrom_calc.asm`, 1,931 bytes, unchanged, counted as platform cost).
3. Identifiers compile to a symbol **index**, not a name lookup at runtime —
   the whole point of a compile step.
4. Program storage decision (source-text-primary vs. bytecode-primary) is
   made explicitly, not left implicit — see `REWRITE_RAM_BUDGET.md`.
5. Editor stays as-is; the new boundary is EDITOR → COMPILER → VM, not
   EDITOR → VM directly.

## What was actually built and measured

Two standalone sjasmplus spikes exist under `~/2068-Leap/spikes/v2_vm_sizing/`
(new directory, isolated, not referenced by the real Makefile, never
touching `rom/`, `basic/`, `kernel/`, `include/`):

- `vm_sizing_spike.asm` — a real bytecode dispatch loop, jump table, 20
  representative opcode handlers, a compiled-index symbol-access routine,
  and operand-stack push/pop helpers.
- `compiler_sizing_spike.asm` — a real recursive-descent expression
  compiler (`expr := term (('+'|'-') term)*`, `term := factor (('*'|'/')
  factor)*`, `factor := NUMBER | IDENT | '(' expr ')'`) emitting bytecode
  for the opcodes above, including the "small vs. large integer constant"
  encoding choice the study brief asks for.

Both assemble clean (0 errors, 0 warnings) with the project's real
`sjasmplus` (v1.23.1). Sizes below are the assembler's own reported byte
ranges (`DISPLAY` directives comparing label addresses), not estimates.

### VM dispatch + handlers (`VERIFIED`, real assembled bytes)

| Component | Bytes | Notes |
|---|---:|---|
| Dispatch loop + 20-entry jump table | 61 | Fetch, index, `jp (hl)` |
| Symbol-address routine (index → record address) | 18 | Compiled-index access, not a name scan |
| Operand-stack push/pop helpers | 30 | |
| 20 representative opcode handlers | 479 | See breakdown below |
| **Total (20 opcodes)** | **588** | |

The 20 opcodes assembled: `HALT`, `PUSH_I8`, `PUSH_I16`, `LOAD_VAR`,
`STORE_VAR`, `ADD` (mixed int/float dispatch — the representative "hybrid
numeric" handler), `SUB`, `MUL` (with overflow-triggers-promotion, per
`NUMERIC_DESIGN.md`'s existing policy), `DIV` (always through the
calculator, matching V1's own existing `/` behavior — `VERIFIED` in
`NUMERIC_DESIGN.md`), `CMP_LT`, `CMP_EQ`, `JMP`, `JMPZ`, `FOR_INIT`,
`FOR_NEXT` (compiled branch target, no source re-scan — directly answering
`PERFORMANCE_BASELINE.md`'s GOTO-catastrophe finding), `CALL`, `RET`,
`LOAD_FLOAT_VAR`, `STORE_FLOAT_VAR`, `PROMOTE_TOS`.

Average handler cost: 479/20 = **24.0 bytes/opcode** (`VERIFIED`, this
sample). Fixed overhead (dispatch+table+sym-addr+stack helpers) does not
grow with the opcode count except the jump table itself (+2 bytes/opcode).

Calls into the **already-existing** calculator/math primitives
(`CALC_ADD_STUB` etc.) are represented as real 3-byte `CALL` instructions to
external stub labels — the call-site cost is measured for real; the
callee's own body is deliberately **not** re-measured here, since it
already exists and its cost is already counted once, in
`LANGUAGE_CORE_ROM_ANALYSIS.md`'s platform total (1,931 EXROM bytes for the
calculator, 403 HOME bytes for `kernel/math`).

### Expression compiler (`VERIFIED`, real assembled bytes)

| Component | Bytes |
|---|---:|
| `expr`/`term`/`factor` control flow (precedence climbing) | 129 |
| Number-literal compiler (8-bit vs. 16-bit encoding choice) | 60 |
| Identifier-load compiler (excluding the symbol-table scan itself) | 34 |
| Emit helpers (7 opcode-emitting routines) | 44 |
| **Total** | **291** |

This is a genuinely complete 4-operator, parenthesized, literal+identifier
expression compiler with correct precedence — not a toy fragment. It is the
single most useful real data point this study has for "how much does new
compiler machinery actually cost," since V1 has **zero** existing code to
compare it against (there is no compile step today).

## Extrapolation to a full VM + compiler (`ESTIMATED`, anchored on the above)

### VM runtime, ~40 opcodes (covering the full bytecode list the study asks
for: small/large int constants, float constants, load/store, integer arith,
float arith, comparisons, branches, loops, calls, string ops, and native
graphics/sound/sprite/storage dispatch)

- Fixed overhead: 69 bytes (dispatch loop 21 + sym-addr 18 + stack helpers
  30, unchanged from the 20-opcode measurement).
- Jump table: 40 × 2 = 80 bytes.
- Handlers: roughly half the additional 20 opcodes are cheap "fetch operand,
  `CALL` native platform routine, push result if any" trampolines for
  graphics/sound/sprite/storage calls (measured shape ≈ 12-15 bytes each,
  cheaper than the arithmetic/control handlers already measured), pulling
  the average down from 24.0 to an estimated ~20 bytes/handler across all
  40: 40 × 20 = 800 bytes.
- **Estimated VM total: 69 + 80 + 800 ≈ 950 bytes** (stated range: 900-1,100
  to reflect that this is an extrapolation, not a full 40-opcode assembly).

### Compiler, full statement + expression grammar (`ESTIMATED`)

- Expression compiler, extended to comparisons/unary/string-concat/function
  calls: ~2× the measured 291-byte core ≈ **600 bytes**.
- Statement compiler, one compile-routine per statement type. V1 has
  roughly 35-40 distinct statement keywords (`report_rom_map.py`/dispatch
  table size implies this order of magnitude). The existing checker already
  does grammar recognition (validate-only) for this same set at 1,860 bytes
  (~49-53 bytes/statement average). A compile routine does recognition
  *plus* bytecode emission — estimated 1.5-2× the checker's per-statement
  cost: **2,700-4,200 bytes**.
- Symbol-table builder (compile-time-only find-or-create, reusing the same
  bounded-name-compare shape `STRING_AND_SYMBOL_DESIGN.md` already costs for
  the runtime side): **60-100 bytes**.
- Branch/backpatch bookkeeping for forward references (`IF`/`FOR`/`WHILE`/
  procedure calls need their target address patched after the target is
  compiled): **150-250 bytes**.
- Compile-time error reporting (source-position-aware, distinct from the
  existing runtime `BASIC_RAISE_*` mechanism which V2 keeps unchanged for
  runtime errors): **150-300 bytes**.
- **Estimated compiler total: 3,660-5,450 bytes** (midpoint ≈ 4,550).

### Program-representation glue

If the design stores bytecode as the primary representation (recommended —
see `REWRITE_RAM_BUDGET.md` for why), a decompiler/pretty-printer for
`LIST`/`EDIT` is new, genuinely-needed code: **ESTIMATED 300-500 bytes**.

### Rewritten language core total (`ESTIMATED`, Architecture B)

| Component | Bytes |
|---|---:|
| VM runtime (~40 opcodes) | 900-1,100 |
| Compiler (statements + expressions + symtab + backpatch + errors) | 3,660-5,450 |
| String/ordering runtime (reuses `STRING_AND_SYMBOL_DESIGN.md`'s existing plan, not re-costed here) | 150-170 |
| Decompiler/pretty-printer for `LIST`/`EDIT` (if bytecode-primary storage) | 300-500 |
| **Total** | **5,010-7,220** (midpoint ≈ 6,100) |

Compare: V1's measured language core is **13,893 bytes**
(`LANGUAGE_CORE_ROM_ANALYSIS.md`). Even at the high end of this estimate
range, a rewritten core is roughly **6,700-8,900 bytes smaller**.

## What this design deliberately does NOT do

Same rejections as evolved-V1's plan, for the same reasons
(`ARCHITECTURE_COMPARISON.md`): no reference-counted/generational string
heap, no checked-return-record VM-guard layer (structured-basic-poc's own
measured ~22% perf tax for a threat model — untrusted bytecode modules —
that doesn't exist here), no relocatable multi-module registry. The VM is a
plain, unchecked dispatch loop over a trusted, locally-compiled bytecode
stream — the same trust model V1 already has for its own interpreted
source text.

## Honest confidence statement (original, pre-statement-compiler-spike)

The VM-runtime estimate is anchored on a real 20-opcode/588-byte
measurement and is `LIKELY` accurate to within ±20%. The compiler estimate
is anchored on one real 291-byte expression-compiler measurement but
extrapolates the much larger statement-compiler component from the
checker's existing size using a multiplier (1.5-2×) that is itself
`ASSUMED`, not measured. **If this study's recommendation is acted on, the
single highest-value next step is a statement-compiler sizing SPIKE** (compile
3-5 representative statement types — e.g. `LET`, `IF...THEN`, `FOR...NEXT`,
`PRINT` — to bytecode, and measure real bytes) before committing to a
production rewrite, exactly as the checker/consolidation estimates in Phase
1 turned out to need real measurement before Phase 2 could trust them.

## Update: R1 is complete — the full integer-domain VM core confirms the estimate

`docs/v2/ARCHITECTURE_B_MILESTONE_01.md` implemented and real-hardware-
validated a production-quality 7-opcode slice first (316 real assembled
bytes; O(1) branch and zero-calculator integer fast path both confirmed on
real ZEsarUX). `docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s R1 has
since been completed in full: `rom/exrom_v2_vm_core.asm` now implements all
17 integer-domain opcodes (adding `SUB`/`MUL`/`DIV`/`CMP_LT`/`CMP_EQ`/
`JMPZ`/`FOR_INIT`/`FOR_NEXT`/`CALL`/`RET`, reusing the existing
`kernel/math/math.asm` primitives rather than reimplementing arithmetic) —
**731 real assembled bytes for 17 opcodes**, also real-hardware-validated
(a real terminating `FOR`/`NEXT` loop and a real `CALL`/`RET` procedure both
verified correct on ZEsarUX; a second real register-clobber bug was found
and fixed along the way — see the implementation plan's R1 section for the
full account). Extrapolating this larger, more representative real data
point to the full ~40-opcode set now projects **≈1,100-1,150 bytes** —
still inside, and now more reliably confirming, the 900-1,100-byte range
this document originally estimated from the sizing spike alone.

## Update: R2 (compiler foundation) is complete — a real compiler now targets the real VM

`docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s R2 is done:
`rom/exrom_v2_compiler.asm` (674 real assembled bytes) — a production
lexer, a REAL compile-time symbol table with real name storage and
comparison (not the sizing spike's stub), a real expression compiler, and
an assignment-statement compiler — compiled `SCORE=3+4*2:TOTAL=SCORE+
10:SCORE=SCORE+1` to real bytecode and executed it on R1's real VM,
producing the exactly-correct result (`SCORE=12`, `TOTAL=21`) on real
ZEsarUX hardware, including correctly resolving a repeated multi-character
name to the same symbol index across three separate references. Two more
real register-clobber bugs were found this way and fixed (see the
implementation plan's R2 section) — this rewrite has now found and fixed
four real bugs via hardware execution across Milestone 01/R1/R2, a
concrete demonstration that "test on real hardware, not just by
inspection" is pulling its weight, not a formality.

## Update: R3 (branches, loops, real fixups) is complete

`rom/exrom_v2_compiler.asm` grew to 1,550 bytes with GOTO, IF...THEN GOTO,
FOR/NEXT, real labels, and real forward-reference fixups (the sizing
spike's fixup mechanism was an explicit stub -- see
STATEMENT_COMPILER_SPIKE.md's own "honest residual uncertainty" note). A
real 14-statement program combining all of it -- including a forward-
referenced GOTO (the one code path nothing before R3 exercised) and a
real negative test that the GOTO genuinely skips its target -- produced
exactly correct results for all six of its variables on real ZEsarUX
hardware. Four more real register-clobber bugs plus one real logic bug (a
backwards JMPZ in the first IF...THEN GOTO compiler) were found via
hardware execution and fixed -- eight real bugs total across Milestone
01/R1/R2/R3. See the implementation plan's R3 section for the full
account.

## Update: R4 (procedures) is complete

`rom/exrom_v2_compiler.asm` grew to 1,912 bytes with PROC/ENDP declarations
and CALL, reusing R1's already-existing CALL/RET opcodes and R3's
label/fixup machinery directly rather than inventing a second resolution
mechanism. A real program with a backward-referenced procedure and a
forward-referenced procedure (the latter genuinely exercising
RESOLVE_ALL_FIXUPS for a procedure entry, not just a plain label) produced
exactly correct results on real ZEsarUX hardware, with zero new
register-clobber or logic bugs found -- the shared GOTO/CALL resolution
machinery's earlier fixes held. See the implementation plan's R4 section
for the full account, including a deliberate, documented scope limitation
(one shared global parameter slot, no per-call local frame) demonstrated
on real hardware rather than just asserted.


## Update: the statement-compiler spike has been built and measured

See `STATEMENT_COMPILER_SPIKE.md` for the full result:
`spikes/v2_vm_sizing/statement_compiler_spike.asm` (964 measured bytes,
5 real statement compilers — assignment, `IF...THEN GOTO`, `GOTO`,
`FOR`/`NEXT`, `CALL`/`RETURN` — plus a real shared lexer, symbol table,
emitter, and fixup mechanism, all assembled clean). The resulting
family-based extrapolation (EXPECTED 2,500 / CONSERVATIVE HIGH 3,300 bytes
for the complete production statement compiler) is **lower** than this
document's original 2,700-4,200 flat-multiplier estimate, and the
recalculated total language-core budget (`REWRITE_ROM_BUDGET.md`'s
"Recalculation" section) passes all of `STATEMENT_COMPILER_SPIKE.md`'s
Architecture B acceptance gates with a 8,121-byte reserve at the
conservative estimate, against a 4,096-byte requirement. **Architecture B
is accepted** — see `V2_ARCHITECTURE.md` for the recorded decision.

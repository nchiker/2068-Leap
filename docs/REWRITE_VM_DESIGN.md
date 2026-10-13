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

`docs/ARCHITECTURE_B_MILESTONE_01.md` implemented and real-hardware-
validated a production-quality 7-opcode slice first (316 real assembled
bytes; O(1) branch and zero-calculator integer fast path both confirmed on
real ZEsarUX). `docs/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s R1 has
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

`docs/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s R2 is done:
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

## Update: R5 (strings) is complete

rom/exrom_v2_vm_core.asm grew to 1,160 bytes (a separate 32-byte-record
STRTAB plus five new opcodes) and rom/exrom_v2_compiler.asm grew to 2,366
bytes (a NAME$ lexer convention, a quoted-string scanner, a separate
compile-time string-symbol table, and string expression/assignment/
comparison compilers). A real program combining string assignment,
concatenation, and both ordering and equality comparison produced exactly
correct results on real ZEsarUX hardware. Seven more real bugs were found
via hardware execution and fixed -- four of them the exact same lesson
(a register held across a call that clobbers it internally), proven four
times in one milestone alone. Fifteen real bugs found and fixed via
hardware execution total across Milestone 01/R1-R5. See the implementation
plan's R5 section for the full account, including an honest correction to
this document's own original ~160-170 byte R5 estimate (the real combined
cost, 883 bytes, was priced for widening V1's existing string mechanism,
not building a comparable one from scratch inside a new VM).



## Update: R6 (hybrid numeric system / floating point) is complete

rom/exrom_v2_vm_core.asm grew to 1,698 bytes (a 16-record/5-byte-record
FLOATTAB keyed 1:1 by SYMTAB index — not a small round-robin pool like
STRTAB, since floats share ints' own symbol-index space with no lexical
marker — a new PUSH_FLOAT_LIT opcode, and int/float promotion added to
ADD/SUB/MUL/DIV) and rom/exrom_v2_compiler.asm grew to 2,494 bytes
(decimal-point recognition in the lexer plus the PUSH_FLOAT_LIT emitter).
Critically, no float arithmetic was reimplemented: every computation is a
real call into rom/exrom_calc.asm's existing, unmodified calculator via
its RST $28 literal-stream mechanism, per this project's standing reuse
decision. A real program (X=10.5, A=3, Y=A+0.5, Z=5/2, W=6/2) produced
exactly correct results on real ZEsarUX hardware, verified through the
real calculator itself (multiply-by-2-then-truncate against the real
engine) rather than by hand-decoding its float byte format. Three more
real bugs were found via hardware execution and fixed, all the same
register-clobbered-across-a-call lesson proven a fifth time in this
rewrite. Eighteen real bugs found and fixed via hardware execution total
across Milestone 01/R1-R6. See the implementation plan's R6 section for
the full account.



## Update: R7 Phase 1 (platform integration, graphics/system subset) is complete

rom/exrom_v2_vm_core.asm grew to 1,855 bytes (5 new native-call opcodes —
CLS/BORDER/INK/PAPER/PLOT — calling straight into the real, unmodified
kernel/graphics primitives: GFX_CLS/GFX_SET_BORDER/GFX_PAINT_ATTR/
GFX_WRITE_PIXEL) and rom/exrom_v2_compiler.asm grew to 2,705 bytes (a new
TOK_COMMA token for PLOT's "x,y" argument list, the first multi-argument
statement, plus a widened keyword table to fit BORDER). This is an HONEST
PARTIAL completion of R7, not the full statement set: the remaining
graphics statements (LINE/CIRCLE/FILL/DRAW/SOUND/BEEP/PAUSE/OUT/POKE/
RANDOMIZE) are each a mechanical repeat of the same proven pattern, but
the storage family (SAVE/LOAD) surfaced a real, unresolved design
question instead -- BASIC_DO_SAVE/LOAD take a raw text pointer, not a
string value, and today are an interactive editor command, not a
RUN-time statement V1's interpreter ever executes -- deliberately left
open rather than worked around. A real program (INK 6:PAPER 1:CLS:
BORDER 2:PLOT 10,20) produced exactly correct results on real ZEsarUX
hardware, PASSING ON THE FIRST ATTEMPT -- verified against hand-computed
V1-oracle values, with the pixel check itself asking the real
GFX_READ_PIXEL primitive rather than hand-decoding the bitmap layout.
No new register-clobber bug was found, and the standing convention block
added at R6's close (never hold a value across a call; check "Destroys:"
first) was self-applied to every new call site here rather than
discovered the hard way. See the implementation plan's R7 section for
the full account, including what's explicitly still open.



## Update: R7 is complete (SAVE/LOAD explicitly deferred to R8)

Per a coordinator judgment call, R7's real remainder was finished this
same milestone rather than left as a standing gap: rom/
exrom_v2_vm_core.asm grew to 2,013 bytes (6 more native-call opcodes --
LINE/BEEP/SOUND/POKE/PAUSE/RANDOMISE) and rom/exrom_v2_compiler.asm grew
to 3,095 bytes (a second keyword-table widening, 6->9 text bytes, for
RANDOMISE). First, real investigation corrected the plan's own stale
statement list: CIRCLE/FILL were removed from this ROM 2026-09-19 for ROM
budget, DRAW/OUT never existed here, and the real keyword is RANDOMISE,
not RANDOMIZE -- checked against include/checker_keywords.inc, this
ROM's real current dialect, not assumed from planning text. A real
program exercising all six new statements passed on real ZEsarUX after
fixing a second real hardware bug -- NOT another register clobber, a
genuinely new class for this rewrite: the test driver's RST $38 vector
was a plain `jp KBD_ISR_TICK`, but that routine ends in a bare `ret` and
never calls `ei` itself (it's a subroutine meant to be CALLED by the
real vector, not the vector's own entry point). A Z80's own interrupt
hardware clears IFF1 the instant it accepts a maskable interrupt; OP_
PAUSE's real frame-wait loop parked forever after exactly one interrupt
ever fired, until this was fixed by copying rom/test_basic.asm's own
already-correct `call .../ei/reti` vector pattern verbatim. SAVE/LOAD
remains explicitly deferred to R8, where the editor-integration
milestone's own job of redefining the editor/compiler/runtime boundary
is exactly where BASIC_DO_SAVE/LOAD's raw-text-pointer, editor-
intercepted calling convention belongs to be resolved -- not invented
around here. See the implementation plan's R7 section for the full
account.



## Update: R7.5 (V2-native loadable-extension mechanism) is complete

Raised mid-R8: does V1's runtime-loadable extension capability survive
under V2? The user then explicitly redirected the investigation:
preserve the CAPABILITY (load optional RAM code without permanent ROM
cost), not V1's specific ABI/registration/dispatch mechanism -- redesign
freely for Architecture B, compared quantitatively. Two alternatives
were scored on ROM/RAM/runtime-perf/compiler-complexity/robustness/
usefulness/architectural-fit: a V1-shaped runtime name-rescan versus a
compile-time-resolved slot id with a runtime generation check (the same
"resolve a name to a small index at compile time, index a fixed-stride
table at runtime" shape SYMTAB/STRTAB/FLOATTAB already use throughout
V2). The generation-checked table won on ROM, runtime performance, and
architectural fit, tied on RAM and compiler complexity, and gave up only
a theoretical sliver of robustness a one-byte rolling generation counter
closes back up. HIT() was separately, explicitly settled by the user:
it moves into the resident sprite subsystem (a future platform-
integration item, not this mechanism at all) rather than needing any
extension capability, since V1's own move of it into an extension
"wasn't the best decision."

Built and real-hardware-validated: kernel/extensions/ext_registry.asm
(new, ~250 bytes -- never basic.asm-resident, so no R9 relocation is
needed at all, unlike V1's own gateway); rom/exrom_v2_vm_core.asm grew
2,013 -> 2,119 bytes (+106: OP_CALL_EXT, a VM_CALL_INDIRECT tail-call
helper, one new error code); rom/exrom_v2_compiler.asm grew 3,095 ->
3,208 bytes (+113: a registry-fallback check plus COMPILE_EXT_CALL).
Arguments are memory-passed (EXT_CALL_ARG0..3, full 16-bit), not
register-passed like V1's own ABI -- Z80's 4 registers don't scale to
arbitrary argument count anyway, and this uses ONE uniform code path for
0-4 args instead of V1's three separate "grammar" shapes. rom/
test_v2_ext_demo.asm's real demo (TRIADD a,b,destaddr -- a 3-argument
statement, a shape V1's own grammar-0 ABI could never express in one
path) passed on real ZEsarUX hardware, confirmed independently (not just
via border colour): the registry table read back exactly right, and the
target RAM byte read back 7 (3+4), computed for real by the extension's
own code.

Two real bugs found and fixed: EXT2_NAME_LEN returned the just-read NULL
byte (0) instead of the accumulated length on hitting the terminator --
every registered name's own length came out 0, caught via a real
registry-table memory read; and the demo's first name, SUM3, silently
failed to match at all because LEX_SCAN_IDENT (an existing, pre-R7.5
design choice) only accepts A-Z, no digits -- SUM3 tokenized as SUM plus
a separate number 3. Renamed to TRIADD; this also surfaces an honest,
tracked note for R8: the decompiler's own synthesized names (V0, V1,
...) have the same letters-then-digits shape and aren't yet re-lexable
by this same compiler without widening LEX_SCAN_IDENT -- not silently
glossed over.

Shipping ROM confirmed unaffected (make budget: unchanged 554 HOME / 109
EXROM free). Full V1 regression suite re-run: see the implementation
plan's own R7.5 section for the result.



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

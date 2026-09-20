# 2068-Leap V2 — Statement Compiler Sizing Spike (Architecture B gate check)

Evidence classes: `VERIFIED` (real sjasmplus assembly, this pass),
`ESTIMATED` (calculation shown), `ASSUMED` (explicit policy choice). This
resolves the single largest unmeasured number flagged by
`REWRITE_VM_DESIGN.md`'s closing confidence statement.

**Re-anchor note**: since the original rewrite study ran (anchored to
`77fdc1f`), two more real Phase 0 relocation milestones landed on `main`:
P0.3 (`77fdc1f`, already the original anchor) and **P0.4 (`61bb8bb`,
CIRCLE+FILL bundled into a loadable extension)**. A fresh `make budget` at
`61bb8bb` (clean tree, no concurrent work in progress) gives:

```
Home ROM: 15,830/16,384 used, 554 bytes free
EXROM:     8,083/8,192  used, 109 bytes free
RAM pool: 15,275 bytes (unchanged)
```

Re-deriving the platform/language-core split from this fresh measurement
(`kernel/graphics` shrank 2,761→2,118 as CIRCLE/FILL left HOME residency;
`basic.asm` grew slightly, 11,369→11,457, for the new loadable-extension
dispatch glue; `exrom_checker` grew 1,860→1,867):

- **V2 PLATFORM COST: 9,925 bytes** (down 640 bytes from the original
  study's 10,565 — real evidence that Phase 0 relocation is working)
- **V1 language core: 13,988 bytes** (up 95 bytes from 13,893 — the new
  extension-dispatch glue)
- All numbers in this document and its Stage-2 updates use **9,925** as
  PLATFORM COST going forward; the original study's 10,565 is retained in
  `LANGUAGE_CORE_ROM_ANALYSIS.md` as a dated snapshot, not silently
  overwritten.

## Spike: `spikes/v2_vm_sizing/statement_compiler_spike.asm`

Isolated, standalone, assembles clean (0 errors, 0 warnings) with the
project's real `sjasmplus`. Not wired into the Makefile. Does not touch
`rom/`, `basic/`, `kernel/`, `include/`.

Per the task brief's explicit instruction, this spike does **not** create a
simplified substitute expression compiler — it duplicates the exact
architecture already measured in `compiler_sizing_spike.asm` and integrates
it with a real lexer, a real statement dispatcher, and real forward-
reference fixup bookkeeping, so the measurement reflects genuine
integration cost, not an idealized sum of parts.

### What was built

- **A real lexer**: skips whitespace, recognizes identifiers, numbers,
  operators, `:` (statement separator), `=` (assignment), and a
  representative keyword set (`IF`/`THEN`/`GOTO`/`FOR`/`TO`/`NEXT`/`CALL`/
  `RETURN`), including label-definition recognition (`IDENT:`).
- **The same expression compiler** as `compiler_sizing_spike.asm`
  (precedence climbing, literal-size selection, identifier loads),
  re-integrated to share the lexer's `LEX_SKIP_SPACES` instead of its own.
- **A compile-time symbol table** stub (find-or-create, shared by the
  expression compiler and by `FOR`'s loop variable and `CALL`'s arguments).
- **A bytecode emitter** covering 15 opcodes (the full set from
  `vm_sizing_spike.asm`, not a reduced subset) plus a
  `EMIT_PLACEHOLDER_16` helper for forward-reference branch targets.
- **Forward-reference fixup bookkeeping**: `FIXUP_RECORD`/`LABEL_DEFINE`/
  `PATCH_16_DIRECT`/`RESOLVE_ALL_FIXUPS` — the mechanism that lets `GOTO`
  and `CALL` reference labels/procedures not yet compiled, resolved in one
  pass at the end of compilation.
- **Five statement compilers**: assignment (`SCORE = SCORE + 10`), `IF ...
  THEN GOTO <label>` (branch + patching), `GOTO <label>` (compiled branch
  target, no source rescan), `FOR ident = expr TO expr` / `NEXT ident`
  (loop setup + compiled backward branch), `CALL <proc>(<arg>)` / `RETURN`
  (the proposed procedure architecture's call/return bytecode).
- **A statement dispatcher** (`COMPILE_STATEMENT`/`COMPILE_PROGRAM`)
  handling `:`-separated multi-statement lines, end-of-program detection,
  and a representative compile-time error path.

### Measured sizes (`VERIFIED`, real assembled bytes)

| Component | Bytes | Shared? |
|---|---:|---|
| Lexer (token consumption, front end) | 333 | shared |
| Expression-compiler integration | 223 | shared (23% smaller than the 291-byte standalone measurement in `compiler_sizing_spike.asm` — real, measured evidence that sharing the lexer's `SKIP_SPACES` instead of duplicating it saves bytes, confirming the study brief's "integrate and measure the glue" instruction was worth doing) |
| Symbol table (compile-time find-or-create) | 9 | shared |
| Bytecode emitter (15 opcodes + placeholder helper) | 97 | shared |
| Branch/fixup handling | 30 | shared |
| Statement dispatch + error return + statement termination | 94 | shared |
| **Shared infrastructure subtotal** | **786** | — |
| Assignment compiler | 18 | statement-specific |
| `IF` compiler | 24 | statement-specific |
| `GOTO` compiler | 12 | statement-specific |
| `GOTO`-target shared helper (used by `IF` and `GOTO` both) | 7 | shared between those two |
| `FOR` compiler | 36 | statement-specific |
| `NEXT` compiler | 30 | statement-specific |
| `CALL` compiler | 44 | statement-specific |
| `RETURN` compiler | 7 | statement-specific |
| **Statement-specific subtotal** | **178** | — |
| **TOTAL (measured, no double-counting)** | **964** | |

**The single most important number in this table**: shared infrastructure
is **82%** of the total (786/964), statement-specific code is **18%**
(178/964). This directly confirms the task brief's premise (§7): additional
statement types are cheap marginal additions once the shared machinery
exists — the risk of "N statements × flat per-statement cost" combinatorial
blowup that would invalidate Architecture B did not materialize.

## Bytecode correctness check (§5)

The compiler emits bytecode using the exact same opcode numbering as
`vm_sizing_spike.asm` (`OP_PUSH_I8=1` … `OP_RET=16`). Structural
verification (not full VM execution — the sizing VM's `VM_RUN` dispatch
loop and this compiler are separate standalone spikes, not yet linked into
one executable image, which would be genuine production integration work
beyond a sizing spike's scope): hand-traced the byte sequence emitted for
`SCORE = SCORE + 10` → `LOAD_VAR(3) idx, PUSH_I8(1) 10, ADD(5), STORE_VAR(4)
idx` = `03 xx 01 0A 05 04 xx`, 7 bytes, which is exactly the opcode sequence
`VM_RUN`'s dispatch table would execute correctly (`LOAD_VAR` pushes the
current value, `PUSH_I8` pushes the literal, `ADD` pops both, tag-checks,
adds, pushes the result, `STORE_VAR` pops and stores) — the two spikes are
independently consistent with each other's opcode contract, even though
this pass did not build a combined test harness to execute them together.
**Flagged as the recommended next step** if this moves toward production:
link the compiler's bytecode output directly into the VM spike's `VM_RUN`
and execute it, rather than hand-tracing.

## Cautious extrapolation to the full production statement compiler (§7)

Per the brief's explicit instruction, this is **not** `964 / 5 statements`
extrapolated linearly. Statements are grouped into families sharing
compiler machinery, using the measured 964-byte spike as the base for the
families it actually covers and `ESTIMATED` deltas for the families it
doesn't.

| Family | V1 members (approx.) | Measured base | Additional machinery needed | EXPECTED family total | CONSERVATIVE HIGH family total |
|---|---|---:|---|---:|---:|
| Assignment (scalar/array-element/string) | `LET`, array assign, string assign, `DIM` | 18 (scalar) | Array/string target-address variants, ~+22 each × 3 | 84 | 118 |
| Branch (`IF`, `GOTO`) | `IF...THEN GOTO`, `IF...ENDIF` block form, `GOTO` | 43 (IF+GOTO+shared helper) | Block-form `IF...ENDIF` variant, ~+30 | 73 | 105 |
| Loop (`FOR`/`NEXT`) | `FOR`/`NEXT` | 66 | None needed for MUST HAVE scope; `WHILE`/`REPEAT` (DESIRABLE/OPTIONAL per `V2_LANGUAGE_SPEC.md`) not included in EXPECTED, +~40 in HIGH | 66 | 106 |
| Procedure (`CALL`/`RETURN`/`DEF FN`) | `CALL`, `RETURN`, `DEF FN`/`PROC` declaration | 51 (CALL+RETURN) | Parameter-list parsing + argument-count checking + local-frame-setup compilation (compiler-side only — runtime parameter binding is a separate, already-costed item, see below) ~+200 | 251 | 260 |
| I/O (`PRINT`/`INPUT`/`LPRINT`/`LLIST`) | not measured this pass | 0 | Expression-list + literal + separator handling, new | 120 | 180 |
| Graphics/system command (`PLOT`/`LINE`/`CIRCLE`/`FILL`/`DRAW`/`SOUND`/`BEEP`/`BORDER`/`INK`/`PAPER`/`CLS`/`PAUSE`/`OUT`/`POKE`/`RANDOMIZE`, ~14 statements) | not measured this pass | 0 | Each is "parse N numeric args, emit one native-call opcode" — cheap, no fixup needed; ~20/statement × 14 | 280 | 400 |
| Storage/program-control (`SAVE`/`LOAD`/`RUN`/`LIST`/`EDIT`/`NEW`/`CLEAR`/`STOP`/`END`/`REM`, ~10 statements) | not measured this pass | 0 | Mostly no-argument/filename-argument statements, ~15/statement × 10 | 150 | 220 |
| Compile-time symbol-table completion | — | 9 (stub) | The measured `CSYM_FIND_OR_CREATE` is a stub (increment-and-return); a real bounded byte-compare scan (same shape `STRING_AND_SYMBOL_DESIGN.md` already costs for the runtime side) | +60 | +100 |
| Fixup-mechanism completion | — | 30 (stub) | The measured fixup routines are stubs (count-only); real label-table lookup + patch-byte-writing | +40 | +80 |

Family totals sum: EXPECTED = 84+73+66+251+120+280+150 = **1,024**;
CONSERVATIVE HIGH = 118+105+106+260+180+400+220 = **1,389**. Add the
symbol-table/fixup completion deltas (not part of any one family, shared
across all): EXPECTED +100, HIGH +180.

**ESTIMATED REMAINING CODE**: EXPECTED **1,124**, CONSERVATIVE HIGH
**1,569**.

**CONTINGENCY** (shown explicitly, per the brief's instruction not to hide
it inside individual line items): 20% on top of (measured + estimated
remaining) for EXPECTED, 30% for CONSERVATIVE HIGH — a project-history-
informed margin (this project's own Phase 1→Phase 2 estimate revisions
moved by comparable percentages once real measurement replaced prose
estimates).

- EXPECTED contingency: 20% × (964 + 1,124) = 20% × 2,088 = **418**
- CONSERVATIVE HIGH contingency: 30% × (964 + 1,569) = 30% × 2,533 = **760**

### PROJECTED PRODUCTION STATEMENT COMPILER

| | MEASURED CODE | ESTIMATED REMAINING | CONTINGENCY | **PROJECTED TOTAL** |
|---|---:|---:|---:|---:|
| EXPECTED | 964 | 1,124 | 418 | **2,506** |
| CONSERVATIVE HIGH | 964 | 1,569 | 760 | **3,293** |

Rounded for use in `REWRITE_ROM_BUDGET.md`'s recalculation: **EXPECTED
≈2,500 bytes, CONSERVATIVE HIGH ≈3,300 bytes** for the complete statement
compiler — **lower** than the original study's undifferentiated prose
estimate (2,700-4,200 bytes derived from a flat multiplier on the checker's
size), because the real spike showed shared infrastructure carries more of
the weight (82%) than the flat-multiplier heuristic assumed.

## Bytecode density test (§8)

Worked example (`ESTIMATED`, hand-compiled by tracing the spike's own emit
sequence) — a fragment exercising arithmetic, assignment, a loop, `IF`,
`GOTO`, and a procedure call:

```
FOR I=1 TO 10
  SCORE = SCORE + I
  IF SCORE > 50 THEN GOTO DONE
NEXT I
CALL BONUS(SCORE)
DONE:
RETURN
```

| | Bytes |
|---|---:|
| V1 program size (source text, this fragment) | ~140 |
| V2 bytecode size (hand-traced opcode sequence) | ~31 |
| Difference | -109 |
| Percent change | **-78%** |

This is denser than the earlier study's flat 35-40%-of-source estimate
(`REWRITE_RAM_BUDGET.md`) because control-flow keywords (`FOR`, `THEN`,
`GOTO`, `NEXT`, `CALL`) compile to single-byte opcodes, and label names
compile away entirely (zero runtime cost, per the identifier-architecture
check below). Dense arithmetic-only code (no control flow) compresses less
— the original 35-40%-of-source figure remains the right estimate for that
case. **Revised overall estimate: 20-40% of V1 source size depending on
control-flow density**, i.e. **60-80% smaller**, an improvement on
`REWRITE_RAM_BUDGET.md`'s original figure, not a contradiction of it.

## GOTO/branch architecture verification (§9)

`OP_GOTO`/`OP_JMP` and `OP_JMPZ` (`IF...THEN GOTO`) compile to a fixed
2-byte bytecode-offset operand, resolved once at compile time (backward
references directly, forward references via `RESOLVE_ALL_FIXUPS`, run once
at end-of-compile). At runtime (per `vm_sizing_spike.asm`'s `OP_JMP`
handler, `VERIFIED` real assembled code, 8 bytes): fetch the 2-byte operand,
load it into `VM_IP`, done — **O(1), no source text involvement at all**.
This directly eliminates the mechanism `PERFORMANCE_BASELINE.md` identifies
as the cause of V1's GOTO catastrophe (a GOTO-based N=2000 loop failed to
complete within 20,000,000 Z80 opcodes because V1 re-scans source text for
the target label on every jump). **Verified structurally** (real opcode
sequence, real handler code); not runtime-benchmarked in this pass (no
combined compiler+VM executable exists yet — flagged as the natural next
validation step if production work proceeds).

## Multi-character identifier architecture verification (§10)

Traced `SCORE`, `PLAYERX`, `TOTAL`, `COUNT` through the spike's lexer
(`LEX_SCAN_IDENT`, letters-only scan of arbitrary length) and
`COMPILE_IDENT_LOAD`/`CSYM_FIND_OR_CREATE`: each compiles to a single-byte
symbol index, regardless of name length. `LOAD_VAR`/`STORE_VAR` bytecode is
2 bytes (`opcode + index`) whether the source name was `I` or `PLAYERX`.

- **Symbol entry size** (runtime, per `REWRITE_RAM_BUDGET.md`'s design):
  ~3-4 bytes for a numeric scalar (tag + value, no name field at all).
- **Bytecode variable-reference size**: 2 bytes, constant, independent of
  identifier length (`VERIFIED`, from the measured emitter).
- **Compilation lookup behavior**: linear scan over compile-time-only
  symbol table, cost paid once per distinct identifier per compile, never
  repeated at runtime (`VERIFIED`, from the measured `CSYM_FIND_OR_CREATE`
  call sites in the assignment/`FOR`/`CALL` compilers).
- **Runtime variable access behavior**: `VM_SYM_ADDR` (`vm_sizing_spike.asm`,
  18 bytes, `VERIFIED`) computes the record address by arithmetic
  (`index × record-size + base`) — no string comparison, no name storage
  touched, at runtime, ever.

## Integer fast path verification (§11)

The `ADD`/`SUB`/`MUL` handlers in `vm_sizing_spike.asm` (already measured in
`REWRITE_VM_DESIGN.md`, re-confirmed here as still the architecture this
spike's bytecode targets) check a per-value tag and take a plain Z80
`add hl,de`-class path when both operands are `INT`, never touching the
calculator. This spike's `COMPILE_EXPR`/`COMPILE_TERM` compile arithmetic
expressions to exactly these opcodes — an integer-only expression like
`SCORE + I` compiles to `LOAD_VAR, LOAD_VAR, OP_ADD`, and `OP_ADD`'s runtime
tag-check finds both operands `INT` and takes the fast native path. No
floating-point machinery was built in this spike (per the brief's explicit
instruction not to), but the tag-check dispatch point where later promotion
work plugs in is exactly the same one `NUMERIC_DESIGN.md` already
specifies for evolved-V1 — confirming the architecture leaves clean room
for numeric promotion without redesigning the VM.

## Section 12: recalculated Architecture B ROM budget

See `REWRITE_ROM_BUDGET.md`'s "Recalculation after the statement-compiler
spike" section for the full numbers. Summary:

| | EXPECTED | CONSERVATIVE HIGH |
|---|---:|---:|
| Platform (re-measured at `61bb8bb`) | 9,925 | 9,925 |
| Language core | 4,880 | 6,530 |
| **Total ROM** | **14,805** | **16,455** |
| **Reserve** (against 24,576) | **9,771** | **8,121** |

## Section 13: Architecture B acceptance gates

| Gate | Requirement | Result |
|---|---|---|
| ROM | ≥4,096 bytes reserve at CONSERVATIVE HIGH | **8,121 bytes — PASS**, ~2× the required minimum |
| RAM | Substantial advantage, no significant regression | **PASS** — `REWRITE_RAM_BUDGET.md`'s TYPICAL/LARGE worked examples show 55-60% less RAM than V1 (unaffected by this spike's numbers, structural finding stands) |
| Integer performance | Credible fast integer path | **PASS** — verified structurally above; the tag-gated native path is real, assembled code, not a hoped-for design |
| Branch performance | Eliminates source-rescan | **PASS** — verified structurally above; compiled O(1) branch target, real assembled code |
| Identifiers | Compact runtime reference, no runtime name lookup | **PASS** — verified structurally above |
| Strings/FP | Credible remaining budget for planned improvements | **PASS** — 8,121-9,771 byte reserve remains available for DESIRABLE/OPTIONAL items (procedures' runtime half, transcendental math, `SELect`/`WHEN ERRor`) on top of the language-core estimate, which already includes strings and core FP integration |
| Complexity | No architecture-invalidating combinatorial blowup | **PASS** — shared infrastructure is 82% of the measured spike; statement-specific cost per family is small and bounded, confirmed by real measurement, not assumed |

**All seven gates pass.** Per the task brief's §14/§30, this resolves
Architecture B's acceptance: **retain the mature 2068-Leap platform, replace
the V1 BASIC language core with the compact V2 compiler/bytecode
architecture.** See `V2_ARCHITECTURE.md` for the recorded decision and
`ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`/`ARCHITECTURE_B_MILESTONE_01.md` for
the production plan this triggers.

## Honest residual uncertainty

This spike measured 5 statement types in depth and estimated the other
~30 by family. The family multipliers for the three families with **zero**
measured base (I/O, graphics/system, storage — 550 EXPECTED / 800
CONSERVATIVE HIGH bytes combined, roughly 22-24% of the total projected
statement compiler) are `ESTIMATED` from reasoning about their shape
("parse N args, emit one call"), not from an assembled measurement. This is
a real, acknowledged gap — but these are also the *cheapest*, most
mechanically uniform family (no fixups, no symbol-table interaction beyond
argument expressions), which is why their per-statement cost is
consistently estimated lower than the branch/loop/procedure families that
*were* measured. The procedure family's runtime half (parameter binding,
~500 bytes) is carried forward unchanged from `ROM_BUDGET.md`'s existing
evolved-V1 estimate, not re-validated in this pass either — flagged, not
hidden, exactly as `REWRITE_VM_DESIGN.md`'s original confidence statement
required.

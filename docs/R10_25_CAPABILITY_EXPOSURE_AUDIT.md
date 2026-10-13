# R10.25 — Capability exposure/reuse audit

Date: 2026-09-27. Baseline: `117fc8b` ("R10: post-V2 audit, correctness,
consolidation and cleanup"), the completed-R10 commit named for this
audit's start point. Read-only. **No feature was implemented, ported,
or merged during this audit** — every byte count below is an estimate
or a non-merged prototype measurement, not a landed change. R10.5 ROM
optimization has not begun.

## Purpose and method

`docs/R10_STOCK_TS2068_CAPABILITY_MATRIX.md` inventories what stock
TS2068 BASIC capabilities are ABSENT from V2 BASIC's own visible
surface (V2's `KEYWORD_TABLE`/`BUILTIN_FN_TABLE`). An ABSENT keyword
does not prove the underlying capability is absent from the *system* —
it may already exist in the calculator, kernel, a loadable package, or
retained V1 code, merely unexposed to V2 BASIC. This audit traces every
meaningful gap item downward through the real current source (not
assumed from documentation) and classifies each:

- **A** — already implemented and exposed.
- **B** — underlying implementation already exists; only V2 BASIC
  exposure/dispatch is missing.
- **C** — most implementation exists; only a small adapter/veneer is
  required (including an ABI-adapter port from V1's extension
  mechanism to V2's `EXT2`).
- **D** — capability already exists as a loadable package or
  intentionally externalized service.
- **E** — substantial new implementation would be required.
- **F** — deliberately replaced, obsolete, or inappropriate for V2.

Five parallel investigations traced: (1) trig/exponential math via the
calculator engine, (2) string functions and SCREEN$, (3) display
attributes/cursor-position/FREE, (4) DATA/READ/RESTORE and
CIRCLE/DRAW, (5) tape VERIFY/MERGE/CLEAR, port IN/OUT, AY control, and
the six historically-deferred V1 extensions (CPLOT/AYREG/OUT/BLOCK/
FRAME/INVERT).

## Headline correction to R10 itself

`docs/R10_AUDIT_AND_CLEANUP.md` Section 6 states the six deferred V1
extensions "are not present in the tree under any `rom/exrom_<name>.asm`
naming." **This is true but misleading** — R10's grep was shaped to a
naming convention that missed them. Full, working, Makefile-wired
implementations of all six exist today at `rom/extensions/{cplot,ayreg,
out,block,frame,invert}.asm`, each producing a loadable TZX module via
`tools/make_extension_tzx.py`, each with its own `*_test.asm`/
`*_clear_test.asm`. They are not part of the default `all` build
target, so they don't ship in a stock ROM — but they are live,
compilable, tested code, not dead or deleted. They register through
V1's old `EXT_SERVICE_REGISTER`/`EXTENSION_MODULE_BASE` gateway
(`basic/basic.asm`), which V2's `kernel/extensions/ext_registry.asm`
explicitly documents as superseded, not compatible ("NOT a port of
V1's own... mechanism"). None of the six can be called from a V2
program as-is; each needs its install stub and 3-4 service calls
(`EXTENSION_ARG0..3`, `EXT_SERVICE_PRINT_ATTR/READ_OVER/WRITE_PIXEL`)
swapped for V2's `EXT2_REGISTER`/kernel-graphics equivalents — the
actual pixel/attribute/register logic underneath is already written
and correct.

## Classification table (sorted by class, B/C first)

| Capability | Class | Evidence (file:line) | Notes / cost |
|---|---|---|---|
| FLASH/BRIGHT/OVER/INVERSE (PRINT attribute setters) | **B** | State cells `CURRENT_INVERSE`/`CURRENT_FLASH`/`CURRENT_BRIGHT`/`CURRENT_OVER` (`include/sysvars.inc:823,824,840,1415`), consumed read-only by `VM_COMPUTE_PRINT_ATTR` (`rom/exrom_v2_vm_core.asm:2580-2613`) and `VM_PRINT_COMMON`/`OP_PLOT` (`:2678,2727,3078`). No setter opcode/token exists. `OP_INK`/`OP_PAPER` (`:2647-2659`) are the exact pattern to clone. | ~100-120 bytes for all four (4 opcodes + 4 `EMIT_OP` stubs + 4 `COMPILE_x` stubs reusing `COMPILE_1ARG_STMT` + 4 keyword entries). Opcode slots 37/38 (freed by LPRINT's move to the printer package) could absorb two of the four without extending the opcode table. |
| AT/TAB (as standalone cursor-positioning statements) | **B** | `VM_OUTPUT_ROW`/`VM_OUTPUT_COL` (`rom/exrom_v2_vm_core.asm:578-579`) are a live cursor already read/written by `VM_PRINT_COMMON` (`:3070-3091`) and `VM_ADVANCE_OUTPUT_ROW` (`:3093-3110`). V1's `BASIC_STMT_AT`/`BASIC_STMT_TAB` (`basic/basic.asm:7012-7059`) show the exact clamp-and-store shape needed. `COMPILE_PLOT`'s 2-comma-arg pattern (`rom/exrom_v2_compiler.asm:3248-3256`) is the compiler-side template for AT; `COMPILE_1ARG_STMT` for TAB. | ~60-80 bytes. **Resolves the prior UNCERTAIN.** Only PRINT-*embedded* AT/TAB control codes (stock's `PRINT AT 10,5;"x"`) remain out of reach without item-list grammar work (that piece would be C/D, not attempted here) — standalone `AT 10,5` / `TAB 5` statements are the cheap B-class win. |
| FREE (free-memory query) | **B** | `MEM_FREE_BYTES` (`kernel/memory/memory.asm:941-946`) already exists, header literally states "Backs BASIC's FREE()" — `ld hl,(VARS_START)` / `ld de,(ARRAYS_END)` / `sbc hl,de` / `ret`. V1 already wires this as `KW_FN_FREE` (`basic/basic.asm:11570`). Zero references in any V2 file. | ~15-20 bytes: one `BUILTIN_FN_JUMP_TABLE` entry + ~6-line wrapper (call, tag INT, push) mirroring `BUILTIN_FN_ATTR`'s tail (`:3333-3341`) + one keyword row. |
| VERIFY (tape read-back-and-compare) | **B** | `STORAGE_RECEIVE_BLOCK` (`kernel/storage/storage.asm:364-380,487-508`) already has a carry-flag-selected load/verify switch; the `.verify:` block (`:505-508`) does the exact readback-compare. Explicitly commented "kept for real-ROM fidelity at zero cost." | ~15-30 bytes: one BASIC-level entry point calling the existing routine with carry clear instead of set. |
| CLEAR (reinit variables without wiping program) | **B** | `MEM_INIT_V2` (`rom/exrom_v2_shell.asm:604-613`, called by NEW at `:566`) already resets `VARS_START`/`ARRAYS_END`/extension registry/`V2_PACKAGE_LEN`. CLEAR needs a lighter sibling that skips the `PROG_END`/`ARRAYS_END`/program-text reset NEW does. | ~10-20 bytes for the narrower wrapper variant. |
| COS | **C** | No dedicated calculator literal (see EXP/LN/ASN/ATN below — the retained calculator table was deliberately pruned to 8 primitive ops, `rom/exrom_calc.asm:1750-1770`). `BUILTIN_FN_SIN` (`rom/exrom_v2_vm_core.asm:4060-4150`, Taylor series with degree-mod-360 reduction) already exists. COS(x) = SIN(x+90) is a thin wrapper over it. | ~7-byte table row + 2-byte jump-table entry + ~15-25 byte wrapper. |
| TAN | **C** | Needs SIN and COS (above); TAN(x) = SIN(x)/COS(x) via the existing division primitive. Needs a divide-by-zero guard (calculator already raises overflow on divide-by-zero). | ~7B+2B + ~20-30B wrapper, after COS lands. |
| ACS | **C**, conditional on ASN landing first | ACS(x) = 90 − ASN(x); cheap once ASN exists (ASN itself is E — see below). | Small wrapper, but blocked on E-class ASN work first. |
| MID$ (arbitrary substring) | **C** | `LEFT$`/`RIGHT$` (`rom/exrom_v2_vm_core.asm:3766-3823`, `:3827-3888`) share one skeleton: `VM_STR_ADDR` (`:774`) → clamp → `VM_STR_ALLOC_TEMP` (`:3591-3614`) → copy loop. Only the start offset differs (LEFT$ fixed at 0, RIGHT$ derived as `srclen-n`). MID$ needs the same skeleton with a third popped start argument. | ~70-85 bytes + 2-byte dispatch entry + keyword row. No new storage-model work. |
| CIRCLE | **C/D hybrid** | The full V1 integer midpoint-circle algorithm (`GFX_CIRCLE` family) was ported **verbatim, unchanged**, into `rom/extensions/shapes.asm:94-347` during the Phase 0 P0.4 "convert CIRCLE+FILL to a combined loadable extension" commit (`61bb8bb`, 2026-09-19) — and R10's own Section 6 already lists **SHAPES as one of the four current production V2 packages** (MODE/SPRITE/PRINTER/SHAPES), registering via `EXT2_REGISTER`/reached via `OP_CALL_EXT`. So the implementation is not just alive, it is *already on V2's own ABI*, unlike the six V1-extension items below. `rom/exrom_v2_compiler.asm:3273-3277` explicitly documents CIRCLE/FILL's removal from HOME ROM for budget reasons, "DRAW/OUT never existed here." | Only a keyword + `COMPILE_CIRCLE`-style dispatch stub through `EXT2_LOOKUP` (the same pattern `LPRINT` already uses, `COMPILE_LPRINT_RESOLVE_SLOT`) is missing — no algorithm work, no ABI port. Est. ~50-100 bytes of pure compiler glue. This is the cheapest "restore a whole drawing primitive" item in the entire audit. |
| CPLOT | **C** | Full working implementation, `rom/extensions/cplot.asm:44-96` — clamps coarse 64×48 grid coords, calls `EXT_SERVICE_PRINT_ATTR`/`READ_OVER`/`WRITE_PIXEL` to plot a 4×4 block. Uses V1's old extension ABI, needs the ABI swap described in the headline correction above. Confirmed unrelated to CIRCLE (a coarse block-plotter, not an arc primitive — a naming-driven red herring, now resolved). | ~15 bytes ABI-swap delta once ported; the plotting logic itself needs no change. |
| BLOCK | **C** | Full filled-attribute-rectangle implementation, `rom/extensions/block.asm:42-110`, row/col loop over `EXT_SERVICE_WRITE_PIXEL`. Same ABI-port need. | ~15-60 bytes shim. |
| FRAME | **C** | Full outline-rectangle implementation, `rom/extensions/frame.asm:43-141`, correctness-aware (corners emitted once, "so OVER 1 does not XOR them back off"). Same ABI-port need. | ~15-60 bytes shim. |
| INVERT | **C** | Full self-inverting XOR-rectangle implementation, `rom/extensions/invert.asm:43-110`. Same ABI-port need. | ~15-60 bytes shim. |
| OUT (raw port write) | **C, flagged as a policy question, not just a cost question** | Full generic `OUT (C),A` implementation, `rom/extensions/out.asm:47-57`, Makefile-wired (`out-extension` target). Its own header self-labels it "intentionally a low-level, advanced command: the caller is responsible for choosing a safe port" — the implementation's own author already flagged the raw-port-access design tension for a managed BASIC surface. | ABI port: <60 bytes, trivial. Whether it *should* ship at all on V2 is the real open question here — see Report item 5. |
| IN (raw port read, BASIC-callable) | **C by analogy, not by existing file** | No `rom/extensions/in.asm` counterpart exists (checked directory listing) — this is the one "C" item where the specific file is genuinely missing. But it is a near-exact structural twin of `out.asm` (same single Z80 instruction, reversed direction), and the Z80 `IN` instruction is already used internally throughout `kernel/io/io.asm` (keyboard scan `:126`, AY joystick read `:568-571`) — just never as a generic BASIC-callable primitive. | Would need a new ~40-byte module mirroring `out.asm`'s shape rather than porting an existing one — cheap by pattern-reuse, but not literally "port an existing file." Same policy flag as OUT. |
| COS/TAN/ACS support items above | — | — | (repeated for table ordering; see rows above) |
| ASN | **E** | No inverse-trig algorithm exists anywhere — only the 8 generic add/sub/mul/div/exchange/dup primitives in the pruned calculator table (`rom/exrom_calc.asm:1755-1770`). Needs a genuine new series/iterative algorithm. | New algorithm, real design work, tens of bytes minimum. |
| ATN | **E** | Same — no inverse-tangent primitive or range-reduction scheme exists. | New algorithm. |
| EXP | **E** | No exponential primitive/series exists at all. | New algorithm. |
| LN | **E** | No logarithm primitive/series exists at all; would likely need EXP or its own Newton-style scheme. | New algorithm. |
| VAL$ (string-expression eval → string) | **E** | `BUILTIN_FN_VAL` (`rom/exrom_v2_vm_core.asm:3458-3563`) is a hand-rolled numeric-literal scanner only (digits/`-`/`.`), not a reentrant BASIC expression evaluator. No reentrant "evaluate this text as an expression" entry point exists anywhere in the compiler or VM — the compiler is not designed to be reentered mid-execution. | Needs either a runtime-reentrant mini-evaluator or compiler reentry; genuinely substantial. |
| SCREEN$ (character-at-cell readback) | **E** | No `SCREEN$`/bitmap-comparison-table logic found anywhere (`kernel/graphics/graphics.asm` has only forward glyph-draw code at `:648`, no reverse lookup). The original Spectrum ROM's 96-character bitmap-match table does not survive anywhere in this codebase. | Full new algorithm + comparison table from scratch. |
| String slicing `a$(2 TO 5)` | **E** (compiler/grammar surgery; runtime half is cheap) | No string-subscript grammar exists in `rom/exrom_v2_compiler.asm` at all — `TOK_KW_TO` (`:547`) is consumed only by `COMPILE_FOR`/`COMPILE_LINE`, no string-variable call site. | New lexer/parser production + new opcode needed. The VM-side copy, once parsed, would reuse MID$'s primitive (above) almost for free — the cost is concentrated entirely in the compiler grammar, not the runtime. |
| DATA/READ/RESTORE | **E** | No tokens anywhere, in V1 or V2 (never implemented in either dialect — not a V2 regression). REM's compile-time "skip to end-of-line, emit nothing" trick (`rom/exrom_v2_compiler.asm:4060-4133`) is the closest analog but solves only the *compile-time skip*, not RESTORE's runtime cursor. V2's bytecode-only execution model has **no retained pointer into original source text at runtime at all** — DATA/READ/RESTORE need a new compile-time literal-indexing pass, new VM cursor state, and RESTORE's reset/redirect logic. No partial infrastructure found beyond the unrelated REM trick. | Substantial new compiler pass + new VM state; the largest single item in this audit. |
| DRAW (relative-line/arc, "turtle" position) | **E** | No primitive, no "current position" state anywhere. `kernel/graphics/graphics.asm:1415` explicitly documents this as a deliberate design choice: V2's LINE takes absolute coordinates for both endpoints "deliberately not classic Sinclair BASIC's relative-only DRAW — no 'current position' to track." | New position-tracking state + relative-line/arc math needed; straight-segment portion could reuse `GFX_LINE`'s existing Bresenham core, but the position-tracking wrapper around it does not exist. |
| MERGE (load-and-combine into existing program) | **E** | `docs/v1/development_log.md:165-169`, `docs/v1/basic_language_reference.md:669`, `rom/test_basic.asm:328-332` all explicitly state MERGE "was not built" and remains "genuinely separate... still not built." No combine/append primitive found in `kernel/storage` or `memory.asm`; `V2_LOAD` (`rom/exrom_v2_shell.asm:745`) unconditionally replaces rather than merges. | Real new work: line-by-line merge-insert logic, not a thin wrapper. Not deliberately excluded by design — just never attempted in either dialect. |
| AYREG (raw AY register 0-15 poke) | **F** — implementation exists but is functionally redundant | Full implementation exists, `rom/extensions/ayreg.asm:45-64` (register 0-15 poke). But `SOUND` (`rom/exrom_sound.asm:33-49`) is already a direct disassembly-accurate port of the real ROM's SOUND, and already does unrestricted `out (PORT_AY_REG),a`/`out (PORT_AY_DATA),a` for any register 1-16 — amplitude, tone, noise (reg 6), mixer (reg 7), envelope (regs 11-13), the full raw register space, just off-by-one in numbering convention from AYREG. | Nothing AYREG offers that SOUND doesn't already expose. Safe to classify obsolete/redundant rather than port. |

## Package/service context (not gaps — confirms existing V2-native coverage)

- **MODE/SPRITE/PRINTER/SHAPES** are the four current production V2
  packages (R10 Section 6), each registering via `EXT2_REGISTER`,
  reached uniformly through `OP_CALL_EXT`/`EXT2_LOOKUP` — this is the
  living, correct V2-native extension mechanism that CPLOT/BLOCK/FRAME/
  INVERT/OUT would need porting *to*, and that CIRCLE (via SHAPES)
  already lives on.
- **AY hardware control**, previously marked UNCERTAIN in the stock
  matrix, is resolved by this audit: `SOUND`'s existing implementation
  already drives the full AY register space (not just simple tone) —
  this UNCERTAIN should be closed to PRESENT, richer than the matrix
  assumed. `kernel/sound/sound.asm` itself has zero AY code (only the
  beeper); all AY access lives in the EXROM `SOUND` command.

## Overlap and redundancy findings

- **AYREG ≈ SOUND.** AYREG's raw register-poke capability is a strict
  subset of what SOUND's existing register-poke implementation already
  does — restoring AYREG separately would duplicate SOUND, not add
  capability. This directly resolves the stock matrix's own AY-control
  UNCERTAIN in SOUND's favor.
- **CPLOT ≠ CIRCLE.** Confirmed unrelated despite the superficially
  similar naming — CPLOT is a coarse 64×48-grid block plotter (a V1
  convenience wrapper over the same pixel-write primitive PLOT uses),
  CIRCLE is the arc-drawing primitive from the stock gap list. No
  overlap; both are independently worth having for different reasons.
- **OUT (stock gap) ≈ OUT (deferred V1 extension).** These are the same
  underlying capability request, and the deferred V1 extension already
  contains a complete, tested implementation — a genuine convergence
  the two source lists didn't state explicitly.
- **BLOCK/FRAME/INVERT have no stock TS2068 BASIC counterpart at all** —
  they are V1-native additions (attribute-rectangle operations), not
  stock-compatibility items. Restoring them is a "cheap V2-native
  feature add," not a "compatibility gap fix" — a distinct kind of
  decision from the rest of this table (see Report item 5).

## Report

**1. Capabilities requiring only BASIC exposure (Class B):**
FLASH/BRIGHT/OVER/INVERSE, AT/TAB (as standalone statements), FREE,
VERIFY, CLEAR.

**2. Capabilities requiring a small adapter (Class C):**
COS, TAN (both calculator-reuse wrappers over existing SIN), ACS
(blocked on ASN), MID$ (reuses LEFT$/RIGHT$ primitive), CIRCLE (compiler
dispatch stub onto the already-EXT2-native SHAPES package), CPLOT,
BLOCK, FRAME, INVERT, OUT (all five: ABI-port from V1's extension
mechanism to V2's EXT2 — logic already correct, only the service-call
surface changes), IN (new module mirroring OUT's existing shape).

**3. Capabilities already supplied by packages (Class D):**
CIRCLE's algorithm, specifically, already lives inside the SHAPES
package (cross-referenced above as a C/D hybrid — the package exists,
only compiler wiring is missing). MODE/SPRITE/PRINTER/SHAPES themselves
are the general confirmation that the package mechanism is healthy and
already carries real capability.

**4. Capabilities requiring substantial new implementation (Class E):**
ASN, ATN, EXP, LN (each needs a genuinely new numerical algorithm — no
shared "one adapter covers all six trig/log/exp gaps" shortcut exists,
contrary to what a superficial reading of the gap list might suggest),
VAL$ (needs a reentrant expression evaluator), SCREEN$ (needs a full
bitmap-match algorithm and table from scratch), string slicing (needs
new compiler grammar; only the runtime copy is cheap), DATA/READ/RESTORE
(the single largest item — new compiler pass + new VM cursor state,
never built in either dialect), DRAW (needs new position-tracking state;
deliberately designed out of LINE), MERGE (never built in either
dialect, real line-merge logic required).

**5. Capabilities deliberately not worth restoring for compatibility
alone:**
AYREG is redundant with SOUND's existing full register access — not
worth porting under any framing. OUT and IN (raw port I/O) are a
genuine open policy question, not a cost question: both are cheap to
expose (Class C), but `out.asm`'s own header self-flags raw port access
as "intentionally low-level, advanced... the caller is responsible for
choosing a safe port" on what is otherwise a managed, bounds-checked
BASIC surface (fixed string slots, compile-time array sizes, etc.) —
whether that tension is acceptable is a product decision, explicitly
not resolved by this audit. BLOCK/FRAME/INVERT are cheap V1-extension
ports but have no stock-compatibility motivation at all (see Overlap
findings) — restoring them is a feature-add decision, not a
compatibility-gap fix, and should be weighed on that basis rather than
folded into "gap closure."

**6. Measured/estimated cost of every B/C candidate:** see the
Notes/cost column in the classification table above; no item was
merged or prototype-measured on the real build (per this audit's
read-only scope) — all figures are estimates derived from the actual
size of the closest existing analogous routine (INK/PAPER for
attribute setters, LEFT$/RIGHT$ for MID$, `BUILTIN_FN_ATTR`'s tail for
FREE, the existing `EXT2` package call-site convention for the six
deferred-extension ports).

**7. Surprising existing capabilities the R10 stock matrix made appear
wholly absent:**
- The six "deferred, not present in the tree" V1 extensions
  (CPLOT/AYREG/OUT/BLOCK/FRAME/INVERT) are in fact fully implemented,
  tested, and Makefile-wired — just on the old V1 ABI and outside the
  default build target. This is the single biggest correction this
  audit makes to R10's own record.
- CIRCLE's complete drawing algorithm is not gone — it was moved,
  unchanged, into the SHAPES package during a September 2026 ROM-budget
  commit, and R10's own Section 6 already lists SHAPES as a live
  production package without connecting the two facts.
- AY sound control is not merely "uncertain" — SOUND already drives the
  full raw AY register space, richer than the stock matrix's hedge
  suggested, and richer than the deferred AYREG extension it would have
  restored.
- FREE's entire computation already exists and is already labeled, in
  its own source comment, as backing BASIC's FREE() — it was never a
  missing capability, only a missing three-line wrapper.
- MID$'s absence looks like a bigger gap than it is: LEFT$ and RIGHT$
  already contain the exact generic byte-range-copy primitive MID$
  needs; only the start-offset argument differs.

## Explicitly out of scope for this audit (per instruction)

No feature was implemented, ported, or permanently merged. R10.5 ROM
optimization has not begun. This document is a decision input for R11
prioritization, not a prioritization decision itself — no item above
was picked or scheduled.

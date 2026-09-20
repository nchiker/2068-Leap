# 2068-Leap V2 — Language-Core ROM Analysis (Rewrite Feasibility Study)

Evidence classes follow project convention: `VERIFIED` (fresh build/measurement
this pass), `LIKELY` (strong local evidence, one check remains), `ESTIMATED`
(derived by calculation from VERIFIED numbers, shown with its formula),
`ASSUMED` (an explicit policy choice, not a measurement).

**Anchor commit: `77fdc1f`** (Phase 0 P0.3, "convert HIT() to a loadable RAM
extension function"). The live working tree has uncommitted changes to
`rom/exrom_checker.asm`, `basic/basic.asm`, `include/sysvars.inc`,
`kernel/memory/memory.asm` from concurrent CIRCLE+FILL bundling work — per
this study's brief, that in-progress tree was not used. Instead a detached
git worktree was checked out at `77fdc1f` and `make budget` was run there
cleanly. All numbers below are `VERIFIED` from that run unless marked
otherwise.

## Baseline measurement (`VERIFIED`, commit `77fdc1f`, fresh `make budget`)

```
Home ROM: 0x3ffe/0x4000 used, 2 bytes free
EXROM:    0xdf8c/0xe000 end, 116 bytes free
```

HOME: 16,382/16,384 used. EXROM: 8,076/8,192 used. Total used: 24,458/24,576.
**Total free today: 118 bytes** (2 HOME + 116 EXROM). Note this is a slightly
healthier snapshot than `CURRENT_LIMITATIONS.md`'s `942facb` figure (32 bytes
free total) — P0.3's HIT() extraction and other Phase-0 work already
recovered some room. It does not change this study's conclusions; both
figures represent "a full ROM with essentially no reserve."

## Per-module breakdown (`VERIFIED`, from `report_rom_map.py` at `77fdc1f`)

| Module | Bytes | Bank |
|---|---:|---|
| ROM driver, vectors and tables | 280 | HOME |
| `basic/basic.asm` | 11,369 | HOME |
| `kernel/memory/memory.asm` | 812 | HOME |
| `kernel/io/io.asm` | 504 | HOME |
| `kernel/graphics/graphics.asm` | 2,761 | HOME |
| `kernel/math/math.asm` | 403 | HOME |
| `kernel/sound/sound.asm` | 55 | HOME |
| `kernel/interrupt/interrupt.asm` | 144 | HOME |
| `kernel/bank/bank.asm` | 54 | HOME |
| `rom/exrom_checker.asm` | 1,860 | EXROM |
| `rom/exrom_storage.asm` | 927 | EXROM |
| `rom/exrom_format.asm` | 196 | EXROM |
| `rom/exrom_calc.asm` | 1,931 | EXROM |
| `rom/exrom_sound.asm` | 17 | EXROM |
| `rom/exrom_ulaplus.asm` | 83 | EXROM |
| `rom/exrom_sprite.asm` | 988 | EXROM |
| `rom/exrom_strfuncs.asm` | 383 | EXROM |
| `rom/exrom_editor.asm` | 730 | EXROM |
| `rom/exrom_input.asm` | 271 | EXROM |
| `rom/exrom_dim.asm` | 210 | EXROM |
| `rom/exrom_arrays.asm` | 71 | EXROM |
| `rom/exrom_highlight.asm` | 156 | EXROM |
| `rom/exrom_printer.asm` | 253 | EXROM |

## Classification: LANGUAGE CORE vs. V2 PLATFORM

**Language core** (tokenizer/parser/interpreter/expression-evaluator/
numeric-policy/symbol-handling/string-runtime/program-representation support —
the part the study asks us to consider replacing):

| Module | Bytes | Why language-core |
|---|---:|---|
| `basic/basic.asm` | 11,369 | The direct-execute-from-source interpreter itself: statement parsing, dispatch, expression evaluation, `DEF FN`, error raising, editor-integration glue |
| `rom/exrom_checker.asm` | 1,860 | Whole-program grammar validator — its keyword/grammar tables are a direct function of the language's syntax, would need re-authoring for any new grammar |
| `rom/exrom_strfuncs.asm` | 383 | String runtime (`LEN`/`MID$`/etc.) |
| `rom/exrom_dim.asm` | 210 | Array allocator — variable/symbol subsystem |
| `rom/exrom_arrays.asm` | 71 | Array element access — variable/symbol subsystem |
| **V1 language-core total** | **13,893** | |

**V2 platform** (mature hardware/environment functionality this study's brief
says should survive largely unchanged behind clean interfaces, regardless of
which language core sits on top):

| Module | Bytes | Why platform |
|---|---:|---|
| ROM driver/vectors/tables | 280 | Startup/kernel |
| `kernel/memory/memory.asm` | 812 | Dynamic pool allocator — reused by any design (already the target `STRING_AND_SYMBOL_DESIGN.md` and this study both build on) |
| `kernel/io/io.asm` | 504 | Keyboard/low-level I/O |
| `kernel/graphics/graphics.asm` | 2,761 | Display/graphics primitives |
| `kernel/math/math.asm` | 403 | `MATH_UMUL16`/`MATH_UDIV16` — integer primitives every architecture's fast path calls |
| `kernel/sound/sound.asm` | 55 | AY/BEEP primitives |
| `kernel/interrupt/interrupt.asm` | 144 | Interrupt handling |
| `kernel/bank/bank.asm` | 54 | EXROM paging |
| `rom/exrom_storage.asm` | 927 | Cassette/tape I/O |
| `rom/exrom_format.asm` | 196 | Number formatting for `PRINT`/tape |
| `rom/exrom_calc.asm` | 1,931 | The Sinclair-derived float calculator engine — every document in this project's Phase 1/2 corpus and this study's own architecture comparison recommends reusing this regardless of language-core design ("reuse the calculator" is the one point of unanimous agreement across `NUMERIC_DESIGN.md`, `ARCHITECTURE_COMPARISON.md`, and 2068-Forth's independent corroboration) |
| `rom/exrom_sound.asm` | 17 | Sound extension glue |
| `rom/exrom_ulaplus.asm` | 83 | ULAPlus hardware support |
| `rom/exrom_sprite.asm` | 988 | Sprite engine |
| `rom/exrom_editor.asm` | 730 | Full-screen editor engine — independently confirmed (`ARCHITECTURE_COMPARISON.md`/`V2_ARCHITECTURE.md`) to have zero calls into interpreter internals |
| `rom/exrom_input.asm` | 271 | Keyboard/joystick input handling |
| `rom/exrom_highlight.asm` | 156 | Editor syntax highlighting |
| `rom/exrom_printer.asm` | 253 | `LPRINT`/`LLIST` |
| **V2 platform total** | **10,565** | |

Sanity check: 13,893 + 10,565 = 24,458 = total ROM used at `77fdc1f`. ✓.

## Overhead that would disappear in a from-scratch rewrite

`basic.asm`'s 11,369 bytes conflate two things that a compile-once
architecture separates:

1. **Syntax recognition per statement** — parsing `PLOT x,y`'s argument
   list, `FOR I=1 TO N STEP S`'s clauses, etc. This cost does **not**
   disappear in a rewrite; it moves from the interpreter to a compiler,
   which must recognize the same syntax. It is currently paid **twice** in
   V1: once by `exrom_checker.asm` (validate-only, 1,860 bytes) and again,
   inline, inside `basic.asm`'s direct-execute handlers (re-parsed from text
   on every single execution of every statement — the mechanism
   `CURRENT_LIMITATIONS.md` and `PERFORMANCE_BASELINE.md` identify as the
   GOTO-loop performance cliff). A compile-once design collapses this to
   **one** pass (the compiler, which both validates and emits), amortized
   over the whole program's lifetime rather than paid on every execution.
2. **Dispatch-and-act glue** — calling into `kernel/graphics`,
   `kernel/sound`, `exrom_sprite`, etc. once syntax is recognized. In a
   bytecode VM this becomes a small number of generic "native call"
   opcodes (measured ~12-15 bytes each, see `REWRITE_VM_DESIGN.md`) instead
   of one bespoke handler per statement.

This is the structural basis for this study's central finding: replacing the
language core is not "the same code moved elsewhere" — the double-payment
for syntax recognition (checker + interpreter) is genuinely eliminable,
which V1's own Phase 2 evidence (`E14`, "checker/exec dispatch-table
duplication is structurally necessary... only the per-keyword handler
pointers differ") already flags as unavoidable *for the current
architecture specifically*, not as a law of nature.

See `REWRITE_VM_DESIGN.md` and `REWRITE_ROM_BUDGET.md` for the measured/
estimated size of the replacement, and `REWRITE_COMPARISON.md` for the full
side-by-side table.

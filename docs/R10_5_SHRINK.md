# R10.5 — dedicated ROM shrink/optimization

Date: 2026-09-27. Baseline: `c420918` ("R10.25: read-only capability
exposure/reuse audit"), confirmed clean working tree. This milestone
changes zero BASIC behavior and implements zero features — in
particular, none of `docs/R10_25_CAPABILITY_EXPOSURE_AUDIT.md`'s
audited capability gaps (FREE, CLEAR, VERIFY, attributes, AT/TAB,
COS/TAN, MID$, CIRCLE exposure, extension ports, OUT/IN, larger
capacities) were touched. Every change below is a byte-identical-
behavior source transformation, verified against a fresh build after
each step.

## Baseline confirmation

Reproduced exactly before any change, from `c420918`:

- `make check`: pass.
- `make test`: pass — 9/9 smoke, 2/2 editor flows, 11/11 storage cases,
  **18/18 V2 standalone** (`arrays`, `block_if`, `decompiler`,
  `for_nested`, `for_step`, `group6_math`, `input`, `mode_module`,
  `printer_module`, `proc_recursion`, `relational`, `save_load`,
  `sqr_decomp`, `strfuncs`, `r10_numeric`, `deffn`, `ext_demo`,
  `vm_milestone01`).
- `make budget`: **HOME 15,201/16,384 used, 1,183 free; EXROM
  5,864/8,192 used, 2,328 free.**
- `make v2-packages`: pass — MODE 165, SPRITE 832, PRINTER 345, SHAPES
  762 payload bytes (unchanged throughout this milestone, confirming no
  package logic was touched).

## Method

Followed the `z80-skills` shrink-z80 methodology: SAFE-lane evidence
first (duplicate-sequence/n-gram scanning of the real current source,
byte-exact counting from fresh `sjasmplus` listings/symbol tables —
never estimated), one change at a time, full gate (`make
check`/`test`/`budget`/`v2-packages`, 18/18 V2 standalone) rerun after
each isolated change before moving to the next. No black-belt/
experimental technique was needed — every accepted candidate is a
plain dedup or a mechanical `jp`→`jr` downgrade with a range-checked,
build-confirmed displacement.

Attack order followed the priority given: HOME first (both of the two
largest HOME files, `rom/exrom_v2_vm_core.asm` and
`rom/exrom_v2_compiler.asm`, were the biggest single contributors to
every win below), then total ROM, with zero speed/ROM tradeoffs — every
change here is either exactly speed-neutral (mechanical `jp`→`jr`) or
trades one extra `call`/`ret` pair for many fewer duplicated bytes on
cold, non-hot-loop paths (arithmetic-opcode dispatch and compile-time
label/fixup patching, not the VM's per-instruction fetch loop).

## Changes applied

### 1. `jp`→`jr` downgrade, pass 1 (44 sites, exact 1 byte each)

A displacement-range scan of the real `build/test_basic.lst`/
`build/exrom.lst` listings against `build/test_basic.sym`/
`build/exrom.sym` found every unconditional `jp target` whose target
lies within `jr`'s ±127-byte range. All 44 in-range sites were
converted; every other `jp` to the same target names (e.g. the many
out-of-range `jp VM_ERR_COMMON`/`jp EMIT_BYTE` call sites elsewhere in
the same files) was left untouched, confirmed by re-deriving file:line
from the listing's own per-file line counters, not by blind
find/replace.

| File | Target(s) | Sites | Bytes |
|---|---|---:|---:|
| `kernel/graphics/graphics.asm:2207,2235` | `GFX_SPRITE_TRANSFER` | 2 | 2 |
| `kernel/math/math.asm:218,242` | `MATH_APPLY_SIGN` | 2 | 2 |
| `rom/exrom_v2_vm_core.asm:1047` | `VM_STORE_VAR_BY_INDEX` | 1 | 1 |
| `rom/exrom_v2_vm_core.asm:3049` | `VM_PRINT_COMMON` | 1 | 1 |
| `rom/exrom_v2_vm_core.asm:4250-4290` (11 sites) | `VM_ERR_COMMON` | 11 | 11 |
| `rom/exrom_v2_compiler.asm:779` | `LEX_SCAN_NUMBER` | 1 | 1 |
| `rom/exrom_v2_compiler.asm:1417-1435` (19 sites) | `EMIT_BYTE` | 19 | 19 |
| `rom/exrom_v2_compiler.asm:3224-3232` (3 sites) | `COMPILE_1ARG_STMT` | 3 | 3 |
| `rom/exrom_v2_compiler.asm:4637` | `COMPILE_RAISE_ERROR` | 1 | 1 |
| `rom/exrom_editor.asm:140,178` | `EDITOR_LOOP` | 2 | 2 |
| `rom/exrom_v2_shell.asm:229` | `V2_LOAD_EDIT` | 1 | 1 |

**41 bytes HOME, 3 bytes EXROM.** Confirmed by rebuild: HOME free
1,183→1,224; EXROM free 2,328→2,331 — an exact match to the count.
`make check`/`v2-packages` pass; full `make test` (18/18 V2 standalone)
confirmed green on this change in isolation.

### 2. `OP_ADD`/`OP_SUB`/`OP_MUL`/`OP_DIV` shared prologue + FLOAT-path body

`rom/exrom_v2_vm_core.asm` (HOME). These four opcodes each open with an
identical 10-instruction pop/tag-check prologue (`call VM_POP` ×2 +
tag-store + `or c` + `jr nz,.float_path`), and three of them
(ADD/SUB/MUL, plus DIV's own `.float_path`) close with a near-identical
14-15 instruction "push both operands through the calculator, call the
op-specific `CALC_*_STUB`, store the result, return to the VM loop"
tail differing only in which stub is called.

Factored into two new shared routines:

- **`VM_PREPARE_BINARY_OPERANDS`** — the shared prologue (`call VM_POP`
  ×2, tag compare, `ret` with Z flag preserved across the `ret` for the
  caller's own `jr nz,.float_path` — Z80's `ret` does not touch flags,
  confirmed before relying on it).
- **`VM_FLOAT_BINARY_COMMON`** — the shared FLOAT-path tail. Takes the
  op-specific `CALC_*_STUB` address in `HL` and reaches it via the
  existing `VM_CALL_USR_TRAMPOLINE` (`jp (hl)`, `rom/
  exrom_v2_vm_core.asm`, originally written for `BUILTIN_FN_USR`) —
  `call VM_CALL_USR_TRAMPOLINE` with the stub address in `HL` behaves
  as an indirect call: the trampoline's `jp (hl)` transfers control
  without pushing a new return address, so the stub's own `ret` pops
  the address `VM_FLOAT_BINARY_COMMON`'s own `call` pushed, returning
  control there. No new indirect-call primitive needed; this reuses an
  existing, already-tested one-instruction routine.

Each opcode's body shrank to its int-fast-path plus a two-instruction
tail (`ld hl,VM_CALC_*_STUB` / `jp VM_FLOAT_BINARY_COMMON`); `OP_DIV`
additionally keeps its own zero-check ahead of the shared tail. No
flag, register, or ordering change: `VM_PREPARE_BINARY_OPERANDS`
reproduces the exact original instruction sequence, just call-boundary-
split; `VM_FLOAT_BINARY_COMMON` reproduces the exact original operand-
push/stub-call/store/return sequence for every one of its four callers.

**159 bytes HOME** (`rom/exrom_v2_vm_core.asm`: 4,844→4,685 bytes,
exact). Verified in isolation: `make check`/`budget`/`v2-packages`
pass, then a full `make test` run (18/18 V2 standalone, including
`r10_numeric` and `group6_math`, the two tests most likely to catch an
arithmetic regression) passed clean before any further change was
layered on.

### 3. `COMPILE_RELATIVE_OFFSET` — shared "current bytecode position" helper

`rom/exrom_v2_compiler.asm` (HOME). Nine call sites (label/fixup-
address patching in `LABEL_DEFINE`, `COMPILE_IF_BLOCK`'s
then/else-skip patches, `COMPILE_FOR`'s loop-top/exit offsets,
`COMPILE_PROC`/`COMPILE_DEFFN`'s skip-jump patches) each independently
computed `EMIT_PTR - VM_CODE_BASE` via the identical four-instruction
sequence `ld hl,(EMIT_PTR)` / `ld de,VM_CODE_BASE` / `or a` / `sbc
hl,de`. None of the nine sites branch on the resulting flags — every
one immediately uses the `HL` (and sometimes, via the site's own
already-present `ex de,hl`, `DE`) value — so the sequence could be
call-boundary-split without changing behavior. Factored into a single
`COMPILE_RELATIVE_OFFSET: ld hl,(EMIT_PTR) / ld de,VM_CODE_BASE / or a
/ sbc hl,de / ret`; all nine sites now `call` it, keeping each site's
own original trailing comment.

Sites: `rom/exrom_v2_compiler.asm` (pre-edit line numbers) 2973, 3578,
3655, 3687, 3700, 3796, 3920, 4383, 4546.

**44 bytes HOME** (`rom/exrom_v2_compiler.asm`: 5,693→5,649 bytes,
exact). Verified: `make check`/`budget`/`v2-packages` pass; a combined
`make test` run (with change #2 also present) passed 18/18 V2
standalone clean.

### 4. `VM_DIV_VIA_FLOAT` — shared integer-pair-to-FLOAT division tail

`rom/exrom_v2_vm_core.asm` (HOME). Three call sites — `OP_DIV`'s own
inexact-quotient fallback, and two other opcodes that divide a pair of
plain `VM_FLOAT_A_VAL`/`VM_FLOAT_B_VAL` INT16s through the calculator
to force a FLOAT result — shared an identical nine-instruction tail
(`xor a` / clear `CALC_SP` / convert both operands via
`CALC_INT_TO_FP` / `call VM_CALC_DIV_STUB` / `call
VM_FLOAT_STORE_RESULT` / `jp VM_RUN.loop`). Factored into
`VM_DIV_VIA_FLOAT`, defined once beside `VM_CALC_DIV_STUB`; all three
sites now tail-jump to it (`jp VM_DIV_VIA_FLOAT`) instead of repeating
the sequence, since none needed to return to their own call site
afterward (the original tail always ended in `jp VM_RUN.loop`).

Sites: `rom/exrom_v2_vm_core.asm` (post-change-#2 line numbers) 1614
(`OP_DIV.inexact`), 2505, 3513.

**41 bytes HOME.** Verified: `make check`/`budget`/`v2-packages` pass;
full `make test` (18/18 V2 standalone) passed clean.

### 5. `jp`→`jr` downgrade, pass 2 (6 further sites, opened up by #2-#4)

Changes #2-#4 moved code closer together, bringing 6 more previously
out-of-range `jp` instructions into `jr` range — confirmed by rescanning
the fresh post-change listings/symbol tables the same way as pass 1,
not assumed from the pass-1 list.

| File | Target | Sites | Bytes |
|---|---|---:|---:|
| `rom/exrom_v2_vm_core.asm:1520,1546` | `VM_FLOAT_BINARY_COMMON` | 2 | 2 |
| `rom/exrom_v2_compiler.asm:1436-1439` | `EMIT_BYTE` | 4 | 4 |

**6 bytes HOME.** A final rescan after this pass found zero further
in-range candidates in either bank.

## Considered and rejected (documented, not applied)

- **Four near-identical symbol-table linear-scan routines**
  (`CSYM_FIND_OR_CREATE`, `STRSYM_FIND_OR_CREATE`, `ARRSYM_LOOKUP`,
  `LABEL_LOOKUP`, all in `rom/exrom_v2_compiler.asm`) share an ~25-30
  line scan-loop skeleton (walk index 0..COUNT, compare stored
  name_len then name bytes) differing only in which COUNT variable,
  entry-address routine, and per-table scratch cells (`CSYM_FIND_NAME_
  PTR` vs `STRSYM_FIND_NAME_PTR` vs `ARRSYM_FIND_NAME_PTR` vs
  `LABEL_FIND_NAME_PTR`) each uses. A generic, parametrized scan routine
  is plausible (likely on the order of 60-100+ bytes, ESTIMADO, not
  measured) but would require either sharing one scratch-cell pair
  across all four tables (needs an audit that no call path nests two
  of these lookups before the first completes — plausible for a
  single-pass recursive-descent compiler, but not verified this
  milestone) or an indirect-call parameterization scheme per table
  (entry-address routine address passed in a register, mirroring this
  milestone's `VM_CALL_USR_TRAMPOLINE` reuse). Flagged as a real,
  larger "arch" candidate for a dedicated follow-up pass, not attempted
  here given the higher verification cost and this milestone's
  incremental-isolation discipline.
- **`rom/exrom_v2_shell.asm` `V2_LIST`/redraw-loop shared 6-instruction
  span** (`call V2_COPY_RECORD` / `ld hl,DETOK_BUF` / `call
  V2_KW_DETECT_SPANS` / `ld a,1` / `ld (V2_DRAW_BOLD_ENABLE),a` / `ld
  hl,DETOK_BUF`, appearing at `V2_LIST`'s loop body and
  `V2_REDRAW_PROGRAM`'s `.settled:` block) — EXACTO 17 bytes ×2 sites,
  factoring to ~11 bytes net. Not applied: EXROM already has ample free
  space (2,331/8,192) relative to HOME's tighter margin, and an 11-byte
  win did not justify another full ~5-8 minute real-ZEsarUX `make test`
  verification round trip at the point this was found, per this
  milestone's own priority order (HOME first, then total ROM,
  correctness-verification cost considered). Left as a documented,
  measured candidate for whenever EXROM work is next touched.

No dead code was found or removed — `docs/R10_AUDIT_AND_CLEANUP.md`
Section 4 already established the production include set is clean, and
this milestone's own read-only scans over the same production file set
found nothing to add to that finding.

## Final numbers

| | HOME used | HOME free | EXROM used | EXROM free |
|---|---:|---:|---:|---:|
| Baseline (`c420918`) | 15,201 | 1,183 | 5,864 | 2,328 |
| After change 1 | 15,160 | 1,224 | 5,861 | 2,331 |
| After change 2 | 15,001 | 1,383 | 5,861 | 2,331 |
| After change 3 | 14,957 | 1,427 | 5,861 | 2,331 |
| After change 4 | 14,916 | 1,468 | 5,861 | 2,331 |
| After change 5 (final) | **14,910** | **1,474** | **5,861** | **2,331** |

**Total recovered: 291 bytes HOME, 3 bytes EXROM, 294 bytes combined.**
100% of it landed in HOME ROM (this milestone's stated first priority)
except the 3 EXROM bytes from pass-1's `jp`→`jr` downgrades, which cost
nothing to also take. No speed/ROM tradeoff was made anywhere: all
`jp`→`jr` conversions are exactly speed-neutral (same semantics, one
byte narrower), and all four dedups replace duplicated inline code on
compile-time/cold arithmetic-dispatch paths with one extra `call`/`ret`
or `call`/indirect-`jp` pair — not the VM's hot per-instruction fetch
loop (`VM_RUN.loop` itself, `OP_JMP`, `VM_POP`/`VM_PUSH` were not
touched).

## Final verification

Reproduced from the final tree, matching the baseline gate exactly:

- `make check`: pass (0 errors, 0 warnings).
- `make budget`: pass — figures in the table above.
- `make v2-packages`: pass — MODE 165, SPRITE 832, PRINTER 345, SHAPES
  762 payload bytes, byte-identical to the baseline (confirming no
  package source was touched).
- `make test`: pass — 9/9 smoke, 2/2 editor flows, 11/11 storage
  cases, **18/18 V2 standalone** (same 18 tests as the baseline list
  above, all green-border PASS in real ZEsarUX), exit code 0.

No BASIC-visible behavior changed. No feature was implemented, ported,
or exposed. R10.25's capability items remain entirely untouched and
available for R11 prioritization as that document already lays out.

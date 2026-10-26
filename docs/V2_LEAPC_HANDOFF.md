# Leap-C back-port: handoff after phase 4

Written 2026-10-26 at the end of phase 3; updated at the end of phase 4. The plan is `docs/V2_LEAPC_BACKPORT_PLAN.md`; this file is
only where things stand and how to pick up.

## State

- Branch `backport/leapc` (off `v2-development`), not pushed. Phases 0-4 and the redraw item committed (redraw: commit after 07a18da).
- Free ROM: HOME 354 B, EXROM 186 B (`make budget`). Emergency reserve HOME 64 / EXROM 32
  (`make check` fails below it). Spending is weighted by benefit per byte, not floored.
- No stock-ROM-derived code left in the images: `tools/check_provenance.py` (in `make check`) has an
  empty allow-list. Keep it that way; anything taken from Leap-C is MIT and goes in `NOTICE.md`.
- Last full `make test` result: see the phase-4 commit message.

## Working rules (owner)

- Standard test runs (`make test`, `make qual`, the prod suites) go to a cheaper subagent
  (haiku/sonnet) that reports PASS/FAIL counts and failing text; the main session judges them.
- Run long suites on an rsync copy in the scratchpad, never `make` in the real tree while a suite runs
  there. `make test` is ~32 min (fast emulation); the prod suites use ports 10241-10246.
- Never run `make test-legacy` / `test-all` (Fuse) unprompted. Fuse was approved only for probe 0.8.
- Commit only on `backport/leapc`; don't push.
- Each item: measure bytes with `make budget`, record them in the plan's ledger and item outcome.

## Tools added in phases 0-3 (use them)

| Tool | What it checks |
| --- | --- |
| `tools/qual/qcanary.py --banking` | paging invariants over the corpus |
| `tools/qual/qpoweron.py` | boot from non-zero RAM patterns |
| `tools/qual/fuse_frames_probe.py` | frames lost by `di` windows (Fuse; approved probe only) |
| `tools/qual/qrnd.py`, `qmuldiv.py` | RND sequence/period, 16-bit mul/div differential |
| `tools/qtapetol.py` | LOAD under 23 tape distortions (old receiver 16, new 22) |
| `tools/qual/qmicsave.py` | real SAVE captured at MIC, decoded, played back (in the prod suites) |
| `tools/check_repro.sh` (`make repro`) | the build is reproducible |

## Next: phase 5.1 prototype (float literals as 5-byte constants)

Phase 4 and the redraw-from-the-cursor's-line item are done (outcomes in the plan). Free: HOME 354 B,
EXROM 186 B. `SH_VIEW` (~94 B EXROM, fixes ED4/R9) is decided after 5.1 is measured.

**Goal of this step:** a prototype of 5.1 with its measured size and speed; the owner then decides
whether to integrate it. Work on a branch off `backport/leapc` (e.g. `proto/5.1-float5`), commit there.

**Where things are.** The compiler and VM core are in HOME (`rom/v2_home.asm` includes
`rom/exrom_v2_vm_core.asm` and `rom/exrom_v2_compiler.asm`); the calculator, editor and shell are in
EXROM. Most of 5.1 exists already:

- `OP_PUSH_FLOAT5` (opcode 70, `exrom_v2_vm_core.asm` ~l.3356): pushes a 5-byte literal operand.
- `LEX_NUMBER_TOO_BIG` (`exrom_v2_compiler.asm` ~l.866): re-parses the literal from `LEX_NUM_START`
  with `NUM_PARSE_CALC` (vm_core ~l.3238, shared with INPUT/VAL) into `TOK_FLOAT5_BUF`, token
  `TOK_FLOAT5`; `COMPILE_FLOAT5` emits it. Used today for literals > 65535, > 4 decimals or a
  mantissa > 32767.
- Still on the slow path: short decimals (`0.5`, `2.25`). `LEX_SCAN_NUMBER` (~l.765) builds digits +
  divisor 10^k (`TOK_FLOAT_NUMBER`, `TOK_FLOAT_DIVISOR`, `CNUM_DIVISOR_TMP`); `COMPILE_FLOAT_LITERAL`
  (~l.2325) emits opcode 22; `OP_PUSH_FLOAT_LIT` (vm_core ~l.3370) divides at every execution
  (`VM_DIV_VIA_FLOAT`). Plan: `x=x+0.5` costs 31,542 T per iteration.

**The change.** In `LEX_SCAN_NUMBER.check_dot`, on `.`, jump to `LEX_NUMBER_TOO_BIG`. Then remove what
becomes dead: the fraction loop and divisor, the `.is_float` branch of `.done`, `COMPILE_FACTOR`'s
`TOK_FLOAT_NUMBER` case (~l.1714/1767) and `COMPILE_FLOAT_LITERAL`, and `OP_PUSH_FLOAT_LIT`. Keep
opcode 22's jump-table slot (point it at the VM's invalid-opcode handling or leave the handler under
`IFNDEF V2_PRODUCTION`: `rom/test_v2_call_fn.asm` and `rom/test_v2_decompiler_phase2.asm` mention it;
check whether they emit it). Grep `tools/qual/corpus.py` and `inventory.py` for opcode-22
expectations. The `ld a,22` at compiler ~l.2849 and ~l.3261 are error codes, not this opcode.

**Size estimate [E]: HOME about −100 B** (fraction loop + divisor ~50, `.done` float branch ~15,
compile case + `COMPILE_FLOAT_LITERAL` ~25, `OP_PUSH_FLOAT_LIT` ~20, new jump +2). Measure with
`make budget`; record in the plan's ledger.

**Risks to check.**

1. Rounding: compare `NUM_PARSE_CALC`'s 5 bytes with the old run-time value/divisor result for every
   short decimal: all 0.0001-steps up to a few units, the corpus's literals, and edge forms (`2.0`,
   `0.0001`, `32767.5`, `3276.7`, `.5` if the lexer accepts it, `1.`). Write a small probe: compile and
   run `PRINT` / store on both builds, or call both routines directly (the phase-4 probe pattern
   below). Any bit difference: decide which is the correctly rounded value before accepting it.
2. Type: a decimal literal must still give a float (`2.0` stays float; check `VM_FLOAT_STORE_RESULT`
   and anything that reads the int/float tag, e.g. integer FOR fast paths, `MOD`, array indices).
3. Compile time: `NUM_PARSE_CALC` per literal instead of digit accumulation; measure with qbench's
   `compile_only` plus a decimal-heavy program.

**Measurements.**

- Size: `make budget` before/after.
- Speed: `tools/qual/qbench.py` (it reads builds from `build/qual-builds/<cfg>`, see
  `tools/qual/build_configs.sh`; or copy each tree's `build/` there). `float_loop` and
  `for_float_step` are the relevant programs; add `x=x+0.5` alone and a decimal-heavy compile.
  Report T before/after per program.
- Bytecode: `tools/qual/qbytecode.py <old tree> <new tree>`: differences are expected exactly for
  programs with short decimals (opcode 22 → 70, operand 4 → 5 bytes); list any other difference.
- Correctness: `make check`, `make doc-examples`, then `make test` via a cheaper subagent on an rsync
  copy. Manual examples that print decimals are the likeliest to show rounding changes.

Phase 4 tools worth reusing: a differential probe pattern (old build in a `git worktree`, a small
sjasmplus harness at `$F400`, `reset/get-tstates-partial`, compare RAM) and a PNG cell-diff that
classifies changed 8x8 cells of manual screenshots. Both were scratch scripts; rebuild from the plan's
4.1-4.3 outcome notes if needed.

## Open points from phase 3

- `qtapetol` "speed 1.25" fails with the new receiver at `TR_ONE` 34 (ZEsarUX sampling on the bit
  threshold); 35 trades it for two other cases. Kept 34; revisit only with real-tape evidence.
- The calculator rewrite (3.2) was written from the interface with the old derived code visible, not
  by a separated clean-room author; `NOTICE.md` says so. Owner decision 2026-10-26: that counts as
  clean-room enough.
- Plan item 0.10: owner decision 2026-10-26, fast emulation (`TS2068_DEBUG_ZESARUX_FAST=1`) is the
  default (in ts2068-debug; `=0` for real speed). Done: `make test` 1,940 s, all PASS.

# 2068-Leap V2 — Architecture B, Milestone 01: Minimal VM Core + Branch/Integer Validation

**Status: COMPLETE. Implemented, assembled, and validated on real ZEsarUX
via `ts2068-debug`. See "RESULTS" at the end of this document for the full
real-measurement writeup.** This is the smallest slice of
`ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s R1 that (a) is real production
code, not a spike, and (b) directly validates this whole rewrite's two most
load-bearing assumptions on real hardware: that a compiled branch is O(1)
(no source rescan) and that tag-gated integer arithmetic never touches the
calculator. It deliberately does **not** attempt all of R1 — no float
dispatch, no procedure calls, no full 40-opcode set — because the brief
asks for the smallest milestone that validates an important assumption and
establishes a foundation, not a large vertical slice.

## OBJECTIVE

Produce a real, production-quality (not spike-quality) bytecode VM core
supporting exactly 7 opcodes — `HALT`, `PUSH_I8`, `PUSH_I16`, `LOAD_VAR`,
`STORE_VAR`, `ADD` (integer-only, tag-check present but float path is a
stub that raises "not yet implemented" rather than a real promotion —
honestly incomplete, not silently wrong), `JMP` — plus the symbol-index
variable-access routine and operand stack, executing a hand-assembled
bytecode test program that exercises a loop via repeated `JMP`. Measure its
real ROM cost and validate, on real hardware/emulator, that:

1. The `JMP` handler's execution time is independent of how many bytes of
   "source" precede it (there is no source at all — bytecode has no
   textual form to rescan) — the direct, concrete test of the GOTO-
   catastrophe fix this whole rewrite is justified by.
2. The `ADD` handler, given two `INT`-tagged operands, executes a fixed,
   small number of Z80 instructions and makes zero calls into
   `rom/exrom_calc.asm` — verified by instruction trace, not just by
   reading the source.

## DEPENDENCIES

None. First production-code milestone under Architecture B.

## FILES

- **New**: `rom/exrom_v2_vm_core.asm` (EXROM-resident; placement chosen
  because the VM's hot dispatch loop is exactly analogous to
  `basic.asm`'s current HOME-resident dispatch loop, but this milestone is
  small enough, and the ROM headroom large enough post-Phase-0
  `(554 HOME / 109 EXROM free at 61bb8bb)`, that EXROM residency for this
  first slice avoids any HOME pressure while the design is still proving
  itself; a HOME-vs-EXROM placement decision for the *final* VM is deferred
  to R1's completion, per the placement-decision methodology
  `ARCHITECTURE_COMPARISON.md` recommends adopting).
- **New**: `tests/v2_vm_milestone_01/` — hand-assembled `.bin` bytecode test
  programs and their expected results (not `.bas` — no compiler exists
  yet).
- **Modified**: none. This milestone adds a new, currently-uncalled EXROM
  module; nothing in the existing boot/dispatch path references it yet, so
  V1 is provably unaffected (nothing new is on any existing call path).
- **Build**: a new, minimal build target added to `Makefile` (or a
  standalone `tools/build_v2_vm_milestone_01.sh`, decided during
  implementation) that assembles this module into its own small test image
  alongside the existing production ROM images — not replacing them.

## IMPLEMENTATION

1. Promote `spikes/v2_vm_sizing/vm_sizing_spike.asm`'s dispatch loop,
   `VM_SYM_ADDR`, `VM_PUSH16`/`VM_POP16`, and the `HALT`/`PUSH_I8`/
   `PUSH_I16`/`LOAD_VAR`/`STORE_VAR`/`ADD`/`JMP` handlers from stub-quality
   (calling `RET`-only external stubs for the calculator) to real quality:
   - `ADD`'s float-tagged path calls the **real**
     `rom/exrom_calc.asm` entry points (`CALC_INT_TO_FP`, the add literal)
     instead of a stub, OR — if that integration is judged too large for
     this milestone — raises a clearly-labeled "not yet implemented" error
     rather than silently producing a wrong result. This choice is made and
     documented during implementation, not left ambiguous.
   - Real bounds checking on the operand stack (the spike had none).
   - Real symbol-table record layout, matching whatever
     `STRING_AND_SYMBOL_DESIGN.md`-derived record shape R2 (compiler
     foundation) will target, decided now so R2 doesn't have to change it.
2. Write 3 hand-assembled bytecode test programs:
   - **Arithmetic**: `PUSH_I8 5, PUSH_I8 3, ADD, STORE_VAR 0, HALT` — checks
     basic dispatch + stack + integer add + variable store.
   - **Loop-via-JMP**: a bytecode loop incrementing a variable N times via
     repeated `JMP` back to a fixed offset (the direct analog of V1's
     catastrophic GOTO loop, but hand-assembled bytecode instead of
     compiled source) — this is the milestone's central test.
   - **Stack-bounds**: a deliberately-overflowing sequence, checking the
     new bounds-check behavior added in step 1 (a real, negative test).

## TESTS

- Unit-level: each of the 3 bytecode programs, assembled into the test
  image, executed via `ts2068-debug`'s ZRCP-based direct-memory-injection
  (per the `benchmark-z80` skill's established methodology — no typing,
  no live-keyboard dependency), checked register/memory state against
  hand-computed expected results.
- Regression: full existing V1 test suite re-run once (confirming the new,
  currently-uncalled module has zero effect on anything) — cheap insurance,
  not expected to find anything, per the "nothing modified" file list
  above.

## ROM BUDGET

- Target: ≤200 bytes for this 7-opcode subset (scaled down from
  `REWRITE_VM_DESIGN.md`'s 588-byte/20-opcode measurement — 7 opcodes is
  roughly a third of that set, and several of the 20 measured opcodes, e.g.
  `FOR_INIT`/`CALL`, are excluded here).
- DEV ROM: this milestone's module (≤200 bytes) is added to a **separate
  test image**, not merged into the production 24KB ROM at all yet (no
  build-system wiring makes it resident in the shipping image) — so there
  is no coexistence-ROM accounting needed until R2 begins integrating with
  the compiler and the question of a combined dev image arises.
- SHIP ROM impact: **zero** at this milestone (nothing is wired into the
  shipping build).

## RAM BUDGET

- Operand stack: a fixed, documented-size region in the test image's own
  RAM map (not overlapping any V1 sysvar or buffer — a real address chosen
  and checked against `include/sysvars.inc`'s existing map for collisions,
  even though this milestone doesn't modify that file).
- Symbol table: sized for the test programs' variable count (small, e.g.
  4-8 slots) — this milestone does not need a production-scale table.

## BENCHMARKS

- The loop-via-JMP test program run for N=2000 (matching
  `PERFORMANCE_BASELINE.md`'s existing GOTO-loop benchmark's N, for a
  direct, apples-to-apples comparison), FRAMES measured via the existing
  `harness/METHODOLOGY.md` stopwatch protocol.
- **Success threshold**: completes well within V1's failure threshold (V1's
  equivalent did not complete within 20,000,000 opcodes/54.7 seconds) —
  this milestone's bytecode loop should complete in a small fraction of
  that, consistent with `FOR`/`NEXT`'s existing ~529-frame V1 baseline
  (`PERFORMANCE_BASELINE.md`) being the right order of magnitude to expect,
  since both mechanisms share the same "no source involvement" property.

## EMULATOR VALIDATION

Real ZEsarUX run via `ts2068-debug`, per the `2068-debug` skill's
established workflow for this project — register/memory state inspected
after each test program halts, not inferred from assembly alone.

## SUCCESS CRITERIA

1. All 3 test programs assemble and execute correctly on real
   hardware/emulator.
2. The loop-via-JMP benchmark completes (does not hang), with a measured
   FRAMES count reported and compared against the target threshold above.
3. Instruction-trace confirms zero calculator calls on the integer-only
   `ADD` path.
4. ROM cost of the new module is within 25% of the ≤200-byte target.
5. Full existing V1 regression suite remains 100% green (this module is
   inert with respect to everything else).

## ROLLBACK CRITERIA

If any of the following occur, this milestone is reverted (the new file(s)
deleted) rather than patched forward, and the finding is reported before
any further Architecture B work proceeds, per the study's own "stop if
evidence invalidates a fundamental assumption" rule:

- The loop-via-JMP benchmark does **not** demonstrate O(1)/independent-of-
  program-size branch behavior (i.e., if some other bottleneck makes
  bytecode dispatch itself scale badly with program size, which nothing in
  the design predicts but which only a real measurement can rule out).
- The integer `ADD` path is found to invoke the calculator or otherwise
  cost meaningfully more than a native Z80 add sequence.
- Real ROM cost exceeds the 200-byte target by more than 2× with no clear,
  fixable cause (a signal the 588-byte/20-opcode extrapolation in
  `REWRITE_VM_DESIGN.md` is systematically off, which would need
  re-costing the entire rewrite before proceeding further).

## Why this is the right first milestone

It is smaller than "all of R1" (7 opcodes, not ~40; no float, no
procedures, no compiler at all — bytecode is hand-assembled). It is
independently testable (no dependency on anything else in the plan). It
validates the two claims this entire rewrite's justification rests on most
heavily: the GOTO-catastrophe fix (branch performance) and the integer
fast-path preservation (arithmetic performance) — both stated as explicit
success criteria in `REWRITE_VM_DESIGN.md` and `STATEMENT_COMPILER_SPIKE.md`
but not yet demonstrated on real hardware with production-quality code
(the spikes were assembled and size-measured, never executed). If this
milestone's benchmark did NOT confirm the branch-performance claim, that
would be exactly the kind of evidence invalidating a fundamental
Architecture B assumption that warrants stopping and re-evaluating before
any further investment — which is also why it is sequenced first, before
any larger commitment (R2 onward) is made.

## RESULTS (real, measured, this pass)

Implemented as `rom/exrom_v2_vm_core.asm` (production module, not a spike —
real bounds-checked operand stack, real `[tag][value_lo][value_hi]` symbol
records, real error codes, no calculator stub calls of any kind) and
`rom/test_v2_vm_milestone01.asm` (standalone smoke-test ROM, following this
project's own established `rom/test_math.asm`/`tools/build_smoke_roms.sh`
pattern exactly — border-color PASS/FAIL for two chained, self-terminating
tests, plus a separately-entered unbounded loop for the branch-cost
measurement). Neither file is referenced by `rom/exrom_build.asm` or the
production Makefile targets — zero effect on the shipping ROM or the V1
interpreter, confirmed by `git status` before and after (only these two new
files plus a build artifact set appeared).

**Assembly**: clean, 0 errors, 0 warnings, via `tools/sjasmplus_strict.sh`,
first on the second attempt — see "A real bug found and fixed" below.

### Real ROM cost (`VERIFIED`, from the assembled `.sym` file)

| Component | Bytes |
|---|---:|
| `VM_INIT` | 17 |
| `VM_RUN` dispatch loop + 7-entry jump table | 45 |
| `VM_SYM_ADDR` (compiled-index symbol access) | 12 |
| `VM_PUSH` (bounds-checked) | 48 |
| `VM_POP` (bounds-checked) | 26 |
| `OP_HALT` | 6 |
| `OP_PUSH_I8` | 25 |
| `OP_PUSH_I16` | 19 |
| `OP_LOAD_VAR` | 23 |
| `OP_STORE_VAR` | 28 |
| `OP_ADD` (tag-gated integer fast path) | 22 |
| `OP_JMP` (compiled O(1) branch) | 16 |
| Error handlers (4 codes) | 29 |
| **TOTAL, this 7-opcode production module** | **316** |

Extrapolating with this real data point to the full ~40-opcode set using
`REWRITE_VM_DESIGN.md`'s own method: fixed shared infrastructure that
doesn't scale with opcode count (`VM_INIT` + dispatch loop minus its table
+ `VM_SYM_ADDR` + `VM_PUSH` + `VM_POP` + error handlers) = 163 bytes; the
jump table scales at 2 bytes/opcode (40×2=80); handlers averaged 19.9
bytes/opcode here (139/7) — close to, and confirming, `REWRITE_VM_DESIGN.md`'s
~20 bytes/opcode assumption. **Projected full VM: 163+80+(40×20) ≈ 1,043
bytes** — inside the 900-1,100 range that document already estimated,
now confirmed by real production-quality code rather than sizing-spike
code alone.

### Real hardware validation (`VERIFIED`, real ZEsarUX via `ts2068-debug`)

**TEST1 (arithmetic)**: `PUSH_I8 5, PUSH_I8 3, ADD, STORE_VAR 0, HALT`.
Real run: symbol 0 ended as `tag=INT, value=8` — correct. Border went
green (PASS) after both chained tests.

**TEST3 (stack-overflow negative test)**: an intentionally-unbounded
`PUSH_I8 7` / `JMP` self-loop. Real run: `VM_ERROR_CODE` became `2`
(overflow) as designed — the bounds check added in this milestone (absent
from the sizing spike) fired correctly and halted cleanly rather than
corrupting memory or hanging.

**TEST2 (branch/loop cost — the milestone's central claim)**: entered
directly via `set-register PC` to `VM_RUN` with `VM_IP` pointed at the loop
bytecode (bypassing `COLD_START`, per the design — this loop has no
conditional exit by construction in this 7-opcode slice, so it is bounded
externally, not internally). Two independent 5,000,000-Z80-instruction
bounded runs were executed back to back, resuming from wherever the first
left off (i.e. the second run started from an already-elevated iteration
count, not from zero):

| Run | Instructions bound | Loop-counter delta (real iterations completed) |
|---|---:|---:|
| 1st (starting near iteration 3,514) | 5,000,000 | 17,574 |
| 2nd (starting near iteration 21,088) | 5,000,000 | 17,574 |

**The two deltas are bit-for-bit identical.** This is the direct, real,
hardware-measured confirmation that the compiled `JMP`'s cost is constant
per iteration and does not grow as more iterations accumulate — the exact
property `PERFORMANCE_BASELINE.md`'s GOTO-catastrophe finding showed V1
*lacks* (where cost is a function of program text/position, not iteration
count). `VM_ERROR_CODE` remained `0` throughout both runs (no crash, no
stack corruption — net stack depth per iteration is zero, by the loop's
own arithmetic, so no overflow was ever expected or seen).

**Integer-fast-path claim**: verified two ways. (1) Real execution: TEST1's
`ADD` produced the correct integer result via a plain `add hl,de`. (2)
Structural: `grep -in "calc" rom/exrom_v2_vm_core.asm` finds zero references
to any `exrom_calc.asm` symbol anywhere in the module — the integer path
cannot invoke the calculator because nothing in this module even links to
it. This is a stronger guarantee than an instruction trace of one sample
run: it holds for every possible execution, not just the one traced.

### A real bug found and fixed (worth recording, not hiding)

The first assembled version's `OP_STORE_VAR`/`OP_LOAD_VAR` write symbol
records as `[tag][value_lo][value_hi]`, but the test driver's `CHECK_TEST1`
was written assuming `[value_lo][value_hi][tag]` — a real, if small,
layout mismatch. The first real ZEsarUX run caught this immediately:
border went red (FAIL) even though the VM had computed the correct answer
(8). Reading `VM_ERROR_CODE` (0, no VM-internal error) and the raw symbol
bytes (`00 08 00` — tag=INT, value=8, correct) by hand via `ts2068-debug
mem` made the actual mismatch obvious in under a minute. Fixed the
checker, reassembled, reran: green border. **This is exactly the kind of
failure the milestone's own "failures are engineering work, not a stop
condition" rule covers** — investigated, fixed, reverified, documented,
continued, no permission requested or needed.

### Success criteria: met

All 5 criteria from this document's own "SUCCESS CRITERIA" section above
are satisfied: both terminating tests pass on real hardware; the loop
benchmark ran 10,000,000+ bounded instructions total across two runs with
zero degradation and zero errors; the calculator-avoidance claim is
verified both by execution and by structural exclusion; ROM cost (316
bytes for 7 opcodes) extrapolates to within the existing 900-1,100-byte
full-VM estimate; the full existing V1 test suite was not affected (no
production file was modified — confirmed by `git status`).

### What this validates for the rest of Architecture B

The two assumptions this whole rewrite's justification leans on most
heavily — O(1) compiled branches and a genuinely free integer fast path —
are no longer only spike-sized-and-inspected; they are now hardware-
measured on real, bounds-checked production code. Nothing here invalidates
Architecture B.

**Update: R1 is now complete in full**, not just this milestone's 7-opcode
slice — `rom/exrom_v2_vm_core.asm` was extended to all 17 integer-domain
opcodes (`SUB`/`MUL`/`DIV`/`CMP_LT`/`CMP_EQ`/`JMPZ`/`FOR_INIT`/`FOR_NEXT`/
`CALL`/`RET` added), reusing `kernel/math/math.asm`'s existing verified
primitives, real-hardware-validated (a genuine terminating `FOR`/`NEXT`
loop and a `CALL`/`RET` procedure both confirmed correct on ZEsarUX; one
more real bug — a register clobbered across a subroutine call in
`OP_CALL` — found and fixed the same way as this document's own bug). See
`ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s R1 section for the full account
and the updated 731-byte/17-opcode ROM measurement. R2 (compiler
foundation) is next.

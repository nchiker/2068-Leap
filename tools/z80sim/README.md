# z80sim — source-level Z80 instruction simulator

A small Python tool for **testing one already-narrowed-down routine of Z80 assembly against a real, observed
state**. It parses sjasmplus-style `.asm` source directly (no assembling step) and executes it instruction by
instruction, with exact flag semantics, per-instruction source-file/line tracing, and saved-state
replay. It is an instruction-subset interpreter, not a general emulator; see
[Known limitations](#known-limitations).

Authoritative source of truth: this repository (`nchiker/z80sim`). It is developed for the
[2068-Leap](https://github.com/nchiker/2068-Leap) TS2068 ROM project, which carries a vendored copy in
`tools/z80sim/` (see [Use in 2068-Leap](#use-in-2068-leap)); the tool itself is project-neutral apart from the
`SYSVARS` table in `sim.py`, which you edit for your own system variables.

## Install and run

Python 3.8+ and nothing else: no packages, no build step. Clone and run the scripts in place.

```sh
git clone https://github.com/nchiker/z80sim.git
cd z80sim
python3 extract_routine.py my.asm ROUTINE_LABEL NEXT_LABEL --with-locations > /tmp/routine.asm
python3 replay_snapshot.py /tmp/routine.asm /tmp/case.json -o /tmp/result.json   # see "Saved-state replay"
```

## Tests

```sh
python3 -m unittest -v test_flags test_snapshot      # run from the repository root; ~1 s
```

`test_flags` covers the modelled flag semantics (all 8-bit add/sub helper inputs, logic, shifts, rotates, LDIR,
parity conditions); `test_snapshot` covers snapshot save/restore, source-line extraction, listing/symbol
correlation (including sjasmplus's `NN+` include-nesting line numbers) and bounded replay. The
source-level driver suites that exercise 2068-Leap's own routines (`test_calc_dispatcher.py`,
`test_sprite_driver.py`, `test_sprite_basic_driver.py`) need that project's source tree, so they live in
2068-Leap.

## Use in 2068-Leap

2068-Leap vendors these files into `tools/z80sim/`; `tools/z80sim/UPSTREAM.md` there records the exact
commit of this repository it carries and how to update it. Change the simulator here, then sync it into
2068-Leap; do not edit the vendored copy. Paths in the rest of this document are relative to this
directory (`tools/z80sim/` inside 2068-Leap).

License: MIT, see [LICENSE](../../LICENSE).

---

A Python interpreter that parses this project's own Z80 assembly
source directly (no separate assembly step) and executes it
instruction-by-instruction against a simulated register/memory/stack
state. Built during the SAVE/LOAD debugging saga specifically because
repeated hand-tracing and "reasoned" Python translations of individual
routines kept saying code was correct when it genuinely wasn't — this
tool replays the real instructions exactly as written, with no
opportunity to unknowingly "fix" a bug while translating it.

## What it caught

A real, confirmed bug in three routines (`.report_load_progress`,
`.bitmap_all_set`, `.count_lost_blocks` in kernel/storage/storage.asm)
that had passed multiple rounds of hand-tracing and simpler Python
simulation. The bug: each routine read a bitmap byte into register A,
then later ran a small loop to build a bit-mask whose own "is my
counter done" check did `ld a,b` — silently overwriting A and
destroying the just-read byte before it was ever tested. Every earlier
"reasoned" simulation of this same code had tested the loop counter as
its own separate Python variable rather than literally replaying the
overwrite, and so never caught it. Faithfully replaying the actual
instructions did.

## What it's for

Testing a *specific, already-narrowed-down* piece of real code against
a *specific, real, observed state* (e.g. from a debug.bin capture) —
not a general-purpose emulator, and not a substitute for real Fuse
testing. Best used when static analysis and hand-tracing have both
been exhausted on a reproducible bug and you have concrete state to
seed it with.

## Known limitations

- This is an instruction-subset interpreter, not a complete Z80
  emulator. The current implemented instruction forms are listed under
  **Supported instruction and flag contract** below. An unknown
  mnemonic raises `ValueError`, and unsupported operand forms generally
  fail during operand resolution. This does not mean every legal Z80
  form of an implemented mnemonic is accepted; use the project's
  assembler to validate source syntax.
- **`(IX+d)`/`(IY+d)` addressing requires IX/IY to already hold a REAL
  numeric address**, not a label — `ld ix, SOME_LABEL` resolves to a
  code-address marker (this simulator has no real memory image for
  arbitrary `DB`/`DW` data), not a usable address for indexed reads.
  To test a routine that walks a data table via IX (like
  `BASIC_DETECT_KEYWORD_PREFIX`/`BASIC_TRY_EVAL_FUNCTION`'s own
  `KEYWORD_HILITE_TABLE`/`FUNCTION_TABLE` walks), a driver script must
  seed the table's real bytes into `sim.mem` at a chosen address itself
  and either patch the extracted `ld ix, TABLE_LABEL` line to a literal
  address for the test copy, or set `sim.regs['IX']` directly before
  jumping into the loop body. See `tools/z80sim`'s own git history /
  the driver used for `BASIC_TRY_EVAL_FUNCTION` for a worked example.
- Character literals: both `'x'` and `"x"` single-char forms are
  supported (sjasmplus accepts either; this project's own source uses
  `"x"` throughout), including `"9" + 1`-style "one past this char"
  arithmetic used constantly for boundary checks.
- No port-device simulation. The narrow `OUT (n),A` form records the
  low-byte port and value in `sim.io_writes`, but does not model device
  effects; `IN` is unsupported. Tape-reading primitives
  (STORAGE_WAIT_EDGE, STORAGE_PULSE, etc.) need real Fuse testing or a
  separate tape-signal model.
- No interrupts, no timing/T-state modeling.
- `sim.py`'s own `SYSVARS` dict hardcodes the addresses it knows
  about — add any new sysvar you need to reference before using it,
  matching the real value from `include/sysvars.inc` (these drift as
  the project's own sysvar layout moves; always double-check against
  the current source rather than trusting this file's own copy).
- Local-label scoping requires extracting a routine starting from its
  enclosing GLOBAL label — if the code you're testing calls into
  local labels that live under a *different* global label elsewhere
  in the source (rare — `BASIC_DRAW_STATUS_LINE`'s own `.print_status`
  is the one case seen so far), extract that whole span together, not
  as separate files, or those local labels won't resolve.
- Leaf routines you don't care about the internals of (graphics,
  string-building) can be "stubbed" — see `STUB_ROUTINES` in
  `sim.py` — meaning a `call` to them is treated as an immediate
  no-op return, so the surrounding call/return mechanics still get
  exercised faithfully without needing to simulate their own bodies.

## Supported instruction and flag contract

The instruction handlers in `sim.py` currently implement these mnemonic
families. Operand forms are intentionally narrower than the full Z80 ISA:

| Family | Implemented forms |
| --- | --- |
| Data movement | `LD` for 8-bit registers, supported indirect byte reads/writes, 16-bit register pairs and indexed registers, immediate values, and absolute memory operands; `LDIR`, `LDDR`; `NAME EQU expr` constants (numbers, known names, `+`/`-`) |
| Arithmetic and logic | 8-bit `INC`/`DEC`; `ADD HL/IX/IY,rr`; `ADD A,r/n`; `ADC A,r/n` and `ADC HL,rr`; implicit-A `SUB/AND/OR/XOR/CP`; `SBC A,r/n` and `SBC HL,rr` |
| Bit and shifts | `BIT n,r/(HL)`, `SET`/`RES`, `SLA`, `SRL`, `RL`, `RR` on a register or `(HL)`, accumulator rotates `RLCA/RRCA/RLA/RRA` |
| Control flow | `JR` with `Z/NZ/C/NC`; `JP`, `CALL`, and `RET` with `Z/NZ/C/NC/M/P/PE/PO`; `DJNZ` |
| Stack and exchange | `PUSH`, `POP`, `EX DE,HL`, `EX AF,AF'`, `EXX` (BC/DE/HL with BC'/DE'/HL', saved in snapshots) |
| Other | `SCF`, `CCF`, `DI`, `EI`, and recorded `OUT (n),A` |

For supported forms, the modeled documented flags are `S`, `Z`, `H`,
`PV`, `N`, and `C`. Eight-bit arithmetic computes sign, zero, half-carry
or half-borrow, signed overflow, subtract, and carry/borrow. Logic and
shifts compute even parity in `PV`; `BIT` copies its zero result to
`PV` as the simulator's common Z80 convention. `BIT`'s `S` and `PV` are
listed as unspecified in Zilog's manual, so the simulator's chosen values
must not be treated as portable hardware evidence ([Zilog Z80 CPU User
Manual, UM0080](https://www.zilog.com/docs/z80/um0080.pdf)). `INC`/`DEC`
preserve carry. `ADD HL/IX/IY,rr` updates `H/N/C`
and preserves `S/Z/PV`; `ADC HL,rr` and `SBC HL,rr` compute all six documented flags.
Accumulator-only rotates preserve `S/Z/PV` and update `H/N/C`;
`SCF` preserves `S/Z/PV` and sets `C` while clearing `H/N`; `CCF` preserves `S/Z/PV`, copies the old
`C` to `H`, inverts `C` and clears `N`.
Completed `LDIR` preserves `S/Z/C`, clears `H/N`, and leaves `PV` clear.

`PUSH AF`/`POP AF` pack and restore those six flags. Undocumented flag
bits 3 and 5 are not modeled. The simulator also does not model
instruction timing, interrupt state changes, or peripheral effects.
Use a real emulator or hardware whenever the behavior under investigation
depends on those details.

Run the regressions with `python3 -m unittest -v test_flags test_snapshot` (see Tests above; in 2068-Leap,
`make check` runs them together with that project's source-level driver suites). They cover the flag
semantics, all 8-bit add/sub helper input combinations including carry-in, snapshots, source/artifact
mapping, and bounded replay. They are not a complete Z80 conformance suite.

## Saved-state replay and build annotations

`snapshot.py` stores a versioned `z80sim-state` JSON file containing the
routine entry (`scope` and optional local `label`), registers, modeled
flags, alternate AF state, logical stack markers, I/O write log, and only
the memory ranges selected by the caller. Memory is encoded as hex. The
format rejects unknown versions, malformed registers/flags, overlapping
or wrapping memory ranges, and unsupported logical stack values.

For extracted routines, pass `--with-locations` so each copied source line
retains its original file and line number in a comment understood by
`Program`. Existing extraction output stays unchanged when the option is
omitted:

```sh
python3 extract_routine.py source.asm \
    ROUTINE_GLOBAL --with-locations > /tmp/routine.asm
```

Save a seeded setup from a driver script:

```python
from snapshot import save_snapshot

save_snapshot('/tmp/routine-case.json', sim,
              'ROUTINE_GLOBAL', '.entry',
              [(0x60DC, 4), (0x8000, 128)])
```

Replay it with a bounded run and optional SjASMPlus artifacts:

```sh
python3 replay_snapshot.py /tmp/routine.asm \
    /tmp/routine-case.json --symbols build/program.sym \
    --listing build/program.lst --max-steps 200000 \
    --output /tmp/routine-replay.json
```

The result JSON records the outcome, final state, bounded trace, loaded
source hashes, and artifact hashes. Trace entries include their exact input
source file/line. A matched `.lst` row adds its assembled address; duplicate
or mismatched source rows are left unmapped. A `.sym` file adds addresses
for the nearest known label. SjASMPlus symbol/listing syntax is supported, including the `NN+` line numbers it writes for lines of included files
(verified against 2068-Leap's real `build/test_basic.lst`/`.sym`).
Artifacts must correspond to the code being investigated: the tool checks
exact listing source text for mapped rows but cannot prove the complete
build is fresh, so result metadata labels artifact freshness as unverified.
If an artifact is missing, has no matching symbols, or has no matching
listing lines, the command reports that instead of silently treating it as
verified. Without artifacts, source-line tracing still works and the result
marks assembled-address mapping unavailable.

`replay_snapshot.py` returns status 0 for a clean routine return and status
2 for a step limit or other simulated halt. Trace output is capped at 5,000
executed instructions by default; the result records when entries were
dropped. Snapshot memory ranges are caller-selected, so state outside those
ranges is not reproduced.

## How to use it

1. **Extract the routine(s) you need**, stripped of comments, using
   `extract_routine.py`:

   ```
   python3 extract_routine.py kernel/storage/storage.asm \
       .bitmap_all_set .count_lost_blocks > /tmp/bitmap_all_set.txt
   ```

   The second label is the *boundary* extraction stops at — pass the
   *next* routine/section's label, not the last line you want
   included (see the script's own docstring for why, and the caveat
   above about local-label scoping if your routine's own local labels
   don't all live under one contiguous global-label span).

2. **Write a small driver script** (see the pattern used throughout
   the SAVE/LOAD debugging session): load the extracted file(s) into
   a `Program`, create a `Z80Sim`, seed memory with the real observed
   state (from a debug.bin capture or otherwise), push a
   `('HALT', None)` sentinel so the routine's own final `ret` stops
   the simulation cleanly, then run and inspect the result:

   ```python
   import sys
   sys.path.insert(0, 'tools/z80sim')  # or wherever this directory is
   from sim import Program, Z80Sim, Interp, SYSVARS, Halt

   prog = Program()
   prog.load_file('/tmp/bitmap_all_set.txt')

   sim = Z80Sim()
   sim.wb(SYSVARS['STORAGE_BLOCK_COUNT'], 1)
   sim.wb(SYSVARS['STORAGE_BLOCK_BITMAP'], 0x01)

   interp = Interp(prog, sim)
   sim.push(('HALT', None))
   idx = next(i for (scope, name), i in prog.label_index.items()
              if name == '.bitmap_all_set')
   interp.current_idx = idx
   try:
       while True:
           scope, label, mn, op = prog.lines[interp.current_idx]
           if mn is None:
               interp.current_idx += 1
               continue
           result = interp.exec_instr(scope, mn, op)
           if result is None:
               interp.current_idx += 1
           elif isinstance(result, int):
               interp.current_idx = result
   except Halt:
       pass

   print('Carry flag:', sim.flags['C'])
   ```

3. **For deeper tracing**, append each instruction (with a snapshot of
   `sim.regs`/`sim.flags`) to a list before executing it, so you can
   print the exact sequence leading up to a wrong result — this is
   what actually found the bug above; a final-state-only check can
   tell you *that* something's wrong but not *where*.

4. If a `call` target is a routine you don't have extracted and don't
   care about the internals of, add its name to `STUB_ROUTINES` in
   `sim.py` rather than extracting and loading it.

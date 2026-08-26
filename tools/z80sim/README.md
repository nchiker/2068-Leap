# tools/z80sim — source-level Z80 instruction simulator

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

- Supports a working subset of Z80 instructions (8/16-bit loads,
  INC/DEC, basic ALU ops, shifts/rotates, JR/JP/CALL/RET/DJNZ,
  PUSH/POP, EX DE,HL, LDIR, SCF, `(IX+d)`/`(IY+d)` indexed addressing
  and `ADD IX,BC`-style pointer arithmetic — added when
  `BASIC_TRY_EVAL_FUNCTION`'s table walk needed it, see below) — enough
  for everything tested so far, but NOT exhaustive. Attempting an
  unsupported mnemonic raises a clear `ValueError` naming it, rather
  than silently doing the wrong thing.
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
- No port I/O simulation (`IN`/`OUT` aren't implemented) — this tool
  is for pure memory/CPU logic, not the tape-reading primitives
  themselves (STORAGE_WAIT_EDGE, STORAGE_PULSE, etc.), which need
  real Fuse testing or a genuinely different kind of tape-signal
  simulation.
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

## How to use it

1. **Extract the routine(s) you need**, stripped of comments, using
   `extract_routine.py`:

   ```
   python3 tools/z80sim/extract_routine.py kernel/storage/storage.asm \
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
   sys.path.insert(0, 'tools/z80sim')
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

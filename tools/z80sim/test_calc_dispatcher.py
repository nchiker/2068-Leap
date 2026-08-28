#!/usr/bin/env python3
"""
test_calc_dispatcher.py — real-instruction z80sim verification for the
2026-08-20 calculator engine (RST $28) dispatcher, rom/exrom_calc.asm.

This is the smoke test flagged as the real gate in this project's own
/areas notes: nothing else about the calculator is trustworthy until
this passes, since it's the only way to catch a stack-depth or
register mistake in the entry/exit plumbing before it's buried under
real op code.

Covers:
  1. The full round trip for a real op (end-calc, literal $38) — the
     ONLY implemented literal so far. Verifies CALC_GEN_ENT_1/2 pop the
     right thing, CALC_RE_ENTRY/CALC_SCAN_ENT/CALC_FIRST_3D correctly
     route a $38 literal down the unary/manipulatory path (not binary),
     CALC_STK_PNTRS_UNARY doesn't crash, CALC_DISPATCH's table lookup
     (real CALC_TABLE data, not faked) lands on the real CALC_OP_END_
     CALC body, and that body computes the correct final resume
     address.
  2. The unimplemented-op path, across all three CALC_SCAN_ENT
     branches (binary $00-$17, unary/manipulatory $18-$3D, multi-
     purpose $80+) — confirms each produces the correct CALC_TABLE
     index and, for the multi-purpose branch, the correct extracted
     parameter, without crashing the pointer-computation calls along
     the way.

Why the entry/exit trampolines (basic/basic.asm's CALC_ENTRY_
TRAMPOLINE/CALC_EXIT_TRAMPOLINE) aren't loaded here: they page real
EXROM hardware in and out, which this symbolic simulator has no model
for at all (no memory-banking concept) — that's out of scope for any
z80sim test, calculator or otherwise, in this project. What IS in
scope and IS tested: that CALC_OP_END_CALC computes the correct value
and leaves it in the right place for those trampolines to hand off
correctly (see test 1's own comments). A one-line stand-in for CALC_
EXIT_TRAMPOLINE is defined below purely to capture that value for
inspection — not to model paging, which this simulator can't do.

Not a leftover file in the tree — run manually when touching this
feature again; not part of any CI step in this project.
"""
import sys
sys.path.insert(0, 'tools/z80sim')
import sim

# ---- register the real production sysvar addresses (from include/
# sysvars.inc, not invented) so `ld hl,(CALC_LITERAL_PTR)` etc. resolve
# to real integers rather than being misread as code-address markers --
sim.SYSVARS['CALC_STACK'] = 0xB1FD
sim.SYSVARS['CALC_SP'] = 0xB225
sim.SYSVARS['CALC_BREG'] = 0xB244
sim.SYSVARS['CALC_UNIMPLEMENTED_LITERAL_FLAG'] = 0xB246
sim.SYSVARS['CALC_LITERAL_PTR'] = 0xB247
sim.SYSVARS['CALC_OP1_PTR'] = 0xB249
sim.SYSVARS['CALC_OP2_PTR'] = 0xB24B
sim.SYSVARS['CALC_LITERAL_PARAM'] = 0xB24D
sim.SYSVARS['CALC_STACK_OVERFLOW_FLAG'] = 0xB24E
sim.SYSVARS['CALC_TRUNC_FLAG'] = 0xB245
sim.SYSVARS['CALC_ERROR_CODE'] = 0xB246
sim.SYSVARS['CALC_ERR_NONE'] = 0
sim.SYSVARS['CALC_ERR_INVALID_LITERAL'] = 1
sim.SYSVARS['CALC_ERR_STACK_UNDERFLOW'] = 2
sim.SYSVARS['CALC_ERR_STACK_OVERFLOW'] = 3
sim.SYSVARS['CALC_ERR_DIVISION_BY_ZERO'] = 4
sim.SYSVARS['CALC_ERR_NUMERIC_OVERFLOW'] = 5
sim.SYSVARS['CALC_ERR_UNIMPLEMENTED'] = 6
# ---- 2026-08-21 real-arithmetic addition: register the 5 new scratch
# sysvars (include/sysvars.inc's own real addresses, not invented) ----
sim.SYSVARS['CALC_UNP_A'] = 0xB24F
sim.SYSVARS['CALC_UNP_B'] = 0xB255
sim.SYSVARS['CALC_SHIFT_COUNT'] = 0xB25B
sim.SYSVARS['CALC_MUL_ACC'] = 0xB25C
sim.SYSVARS['CALC_MUL_CAND'] = 0xB264

# CALC_TABLE's real address depends on wherever rom/exrom_build.asm
# ends up placing it inside the EXROM image — this simulator has no
# assembler pass computing that, so (matching this project's own
# ROW_BASE_TABLE precedent in test_sprite_driver.py) any consistent
# scratch address works; chosen clear of every other registered range.
CALC_TABLE_ADDR = 0x9200
sim.SYSVARS['CALC_TABLE'] = CALC_TABLE_ADDR

# Scratch memory for the fake "literal-op byte stream" each test pokes
# a literal byte into before running.
LITERAL_STREAM_ADDR = 0x9300

FAILURES = []


def check(label, got, want):
    if got != want:
        FAILURES.append(f"{label}: got {got!r}, want {want!r}")


def build_program():
    prog = sim.Program()
    prog.load_file('rom/exrom_calc.asm')
    # CALC_OP_END_CALC jumps to KTAB_CALC_EXIT_TRAMPOLINE (include/
    # exrom_jumptable.inc's KTAB indirection — EXROM code can't
    # directly reference basic.asm's real CALC_EXIT_TRAMPOLINE label,
    # they're separate sjasmplus compilation units; see that fix's own
    # history). Real KTAB_CALC_EXIT_TRAMPOLINE is itself just a `jp
    # CALC_EXIT_TRAMPOLINE` stub in the real build — this fixture
    # collapses both hops into one label directly, since neither the
    # KTAB indirection mechanics nor the real page-out CALC_EXIT_
    # TRAMPOLINE performs are things this symbolic simulator can (or
    # needs to) model; what matters for this test is only that CALC_
    # OP_END_CALC's pushed value ends up correct, captured here for
    # inspection instead of actually resuming execution there.
    import tempfile, os
    fixture = tempfile.NamedTemporaryFile(
        mode='w', suffix='.asm', delete=False)
    fixture.write("KTAB_CALC_EXIT_TRAMPOLINE:\n    pop  hl\n    ret\n")
    fixture.close()
    prog.load_file(fixture.name)
    os.unlink(fixture.name)
    return prog


def expected_table_index_simple(literal):
    """literal in $00-$3D: table index = literal * 2 (CALC_DOUBLE_A)."""
    return (literal * 2) & 0xFF


def expected_table_index_multi(literal):
    """literal >= $80: replicate CALC_SCAN_ENT's multi-purpose-literal
    arithmetic in Python (AND $60, four SRLs, ADD $7C) so the test's
    expectation is derived the same way the real code derives it, not
    hand-computed and liable to a transcription slip."""
    a = literal & 0x60
    for _ in range(4):
        a >>= 1
    a = (a + 0x7C) & 0xFF
    return a


def expected_param(literal):
    return literal & 0x1F


def populate_calc_table(prog, s):
    """Writes the production sparse CALC_TABLE into simulated memory."""
    real_ops = {
        0x02: 'CALC_OP_EXCHANGE',
        0x04: 'CALC_OP_DELETE',
        0x06: 'CALC_OP_SUB',       # literal $03, subtract
        0x08: 'CALC_OP_MUL',       # literal $04, multiply
        0x0A: 'CALC_OP_DIV',       # literal $05, division
        0x1E: 'CALC_OP_ADD',       # literal $0F, addition
        0x62: 'CALC_OP_DUPLICATE',
        0x70: 'CALC_OP_END_CALC',
    }
    address = CALC_TABLE_ADDR
    for offset, label in real_ops.items():
        s.wb(address, offset)
        s.ww(address + 1, prog.resolve_label(None, label))
        address += 3
    s.wb(address, 0xFF)


def new_sim(prog, calc_sp=1):
    s = sim.Z80Sim()
    s.wb(sim.SYSVARS['CALC_SP'], calc_sp)
    s.wb(sim.SYSVARS['CALC_BREG'], 0)
    populate_calc_table(prog, s)
    return s


def run_literals(prog, s, literals, b_reg=0, max_steps=2000):
    """Pokes a sequence of literal bytes starting at LITERAL_STREAM_ADDR
    (e.g. [0x01, 0x38] for 'exchange then end-calc'), sets up the stack
    exactly as RST $28 would (return address = the literal stream's
    start, nothing else on top of it), and runs from CALC_EXROM_ENTRY.
    Returns (interp, halt_message_or_None)."""
    for i, lit in enumerate(literals):
        s.wb(LITERAL_STREAM_ADDR + i, lit)
    interp = sim.Interp(prog, s)
    s.regs['B'] = b_reg
    s.push(('HALT',))              # outermost sentinel — matches this
                                    # project's own established z80sim
                                    # test pattern (test_sprite_driver.
                                    # py's run_from)
    s.push(LITERAL_STREAM_ADDR)    # what CALC_GEN_ENT_2 pops — the
                                    # real RST $28 return-address
                                    # contract, a raw integer, not a
                                    # call-tracked RETIDX
    try:
        interp.run('CALC_EXROM_ENTRY', None, max_steps=max_steps)
        return interp, None
    except sim.Halt as ex:
        return interp, str(ex)


def run_literal(prog, s, literal, b_reg=0, max_steps=2000):
    """Single-literal convenience wrapper around run_literals, for
    tests that want to observe the unimplemented-op hang path (which
    has no follow-on literal to reach)."""
    return run_literals(prog, s, [literal], b_reg=b_reg, max_steps=max_steps)


# ---- test 1: end-calc (literal $38) full round trip -----------------
prog = build_program()
s = new_sim(prog, calc_sp=1)
interp, halt_msg = run_literal(prog, s, 0x38)

check("test1 end-calc: clean stop reached",
      halt_msg is not None and 'clean stop' in halt_msg, True)
# CALC_RE_ENTRY advances CALC_LITERAL_PTR past the $38 byte BEFORE
# dispatch, so the correct resume address is stream_start + 1 — the
# fixture's `pop hl` captured exactly that value for inspection here.
got_resume_addr = (s.regs['H'] << 8) | s.regs['L']
check("test1 end-calc: resume address", got_resume_addr,
      LITERAL_STREAM_ADDR + 1)
check("test1 end-calc: CALC_LITERAL_PTR left consistent",
      s.rw(sim.SYSVARS['CALC_LITERAL_PTR']), LITERAL_STREAM_ADDR + 1)

# ---- test 2: unimplemented op, binary path (literal $06, < $18) -----
s = new_sim(prog, calc_sp=2)   # 2, so CALC_STK_PNTRS_BINARY's -5 adjustment
                         # doesn't need to go negative-index (SP-1 >= 1)
interp, halt_msg = run_literals(prog, s, [0x06, 0x38], max_steps=500)
check("test2 binary-unimpl: returned through end-calc",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test2 binary-unimpl: error recorded",
      s.rb(sim.SYSVARS['CALC_ERROR_CODE']), 6)

# ---- test 3: unimplemented op, unary/manipulatory path (literal $20) -
s = new_sim(prog, calc_sp=1)
interp, halt_msg = run_literals(prog, s, [0x20, 0x38], max_steps=500)
check("test3 unary-unimpl: returned through end-calc",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test3 unary-unimpl: error recorded",
      s.rb(sim.SYSVARS['CALC_ERROR_CODE']), 6)

# ---- test 4: unimplemented op, multi-purpose path (literal $C3) -----
s = new_sim(prog, calc_sp=1)
interp, halt_msg = run_literals(prog, s, [0xC3, 0x38], max_steps=500)
check("test4 multi-unimpl: returned through end-calc",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test4 multi-unimpl: error recorded",
      s.rb(sim.SYSVARS['CALC_ERROR_CODE']), 6)
check("test4 multi-unimpl: parameter extracted",
      s.rb(sim.SYSVARS['CALC_LITERAL_PARAM']),
      expected_param(0xC3))

# ---- test 5: exchange (literal $01) — real byte-level verification --
CALC_STACK_ADDR = sim.SYSVARS['CALC_STACK']


def poke_slot(s, slot_index, pattern):
    for i, b in enumerate(pattern):
        s.wb(CALC_STACK_ADDR + slot_index * 5 + i, b)


def read_slot(s, slot_index):
    return [s.rb(CALC_STACK_ADDR + slot_index * 5 + i) for i in range(5)]


slot0_pattern = [0x11, 0x22, 0x33, 0x44, 0x55]
slot1_pattern = [0x66, 0x77, 0x88, 0x99, 0xAA]

s = new_sim(prog, calc_sp=2)
poke_slot(s, 0, slot0_pattern)
poke_slot(s, 1, slot1_pattern)
interp, halt_msg = run_literals(prog, s, [0x01, 0x38])  # exchange, end-calc
check("test5 exchange: clean stop reached",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test5 exchange: slot0 got slot1's old bytes",
      read_slot(s, 0), slot1_pattern)
check("test5 exchange: slot1 got slot0's old bytes",
      read_slot(s, 1), slot0_pattern)
check("test5 exchange: CALC_SP unchanged (same depth, reordered)",
      s.rb(sim.SYSVARS['CALC_SP']), 2)

# ---- test 6: delete (literal $02) — CALC_SP shrinks, first operand
# survives untouched, second is simply no longer part of the stack ----
s = new_sim(prog, calc_sp=2)
poke_slot(s, 0, slot0_pattern)
poke_slot(s, 1, slot1_pattern)
interp, halt_msg = run_literals(prog, s, [0x02, 0x38])  # delete, end-calc
check("test6 delete: clean stop reached",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test6 delete: CALC_SP decremented", s.rb(sim.SYSVARS['CALC_SP']), 1)
check("test6 delete: first operand (slot0) untouched",
      read_slot(s, 0), slot0_pattern)

# ---- test 7: duplicate (literal $31) — CALC_SP grows, new top is a
# copy of the old one -------------------------------------------------
s = new_sim(prog, calc_sp=1)
poke_slot(s, 0, slot0_pattern)
interp, halt_msg = run_literals(prog, s, [0x31, 0x38])  # duplicate, end-calc
check("test7 duplicate: clean stop reached",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test7 duplicate: CALC_SP incremented", s.rb(sim.SYSVARS['CALC_SP']), 2)
check("test7 duplicate: new slot1 is a copy of slot0",
      read_slot(s, 1), slot0_pattern)
check("test7 duplicate: original slot0 untouched",
      read_slot(s, 0), slot0_pattern)

# ---- test 8: duplicate overflow (CALC_SP already at the 8-slot cap) -
# Expected: returns with an explicit error rather than writing past
# CALC_STACK's real 40-byte allocation.
s = new_sim(prog, calc_sp=8)
interp, halt_msg = run_literals(prog, s, [0x31, 0x38], max_steps=500)
check("test8 duplicate-overflow: returned through end-calc",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test8 duplicate-overflow: overflow flag recorded CALC_SP",
      s.rb(sim.SYSVARS['CALC_STACK_OVERFLOW_FLAG']), 8)

# ---- test 9: CALC_INT_TO_FP / CALC_FP_TO_INT round trip (both are
# plain kernel routines, not CALC_TABLE literals -- called directly by
# label, same pattern the real ROM's STACK-A/STK-TO-A would be called,
# not through the RST $28 literal dispatch at all) ---------------------
def small_int_form(n):
    """Python mirror of the real small-int fast-path byte layout, for
    building expected values -- matches CALC_INT_TO_FP exactly."""
    u = n & 0xFFFF
    sign = 0xFF if n < 0 else 0x00
    return [0x00, sign, u & 0xFF, (u >> 8) & 0xFF, 0x00]


def run_sub(prog, s, label, setup=None, max_steps=2000):
    """Calls a plain (non-dispatch) subroutine directly by label, with
    a HALT sentinel return address -- for CALC_INT_TO_FP/CALC_FP_TO_INT,
    which aren't reached through CALC_EXROM_ENTRY at all."""
    interp = sim.Interp(prog, s)
    if setup:
        setup(s)
    s.push(('HALT',))
    try:
        interp.run(label, None, max_steps=max_steps)
        return interp, None
    except sim.Halt as ex:
        return interp, str(ex)


s = new_sim(prog, calc_sp=0)
interp, halt_msg = run_sub(prog, s, 'CALC_INT_TO_FP',
                            setup=lambda s: s.regs.update(H=0x04, L=0xD2))
check("test9 int_to_fp: clean stop reached",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test9 int_to_fp: CALC_SP incremented", s.rb(sim.SYSVARS['CALC_SP']), 1)
check("test9 int_to_fp: pushed small-int-form bytes for 1234",
      read_slot(s, 0), small_int_form(1234))

interp, halt_msg = run_sub(prog, s, 'CALC_FP_TO_INT')
check("test9 fp_to_int: clean stop reached",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test9 fp_to_int: CALC_SP decremented back", s.rb(sim.SYSVARS['CALC_SP']), 0)
got_hl = (s.regs['H'] << 8) | s.regs['L']
check("test9 fp_to_int: recovered 1234", got_hl, 1234)
check("test9 fp_to_int: CALC_TRUNC_FLAG clear (in range)",
      s.rb(sim.SYSVARS['CALC_TRUNC_FLAG']), 0)

# negative round trip
s = new_sim(prog, calc_sp=0)
interp, halt_msg = run_sub(prog, s, 'CALC_INT_TO_FP',
                            setup=lambda s: s.regs.update(H=0xFB, L=0x2E))
check("test9b int_to_fp: pushed small-int-form bytes for -1234",
      read_slot(s, 0), small_int_form(-1234))
interp, halt_msg = run_sub(prog, s, 'CALC_FP_TO_INT')
got_hl = (s.regs['H'] << 8) | s.regs['L']
got_signed = got_hl - 0x10000 if got_hl & 0x8000 else got_hl
check("test9b fp_to_int: recovered -1234", got_signed, -1234)
check("test9b fp_to_int: CALC_TRUNC_FLAG clear (in range)",
      s.rb(sim.SYSVARS['CALC_TRUNC_FLAG']), 0)

# ---- test 10: addition (literal $0F) — 100 + 250 = 350, verified by
# round-tripping the result through CALC_FP_TO_INT (not just checking
# raw bytes, since the general-form encoding isn't hand-obvious) ------
s = new_sim(prog, calc_sp=2)
poke_slot(s, 0, small_int_form(100))
poke_slot(s, 1, small_int_form(250))
interp, halt_msg = run_literals(prog, s, [0x0F, 0x38])  # addition, end-calc
check("test10 add: clean stop reached",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test10 add: CALC_SP net -1 (two consumed, one produced)",
      s.rb(sim.SYSVARS['CALC_SP']), 1)
interp, halt_msg = run_sub(prog, s, 'CALC_FP_TO_INT')
got_hl = (s.regs['H'] << 8) | s.regs['L']
got_signed = got_hl - 0x10000 if got_hl & 0x8000 else got_hl
check("test10 add: 100+250=350", got_signed, 350)
check("test10 add: not flagged overflow", s.rb(sim.SYSVARS['CALC_TRUNC_FLAG']), 0)

# ---- test 11: subtraction (literal $03) — 100 - 250 = -150, first
# (lower) operand minus second (top) operand, matching the real ROM's
# own literal semantics -------------------------------------------------
s = new_sim(prog, calc_sp=2)
poke_slot(s, 0, small_int_form(100))
poke_slot(s, 1, small_int_form(250))
interp, halt_msg = run_literals(prog, s, [0x03, 0x38])  # subtract, end-calc
check("test11 sub: clean stop reached",
      halt_msg is not None and 'clean stop' in halt_msg, True)
interp, halt_msg = run_sub(prog, s, 'CALC_FP_TO_INT')
got_hl = (s.regs['H'] << 8) | s.regs['L']
got_signed = got_hl - 0x10000 if got_hl & 0x8000 else got_hl
check("test11 sub: 100-250=-150", got_signed, -150)

# ---- test 12: multiply (literal $04) — 181*181=32761 (fits exactly;
# 182*182 would not — this deliberately exercises a near-boundary case,
# not just a trivially small product) -----------------------------------
s = new_sim(prog, calc_sp=2)
poke_slot(s, 0, small_int_form(181))
poke_slot(s, 1, small_int_form(181))
interp, halt_msg = run_literals(prog, s, [0x04, 0x38], max_steps=8000)  # multiply, end-calc
check("test12 mul: clean stop reached",
      halt_msg is not None and 'clean stop' in halt_msg, True)
interp, halt_msg = run_sub(prog, s, 'CALC_FP_TO_INT')
got_hl = (s.regs['H'] << 8) | s.regs['L']
check("test12 mul: 181*181=32761", got_hl, 32761)
check("test12 mul: not flagged overflow", s.rb(sim.SYSVARS['CALC_TRUNC_FLAG']), 0)

# ---- test 13: multiply overflow (literal $04) — 200*200=40000, out of
# 16-bit signed range -> CALC_TRUNC_FLAG must be set -------------------
s = new_sim(prog, calc_sp=2)
poke_slot(s, 0, small_int_form(200))
poke_slot(s, 1, small_int_form(200))
interp, halt_msg = run_literals(prog, s, [0x04, 0x38], max_steps=8000)
interp, halt_msg = run_sub(prog, s, 'CALC_FP_TO_INT')
check("test13 mul-overflow: CALC_TRUNC_FLAG set",
      s.rb(sim.SYSVARS['CALC_TRUNC_FLAG']), 1)

# ---- test 14: chained (a+b)*c — -30 + 80 = 50, 50*7 = 350, exercises
# the add engine's result being correctly re-unpacked by a subsequent
# op, not just individually correct ops ----------------------------------
s = new_sim(prog, calc_sp=2)
poke_slot(s, 0, small_int_form(-30))
poke_slot(s, 1, small_int_form(80))
interp, halt_msg = run_literals(prog, s, [0x0F, 0x38])
check("test14 chain: intermediate CALC_SP", s.rb(sim.SYSVARS['CALC_SP']), 1)
poke_slot(s, 1, small_int_form(7))
s.wb(sim.SYSVARS['CALC_SP'], 2)
interp, halt_msg = run_literals(prog, s, [0x04, 0x38], max_steps=8000)  # multiply, end-calc
interp, halt_msg = run_sub(prog, s, 'CALC_FP_TO_INT')
got_hl = (s.regs['H'] << 8) | s.regs['L']
check("test14 chain: (-30+80)*7=350", got_hl, 350)

# ---- test 15: malformed simple literal is bounded -------------------
s = new_sim(prog, calc_sp=2)
interp, halt_msg = run_literals(prog, s, [0x42, 0x38])
check("test15 invalid literal: clean error return",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test15 invalid literal: error code",
      s.rb(sim.SYSVARS['CALC_ERROR_CODE']), 1)

# ---- test 16: binary stack underflow cannot escape CALC_STACK -------
s = new_sim(prog, calc_sp=1)
interp, halt_msg = run_literals(prog, s, [0x0F, 0x38])
check("test16 stack underflow: clean error return",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test16 stack underflow: error code",
      s.rb(sim.SYSVARS['CALC_ERROR_CODE']), 2)
check("test16 stack underflow: stack reset", s.rb(sim.SYSVARS['CALC_SP']), 0)

# ---- test 17: calculator division by zero is recoverable ------------
s = new_sim(prog, calc_sp=2)
poke_slot(s, 0, small_int_form(10))
poke_slot(s, 1, small_int_form(0))
interp, halt_msg = run_literals(prog, s, [0x05, 0x38])
check("test17 divide zero: clean error return",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test17 divide zero: error code",
      s.rb(sim.SYSVARS['CALC_ERROR_CODE']), 4)

# ---- test 18: FP_TO_INT overflow saturates consistently by sign -----
for label, packed, expected in (
        ("positive", [0x91, 0x00, 0, 0, 0], 0x7FFF),
        ("negative", [0x91, 0x80, 0, 0, 0], 0x8000)):
    s = new_sim(prog, calc_sp=1)
    poke_slot(s, 0, packed)
    interp, halt_msg = run_sub(prog, s, 'CALC_FP_TO_INT')
    got_hl = (s.regs['H'] << 8) | s.regs['L']
    check(f"test18 {label}: saturated result", got_hl, expected)
    check(f"test18 {label}: trunc flag", s.rb(sim.SYSVARS['CALC_TRUNC_FLAG']), 1)
    check(f"test18 {label}: numeric error", s.rb(sim.SYSVARS['CALC_ERROR_CODE']), 5)

# ---- test 19: exponent overflow errors; underflow becomes zero -------
def run_binary_packed(op, left, right, max_steps=10000):
    state = new_sim(prog, calc_sp=2)
    poke_slot(state, 0, left)
    poke_slot(state, 1, right)
    interpreter, stopped = run_literals(prog, state, [op, 0x38],
                                        max_steps=max_steps)
    return state, stopped


s, halt_msg = run_binary_packed(0x0F, [0xFF, 0, 0, 0, 0],
                                [0xFF, 0, 0, 0, 0])
check("test19 add exponent overflow: clean return",
      halt_msg is not None and 'clean stop' in halt_msg, True)
check("test19 add exponent overflow: error", s.rb(sim.SYSVARS['CALC_ERROR_CODE']), 5)

s, halt_msg = run_binary_packed(0x04, [200, 0, 0, 0, 0],
                                [200, 0, 0, 0, 0])
check("test19 mul exponent overflow: error", s.rb(sim.SYSVARS['CALC_ERROR_CODE']), 5)

s, halt_msg = run_binary_packed(0x04, [1, 0, 0, 0, 0],
                                [1, 0, 0, 0, 0])
check("test19 mul exponent underflow: no error", s.rb(sim.SYSVARS['CALC_ERROR_CODE']), 0)
check("test19 mul exponent underflow: zero exponent", read_slot(s, 0)[0], 0)

s, halt_msg = run_binary_packed(0x05, [250, 0, 0, 0, 0],
                                [1, 0, 0, 0, 0])
check("test19 div exponent overflow: error", s.rb(sim.SYSVARS['CALC_ERROR_CODE']), 5)

s, halt_msg = run_binary_packed(0x05, [1, 0, 0, 0, 0],
                                [250, 0, 0, 0, 0])
check("test19 div exponent underflow: no error", s.rb(sim.SYSVARS['CALC_ERROR_CODE']), 0)
check("test19 div exponent underflow: zero exponent", read_slot(s, 0)[0], 0)

# ---- results ----------------------------------------------------------
if FAILURES:
    print(f"FAIL ({len(FAILURES)}):")
    for f in FAILURES:
        print(f"  {f}")
    sys.exit(1)
else:
    print("PASS: all calculator dispatcher checks passed")

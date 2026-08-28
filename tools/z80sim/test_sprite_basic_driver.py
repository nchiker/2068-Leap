#!/usr/bin/env python3
"""
test_sprite_basic_driver.py — real-instruction z80sim verification for
the BASIC-level Sprites feature (SPRITE GRAB/SHOW/HIDE/MOVE/HIT,
rom/exrom_sprite.asm). Scripts BASIC_EVAL_EXPR/BASIC_MATCH_KEYWORD_BOUNDARY/
BASIC_EXPECT_COMMA_EXPR/BASIC_EXPECT_STATEMENT_END/BASIC_SKIP_SPACES/
GFX_SPRITE_CAPTURE/GFX_SPRITE_DRAW (all already independently verified
or hardware-confirmed elsewhere) so this test focuses on what's
actually NEW: slot->address arithmetic, range checks, and the GRAB/
SHOW/HIDE state machine wiring itself. BASIC_SET_PENDING_ERROR/
BASIC_RAISE_SYNTAX_ERROR run for REAL (their own bodies are small,
simple, and already proven) rather than being scripted, so pending-
error/carry behavior is checked against real execution, not an
assumption.

Not run automatically — kept in the tree for next time this feature
is touched, same as test_sprite_driver.py.
"""
import sys
sys.path.insert(0, 'tools/z80sim')
import sim

sim.SYSVARS['SPRITE_ARG_SLOT'] = 0x9F00
sim.SYSVARS['SPRITE_ARG_ROW'] = 0x9F01
sim.SYSVARS['SPRITE_ARG_COL'] = 0x9F02
sim.SYSVARS['SPRITE_ARG_W'] = 0x9F03
sim.SYSVARS['SPRITE_ARG_H'] = 0x9F04
sim.SYSVARS['SPRITE_SLOT_DEFINED'] = 0x9560
sim.SYSVARS['SPRITE_SLOT_SHOWN'] = 0x9568
sim.SYSVARS['SPRITE_SLOT_W'] = 0x9570
sim.SYSVARS['SPRITE_SLOT_H'] = 0x9578
sim.SYSVARS['SPRITE_SLOT_ROW'] = 0x9580
sim.SYSVARS['SPRITE_SLOT_COL'] = 0x9588
sim.SYSVARS['SPRITE_DISPLAY_DEPTH'] = 0x9590
sim.SYSVARS['SPRITE_DISPLAY_STACK'] = 0x9591
sim.SYSVARS['SPRITE_SLOT_IMG_BUF'] = 0x9599
sim.SYSVARS['SPRITE_SLOT_BG_BUF'] = 0x9A19
sim.SYSVARS['SPRITE_SLOT_BYTES'] = 144
sim.SYSVARS['SPRITE_SLOT_MAX'] = 8
sim.SYSVARS['SPRITE_CELL_MAX'] = 4
sim.SYSVARS['MSG_SPRITE_BAD_SLOT'] = 0x7300
sim.SYSVARS['MSG_SPRITE_TOO_LARGE'] = 0x7310
sim.SYSVARS['MSG_SPRITE_OUT_OF_RANGE'] = 0x7320
sim.SYSVARS['MSG_SPRITE_NOT_DEFINED'] = 0x7330
sim.SYSVARS['MSG_SPRITE_ALREADY_SHOWN'] = 0x7340
sim.SYSVARS['MSG_SPRITE_NOT_SHOWN'] = 0x7350
sim.SYSVARS['MSG_SPRITE_ORDER'] = 0x7370
sim.SYSVARS['MSG_SYNTAX_ERROR'] = 0x7360
sim.SYSVARS['PENDING_ERROR_MSG'] = 0x82EE
sim.SYSVARS['KW_GRAB'] = 0x7400
sim.SYSVARS['KW_SHOW'] = 0x7410
sim.SYSVARS['KW_HIDE'] = 0x7420
sim.SYSVARS['KW_MOVE'] = 0x7430

FAILURES = []
def check(label, got, want):
    if got != want:
        FAILURES.append(f"{label}: got {got!r}, want {want!r}")

# ---- build the program: the real extracted SPRITE block + the real
# (not stubbed) BASIC_SET_PENDING_ERROR/BASIC_RAISE_SYNTAX_ERROR ------
import subprocess
block = subprocess.run(
    ['python3', 'tools/z80sim/extract_routine.py', 'rom/exrom_sprite.asm',
     'BASIC_STMT_SPRITE', 'SPRITE_BASIC_TEST_END'],
    capture_output=True, text=True, check=True).stdout
tail = subprocess.run(
    ['python3', 'tools/z80sim/extract_routine.py', 'basic/basic.asm',
     'BASIC_SET_PENDING_ERROR', 'BASIC_REPORT_ERROR'],
    capture_output=True, text=True, check=True).stdout

with open('/tmp/sprite_basic_combined.asm', 'w') as f:
    f.write(block)
    f.write('\n')
    f.write(tail)
    f.write('\nKTAB_BASIC_SET_PENDING_ERROR:\n')
    f.write('    jp BASIC_SET_PENDING_ERROR\n')
    for ktab, target in (
            ('KTAB_BASIC_EVAL_EXPR', 'BASIC_EVAL_EXPR'),
            ('KTAB_BASIC_SKIP_SPACES', 'BASIC_SKIP_SPACES'),
            ('KTAB_BASIC_MATCH_KEYWORD_BOUNDARY',
             'BASIC_MATCH_KEYWORD_BOUNDARY'),
            ('KTAB_BASIC_EXPECT_COMMA_EXPR', 'BASIC_EXPECT_COMMA_EXPR'),
            ('KTAB_BASIC_EXPECT_STATEMENT_END',
             'BASIC_EXPECT_STATEMENT_END'),
            ('KTAB_GFX_SPRITE_CAPTURE', 'GFX_SPRITE_CAPTURE'),
            ('KTAB_GFX_SPRITE_DRAW', 'GFX_SPRITE_DRAW')):
        f.write(f'{ktab}:\n    call {target}\n    ret\n')

def new_interp():
    prog = sim.Program()
    prog.load_file('/tmp/sprite_basic_combined.asm')
    s = sim.Z80Sim()
    s.ww(sim.SYSVARS['PENDING_ERROR_MSG'], 0)   # clean slate each time
    return prog, sim.Interp(prog, s)

def run(prog, interp, label, hl=0x8000):
    interp.sim.regs['H'], interp.sim.regs['L'] = (hl >> 8) & 0xFF, hl & 0xFF
    interp.sim.push(('HALT',))
    try:
        interp.run(label, None)
    except sim.Halt as ex:
        if 'clean stop' not in str(ex):
            raise

MATCH = ({}, {'C': 0})
NOMATCH = ({}, {'C': 1})

# =====================================================================
# 1. Slot/buffer address arithmetic (BASIC_SPRITE_SLOT_IMG_ADDR/
#    BG_ADDR/ADD_SLOT_OFFSET, BASIC_SPRITE_SLOT_FLAG_ADDR)
# =====================================================================
for slot in range(8):
    prog, interp = new_interp()
    interp.sim.wb(sim.SYSVARS['SPRITE_ARG_SLOT'], slot)
    run(prog, interp, 'BASIC_SPRITE_SLOT_IMG_ADDR')
    got = interp.sim.get_reg16('HL') if hasattr(interp.sim, 'get_reg16') else (interp.sim.regs['H'] << 8 | interp.sim.regs['L'])
    want = sim.SYSVARS['SPRITE_SLOT_IMG_BUF'] + slot * sim.SYSVARS['SPRITE_SLOT_BYTES']
    check(f'IMG_ADDR slot {slot}', got, want)

    prog, interp = new_interp()
    interp.sim.wb(sim.SYSVARS['SPRITE_ARG_SLOT'], slot)
    run(prog, interp, 'BASIC_SPRITE_SLOT_BG_ADDR')
    got = (interp.sim.regs['H'] << 8) | interp.sim.regs['L']
    want = sim.SYSVARS['SPRITE_SLOT_BG_BUF'] + slot * sim.SYSVARS['SPRITE_SLOT_BYTES']
    check(f'BG_ADDR slot {slot}', got, want)

for slot in range(8):
    prog, interp = new_interp()
    interp.sim.wb(sim.SYSVARS['SPRITE_ARG_SLOT'], slot)
    interp.sim.regs['A'] = slot
    interp.sim.regs['H'], interp.sim.regs['L'] = (sim.SYSVARS['SPRITE_SLOT_ROW'] >> 8) & 0xFF, sim.SYSVARS['SPRITE_SLOT_ROW'] & 0xFF
    interp.sim.push(('HALT',))
    try:
        interp.run('BASIC_SPRITE_SLOT_FLAG_ADDR', None)
    except sim.Halt as ex:
        if 'clean stop' not in str(ex):
            raise
    got = (interp.sim.regs['H'] << 8) | interp.sim.regs['L']
    want = sim.SYSVARS['SPRITE_SLOT_ROW'] + slot
    check(f'FLAG_ADDR(SPRITE_SLOT_ROW) slot {slot}', got, want)

# =====================================================================
# 2. Range checks (BASIC_SPRITE_CHECK_ROW/COL/WH)
# =====================================================================
def check_range_routine(label, good_vals, bad_vals):
    for v in good_vals:
        prog, interp = new_interp()
        interp.sim.regs['D'] = (v >> 8) & 0xFF
        interp.sim.regs['E'] = v & 0xFF
        interp.sim.push(('HALT',))
        try:
            interp.run(label, None)
        except sim.Halt as ex:
            if 'clean stop' not in str(ex):
                raise
        check(f'{label}({v}) accepted', interp.sim.flags['C'], 0)
    for v in bad_vals:
        prog, interp = new_interp()
        interp.sim.regs['D'] = (v >> 8) & 0xFF
        interp.sim.regs['E'] = v & 0xFF
        interp.sim.push(('HALT',))
        try:
            interp.run(label, None)
        except sim.Halt as ex:
            if 'clean stop' not in str(ex):
                raise
        check(f'{label}({v}) rejected', interp.sim.flags['C'], 1)

check_range_routine('BASIC_SPRITE_CHECK_ROW', [0, 23], [24, 255])
check_range_routine('BASIC_SPRITE_CHECK_COL', [0, 31], [32, 255])
check_range_routine('BASIC_SPRITE_CHECK_WH', [1, 4], [0, 5, 255])
check_range_routine('BASIC_SPRITE_CHECK_ROW', [], [256])
check_range_routine('BASIC_SPRITE_CHECK_COL', [], [256])
check_range_routine('BASIC_SPRITE_CHECK_WH', [], [256])

# =====================================================================
# 3. BASIC_SPRITE_PARSE_SLOT — valid, out-of-range, malformed
# =====================================================================
prog, interp = new_interp()
interp.set_script('BASIC_EVAL_EXPR', [({'D': 0, 'E': 2}, {'C': 0})])
run(prog, interp, 'BASIC_SPRITE_PARSE_SLOT')
check('PARSE_SLOT valid(2) carry', interp.sim.flags['C'], 0)
check('PARSE_SLOT valid(2) stored', interp.sim.rb(sim.SYSVARS['SPRITE_ARG_SLOT']), 2)

prog, interp = new_interp()
interp.set_script('BASIC_EVAL_EXPR', [({'D': 0, 'E': 8}, {'C': 0})])
run(prog, interp, 'BASIC_SPRITE_PARSE_SLOT')
check('PARSE_SLOT bad slot(8) carry', interp.sim.flags['C'], 1)
check('PARSE_SLOT bad slot(8) message', interp.sim.rw(sim.SYSVARS['PENDING_ERROR_MSG']), sim.SYSVARS['MSG_SPRITE_BAD_SLOT'])

prog, interp = new_interp()
interp.set_script('BASIC_EVAL_EXPR', [({'D': 1, 'E': 0}, {'C': 0})])
run(prog, interp, 'BASIC_SPRITE_PARSE_SLOT')
check('PARSE_SLOT 256 does not wrap to slot 0', interp.sim.flags['C'], 1)

prog, interp = new_interp()
interp.set_script('BASIC_EVAL_EXPR', [({}, {'C': 1})])  # malformed expression
run(prog, interp, 'BASIC_SPRITE_PARSE_SLOT')
check('PARSE_SLOT malformed expr carry', interp.sim.flags['C'], 1)
check('PARSE_SLOT malformed expr message', interp.sim.rw(sim.SYSVARS['PENDING_ERROR_MSG']), sim.SYSVARS['MSG_SYNTAX_ERROR'])

# =====================================================================
# 4. BASIC_STMT_SPRITE dispatch — routes GRAB/SHOW/HIDE correctly
# =====================================================================
prog, interp = new_interp()
interp.set_script('BASIC_SKIP_SPACES', [({}, {})])
interp.set_script('BASIC_MATCH_KEYWORD_BOUNDARY', [MATCH])  # GRAB matches first try
interp.set_script('BASIC_EVAL_EXPR', [({}, {'C': 1})])       # fail fast inside GRAB
run(prog, interp, 'BASIC_STMT_SPRITE')
grab_hit = any(sc == 'BASIC_STMT_SPRITE_GRAB' for (sc, l, mn, op, r, fl) in interp.trace_log)
check('SPRITE dispatch reaches GRAB on 1st keyword match', grab_hit, True)

prog, interp = new_interp()
interp.set_script('BASIC_SKIP_SPACES', [({}, {})])
interp.set_script('BASIC_MATCH_KEYWORD_BOUNDARY', [NOMATCH, MATCH])  # SHOW matches 2nd
interp.set_script('BASIC_EVAL_EXPR', [({}, {'C': 1})])
run(prog, interp, 'BASIC_STMT_SPRITE')
show_hit = any(sc == 'BASIC_STMT_SPRITE_SHOW' for (sc, l, mn, op, r, fl) in interp.trace_log)
check('SPRITE dispatch reaches SHOW on 2nd keyword match', show_hit, True)

prog, interp = new_interp()
interp.set_script('BASIC_SKIP_SPACES', [({}, {})])
interp.set_script('BASIC_MATCH_KEYWORD_BOUNDARY', [NOMATCH, NOMATCH, MATCH])  # HIDE 3rd
interp.set_script('BASIC_EVAL_EXPR', [({}, {'C': 1})])
run(prog, interp, 'BASIC_STMT_SPRITE')
hide_hit = any(sc == 'BASIC_STMT_SPRITE_HIDE' for (sc, l, mn, op, r, fl) in interp.trace_log)
check('SPRITE dispatch reaches HIDE on 3rd keyword match', hide_hit, True)

prog, interp = new_interp()
interp.set_script('BASIC_SKIP_SPACES', [({}, {})])
interp.set_script('BASIC_MATCH_KEYWORD_BOUNDARY', [NOMATCH, NOMATCH, NOMATCH])
run(prog, interp, 'BASIC_STMT_SPRITE')
check('SPRITE dispatch: no keyword matches -> syntax error, carry set', interp.sim.flags['C'], 1)
check('SPRITE dispatch: no keyword matches -> right message',
      interp.sim.rw(sim.SYSVARS['PENDING_ERROR_MSG']), sim.SYSVARS['MSG_SYNTAX_ERROR'])

# =====================================================================
# 5. Full GRAB flow: slot=1, row=5, col=10, w=2, h=3
# =====================================================================
prog, interp = new_interp()
interp.set_script('BASIC_SKIP_SPACES', [({}, {})])
interp.set_script('BASIC_MATCH_KEYWORD_BOUNDARY', [MATCH])
interp.set_script('BASIC_EVAL_EXPR', [({'D': 0, 'E': 1}, {'C': 0})])   # slot=1
interp.set_script('BASIC_EXPECT_COMMA_EXPR', [
    ({'D': 0, 'E': 5}, {'C': 0}),    # row=5
    ({'D': 0, 'E': 10}, {'C': 0}),   # col=10
    ({'D': 0, 'E': 2}, {'C': 0}),    # w=2
    ({'D': 0, 'E': 3}, {'C': 0}),    # h=3
])
interp.set_script('BASIC_EXPECT_STATEMENT_END', [({}, {'C': 0})])
interp.set_script('GFX_SPRITE_CAPTURE', [({}, {'C': 0})])
run(prog, interp, 'BASIC_STMT_SPRITE')

check('GRAB success carry', interp.sim.flags['C'], 0)
check('GRAB slot 1 DEFINED', interp.sim.rb(sim.SYSVARS['SPRITE_SLOT_DEFINED'] + 1), 1)
check('GRAB slot 1 W', interp.sim.rb(sim.SYSVARS['SPRITE_SLOT_W'] + 1), 2)
check('GRAB slot 1 H', interp.sim.rb(sim.SYSVARS['SPRITE_SLOT_H'] + 1), 3)

capture_call = next(
    (r for (sc, l, mn, op, r, fl) in interp.trace_log
     if mn == 'call' and op and 'GFX_SPRITE_CAPTURE' in op), None)
if capture_call is None:
    FAILURES.append('GRAB never called GFX_SPRITE_CAPTURE')
else:
    want_hl = sim.SYSVARS['SPRITE_SLOT_IMG_BUF'] + 1 * sim.SYSVARS['SPRITE_SLOT_BYTES']
    got_hl = (capture_call['H'] << 8) | capture_call['L']
    check('GRAB->CAPTURE B (row)', capture_call['B'], 5)
    check('GRAB->CAPTURE C (col)', capture_call['C'], 10)
    check('GRAB->CAPTURE D (w)', capture_call['D'], 2)
    check('GRAB->CAPTURE E (h)', capture_call['E'], 3)
    check('GRAB->CAPTURE HL (slot 1 img buffer)', got_hl, want_hl)

# Re-GRAB must not replace a shown slot's image/dimensions.
prog, interp = new_interp()
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_SHOWN'] + 1, 1)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_W'] + 1, 2)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_H'] + 1, 3)
interp.set_script('BASIC_SKIP_SPACES', [({}, {})])
interp.set_script('BASIC_MATCH_KEYWORD_BOUNDARY', [MATCH])
interp.set_script('BASIC_EVAL_EXPR', [({'D': 0, 'E': 1}, {'C': 0})])
interp.set_script('BASIC_EXPECT_COMMA_EXPR', [
    ({'D': 0, 'E': 1}, {'C': 0}), ({'D': 0, 'E': 1}, {'C': 0}),
    ({'D': 0, 'E': 4}, {'C': 0}), ({'D': 0, 'E': 4}, {'C': 0})])
interp.set_script('BASIC_EXPECT_STATEMENT_END', [({}, {'C': 0})])
run(prog, interp, 'BASIC_STMT_SPRITE')
check('GRAB shown slot rejected', interp.sim.flags['C'], 1)
check('GRAB shown slot keeps W', interp.sim.rb(sim.SYSVARS['SPRITE_SLOT_W'] + 1), 2)
check('GRAB shown slot keeps H', interp.sim.rb(sim.SYSVARS['SPRITE_SLOT_H'] + 1), 3)

# =====================================================================
# 6. Full SHOW flow: slot 1 already GRAB'd (W=2,H=3), not shown yet;
#    SHOW at row=8,col=12
#    HL is deliberately made to ADVANCE distinctively on each scripted
#    call below (0x8010, 0x8020, 0x8030...) rather than sitting frozen
#    at its initial value — this is the fix for a real gap the ORIGINAL
#    version of this test had: scripted stubs don't touch HL unless
#    told to, so a version of this test that never varies HL could
#    never have caught the real bug [stated] hit (BASIC_STMT_SPRITE_
#    SHOW's flag lookups clobbering the live text-parse pointer between
#    BASIC_SPRITE_PARSE_SLOT and the row/col BASIC_EXPECT_COMMA_EXPR
#    calls) — HL just stayed wherever `run()` initially put it the
#    whole test, so there was nothing for a wrong value to disagree
#    with. Asserting HL going INTO each BASIC_EXPECT_COMMA_EXPR call
#    matches what the PREVIOUS call was scripted to leave it at closes
#    that gap: if anything between calls clobbers HL, this catches it.
# =====================================================================
prog, interp = new_interp()
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_DEFINED'] + 1, 1)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_SHOWN'] + 1, 0)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_W'] + 1, 2)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_H'] + 1, 3)
interp.set_script('BASIC_SKIP_SPACES', [({}, {})])
interp.set_script('BASIC_MATCH_KEYWORD_BOUNDARY', [NOMATCH, MATCH])
interp.set_script('BASIC_EVAL_EXPR', [({'D': 0, 'E': 1, 'H': 0x80, 'L': 0x10}, {'C': 0})])  # slot=1, HL->0x8010
interp.set_script('BASIC_EXPECT_COMMA_EXPR', [
    ({'D': 0, 'E': 8, 'H': 0x80, 'L': 0x20}, {'C': 0}),    # row=8, HL->0x8020
    ({'D': 0, 'E': 12, 'H': 0x80, 'L': 0x30}, {'C': 0}),   # col=12, HL->0x8030
])
interp.set_script('BASIC_EXPECT_STATEMENT_END', [({}, {'C': 0})])
interp.set_script('GFX_SPRITE_CAPTURE', [({}, {'C': 0})])
interp.set_script('GFX_SPRITE_DRAW', [({}, {'C': 0})])
run(prog, interp, 'BASIC_STMT_SPRITE')

# find the two BASIC_EXPECT_COMMA_EXPR call sites and check HL AT the
# moment of each call — this is the check that would have caught the
# real bug: HL must be exactly what the PRIOR call left it at (0x8010
# going into the row call, 0x8020 going into the col call), never a
# leftover SPRITE_SLOT_* array address from the flag lookups in between
comma_calls = [r for (sc, l, mn, op, r, fl) in interp.trace_log
               if mn == 'call' and op == 'BASIC_EXPECT_COMMA_EXPR']
if len(comma_calls) < 2:
    FAILURES.append(f'SHOW: expected 2 BASIC_EXPECT_COMMA_EXPR calls, got {len(comma_calls)}')
else:
    row_call_hl = (comma_calls[0]['H'] << 8) | comma_calls[0]['L']
    col_call_hl = (comma_calls[1]['H'] << 8) | comma_calls[1]['L']
    check('SHOW: HL into row-parse call == PARSE_SLOT\'s own exit HL (0x8010)', row_call_hl, 0x8010)
    check('SHOW: HL into col-parse call == row-parse\'s own exit HL (0x8020)', col_call_hl, 0x8020)

check('SHOW success carry', interp.sim.flags['C'], 0)
check('SHOW slot 1 SHOWN', interp.sim.rb(sim.SYSVARS['SPRITE_SLOT_SHOWN'] + 1), 1)
check('SHOW pushes display depth',
      interp.sim.rb(sim.SYSVARS['SPRITE_DISPLAY_DEPTH']), 1)
check('SHOW pushes slot number',
      interp.sim.rb(sim.SYSVARS['SPRITE_DISPLAY_STACK']), 1)
check('SHOW slot 1 ROW', interp.sim.rb(sim.SYSVARS['SPRITE_SLOT_ROW'] + 1), 8)
check('SHOW slot 1 COL', interp.sim.rb(sim.SYSVARS['SPRITE_SLOT_COL'] + 1), 12)

bg_capture_call = next(
    (r for (sc, l, mn, op, r, fl) in interp.trace_log
     if mn == 'call' and op and 'GFX_SPRITE_CAPTURE' in op), None)
draw_call = next(
    (r for (sc, l, mn, op, r, fl) in interp.trace_log
     if mn == 'call' and op and 'GFX_SPRITE_DRAW' in op), None)
if bg_capture_call is None:
    FAILURES.append('SHOW never captured background')
else:
    want_hl = sim.SYSVARS['SPRITE_SLOT_BG_BUF'] + 1 * sim.SYSVARS['SPRITE_SLOT_BYTES']
    got_hl = (bg_capture_call['H'] << 8) | bg_capture_call['L']
    check('SHOW->CAPTURE(bg) B/C/D/E', (bg_capture_call['B'], bg_capture_call['C'], bg_capture_call['D'], bg_capture_call['E']), (8, 12, 2, 3))
    check('SHOW->CAPTURE(bg) HL (slot 1 bg buffer)', got_hl, want_hl)
if draw_call is None:
    FAILURES.append('SHOW never drew the sprite image')
else:
    want_hl = sim.SYSVARS['SPRITE_SLOT_IMG_BUF'] + 1 * sim.SYSVARS['SPRITE_SLOT_BYTES']
    got_hl = (draw_call['H'] << 8) | draw_call['L']
    check('SHOW->DRAW(img) B/C/D/E', (draw_call['B'], draw_call['C'], draw_call['D'], draw_call['E']), (8, 12, 2, 3))
    check('SHOW->DRAW(img) HL (slot 1 img buffer)', got_hl, want_hl)

# ---- SHOW error paths ----
prog, interp = new_interp()  # slot not defined
interp.set_script('BASIC_SKIP_SPACES', [({}, {})])
interp.set_script('BASIC_MATCH_KEYWORD_BOUNDARY', [NOMATCH, MATCH])
interp.set_script('BASIC_EVAL_EXPR', [({'D': 0, 'E': 2}, {'C': 0})])
run(prog, interp, 'BASIC_STMT_SPRITE')
check('SHOW undefined slot carry', interp.sim.flags['C'], 1)
check('SHOW undefined slot message', interp.sim.rw(sim.SYSVARS['PENDING_ERROR_MSG']), sim.SYSVARS['MSG_SPRITE_NOT_DEFINED'])

prog, interp = new_interp()  # already shown
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_DEFINED'] + 1, 1)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_SHOWN'] + 1, 1)
interp.set_script('BASIC_SKIP_SPACES', [({}, {})])
interp.set_script('BASIC_MATCH_KEYWORD_BOUNDARY', [NOMATCH, MATCH])
interp.set_script('BASIC_EVAL_EXPR', [({'D': 0, 'E': 1}, {'C': 0})])
run(prog, interp, 'BASIC_STMT_SPRITE')
check('SHOW already-shown carry', interp.sim.flags['C'], 1)
check('SHOW already-shown message', interp.sim.rw(sim.SYSVARS['PENDING_ERROR_MSG']), sim.SYSVARS['MSG_SPRITE_ALREADY_SHOWN'])

# =====================================================================
# 7. Full HIDE flow: slot 1 shown at row=8,col=12,w=2,h=3
# =====================================================================
prog, interp = new_interp()
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_SHOWN'] + 1, 1)
interp.sim.wb(sim.SYSVARS['SPRITE_DISPLAY_DEPTH'], 1)
interp.sim.wb(sim.SYSVARS['SPRITE_DISPLAY_STACK'], 1)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_ROW'] + 1, 8)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_COL'] + 1, 12)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_W'] + 1, 2)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_H'] + 1, 3)
interp.set_script('BASIC_SKIP_SPACES', [({}, {})])
interp.set_script('BASIC_MATCH_KEYWORD_BOUNDARY', [NOMATCH, NOMATCH, MATCH])
interp.set_script('BASIC_EVAL_EXPR', [({'D': 0, 'E': 1}, {'C': 0})])
interp.set_script('BASIC_EXPECT_STATEMENT_END', [({}, {'C': 0})])
interp.set_script('GFX_SPRITE_DRAW', [({}, {'C': 0})])
run(prog, interp, 'BASIC_STMT_SPRITE')

check('HIDE success carry', interp.sim.flags['C'], 0)
check('HIDE slot 1 SHOWN cleared', interp.sim.rb(sim.SYSVARS['SPRITE_SLOT_SHOWN'] + 1), 0)
check('HIDE pops display depth',
      interp.sim.rb(sim.SYSVARS['SPRITE_DISPLAY_DEPTH']), 0)

hide_draw_call = next(
    (r for (sc, l, mn, op, r, fl) in interp.trace_log
     if mn == 'call' and op and 'GFX_SPRITE_DRAW' in op), None)
if hide_draw_call is None:
    FAILURES.append('HIDE never restored the background')
else:
    want_hl = sim.SYSVARS['SPRITE_SLOT_BG_BUF'] + 1 * sim.SYSVARS['SPRITE_SLOT_BYTES']
    got_hl = (hide_draw_call['H'] << 8) | hide_draw_call['L']
    check('HIDE->DRAW(bg) B/C/D/E', (hide_draw_call['B'], hide_draw_call['C'], hide_draw_call['D'], hide_draw_call['E']), (8, 12, 2, 3))
    check('HIDE->DRAW(bg) HL (slot 1 bg buffer)', got_hl, want_hl)

prog, interp = new_interp()  # not shown
interp.set_script('BASIC_SKIP_SPACES', [({}, {})])
interp.set_script('BASIC_MATCH_KEYWORD_BOUNDARY', [NOMATCH, NOMATCH, MATCH])
interp.set_script('BASIC_EVAL_EXPR', [({'D': 0, 'E': 1}, {'C': 0})])
interp.set_script('BASIC_EXPECT_STATEMENT_END', [({}, {'C': 0})])
run(prog, interp, 'BASIC_STMT_SPRITE')
check('HIDE not-shown carry', interp.sim.flags['C'], 1)
check('HIDE not-shown message', interp.sim.rw(sim.SYSVARS['PENDING_ERROR_MSG']), sim.SYSVARS['MSG_SPRITE_NOT_SHOWN'])

# MOVE parse failure is transactional: the old background is not drawn and
# the slot remains shown at its original coordinates.
prog, interp = new_interp()
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_SHOWN'] + 1, 1)
interp.sim.wb(sim.SYSVARS['SPRITE_DISPLAY_DEPTH'], 1)
interp.sim.wb(sim.SYSVARS['SPRITE_DISPLAY_STACK'], 1)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_ROW'] + 1, 8)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_COL'] + 1, 12)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_W'] + 1, 2)
interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_H'] + 1, 3)
interp.set_script('BASIC_SKIP_SPACES', [({}, {})])
interp.set_script('BASIC_MATCH_KEYWORD_BOUNDARY',
                  [NOMATCH, NOMATCH, NOMATCH, MATCH])
interp.set_script('BASIC_EVAL_EXPR', [({'D': 0, 'E': 1}, {'C': 0})])
interp.set_script('BASIC_EXPECT_COMMA_EXPR', [({}, {'C': 1})])
run(prog, interp, 'BASIC_STMT_SPRITE')
move_draws = [r for (sc, l, mn, op, r, fl) in interp.trace_log
              if mn == 'call' and op == 'GFX_SPRITE_DRAW']
check('MOVE parse failure does not erase sprite', len(move_draws), 0)
check('MOVE parse failure leaves SHOWN set',
      interp.sim.rb(sim.SYSVARS['SPRITE_SLOT_SHOWN'] + 1), 1)
check('MOVE parse failure leaves ROW',
      interp.sim.rb(sim.SYSVARS['SPRITE_SLOT_ROW'] + 1), 8)
check('MOVE parse failure leaves COL',
      interp.sim.rb(sim.SYSVARS['SPRITE_SLOT_COL'] + 1), 12)

# Two displayed slots model an overlap-capable save-under stack.  Removing a
# lower slot first must fail before drawing; the upper slot remains removable.
prog, interp = new_interp()
for slot in (0, 1):
    interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_SHOWN'] + slot, 1)
    interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_ROW'] + slot, 4)
    interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_COL'] + slot, 4)
    interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_W'] + slot, 2)
    interp.sim.wb(sim.SYSVARS['SPRITE_SLOT_H'] + slot, 2)
interp.sim.wb(sim.SYSVARS['SPRITE_DISPLAY_DEPTH'], 2)
interp.sim.wb(sim.SYSVARS['SPRITE_DISPLAY_STACK'], 0)
interp.sim.wb(sim.SYSVARS['SPRITE_DISPLAY_STACK'] + 1, 1)
interp.set_script('BASIC_EVAL_EXPR', [({'D': 0, 'E': 0}, {'C': 0})])
interp.set_script('BASIC_EXPECT_STATEMENT_END', [({}, {'C': 0})])
run(prog, interp, 'BASIC_STMT_SPRITE_HIDE')
order_draws = [r for (sc, l, mn, op, r, fl) in interp.trace_log
               if mn == 'call' and op == 'GFX_SPRITE_DRAW']
check('out-of-order HIDE rejected before drawing', len(order_draws), 0)
check('out-of-order HIDE reports order error',
      interp.sim.rw(sim.SYSVARS['PENDING_ERROR_MSG']),
      sim.SYSVARS['MSG_SPRITE_ORDER'])
check('out-of-order HIDE preserves depth',
      interp.sim.rb(sim.SYSVARS['SPRITE_DISPLAY_DEPTH']), 2)
check('out-of-order HIDE preserves shown state',
      interp.sim.rb(sim.SYSVARS['SPRITE_SLOT_SHOWN']), 1)

# ---- report -----------------------------------------------------------
if FAILURES:
    print(f"FAILED ({len(FAILURES)} failing checks):")
    for f in FAILURES:
        print(' -', f)
    sys.exit(1)
else:
    print("ALL CHECKS PASSED (SPRITE GRAB/SHOW/HIDE/MOVE)")

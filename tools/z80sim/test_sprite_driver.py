#!/usr/bin/env python3
"""
test_sprite_driver.py — real-instruction z80sim verification for the
2026-08-19 Sprites feature (GFX_SPRITE_CAPTURE / GFX_SPRITE_DRAW,
kernel/graphics/graphics.asm), and their two small address-math
helpers (GFX_CELL_BITMAP_ADDR / GFX_CELL_ATTR_ADDR) plus
GFX_SPRITE_BOUNDS_CHECK / GFX_SPRITE_CELL_ROWCOL.

Not a leftover file in the tree — run manually when touching this
feature again; not part of any CI step in this project.
"""
import sys
sys.path.insert(0, 'tools/z80sim')
import sim

# ---- extend SYSVARS with this test's own addresses -----------------
# ROW_BASE_TABLE's placement here ($9000) is arbitrary scratch chosen
# only for this test — its CONTENT below is the real, hardware-
# confirmed table straight from kernel/graphics/graphics.asm, not
# invented, so the address math this test exercises is checked against
# real production data.
ROW_BASE_TABLE_ADDR = 0x9000
sim.SYSVARS['ROW_BASE_TABLE'] = ROW_BASE_TABLE_ADDR
sim.SYSVARS['ATTR_ADDR'] = 0x5800  # already present upstream; restated
                                    # for clarity, same value
sim.SYSVARS['SPRITE_BUF_PTR'] = 0x9558
sim.SYSVARS['SPRITE_TOP_ROW'] = 0x955A
sim.SYSVARS['SPRITE_TOP_COL'] = 0x955B
sim.SYSVARS['SPRITE_W'] = 0x955C
sim.SYSVARS['SPRITE_H'] = 0x955D
sim.SYSVARS['SPRITE_ROW_IDX'] = 0x955E
sim.SYSVARS['SPRITE_COL_IDX'] = 0x955F
sim.SYSVARS['SPRITE_SLOT_SHOWN'] = 0x9560
sim.SYSVARS['SPRITE_DISPLAY_DEPTH'] = 0x9568
sim.SYSVARS['SPRITE_SLOT_MAX'] = 8

REAL_ROW_BASE_TABLE = [
    0x4000, 0x4020, 0x4040, 0x4060, 0x4080, 0x40A0, 0x40C0, 0x40E0,
    0x4800, 0x4820, 0x4840, 0x4860, 0x4880, 0x48A0, 0x48C0, 0x48E0,
    0x5000, 0x5020, 0x5040, 0x5060, 0x5080, 0x50A0, 0x50C0, 0x50E0,
]

FAILURES = []

def check(label, got, want):
    if got != want:
        FAILURES.append(f"{label}: got {got!r}, want {want!r}")

def bitmap_addr(row, col, scanline):
    return REAL_ROW_BASE_TABLE[row] + col + scanline * 256

def attr_addr(row, col):
    return 0x5800 + row * 32 + col

def build_program():
    prog = sim.Program()
    prog.load_file('kernel/graphics/graphics.asm')
    return prog

def new_sim():
    s = sim.Z80Sim()
    for i, addr in enumerate(REAL_ROW_BASE_TABLE):
        s.ww(ROW_BASE_TABLE_ADDR + i * 2, addr)
    return s

def run_from(prog, s, label, b, c, d, e, hl):
    interp = sim.Interp(prog, s)
    s.regs['B'], s.regs['C'], s.regs['D'], s.regs['E'] = b, c, d, e
    s.regs['H'], s.regs['L'] = (hl >> 8) & 0xFF, hl & 0xFF
    s.push(('HALT',))
    try:
        interp.run(label, None)
    except sim.Halt as ex:
        if 'clean stop' not in str(ex):
            raise
    return s

# ---- test 1: CAPTURE reads the right bytes from the right cells,
# in the documented 9-bytes-per-cell row-major buffer order ----------
prog = build_program()
s = new_sim()

# seed 4 cells (rows 0-1, cols 0-1) with distinct, identifiable content
cell_bitmap = {
    (0,0): [0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18],
    (0,1): [0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28],
    (1,0): [0x31,0x32,0x33,0x34,0x35,0x36,0x37,0x38],
    (1,1): [0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48],
}
cell_attr = {(0,0): 0x51, (0,1): 0x52, (1,0): 0x53, (1,1): 0x54}
for (row, col), bytes8 in cell_bitmap.items():
    for scan, byte in enumerate(bytes8):
        s.wb(bitmap_addr(row, col, scan), byte)
for (row, col), a in cell_attr.items():
    s.wb(attr_addr(row, col), a)

BUF = 0xA000
run_from(prog, s, 'GFX_SPRITE_CAPTURE', b=0, c=0, d=2, e=2, hl=BUF)

expected = []
for row in (0, 1):
    for col in (0, 1):
        expected.extend(cell_bitmap[(row, col)])
        expected.append(cell_attr[(row, col)])
got = [s.rb(BUF + i) for i in range(36)]
check('CAPTURE buffer contents (2x2 cells, row-major, 9B/cell)', got, expected)
check('CAPTURE success (carry clear)', s.flags['C'], 0)
check('SPRITE_BUF_PTR advanced by 36 (4 cells x 9B)',
      s.rw(sim.SYSVARS['SPRITE_BUF_PTR']), BUF + 36)

# ---- test 2: DRAW restores the SAME captured buffer back onto the
# SAME position after the screen is corrupted — save/restore round
# trip, the core sprite-hide use case -----------------------------
for (row, col) in cell_bitmap:
    for scan in range(8):
        s.wb(bitmap_addr(row, col, scan), 0xFF)  # corrupt
    s.wb(attr_addr(row, col), 0xFF)

run_from(prog, s, 'GFX_SPRITE_DRAW', b=0, c=0, d=2, e=2, hl=BUF)

for (row, col), bytes8 in cell_bitmap.items():
    for scan, byte in enumerate(bytes8):
        check(f'DRAW restored bitmap row{row}col{col}scan{scan}',
              s.rb(bitmap_addr(row, col, scan)), byte)
for (row, col), a in cell_attr.items():
    check(f'DRAW restored attr row{row}col{col}', s.rb(attr_addr(row, col)), a)
check('DRAW success (carry clear)', s.flags['C'], 0)

# ---- test 3: DRAW to a DIFFERENT position (the COPY / "move sprite"
# use case) — same captured buffer, drawn at row=5,col=10 this time --
s2 = new_sim()
for (row, col), bytes8 in cell_bitmap.items():
    for scan, byte in enumerate(bytes8):
        s2.wb(bitmap_addr(row, col, scan), byte)
for (row, col), a in cell_attr.items():
    s2.wb(attr_addr(row, col), a)
run_from(prog, s2, 'GFX_SPRITE_CAPTURE', b=0, c=0, d=2, e=2, hl=BUF)
run_from(prog, s2, 'GFX_SPRITE_DRAW', b=5, c=10, d=2, e=2, hl=BUF)

for r_off in (0, 1):
    for c_off in (0, 1):
        src_row, src_col = r_off, c_off
        dst_row, dst_col = 5 + r_off, 10 + c_off
        for scan, byte in enumerate(cell_bitmap[(src_row, src_col)]):
            check(f'COPY dest bitmap row{dst_row}col{dst_col}scan{scan}',
                  s2.rb(bitmap_addr(dst_row, dst_col, scan)), byte)
        check(f'COPY dest attr row{dst_row}col{dst_col}',
              s2.rb(attr_addr(dst_row, dst_col)), cell_attr[(src_row, src_col)])

# ---- test 4: bounds rejection — top+height > 24 must be refused,
# leaving the buffer/screen untouched -------------------------------
s3 = new_sim()
sentinel_buf = 0xB000
for i in range(9):
    s3.wb(sentinel_buf + i, 0xAA)
run_from(prog, s3, 'GFX_SPRITE_CAPTURE', b=23, c=0, d=1, e=2, hl=sentinel_buf)
check('CAPTURE out-of-range top+height>24 rejected (carry set)', s3.flags['C'], 1)
check('CAPTURE out-of-range: buffer untouched', s3.rb(sentinel_buf), 0xAA)

s4 = new_sim()
run_from(prog, s4, 'GFX_SPRITE_CAPTURE', b=0, c=31, d=2, e=1, hl=sentinel_buf)
check('CAPTURE out-of-range top+width>32 rejected (carry set)', s4.flags['C'], 1)

s5 = new_sim()
run_from(prog, s5, 'GFX_SPRITE_CAPTURE', b=0, c=0, d=0, e=1, hl=sentinel_buf)
check('CAPTURE width=0 rejected (carry set)', s5.flags['C'], 1)

s6 = new_sim()
run_from(prog, s6, 'GFX_SPRITE_CAPTURE', b=0, c=0, d=1, e=0, hl=sentinel_buf)
check('CAPTURE height=0 rejected (carry set)', s6.flags['C'], 1)

# ---- test 5: global screen transformations invalidate displayed state ----
s7 = new_sim()
for slot in range(8):
    s7.wb(sim.SYSVARS['SPRITE_SLOT_SHOWN'] + slot, slot + 1)
s7.wb(sim.SYSVARS['SPRITE_DISPLAY_DEPTH'], 8)
run_from(prog, s7, 'GFX_SPRITE_INVALIDATE', b=0, c=0, d=0, e=0, hl=0)
check('INVALIDATE clears every shown flag',
      [s7.rb(sim.SYSVARS['SPRITE_SLOT_SHOWN'] + i) for i in range(8)],
      [0] * 8)
check('INVALIDATE clears display depth',
      s7.rb(sim.SYSVARS['SPRITE_DISPLAY_DEPTH']), 0)

# ---- report ----------------------------------------------------------
total_checks = 'many'
if FAILURES:
    print(f"FAILED ({len(FAILURES)} failing checks):")
    for f in FAILURES:
        print(' -', f)
    sys.exit(1)
else:
    print("ALL CHECKS PASSED (sprite graphics primitives and invalidation)")

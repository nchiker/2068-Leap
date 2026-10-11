#!/usr/bin/env python3
"""STUDY: BREAK (VM_HALTED set by the ISR) interrupts a long FILL promptly."""
import os, sys, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ["V2_FILL_NO_REBUILD"] = "1"
import v2_fill_check as F
import v2_known_defects as K
from v2_headless import *
sys.argv = [sys.argv[0]]
img, sx, sy = K._fill_scenarios()["staggered-dots"]
F.start()
D("mem-write", hex(F.BASE), open("build/v2_package_shapes.bin", "rb").read().hex())
D("mem-write", "0x4000", F.to_bytes(img).hex())
for sym, v in (("GFX_FILL_X", sx), ("GFX_FILL_Y", sy), ("GFX_FILL_ATTR", 0x38)):
    D("mem-write", hex(HSYM[sym]), bytes([v]).hex())
w = lambda v: struct.pack("<H", v)
body = b"\xCD" + w(HSYM["BANK_PAGE_EXROM_OUT"]) + b"\xCD" + w(F.PKG["SHAPES_GFX_FILL"])
done = 0xFE00 + len(body)
D("mem-write", "0xFE00", (body + b"\x18\xFE").hex())
D("mem-write", hex(HSYM["VM_HALTED"]), b"\x00".hex())
D("set-register", "SP", "0xFDF0"); D("set-register", "PC", "0xFE00")
D("run", "--until", hex(done), "--max-instructions", "20000000", t=900)   # 20M instructions, far from finishing
D("pause")
pc1 = D("regs")["registers"]["PC"]
D("mem-write", hex(HSYM["VM_HALTED"]), b"\x01".hex())                      # what the ISR does on BREAK
D("run", "--until", hex(done), "--max-instructions", "2000000", t=300)
D("pause")
pc2 = D("regs")["registers"]["PC"]
print("running before BREAK: %s; returned to the caller after BREAK: %s" % (pc1 != done, pc2 == done))
D("stop")
sys.exit(0 if (pc1 != done and pc2 == done) else 1)

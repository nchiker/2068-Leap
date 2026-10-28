#!/usr/bin/env python3
"""6.5 (docs/V2_LEAPC_BACKPORT_PLAN.md): the machine stack a package uses, measured.

For each program below, the package's execute routine is caught where OP_CALL_EXT calls it (`call
VM_CALL_INDIRECT`, found in build/test_basic.lst): SP there is the stack at the call, the stack below
it is filled with a canary byte, the routine runs, and on its return the lowest byte that changed
gives the depth: the call's own return address, the routine, the services it called and any
interrupt taken meanwhile (for an error raised in the package, at VM_ERR_COMMON). Each program runs twice, with canaries $A5 and $5A (a byte pushed that
equals the canary is not missed twice). The install (the package's first instruction, called with SP
= $FF00 as LOAD ... EXT's harness does) is measured the same way. Then the interrupt routine on its
own: at $0038 (IM 1) the stack below SP is filled and the interrupted PC is caught on the return;
the deepest of 200 interrupts, the pushed PC included, is the cost of an interrupt on top of a
package's own depth.

Usage: python3 tools/qual/qpkgstack.py [--tree DIR] [--port N]
"""
import argparse
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine, HARNESS_RET_SLOT          # noqa: E402

FLOOR = 0xF800                     # $F800-$FEFF is stack only (docs/PACKAGE_ABI.md s2)

# (package, program): the heaviest paths of each shipped package and of the ABI 2.1 test packages
PROGRAMS = [
    ("shapes", ["CIRCLE 128,96,90", "CIRCLE 10,10,40", "FILL 128,96", "CIRCLE 200,100,30", "FILL 5,5"]),
    ("sprite", ["GRAB 0,0,0,4,4", "SHOW 0,2,2", "MOVE 0,7,8", "MOVE 0,20,28", "HIDE 0", "SHOW 1,2,2"]),
    ("sprite", ["GRAB 9,0,0,1,1"]),
    ("mode", ["MODE 1", "MODE 0", "ULAPLUS 1", "PALETTE 3,255", "ULAPLUS 0", "MODE 5"]),
    ("graphics", ["BLOCK 0,0,255,191", "FRAME 0,0,255,191", "CPLOT 20,20", "INVERT 0,0,255,191"]),
    ("printer", ["LPRINT 12345", "LPRINT -32768", 'a$ = "hello"', "LPRINT a$", "LLIST"]),
    ("cbeep", ["CBEEP 10, 0, 7", "CBEEP 1, 24, 2", "CBEEP 0, -60, 1", "CBEEP 99, 99, 0"]),
    ("fntest", ["PRINT ADD3(1, 2, 3)", "PRINT HEX$(48879)", 'PRINT MIX(1, 2, "abc", 4, 5)',
                'PRINT REV$("abcdefghijklmnopqrstuvwxyz01234")', "SETR 3", "PRINT BAD(1)"]),
    ("fptest", ["PRINT FADD(1.5, 2.25)", "PRINT FDIV(1, 3)", "PRINT FPOLY(1, 2, 3, 4, 5)", "PRINT FTI(-7.9)",
                "PRINT FSGN$(-1)", "PRINT TRYREG(1)", "PRINT FDIV(1, 0)"]),
    ("fptest", ["PRINT RAISE(13)"]),
    # the VM's own depth at the call: in a user function, in a recursive PROC, in a deep expression
    ("fntest", ["DEF FN f(x) = ADD3(x, 1, 1)", "DEF FN g(x) = FN f(x) * 2", "PRINT FN g(2)"]),
    ("shapes", ["CALL r(20)", "END", "PROC r(n):", "IF n > 0 THEN", "CALL r(n - 1)", "ENDIF", "CIRCLE 128,96,n", "ENDP"]),
    ("fntest", ["PRINT 1 + (2 * (3 + (4 * (5 + (6 * (7 + ADD3(1, 2, ADD3(1, 1, 1))))))))"]),
    ("fptest", ["PRINT TRAP(0)"]),
]


def call_site(tree):
    """The address of OP_CALL_EXT's `call VM_CALL_INDIRECT` in the HOME listing."""
    inside = False
    for line in open(os.path.join(tree, "build", "test_basic.lst"), errors="replace"):
        if re.search(r"\bOP_CALL_EXT:", line):
            inside = True
        elif inside and re.search(r"\bcall\s+VM_CALL_INDIRECT\b", line):
            return int(line.split()[1], 16)
    raise SystemExit("OP_CALL_EXT's call VM_CALL_INDIRECT not found in build/test_basic.lst")


def lowest_changed(m, lo, hi, canary):
    data = m.read(lo, hi - lo)
    for i, b in enumerate(data):
        if b != canary:
            return lo + i
    return hi


class Probe:
    def __init__(self, m, site):
        self.m = m
        self.site = site
        self.back = site + 3
        self.exits = (m.sym("IO_READ_KEY"), m.sym("V2_COMMAND_LOOP.loop"))
        self.err = m.sym("VM_ERR_COMMON")

    def install(self, name, canary):
        """Install `name` as the harness does, measuring its stack: depth below $FF00."""
        m = self.m
        blob = open(os.path.join(m.cfgdir, "build", "v2_package_%s.bin" % name), "rb").read()
        m.write(m.sym("EXTENSION_MODULE_BASE"), blob)
        m.poke16(m.sym("V2_PACKAGE_LEN"), len(blob))
        m.write(0xFE00, b"\x18\xFE")
        m.write(FLOOR, bytes([canary]) * (HARNESS_RET_SLOT - FLOOR))
        m.write(HARNESS_RET_SLOT, struct.pack("<H", 0xFE00))
        m.setreg("SP", HARNESS_RET_SLOT)
        m.setreg("PC", m.sym("EXTENSION_MODULE_BASE"))
        m.set_bps([0xFE00])
        m.run(3_000_000)
        assert m.pc() == 0xFE00 and not (m.regs()["AF"] & 1), "package %s did not install" % name
        return HARNESS_RET_SLOT - lowest_changed(m, FLOOR, HARNESS_RET_SLOT, canary)

    def run(self, pkg, lines, canary, command=None):
        """Run `lines` with `pkg` installed (with `command`, that line through V2_DISPATCH as the
        command loop runs it); return (install depth, [(exec address, SP at the call, depth)]) for
        every package call, and the VM error code."""
        m = self.m
        m.restore()
        inst = self.install(pkg, canary)
        m.put_store(lines)
        m.write(HARNESS_RET_SLOT, struct.pack("<H", self.exits[1]))
        m.setreg("SP", HARNESS_RET_SLOT)
        if command:
            m.write(m.sym("EDIT_LINE_BUF"), command.encode("latin-1") + b"\0")
        m.setreg("PC", m.sym("V2_DISPATCH" if command else "V2_RUN_STORED"))
        calls = []
        pending = None
        quiet = 0                           # runs of 80M instructions with no stop
        while quiet < 8:
            if not pending:
                m.set_bps([self.site, self.exits[0], self.exits[1]])
            m.run(80_000_000)
            r = m.regs()
            pc, sp = r["PC"], r["SP"]
            if pc not in (self.site, self.back, self.err) + self.exits:
                quiet += 1
                continue
            if pc == self.site:
                m.write(FLOOR, bytes([canary]) * (sp - FLOOR))
                pending = (r["DE"], sp)
                m.set_bps([self.back, self.err, self.exits[0], self.exits[1]])
                continue
            if pc == self.back and pending:
                target, at = pending
                calls.append((target, at, at - lowest_changed(m, FLOOR, at, canary)))
                pending = None
                m.step()
                continue
            if pc == self.err and pending:  # an error raised in the package: measured where it unwinds
                target, at = pending
                calls.append((target, at, at - lowest_changed(m, FLOOR, at, canary)))
                pending = None
                continue
            if pc in self.exits:
                break
        else:
            raise RuntimeError("%s: the program did not finish (PC $%04X)" % (pkg, pc))
        ce = m.read(m.sym("COMPILE_ERROR_CODE"), 1)[0]
        assert ce == 0, "%s: compile error %d" % (pkg, ce)
        return inst, calls, m.read(m.sym("VM_ERROR_CODE"), 1)[0]

    def isr(self, canary, n=200):
        """The deepest of n interrupts taken while a program runs (the pushed PC included)."""
        m = self.m
        m.restore()
        m.put_store(["FOR i = 1 TO 30000", "a = a + 1", "NEXT i"])
        m.write(HARNESS_RET_SLOT, struct.pack("<H", self.exits[1]))
        m.setreg("SP", HARNESS_RET_SLOT)
        m.setreg("PC", m.sym("V2_RUN_STORED"))
        worst = 0
        for _ in range(n):
            m.set_bps([0x0038, self.exits[0], self.exits[1]])
            m.run(80_000_000)
            r = m.regs()
            if r["PC"] != 0x0038:
                break
            sp = r["SP"]
            ret = m.w16(sp)
            m.write(FLOOR, bytes([canary]) * (sp - FLOOR))
            m.set_bps([ret])
            m.run(1_000_000)
            assert m.pc() == ret, "the interrupt did not return to $%04X" % ret
            worst = max(worst, sp + 2 - lowest_changed(m, FLOOR, sp, canary))
        return worst


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=os.getcwd())
    ap.add_argument("--port", type=int, default=10320)
    a = ap.parse_args()
    m = Machine(a.tree, a.port)
    m.start()
    p = Probe(m, call_site(a.tree))
    worst_call = worst_inst = 0
    entry_sps = set()
    try:
        for pkg, lines in PROGRAMS:
            per = {}
            inst = 0
            ve = None
            for canary in (0xA5, 0x5A):
                i, calls, ve = p.run(pkg, lines, canary)
                inst = max(inst, i)
                for target, at, depth in calls:
                    entry_sps.add(at - 2)
                    per[target] = max(per.get(target, 0), depth)
            worst_inst = max(worst_inst, inst)
            deep = max(per.values()) if per else 0
            worst_call = max(worst_call, deep)
            print("%-9s install %3d B; calls: %s; ve=%d   %s" % (
                pkg, inst, ", ".join("$%04X %d B" % (t, d) for t, d in sorted(per.items())), ve, " / ".join(lines)))
        isr = max(p.isr(0xA5), p.isr(0x5A))
        # the command loop calls V2_DISPATCH with SP = $FF00 (V2_MACHINE_STACK_TOP; the harness's
        # return slot puts it at $FF02): a package's SP at entry as RUN and an immediate statement have it
        prod = []
        for command in ("RUN", ": CIRCLE 128,96,20"):
            _, calls, _ = p.run("shapes", ["CIRCLE 128,96,20"], 0xA5, command)
            prod.append((command, min(at for _, at, _ in calls) - 2 - 2))
    finally:
        m.stop()
    print("interrupt: %d B (the pushed PC included)" % isr)
    print("SP at a package's entry: %s (V2_RUN_STORED called with SP = $FF00); in the command loop: %s"
          % (", ".join("$%04X" % s for s in sorted(entry_sps)), ", ".join("%s $%04X" % c for c in prod)))
    print("deepest execute call %d B (its return address included), with an interrupt %d B; deepest install %d B"
          % (worst_call, worst_call + isr, worst_inst))
    return 0


if __name__ == "__main__":
    sys.exit(main())

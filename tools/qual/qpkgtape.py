#!/usr/bin/env python3
"""The tape stamp (docs/V2_LEAPC_BACKPORT_PLAN.md, the open item from 6.1): package tapes carry the
minor their package needs, so the statement-only packages load on a v2.0.x ROM again.

Each package's tape blocks are made as `make v2-packages` makes them (tools/qual/manual_tapes.py
package_blocks: the word from tools/v2_abi.py needed_minor) from this tree's build, and LOADed EXT
through the real tape receiver of each ROM given (--rom TREE, a built tree: this one by default;
e.g. a v2.0.2-emu.1 tree built from its tag). A package the ROM's ABI minor covers must say LOADED,
install and run one statement with no error; one it does not must say BAD TAPE VERSION.

Usage: python3 tools/qual/qpkgtape.py [--tree DIR] [--rom TREE ...] [--port N]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import manual_tapes                    # noqa: E402
import v2_abi                          # noqa: E402

# (package, one statement and a PRINT; the output is not compared: no glyph table on a tape boot)
PROGRAMS = [
    ("mode", ["MODE 0", "PRINT 1"]),
    ("sprite", ["GRAB 0, 2, 3, 2, 2", "PRINT 1"]),
    ("printer", ["LPRINT 1", "PRINT 1"]),
    ("shapes", ["CIRCLE 128, 96, 20", "PRINT 1"]),
    ("graphics", ["CPLOT 20, 20", "PRINT 1"]),
    ("cbeep", ["CBEEP 10, 0, 7", "PRINT 1"]),
    ("fntest", ["PRINT SEVEN()"]),
    ("fptest", ["PRINT FADD(1, 2)"]),
]


def rom_minor(tree):
    return v2_abi.Abi(os.path.join(tree, "include", "v2_package_abi.inc")).minor


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=os.getcwd())
    ap.add_argument("--rom", action="append")
    ap.add_argument("--port", type=int, default=10340)
    a = ap.parse_args()
    abi = v2_abi.load()
    fails, n = [], 0
    for k, tree in enumerate(a.rom or [a.tree]):
        tree = os.path.abspath(tree)
        have = rom_minor(tree)
        for j, (pkg, lines) in enumerate(PROGRAMS):
            blocks = manual_tapes.package_blocks(pkg)
            word = blocks[0][1][13] | blocks[0][1][14] << 8
            want = "LOADED" if (word & 0xFF) <= have else "BAD_VERSION"
            m = manual_tapes.boot_with_tape(tree, a.port + 20 * k + j, {}, blocks)
            try:
                m.write(m.sym("EDIT_LINE_BUF"), ('LOAD "%s" EXT' % pkg.upper()).encode() + b"\0")
                r = m.call_routine("V2_DISPATCH", maxi=900_000_000)
                ok = r.msg == want
                run = ""
                if ok and want == "LOADED":
                    m.put_store(lines)
                    rr = m.call_routine("V2_RUN_STORED", maxi=80_000_000)
                    ok = rr.status == "OK" and rr.ce == 0 and rr.ve == 0
                    run = " run ce=%d ve=%d %s" % (rr.ce, rr.ve, rr.status)
            finally:
                m.stop()
            n += 1
            print("%s  ROM 2.%d %-9s tape $%04X: %s (want %s)%s" % ("PASS" if ok else "FAIL", have, pkg, word,
                                                                  r.msg, want, run))
            if not ok:
                fails.append((tree, pkg))
    print("qpkgtape: %d/%d PASS" % (n - len(fails), n))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

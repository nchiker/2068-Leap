#!/usr/bin/env python3
"""MAINT (ClassicBEEP study): the CBEEP package through the real tape receiver, on this tree's
production image (build/, after `make build v2-packages`).

    TS2068_DEBUG_STATE_DIR=<dir> TS2068_V2_PORT=<port> python3 tools/maint/cbeep_tape_test.py

LOAD "CBEEP" EXT from a synthesised EAR stream (tools/tape_synth.py), registry check, a program that
uses it; then a second package LOADed over it (the window holds one package at a time); then a
CBEEP tape with the newer ABI minor word is refused.  Runs with the gate's runner (v2_prod).
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from v2_prod import *            # noqa: E402,F401,F403
import v2_prod as P              # noqa: E402
import tape_synth as TS          # noqa: E402
import v2_abi                    # noqa: E402

ABI = v2_abi.load()
BLOB = open("build/v2_package_cbeep.bin", "rb").read()
SHAPES = open("build/v2_package_shapes.bin", "rb").read()


def pkg_tape(*pkgs):
    t = TS.Tape()
    for name, blob, word in pkgs:
        t.block(TS.framed(0, TS.header_payload(4, name, len(blob), autostart=word)))
        t.block(TS.framed(0xFF, blob))
    return t


def names():
    out = []
    for i in range(12):
        rec = P.read(0xBF00 + 14 * i, 14)
        if rec[0]:
            out.append(rec[2:2 + rec[1]].decode("latin-1"))
    return out


def load(name):
    P.poke(P.sym("EDIT_LINE_BUF"), b'load "%s" EXT\0' % name.encode())
    return P.call_prompt("V2_DISPATCH", maxi=900_000_000)


@case("cbeep-tape-load", "LOAD \"CBEEP\" EXT through the real receiver installs CBEEP; a program uses it")
def tape_load():
    P.boot(pkg_tape(("CBEEP", BLOB, ABI.pkg_word)))
    msg = load("CBEEP")
    reg, ln = names(), P.w16(P.sym("V2_PACKAGE_LEN"))
    P.put_store(["BORDER 1", "CBEEP 100,0,1", "CBEEP 50,12,1", 'PRINT "ok"'])
    P.call_prompt("V2_RUN_STORED")
    ve = P.read(P.sym("VM_ERROR_CODE"), 1)[0]
    ce = P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    return msg == "LOADED" and reg == ["CBEEP"] and ln == len(BLOB) and ve == 0 and ce == 0, \
        "msg=%s registry=%s len=%d ce=%d ve=%d" % (msg, reg, ln, ce, ve)


@case("cbeep-replaced", "a second package LOADed after CBEEP replaces it: CBEEP is then a compile error")
def replaced():
    P.boot(pkg_tape(("CBEEP", BLOB, ABI.pkg_word), ("SHAPES", SHAPES, ABI.pkg_word)))
    m1 = load("CBEEP")
    m2 = load("SHAPES")
    reg = names()
    P.put_store(["CBEEP 100,0,7"])
    P.call_prompt("V2_RUN_STORED")
    ce = P.read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
    return m1 == "LOADED" and m2 == "LOADED" and reg == ["CIRCLE", "FILL"] and ce != 0, \
        "msgs=%s,%s registry=%s ce=%d" % (m1, m2, reg, ce)


@case("cbeep-newer-minor", "a CBEEP tape stamped with a newer ABI minor (e.g. one needing a 2.1 pin) is refused")
def newer_minor():
    P.boot(pkg_tape(("CBEEP", BLOB, ABI.pkg_word + 1)))
    msg = load("CBEEP")
    return msg == "BAD_VERSION" and names() == [] and P.w16(P.sym("V2_PACKAGE_LEN")) == 0, \
        "msg=%s registry=%s" % (msg, names())


if __name__ == "__main__":
    sys.exit(run_cases(sys.argv[1:] or None, label="cbeep tape"))

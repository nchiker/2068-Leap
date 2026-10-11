#!/usr/bin/env python3
"""STUDY: U6 -- display/attribute state restored on return to the editor.
Run: TS2068_DEBUG_STATE_DIR=<dir> TS2068_V2_PORT=<port> python3 tools/study_u6.py [substr]"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_prod import *            # noqa: E402,F401,F403
import v2_prod as P              # noqa: E402


def attrs():
    names = ("CURRENT_INK", "CURRENT_PAPER", "CURRENT_BRIGHT", "CURRENT_FLASH", "CURRENT_OVER", "CURRENT_INVERSE")
    return {n[8:]: P.read(P.sym(n), 1)[0] for n in names}


@case("u6-colour-state-restored", "INK/PAPER/FLASH/BRIGHT/OVER/INVERSE and BORDER are default again in the editor")
def colours():
    P.boot()
    P.put_store(["INK 2", "PAPER 5", "FLASH 1", "BRIGHT 1", "OVER 1", "INVERSE 1", "BORDER 2"])
    P.call_prompt("V2_RUN_STORED")
    in_prog = attrs()
    P.key(0x20)
    back = attrs()
    want = {"INK": 0, "PAPER": 7, "BRIGHT": 0, "FLASH": 0, "OVER": 0, "INVERSE": 0}
    return in_prog["INK"] == 2 and back == want, "during=%s back=%s" % (in_prog, back)


@case("u6-mode1-return", "MODE 1 program: editor comes back in video mode 0 with the status bar attribute")
def mode1():
    P.boot()
    assert P.install_package("mode")
    P.put_store(["MODE 1"])
    P.call_prompt("V2_RUN_STORED")
    in_prog = P.read(P.sym("PORT_FF_SHADOW"), 1)[0] & 7
    P.key(0x20)
    back = P.read(P.sym("PORT_FF_SHADOW"), 1)[0] & 7
    status_attr = P.read(0x5800 + 23 * 32 + 4, 1)[0]
    return in_prog != 0 and back == 0 and status_attr == 0x07, "mode bits run=%d editor=%d status-bar attr=%02X" % (in_prog, back, status_attr)


@case("u6-border", "BORDER set by a program is white again in the editor")
def border():
    P.boot()
    P.put_store(["BORDER 2"])
    P.call_prompt("V2_RUN_STORED")
    during = P.read(P.sym("PORT_FE_SHADOW"), 1)[0] & 7 if "PORT_FE_SHADOW" in P.SYM or "PORT_FE_SHADOW" in P.HSYM else None
    P.key(0x20)
    back = P.read(P.sym("PORT_FE_SHADOW"), 1)[0] & 7 if during is not None else None
    return back == 7, "border during=%s back=%s" % (during, back)


@case("u6-second-run-clean", "a second RUN does not inherit colours from the first")
def second_run():
    P.boot()
    P.put_store(["INK 3", "x = 1"])
    P.call_prompt("V2_RUN_STORED")
    P.key(0x20)
    P.put_store(["x = 2"])
    P.call_prompt("V2_RUN_STORED")
    return attrs()["INK"] == 0, "INK after second run=%d" % attrs()["INK"]


if __name__ == "__main__":
    sys.exit(run_cases(sys.argv[1:] or None, "study-u6"))

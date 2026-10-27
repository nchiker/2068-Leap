#!/usr/bin/env python3
"""Item VER (docs/V2_LEAPC_BACKPORT_PLAN.md, owner F22): the ROM's version at power-on.

Boots the production ROM from reset and checks:
  - at STARTUP_CHIME's entry and at its return, row 23 shows the version (include/v2_version.inc) with
    the status-bar attribute: the text is up before the chime's first note and still up after its last;
  - at the editor's first key wait (the harness's boot snapshot) it is still there;
  - LEFT (a key that does not redraw) leaves it; the first typed key reaches the editor (the character on
    row 0) and the status row shows LINE 1/0 again;
  - NEW (a return to the editor through V2_COMMAND_LOOP.loop) does not bring the version back.

Usage: python3 tools/qual/qverboot.py [--tree DIR] [--port N]
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qharness import Machine          # noqa: E402

KEY_LEFT = 0x01                    # KEY_CURSOR_LEFT
KEY_ENTER = 0x0D
STATUS_ATTRS = bytes([0x07] * 29 + [0x10, 0x20, 0x08])


def version_text(tree):
    src = open(os.path.join(tree, "include", "v2_version.inc")).read()
    return re.search(r'V2_VERSION_TEXT:\s*DB\s*"([^"]*)"', src).group(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=os.getcwd())
    ap.add_argument("--port", type=int, default=10300)
    a = ap.parse_args()
    ver = version_text(a.tree)
    m = Machine(a.tree, a.port)
    S = m.sym
    fails = []

    def check(name, ok, detail=""):
        print("%s  %s%s" % ("PASS" if ok else "FAIL", name, ("  [" + detail + "]") if detail and not ok else ""))
        if not ok:
            fails.append(name)

    def row23():
        scr = m.read(0x4000, 6912)
        return m.screen_rows(scr)[23], scr[6144 + 23 * 32:6144 + 24 * 32], m.screen_rows(scr)

    def key(code):
        m.write(S("KBD_LASTK"), code)
        m.write(S("KBD_KEYHIT"), 1)
        m.step()
        m.set_bps([S("IO_READ_KEY")])
        m.run(40_000_000)
        assert m.pc() == S("IO_READ_KEY"), "no key wait after key %02X" % code

    m.start()                          # glyph table; the boot snapshot as every tool takes it
    try:
        # the call to STARTUP_CHIME in V2_COMMAND_LOOP's head: its return address
        chime = S("STARTUP_CHIME")
        head = m.read(S("V2_COMMAND_LOOP"), 32)
        i = head.find(bytes([0xCD, chime & 0xFF, chime >> 8]))
        assert i >= 0, "call STARTUP_CHIME not found in V2_COMMAND_LOOP's head"
        after = S("V2_COMMAND_LOOP") + i + 3
        m.cmd("reset-cpu")
        m.set_bps([chime])
        m.run(80_000_000)
        assert m.pc() == chime, "boot did not reach STARTUP_CHIME"
        text, attrs, _ = row23()
        check("chime entry: version on row 23", text == ver, repr(text))
        check("chime entry: status-bar attribute", attrs == STATUS_ATTRS, attrs.hex())
        m.set_bps([after])
        m.run(20_000_000)
        assert m.pc() == after, "STARTUP_CHIME did not return"
        text, attrs, _ = row23()
        check("chime return: version on row 23", text == ver, repr(text))
        m.set_bps([S("IO_READ_KEY")])
        m.run(40_000_000)
        assert m.pc() == S("IO_READ_KEY")
        text, attrs, rows = row23()
        check("first key wait: version on row 23", text == ver, repr(text))
        check("first key wait: status-bar attribute", attrs == STATUS_ATTRS, attrs.hex())
        check("first key wait: rows 0-22 blank but the cursor", all(r.strip() in ("", "~") for r in rows[:23]),
              repr(rows[:3]))
        key(KEY_LEFT)
        text, _, _ = row23()
        check("LEFT: version still up", text == ver, repr(text))
        key(ord("A"))
        text, attrs, rows = row23()
        check("first typed key: on row 0", rows[0].startswith("A"), repr(rows[0]))
        check("first typed key: LINE 1/0", text == "LINE 1/0", repr(text))
        check("first typed key: status-bar attribute", attrs == STATUS_ATTRS, attrs.hex())
        key(ord("B"))
        text, _, rows = row23()
        check("second key: row 0 AB, LINE 1/0", rows[0].startswith("AB") and text == "LINE 1/0",
              repr((rows[0], text)))
        check("flag spent", m.read(S("V2_VER_FLAG"), 1)[0] == 0)
        # NEW from the editor: back through V2_COMMAND_LOOP.loop, no version
        m.restore()
        for k in b"NEW":
            key(k)
        key(KEY_ENTER)
        text, _, rows = row23()
        check("NEW: LINE 1/0, no version", text == "LINE 1/0", repr(text))
    finally:
        m.stop()
    print("qverboot: %d failed" % len(fails))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())

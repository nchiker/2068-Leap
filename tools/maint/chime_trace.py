#!/usr/bin/env python3
"""MAINT (AY BEEP study): the startup chime as a list of AY register writes with the display frame
(FRAMES, relative to the first write) each happens in, from a cold start of a configuration's image.

    python3 tools/maint/chime_trace.py CFGDIR [CFGDIR...] [--port N]

Every chime variant writes through SOUND_EXROM (B = register, C = value) except the release's raw
register-0 write, which is caught at its OUT.  Prints each trace and whether they are identical.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from aytest import AYMachine          # noqa: E402


def trace(cfg, port):
    m = AYMachine(cfg, port, label="trace")
    import qharness
    m.proc = qharness.ZEsarUXProcess(qharness.ZESARUX, port=port, romfile=m.rom)
    m.proc.start()
    m.c = qharness.ZRCPClient(port=port, timeout=60)
    m.c.connect(retries=100)
    out = []
    try:
        m.cmd("enter-cpu-step")
        m.cmd("reset-cpu")
        stops = [m.sym("SOUND_EXROM"), m.sym("IO_READ_KEY")]
        raw0 = m.S.get("STARTUP_CHIME")          # the release writes R0 with OUTs at its very start
        m.set_bps(stops + ([raw0] if raw0 else []))
        f0 = None
        for _ in range(500):
            m.run(100_000_000)
            r = m.regs()
            fr = m.w16(m.sym("FRAMES"))
            if r["PC"] == m.sym("IO_READ_KEY"):
                break
            if r["PC"] == raw0:
                if m.read(raw0, 1)[0] == 0x3E:   # `ld a,0`: the raw register-0 write
                    f0 = fr if f0 is None else f0
                    out.append((fr - f0, 0, m.read(raw0 + 5, 1)[0]))
                m.step()
                continue
            f0 = fr if f0 is None else f0
            out.append((fr - f0, r["BC"] >> 8, r["BC"] & 255))
            m.step()
    finally:
        m.stop()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cfgs", nargs="+")
    ap.add_argument("--port", type=int, default=10980)
    a = ap.parse_args()
    traces = {}
    for c in a.cfgs:
        t = trace(c, a.port)
        traces[c] = t
        print("%s: %d writes, last at frame %d" % (os.path.basename(c.rstrip("/")), len(t), t[-1][0] if t else -1))
        print("   " + " ".join("%d:R%d=%d" % w for w in t))
    names = list(traces)
    for n in names[1:]:
        same = traces[n] == traces[names[0]]
        print("%s vs %s: %s" % (os.path.basename(n.rstrip("/")), os.path.basename(names[0].rstrip("/")),
                                "IDENTICAL" if same else "different"))


if __name__ == "__main__":
    main()

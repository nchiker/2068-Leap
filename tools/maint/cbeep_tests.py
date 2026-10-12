#!/usr/bin/env python3
"""MAINT (ClassicBEEP study): emulator tests of the CBEEP loudspeaker package on a ROM image.

    python3 tools/maint/cbeep_tests.py CFGDIR [--port N] [--json OUT] [--quick] [--audio OUTDIR]

CFGDIR: a configuration directory built by tools/maint/build_variants.sh (or this tree after
`make build`).  The package is assembled from this tree (rom/v2_package_cbeep.asm, default and
-DCB_RAW builds) into a temporary directory and installed through its real entry point; programs
run from V2_RUN_STORED on the real production image.  Expected pitch / cycle values come from the
bit-exact model tools/maint/cbeep_model.py.  --audio records the loudspeaker (ZEsarUX --aofile)
and measures the frequencies.  --pin tests the two-argument build (-DCB_PIN_FE; needs the ABI 2.1
copy made by tools/maint/abi21_pin_variant.sh, run from that copy).  Exit status 0 = all pass.
"""
import argparse
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from aytest import AYMachine, load_raw, segments, zc_frequency, write_wav, SAMPLE_RATE   # noqa: E402
from cbeep_model import model, FIXED, STEP                                                 # noqa: E402
from qharness import HARNESS_RET_SLOT                                                      # noqa: E402

TREE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
EMU_CPU = 3_500_000
results = []


def check(name, ok, detail=""):
    results.append({"case": name, "pass": bool(ok), "detail": detail})
    print("%-4s %-60s %s" % ("ok" if ok else "FAIL", name, detail), flush=True)


def build_package(defs, tag):
    d = tempfile.mkdtemp(prefix="cbeep-")
    os.makedirs(os.path.join(d, "build"))
    for sub in ("include", "kernel", "rom"):
        os.symlink(os.path.join(TREE, sub), os.path.join(d, sub))
    r = subprocess.run(["sjasmplus"] + defs + ["--sym=build/p.sym", "rom/v2_package_cbeep.asm"], cwd=d,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    name = {"raw": "v2_package_cbeep_raw.bin", "default": "v2_package_cbeep.bin", "pin": "v2_package_cbeep_pin.bin"}[tag]
    blob = open(os.path.join(d, "build", name), "rb").read()
    syms = {}
    for line in open(os.path.join(d, "build", "p.sym")):
        t = line.split()
        if len(t) >= 3 and t[1] == "EQU":
            syms[t[0].rstrip(":")] = int(t[2], 16)
    return blob, syms


class CB:
    pin = False

    def __init__(self, m, blob, syms):
        self.m, self.blob, self.syms = m, blob, syms

    def install(self):
        m = self.m
        m.write(m.sym("EXTENSION_MODULE_BASE"), self.blob)
        m.poke16(m.sym("V2_PACKAGE_LEN"), len(self.blob))
        m.write(0xFE00, b"\x18\xFE")
        m.write(HARNESS_RET_SLOT, struct.pack("<H", 0xFE00))
        m.setreg("SP", HARNESS_RET_SLOT)
        m.setreg("PC", m.sym("EXTENSION_MODULE_BASE"))
        m.set_bps([0xFE00])
        m.run(3_000_000)
        return m.pc() == 0xFE00 and not (m.regs()["AF"] & 1)

    def start(self, lines, install=True):
        m = self.m
        m.restore()
        if install:
            assert self.install(), "package did not install"
        if self.pin:                    # two arguments: the border comes from V2 (ABI 2.1 pin)
            lines = [re.sub(r"(?i)^(cbeep [^,]+,[^,]+),[^,]+$", r"\1", l) for l in lines]
        m.put_store(lines)
        m.write(HARNESS_RET_SLOT, struct.pack("<H", m.sym("V2_COMMAND_LOOP.loop")))
        m.setreg("SP", HARNESS_RET_SLOT)
        m.setreg("PC", m.sym("V2_RUN_STORED"))

    def at_beeper(self, lines, install=True):
        """Run to the package's SOUND_BEEP: (BC = pitch, DE = cycles) or None."""
        self.start(lines, install)
        hit = self.m.run_until([self.syms["cb.SOUND_BEEP"]], 30_000_000)
        if hit is None:
            return None
        r = self.m.regs()
        return r["BC"], r["DE"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cfg")
    ap.add_argument("--port", type=int, default=11010)
    ap.add_argument("--json")
    ap.add_argument("--quick", action="store_true", help="every 7th semitone only")
    ap.add_argument("--audio", help="record the loudspeaker into this directory")
    ap.add_argument("--pin", action="store_true", help="the two-argument ABI 2.1 build")
    a = ap.parse_args()
    CB.pin = a.pin
    blob, syms = build_package(["-DCB_PIN_FE"], "pin") if a.pin else build_package([], "default")
    raw_blob, raw_syms = build_package(["-DCB_RAW"], "raw")
    print("package: %d bytes (raw design: %d bytes)" % (len(blob), len(raw_blob)))
    rawfile = None
    if a.audio:
        os.makedirs(a.audio, exist_ok=True)
        rawfile = os.path.join(a.audio, "cbeep.raw")
        if os.path.exists(rawfile):
            os.remove(rawfile)
    m = AYMachine(a.cfg, a.port, aofile=rawfile, label="cbeep").start()
    cb = CB(m, blob, syms)
    BEEPER = syms["cb.SOUND_BEEP"]
    try:
        # ------------------------------------------------------------ install / registry
        m.restore()
        ok = cb.install()
        check("install: EXT2_REGISTER accepts CBEEP (%d numeric arguments)" % (2 if a.pin else 3), ok)

        # ------------------------------------------------------------ pitch and cycles, every semitone
        sweep = list(range(-60, 70)) if not a.quick else list(range(-60, 70, 7)) + [69]
        bad = []
        for s in sweep:
            got = cb.at_beeper(["CBEEP 1000,%d,7" % s])
            want = model(1000, s)
            if got != want:
                bad.append((s, got, want))
            m.setreg("DE", 0)                       # skip the sound itself: SOUND_BEEP returns at once
            ve, ce, _ = m.finish()
            if ve or ce:
                bad.append((s, "ve", ve, ce))
        check("pitch/cycles = model for %d semitones (1000 ms)" % len(sweep), not bad, "bad=%s" % bad[:4])

        # ------------------------------------------------------------ timing of the real loop
        for ms, s in ((100, 0), (250, 12), (60, -24), (40, 36), (500, -60)):
            got = cb.at_beeper(["CBEEP %d,%d,7" % (ms, s)])
            p, c = got
            ret = m.w16(m.regs()["SP"])
            m.tstates_reset()
            m.set_bps([ret])
            m.run(400_000_000)
            t = m.tstates()
            want_t = c * (FIXED + STEP * p)
            real_ms = t / 3528.0                  # the same T-states on a 3.528 MHz TS2068
            period_ms = (FIXED + STEP * p) / 3528.0
            # the loop costs 222 + 52 x pitch T a cycle (measured on the release; from RAM the port-$FE
            # contention phase adds up to ~0.1 %); the cycle count is truncated, as the stock ROM's
            ok = abs(t - want_t) <= 300 + 0.002 * want_t and \
                -period_ms - 0.01 * ms <= real_ms - ms <= 0.03 * ms
            check("CBEEP %d,%d: %d cycles x (222 + 52 x %d) T" % (ms, s, c, p), ok,
                  "%d T (want %d); %.1f ms on a TS2068, %.1f ms in the 3.5 MHz emulator" %
                  (t, want_t, real_ms, t / 3500.0))
            m.finish()

        # ------------------------------------------------------------ border, AY untouched
        cb.start(["BORDER 2", "SOUND 8,9", "SOUND 0,77", "CBEEP 30,0,2", 'PRINT "b"'])
        ve, ce, rows = m.finish()
        r = m.ay_regs()
        home = m.read(m.sym("PORT_FE_SHADOW"), 1)[0]
        cell = m.read(syms["cb.PORT_FE_SHADOW"], 1)[0]
        check("BORDER 2: CBEEP ...,2 keeps the border, HOME's shadow untouched, AY untouched",
              ve == 0 and rows[0] == "b" and home & 7 == 2 and cell == 2 and r[8] == 9 and r[0] == 77,
              "ve=%d out=%r HOME shadow=%02X package cell=%02X R8=%d R0=%d" % (ve, rows[0], home, cell, r[8], r[0]))
        if not a.pin:
            cb.start(["CBEEP 30,0,13"])
            ve, ce, _ = m.finish()
            check("border argument uses its low 3 bits (13 -> 5)",
                  ve == 0 and m.read(syms["cb.PORT_FE_SHADOW"], 1)[0] == 5,
                  "cell=%02X" % m.read(syms["cb.PORT_FE_SHADOW"], 1)[0])

        # ------------------------------------------------------------ arguments and errors
        top = max(ms for ms in range(0, 32768) if model(ms, 69))
        for prog, want in ((["CBEEP 1000,70,7"], 15), (["CBEEP 1000,-61,7"], 15), (["CBEEP -1,0,7"], 15),
                           (["CBEEP 32767,69,7"], 15), (["CBEEP %d,69,7" % (top + 1)], 15),
                           (["CBEEP 1000,32767,7"], 15), (["CBEEP 1000,-32768,7"], 15)):
            cb.start(prog)
            hit = m.run_until([BEEPER], 30_000_000)
            ve, ce, _ = m.finish()
            check("error: %s -> runtime error %d, no sound" % (prog[0], want), hit is None and ve == want,
                  "ve=%d ce=%d" % (ve, ce))
        got = cb.at_beeper(["CBEEP %d,69,7" % top])
        m.setreg("DE", 0)
        m.finish()
        check("CBEEP %d,69 (the longest note at +69) plays" % top, got == model(top, 69), "got=%s" % (got,))
        got = cb.at_beeper(["CBEEP 0,0,7"])
        ve, ce, _ = m.finish()
        check("CBEEP 0,0,7: zero cycles, returns at once", got is not None and got[1] == 0 and ve == 0, "got=%s" % (got,))
        got = cb.at_beeper(["CBEEP 99.9,0.9,7"])
        m.setreg("DE", 0)
        m.finish()
        check("fractions are cut off: CBEEP 99.9,0.9 = CBEEP 99,0", got == model(99, 0), "got=%s" % (got,))
        got = cb.at_beeper(["cbeep 1000,12,7"])
        m.setreg("DE", 0)
        m.finish()
        check("name is case-insensitive (cbeep)", got == model(1000, 12), "got=%s" % (got,))
        for prog in ((["CBEEP 1"], ["CBEEP 1,2,3,4"], ['CBEEP "a",1']) if a.pin else
                     (["CBEEP 1,2"], ["CBEEP 1,2,3,4"], ['CBEEP "a",1,2'])):
            cb.start(prog)
            ve, ce, _ = m.finish()
            check("compile error: %s" % prog[0], ce != 0, "ce=%d ve=%d" % (ce, ve))
        cb.start(["CBEEP 100,0,7"], install=False)
        hit = m.run_until([BEEPER], 30_000_000)
        ve, ce, _ = m.finish()
        check("without the package: CBEEP is a compile error", hit is None and ce != 0, "ce=%d ve=%d" % (ce, ve))

        # ------------------------------------------------------------ the AY BEEP alongside
        if "AY_WAIT_FRAMES" in m.S:
            cb.start(["CBEEP 20,0,7", "BEEP 0.05,0", "CBEEP 20,12,7", 'PRINT "y"'])
            hit = m.run_until([m.sym("AY_WAIT_FRAMES")], 30_000_000)
            ve, ce, rows = m.finish()
            r = m.ay_regs()
            check("CBEEP, AY BEEP, CBEEP in one program", hit is not None and ve == 0 and rows[0] == "y" and r[8] == 0,
                  "ve=%d out=%r R8=%d" % (ve, rows[0], r[8]))
        cb.start(["a=7", 'b$="xy"', "f=FREE()", "FOR i=1 TO 10", "CBEEP 5,i,7", "NEXT i", "PRINT a*3;b$;FREE()-f"])
        ve, ce, rows = m.finish()
        check("no side effects: variables, strings, FREE() unchanged by 10 CBEEPs",
              ve == 0 and rows[0] == "21xy0", "ve=%d out=%r" % (ve, rows[0]))

        # ------------------------------------------------------------ design A: the raw arguments
        rcb = CB(m, raw_blob, raw_syms)
        rcb.pin = False
        got = rcb.at_beeper(["CBEEP 100,100,7"])
        ret = m.w16(m.regs()["SP"])
        m.tstates_reset()
        m.set_bps([ret])
        m.run(100_000_000)
        t = m.tstates()
        ve, ce, _ = m.finish()
        check("raw design A: CBEEP 100,100,7 = the release's BEEP 100,100 (100 x 5422 T)",
              got == (100, 100) and abs(t - 542_200) <= 300 + 0.002 * 542_200 and ve == 0, "got=%s T=%d" % (got, t))

        # ------------------------------------------------------------ what the loudspeaker sounds
        if a.audio:
            time.sleep(1)
            mark = os.path.getsize(rawfile)
            notes = (-24, -12, 0, 9, 12, 24)
            prog = []
            for s in notes:
                prog += ["CBEEP 300,%d,7" % s, "PAUSE 15"]
            cb.start(prog)
            ve, ce, _ = m.finish(2_000_000_000)
            time.sleep(1)
    finally:
        m.stop()
    if a.audio:
        smp = load_raw(rawfile)[mark:]
        segs, _ = segments(smp, min_len=SAMPLE_RATE // 20, gap=SAMPLE_RATE // 20)
        segs = segs[-len(notes):]
        write_wav(os.path.join(a.audio, "cbeep_scale.wav"), smp[max(0, segs[0][0] - 800):segs[-1][1] + 800]
                  if segs else smp)
        out = []
        for (sa, sb), s in zip(segs, notes):
            p, c = model(300, s)
            fe = EMU_CPU / (FIXED + STEP * p)
            f = zc_frequency(smp, sa, sb)
            out.append({"semitone": s, "pitch": p, "measured_hz": round(f, 2), "expected_emu_hz": round(fe, 2),
                        "real_ts2068_hz": round(3_528_000 / (FIXED + STEP * p), 2),
                        "ideal_hz": round(261.6256 * 2 ** (s / 12), 2), "err_pct": round(100 * (f / fe - 1), 2)})
        json.dump(out, open(os.path.join(a.audio, "cbeep_audio.json"), "w"), indent=1)
        check("loudspeaker: %d notes recorded, each within 1.5 %% of 3.5 MHz / (222 + 52 x pitch)" % len(notes),
              len(out) == len(notes) and all(abs(x["err_pct"]) < 1.5 for x in out),
              "; ".join("%+d: %.1f/%.1f Hz" % (x["semitone"], x["measured_hz"], x["expected_emu_hz"]) for x in out))
    npass = sum(1 for x in results if x["pass"])
    print("\n%d of %d pass" % (npass, len(results)))
    if a.json:
        json.dump(results, open(a.json, "w"), indent=1)
    sys.exit(0 if npass == len(results) else 1)


if __name__ == "__main__":
    main()

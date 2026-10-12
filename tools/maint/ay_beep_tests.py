#!/usr/bin/env python3
"""MAINT (AY BEEP study): focused emulator tests of AY BEEP, SOUND register 0 and their interaction.

    python3 tools/maint/ay_beep_tests.py CFGDIR [--port N] [--json OUT] [--quick]

CFGDIR is a configuration directory built by tools/maint/build_variants.sh (or this tree after
`make build EXTRA_DEFS=...`).  Every case runs the real production image (HOME + EXROM) from the
booted editor state (snapshot), with the program in the line store, from V2_RUN_STORED.  AY
registers are read back from the emulated chip (tools/maint/aytest.py).  Exit status 0 = all pass.
"""
import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from aytest import AYMachine, model_period, ideal_period, EMU_FRAME_T, REAL_AY_CLOCK   # noqa: E402

results = []


def check(name, ok, detail=""):
    results.append({"case": name, "pass": bool(ok), "detail": detail})
    print("%-4s %-44s %s" % ("ok" if ok else "FAIL", name, detail), flush=True)


def trunc0(x):
    return int(x)          # toward zero, as VM_POP_COERCE_INT


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cfg")
    ap.add_argument("--port", type=int, default=10960)
    ap.add_argument("--json")
    ap.add_argument("--quick", action="store_true", help="every 7th semitone only")
    a = ap.parse_args()
    m = AYMachine(a.cfg, a.port, label="aybeep").start()
    W = m.sym("AY_WAIT_FRAMES")
    ENTRY = m.sym("AY_BEEP")
    try:
        # ---------------------------------------------------------------- boot / chime state
        m.restore()
        r = m.ay_regs()
        check("boot: editor reached, AY quiet after chime", r[8] == 0 and r[9] == 0 and r[10] == 0,
              "R7=%02X R8-10=%s R0/R1=%d R2/R3=%d R4/R5=%d" % (r[7], r[8:11], r[0] | r[1] << 8, r[2] | r[3] << 8,
                                                              r[4] | r[5] << 8))
        check("boot: mixer tones on, noise off (as the release chime)", r[7] == 0xF8, "R7=%02X" % r[7])

        # ---------------------------------------------------------------- pitch: every semitone
        sweep = list(range(-60, 70)) if not a.quick else list(range(-60, 70, 7)) + [69]
        worst = 0.0
        bad = []
        for s in sweep:
            m.start_program(["BEEP 0.05,%d" % s])
            hit = m.run_until([W])
            if hit is None:
                bad.append((s, "no note"))
                continue
            r = m.ay_regs()
            per = r[0] | (r[1] & 15) << 8
            want = model_period(s)
            if per != want or r[8] != 15 or (r[7] & 9) != 8:
                bad.append((s, per, want, r[7], r[8]))
            if s >= -39:
                cents = 1200 * math.log2(ideal_period(s) / per)
                worst = max(worst, abs(cents)) if s <= 36 else worst
            ve, ce, _ = m.finish()
            r2 = m.ay_regs()
            if ve or ce or r2[8] != 0:
                bad.append((s, "end", ve, ce, r2[8]))
        check("pitch: R0/R1 = model period, R8=15, tone A on/noise A off, R8=0 after (%d notes)" % len(sweep),
              not bad, "worst error -39..+36: %.1f cents; bad=%s" % (worst, bad[:5]))

        # ---------------------------------------------------------------- pitch: arguments
        for expr, s_eff in (("0.5", 0), ("-0.5", 0), ("11.9", 11), ("-11.9", -11), ("24/2", 12), ("INT(3.9)", 3),
                            ("-50", -50), ("-39", -39), ("69", 69)):
            m.start_program(["BEEP 0.05,%s" % expr])
            hit = m.run_until([W])
            r = m.ay_regs() if hit else [0] * 16
            per = r[0] | (r[1] & 15) << 8
            check("pitch arg %s -> semitone %d" % (expr, s_eff), hit is not None and per == model_period(s_eff),
                  "period %d (want %d)" % (per, model_period(s_eff)))
            m.finish()

        # ---------------------------------------------------------------- errors
        for prog, want_ve in ((["BEEP 1,70"], 15), (["BEEP 1,-61"], 15), (["BEEP -1,0"], 15), (["BEEP -0.01,0"], 15),
                              (["BEEP 273.1,0"], 15), (["BEEP 1000*1000,0"], 15), (["BEEP 1,32767"], 15),
                              (["BEEP 1,-32768"], 15)):
            m.start_program(prog)
            m.restore_bps = None
            hit = m.run_until([W])
            ve, ce, _ = m.finish()
            r = m.ay_regs()
            check("error: %s -> runtime error %d, no sound" % (prog[0], want_ve),
                  hit is None and ve == want_ve and r[8] == 0, "ve=%d ce=%d R8=%d" % (ve, ce, r[8]))
        for prog in (["BEEP 1"], ['BEEP "a",1'], ["BEEP 1,2,3"]):
            m.start_program(prog)
            ve, ce, _ = m.finish()
            check("error: %s -> compile error" % prog[0], ce != 0, "ce=%d ve=%d" % (ce, ve))

        # ---------------------------------------------------------------- durations
        for d in ("0", "0.001", "0.008", "0.009", "1/60", "0.1", "0.125", "0.25", "0.5", "1", "2.5", "273"):
            secs = eval(d)
            want = (int(secs * 120) + 1) >> 1 if secs > 0 else 0
            m.start_program(["BEEP %s,0" % d])
            hit = m.run_until([ENTRY])
            if hit is None:
                check("duration %s s" % d, False, "AY_BEEP not reached")
                continue
            regs = m.regs()
            frames = regs["DE"]
            if d == "273":           # only the conversion: 16380 frames would take a minute to run
                check("duration %s s -> %d frames (not played)" % (d, want), frames == want, "DE=%d" % frames)
                continue
            sp = regs["SP"]
            ret = m.w16(sp)
            f0 = m.w16(m.sym("FRAMES"))
            m.tstates_reset()
            m.set_bps([ret])
            m.run(400_000_000)
            t = m.tstates()
            f1 = m.w16(m.sym("FRAMES"))
            ok = frames == want and (f1 - f0) & 0xFFFF == frames and \
                (frames == 0 and t < 2000 or (frames - 1) * EMU_FRAME_T < t <= frames * EMU_FRAME_T + 2000)
            check("duration %s s -> %d frames" % (d, want), ok,
                  "DE=%d, FRAMES +%d, %d T = %.3f emulator frames" % (frames, (f1 - f0) & 0xFFFF, t, t / EMU_FRAME_T))
            ve, ce, _ = m.finish()

        # ---------------------------------------------------------------- interrupts stay on
        m.start_program(["BEEP 0.2,0"])
        m.run_until([W])
        regs = m.cmd("get-registers")
        check("interrupts enabled while the note sounds", "IFF12" in regs, regs[regs.find("IM"):][:10])
        m.finish()

        # ---------------------------------------------------------------- program-level behaviour
        m.start_program(["a=7", 'b$="xy"', "f=FREE()", "FOR i=1 TO 25", "BEEP 0.02,i-12", "NEXT i",
                         "PRINT a*3;b$;FREE()-f"])
        ve, ce, rows = m.finish()
        check("no side effects: variables, strings, FREE() unchanged by 25 BEEPs in a loop",
              ve == 0 and rows[0] == "21xy0", "ve=%d out=%r" % (ve, rows[0]))
        m.start_program(["BEEP SQR(4)/40, INT(3.9*4)-12", "PRINT 1+2*3;\" \";2*512"])
        ve, ce, rows = m.finish()
        check("calculator: expressions around BEEP", ve == 0 and rows[0].replace(" ", "") == "71024",
              "ve=%d out=%r" % (ve, rows[0]))
        calc_sp = m.read(m.sym("CALC_SP"), 1)[0]
        check("calculator stack empty after BEEP", calc_sp == 0, "CALC_SP=%d" % calc_sp)
        m.start_program(["BEEP 0.1,0", "PAUSE 5", "BEEP 0.1,12", 'PRINT "p"'])
        ve, ce, rows = m.finish()
        check("PAUSE between BEEPs", ve == 0 and rows[0] == "p", "ve=%d out=%r" % (ve, rows[0]))

        # ---------------------------------------------------------------- SOUND register 0 .. 17
        for reg, val, want_ve in ((0, 123, 0), (1, 5, 0), (8, 9, 0), (15, 7, 0), (16, 9, 0), (17, 1, 8), (20, 1, 8)):
            m.start_program(["SOUND %d,%d" % (reg, val)])
            ve, ce, _ = m.finish()
            r = m.ay_regs()
            ok = ve == want_ve and (want_ve or reg > 15 or r[reg] == (val & (15 if reg in (1, 3, 5, 13) else 31
                                                                            if reg in (6, 8, 9, 10) else 255)))
            check("SOUND %d,%d -> %s" % (reg, val, "error %d" % want_ve if want_ve else "R%d written" % reg), ok,
                  "ve=%d R%d=%s" % (ve, reg, r[reg] if reg < 16 else "-"))

        # ---------------------------------------------------------------- SOUND <-> BEEP
        m.start_program(["SOUND 2,100", "SOUND 3,1", "SOUND 9,12", "SOUND 4,50", "SOUND 10,7", "SOUND 7,56",
                         "BEEP 0.05,0"])
        m.finish()
        r = m.ay_regs()
        check("BEEP keeps channels B/C (periods, levels) and R7 = 56",
              r[2] == 100 and r[3] == 1 and r[9] == 12 and r[4] == 50 and r[10] == 7 and r[7] == 56 and r[8] == 0
              and (r[0] | r[1] << 8) == model_period(0), "R0-10=%s" % r[:11])
        for r7, want in ((255, 254), (0, 8), (0x41, 0x48), (0xB6, 0xBE)):
            m.start_program(["SOUND 7,%d" % r7, "BEEP 0.05,0"])
            m.finish()
            r = m.ay_regs()
            check("mixer R7 %3d -> %3d after BEEP (tone A on, noise A off, rest kept)" % (r7, want), r[7] == want,
                  "R7=%d" % r[7])
        m.start_program(["SOUND 0,200", "SOUND 1,0", "SOUND 8,10", "BEEP 0.05,12"])
        m.finish()
        r = m.ay_regs()
        check("SOUND on channel A, then BEEP: A takes BEEP's period, silent after", r[8] == 0 and
              (r[0] | r[1] << 8) == model_period(12), "R0/R1=%d R8=%d" % (r[0] | r[1] << 8, r[8]))
        m.start_program(["BEEP 0.05,12", "SOUND 0,200", "SOUND 1,0", "SOUND 8,10"])
        m.finish()
        r = m.ay_regs()
        check("BEEP, then SOUND on channel A (register 0 included) works", r[0] == 200 and r[1] == 0 and r[8] == 10,
              "R0=%d R1=%d R8=%d" % (r[0], r[1], r[8]))
        m.start_program(["SOUND 8,16", "SOUND 13,14", "BEEP 0.05,0"])
        m.finish()
        r = m.ay_regs()
        check("channel A in envelope mode before BEEP: fixed level 0 after (documented)", r[8] == 0, "R8=%d" % r[8])

        # ---------------------------------------------------------------- BREAK, PAUSE (shared wait)
        shared = "OP_PAUSE.wait_loop" not in m.S       # V2_MAINT_SHARED_WAIT: PAUSE uses BEEP's wait
        for prog, what in ((["BEEP 5,0", 'PRINT "n"'], "BEEP 5,0"), (["PAUSE 300", 'PRINT "n"'], "PAUSE 300")):
            m.start_program(prog)
            m.run_until([W] if what.startswith("BEEP") else [], 3_000_000 if what.startswith("BEEP") else 200_000)
            f0 = m.w16(m.sym("FRAMES"))
            m.cmd("send-keys-event 135 1")              # CAPS SHIFT + SPACE in the emulated matrix
            m.cmd("send-keys-event 128 1")
            m.set_bps([])                               # (a breakpoint in the wait loop would stop
            m.run(400_000)                              # every frame) some frames: debounce, the ISR
            m.cmd("send-keys-event 128 0")
            m.cmd("send-keys-event 135 0")
            ve, ce, rows = m.finish(60_000_000)
            df = (m.w16(m.sym("FRAMES")) - f0) & 0xFFFF
            r = m.ay_regs()
            brk = what.startswith("PAUSE") or shared
            check("BREAK during %s %s" % (what, "stops it (error 66), channel A silent" if brk else
                                          "(release behaviour: the note plays out, then BREAK)"),
                  ve == 66 and r[8] == 0 and rows[0] != "n" and (df < 60 if brk else df >= 250),
                  "ve=%d R8=%d frames=%d out=%r" % (ve, r[8], df, rows[0]))
        for start in (65530, 1000):
            m.start_program(["PAUSE 20", 'PRINT "p"'])
            m.run_until([m.sym("OP_PAUSE")])
            m.poke16(m.sym("FRAMES"), start)
            f0 = start
            ve, ce, rows = m.finish(60_000_000)
            df = (m.w16(m.sym("FRAMES")) - f0) & 0xFFFF
            ok = ve == 0 and rows[0] == "p" and 19 <= df <= 21
            if not shared and start == 65530:           # the release's target compare: ends at once
                check("PAUSE 20 across the FRAMES wrap (release: ends at once, defect)", df < 2, "frames=%d" % df)
            else:
                check("PAUSE 20 from FRAMES=%d waits 20 frames" % start, ok, "ve=%d frames=%d out=%r" %
                      (ve, df, rows[0]))
    finally:
        m.stop()
    npass = sum(1 for x in results if x["pass"])
    print("\n%d of %d pass" % (npass, len(results)))
    if a.json:
        json.dump(results, open(a.json, "w"), indent=1)
    sys.exit(0 if npass == len(results) else 1)


if __name__ == "__main__":
    main()

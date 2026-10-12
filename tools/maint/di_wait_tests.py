#!/usr/bin/env python3
"""MAINT (ClassicBEEP study): PAUSE / BEEP / CBEEP with the frame interrupt unavailable.

    python3 tools/maint/di_wait_tests.py CFGDIR [--port N] [--json OUT] [--release]

A program can leave the CPU's interrupts off (a USR routine that ends `DI : RET`; the manual says to
leave them on) or switch the frame interrupt off at the source (port $FF bit 6, `OUT 255,192`).  The
shared frame wait counts frames with HALT, so it can only end on an interrupt.  This suite shows
what each statement then does.

Safe in the emulator: every run is bounded by an instruction budget (the ZRCP `run N` of the
harness), so a statement that never ends is reported as HANG with its PC, and the next case starts
from the booted snapshot.  Nothing here can stop the emulator or the test runner.  On a real
TS2068 a HANG case needs the reset button.

--release: CFGDIR is the release image (raw BEEP counts, no package checks).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cbeep_tests import CB, build_package       # noqa: E402
from aytest import AYMachine                      # noqa: E402

BUDGET = 40_000_000       # instructions; a HALT loop executes ~17 500 a frame, so > 2 000 frames
results = []


def check(name, ok, detail=""):
    results.append({"case": name, "pass": bool(ok), "detail": detail})
    print("%-4s %-66s %s" % ("ok" if ok else "FAIL", name, detail), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cfg")
    ap.add_argument("--port", type=int, default=11050)
    ap.add_argument("--json")
    ap.add_argument("--release", action="store_true")
    a = ap.parse_args()
    m = AYMachine(a.cfg, a.port, label="di").start()
    blob, syms = (None, None) if a.release else build_package([], "default")
    cb = CB(m, blob, syms)
    shared = "OP_PAUSE.wait_loop" not in m.S
    ay = "AY_WAIT_FRAMES" in m.S
    DI = ["POKE 23296,243", "POKE 23297,201", "x = USR(23296)"]          # DI : RET at $5B00
    INH = ["OUT 255,192"]          # SCLD: frame interrupt off (bit 6), EXROM kept selected (bit 7): 64 alone
                                # would also deselect the EXROM, which breaks the next EXROM call by itself
    beep = "BEEP 0.1,0" if ay else "BEEP 100,100"
    ops = [("PAUSE 10", "PAUSE 10"), (beep, "BEEP"), ("PAUSE 0", "PAUSE 0 (key)")]
    if not a.release:
        ops.append(("CBEEP 10,0,7", "CBEEP"))
    names = sorted((v, k) for k, v in m.S.items())

    def label(pc):
        best = max((v, k) for v, k in names if v <= pc and ((v < 0x4000) == (pc < 0x4000)))
        return "%s+%d" % (best[1], pc - best[0])

    stops = [m.sym("V2_SHOW_MESSAGE"), m.sym("V2_COMMAND_LOOP.loop")]

    def ran_to_end():
        return any(r.strip() == "end" for r in m.screen_rows())

    try:
        for how, pre in (("interrupts off (USR DI)", DI), ("frame interrupt inhibited (OUT 255,192)", INH)):
            for stmt, label_ in ops:
                prog = pre + [stmt, 'PRINT "end"']
                cb.start(prog, install=label_ == "CBEEP")
                m.set_bps(stops)
                f0 = m.w16(m.sym("FRAMES"))
                m.run(BUDGET)
                pc = m.pc()
                done = ran_to_end()
                df = (m.w16(m.sym("FRAMES")) - f0) & 0xFFFF
                regs = m.cmd("get-registers")
                iff = "IFF12" in regs or "IFF1 " in regs
                status = "completes" if done else "never ends: PC %04X %s" % (pc, label(pc))
                # expected (documented in V2_CLASSICBEEP_STUDY.md s10): a statement that counts frames
                # waits forever; one that pages the EXROM first (the AY BEEP: calculator + its slot) turns
                # interrupts back on, BANK_PAGE_EXROM_IN/OUT end with EI and paging in rewrites port $FF
                # from its copy (bit 6 clear); CBEEP and the release's raw BEEP are timed busy loops.
                # the AY BEEP: interrupts left off by machine code are switched back on by the EXROM
                # paging on its way (BANK_PAGE_EXROM_IN/OUT end with EI), but a frame interrupt
                # inhibited at port $FF stays inhibited (the VM already has the EXROM paged in, so
                # port $FF is not rewritten) and its wait never ends, with the note sounding
                want_done = label_ == "CBEEP" or (label_ == "BEEP" and (not ay or pre is DI))
                check("%s: %s" % (how, label_), done == want_done,
                      "%s; FRAMES +%d; interrupts %s at the end of the budget" % (status, df, "on" if iff else "off"))
                if not done and label_ == "BEEP":
                    r = m.ay_regs()
                    check("  ... channel A keeps sounding (R8 = 15) until the machine is reset", r[8] == 15,
                          "R8=%d" % r[8])
                if not done:
                    m.cmd("send-keys-event 135 1")
                    m.cmd("send-keys-event 128 1")
                    m.run(2_000_000)
                    m.cmd("send-keys-event 128 0")
                    m.cmd("send-keys-event 135 0")
                    m.run(2_000_000)
                    ve = m.read(m.sym("VM_ERROR_CODE"), 1)[0]
                    check("  ... and BREAK does not end it (the keyboard is scanned by the interrupt)",
                          not ran_to_end() and ve != 66, "PC %04X %s, ve=%d" % (m.pc(), label(m.pc()), ve))
        # control: the same programs with interrupts switched back on (EI : RET) complete
        cb.start(["POKE 23296,243", "POKE 23297,201", "POKE 23298,251", "POKE 23299,201", "x = USR(23296)",
                  "x = USR(23298)", "PAUSE 10", beep, 'PRINT "end"'], install=False)
        ve, ce, rows = m.finish(BUDGET)
        check("control: DI then EI again (USR), PAUSE and BEEP complete", rows[0] == "end" and ve == 0,
              "ve=%d out=%r" % (ve, rows[0]))
        print("(shared wait: %s; AY BEEP: %s)" % (shared, ay))
    finally:
        m.stop()
    npass = sum(1 for x in results if x["pass"])
    print("\n%d of %d pass" % (npass, len(results)))
    if a.json:
        json.dump(results, open(a.json, "w"), indent=1)
    sys.exit(0 if npass == len(results) else 1)


if __name__ == "__main__":
    main()

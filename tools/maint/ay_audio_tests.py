#!/usr/bin/env python3
"""MAINT (AY BEEP study): what the emulated AY actually sounds -- BEEP frequencies/durations and the
startup chime -- from ZEsarUX's raw audio output (--aofile; 8-bit, 15600 Hz, emulated time).

    python3 tools/maint/ay_audio_tests.py CFGDIR OUTDIR [--port N] [--chime-only]

Writes OUTDIR/<label>_chime.wav (the boot), OUTDIR/<label>_scale.wav (the BEEP sequence) and
OUTDIR/<label>_audio.json.  Frequencies are compared with the emulator's AY clock (1.7734 MHz);
the same periods on a real TS2068 (1.764 MHz) are 0.53 % lower.  Notes above about 7.8 kHz
(semitone > +50) are beyond the 15.6 kHz capture's Nyquist limit and are checked by register only
(tools/maint/ay_beep_tests.py).
"""
import argparse
import json
import math
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from aytest import (AYMachine, load_raw, segments, zc_frequency, goertzel, write_wav, model_period,   # noqa: E402
                    EMU_AY_CLOCK, REAL_AY_CLOCK, SAMPLE_RATE)

NOTES = (-39, -24, -12, 0, 4, 7, 9, 12, 24, 36, 48)
SECS = 0.3            # 18 frames at 60/s; the emulator's frames are 1/50 s, so 0.36 s of audio


def chime_profile(samples, a, b):
    """Power of C4/E4/G4 (emulator clock) in 1/50 s windows: which notes sound when."""
    fs = [EMU_AY_CLOCK / 16 / p for p in (421, 334, 281)]
    win = SAMPLE_RATE // 50
    rows = []
    for w in range(a, b, win):
        p = [goertzel(samples, w, min(b, w + win), f) for f in fs]
        rows.append(p)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cfg")
    ap.add_argument("out")
    ap.add_argument("--port", type=int, default=10970)
    ap.add_argument("--label", default=None)
    ap.add_argument("--chime-only", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    label = a.label or os.path.basename(os.path.abspath(a.cfg))
    raw = os.path.join(a.out, label + ".raw")
    if os.path.exists(raw):
        os.remove(raw)
    res = {"label": label}
    m = AYMachine(a.cfg, a.port, aofile=raw, label="audio").start()   # boots: the chime is recorded
    try:
        time.sleep(1)
        boot_len = os.path.getsize(raw)
        if not a.chime_only:
            prog = []
            for s in NOTES:
                prog += ["BEEP %s,%d" % (SECS, s), "PAUSE 15"]
            m.start_program(prog)
            ve, ce, _ = m.finish(2_000_000_000)
            res["scale_ve"] = ve
            time.sleep(1)
    finally:
        m.stop()
    smp = load_raw(raw)
    segs, idle = segments(smp[:boot_len])
    if segs:
        a0, b0 = segs[0][0], segs[-1][1]
        write_wav(os.path.join(a.out, label + "_chime.wav"), smp[max(0, a0 - 800):b0 + 800])
        prof = chime_profile(smp, a0, b0)
        mx = max(max(r) for r in prof) or 1
        res["chime"] = {"start": a0, "length_s": round((b0 - a0) / SAMPLE_RATE, 3), "segments": len(segs),
                        "profile_C4_E4_G4": [[round(x / mx, 2) for x in r] for r in prof]}
    else:
        res["chime"] = None
    if not a.chime_only:
        scale = smp[boot_len:]
        segs, idle = segments(scale, min_len=SAMPLE_RATE // 10, gap=SAMPLE_RATE // 10)
        segs = segs[-len(NOTES):]           # the boot chime's tail may lead the capture
        write_wav(os.path.join(a.out, label + "_scale.wav"), scale[max(0, segs[0][0] - 800):segs[-1][1] + 800]
                  if segs else scale)
        notes = []
        for (sa, sb), s in zip(segs, NOTES):
            f = zc_frequency(scale, sa, sb)
            per = model_period(s)
            fe = EMU_AY_CLOCK / 16 / per
            notes.append({"semitone": s, "period": per, "measured_hz": round(f, 2), "expected_emu_hz": round(fe, 2),
                          "err_pct": round(100 * (f / fe - 1), 3) if f else None,
                          "real_ts2068_hz": round(REAL_AY_CLOCK / 16 / per, 2),
                          "ideal_hz": round(440 * 2 ** ((s - 9) / 12), 2),
                          "duration_s": round((sb - sa) / SAMPLE_RATE, 4)})
        res["segments"] = len(segs)
        res["notes"] = notes
        frames = (int(SECS * 120) + 1) >> 1
        res["expected_duration_emu_s"] = [round((frames - 1) / 50, 3), round(frames / 50, 3)]
        # durations are only indicative here (the capture's idle insertions); ay_beep_tests.py times them
        # 15.6 kHz capture: a note needs >= 7 samples per cycle to be measured (<= ~2.2 kHz); the
        # emulator's audio idle insertions make single intervals jitter, so 1.5 % (register values are
        # checked exactly by ay_beep_tests.py)
        for n in notes:
            n["measurable"] = n["expected_emu_hz"] <= SAMPLE_RATE / 7
        ok = len(segs) == len(NOTES) and all(
            (n["err_pct"] is not None and abs(n["err_pct"]) < 1.5) for n in notes if n["measurable"])
        res["pass"] = ok
    json.dump(res, open(os.path.join(a.out, label + "_audio.json"), "w"), indent=1)
    print(json.dumps({k: v for k, v in res.items() if k != "chime"}, indent=1))
    if res.get("chime"):
        c = res["chime"]
        print("chime: %.3f s, %d segment(s); C4/E4/G4 power per 1/50 s:" % (c["length_s"], c["segments"]))
        for i, r in enumerate(c["profile_C4_E4_G4"]):
            print("  %3d  %s" % (i, "  ".join("%-5s" % ("#" * int(round(x * 5))) for x in r)))
    sys.exit(0 if res.get("pass", True) else 1)


if __name__ == "__main__":
    main()

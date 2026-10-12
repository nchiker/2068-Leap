"""MAINT (ClassicBEEP study): bit-exact model of the CBEEP package's integer maths
(rom/v2_package_cbeep.asm) and its accuracy against Sinclair BEEP on a real TS2068.

    python3 tools/maint/cbeep_model.py        # prints the tables and the accuracy summary
"""
import math

CPU = 3_528_000           # real TS2068 CPU clock
FIXED, STEP = 222, 52     # SOUND_BEEP: one cycle = 222 + 52 * pitch T-states (measured)
C4 = 261.6256


def f_ideal(s):
    return C4 * 2 ** (s / 12)


def f_low(n):             # the lowest octave, semitones -60..-49
    return f_ideal(n - 60)


# Q[n] = 4 * CPU / (STEP * f): the pitch count, in quarter steps, before the 222 T overhead
TQ = [round(4 * CPU / (STEP * f_low(n))) for n in range(12)]
# F[n] = f * 65536 * 64 / 1000: cycles = ms * F >> (22 - octave)
TF = [round(f_low(n) * 65536 * 64 / 1000) for n in range(12)]
ROUND = 4 * FIXED / STEP - 2          # 17.08 quarter steps of overhead, less half a step (rounding)
SUB = round(ROUND)                    # 15


def model(ms, s):
    """-> (pitch, cycles) as the package computes them, or None (error 15)."""
    if not (0 <= ms <= 32767) or not (-60 <= s <= 69):
        return None
    n, octave = (s + 60) % 12, (s + 60) // 12
    pitch = ((TQ[n] >> octave) - SUB) >> 2
    cycles = (ms * TF[n]) >> (22 - octave)
    if cycles > 65535:
        return None
    return pitch, cycles


def played_hz(pitch):
    return CPU / (FIXED + STEP * pitch)


if __name__ == "__main__":
    print("TQ", TQ)
    print("TF", TF)
    worst = {}
    for s in range(-60, 70):
        p, c = model(1000, s) or (None, None)
        if p is None:
            print("s", s, "error at 1000 ms")
            continue
        assert p >= 1, s
        cents = 1200 * math.log2(played_hz(p) / f_ideal(s))
        band = next(b for b in ((-60, -1), (0, 23), (24, 35), (36, 47), (48, 59), (60, 69)) if b[0] <= s <= b[1])
        worst[band] = max(worst.get(band, 0), abs(cents))
    for b, w in sorted(worst.items()):
        print("semitones %3d..%3d: worst %.1f cents" % (b[0], b[1], w))
    print("longest note at +69:", max(ms for ms in range(0, 32768, 10) if model(ms, 69)), "ms")
    print("1000 ms at 0:", model(1000, 0), "stock: HL=1642 DE=261")

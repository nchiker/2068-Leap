"""MAINT (AY BEEP study): shared helpers for the AY BEEP / SOUND / chime emulator tests.

Builds on tools/qual/qharness.py (persistent ZRCP session, snapshot per case, real production image
of a configuration directory made by tools/maint/build_variants.sh).  Adds:
  * ay_regs(): reads the 16 AY registers by running a small probe routine in the emulator (port
    $F5 select / $F6 read, as STICK does), then re-selects R8 (BEEP's player relies on R8 staying
    selected while it waits) and puts PC/SP back;
  * audio capture: ZEsarUX's --aofile raw output (8-bit signed mono, 15600 Hz, emulated time),
    segmented into tones; frequency by zero crossings, single-frequency power by Goertzel.

Emulator facts measured for this study (ZEsarUX 13.0, machine TS2068): CPU 3.5 MHz, a frame is
69 888 T-states (50 Hz), the AY clock is 1.7734 MHz.  A real TS2068 runs 3.528 MHz, 60 Hz frames
and an AY clock of 1.764 MHz (CPU / 2) -- the ROM is written for the real machine.
"""
import math
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "qual"))
from qharness import Machine, HARNESS_RET_SLOT                     # noqa: E402
from ts2068_debug.process import ZEsarUXProcess                     # noqa: E402

EMU_AY_CLOCK = 1_773_400
REAL_AY_CLOCK = 1_764_000
EMU_FRAME_T = 69_888
SAMPLE_RATE = 15_600
PROBE_ADDR = 0xFD00
PROBE_OUT = 0xFD80


def ideal_period(semitones, clock=REAL_AY_CLOCK):
    f = 440.0 * 2 ** ((semitones - 9) / 12.0)
    return clock / 16.0 / f


def model_period(semitones):
    """Bit-exact model of AY_BEEP_PERIOD (rom/v2_ay_beep.asm) for a whole number of semitones."""
    n = semitones + 39
    if n < 0:
        n = 0
    table = [round(16 * 110250 / (440 * 2 ** ((-39 + k - 9) / 12))) for k in range(12)]
    v = table[n % 12]
    shift = n // 12 + 4
    half = (v >> (shift - 1)) & 1
    return (v >> shift) + half


def _assemble(src_lines, org):
    d = tempfile.mkdtemp(prefix="aytest-")
    src = ["    DEVICE ZXSPECTRUM48", "    ORG $%04X" % org] + src_lines + [
        '    SAVEBIN "%s/p.bin", $%04X, $-$%04X' % (d, org, org)]
    open(d + "/p.asm", "w").write("\n".join(src) + "\n")
    r = subprocess.run(["sjasmplus", "--sym=" + d + "/p.sym", d + "/p.asm"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    syms = {}
    for l in open(d + "/p.sym"):
        t = l.split()
        if len(t) >= 3 and t[1] == "EQU":
            syms[t[0].rstrip(":")] = int(t[2], 16)
    return open(d + "/p.bin", "rb").read(), syms


PROBE_BIN, PROBE_SYMS = _assemble([
    "    push af", "    push bc", "    push hl",
    "    ld hl,$%04X" % PROBE_OUT, "    ld c,$F6", "    xor a",
    "lp: out ($F5),a", "    push af", "    in a,(c)", "    ld (hl),a", "    inc hl", "    pop af",
    "    inc a", "    cp 16", "    jr nz,lp",
    "    ld a,8", "    out ($F5),a",
    "    pop hl", "    pop bc", "    pop af",
    "done: jr done"], PROBE_ADDR)


class AudioProcess(ZEsarUXProcess):
    def __init__(self, *a, aofile=None, **k):
        super().__init__(*a, **k)
        self.aofile = aofile

    def start(self):
        orig = subprocess.Popen

        def patched(args, **kw):
            return orig(list(args) + ["--aofile", self.aofile], **kw)
        subprocess.Popen = patched
        try:
            super().start()
        finally:
            subprocess.Popen = orig


class AYMachine(Machine):
    def __init__(self, cfgdir, port, aofile=None, **kw):
        super().__init__(cfgdir, port, **kw)
        self.aofile = aofile

    def start(self):
        if self.aofile:
            import qharness
            orig = qharness.ZEsarUXProcess
            qharness.ZEsarUXProcess = lambda *a, **k: AudioProcess(*a, aofile=self.aofile, **k)
            try:
                return super().start()
            finally:
                qharness.ZEsarUXProcess = orig
        return super().start()

    # ------------------------------------------------------------------ AY registers
    def ay_regs(self):
        r = self.regs()
        pc, sp = r["PC"], r["SP"]
        saved = self.read(PROBE_ADDR, len(PROBE_BIN))
        self.write(PROBE_ADDR, PROBE_BIN)
        self.setreg("PC", PROBE_ADDR)
        old_bps = getattr(self, "_bps", [])
        self.set_bps([PROBE_SYMS["done"]])
        self.run(200_000)
        assert self.pc() == PROBE_SYMS["done"], "AY probe did not finish"
        vals = self.read(PROBE_OUT, 16)
        self.write(PROBE_ADDR, saved)
        self.setreg("PC", pc)
        assert self.regs()["SP"] == sp
        self.set_bps(old_bps)
        return list(vals)

    def set_bps(self, addrs):
        self._bps = list(addrs)
        super().set_bps(addrs)

    def ay_write(self, reg, val):
        """Write an AY register directly (test setup), through the probe area."""
        r = self.regs()
        pc = r["PC"]
        code, syms = _assemble(["    push af", "    ld a,%d" % reg, "    out ($F5),a", "    ld a,%d" % val,
                                "    out ($F6),a", "    pop af", "done: jr done"], PROBE_ADDR)
        saved = self.read(PROBE_ADDR, len(code))
        self.write(PROBE_ADDR, code)
        self.setreg("PC", PROBE_ADDR)
        old = getattr(self, "_bps", [])
        self.set_bps([syms["done"]])
        self.run(100_000)
        self.write(PROBE_ADDR, saved)
        self.setreg("PC", pc)
        self.set_bps(old)

    # ------------------------------------------------------------------ program runs
    def start_program(self, lines):
        """Restore the booted machine, store the program and point the CPU at V2_RUN_STORED."""
        self.restore()
        self.put_store(lines)
        self.write(HARNESS_RET_SLOT, struct.pack("<H", self.sym("V2_COMMAND_LOOP.loop")))
        self.setreg("SP", HARNESS_RET_SLOT)
        self.setreg("PC", self.sym("V2_RUN_STORED"))

    def run_until(self, addrs, maxi=200_000_000):
        """Run until one of `addrs` or the program's end (IO_READ_KEY / message / return)."""
        ends = [self.sym("IO_READ_KEY"), self.sym("V2_SHOW_MESSAGE"), self.sym("V2_COMMAND_LOOP.loop")]
        self.set_bps(list(addrs) + ends)
        self.run(maxi)
        p = self.pc()
        return p if p in addrs else None

    def finish(self, maxi=400_000_000):
        """Run to the end of the program; return (ve, ce, screen rows)."""
        self.run_until([], maxi)
        return (self.read(self.sym("VM_ERROR_CODE"), 1)[0], self.read(self.sym("COMPILE_ERROR_CODE"), 1)[0],
                self.screen_rows())

    def tstates_reset(self):
        self.cmd("reset-tstates-partial")

    def tstates(self):
        return int(self.cmd("get-tstates-partial").strip())


# ---------------------------------------------------------------------- audio analysis
def load_raw(path):
    d = open(path, "rb").read()
    return [b - 256 if b > 127 else b for b in d]


def segments(samples, min_len=40, gap=60):  # gap: idle samples that end a tone
    """Tone segments: runs where the signal moves (|s - idle| > 2), split at `gap` samples of stillness."""
    from collections import Counter
    idle = Counter(samples).most_common(1)[0][0] if samples else 0     # silence dominates the capture
    active = [abs(s - idle) > 2 for s in samples]
    segs = []
    i, n = 0, len(samples)
    while i < n:
        if not active[i]:
            i += 1
            continue
        j = i
        last = i
        while j < n and j - last <= gap:
            if active[j]:
                last = j
            j += 1
        if last - i >= min_len:
            segs.append((i, last + 1))
        i = last + 1
    return segs, idle


def zc_frequency(samples, a, b):
    """Mean length of the rising-edge intervals that are within 20 % of their median: robust to the
    idle (mid-level) samples the emulator's null audio driver inserts when its buffer runs dry."""
    seg = samples[a:b]
    hi, lo = max(seg), min(seg)
    mid = (hi + lo) / 2.0
    ups = [k for k in range(1, len(seg)) if seg[k - 1] < mid <= seg[k]]
    iv = [y - x for x, y in zip(ups, ups[1:])]
    if len(iv) < 2:
        return 0.0
    med = sorted(iv)[len(iv) // 2]
    good = [v for v in iv if abs(v - med) <= 0.2 * med]
    return SAMPLE_RATE * len(good) / sum(good)


def goertzel(samples, a, b, f):
    n = b - a
    k = 2 * math.cos(2 * math.pi * f / SAMPLE_RATE)
    s1 = s2 = 0.0
    mean = sum(samples[a:b]) / max(1, n)
    for x in samples[a:b]:
        s0 = (x - mean) + k * s1 - s2
        s2, s1 = s1, s0
    return (s1 * s1 + s2 * s2 - k * s1 * s2) / max(1, n * n)


def write_wav(path, samples):
    data = bytes((s + 128) & 0xFF for s in samples)
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack(
        "<IHHIIHH", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE, 1, 8) + b"data" + struct.pack("<I", len(data))
    open(path, "wb").write(hdr + data)

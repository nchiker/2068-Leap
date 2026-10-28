#!/usr/bin/env python3
"""Interrupts lost in float code, measured on Fuse (docs/V2_LEAPC_BACKPORT_PLAN.md item 0.8).

V2's FRAMES (counted by the IM 1 handler) is compared with Fuse's own frame count over a program run.
ZEsarUX cannot show this: it does not model the TS2068's 32 T INT pulse, so an interrupt arriving while
interrupts are disabled is never lost there. Fuse does (libspectrum timings), as 2068-Leap-C found
(its delta D14: BANK_PAGE_EXROM_IN/OUT held interrupts off for ~63-120 T on every float op).

Each program is poked into the line store of a booted machine and started at V2_RUN_STORED with
interrupts on (as tools/v2_headless.py does under ZEsarUX); breakpoints print Fuse's frame counter and
FRAMES when it returns. A loss of about 1 frame is the sampling offset at the start.

Measured 2026-10-25 (v2.0.2-emu.1, 20,000-iteration loops):
  with the di:     float x=x+0.5  47 of 11,232 frames lost (0.42%);  int s=s+1  1 of 1,319
  without the di:  float          1 of 11,228;                       int        1 of 1,319

Needs Fuse 1.9.1 built from source and not stripped (, default /usr/local/bin/fuse), gcc and
the SDL2 development files (the LD_PRELOAD shim tools/fuse/fuseshim.c, from 2068-Leap-C). Runs headless.

Usage: python3 tools/qual/fuse_frames_probe.py [BUILD_DIR ...]   (default: build)
Exit status 1 when the float loop loses more than 2 frames.
"""
import os, re, socket, struct, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
SHIM_SRC = os.path.join(HERE, "..", "fuse", "fuseshim.c")
FUSE = os.environ.get("V2_FUSE", "/usr/local/bin/fuse")
SHIM_SYMS = ("memory_map_read", "z80", "frames_since_reset", "tstates", "keyboard_press", "keyboard_release",
             "debugger_command_evaluate", "writebyte_internal", "tape_open", "tape_write", "tape_record_start",
             "tape_record_stop", "tape_is_playing", "tape_toggle_play")
MEMORY_PAGE_SIZE, PROCESSOR_SIZE = 32, 52      # the shim's structs (x86-64), checked against Fuse below
PROGS = {"float x=x+0.5": ["x = 0", "FOR i = 1 TO 20000", "x = x + 0.5", "NEXT i"],
         "int   s=s+1  ": ["s = 0", "FOR i = 1 TO 20000", "s = s + 1", "NEXT i"]}


def build_shim(wd):
    out = os.path.join(wd, "fuseshim.so")
    if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(SHIM_SRC):
        cflags = subprocess.run(["sdl2-config", "--cflags"], capture_output=True, text=True).stdout.split()
        subprocess.run(["gcc", "-shared", "-fPIC", "-O2", "-Wall"] + cflags + ["-o", out, SHIM_SRC, "-ldl"], check=True)
    return out


def fuse_syms():
    out, sizes = {}, {}
    for l in subprocess.run(["nm", "-S", FUSE], capture_output=True, text=True, check=True).stdout.split("\n"):
        p = l.split()
        if len(p) == 4:
            out[p[3]], sizes[p[3]] = p[0], int(p[1], 16)
        elif len(p) == 3:
            out.setdefault(p[2], p[0])
    missing = [n for n in SHIM_SYMS if n not in out]
    if missing:
        raise RuntimeError("Fuse binary lacks %s (not 1.9.1, or stripped)" % missing)
    if sizes.get("memory_map_read") != 32 * MEMORY_PAGE_SIZE or sizes.get("z80") != PROCESSOR_SIZE:
        raise RuntimeError("Fuse's memory_page or processor is not the shim's")
    return ",".join("%s=%s" % (n, out[n]) for n in SHIM_SYMS)

def syms(b):
    out = {}
    for f in ("exrom.sym", "test_basic.sym"):
        for l in open(os.path.join(b, f)):
            p = l.split()
            if len(p) >= 3 and p[1] == "EQU":
                out.setdefault(p[0].rstrip(":"), int(p[2], 16))
    return out

class F:
    def __init__(self, b, tag):
        self.S = syms(b); S = self.S
        wd = os.path.join(b, "fuse_probe_" + tag); os.makedirs(wd, exist_ok=True)
        self.out_path = os.path.join(wd, "fuse.out")
        sock = "leapv2-fuse-%d-%s" % (os.getpid(), tag)
        dbg = ("tbreak 0x%04x\ncommands 1\nprint 0xb0070\ncontinue\nend\n"
               "break 0x%04x if z80:sp == 0xff00\ncommands 2\nprint 0xb0071\nprint spectrum:frames\nprint [0x%04x]\nprint [0x%04x]\nprint [0x%04x]\ncontinue\nend"
               % (S["IO_READ_KEY"], S["IO_READ_KEY"], S["FRAMES"], S["FRAMES"] + 1, S["FRAMES"] + 2))
        env = dict(os.environ, SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy", LD_PRELOAD=build_shim(wd),
                   LEAPC_FUSE_SOCK="@" + sock, LEAPC_FUSE_SYMS=fuse_syms(), HOME=wd, XDG_CONFIG_HOME=wd)
        args = [FUSE, "--machine", "ts2068", "--rom-ts2068-0", os.path.join(b, "test_basic.bin"),
                "--rom-ts2068-1", os.path.join(b, "exrom.bin"), "--no-sound", "--speed", "20000", "--no-auto-load",
                "--no-traps", "--no-confirm-actions", "--no-autosave-settings", "--debugger-command", dbg]
        self.out = open(self.out_path, "w")
        self.proc = subprocess.Popen(args, env=env, stdout=self.out, stderr=subprocess.STDOUT, cwd=wd)
        t0 = time.time()
        while True:
            self.s = socket.socket(socket.AF_UNIX)
            try:
                self.s.connect("\0" + sock); break
            except OSError:
                self.s.close()
                if self.proc.poll() is not None or time.time() - t0 > 30:
                    raise RuntimeError(open(self.out_path).read()[-400:])
                time.sleep(0.05)
        self.f = self.s.makefile("rw")
        self.wait(lambda: self.vals(0xB0070) is not None, 60)
    def cmd(self, line):
        self.f.write(line + "\n"); self.f.flush(); r = self.f.readline().strip()
        if not r.startswith("ok"): raise RuntimeError("%r -> %r" % (line, r))
        return r[3:]
    def peek(self, a, n): return bytes.fromhex(self.cmd("peek %d %d" % (a, n)))
    def poke(self, a, d): self.cmd("poke %d %s" % (a, d.hex()))
    def vals(self, marker):
        self.out.flush()
        v = [int(x, 16) for x in open(self.out_path).read().split() if re.fullmatch(r"0x[0-9a-f]+", x)]
        if marker not in v: return None
        i = len(v) - 1 - v[::-1].index(marker); return v[i + 1:]
    def wait(self, c, t):
        t0 = time.time()
        while not c():
            if time.time() - t0 > t: raise TimeoutError
            time.sleep(0.02)
    def run(self, lines):
        S = self.S
        blob = b"".join(struct.pack("<H", len(l) + 1) + l.encode() + b"\r" for l in lines)
        base = S["PROG_AREA_START"]; self.poke(base, blob)
        for c in ("PROG_END", "ARRAYS_END"): self.poke(S[c], struct.pack("<H", base + len(blob)))
        self.poke(0xFF00, struct.pack("<H", S["V2_COMMAND_LOOP.loop"]))
        before = len(open(self.out_path).read())
        f0 = int(self.cmd("ping").split()[0]); F0 = int.from_bytes(self.peek(S["FRAMES"], 3), "little")
        self.cmd("dbg set z80:sp 0xff00\\nset z80:iff1 1\\nset z80:iff2 1\\nset z80:pc 0x%04x" % S["V2_RUN_STORED"])
        def done():
            self.out.flush()
            if "0xb0071" not in open(self.out_path).read()[before:]: return False
            v = self.vals(0xB0071); return v is not None and len(v) >= 4
        self.wait(done, 300)
        v = self.vals(0xB0071); f1 = v[0]; F1 = v[1] | v[2] << 8 | v[3] << 16
        return f1 - f0, F1 - F0
    def stop(self):
        try: self.f.write("quit\n"); self.f.flush()
        except OSError: pass
        try: self.proc.wait(5)
        except subprocess.TimeoutExpired: self.proc.kill()

def main():
    worst = 0
    for b in sys.argv[1:] or ["build"]:
        b = os.path.abspath(b)
        tag = os.path.basename(os.path.dirname(b))
        for name, prog in PROGS.items():
            fz = F(b, tag)
            try:
                fuse_n, v2_n = fz.run(prog)
            finally:
                fz.stop()
            if name.startswith("float"):
                worst = max(worst, fuse_n - v2_n)
            print("%-8s %s  Fuse frames %6d  V2 FRAMES %6d  lost %5d (%.2f%%)" % (
                tag, name, fuse_n, v2_n, fuse_n - v2_n, 100.0 * (fuse_n - v2_n) / fuse_n))
    return 1 if worst > 2 else 0


if __name__ == "__main__":
    sys.exit(main())

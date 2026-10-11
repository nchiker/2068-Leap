#!/usr/bin/env python3
"""STUDY: exhaustive-boundary + random oracle for the VM integer ops, run as REAL Z80 code in ZEsarUX.

A tiny driver (assembled with sjasmplus against the build's symbols) loops over (a,b) pairs held in RAM and,
for each, either calls VM_MUL_CHECKED directly ('mul') or patches and runs a 3-opcode bytecode program
PUSH_I16 a / PUSH_I16 b / <op> / HALT through the REAL VM_RUN ('add', 'sub', 'mulop').  Results are compared with an
exact Python reference.

   python3 tools/study_vm_oracle.py mul|add|sub|mulop [random_count]   (after `make build`)
Env: TS2068_DEBUG_STATE_DIR / TS2068_V2_PORT as for the other suites.
"""
import os
import random
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_prod import *            # noqa: E402,F401,F403
import v2_prod as P              # noqa: E402

OPS = {"add": 5, "sub": 7, "mulop": 8}
IN, OUT, DRV = 0xE000, 0xE800, 0xF400
BATCH = 250


def hsym(n):
    return HSYM[n]


def build_driver(mode, opcode):
    src = ["    DEVICE ZXSPECTRUM48", "    ORG %d" % DRV]
    for n in ("VM_CODE_BASE", "VM_IP", "VM_SP", "VM_STACK_TOP", "VM_HALTED", "VM_ERROR_CODE", "VM_RUN", "VM_POP",
              "VM_TOS_TAG", "VM_STR_TEMP_NEXT", "VM_FLOAT_TEMP_NEXT", "VM_FLOAT_ADDR"):
        src.append("%s EQU $%04X" % (n, hsym(n)) if n in HSYM else "%s EQU $%04X" % (n, SYM[n]))
    if mode == "mul":
        src.append("VM_MUL_CHECKED EQU $%04X" % hsym("VM_MUL_CHECKED"))
    src += ["    ld ix,%d" % IN, "    ld iy,%d" % OUT, "    ld a,(CNT)", "    ld b,a",
            ".next:", "    push bc"]
    if mode == "mul":
        src += ["    ld l,(ix+0)", "    ld h,(ix+1)", "    ld e,(ix+2)", "    ld d,(ix+3)",
                "    call VM_MUL_CHECKED", "    ld (iy+0),l", "    ld (iy+1),h", "    ld a,0", "    rla", "    ld (iy+2),a"]
    else:
        src += ["    ld hl,VM_CODE_BASE",
                "    ld (hl),2", "    inc hl", "    ld a,(ix+0)", "    ld (hl),a", "    inc hl", "    ld a,(ix+1)", "    ld (hl),a", "    inc hl",
                "    ld (hl),2", "    inc hl", "    ld a,(ix+2)", "    ld (hl),a", "    inc hl", "    ld a,(ix+3)", "    ld (hl),a", "    inc hl",
                "    ld (hl),%d" % opcode, "    inc hl", "    ld (hl),0",
                "    ld hl,VM_CODE_BASE", "    ld (VM_IP),hl", "    ld hl,VM_STACK_TOP", "    ld (VM_SP),hl",
                "    xor a", "    ld (VM_HALTED),a", "    ld (VM_ERROR_CODE),a", "    ld (VM_TOS_TAG),a",
                "    ld (VM_STR_TEMP_NEXT),a", "    ld (VM_FLOAT_TEMP_NEXT),a",
                "    call VM_RUN",
                "    ld a,(VM_ERROR_CODE)", "    ld (iy+2),a",
                "    call VM_POP", "    ld (iy+0),l", "    ld (iy+1),h", "    ld (iy+3),a",
                "    cp 1", "    jr nz,.nofloat", "    ld a,l", "    call VM_FLOAT_ADDR", "    push iy", "    pop de", "    ld bc,4", "    ex de,hl",
                "    add hl,bc", "    ex de,hl", "    ld bc,5", "    ldir",       # copy the 5-byte float to iy+4..8
                ".nofloat:"]
    src += ["    pop bc", "    ld de,4", "    add ix,de", "    ld de,12", "    add iy,de", "    djnz .next",
            "DONE: jr DONE", "CNT: DB 0"]
    d = tempfile.mkdtemp(prefix="oracle-")
    asm, binf = os.path.join(d, "drv.asm"), os.path.join(d, "drv.bin")
    open(asm, "w").write("\n".join(src) + "\n    SAVEBIN \"%s\", %d, $-%d\n" % (binf, DRV, DRV))
    r = subprocess.run(["sjasmplus", "--sym=" + os.path.join(d, "drv.sym"), asm], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(r.stdout + r.stderr)
    done = [int(l.split()[2], 16) for l in open(os.path.join(d, "drv.sym")) if l.startswith("DONE:")][0]
    cnt = [int(l.split()[2], 16) for l in open(os.path.join(d, "drv.sym")) if l.startswith("CNT:")][0]
    return open(binf, "rb").read(), done, cnt


PROMOTE = os.environ.get("ORACLE_PROMOTE") == "1"


def decode_float(b):
    e, b1, b2, b3, b4 = b
    if e == 0:
        v = b2 | b3 << 8
        return v - 65536 if v >= 32768 else v
    sign = -1 if b1 & 0x80 else 1
    mant = ((b1 | 0x80) & 0xFF) << 24 | b2 << 16 | b3 << 8 | b4
    return sign * mant * 2.0 ** (e - 128 - 32)


def s16(v):
    return v - 65536 if v >= 32768 else v


def reference(mode, a, b):
    exact = {"mul": a * b, "mulop": a * b, "add": a + b, "sub": a - b}[mode]
    return exact, -32768 <= exact <= 32767


def cases(rnd):
    V = sorted({0, 1, 2, 3, 4, 5, 7, 10, 11, 100, 127, 128, 180, 181, 182, 183, 255, 256, 257, 1000, 3276, 3277, 4095, 4096, 8191, 8192,
                10922, 10923, 16383, 16384, 16385, 20000, 32766, 32767, 181 * 181, 30000, 25000})
    V = sorted({s * v for v in V for s in (1, -1)} | {-32768, -32767})
    out = [(a, b) for a in V for b in V]
    rr = random.Random(2068)
    for _ in range(rnd):
        k = rr.random()
        if k < 0.35:
            a = rr.randint(-32768, 32767)
            b = rr.randint(-32768, 32767)
        elif k < 0.7:                      # b sits on the overflow threshold of a
            a = rr.choice([-1, 1]) * rr.randint(1, 32768)
            a = max(-32768, min(32767, a))
            t = 32767 // max(1, abs(a))
            b = rr.choice([-1, 1]) * max(0, t + rr.randint(-2, 3))
            b = max(-32768, min(32767, b))
        else:                              # small * big
            a = rr.randint(-300, 300)
            b = rr.randint(-32768, 32767)
        out.append((a, b))
    return out


def main():
    mode = sys.argv[1]
    nrand = int(sys.argv[2]) if len(sys.argv) > 2 else 20000
    opcode = OPS.get(mode, 0)
    drv, done, cnt = build_driver(mode, opcode)
    P.boot()
    P.put_store(["x = 1"])                     # a real RUN carves the run-time tables (float temps) the driver reuses
    P.call_prompt("V2_RUN_STORED")
    P.poke(DRV, drv)
    pairs = cases(nrand)
    bad, nfit, novf = [], 0, 0
    for i in range(0, len(pairs), BATCH):
        chunk = pairs[i:i + BATCH]
        P.poke(IN, b"".join(struct.pack("<hh", a, b) for a, b in chunk))
        P.poke(cnt, len(chunk))
        D("mem-write", "0xFF00", struct.pack("<H", done).hex())
        D("set-register", "SP", "0xFF00")
        D("set-register", "PC", hex(DRV))
        P.run_to(done, 400_000_000)
        raw = read(OUT, 12 * len(chunk))
        for k, (a, b) in enumerate(chunk):
            lo, hi, x, y = raw[12 * k:12 * k + 4]
            fl = raw[12 * k + 4:12 * k + 9]
            exact, fits = reference(mode, a, b)
            got = s16(lo | hi << 8)
            if mode == "mul":
                ovf = bool(x)                          # carry captured via RLA of A=0 after the call? see driver
                ok = (ovf == (not fits)) and (ovf or got == exact)
            else:
                err = x
                if fits:
                    ok = err == 0 and y == 0 and got == exact
                elif PROMOTE:
                    ok = err == 0 and y == 1 and decode_float(fl) == exact
                else:
                    ok = err == 67
            nfit += fits
            novf += not fits
            if not ok:
                bad.append((a, b, exact, fits, got, x, y, fl.hex(), decode_float(fl)))
        print("batch %d..%d done, mismatches so far %d" % (i, i + len(chunk), len(bad)), flush=True)
    print("%s: %d pairs (%d fit, %d overflow), mismatches %d" % (mode, len(pairs), nfit, novf, len(bad)))
    for b in bad[:25]:
        print("  MISMATCH a=%d b=%d exact=%d fits=%s got=%d aux=%d,%d" % b)
    D("stop")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

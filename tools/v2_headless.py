"""Shared helpers for headless production-ROM checks (ts2068-debug / ZEsarUX)."""
import contextlib, io, json, os, struct, subprocess, sys

try:
    from ts2068_debug.cli import main as _cli_main
except ImportError:
    _cli_main = None

# Each D() used to start a `ts2068-debug` process (~77 ms each, before connecting). The CLI's own
# main() is called in-process instead: the same commands, state directory and JSON, without the
# process start. V2_HEADLESS_SUBPROCESS=1 (or a missing package) goes back to one process a call.
_SUBPROCESS = _cli_main is None or os.environ.get("V2_HEADLESS_SUBPROCESS") == "1"

def D(*a, t=300):
    if _SUBPROCESS:
        r = subprocess.run(["ts2068-debug", "--json", *a], capture_output=True, text=True, timeout=t)
        out = r.stdout
    else:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(io.StringIO()):
            try:
                _cli_main(["--json", *a])
            except SystemExit:
                pass
        out = buf.getvalue()
    try:
        return json.loads(out)
    except Exception:
        return out

def syms(path):
    out = {}
    for l in open(path):
        p = l.split()
        if len(p) >= 3 and p[1] == "EQU" and "." not in p[0]:
            out[p[0].rstrip(":")] = int(p[2], 16)
    return out

SYM = syms("build/exrom.sym")
HSYM = syms("build/test_basic.sym")
RET = [int(l.split()[2], 16) for l in open("build/exrom.sym") if l.startswith("V2_COMMAND_LOOP.loop:")][0]

def read(a, n): return bytes.fromhex(D("mem", hex(a), str(n))["hex"])
def w16(a): b = read(a, 2); return b[0] | b[1] << 8
def sym(name): return SYM.get(name) or HSYM[name]

def start():
    D("stop")
    port = ["--port", os.environ["TS2068_V2_PORT"]] if os.environ.get("TS2068_V2_PORT") else []
    D("start", "--rom", "build/ts2068rom_zesarux.bin", "--symbols", "build/exrom.sym", *port)
    D("reset")
    D("run", "--until", "V2_COMMAND_LOOP.loop", "--max-instructions", "80000000")
    D("pause")

def load(lines):
    blob = b"".join(struct.pack("<H", len(l) + 1) + l.encode() + b"\r" for l in lines)
    D("mem-write", hex(HSYM["PROG_AREA_START"]), blob.hex())
    end = HSYM["PROG_AREA_START"] + len(blob)
    for s in ("PROG_END", "ARRAYS_END"):
        D("mem-write", hex(SYM[s]), struct.pack("<H", end).hex())
    assert read(HSYM["PROG_AREA_START"], len(blob)) == blob

def run(lines, maxi=150000000, times=1):
    start(); load(lines)
    for _ in range(times):
        D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
        D("set-register", "SP", "0xFF00")
        D("set-register", "PC", hex(sym("V2_RUN_STORED")))
        D("run", "--until", hex(HSYM["IO_READ_KEY"]), "--max-instructions", str(maxi))
        D("pause")
    ce = read(HSYM["COMPILE_ERROR_CODE"], 1)[0]
    ve = read(HSYM["VM_ERROR_CODE"], 1)[0]
    base = w16(HSYM["RT_SYMTAB_PTR"])
    def v(i): return int.from_bytes(read(base + 3 * i + 1, 2), "little")
    return ce, ve, v


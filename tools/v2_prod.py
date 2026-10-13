"""Shared harness for the R10.9 production-ROM regression suites.

Everything here drives the REAL production image (`build/ts2068rom_zesarux.bin`,
HOME + EXROM exactly as shipped) under ZEsarUX through ts2068-debug:

* key injection through the ISR latch (`KBD_LASTK`/`KBD_KEYHIT`) -- the editor,
  command loop, dispatcher, compiler and VM all run unmodified;
* tape input through ZEsarUX "real tape" (`realtape-open`, EAR line samples
  built by `tools/tape_synth.py`) -- the real `STORAGE_LOAD` /
  `STORAGE_RECEIVE_BLOCK` code reads the signal through port $FE;
* direct calls into production routines (`V2_RUN_STORED`, `V2_DISPATCH`, ...)
  with state written to RAM, where typing or tape timing would add nothing.

What is NOT real here (documented in docs/R10_9_PHASE1_REPORT.md): the
analogue cassette path, physical keyboard matrix timing, display contention,
real EXROM/Dock hardware, real AY / ULAplus / printer hardware.

The runner implements strict expected-failure semantics:

* PASS   a gate test passed;
* XFAIL  a KNOWN, documented defect reproduced (the correct-behaviour
         assertion failed, as recorded);
* FAIL   a gate test failed, or a harness error occurred -> non-zero exit;
* XPASS  a case marked as a known defect now behaves correctly -> non-zero
         exit: the defect was fixed (or the test is wrong); remove the
         `xfail` marker and keep it as a gate test.
"""
import atexit
import json
import os
import shutil
import struct
import sys
import tempfile
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import v2_headless as H           # noqa: E402
import tape_synth as TS           # noqa: E402
from v2_headless import D, SYM, HSYM, RET, read, w16   # noqa: E402,F401

IOK = HSYM["IO_READ_KEY"]
CPU_BOOT_T = 4_200_000            # measured T-states from reset to V2_COMMAND_LOOP.loop

KEY_ENTER, KEY_LEFT, KEY_DOWN, KEY_UP, KEY_RIGHT = 0x0D, 0x01, 0x02, 0x03, 0x04
KEY_DELETE, KEY_INSERT_LINE, KEY_DELETE_LINE, KEY_BREAK = 0x08, 0x0B, 0x0F, 0x10


def sym(name):
    return SYM[name] if name in SYM else HSYM[name]


def local_sym(name):
    """Address of a dotted local label (v2_headless.syms() skips them)."""
    for l in open("build/exrom.sym"):
        t = l.split()
        if len(t) >= 3 and t[0].rstrip(":") == name:
            return int(t[2], 16)
    raise KeyError(name)


def regs():
    return D("regs")["registers"]


def pc():
    return regs()["PC"]


# ---------------------------------------------------------------- raw ZRCP
def _state_port():
    sd = os.environ.get("TS2068_DEBUG_STATE_DIR", os.path.expanduser("~/.ts2068-debug"))
    return json.load(open(os.path.join(sd, "state.json")))["port"]


def zr(cmd, t=120):
    from ts2068_debug.zrcp import ZRCPClient
    c = ZRCPClient(port=_state_port())
    c.connect()
    try:
        return c.command(cmd, timeout=t)
    finally:
        c.close()


_tmpdir = None


def _tape_path():
    global _tmpdir
    if _tmpdir is None:
        _tmpdir = tempfile.mkdtemp(prefix="v2tape-")
        atexit.register(shutil.rmtree, _tmpdir, True)
    return os.path.join(_tmpdir, "t%d.rwa" % int(time.time() * 1000))


# ----------------------------------------------------------------- session
def boot(tape=None, lead=CPU_BOOT_T + 1_800_000, attempts=3):
    """Boot the production ROM to the editor prompt (paused).  With `tape`, a
    tape_synth.Tape is inserted as the EAR input first; ZEsarUX resets the
    machine on insert and starts playing, so `lead` T-states of silence precede
    the first block (boot takes ~CPU_BOOT_T).  A boot that does not reach the
    editor's key wait is retried (emulator start-up occasionally stalls)."""
    for n in range(attempts):
        try:
            H.start()
            if tape is not None:
                zr("realtape-open " + tape.write_rwa(_tape_path(), lead))
                D("run", "--until", "V2_COMMAND_LOOP.loop", "--max-instructions", "200000000")
                D("pause")
            D("run", "--until", hex(IOK), "--max-instructions", "80000000")
            D("pause")
            if pc() == IOK:
                return
        except Exception:
            if n == attempts - 1:
                raise
        D("stop")
    raise AssertionError("boot did not reach the editor key wait after %d attempts" % attempts)


def shutdown():
    D("stop")


def run_to(target, maxi=100_000_000, t=1800):
    """Run until PC == target (symbol or address).  True iff it was reached."""
    a = sym(target) if isinstance(target, str) else target
    D("run", "--until", hex(a), "--max-instructions", str(maxi), t=t)
    D("pause")
    return pc() == a


def call(addr, maxi=100_000_000, until=IOK, **registers):
    """Call a production routine; it returns into V2_COMMAND_LOOP.loop (as the
    command loop's own callees do) and we stop at the next key wait."""
    a = sym(addr) if isinstance(addr, str) else addr
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    for k, v in registers.items():
        D("set-register", k, hex(v))
    D("set-register", "PC", hex(a))
    return run_to(until, maxi)


def poke(addr, data):
    if isinstance(data, int):
        data = bytes([data])
    D("mem-write", hex(addr), data.hex())


def poke16(addr, v):
    poke(addr, struct.pack("<H", v))


def msg_name(ptr):
    for n, a in SYM.items():
        if n.startswith("V2_MSG_") and a == ptr:
            return n[7:]
    return "?%04X" % ptr


def to_prompt(maxi=60_000_000):
    """Run on until the next key wait; returns the V2_SHOW_MESSAGE name seen on the
    way (or None).  Used after any action that may end in a message."""
    D("break", "V2_SHOW_MESSAGE", "--index", "2")
    seen = None
    try:
        D("run", "--until", hex(IOK), "--max-instructions", str(maxi), t=1800)
        D("pause")
        if pc() == sym("V2_SHOW_MESSAGE"):
            seen = msg_name(regs()["HL"])
            D("clear-break", "--index", "2")
            D("run", "--until", hex(IOK), "--max-instructions", str(maxi), t=1800)
            D("pause")
    finally:
        try:
            D("clear-break", "--index", "2")
        except Exception:
            pass
    return seen if pc() == IOK else ("HUNG@%04X" % pc() if seen is None else seen)


def call_prompt(addr, maxi=60_000_000, **registers):
    """Call a production routine (returning into the command loop) and run to the
    next key wait; returns the message name shown on the way, or None."""
    a = sym(addr) if isinstance(addr, str) else addr
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    for k, v in registers.items():
        D("set-register", k, hex(v))
    D("set-register", "PC", hex(a))
    return to_prompt(maxi)


def set_name(text, request_type=0, buf=0xFE80):
    """Fill V2_NAME_PTR/LEN/V2_REQUEST_TYPE as V2_PARSE_NAME would for a quoted name."""
    poke(buf, text.encode())
    poke16(sym("V2_NAME_PTR"), buf)
    poke(sym("V2_NAME_LEN"), len(text))
    poke(sym("V2_REQUEST_TYPE"), request_type)


def tape_op(tape, existing=None, routine="V2_LOAD", name="TEST", request_type=0,
            lead=CPU_BOOT_T + 1_800_000, maxi=900_000_000, interfere=None, prepare=None):
    """Boot with `tape` as EAR input, optionally pre-load a program into the store,
    then run the real LOAD/VERIFY routine and report what happened.

    `interfere(state)` (optional) runs once the data block is being received (see
    `wait_in_data`) and may alter machine state exactly where hardware would."""
    boot(tape, lead)
    if existing is not None:
        put_store(existing)
    if prepare:
        prepare()
    before = read(sym("PROG_AREA_START"), w16(sym("PROG_END")) - sym("PROG_AREA_START"))
    set_name(name, request_type)
    a = sym(routine)
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(a))
    if interfere:
        interfere()
    msg = to_prompt(maxi)
    pe = w16(sym("PROG_END"))
    return {"msg": msg, "prog_end": pe, "before": before,
            "after": read(sym("PROG_AREA_START"), max(0, pe - sym("PROG_AREA_START"))),
            "op_state": read(sym("STORAGE_OP_STATE"), 1)[0],
            "verify_mode": read(sym("STORAGE_VERIFY_MODE"), 1)[0],
            "edit_pos": w16(sym("CUR_EDIT_POS")), "edit_index": w16(sym("CUR_EDIT_INDEX"))}


def wait_in_data(min_bytes, chunk=40_000, limit=6_000_000, dest=None):
    """Run in small chunks until the receiver is `min_bytes` into the data block
    (IX walks the destination buffer while the data block is received)."""
    dest = sym("PROG_AREA_START") if dest is None else dest
    for _ in range(limit // chunk):
        D("run", "--max-instructions", str(chunk), t=600)
        ix = regs()["IX"]
        if dest + min_bytes <= ix < dest + 0x1000:
            return True
    return False


def hold_space_for_one_sample():
    """SPACE-abort: at the instruction after the `in a,($FE)` of the receiver's edge
    sampler, make the keyboard read report SPACE held (bit 0 low).  This is exactly
    the value a physical SPACE press produces on that port read."""
    e1 = local_sym("STORAGE_RECEIVE_BLOCK.edge1")
    code = read(e1, 32)
    i = code.find(bytes([0xDB, 0xFE, 0x1F, 0xD0]))      # in a,($FE) / rra / ret nc
    assert i >= 0, "edge sampler pattern not found"
    rra = e1 + i + 2
    for _ in range(64):
        if pc() == rra:
            break
        D("step", "--count", "1")
    assert pc() == rra, "receiver sampler not found at %04X (pc=%04X)" % (rra, pc())
    a = regs()["AF"] >> 8
    D("set-register", "A", hex(a & 0xFE))


def _in_rra(label, tail):
    """Address of the `rra` after the `in a,($FE)` in routine-local `label`
    (pattern in a,($FE) / rra / <tail byte>)."""
    a = local_sym(label)
    code = read(a, 48)
    i = code.find(bytes([0xDB, 0xFE, 0x1F]) + tail)
    assert i >= 0, "in a,($FE)/rra pattern not found in " + label
    return a + i + 2


def _space_down_at(addr, maxi):
    assert run_to(addr, maxi), "never reached %04X" % addr
    D("set-register", "A", hex((regs()["AF"] >> 8) & 0xFE))        # bit 0 low = SPACE down


def press_space(maxi=400_000_000):
    """A real SPACE press as the production code sees it: the receiver's edge sampler
    reads SPACE down at its next sample (-> abort), and SPACE is STILL down when
    STORAGE_LOAD re-reads it to classify the failure (a human keypress lasts
    milliseconds, the failure is reported microseconds later).  Both SPACE reads in
    STORAGE_LOAD's failure path (header-search give-up, abort classification) are
    forced; the keyboard matrix itself is not exercised (see TESTING.md)."""
    _space_down_at(_in_rra("STORAGE_RECEIVE_BLOCK.edge1", b"\xD0"), maxi)
    held = _in_rra("STORAGE_LOAD.space_held", b"\xC9")
    for _ in range(2):
        if not run_to(held, 40):          # the header-search give-up is followed within ~15
            break                         # instructions by the classification read; the data
                                          # path has only the latter (40 stays short of the message)
        D("set-register", "A", hex((regs()["AF"] >> 8) & 0xFE))


def capture_save(cmdline, maxi=60_000_000):
    """Run a typed SAVE command through the real V2_DISPATCH; STORAGE_SEND_BLOCK is
    intercepted at its call site (arguments recorded, call skipped).  Returns
    ([(flag, bytes)...], message-or-None)."""
    poke(sym("EDIT_LINE_BUF"), cmdline.encode() + b"\0")
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(sym("V2_DISPATCH")))
    blocks, msg = [], None
    send, show = sym("STORAGE_SEND_BLOCK"), sym("V2_SHOW_MESSAGE")
    D("break", "STORAGE_SEND_BLOCK", "--index", "3")
    D("break", "V2_SHOW_MESSAGE", "--index", "2")
    try:
        while True:
            D("run", "--until", hex(IOK), "--max-instructions", str(maxi), t=1800)
            D("pause")
            p = pc()
            if p == send:
                r = regs()
                blocks.append((r["AF"] >> 8, read(r["IX"], r["DE"])))
                sp = r["SP"]
                ret = read(sp, 2)
                D("set-register", "SP", hex(sp + 2))
                D("set-register", "PC", hex(ret[0] | ret[1] << 8))
            elif p == show:
                msg = msg_name(regs()["HL"])
                D("clear-break", "--index", "2")
            else:
                break
    finally:
        for i in ("2", "3"):
            try:
                D("clear-break", "--index", i)
            except Exception:
                pass
    return blocks, msg if pc() == IOK else "HUNG@%04X" % pc()


def key(code, maxi=40_000_000):
    """Inject one translated key code through the ISR latch and run to the next key wait."""
    poke(sym("KBD_LASTK"), code)
    poke(sym("KBD_KEYHIT"), 1)
    return to_prompt(maxi)


def type_text(text, enter=True):
    last = None
    for ch in text:
        last = key(ord(ch))
    if enter:
        last = key(KEY_ENTER)
    return last


# ------------------------------------------------------------- state access
def edit_line():
    raw = read(sym("EDIT_LINE_BUF"), 128)
    return raw.split(b"\0")[0]


def store():
    """The line store as a list of text lines."""
    start, end = sym("PROG_AREA_START"), w16(sym("PROG_END"))
    data, out, p = read(start, end - start), [], 0
    while p + 2 <= len(data):
        n = data[p] | data[p + 1] << 8
        out.append(data[p + 2:p + 2 + n - 1].decode("latin-1"))
        p += 2 + n
    return out


def put_store(lines):
    H.load(lines)


def cur_index():
    return w16(sym("CUR_EDIT_INDEX"))


def variables(n):
    """First n numeric scalars as (tag, value16) after a run."""
    base = w16(sym("RT_SYMTAB_PTR"))
    out = []
    for i in range(n):
        b = read(base + 3 * i, 3)
        out.append((b[0], b[1] | b[2] << 8))
    return out


def run_program(lines, maxi=150_000_000):
    """Boot, store `lines`, run the real V2_RUN_STORED.  Returns
    (compile_err, vm_err, message-or-None)."""
    boot()
    put_store(lines)
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(sym("V2_RUN_STORED")))
    msg = to_prompt(maxi)
    ce = read(sym("COMPILE_ERROR_CODE"), 1)[0]
    ve = read(sym("VM_ERROR_CODE"), 1)[0]
    return ce, ve, msg


def install_package(name):
    """Install build/v2_package_<name>.bin through the real package entry (the tape
    transport is not involved).  Returns the carry-clear/failed status of the install."""
    path = "build/v2_package_%s.bin" % name
    blob = open(path, "rb").read()
    poke(sym("EXTENSION_MODULE_BASE"), blob)
    poke16(sym("V2_PACKAGE_LEN"), len(blob))
    D("mem-write", "0xFF00", struct.pack("<H", 0xFE00).hex())
    poke(0xFE00, b"\x18\xFE")                      # jr $ -- stop here
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(sym("EXTENSION_MODULE_BASE")))
    ok = run_to(0xFE00, 2_000_000)
    carry = bool(D("regs")["registers"]["AF"] & 1)
    return ok and not carry


# ---------------------------------------------------------------- the runner
class Case:
    def __init__(self, cid, title, fn, xfail):
        self.cid, self.title, self.fn, self.xfail = cid, title, fn, xfail


CASES = []


def case(cid, title, xfail=None):
    """Register a test.  `fn()` returns (ok, detail).  `xfail` = None for a gate
    test, or a string naming the known defect it demonstrates."""
    def deco(fn):
        CASES.append(Case(cid, title, fn, xfail))
        return fn
    return deco


def run_cases(selected=None, label="suite"):
    counts = {"PASS": 0, "XFAIL": 0, "FAIL": 0, "XPASS": 0}
    bad = []
    t0 = time.time()
    for c in CASES:
        if selected and not any(s in c.cid for s in selected):
            continue
        t1 = time.time()
        try:
            ok, detail = c.fn()
            err = False
        except Exception as e:                       # harness/ROM error -> FAIL
            ok, detail, err = False, "ERROR " + "".join(traceback.format_exception_only(type(e), e)).strip(), True
        finally:
            try:
                D("stop")
            except Exception:
                pass
        if err:
            res = "FAIL"
        elif c.xfail:
            res = "XFAIL" if not ok else "XPASS"
        else:
            res = "PASS" if ok else "FAIL"
        counts[res] += 1
        if res in ("FAIL", "XPASS"):
            bad.append(c.cid)
        extra = ("  [known defect: %s]" % c.xfail) if c.xfail and res != "PASS" else ""
        print("%-5s %-28s %s -- %s%s  (%.0fs)" % (res, c.cid, c.title, detail, extra, time.time() - t1),
              flush=True)
    print("%s: %d PASS, %d XFAIL (known defects reproduced), %d FAIL, %d XPASS  [%.0fs]"
          % (label, counts["PASS"], counts["XFAIL"], counts["FAIL"], counts["XPASS"], time.time() - t0))
    if counts["XPASS"]:
        print("XPASS means a known-defect marker is stale: the behaviour is now correct. "
              "Drop `xfail=` for: " + ", ".join(b for b in bad))
    return 1 if (counts["FAIL"] or counts["XPASS"]) else 0

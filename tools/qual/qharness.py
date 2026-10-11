"""Fast production-ROM harness for the V2 qualification study (persistent ZRCP session).

Drives the REAL assembled production image (HOME + EXROM, `build/ts2068rom_zesarux.bin` of a
configuration directory produced by tools/qual/build_configs.sh) in a headless ZEsarUX.  Unlike
tools/v2_prod.py (one `ts2068-debug` process per command, one cold boot per case) this keeps one
socket open and restores a ZEsarUX snapshot of the booted machine before every case, so a case
costs its own emulated run time plus ~20 ms.

What is real: the editor-to-VM run path from V2_RUN_STORED on (chunked source staging, lexer,
compiler, VM, HOME/EXROM banking, the display routines), the INPUT key wait, every error path.
What is substituted (same as tools/v2_prod.py): the program is written straight into the line
store (no typing), keys are delivered through the ISR latch (KBD_LASTK/KBD_KEYHIT), packages are
copied to $F400 and their real entry is called.  The screen is read back with the ROM's own font
(rendered once by the real GFX_PUTCHAR) -- the result is what a user would see.
"""
import os
import struct
import sys
import time

sys.path.insert(0, os.path.expanduser("~/ts2068-debug"))
from ts2068_debug.zrcp import ZRCPClient, ZRCPError      # noqa: E402
from ts2068_debug.process import ZEsarUXProcess          # noqa: E402

ZESARUX = os.path.expanduser("~/Applications/ZEsarUX-13.0")
HARNESS_RET_SLOT = 0xFF00        # return address slot used for the routine call (as v2_prod.py)
KEY_ENTER, KEY_LEFT, KEY_DOWN, KEY_UP, KEY_RIGHT = 0x0D, 0x01, 0x02, 0x03, 0x04
KEY_DELETE, KEY_INSERT_LINE, KEY_DELETE_LINE, KEY_BREAK = 0x08, 0x0B, 0x0F, 0x10


def load_syms(*paths):
    out = {}
    for p in paths:
        for l in open(p):
            t = l.split()
            if len(t) >= 3 and t[1] == "EQU":
                out.setdefault(t[0].rstrip(":"), int(t[2], 16))
    return out


def cell_from(scr, row, col):
    y0 = row * 8
    base = ((y0 & 0xC0) << 5) | ((y0 & 0x38) << 2) | col
    return bytes(scr[base + 0x100 * k] for k in range(8))


class Result:
    __slots__ = ("ce", "ve", "msg", "rows", "attrs", "pc", "status", "line", "edit_index", "t", "extra")

    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k))

    @property
    def text(self):
        """Program output: rows 0..21 joined, trailing blank rows dropped."""
        rows = list(self.rows or [])
        while rows and not rows[-1]:
            rows.pop()
        return "\n".join(rows)

    def as_dict(self):
        return {"ce": self.ce, "ve": self.ve, "msg": self.msg, "status": self.status, "line": self.line,
                "edit_index": self.edit_index, "out": self.text}


class Machine:
    def __init__(self, cfgdir, port, label=None, snapdir=None):
        self.cfgdir = os.path.abspath(cfgdir)
        self.port = port
        self.label = label or os.path.basename(self.cfgdir)
        b = os.path.join(self.cfgdir, "build")
        self.S = load_syms(os.path.join(b, "exrom.sym"), os.path.join(b, "test_basic.sym"))
        self.rom = os.path.join(b, "ts2068rom_zesarux.bin")
        self.snapdir = snapdir or os.path.join(b, "qual_snap_%d" % port)
        os.makedirs(self.snapdir, exist_ok=True)
        self.snap = os.path.join(self.snapdir, "boot.zsf")
        self.proc = None
        self.c = None
        self.glyphs = None
        self.msgs = {a: n[7:] for n, a in self.S.items() if n.startswith("V2_MSG_")}

    # ------------------------------------------------------------- low level
    def sym(self, n):
        return self.S[n]

    def cmd(self, line, timeout=None):
        return self.c.command(line, timeout=timeout)

    def read(self, addr, n):
        out = b""
        while n > 0:
            k = min(n, 4096)
            out += bytes.fromhex(self.cmd("read-memory %d %d" % (addr, k)).strip())
            addr += k
            n -= k
        return out

    def w16(self, addr):
        b = self.read(addr, 2)
        return b[0] | b[1] << 8

    def write(self, addr, data):
        if isinstance(data, int):
            data = bytes([data])
        for i in range(0, len(data), 2048):
            self.cmd("write-memory-raw %d %s" % (addr + i, data[i:i + 2048].hex()))

    def poke16(self, addr, v):
        self.write(addr, struct.pack("<H", v & 0xFFFF))

    def setreg(self, r, v):
        self.cmd("set-register %s=%04XH" % (r, v & 0xFFFF))

    def regs(self):
        out = {}
        for tok in self.cmd("get-registers").split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                try:
                    out[k] = int(v, 16)
                except ValueError:
                    pass
        return out

    def pc(self):
        return self.regs()["PC"]

    def _enable_bp(self):
        try:
            self.cmd("enable-breakpoints")
        except ZRCPError as e:
            if "already" not in str(e).lower():
                raise

    def set_bps(self, addrs):
        """Arm breakpoints 1..n at the given PCs; clear 1..8 beyond."""
        self._enable_bp()
        for i in range(1, 9):
            if i <= len(addrs):
                self.cmd("set-breakpoint %d PC=%04XH" % (i, addrs[i - 1]))
            else:
                self.cmd("set-breakpoint %d" % i)

    def run(self, maxi):
        return self.cmd("run %d" % maxi, timeout=max(30, maxi / 150_000 + 30))

    def step(self):
        self.cmd("cpu-step")

    # ------------------------------------------------------------- lifecycle
    def start(self):
        self.proc = ZEsarUXProcess(ZESARUX, port=self.port, romfile=self.rom)
        self.proc.start()
        self.c = ZRCPClient(port=self.port, timeout=60)
        self.c.connect(retries=100)
        self.cmd("enter-cpu-step")
        self.cmd("reset-cpu")
        self.set_bps([self.sym("IO_READ_KEY")])
        self.run(80_000_000)
        assert self.pc() == self.sym("IO_READ_KEY"), "boot did not reach IO_READ_KEY (%s)" % self.label
        self.cmd("snapshot-save " + self.snap)
        self.glyphs = self._glyph_table()
        self.restore()
        return self

    def stop(self):
        try:
            if self.c:
                self.c.quit()
        finally:
            if self.proc:
                self.proc.stop()

    def restore(self):
        self.cmd("snapshot-load " + self.snap)
        self._enable_bp()

    def _glyph_table(self):
        """Render chars 32..143 with the real GFX_PUTCHAR (A=char, B=row, C=col) and map each
        8x8 cell bitmap back to its character."""
        import subprocess
        import tempfile
        d = tempfile.mkdtemp(prefix="qglyph-")
        src = ["    DEVICE ZXSPECTRUM48", "    ORG $F400", "    ld d,32", "    ld b,0", "    ld c,0", "loop:",
               "    push de", "    push bc", "    ld a,d", "    call $%04X" % self.sym("GFX_PUTCHAR"), "    pop bc",
               "    pop de", "    inc d", "    inc c", "    ld a,c", "    cp 32", "    jr nz,nx", "    ld c,0",
               "    inc b", "nx: ld a,d", "    cp 144", "    jr nz,loop", "done: jr done",
               '    SAVEBIN "%s/g.bin", $F400, $-$F400' % d]
        open(d + "/g.asm", "w").write("\n".join(src) + "\n")
        r = subprocess.run(["sjasmplus", "--sym=" + d + "/g.sym", d + "/g.asm"], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout + r.stderr
        done = [int(l.split()[2], 16) for l in open(d + "/g.sym") if l.startswith("done:")][0]
        self.write(0xF400, open(d + "/g.bin", "rb").read())
        self.write(HARNESS_RET_SLOT, struct.pack("<H", done))
        self.setreg("SP", HARNESS_RET_SLOT)
        self.setreg("PC", 0xF400)
        self.set_bps([done])
        self.run(5_000_000)
        assert self.pc() == done, "glyph render did not finish"
        scr = self.read(0x4000, 6144)
        table = {}
        for i, ch in enumerate(range(32, 144)):
            cell = cell_from(scr, i // 32, i % 32)
            table.setdefault(cell, chr(ch) if ch < 128 else chr(0x2580 + ch - 128))
        table[bytes(8)] = " "
        return table

    def screen_rows(self, scr=None, nrows=24):
        scr = scr if scr is not None else self.read(0x4000, 6144)
        rows = []
        for r in range(nrows):
            s = ""
            for col in range(32):
                cell = cell_from(scr, r, col)
                ch = self.glyphs.get(cell)
                if ch is None:
                    inv = bytes(255 - b for b in cell)
                    ch = self.glyphs.get(inv)
                    ch = ch.lower() if ch and ch.isalpha() else ("~" if ch is None else ch)
                s += ch
            rows.append(s.rstrip())
        return rows

    # ------------------------------------------------------------- BASIC level
    def put_store(self, lines):
        blob = b"".join(struct.pack("<H", len(l) + 1) + l.encode("latin-1") + b"\r" for l in lines)
        start = self.sym("PROG_AREA_START")
        self.write(start, blob)
        end = start + len(blob)
        for s in ("PROG_END", "ARRAYS_END"):
            self.poke16(self.sym(s), end)

    def install_package(self, name):
        blob = open(os.path.join(self.cfgdir, "build", "v2_package_%s.bin" % name), "rb").read()
        self.write(self.sym("EXTENSION_MODULE_BASE"), blob)
        self.poke16(self.sym("V2_PACKAGE_LEN"), len(blob))
        self.write(0xFE00, b"\x18\xFE")
        self.write(HARNESS_RET_SLOT, struct.pack("<H", 0xFE00))
        self.setreg("SP", HARNESS_RET_SLOT)
        self.setreg("PC", self.sym("EXTENSION_MODULE_BASE"))
        self.set_bps([0xFE00])
        self.run(3_000_000)
        ok = self.pc() == 0xFE00 and not (self.regs()["AF"] & 1)
        assert ok, "package %s did not install" % name
        # back to a sane key-wait state for the next routine call (SP restored by the caller)

    def call_routine(self, routine, keys=(), maxi=60_000_000, stop_at_message=True, poll=None):
        """Call `routine` (returning into V2_COMMAND_LOOP.loop) and run until the routine's own
        final key wait.  INPUT/editor key waits met on the way consume `keys` (ISR latch)."""
        ret = self.sym("V2_COMMAND_LOOP.loop")
        iok = self.sym("IO_READ_KEY")
        msg_at = self.sym("V2_SHOW_MESSAGE")
        self.write(HARNESS_RET_SLOT, struct.pack("<H", ret))
        self.setreg("SP", HARNESS_RET_SLOT)
        self.setreg("PC", self.sym(routine) if isinstance(routine, str) else routine)
        bps = [iok, msg_at, ret] if stop_at_message else [iok, ret]
        self.set_bps(bps)
        keys = list(keys)
        msg = None
        scr = None
        status = "OK"
        budget = maxi
        t0 = time.time()
        while True:
            self.run(budget)
            r = self.regs()
            p = r["PC"]
            if p == msg_at:
                hl = r["HL"]
                msg = self.msgs.get(hl) or self.read(hl, 24).split(b"\0")[0].decode("latin-1")
                scr = self.read(0x4000, 6912)
                self.set_bps([iok, ret])
                self.step()
                continue
            if p == ret:
                status = "OK"          # the routine returned into the command loop (error / message paths)
                break
            if p == iok:
                sp = r["SP"]
                retaddr = self.w16(sp)
                if retaddr == ret:     # V2_COMPILE_RUN's final `jp IO_READ_KEY` after a clean run
                    status = "OK"
                    break
                if keys:
                    k = keys.pop(0)
                    self.write(self.sym("KBD_LASTK"), k)
                    self.write(self.sym("KBD_KEYHIT"), 1)
                    self.step()
                    continue
                status = "WAIT"        # a key wait inside the program with no key left to give
                break
            status = "HUNG"
            break
        if scr is None:
            scr = self.read(0x4000, 6912)
        res = Result(ce=self.read(self.sym("COMPILE_ERROR_CODE"), 1)[0],
                     ve=self.read(self.sym("VM_ERROR_CODE"), 1)[0], msg=msg,
                     rows=self.screen_rows(scr), attrs=scr[6144:], pc=self.pc(), status=status,
                     line=self.w16(self.sym("LEX_LINE")) & 0x7FFF,
                     edit_index=self.w16(self.sym("CUR_EDIT_INDEX")), t=time.time() - t0)
        return res

    def run_program(self, lines, keys=(), maxi=60_000_000, packages=(), prepare=None):
        self.restore()
        for p in packages:
            self.install_package(p)
        self.put_store(lines)
        if prepare:
            prepare(self)
        return self.call_routine("V2_RUN_STORED", keys=keys, maxi=maxi)

    def run_immediate(self, text, lines=(), maxi=60_000_000, keys=()):
        """Type-free immediate statement: EDIT_LINE_BUF = ':' + text, through V2_DISPATCH."""
        self.restore()
        self.put_store(list(lines))
        self.write(self.sym("EDIT_LINE_BUF"), (":" + text).encode("latin-1") + b"\0")
        return self.call_routine("V2_DISPATCH", keys=keys, maxi=maxi)

    def scalars(self, n):
        base = self.w16(self.sym("RT_SYMTAB_PTR"))
        b = self.read(base, 3 * n)
        return [(b[3 * i], b[3 * i + 1] | b[3 * i + 2] << 8) for i in range(n)]

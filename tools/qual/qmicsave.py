#!/usr/bin/env python3
"""SAVE through the real tape sender, captured at the MIC line (docs/V2_LEAPC_BACKPORT_PLAN.md item 3.1).

Every other SAVE case skips the sender at its call site and records its arguments (tools/v2_prod.py
capture_save); here the real TAPE_SEND_BLOCK runs. Each `out (PORT_ULA), a` in it gets a ZEsarUX
breakpoint whose action prints TSTATESP * 16 + (A & 8) on ZEsarUX's standard output without stopping,
so the transfer runs undisturbed; the edges are then decoded back into blocks. After 2068-Leap-C's
lcharness.tape_capture / tapes.decode / tapetest.py "roundtrip".

Checked per case: two blocks, each checksum valid; the header (type, name, length = the data block's,
the format word in the autostart field); the data block = the bytes SAVE was asked to send; pilot
counts (8,063 header, 3,223 data, within one); every pulse the stock ROM's width -2..+16 T. Program
SAVE also plays the captured signal back as EAR input to the real LOAD (tools/v2_prod.tape_op), which
must restore the program.

Usage: TS2068_DEBUG_STATE_DIR=<dir> TS2068_V2_PORT=<port> python3 tools/qual/qmicsave.py [--tree DIR] [--port N]
"""
import argparse
import os
import subprocess
import sys
import time
from functools import reduce
from operator import xor
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import qharness                       # noqa: E402
from qharness import Machine          # noqa: E402
import tape_synth as TS               # noqa: E402

TAPE_SLOTS = (14, 15, 16, 17, 18)     # breakpoint slots (set_bps uses 1-8, qcanary 9-11)
PILOT_T, SYNC1_T, SYNC2_T, ZERO_T, ONE_T = 2168, 667, 735, 855, 1710     # the stock ROM's half-pulses
PROG = ["x = 1", "y = 2", "z = x + y", "w = z * 2", "q = w + 1"]


class StdoutProcess(qharness.ZEsarUXProcess):
    """ZEsarUX with its standard output line-buffered into `out_path` (the breakpoint actions print there)."""
    out_path = None

    def start(self):
        args = ["stdbuf", "-oL", "./" + self.binary, "--noconfigfile", "--machine", self.machine,
                "--enable-remoteprotocol", "--remoteprotocol-port", str(self.port), "--vo", "null", "--ao", "null",
                "--romfile", str(Path(self.romfile).resolve())]
        if os.environ.get("TS2068_DEBUG_ZESARUX_FAST", "1") != "0":     # as ts2068-debug: fast unless =0
            args += ["--emulatorspeed", "1000", "--frameskip", "49"]
        with open(self.out_path, "w") as out:
            self._proc = subprocess.Popen(args, cwd=self.install_dir, stdout=out, stderr=subprocess.DEVNULL)


def capture_on(m):
    lo, hi = m.sym("TAPE_SEND_BLOCK"), m.sym("TAPE_RECV_BLOCK")
    code = m.read(lo, hi - lo)
    outs = [lo + i for i in range(len(code) - 1) if code[i:i + 2] == b"\xD3\xFE"]
    assert 1 <= len(outs) <= len(TAPE_SLOTS), "TAPE_SEND_BLOCK: %d `out ($FE), a`" % len(outs)
    m.cap_at = os.path.getsize(StdoutProcess.out_path)
    for slot, a in zip(TAPE_SLOTS, outs):
        m.cmd("set-breakpoint %d PC=%04XH" % (slot, a))
        m.cmd("set-breakpointaction %d printe TSTATESP*16+(A&8)" % slot)


def capture_off(m):
    for slot in TAPE_SLOTS:
        m.cmd("set-breakpoint %d" % slot)
        m.cmd("set-breakpointaction %d" % slot)
    m.cmd("noop")
    time.sleep(0.2)
    with open(StdoutProcess.out_path, "rb") as f:
        f.seek(m.cap_at)
        lines = f.read().decode("latin-1").split("\n")
    return [int(v) for v in (x.strip() for x in lines) if v.lstrip("-").isdigit()]


def edges_from_capture(values):
    """[(T, MIC level)] at each level change, the 32-bit counter unwrapped."""
    out, base, prev = [], 0, None
    for v in values:
        v &= 0xFFFFFFFF
        if prev is not None and v < prev:
            base += 1 << 32
        prev = v
        t, level = (base + v) >> 4, (v >> 3) & 1
        if not out or out[-1][1] != level:
            out.append((t, level))
    return out


def decode(edges):
    """The blocks in a MIC signal: [dict(data=framed bytes, ok=checksum, pilot=pulses, widths={name: (min, max)})].
    A block is pilot pulses (1,900-2,500 T), two syncs and bit pulses in pairs; a pulse over 2,500 T ends it."""
    w = [t1 - t0 for (t0, _), (t1, _) in zip(edges, edges[1:])]
    blocks, i = [], 0

    def span(name, x, d):
        lo, hi = d.get(name, (x, x))
        d[name] = (min(lo, x), max(hi, x))

    while i < len(w):
        while i < len(w) and not 1900 <= w[i] <= 2500:
            i += 1
        n, widths = 0, {}
        while i < len(w) and 1900 <= w[i] <= 2500:
            span("pilot", w[i], widths)
            n += 1
            i += 1
        if i + 1 >= len(w) or n < 100:
            break
        span("sync1", w[i], widths)
        span("sync2", w[i + 1], widths)
        i += 2
        bits = []
        while i + 1 < len(w) and w[i] < 2500 and w[i + 1] < 2500:
            b = 1 if w[i] + w[i + 1] > ZERO_T + ONE_T else 0
            span("one" if b else "zero", w[i], widths)
            span("one" if b else "zero", w[i + 1], widths)
            bits.append(b)
            i += 2
        data = bytes(int("".join(map(str, bits[k:k + 8])), 2) for k in range(0, len(bits) - len(bits) % 8, 8))
        blocks.append(dict(data=data, ok=bool(data) and reduce(xor, data, 0) == 0, pilot=n, widths=widths,
                           extra_bits=len(bits) % 8))
    return blocks


def tape_from_edges(edges):
    """The captured signal as a tape_synth.Tape, its pulses exactly as the ROM timed them."""
    t = TS.Tape()
    t.level = edges[0][1] ^ 1
    t.flat(TS.CPU_HZ // 2)
    t.level = edges[0][1]
    for (t0, _), (t1, _) in zip(edges, edges[1:]):
        t._run(t1 - t0)
    t._run(ZERO_T)
    t.flat(TS.CPU_HZ)
    return t


def widths_bad(bl):
    want = dict(pilot=PILOT_T, sync1=SYNC1_T, sync2=SYNC2_T, zero=ZERO_T, one=ONE_T)
    return ["%s %d..%d" % (k, lo, hi) for b in bl for k, (lo, hi) in sorted(b["widths"].items())
            if not want[k] - 2 <= lo <= hi <= want[k] + 16]


def save_captured(m, command, prepare):
    """Run `command` on the real dispatcher with the MIC captured: (message, decoded blocks, edges,
    [(flag, bytes)] the sender was asked for)."""
    m.restore()
    prepare(m)
    m.write(m.sym("EDIT_LINE_BUF"), command.encode() + b"\0")
    asked = []
    send = m.sym("TAPE_SEND_BLOCK")
    capture_on(m)
    try:
        # Stop once at each sender entry to record its arguments, then let it run.
        m.write(qharness.HARNESS_RET_SLOT, bytes([m.sym("V2_COMMAND_LOOP.loop") & 0xFF,
                                                  m.sym("V2_COMMAND_LOOP.loop") >> 8]))
        m.setreg("SP", qharness.HARNESS_RET_SLOT)
        m.setreg("PC", m.sym("V2_DISPATCH"))
        for _ in range(2):
            m.set_bps([send])
            m.run(40_000_000)
            r = m.regs()
            assert r["PC"] == send, "TAPE_SEND_BLOCK not reached (PC=%04X)" % r["PC"]
            asked.append((r["AF"] >> 8, m.read(r["IX"], r["DE"])))
            m.set_bps([])
            m.step()
        msg_at, ret, iok = m.sym("V2_SHOW_MESSAGE"), m.sym("V2_COMMAND_LOOP.loop"), m.sym("IO_READ_KEY")
        m.set_bps([msg_at, ret, iok])
        m.run(200_000_000)
        msg = None
        if m.pc() == msg_at:
            hl = m.regs()["HL"]
            msg = m.msgs.get(hl) or m.read(hl, 24).split(b"\0")[0].decode("latin-1")
            m.set_bps([ret, iok])
            m.step()
            m.run(40_000_000)
        if m.pc() not in (ret, iok):
            msg = "HUNG@%04X (%s)" % (m.pc(), msg)
    finally:
        vals = capture_off(m)
    edges = edges_from_capture(vals)
    return msg, decode(edges), edges, asked


def check_blocks(bl, asked, htype, name, word):
    bad = []
    if len(bl) != 2:
        return ["%d blocks decoded" % len(bl)]
    for b, (flag, data) in zip(bl, asked):
        want = bytes([flag]) + data
        want += bytes([reduce(xor, want, 0)])
        if b["data"] != want or not b["ok"] or b["extra_bits"]:
            bad.append("block flag %02X: decoded %s.. ok=%s extra=%d, sent %s.." %
                       (flag, b["data"][:20].hex(), b["ok"], b["extra_bits"], want[:20].hex()))
    hdr = bl[0]["data"][1:-1]
    if bl[0]["data"][:1] != b"\x00" or bl[1]["data"][:1] != b"\xff":
        bad.append("flags %r" % [b["data"][:1].hex() for b in bl])
    if len(hdr) == 17:
        if hdr[0] != htype or hdr[1:11].rstrip(b" ") != name.encode() or \
                int.from_bytes(hdr[11:13], "little") != len(bl[1]["data"]) - 2 or \
                int.from_bytes(hdr[13:15], "little") != word:
            bad.append("header %s" % hdr.hex())
    else:
        bad.append("header length %d" % len(hdr))
    pilots = [b["pilot"] for b in bl]
    if not (abs(pilots[0] - 8063) <= 1 and abs(pilots[1] - 3223) <= 1):
        bad.append("pilots %r" % pilots)
    bad += widths_bad(bl)
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=".")
    ap.add_argument("--port", type=int, default=10880)
    a = ap.parse_args()
    import v2_abi
    abi = v2_abi.load()
    StdoutProcess.out_path = os.path.join(os.path.abspath(a.tree), "build", "qmicsave_%d.out" % a.port)
    qharness.ZEsarUXProcess = StdoutProcess
    m = Machine(a.tree, a.port, label="micsave")
    failed = 0
    edges_prog = store = None
    try:
        m.start()
        cases = [("program", 'save "PROG"', lambda mm: mm.put_store(PROG), 0, "PROG", abi.fmt_word),
                 ("package", 'save "SH" EXT', lambda mm: mm.install_package("shapes"), 4, "SH", abi.pkg_word)]
        for label, command, prep, htype, name, word in cases:
            msg, bl, edges, asked = save_captured(m, command, prep)
            bad = ([] if msg == "SAVED" else ["message %r" % msg]) + check_blocks(bl, asked, htype, name, word)
            failed += bool(bad)
            print("%-5s save-mic-%-8s %s" % ("FAIL" if bad else "PASS", label,
                                              "; ".join(bad) or "pilots %r, widths %r" %
                                              ([b["pilot"] for b in bl], spans(bl))), flush=True)
            if label == "program" and not bad:
                edges_prog, store = edges, asked[1][1]
    finally:
        m.stop()
    if edges_prog is None:
        print("SKIP  save-mic-playback (no clean program capture)")
        failed += 1
    else:
        import v2_prod as P
        try:
            r = P.tape_op(tape_from_edges(edges_prog), existing=["k = 9"], name="PROG")
        finally:
            P.shutdown()
        ok = r["msg"] == "LOADED" and r["after"] == store
        failed += not ok
        print("%-5s save-mic-playback  LOAD of the captured signal: msg=%s, program %s" %
              ("PASS" if ok else "FAIL", r["msg"], "restored" if r["after"] == store else "differs"))
    print("qmicsave: %d failures" % failed)
    return 1 if failed else 0


def spans(bl):
    out = {}
    for b in bl:
        for k, (lo, hi) in b["widths"].items():
            x, z = out.get(k, (lo, hi))
            out[k] = (min(x, lo), max(z, hi))
    return out


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""SAVE through the real tape sender, captured at the MIC line (docs/V2_LEAPC_BACKPORT_PLAN.md item 3.1).

Every other SAVE case skips the sender at its call site and records its arguments (tools/v2_prod.py
capture_save); here the real TAPE_SEND_BLOCK runs. Each `out (PORT_ULA), a` in it gets a ZEsarUX
breakpoint whose action prints TSTATESP * 16 + (A & 8) on ZEsarUX's standard output without stopping,
so the transfer runs undisturbed; the edges are then decoded back into blocks. After 2068-Leap-C's
lcharness.tape_capture / tapes.decode / tapetest.py "roundtrip".

v2.1.2 (item C): segment 2 is $5B00-$77FF, contended RAM. The cases all-seg2 and array-seg2 put an 808-byte
Array Store entry there (SEG_ENTRY), so the real sender reads block 2's payload (SAVE ... ALL) and a stored
array's descriptor (SAVE ... ARRAY) from $5B00+; their captured signals are played back into the real LOAD,
which must give back the bytes at $5B00.. (LOAD ... ALL receives block 2 straight into $5B00+).

Checked per case: two blocks (three for SAVE ... ALL: v2.1.2 sends segment 2 as block 2 after a gap of about
4.5 s, measured here from the edges), each checksum valid; the header (type, name, length = the data block's,
the format word in the autostart field); the data block = the bytes SAVE was asked to send; pilot
counts (8,063 header, 3,223 data, within one); every pulse the stock ROM's width -2..+16 T. Program
SAVE also plays the captured signal back as EAR input to the real LOAD (tools/v2_prod.tape_op), which
must restore the program. v2.1.2 (item D): `code` saves CODE_N bytes from CODE_START (header type 3, PROGLEN
= the start); its data block must be the memory range byte for byte, and its playback through
LOAD "BLOB" CODE must put the range back after it was wiped.

Usage: TS2068_DEBUG_STATE_DIR=<dir> TS2068_V2_PORT=<port> python3 tools/qual/qmicsave.py [--tree DIR] [--port N]
       [--only CASE ...]   (program package all all-seg2 array-seg2 code; only their playbacks follow)
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
SEG_N = 400                           # elements of the segment-2 array: an 808-byte store entry
SEG_DESC = bytes([1]) + SEG_N.to_bytes(2, "little") + b"".join(((i * 37 + 11) & 0xFFFF).to_bytes(2, "little")
                                                                for i in range(SEG_N))
SEG_ENTRY = (4 + 1 + len(SEG_DESC)).to_bytes(2, "little") + bytes([2, 1]) + b"a" + SEG_DESC   # [len][kind][1]"a"


def put_seg(mm):
    """An Array Store holding SEG_ENTRY at ARR2_BASE (segment 2 is bound to it by the session SAVE ... ALL
    starts, or served by SAVE ... ARRAY from the store)."""
    base = mm.sym("ARR2_BASE")
    mm.write(base, SEG_ENTRY)
    mm.poke16(mm.sym("PAS_END"), base + len(SEG_ENTRY))
CODE_START, CODE_N = 30720, 300                      # $7800: the users' machine-code RAM
CODE_DATA = bytes((i * 29 + 7) & 0xFF for i in range(CODE_N))


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
        t_start = edges[i][0]
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
                           extra_bits=len(bits) % 8, t_start=t_start, t_end=edges[i][0]))
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


def save_captured(m, command, prepare, nblocks=2):
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
        for _ in range(nblocks):
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
    if len(bl) != len(asked):
        return ["%d blocks decoded, %d sent" % (len(bl), len(asked))]
    for b, (flag, data) in zip(bl, asked):
        want = bytes([flag]) + data
        want += bytes([reduce(xor, want, 0)])
        if b["data"] != want or not b["ok"] or b["extra_bits"]:
            bad.append("block flag %02X: decoded %s.. ok=%s extra=%d, sent %s.." %
                       (flag, b["data"][:20].hex(), b["ok"], b["extra_bits"], want[:20].hex()))
    hdr = bl[0]["data"][1:-1]
    if bl[0]["data"][:1] != b"\x00" or any(b["data"][:1] != b"\xff" for b in bl[1:]):
        bad.append("flags %r" % [b["data"][:1].hex() for b in bl])
    if len(hdr) == 17:
        if hdr[0] != htype or hdr[1:11].rstrip(b" ") != name.encode() or \
                int.from_bytes(hdr[11:13], "little") != len(bl[1]["data"]) - 2 or \
                int.from_bytes(hdr[13:15], "little") != word:
            bad.append("header %s" % hdr.hex())
    else:
        bad.append("header length %d" % len(hdr))
    pilots = [b["pilot"] for b in bl]
    if not (abs(pilots[0] - 8063) <= 1 and all(abs(p - 3223) <= 1 for p in pilots[1:])):
        bad.append("pilots %r" % pilots)
    if len(bl) == 3:                                  # SAVE ... ALL: the silence between block 1 and block 2
        gap = bl[2]["t_start"] - bl[1]["t_end"]
        if not 14_900_000 <= gap <= 16_600_000:
            bad.append("gap %d T (%.2f s), want 4.3-4.7 s" % (gap, gap / 3_500_000))
    bad += widths_bad(bl)
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tree", default=".")
    ap.add_argument("--port", type=int, default=10880)
    ap.add_argument("--only", nargs="*", help="run only these cases (program package all all-seg2 array-seg2 code); "
                    "their playbacks follow, the others' do not")
    a = ap.parse_args()
    import v2_abi
    abi = v2_abi.load()
    StdoutProcess.out_path = os.path.join(os.path.abspath(a.tree), "build", "qmicsave_%d.out" % a.port)
    qharness.ZEsarUXProcess = StdoutProcess
    m = Machine(a.tree, a.port, label="micsave")
    failed = 0
    edges_prog = store = edges_all = all_prog = None
    seg_caps = {}                     # all-seg2, array-seg2, code: their captures, played back below
    try:
        m.start()
        cases = [("program", 'save "PROG"', lambda mm: mm.put_store(PROG), 0, "PROG", abi.fmt_word),
                 ("package", 'save "SH" EXT', lambda mm: mm.install_package("shapes"), 4, "SH", abi.pkg_word),
                 ("all", 'save "ALLT" ALL', lambda mm: mm.put_store(PROG), 0, "ALLT", abi.fmt_word),
                 ("all-seg2", 'save "ALLS" ALL', lambda mm: (mm.put_store(PROG), put_seg(mm)), 0, "ALLS", abi.fmt_word),
                 ("array-seg2", 'save "ARR" ARRAY a', put_seg, 8, "ARR", abi.fmt_word),
                 ("code", 'save "BLOB" CODE %d,%d' % (CODE_START, CODE_N),
                  lambda mm: mm.write(CODE_START, CODE_DATA), 3, "BLOB", abi.fmt_word)]
        if a.only:
            cases = [c for c in cases if c[0] in a.only]
        for label, command, prep, htype, name, word in cases:
            msg, bl, edges, asked = save_captured(m, command, prep, 3 if label.startswith("all") else 2)
            bad = ([] if msg == "SAVED" else ["message %r" % msg]) + check_blocks(bl, asked, htype, name, word)
            if label == "all-seg2" and not bad and asked[2][1] != SEG_ENTRY:
                bad.append("block 2 is %d bytes, not the %d-byte segment 2" % (len(asked[2][1]), len(SEG_ENTRY)))
            if label == "array-seg2" and not bad and asked[1][1] != SEG_DESC:
                bad.append("data block is not the stored descriptor (%d bytes)" % len(asked[1][1]))
            if label == "code" and not bad and (asked[1][1] != CODE_DATA or
                                                int.from_bytes(asked[0][1][15:17], "little") != CODE_START):
                bad.append("CODE: data block is not the range, or PROGLEN is not the start")
            failed += bool(bad)
            print("%-5s save-mic-%-8s %s" % ("FAIL" if bad else "PASS", label,
                                              "; ".join(bad) or "pilots %r, widths %r" %
                                              ([b["pilot"] for b in bl], spans(bl))), flush=True)
            if label == "program" and not bad:
                edges_prog, store = edges, asked[1][1]
            if label == "all" and not bad:
                edges_all, all_prog = edges, asked[1][1][:int.from_bytes(asked[0][1][15:17], "little")]
            if label in ("all-seg2", "array-seg2", "code"):
                seg_caps[label] = (edges, asked) if not bad else None
    finally:
        m.stop()
    for label, cap in seg_caps.items():
        failed += seg_playback(label, cap)
    if a.only:
        print("qmicsave: %d failures" % failed)
        return 1 if failed else 0
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
    if edges_all is None:
        print("SKIP  save-mic-all-playback (no clean ALL capture)")
        failed += 1
    else:
        import v2_prod as P
        try:
            r = P.tape_op(tape_from_edges(edges_all), existing=["k = 9"], name="ALLT")
        finally:
            P.shutdown()
        ok = r["msg"] == "LOADED" and r["after"] == all_prog
        failed += not ok
        print("%-5s save-mic-all-playback  LOAD of the captured three-block signal (block 2 found after the real gap): "
              "msg=%s, program %s" % ("PASS" if ok else "FAIL", r["msg"], "restored" if r["after"] == all_prog else "differs"))
    print("qmicsave: %d failures" % failed)
    return 1 if failed else 0


def seg_playback(label, cap):
    """Play a captured signal back into the real LOAD. all-seg2: LOAD (V2_LOAD) receives block 2 straight
    into $5B00+, which must then hold exactly what was sent, with the program and PAS_END back.
    array-seg2: LOAD ... ARRAY of the signal stores the same entry. code (item D): LOAD "BLOB" CODE puts
    the range back at CODE_START after it was wiped. Returns 1 on failure."""
    if cap is None:
        print("SKIP  save-mic-%s-playback (no clean capture)" % label)
        return 1
    import v2_prod as P
    edges, asked = cap
    base = P.sym("ARR2_BASE")
    try:
        if label == "code":
            P.boot(tape_from_edges(edges))
            P.poke(CODE_START, bytes(CODE_N))                  # wipe the range first
            P.poke(P.sym("EDIT_LINE_BUF"), b'load "BLOB" CODE\0')
            msg = P.call_prompt("V2_DISPATCH", maxi=900_000_000)
            got = P.read(CODE_START, CODE_N)
            ok = msg == "LOADED" and got == CODE_DATA
            note = "LOAD \"BLOB\" CODE of the captured signal: msg=%s, range %s" % (
                msg, "restored" if got == CODE_DATA else "differs")
        elif label == "all-seg2":
            prog = asked[1][1][:int.from_bytes(asked[0][1][15:17], "little")]
            r = P.tape_op(tape_from_edges(edges), existing=["k = 9"], name="ALLS")
            got, pas = P.read(base, len(SEG_ENTRY)), P.w16(P.sym("PAS_END"))
            ok = r["msg"] == "LOADED" and r["after"] == prog and got == asked[2][1] and pas == base + len(SEG_ENTRY)
            note = "msg=%s, program %s, segment 2 %s, PAS_END=%04X" % (
                r["msg"], "restored" if r["after"] == prog else "differs", "restored" if got == asked[2][1] else "differs", pas)
        else:
            P.boot(tape_from_edges(edges))
            P.poke(P.sym("EDIT_LINE_BUF"), b'load "ARR" ARRAY a\0')
            msg = P.call_prompt("V2_DISPATCH", maxi=900_000_000)
            got, pas = P.read(base, len(SEG_ENTRY)), P.w16(P.sym("PAS_END"))
            ok = msg == "LOADED" and got == SEG_ENTRY and pas == base + len(SEG_ENTRY)
            note = "msg=%s, store entry %s, PAS_END=%04X" % (msg, "identical" if got == SEG_ENTRY else "differs", pas)
    finally:
        P.shutdown()
    print("%-5s save-mic-%s-playback  %s" % ("PASS" if ok else "FAIL", label, note), flush=True)
    return 0 if ok else 1


def spans(bl):
    out = {}
    for b in bl:
        for k, (lo, hi) in b["widths"].items():
            x, z = out.get(k, (lo, hi))
            out[k] = (min(x, lo), max(z, hi))
    return out


if __name__ == "__main__":
    sys.exit(main())

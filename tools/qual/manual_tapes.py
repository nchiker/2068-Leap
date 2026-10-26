"""Tape examples of the documentation suite (see manual_examples.py, `tape` blocks).

SAVE is captured at the real tape transport (STORAGE_SEND_BLOCK is intercepted at its entry, its
arguments recorded and the call skipped) -- the bytes are exactly what the cassette would record.
LOAD / VERIFY run the real tape receiver (STORAGE_RECEIVE_BLOCK) on an EAR signal synthesised from
those bytes (tools/tape_synth.py) and fed through ZEsarUX's real-tape input, as the release's own
production tests do (tools/v2_prod.py, tools/v2_saveall_checks.py).  The analogue cassette path is
not modelled.
"""
import os
import re
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, HERE)
import tape_synth as TS                      # noqa: E402
from qharness import Machine, ZESARUX, HARNESS_RET_SLOT, ZEsarUXProcess, ZRCPClient  # noqa: E402

BOOT_T = 4_200_000


def message_texts():
    """{V2_MSG name suffix: displayed text} read from the shell source."""
    out = {}
    for ln in open(os.path.join(ROOT, "rom", "exrom_v2_shell.asm")):
        m = re.match(r'V2_MSG_(\w+):\s+DB\s+"([^"]*)"', ln)
        if m:
            out[m.group(1)] = m.group(2).rstrip()   # "SYNTAX ERROR " ends in the space before its code
    return out


MSG = message_texts()


def package_blocks(name):
    """The two tape blocks of a package tape, as tools/make_extension_tzx.py --v2 writes them."""
    import v2_abi
    module = open(os.path.join(ROOT, "build", "v2_package_%s.bin" % name.lower()), "rb").read()
    hdr = (bytes([4]) + name.upper().encode("ascii")[:10].ljust(10, b" ") + len(module).to_bytes(2, "little")
           + v2_abi.load().pkg_word.to_bytes(2, "little") + len(module).to_bytes(2, "little"))
    return [(0x00, hdr), (0xFF, module)]


def capture_save(m, command, maxi=60_000_000):
    """Type a SAVE command through V2_DISPATCH.  -> ([(flag, payload)], message text or None, Result-like)."""
    iok, send, show = m.sym("IO_READ_KEY"), m.sym("STORAGE_SEND_BLOCK"), m.sym("V2_SHOW_MESSAGE")
    ret = m.sym("V2_COMMAND_LOOP.loop")
    m.write(m.sym("EDIT_LINE_BUF"), command.encode("latin-1") + b"\0")
    m.write(HARNESS_RET_SLOT, struct.pack("<H", ret))
    m.setreg("SP", HARNESS_RET_SLOT)
    m.setreg("PC", m.sym("V2_DISPATCH"))
    blocks, msg = [], None
    m.set_bps([iok, send, show])
    while True:
        m.run(maxi)
        r = m.regs()
        p = r["PC"]
        if p == send:
            blocks.append((r["AF"] >> 8, m.read(r["IX"], r["DE"])))
            sp = r["SP"]
            back = m.w16(sp)
            m.setreg("SP", sp + 2)
            m.setreg("AF", r["AF"] | 1)  # the real sender's success: carry set (STORAGE_SAVE stops on carry clear)
            m.setreg("PC", back)
        elif p == show:
            msg = MSG.get(m.msgs.get(r["HL"], ""), None)
            m.set_bps([iok, send])
            m.step()
        elif p == iok or p == ret:
            break
        else:
            raise RuntimeError("SAVE stopped at %#06x" % p)
    return blocks, msg


def boot_with_tape(root, port, glyphs, blocks, lead=BOOT_T + 2_000_000):
    t = TS.Tape()
    for flag, payload in blocks:
        t.block(TS.framed(flag, payload))
    path = os.path.join(tempfile.mkdtemp(prefix="doctape-"), "t.rwa")
    t.write_rwa(path, lead)
    m = Machine(root, port, label="tape%d" % port)
    m.proc = ZEsarUXProcess(ZESARUX, port=port, romfile=m.rom)
    m.proc.start()
    m.c = ZRCPClient(port=port, timeout=60)
    m.c.connect(retries=100)
    m.cmd("enter-cpu-step")
    m.cmd("realtape-open " + path)
    m.set_bps([m.sym("IO_READ_KEY")])
    m.run(150_000_000)
    if m.pc() != m.sym("IO_READ_KEY"):
        raise RuntimeError("tape boot did not reach the editor")
    m.glyphs = glyphs
    return m


def step_matches(actual, want):
    wl = want.split("\n")
    if wl[-1] == "...":
        return actual.split("\n")[:len(wl) - 1] == wl[:-1]
    return actual == want


def lead_for(steps):
    """Silence before the tape starts: long when the program is RUN (or immediate statements are typed)
    before the LOAD / VERIFY that reads the tape, so that the tape has not started playing by then."""
    for cmd, _ in steps:
        if cmd.startswith(("LOAD ", "VERIFY ")):
            return BOOT_T + 2_000_000
        if cmd == "RUN" or cmd.startswith(":"):
            return BOOT_T + 120_000_000
    return BOOT_T + 2_000_000


def run_tape_case(m0, c, port):
    """-> (ok, detail, transcript).  `m0` is the worker's normal machine (phase 1)."""
    m = m0
    m.restore()
    for p in c.pkgs:
        m.install_package(p)
    m.put_store(c.lines)
    tape = []                       # [(flag, payload)] in the order saved
    extra = None                    # machine booted from the tape (phase 2+), to stop at the end
    ok, detail, transcript = True, "ok", []
    pending_boot = False
    try:
        for n_step, (cmd, want) in enumerate(c.steps):
            if cmd in ("power on", "---"):
                pending_boot = True
                continue
            if cmd.startswith("package "):
                tape.extend(package_blocks(cmd.split()[1]))
                continue
            if cmd.startswith("store:"):
                if pending_boot:
                    if extra:
                        extra.stop()
                    extra = m = boot_with_tape(ROOT, port, m0.glyphs, tape, lead_for(c.steps[n_step:]))
                    pending_boot = False
                m.put_store([x.strip() for x in cmd[6:].split(";;")])
                continue
            if pending_boot:
                if extra:
                    extra.stop()
                extra = m = boot_with_tape(ROOT, port, m0.glyphs, tape, lead_for(c.steps[n_step:]))
                pending_boot = False
            if cmd.startswith("SAVE "):
                blocks, msg = capture_save(m, cmd)
                tape.extend(blocks)
                r = None
                text = ""
            else:
                if cmd == "RUN":
                    r = m.call_routine("V2_RUN_STORED", maxi=900_000_000)
                elif cmd == "EDIT":
                    r = m.call_routine("V2_CLEAR_ARRAYS")
                else:
                    m.write(m.sym("EDIT_LINE_BUF"), cmd.encode("latin-1") + b"\0")
                    r = m.call_routine("V2_DISPATCH", maxi=900_000_000)
                msg = MSG.get(r.msg, r.msg) if r.msg else None   # a composed text ("SYNTAX ERROR 2") as read
                text = "\n".join(r.rows[:23]).rstrip("\n")
            transcript.append((cmd, msg, text))
            if isinstance(want, tuple) and want[0] == "msg":
                good = msg == want[1]
                what = "message %r" % want[1]
            elif isinstance(want, tuple):
                good = r is not None and (r.ce if want[0] == "ce" else r.ve) == want[1]
                what = "%s=%d" % want
            elif cmd in ("NEW", "EDIT"):
                good, what = r is not None and r.ce == 0 and r.ve == 0, ""
            else:
                good = r is not None and r.ce == 0 and r.ve == 0 and step_matches(text, want)
                what = "output %r" % want
            if not good and ok:
                ok = False
                detail = "step %r: got message=%r output=%r, want %s" % (cmd, msg, text, what)
    finally:
        if extra:
            extra.stop()
    return ok, detail, transcript


def call_routine_break(m, routine, after, maxi=60_000_000):
    """Like Machine.call_routine, but CAPS SHIFT + SPACE is pressed in the emulated keyboard matrix
    (ZEsarUX `send-keys-event`, the real ISR scan -> BREAK request path) after `after` instructions.
    Returns a qharness Result."""
    from qharness import Result
    ret, iok, msg_at = m.sym("V2_COMMAND_LOOP.loop"), m.sym("IO_READ_KEY"), m.sym("V2_SHOW_MESSAGE")
    m.write(HARNESS_RET_SLOT, struct.pack("<H", ret))
    m.setreg("SP", HARNESS_RET_SLOT)
    m.setreg("PC", m.sym(routine))
    m.set_bps([iok, msg_at, ret])
    m.run(after)
    if m.pc() in (iok, msg_at, ret):
        raise RuntimeError("the program stopped by itself before BREAK was pressed")
    m.cmd("send-keys-event 135 1")
    m.cmd("send-keys-event 128 1")
    m.run(after)
    m.cmd("send-keys-event 128 0")
    m.cmd("send-keys-event 135 0")
    msg, scr = None, None
    for _ in range(40):
        if m.pc() in (iok, msg_at, ret):
            break
        m.run(after)
    if m.pc() == msg_at:
        hl = m.regs()["HL"]
        msg = m.msgs.get(hl)
        scr = m.read(0x4000, 6912)
        m.set_bps([iok, ret])
        m.step()
        m.run(maxi)
    if scr is None:
        scr = m.read(0x4000, 6912)
    return Result(ce=m.read(m.sym("COMPILE_ERROR_CODE"), 1)[0], ve=m.read(m.sym("VM_ERROR_CODE"), 1)[0],
                  msg=msg, rows=m.screen_rows(scr), attrs=scr[6144:], pc=m.pc(), status="OK",
                  line=0, edit_index=0, t=0)

BASE = 0xE000
def u16(v): return struct.pack("<H", v)
def num(vals): return bytes([1]) + u16(len(vals)) + b"".join(u16(v) for v in vals)
def strd(width, elems):
    body = b""
    for e in elems:
        e = e.encode(); body += bytes([len(e)]) + e + bytes(width - 1 - len(e))
    return bytes([1]) + u16(len(elems)) + bytes([width]) + body
def tape(files, bad_checksum=None):
    t = TS.Tape()
    for i, (name, body, kw) in enumerate(files):
        t.block(TS.framed(0, TS.header_payload(8, name, kw.get("length", len(body)), autostart=kw.get("word", K.FMT_WORD))))
        fr = bytearray(TS.framed(0xFF, body))
        if kw.get("bad_checksum"): fr[-1] ^= 0xFF
        t.block(bytes(fr))
        t.silence(0.5)
    return t
def store_state():
    end = P.w16(P.sym("PAS_END"))
    return end, (read(BASE, end - BASE) if end > BASE else b"")
def load(cmd, maxi=900_000_000):
    P.poke(P.sym("EDIT_LINE_BUF"), cmd.encode() + b"\0")
    return P.call_prompt("V2_DISPATCH", maxi=maxi)
def run_prog(prog):
    P.put_store(prog)
    P.call_prompt("V2_RUN_STORED")
    return read(P.sym("COMPILE_ERROR_CODE"), 1)[0], read(P.sym("VM_ERROR_CODE"), 1)[0]
def entry(name, kind, desc):
    nm = name.encode(); return u16(4 + len(nm) + len(desc)) + bytes([kind, len(nm)]) + nm + desc
ok = True
def check(name, cond, detail=""):
    global ok; ok &= bool(cond)
    print(("PASS " if cond else "FAIL ") + name + ("  " + detail if detail else ""), flush=True)


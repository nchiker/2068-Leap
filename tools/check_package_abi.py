#!/usr/bin/env python3
"""Package-ABI drift check (part of `make check`; needs `make build` first).

Fails when the HOME image, the five package images and include/v2_package_abi.inc
stop agreeing.  It is the automated half of docs/v2/PACKAGE_ABI.md:

 1. the service table in the built HOME image matches the ABI file (header bytes, slot
    count, every slot is `jp <the named HOME routine>`), and fits the KTAB padding;
 2. every pinned RAM cell / constant is where the ABI file says (the HOME build ASSERTs
    this too; this re-checks the shipped symbols);
 3. no pinned ranges overlap each other or the package scratch block, and nothing in
    HOME/EXROM code references the package scratch block;
 4. every service is EXROM-independent: its call/jump closure never reaches chunk 6
    ($C000-$DFFF) -- packages run with EXROM paged out -- except through the one
    audited wrapper, PKG_NUM_TO_TEXT_SAFE, which pages EXROM in itself;
 5. each package assembles with the ABI file alone (so it cannot name an unlisted HOME
    internal), and every call/jump/memory reference its code makes into HOME ROM or
    the sysvar RAM lands on a service-table slot or a pinned cell;
 6. no package source uses a literal address outside the reserved scratch block.
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
import v2_abi  # noqa: E402

PACKAGES = {
    "mode": "rom/v2_package_mode.asm",
    "sprite": "rom/v2_package_sprite.asm",
    "printer": "rom/v2_package_printer.asm",
    "shapes": "rom/v2_package_shapes.asm",
    "graphics": "rom/v2_package_graphics.asm",
    "cbeep": "rom/v2_package_cbeep.asm",          # MAINT (ClassicBEEP study)
}
# The wrapper that legitimately reaches EXROM (it brackets the call with BANK_PAGE_EXROM_IN/OUT).
WRAPPER = "PKG_NUM_TO_TEXT_SAFE"
WRAPPED = "VM_NUM_TO_TEXT"
# Hardware / always-visible ranges a package may touch without a pin.
HW_RANGES = [(0x4000, 0x5B00, "screen + attributes"), (0x6000, 0x7B00, "second display file")]

errors = []


def fail(msg):
    errors.append(msg)


def syms(path):
    d = {}
    for line in Path(path).read_text().splitlines():
        m = re.match(r"(\S+): EQU 0x([0-9A-Fa-f]+)", line)
        if m:
            d[m.group(1)] = int(m.group(2), 16)
    return d


def load_lst(path):
    ins = {}
    for line in Path(path).read_text(encoding="latin-1").splitlines():
        m = re.match(r"^\s*\d+\+*\s+([0-9A-F]{4})\s+((?:[0-9A-F]{2}\s)+)\s*(.*)$", line + " ")
        if m:
            text = m.group(3).split(";")[0].strip()
            if DATA_RE.match(text):
                continue                                 # data bytes, not an instruction
            ins.setdefault(int(m.group(1), 16), (bytes.fromhex(m.group(2).replace(" ", "")), text))
    return ins


DATA_RE = re.compile(r"^(?:[\w.]+:\s*)?(?:db|dw|defb|defw|ds|defs|dm|defm|byte|word|block|dz)\b", re.I)
COND_JP = {0xC2, 0xCA, 0xD2, 0xDA, 0xE2, 0xEA, 0xF2, 0xFA}
COND_CALL = {0xC4, 0xCC, 0xD4, 0xDC, 0xE4, 0xEC, 0xF4, 0xFC}
MEM_OPS = {0x3A, 0x32, 0x2A, 0x22}          # ld a,(nn) / ld (nn),a / ld hl,(nn) / ld (nn),hl


def decode(addr, ins):
    """(next address or None, control targets, memory references, is_dynamic_jump)."""
    b, _ = ins[addr]
    op, n, nxt = b[0], len(b), addr + len(b)
    if n < 2 and op not in (0xC9, 0xE9) and op & 0xC7 != 0xC7:
        return nxt, [], [], False                       # 1-byte opcode: nothing to follow
    if (op in (0xCD, 0xC3, 0x3A, 0x32, 0x2A, 0x22) or op in COND_JP or op in COND_CALL) and n < 3:
        return nxt, [], [], False
    targets, refs, ft, dyn = [], [], True, False
    if op in (0xDD, 0xFD):
        if n >= 2 and b[1] == 0xE9:
            ft, dyn = False, True
        elif n == 4 and b[1] in (0x2A, 0x22):
            refs.append(b[2] | b[3] << 8)
    elif op == 0xED:
        if n >= 2 and b[1] in (0x4D, 0x45):
            ft = False
        elif n == 4 and b[1] in (0x4B, 0x5B, 0x7B, 0x43, 0x53, 0x73):
            refs.append(b[2] | b[3] << 8)
    elif op == 0xCD or op in COND_CALL:
        targets.append(b[1] | b[2] << 8)
    elif op == 0xC3 or op in COND_JP:
        targets.append(b[1] | b[2] << 8)
        ft = op != 0xC3
    elif op == 0x18:
        targets.append((nxt + ((b[1] ^ 0x80) - 0x80)) & 0xFFFF)
        ft = False
    elif op in (0x20, 0x28, 0x30, 0x38, 0x10):
        targets.append((nxt + ((b[1] ^ 0x80) - 0x80)) & 0xFFFF)
    elif op == 0xC9:
        ft = False
    elif op == 0xE9:
        ft, dyn = False, True
    elif op & 0xC7 == 0xC7:
        targets.append(op & 0x38)
    elif op in MEM_OPS and n == 3:
        refs.append(b[1] | b[2] << 8)
    return (nxt if ft else None), targets, refs, dyn


def closure(entry, ins, stop=()):
    seen, work, bad = set(), [entry], []
    while work:
        a = work.pop()
        if a in seen or a in stop:
            continue
        if a not in ins:
            bad.append(("no listed instruction", a))
            continue
        seen.add(a)
        nxt, targets, refs, dyn = decode(a, ins)
        if dyn:
            bad.append(("indirect jump", a))
        for t in targets:
            if 0xC000 <= t < 0xE000:
                bad.append(("transfers into chunk 6 (EXROM)", a, t))
            elif t < 0x100 and t not in (0,) and not (t == a):
                bad.append(("low-ROM vector", a, t))
            work.append(t)
        for r in refs:
            if 0xC000 <= r < 0xE000:
                bad.append(("data reference into chunk 6", a, r))
        if nxt is not None:
            work.append(nxt)
    return seen, bad


def main():
    os.chdir(ROOT)
    abi = v2_abi.load()
    hsym = syms("build/test_basic.sym")
    home = Path("build/test_basic.bin").read_bytes()
    lst = load_lst("build/test_basic.lst")

    # 1 -- the service table in the shipped HOME image
    h = abi.header
    if list(home[h:h + 4]) != [abi.magic, abi.major, abi.minor, abi.count]:
        fail("service table header %s != magic/major/minor/count %s" %
             (home[h:h + 4].hex(), [abi.magic, abi.major, abi.minor, abi.count]))
    if len(abi.services) != abi.count:
        fail("PKG_SVC_COUNT=%d but PKG_SVC_LIST has %d slots" % (abi.count, len(abi.services)))
    end = abi.slot_addr(len(abi.services))
    if end > abi.max_end:
        fail("service slots end at $%04X, past PKG_SVC_MAX_END $%04X" % (end, abi.max_end))
    if abi.code + 14 > 0x100:
        fail("slot code area overflows the KTAB padding")
    for i, (pkg, homename) in enumerate(abi.services):
        a = abi.slot_addr(i)
        want = hsym.get(homename)
        got = home[a:a + 3]
        if want is None:
            fail("slot %d: HOME routine %s not in build/test_basic.sym" % (i, homename))
        elif got != bytes([0xC3, want & 0xFF, want >> 8]):
            fail("slot %d (%s): bytes %s != jp %s ($%04X)" % (i, pkg, got.hex(), homename, want))
    pad = home[end:abi.code]
    if any(x != 0xFF for x in pad):
        fail("reserved slot area $%04X-$%04X is not blank ($FF)" % (end, abi.code))
    if any(x != 0xFF for x in home[abi.code + 14:0x100]):
        fail("bytes after the slot code up to $0100 are not blank ($FF)")
    w = hsym.get(WRAPPER)
    if w != abi.code:
        fail("%s is at $%04X, expected the slot-code area $%04X" % (WRAPPER, w or 0, abi.code))

    # 2/3 -- pins and constants
    ranges = []
    for name, addr, size in abi.pins:
        if hsym.get(name) != addr:
            fail("pinned cell %s: ABI says $%04X, build has %s" % (name, addr, "$%04X" % hsym[name] if name in hsym else "nothing"))
        ranges.append((addr, addr + size, name))
    for name, value in abi.consts:
        if hsym.get(name) != value:
            fail("pinned constant %s: ABI says $%X, build has %s" % (name, value, hsym.get(name)))
    sb, se = abi.scratch
    ranges.append((sb, se, "PKG_SCRATCH"))
    ranges.sort()
    for (a0, a1, n0), (b0, b1, n1) in zip(ranges, ranges[1:]):
        if b0 < a1:
            fail("pinned ranges overlap: %s [$%04X,$%04X) and %s [$%04X,$%04X)" % (n0, a0, a1, n1, b0, b1))
    for a, (b, src) in lst.items():          # nobody in HOME may use the package scratch block
        for r in decode(a, lst)[2] + decode(a, lst)[1]:
            if sb <= r < se:
                fail("HOME code at $%04X references package scratch $%04X (%s)" % (a, r, src))
    for line in Path("build/exrom.lst").read_text(encoding="latin-1").splitlines():
        m = re.match(r"^\s*\d+\+*\s+([0-9A-F]{4})\s+((?:[0-9A-F]{2}\s)+)\s*(.*)$", line + " ")
        if m and not DATA_RE.match(m.group(3).split(";")[0].strip()):
            b = bytes.fromhex(m.group(2).replace(" ", ""))
            if len(b) == 3 and b[0] in MEM_OPS | {0xCD, 0xC3, 0x21, 0x01, 0x11} and sb <= (b[1] | b[2] << 8) < se:
                fail("EXROM code at $%s references package scratch" % m.group(1))

    # 4 -- EXROM independence of every service
    for i, (pkg, homename) in enumerate(abi.services):
        if homename == WRAPPER:
            seen, bad = closure(hsym[homename], lst, stop={hsym[WRAPPED]})
            code = home[hsym[WRAPPER]:hsym[WRAPPER] + 14]
            exp = (bytes([0xF5, 0xCD]) + hsym["BANK_PAGE_EXROM_IN"].to_bytes(2, "little") + bytes([0xF1, 0xCD])
                   + hsym[WRAPPED].to_bytes(2, "little") + bytes([0xE5, 0xCD])
                   + hsym["BANK_PAGE_EXROM_OUT"].to_bytes(2, "little") + bytes([0xE1, 0xC9]))
            if code != exp:
                fail("%s is not the audited push/IN/pop/call/push/OUT/pop/ret sequence: %s" % (WRAPPER, code.hex()))
            continue
        if homename == WRAPPED:
            fail("%s must be exposed only through %s" % (WRAPPED, WRAPPER))
        seen, bad = closure(hsym[homename], lst)
        for item in bad:
            fail("service %s (%s): %s at $%04X%s" % (pkg, homename, item[0], item[1],
                                                    " -> $%04X" % item[2] if len(item) > 2 else ""))

    # 5/6 -- the packages
    e = abi.env
    consts = dict(abi.consts)
    allowed = [(a, a + size) for _, a, size in abi.pins] + [(sb, se)] + [(x, y) for x, y, _ in HW_RANGES] + [
        (consts["EXTENSION_MODULE_BASE"], consts["EXTENSION_MODULE_LIMIT"]),
        (consts["GFX_FILL_VISITED"], consts["GFX_FILL_STACK_END"]),          # chunk-6 FILL scratch
        (consts["SPRITE_SLOT_IMG_BUF"],
         consts["SPRITE_SLOT_BG_BUF"] + consts["SPRITE_SLOT_MAX"] * consts["SPRITE_SLOT_BYTES"])]
    slots = {abi.slot_addr(i) for i in range(len(abi.services))}
    with tempfile.TemporaryDirectory() as tmp:
        for pkg, src in PACKAGES.items():
            lstf, symf = os.path.join(tmp, pkg + ".lst"), os.path.join(tmp, pkg + ".sym")
            r = subprocess.run(["sjasmplus", "--lst=" + lstf, "--sym=" + symf, src], capture_output=True, text=True)
            if r.returncode != 0 or "error" in r.stdout.lower():
                fail("package %s does not assemble against the ABI file alone:\n%s" % (pkg, r.stdout[-800:]))
                continue
            plst = load_lst(lstf)
            for a in sorted(plst):
                if not (0xF400 <= a < 0xF800):
                    continue
                b, text = plst[a]
                nxt, targets, refs, dyn = decode(a, plst)
                for t in targets:
                    if t < 0xF400 or t >= 0xF800:
                        if t not in slots and t != 0:
                            fail("package %s at $%04X: transfer to $%04X is not a service-table slot (%s)" % (pkg, a, t, text))
                for rf in refs:
                    if not any(lo <= rf < hi for lo, hi in allowed):
                        fail("package %s at $%04X: memory reference $%04X is not a pinned cell/range (%s)" % (pkg, a, rf, text))
        srcs = set()
        for pkg, src in PACKAGES.items():
            srcs.add(src)
            for line in Path(src).read_text().splitlines():
                m = re.match(r'\s*INCLUDE\s+"(rom/[^"]+)"', line)
                if m:
                    srcs.add(m.group(1))
        for src in sorted(srcs):
            for no, line in enumerate(Path(src).read_text().splitlines(), 1):
                code = re.sub(r'"[^"]*"', '""', line.split(";")[0])
                for lit in re.findall(r"\$([0-9A-Fa-f]{4})\b|0x([0-9A-Fa-f]{4})\b", code):
                    v = int((lit[0] or lit[1]), 16)
                    if v >= 0x0100 and not (sb <= v < se):
                        fail("%s:%d: literal address $%04X outside the reserved package scratch block: %s" %
                             (src, no, v, line.strip()))

    if errors:
        print("check_package_abi.py: %d problem(s)" % len(errors))
        for e in errors:
            print("  -", e)
        return 1
    print("check_package_abi.py: ABI %d.%d -- %d service slots, %d pinned cells, %d constants, %d packages: all checks passed."
          % (abi.major, abi.minor, len(abi.services), len(abi.pins), len(abi.consts), len(PACKAGES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

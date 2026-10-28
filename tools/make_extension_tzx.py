#!/usr/bin/env python3
"""Build a stock two-block Direct Recording TZX for a loadable extension.

With --v2 it also warns (6.6, docs/PACKAGE_ABI.md s2 "Names") about each name the package registers
that the language already uses: a keyword or a built-in function (the ROM's word always wins, so the
package's is never reached), a shell command (typed alone as a line, the shell runs it), or a name the
LPRINT/LLIST keywords look up (the package then takes them over from PRINTER). The names are read from
the export table of a package that starts `ld hl,table / jp EXT2_EXPORTS`, otherwise from every
NUL-terminated name-like string in the image (a warning may then be a string that is not a name).
"""

from functools import reduce
from operator import xor
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import v2_abi  # noqa: E402  (R10.9: the ABI version word comes from include/v2_package_abi.inc)

SAMPLE_TSTATES = 80
PILOT_SAMPLES = 27
SYNC_SAMPLES = (8, 9)
ZERO_SAMPLES = 11
ONE_SAMPLES = 22
SILENCE_SAMPLES = 1200
PILOT_PULSES = 3200
MODULE_WINDOW_MAX = 1024  # EXTENSION_MODULE_LIMIT - EXTENSION_MODULE_BASE
                          # ($F800-$F400), enlarged 2026-09-19 for the
                          # combined CIRCLE+FILL module -- keep in sync
                          # with include/sysvars.inc. This is an upper
                          # BOUND on any one module, not a fixed pad-to
                          # size: each module's own actual size is what
                          # goes on tape, so a small extension (CPLOT,
                          # ~132 bytes) doesn't pay to transfer 1024
                          # bytes of padding just because the window
                          # allows a bigger one.


ROOT = Path(__file__).resolve().parent.parent
NAME_RE = re.compile(rb"(?<![A-Za-z0-9$])([A-Z][A-Z0-9]{0,7}\$?)\0")
PRINTER_NAMES = {"LPRINT", "LPRINT$", "LLIST"}          # COMPILE_LPRINT / LLIST look these up by name


def reserved_words() -> dict[str, str]:
    """{word: why a package may not use it}, read from the compiler and shell sources."""
    comp = (ROOT / "rom/exrom_v2_compiler.asm").read_text(encoding="latin-1")
    shell = (ROOT / "rom/exrom_v2_shell.asm").read_text(encoding="latin-1")
    out = {}
    a = comp.index("\nKEYWORD_TABLE:")
    for m in re.finditer(r'db\s+\d+,\s*"([A-Z$]+)",\s*TOK_KW_', comp[a:a + 4000]):
        out[m.group(1)] = "a keyword: the package's name is never reached"
    b = comp.index("\nBUILTIN_FN_TABLE:")
    for m in re.finditer(r'^\s+db\s+\d+,\s*"([A-Z]+)",', comp[b:b + 6000], re.M):
        out.setdefault(m.group(1), "a built-in function: the built-in wins")
    for m in re.finditer(r'^V2_KW_\w+:\s+DB\s+"([A-Z]+)"', shell, re.M):
        out.setdefault(m.group(1), "a shell command: typed alone as a line, the shell runs it")
    for n in PRINTER_NAMES:
        out.setdefault(n, "looked up by LPRINT/LLIST: the package takes them over from PRINTER")
    return out


def package_names(module: bytes, base: int = 0xF400, exports: int = 0x00C6) -> list[str]:
    """The names a package registers: its export table (ABI 2.1), else its name-like strings."""
    if len(module) >= 6 and module[0] == 0x21 and module[3:6] == bytes([0xC3, exports & 0xFF, exports >> 8]):
        i, names = (module[1] | module[2] << 8) - base, []
        while 0 <= i < len(module) and module[i]:
            j = module.index(0, i)
            names.append(module[i:j].decode("latin-1"))
            i = j + 5                                   # the NUL, exec:2, argcount, signature
        return names
    return [m.group(1).decode("latin-1") for m in NAME_RE.finditer(module)]


def warn_names(tape_name: str, module: bytes) -> int:
    words, n = reserved_words(), 0
    for name in package_names(module):
        bare = name.rstrip("$")
        why = words.get(name) or (words.get(bare) if name not in PRINTER_NAMES else None)
        if why and not (tape_name == "PRINTER" and name in PRINTER_NAMES):
            print(f"warning: {tape_name}: the name {name} is {why} (docs/PACKAGE_ABI.md s2 \"Names\")",
                  file=sys.stderr)
            n += 1
    return n


def framed(flag: int, payload: bytes) -> bytes:
    body = bytes([flag]) + payload
    return body + bytes([reduce(xor, body, 0)])


def append_run(bits: list[int], level: int, count: int) -> int:
    bits.extend([level] * count)
    return level ^ 1


def append_block(bits: list[int], block: bytes, level: int) -> int:
    level = append_run(bits, level, SILENCE_SAMPLES)
    for _ in range(PILOT_PULSES):
        level = append_run(bits, level, PILOT_SAMPLES)
    for width in SYNC_SAMPLES:
        level = append_run(bits, level, width)
    for value in block:
        for shift in range(7, -1, -1):
            width = ONE_SAMPLES if value & (1 << shift) else ZERO_SAMPLES
            level = append_run(bits, level, width)
            level = append_run(bits, level, width)
    append_run(bits, level, ZERO_SAMPLES)
    return level


def pack(bits: list[int]) -> tuple[bytes, int]:
    used = len(bits) % 8
    out = bytearray()
    for start in range(0, len(bits), 8):
        value = 0
        for bit in bits[start:start + 8]:
            value = (value << 1) | bit
        value <<= 8 - len(bits[start:start + 8])
        out.append(value)
    return bytes(out), used


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--v2"]
    v2 = len(args) != len(sys.argv) - 1
    if len(args) != 3:
        print("usage: make_extension_tzx.py OUTPUT.tzx NAME MODULE.bin [--v2]\n"
              "  --v2: stamp the V2 package ABI word from include/v2_package_abi.inc "
              "(default: the legacy V1 value 1)", file=sys.stderr)
        return 2
    output, name, module_path = Path(args[0]), args[1], Path(args[2])
    module = module_path.read_bytes()
    if len(module) > MODULE_WINDOW_MAX:
        raise ValueError(f"module is {len(module)} bytes; limit is {MODULE_WINDOW_MAX}")
    module_size = len(module)
    if v2:
        warn_names(name.upper(), module)
    tape_name = name.upper().encode("ascii")[:10].ljust(10, b" ")
    header_payload = (
        bytes([4]) + tape_name + module_size.to_bytes(2, "little")
        + (v2_abi.load().pkg_word if v2 else 1).to_bytes(2, "little") + module_size.to_bytes(2, "little")
    )
    bits: list[int] = []
    level = append_block(bits, framed(0x00, header_payload), 0)
    append_block(bits, framed(0xFF, module), level)
    packed, used = pack(bits)
    raw = bytearray(b"ZXTape!\x1a\x01\x14")
    raw.append(0x15)
    raw += SAMPLE_TSTATES.to_bytes(2, "little")
    raw += (0).to_bytes(2, "little")
    raw.append(used)
    raw += len(packed).to_bytes(3, "little")
    raw += packed
    output.write_bytes(raw)
    print(f"wrote {output}: {len(module)} payload bytes, {len(bits)} samples")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

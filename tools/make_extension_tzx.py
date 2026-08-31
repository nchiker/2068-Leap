#!/usr/bin/env python3
"""Build a stock two-block Direct Recording TZX for a loadable extension."""

from functools import reduce
from operator import xor
from pathlib import Path
import sys

SAMPLE_TSTATES = 80
PILOT_SAMPLES = 27
SYNC_SAMPLES = (8, 9)
ZERO_SAMPLES = 11
ONE_SAMPLES = 22
SILENCE_SAMPLES = 1200
PILOT_PULSES = 3200
MODULE_SIZE = 512


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
    if len(sys.argv) != 4:
        print("usage: make_extension_tzx.py OUTPUT.tzx NAME MODULE.bin", file=sys.stderr)
        return 2
    output, name, module_path = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
    module = module_path.read_bytes()
    if len(module) > MODULE_SIZE:
        raise ValueError(f"module is {len(module)} bytes; limit is {MODULE_SIZE}")
    module = module.ljust(MODULE_SIZE, b"\0")
    tape_name = name.upper().encode("ascii")[:10].ljust(10, b" ")
    header_payload = (
        bytes([4]) + tape_name + MODULE_SIZE.to_bytes(2, "little")
        + (1).to_bytes(2, "little") + MODULE_SIZE.to_bytes(2, "little")
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

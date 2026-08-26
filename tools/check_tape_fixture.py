#!/usr/bin/env python3
"""Decode and validate the confirmed real-Fuse named-LOAD TZX fixture."""

from pathlib import Path
from functools import reduce
from operator import xor
import sys


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIXTURE = ROOT / "export" / "verify"
EXPECTED_PROGRAM = (
    b"\x0b\x00PRINT -123\r"
    b"\x10\x00PRINT str$(456)\r"
    b"\x0d\x00PRINT sqr(2)\r"
)


def sample_runs(data: bytes, used_last: int) -> list[int]:
    bit_count = len(data) * 8
    if used_last:
        bit_count -= 8 - used_last
    bits = [
        (byte >> shift) & 1
        for byte in data
        for shift in range(7, -1, -1)
    ][:bit_count]
    assert bits, "Direct Recording block contains no samples"
    runs: list[int] = []
    previous = bits[0]
    length = 0
    for bit in bits:
        if bit == previous:
            length += 1
        else:
            runs.append(length)
            previous = bit
            length = 1
    runs.append(length)
    return runs


def decode_blocks(runs: list[int]) -> list[bytes]:
    # Fuse records the silent gaps as very long same-level runs. Each
    # non-silent segment is pilot, two sync pulses, encoded byte pairs,
    # and one trailing pulse from the stock sender.
    segments: list[list[int]] = []
    segment: list[int] = []
    for run in runs:
        if run > 100:
            if segment:
                segments.append(segment)
                segment = []
        else:
            segment.append(run)
    if segment:
        segments.append(segment)

    decoded: list[bytes] = []
    for segment in segments:
        pos = 0
        while pos < len(segment) and 24 <= segment[pos] <= 30:
            pos += 1
        assert pos >= 3000, f"pilot too short ({pos} recorded pulses)"
        assert len(segment) >= pos + 2, "missing sync pulses"
        assert all(7 <= width <= 10 for width in segment[pos:pos + 2]), (
            f"invalid sync pulses {segment[pos:pos + 2]}"
        )
        pulses = segment[pos + 2:]
        # The sender's trailing pulse is deliberately not part of a byte.
        pulses = pulses[: len(pulses) // 16 * 16]
        block = bytearray()
        for byte_pos in range(0, len(pulses), 16):
            value = 0
            for bit_pos in range(8):
                pair = pulses[byte_pos + bit_pos * 2:byte_pos + bit_pos * 2 + 2]
                assert abs(pair[0] - pair[1]) <= 2, f"unequal bit pulse pair {pair}"
                average = sum(pair) / 2
                assert 9 <= average <= 12 or 20 <= average <= 23, (
                    f"unrecognized data pulse width {pair}"
                )
                value = (value << 1) | (average >= 16)
            block.append(value)
        decoded.append(bytes(block))
    return decoded


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_FIXTURE
    raw = path.read_bytes()
    assert raw[:8] == b"ZXTape!\x1a", "not a TZX file"
    assert raw[10] == 0x15, "fixture must contain one Direct Recording block"
    sample_tstates = int.from_bytes(raw[11:13], "little")
    used_last = raw[15]
    data_len = int.from_bytes(raw[16:19], "little")
    assert sample_tstates == 80, f"unexpected sample period {sample_tstates} T-states"
    assert len(raw) == 19 + data_len, "unexpected extra or truncated TZX data"

    blocks = decode_blocks(sample_runs(raw[19:], used_last))
    assert len(blocks) == 2, f"expected header and data blocks, found {len(blocks)}"
    header, data = blocks
    assert len(header) == 19 and not header[0], "invalid header block framing"
    assert data[0] == 0xFF, "invalid data block flag"
    assert not header[0] and header[1] == 0, "fixture is not a BASIC program"
    assert header[2:12] == b"verify    ", "named header is not 'verify'"
    payload_len = int.from_bytes(header[12:14], "little")
    assert header[14:16] == b"\x00\x80", "unexpected autostart field"
    assert int.from_bytes(header[16:18], "little") == payload_len
    assert payload_len == len(EXPECTED_PROGRAM)
    assert len(data) == payload_len + 2, "data block length disagrees with header"
    assert data[1:-1] == EXPECTED_PROGRAM, "native program payload changed"
    assert not reduce(xor, header, 0), "header checksum failed"
    assert not reduce(xor, data, 0), "data checksum failed"
    print(
        f"check_tape_fixture.py: {path.name}: verify, "
        f"{payload_len} payload bytes, both checksums valid"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

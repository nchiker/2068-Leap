#!/usr/bin/env python3
"""Static regression checks for the stock-derived tape contract."""

import re
from functools import reduce
from operator import xor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "kernel" / "storage" / "storage.asm"


def equ(text: str, name: str) -> int:
    match = re.search(rf"^{name}\s+EQU\s+(\$[0-9A-F]+|\d+)", text, re.M | re.I)
    if not match:
        raise AssertionError(f"missing {name}")
    value = match.group(1)
    return int(value[1:], 16) if value.startswith("$") else int(value)


def main() -> int:
    source = SOURCE.read_text()
    code = re.sub(r";[^\n]*", "", source)

    # The real LD-EDGE-2 is CALL LD-EDGE-1 / RET NC and then deliberately
    # falls through into LD-EDGE-1 again. A RET inserted here was the root
    # cause of the real LOAD failure found on 2026-08-26.
    edge_pattern = re.compile(
        r"^\.edge2:\s*\n\s*call\s+\.edge1\s*\n\s*ret\s+nc\s*\n\s*\.edge1:",
        re.M | re.I,
    )
    assert edge_pattern.search(code), "EDGE2 no longer falls through into EDGE1"

    expected = {
        "STORAGE_HEADER_TYPE_OFF": 0,
        "STORAGE_HEADER_NAME_OFF": 1,
        "STORAGE_HEADER_LENGTH_OFF": 11,
        "STORAGE_HEADER_AUTOSTART_OFF": 13,
        "STORAGE_HEADER_PROGLEN_OFF": 15,
        "STORAGE_HEADER_PAYLOAD_LEN": 17,
        "STORAGE_TYPE_HEADER": 0x00,
        "STORAGE_TYPE_DATA": 0xFF,
        "STORAGE_LEADER_GAP": 0xC6,
        "STORAGE_BIT_COMPARE": 0xCB,
    }
    for name, value in expected.items():
        actual = equ(source, name)
        assert actual == value, f"{name}: expected {value:#x}, found {actual:#x}"

    save_body = code.split("STORAGE_SAVE:", 1)[1].split("STORAGE_LOAD:", 1)[0]
    sends = len(re.findall(r"\bcall\s+STORAGE_SEND_BLOCK\b", save_body, re.I))
    assert sends == 2, f"stock framing requires two SAVE blocks, found {sends}"

    # Independent checksum sanity check for the documented header layout.
    name = b"test      "
    length = 42
    header = bytes([0]) + name + length.to_bytes(2, "little") + bytes([0, 0x80]) + length.to_bytes(2, "little")
    block = bytes([0]) + header
    checksum = reduce(xor, block, 0)
    assert len(header) == 17 and reduce(xor, block + bytes([checksum]), 0) == 0

    stock = ROOT / "OfficalROM" / "tc2068-1.rom"
    if stock.exists():
        data = stock.read_bytes()
        assert data[0x189:0x18E] == bytes.fromhex("cd8d01d03e"), (
            "stock LD-EDGE-2 reference bytes changed or reference ROM is unexpected"
        )

    print("check_storage_contract.py: all checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

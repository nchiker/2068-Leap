#!/usr/bin/env python3
"""Ensure both ENTER commit paths immediately refresh syntax state."""

import re
from pathlib import Path


source = (Path(__file__).resolve().parent.parent / "basic" / "basic.asm").read_text()


def block(start, end):
    match = re.search(
        rf"^{re.escape(start)}:(.*?)(?=^{re.escape(end)}:)",
        source,
        re.MULTILINE | re.DOTALL,
    )
    if not match:
        raise SystemExit(f"commit validation check: cannot find {start}..{end}")
    return match.group(1)


for name, body in (
    ("append", block(".not_pending_delete", ".commit_existing")),
    ("replace", block(".commit_existing", ".step_down_one")),
):
    store = body.find("call MEM_LINE_STORE")
    validate = body.find("call BASIC_FULL_CHECK_EXROM")
    if store < 0 or validate < 0 or validate < store:
        raise SystemExit(
            f"commit validation check: {name} path must call "
            "BASIC_FULL_CHECK_EXROM after MEM_LINE_STORE"
        )

print("check_commit_validation.py: append and replace paths validated.")

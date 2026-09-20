#!/usr/bin/env python3
"""
tools/run_all_tests_fast.py — run every tests/*.txt fixture via
ts2068-debug's Python API, using the same direct-memory-injection
technique as tools/debug_suite_run.py (see that file's module docstring
for the full "why" -- poke the encoded program into the harness's
PROG_AREA_START/PROG_END at its one-shot INJECT_POINT breakpoint,
now reliable thanks to ts2068-debug's reset_to_known_state() fix).

Speedup over running tools/debug_suite_run.py once per fixture (a fresh
`ts2068-debug` CLI process AND a fresh ZEsarUX launch per fixture,
measured at ~8.5s each, almost entirely ZEsarUX's own process-launch
time): fixtures only need one of FOUR harness ROM variants
(test_suite_inject.bin / test_extension_inject.bin /
test_extension_clear_inject.bin / test_run_state_inject.bin). Group
fixtures by harness variant and only restart ZEsarUX when the variant
changes -- four restarts for the whole suite, not one per fixture.
Confirmed live, repeatedly, that reset_to_known_state() + re-arming the
INJECT_POINT breakpoint + poking fresh program bytes gives a clean,
uncontaminated run every time within one long-lived session (unlike an
earlier, abandoned attempt at reusing one session for the *interactive*
typing-based approach, which did leak state between fixtures -- direct
memory injection through a harness whose own `call BASIC_RUN` reinitializes
runtime state does not have that problem).

Usage:
    python3 tools/run_all_tests_fast.py
"""
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path.home() / "ts2068-debug"))

from debug_suite_run import harness_symbols, expand_symbols, encode_program  # noqa: E402
from ts2068_debug.controller import Ts2068Debug  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
ZESARUX_DIR = Path(os.environ.get(
    "TS2068_DEBUG_ZESARUX_DIR", str(Path.home() / "Applications" / "ZEsarUX-13.0")
))
PORT = int(os.environ.get("TS2068_SUITE_PORT", "10200"))

MAX_INSTRUCTIONS_TO_INJECT_POINT = 2_000_000
MAX_INSTRUCTIONS_AFTER_INJECT = 2_000_000

EXPECTED_CYAN = {
    "ayreg_bad_register", "ayreg_bad_value", "out_bad_value", "err1",
    "snd3", "ulaplus_bad_mode", "ulaplus_bad_index", "ulaplus_bad_value",
}
EXPECTED_RED = {"mem2"}
EXPECTED_BLACK = {
    "ayreg_unloaded", "ayreg_new_clear", "out_unloaded", "out_new_clear",
    "extension_unloaded", "extension_new_clear", "block_unloaded",
    "block_new_clear", "frame_unloaded", "frame_new_clear",
    "invert_unloaded", "invert_new_clear", "print_str_semicolon",
    "hit_unloaded", "hit_new_clear",
}

RAM_EXTENSION_BIN = {
    "gfx6": "build/extensions/cplot_test.bin",
    "ayreg": "build/extensions/ayreg_test.bin",
    "ayreg_bad_register": "build/extensions/ayreg_test.bin",
    "ayreg_bad_value": "build/extensions/ayreg_test.bin",
    "ayreg_new_clear": "build/extensions/ayreg_clear_test.bin",
    "out": "build/extensions/out_test.bin",
    "out_bad_value": "build/extensions/out_test.bin",
    "out_new_clear": "build/extensions/out_clear_test.bin",
    "block": "build/extensions/block_test.bin",
    "block_new_clear": "build/extensions/block_clear_test.bin",
    "frame": "build/extensions/frame_test.bin",
    "frame_over": "build/extensions/frame_test.bin",
    "frame_new_clear": "build/extensions/frame_clear_test.bin",
    "invert": "build/extensions/invert_test.bin",
    "invert_new_clear": "build/extensions/invert_clear_test.bin",
    "extension_register": "build/extensions/cplot_test.bin",
    "extension_new_clear": "build/extensions/cplot_clear_test.bin",
    "hit": "build/extensions/sprite_test.bin",
    "hit_new_clear": "build/extensions/sprite_clear_test.bin",
}
RAM_EXTENSION_CLEAR = {
    "ayreg_new_clear", "out_new_clear", "block_new_clear",
    "frame_new_clear", "invert_new_clear", "extension_new_clear",
    "hit_new_clear",
}
RAM_EXTENSION_SEED_CACHE = {"extension_register"}
RUN_STATE_TEST = {"run_state"}


def harness_for(name):
    if name in RUN_STATE_TEST:
        return "test_run_state_inject.bin", "rom/test_run_state_inject.sym"
    if name in RAM_EXTENSION_BIN:
        if name in RAM_EXTENSION_CLEAR:
            return "test_extension_clear_inject.bin", "rom/test_extension_clear_inject.sym"
        return "test_extension_inject.bin", "rom/test_extension_inject.sym"
    return "test_suite_inject.bin", "rom/test_suite_inject.sym"


def reset_border(dbg, scratch_addr):
    """Deterministically resets the ULA border latch (port 254) to 7,
    matching this harness's own true idle default -- see run_one()'s own
    comment for why this is needed (BORDER is hardware I/O state, not
    something reset_to_known_state()'s CPU-register reset touches).
    Pushes a return address, jumps into a short straight-line
    (LD A,7 / OUT (254),A / RET) snippet already poked at scratch_addr,
    and confirms it returned to exactly where it was called from -- no
    resync needed, unlike the interactive-ROM extension-registration
    case, since this snippet never branches."""
    pc = dbg.get_registers().values["PC"]
    sp = dbg.get_registers().values["SP"]
    new_sp = (sp - 2) & 0xFFFF
    dbg.write_memory(new_sp, bytes([pc & 0xFF, (pc >> 8) & 0xFF]))
    dbg.set_register("SP", new_sp)
    dbg.set_register("PC", scratch_addr)
    # A bounded run() is the wrong tool here, at any instruction count:
    # confirmed live, once RET returns to pc (PC=0, the reset vector --
    # real executable ROM, not a stopping point), execution just keeps
    # going into subsequent real boot code for however many instructions
    # remain in the budget, landing deep inside MEM_INIT well before this
    # function's own PC check runs -- true at both 200 and 10 instructions.
    # The snippet is exactly 3 opcodes (LD A,7 / OUT (254),A / RET);
    # single-step it precisely instead, stopping the instant PC returns.
    for _ in range(10):
        dbg.step()
        if dbg.get_registers().values["PC"] == pc:
            break
    else:
        raise RuntimeError(
            f"reset_border: did not return to 0x{pc:04x} within 10 steps"
        )


def run_one(dbg, syms, name):
    src = REPO_ROOT / "tests" / f"{name}.txt"
    lines = [l.rstrip("\n") for l in src.read_text().splitlines()]
    lines = [l for l in lines if l.strip() and not l.strip().startswith(";;")]
    lines = [expand_symbols(l, syms) for l in lines]
    data = encode_program(lines)

    prog_area_start = syms["PROG_AREA_START"]
    prog_end_addr = syms["PROG_END"]
    prog_end_value = prog_area_start + len(data)

    dbg.reset_to_known_state()
    # BORDER is a ULA hardware I/O latch (port 254), not a CPU register --
    # reset_to_known_state() resets PC/SP/AF/etc but does NOT touch it.
    # Confirmed live: running two fixtures in the same session back to
    # back, where the first deliberately halts with a non-default border
    # (e.g. err1's own "BORDER 5" before its runtime error), the SECOND
    # fixture inherits that stale border if its own program never touches
    # it either (exactly the case for every "checker correctly rejected
    # this unregistered keyword" fixture, which never runs any real
    # statement at all). Reset it explicitly and deterministically by
    # running a tiny inline snippet (LD A,7 / OUT (254),A / RET) via
    # emulate_call, at PROG_AREA_START -- safe scratch space here since
    # the real program bytes overwrite it moments later anyway.
    dbg.write_memory(prog_area_start, bytes([0x3E, 0x07, 0xD3, 0xFE, 0xC9]))
    reset_border(dbg, prog_area_start)

    dbg.set_breakpoint(1, "INJECT_POINT")
    dbg.run(max_instructions=MAX_INSTRUCTIONS_TO_INJECT_POINT)
    # Must clear the breakpoint before resuming execution past it -- PC is
    # sitting exactly on the armed "PC=010CH" condition right now, and for
    # some fixtures (confirmed live: extension_unloaded, frame_unloaded)
    # execution legitimately revisits that exact address again during
    # BASIC_RUN, re-triggering the still-armed breakpoint and executing
    # nothing further. run_until()'s own implementation already clears
    # its breakpoint after use; this hand-rolled break+run sequence must
    # too.
    dbg.clear_breakpoint(1)

    dbg.write_memory(prog_area_start, data)
    dbg.write_memory(prog_end_addr, bytes([prog_end_value & 0xFF, (prog_end_value >> 8) & 0xFF]))

    if name in RAM_EXTENSION_BIN:
        module = (REPO_ROOT / RAM_EXTENSION_BIN[name]).read_bytes()
        module_base = syms["EXTENSION_MODULE_BASE"]
        module_limit = syms["EXTENSION_MODULE_LIMIT"]
        if module_base + len(module) > module_limit:
            raise ValueError(f"{name}: RAM extension exceeds reserved module window")
        dbg.write_memory(module_base, module)
        if name in RAM_EXTENSION_SEED_CACHE:
            dbg.write_memory(syms["STATUS_CHECK_VALID"], bytes([1]))

    dbg.run(max_instructions=MAX_INSTRUCTIONS_AFTER_INJECT)
    return dbg.timex_state().get("border")


def verdict_for(name, border):
    if border == 4:
        return "PASS"
    if border == 5 and name in EXPECTED_CYAN:
        return "PASS (expected cyan)"
    if border == 2 and name in EXPECTED_RED:
        return "PASS (expected pre-run rejection)"
    if border == 7 and name in EXPECTED_BLACK:
        return "PASS (expected unloaded rejection)"
    return "FAIL"


def main():
    subprocess.run(
        ["make", "cplot-extension", "block-extension", "frame-extension",
         "invert-extension", "ayreg-extension", "out-extension",
         "sprite-extension"],
        cwd=REPO_ROOT, check=True, capture_output=True,
    )

    fixtures = sorted(p.stem for p in (REPO_ROOT / "tests").glob("*.txt"))
    groups = {}
    for name in fixtures:
        groups.setdefault(harness_for(name), []).append(name)

    passed, failed = 0, 0
    failed_names = []
    t_start = time.monotonic()

    for (home_rom, sym_rel), names in groups.items():
        syms = harness_symbols(REPO_ROOT / sym_rel)
        combined = REPO_ROOT / "build" / f"suite_fast_{home_rom}"
        combined.write_bytes(
            (REPO_ROOT / home_rom).read_bytes() + (REPO_ROOT / "exrom.bin").read_bytes()
        )
        dbg = Ts2068Debug(str(ZESARUX_DIR), port=PORT, romfile=str(combined))
        dbg.start()
        try:
            dbg.load_symbols(str(REPO_ROOT / sym_rel))
            for name in names:
                try:
                    border = run_one(dbg, syms, name)
                except Exception as exc:  # noqa: BLE001
                    print(f"{name}: EXCEPTION {exc!r} -> FAIL", flush=True)
                    failed += 1
                    failed_names.append(name)
                    continue
                verdict = verdict_for(name, border)
                print(f"{name}: border={border} -> {verdict}", flush=True)
                if verdict.startswith("PASS"):
                    passed += 1
                else:
                    failed += 1
                    failed_names.append(name)
        finally:
            dbg.stop()
            combined.unlink(missing_ok=True)

    elapsed = time.monotonic() - t_start
    n = max(1, len(fixtures))
    print("-" * 40)
    print(f"PASS: {passed}  FAIL: {failed}  "
          f"({elapsed:.1f}s total, {elapsed/n:.2f}s/fixture, "
          f"{len(groups)} ZEsarUX restarts for {n} fixtures)")
    if failed:
        print(f"Failed: {' '.join(failed_names)}")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

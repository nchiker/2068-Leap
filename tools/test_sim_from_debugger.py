#!/usr/bin/env python3
"""sim_from_debugger: a ts2068-debug register/memory capture becomes a replayable z80sim state."""
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "z80sim"))

import sim_from_debugger as sfd  # noqa: E402
from snapshot import restore_state  # noqa: E402
from replay_snapshot import main as replay_main  # noqa: E402
from extract_routine import extract  # noqa: E402

REGS = {"PC": 0x0CDB, "SP": 0xFF00, "AF": 0x00C5, "BC": 0x002D, "DE": 0x007B, "HL": 0, "IX": 0x1234,
        "IY": 0x5C3A, "AF'": 0x1042}


class SimFromDebuggerTests(unittest.TestCase):
    def test_registers_and_flags_are_split_correctly(self):
        state = sfd.build_state(REGS, [(0xF100, b"\x01\x02")], "ROUTINE", None)
        sim, entry, ranges = restore_state(state)
        self.assertEqual((sim.regs["B"], sim.regs["C"], sim.regs["D"], sim.regs["E"]), (0, 45, 0, 123))
        self.assertEqual((sim.regs["IX"], sim.regs["IY"], sim.regs["SP"]), (0x1234, 0x5C3A, 0xFF00 - 2))  # the HALT sentinel push
        # F = 0xC5 = S Z . . . PV . C
        self.assertEqual({k: sim.flags[k] for k in "SZHNC"} | {"PV": sim.flags["PV"]},
                         {"S": 1, "Z": 1, "H": 0, "N": 0, "C": 1, "PV": 1})
        self.assertEqual((sim.alt_a, sim.alt_flags["H"], sim.alt_flags["C"]), (0x10, 0, 0))
        self.assertEqual(sim.alt_flags["Z"], 1)
        self.assertEqual(sim.mem[0xF100:0xF102], b"\x01\x02")
        self.assertEqual(entry, ("ROUTINE", None))

    def test_missing_registers_are_reported(self):
        with self.assertRaisesRegex(ValueError, "missing"):
            sfd.build_state({"PC": 1}, [], "R", None)

    def test_ranges_accept_numbers_and_reject_malformed_or_unknown(self):
        self.assertEqual(sfd.parse_range("0xF100:64"), (0xF100, 64))
        with self.assertRaises(ValueError):
            sfd.parse_range("0xF100")
        with self.assertRaises(ValueError):
            sfd.parse_range("NOSUCH:4")

    def test_captured_state_replays_in_the_simulator(self):
        # A real V2 routine from the current source, seeded from "debugger" registers.
        with tempfile.TemporaryDirectory() as tmp:
            routine = os.path.join(tmp, "umul.asm")
            case = os.path.join(tmp, "case.json")
            result = os.path.join(tmp, "result.json")
            src = os.path.join(HERE, "..", "kernel", "math", "math.asm")
            with open(routine, "w") as fh:
                fh.write("\n".join(extract(src, "MATH_UMUL16", "MATH_UDIV16", with_locations=True)) + "\n")
            regs = dict(REGS, DE=123, BC=45, AF=0)
            with open(case, "w") as fh:
                json.dump(sfd.build_state(regs, [], "MATH_UMUL16", None), fh)
            with redirect_stdout(io.StringIO()):
                status = replay_main([routine, case, "-o", result])
            out = json.load(open(result))
        self.assertEqual(status, 0)
        self.assertEqual(out["outcome"], "returned")
        r = out["final_state"]["cpu"]["regs"]
        self.assertEqual(r["H"] * 256 + r["L"], 123 * 45)
        self.assertEqual(out["trace"][0]["source"]["source"]["path"].replace("\\", "/").split("/")[-1], "math.asm")


if __name__ == "__main__":
    unittest.main()

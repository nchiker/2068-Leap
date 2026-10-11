#!/usr/bin/env python3
"""STUDY: an unterminated FOR reports its OWN line (error 65), nested and with continuation lines."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v2_prod import *
import v2_prod as P

def lc(cid, prog, want_line, want_code=65):
    @case(cid, "unterminated FOR -> cursor on the FOR")
    def fn():
        ce, ve, msg = P.run_program(prog)
        idx = P.cur_index()
        return ce == want_code and idx == want_line, "compile_err=%d (want %d) cursor_line=%d (want %d)" % (ce, want_code, idx, want_line)

lc("eof-for-simple", ["FOR i = 1 TO 3", "x = i"], 0)
lc("eof-for-later", ["a = 1", "b = 2", "FOR i = 1 TO 3", "x = i", "y = 2"], 2)
lc("eof-for-nested-inner-closed", ["x = 1", "FOR i = 1 TO 3", "FOR j = 1 TO 2", "NEXT j", "y = 1"], 1)
lc("eof-for-nested-outer-closed", ["FOR i = 1 TO 3", "x = 1", "FOR j = 1 TO 2", "NEXT j", "NEXT i", "FOR k = 1 TO 2", "z = 3"], 5)
lc("eof-for-continuation", ["a = 1:", "b = 2:", "FOR i = 1 TO 3", "x = i"], 2)
if __name__ == "__main__":
    sys.exit(run_cases(sys.argv[1:] or None, "study-eof-for"))

#!/usr/bin/env python3
"""STUDY: multi-item PRINT (; and ,), bare PRINT, trailing separator, INPUT "prompt"; v -- through the real stack.
The text actually drawn is read back from the screen RAM glyph cells and decoded with the ROM's own font."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from study_util import *

# --- screen text reader: the ROM's own font, rendered by the real GFX_PUTCHAR (one Z80 driver loop), then
# matched against the bitmap of the program's output (one bulk read of screen RAM).
import subprocess, tempfile

def cell_from(scr, row, col):
    y0 = row * 8
    base = (((y0 & 0xC0) << 5) | ((y0 & 0x38) << 2) | col)
    return bytes(scr[base + 0x100 * k] for k in range(8))

def glyph_table():
    d = tempfile.mkdtemp(prefix="glyph-")
    src = ["    DEVICE ZXSPECTRUM48", "    ORG $F400", "    ld d,32", "    ld b,0", "    ld c,0", "loop:", "    push de", "    push bc", "    ld a,d",
           "    call $%04X" % HSYM["GFX_PUTCHAR"], "    pop bc", "    pop de", "    inc d", "    inc c", "    ld a,c", "    cp 32", "    jr nz,nx", "    ld c,0", "    inc b",
           "nx: ld a,d", "    cp 127", "    jr nz,loop", "done: jr done", '    SAVEBIN "%s/g.bin", $F400, $-$F400' % d]
    open(d + "/g.asm", "w").write("\n".join(src) + "\n")
    r = subprocess.run(["sjasmplus", "--sym=" + d + "/g.sym", d + "/g.asm"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    done = [int(l.split()[2], 16) for l in open(d + "/g.sym") if l.startswith("done:")][0]
    P.poke(0xF400, open(d + "/g.bin", "rb").read())
    D("mem-write", "0xFF00", struct.pack("<H", done).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", "0xF400")
    assert P.run_to(done, 5_000_000)
    scr = read(0x4000, 6144)
    table = {}
    for i, ch in enumerate(range(32, 127)):
        table.setdefault(cell_from(scr, i // 32, i % 32), chr(ch))
    D("mem-write", "0x4000", bytes(6144).hex())
    return table

def row_text(table, row, scr=None):
    scr = scr if scr is not None else read(0x4000, 6144)
    out = ""
    for col in range(32):
        cell = cell_from(scr, row, col)
        out += table.get(cell, "#" if any(cell) else " ")
    return out.rstrip()

def run_lines(lines, keys=None):
    P.boot()
    table = glyph_table()
    D("mem-write", "0x4000", bytes(6144).hex())       # blank bitmap
    P.put_store(lines)
    out, ce, ve = capture_run("V2_RUN_STORED") if not keys else (None, None, None)
    return table, ce, ve

def main():
    P.boot()
    table = glyph_table()
    bad = 0
    def case(name, lines, want_rows, ce_want=0):
        nonlocal bad
        P.boot()
        P.put_store(lines)
        D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
        D("set-register", "SP", "0xFF00")
        D("set-register", "PC", hex(P.sym("V2_RUN_STORED")))
        P.to_prompt(60_000_000)
        ce = read(P.sym("COMPILE_ERROR_CODE"), 1)[0]
        ve = read(P.sym("VM_ERROR_CODE"), 1)[0]
        scr = read(0x4000, 6144)
        rows = [row_text(table, r, scr) for r in range(len(want_rows))]
        ok = (ce == ce_want) and (ve == 0 or ce_want) and (ce_want != 0 or rows == want_rows)
        bad += not ok
        print("%-5s %-34s ce=%d ve=%d rows=%s%s" % ("PASS" if ok else "FAIL", name, ce, ve, rows, "" if ok else "   WANT %s" % want_rows), flush=True)
    case("single string", ['PRINT "hello"'], ["hello"])
    case("single number", ["PRINT 42"], ["42"])
    case("semicolon list", ['PRINT "a"; 1; "b"; 2'], ["a1b2"])
    case("comma zones", ['PRINT "ab", "cd", "ef"'], ["ab              cd", "ef"])
    case("trailing semicolon", ['PRINT "x";', 'PRINT "y"'], ["xy"])
    case("bare PRINT = blank line", ['PRINT "a"', "PRINT", 'PRINT "b"'], ["a", "", "b"])
    case("number expressions", ["a = 3", 'PRINT a; "+"; a * 2; "="; a + a * 2'], ["3+6=9"])
    case("string var + concat", ['s$ = "hi"', 'PRINT s$ + "!"; 7'], ["hi!7"])
    case("mixed separators", ['PRINT 1; 2, 3'], ["12              3"])
    case("PRINT in IF/ELSE block", ["a = 1", "IF a = 1 THEN", 'PRINT "yes";', 'PRINT "!"', "ELSE", 'PRINT "no"', "ENDIF"], ["yes!"])
    case("error: junk after item", ['PRINT 1 2'], [""], ce_want=64)
    case("error: INPUT prompt w/o separator", ['INPUT "x" a'], [""], ce_want=22)
    # INPUT prompt: run the program, answer "7" on the key latch, check variable and screen
    P.boot()
    P.put_store(['INPUT "N? "; a', 'PRINT "got "; a'])
    D("mem-write", "0xFF00", struct.pack("<H", RET).hex())
    D("set-register", "SP", "0xFF00")
    D("set-register", "PC", hex(P.sym("V2_RUN_STORED")))
    D("run", "--max-instructions", "30000000"); D("pause")         # reaches INPUT's key wait
    for ch in "7":
        P.poke(P.sym("KBD_LASTK"), ord(ch)); P.poke(P.sym("KBD_KEYHIT"), 1)
        D("run", "--max-instructions", "2000000"); D("pause")
    P.poke(P.sym("KBD_LASTK"), 13); P.poke(P.sym("KBD_KEYHIT"), 1)
    D("run", "--max-instructions", "40000000"); D("pause")           # ENTER ends INPUT; the rest of the program runs
    scr = read(0x4000, 6144)
    rows = [row_text(table, r, scr) for r in range(2)]
    ve = read(P.sym("VM_ERROR_CODE"), 1)[0]
    a = P.variables(1)[0][1]
    ok = rows == ["N? 7", "got 7"] and a == 7 and ve == 0
    bad += not ok
    print("%-5s %-34s rows=%s a=%d ve=%d" % ("PASS" if ok else "FAIL", 'INPUT "N? "; a', rows, a, ve))
    D("stop")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())

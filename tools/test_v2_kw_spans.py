#!/usr/bin/env python3
# R10.7 keyword-rendering span test: calls V2_KW_DETECT_SPANS in the real production ROM (run from repo root after make build,
# with a ts2068-debug session already started: ts2068-debug start --rom build/ts2068rom_zesarux.bin --symbols build/exrom.sym).
import subprocess, json, sys
def D(*a):
    r=subprocess.run(["ts2068-debug","--json",*a],capture_output=True,text=True,timeout=300)
    return json.loads(r.stdout) if r.stdout.strip().startswith("{") else r.stdout
sym={}
for l in open("build/exrom.sym"):
    p=l.split()
    if len(p)>=3 and p[1]=="EQU": sym[p[0].rstrip(":")]=int(p[2],16)
D("pause"); D("reset"); D("run","--until","V2_COMMAND_LOOP.loop","--max-instructions","80000000")
cases=[
 ('for i = 1 to 20',['for','to']),
 ('Print i',['Print']),
 ('next i',['next']),
 ('if a then print "x" else print "y"',['if','then','print','else','print']),
 ('endif',['endif']),
 ('dim a(5)',['dim']),
 ('proc foo',['proc']),
 ('call foo',['call']),
 ('def fn f(x) = x',['def','fn']),
 ('for i=1 to 9 step 2',['for','to','step']),
 ('PRINT "FOR SALE"; "a""b" ',['PRINT']),
 ('print To1',['print']),
 ('print To$',['print']),
 ('print x1for',['print']),
 ('print forx',['print']),
 ('print fo',['print']),
 ('rem for next "print',['rem']),
 ('x = 1: Print x',['Print']),
 ('print "unterminated for',['print']),
 ('goto 10',['goto']),
 ('exit',['exit']),
 ('randomise',['randomise']),
]
bad=0
for line,exp in cases:
    D("mem-write",hex(0xF2A8),line.encode().hex()+"00")
    ret=sym["V2_COMMAND_LOOP.loop"]
    D("mem-write","0xFF00",bytes([ret&255,ret>>8]).hex())
    D("set-register","SP","0xFF00"); D("set-register","HL",hex(0xF2A8)); D("set-register","PC",hex(sym["V2_KW_DETECT_SPANS"]))
    D("run","--until","V2_COMMAND_LOOP.loop","--max-instructions","2000000")
    n=D("mem",hex(sym["KW_SPAN_COUNT"]),"17")["hex"]; b=bytes.fromhex(n)
    spans=[(b[1+2*i],b[2+2*i]) for i in range(b[0])]
    got=[line[s:s+l] for s,l in spans]
    ok=got==exp
    bad+=not ok
    print("OK " if ok else "BAD",repr(line),got)
print("failures",bad)

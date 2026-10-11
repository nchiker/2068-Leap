#!/usr/bin/env python3
"""Cost breakdown for the D11 error variant: revert one component at a time on a scratch copy and measure."""
import os, re, shutil, subprocess, sys
SRC = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/2068-Leap-study/d11-error")
TMP = os.path.expandvars("$CLAUDE_JOB_DIR/tmp/abl")

def prep():
    subprocess.run(["rsync", "-a", "--delete", "--exclude", ".git", "--exclude", "build", SRC + "/", TMP + "/"], check=True)
    os.makedirs(TMP + "/build", exist_ok=True)

def rd(p): return open(os.path.join(TMP, p)).read()
def wr(p, s): open(os.path.join(TMP, p), "w").write(s)

def measure(label):
    r = subprocess.run(["make", "budget"], cwd=TMP, capture_output=True, text=True)
    m = re.findall(r"^(Home ROM|EXROM):.*?(\d+) bytes free", r.stdout, re.M)
    d = dict(m)
    print("%-34s HOME free %s  EXROM free %s" % (label, d.get("Home ROM"), d.get("EXROM")), flush=True)
    if "rror" in r.stdout and "Errors: 0" not in r.stdout: print(r.stdout[-400:])

def revert(comp):
    v = rd("rom/exrom_v2_vm_core.asm")
    if comp in ("add", "all"):
        v = v.replace("        or a\n        adc hl,de               ; STUDY (D11): ADC sets P/V = signed overflow\n        jp pe,VM_ERR_OVERFLOW\n", "        add hl,de\n")
    if comp in ("sub", "all"):
        v = v.replace("        jp pe,VM_ERR_OVERFLOW   ; STUDY (D11)\n", "")
    if comp in ("mul", "all"):
        v = v.replace("        call VM_MUL_CHECKED     ; STUDY (D11): MATH_MULTIPLY16 with overflow detection\n        jp c,VM_ERR_OVERFLOW\n        jp PUSH_INT_CONTINUE\n", "        call MATH_MULTIPLY16\n")
        a = v.index("; STUDY (D11): signed 16x16 multiply with overflow detection")
        b = v.index("VM_ERR_COMMON:\n        ld (VM_ERROR_CODE),a")
        v = v[:a] + v[b:]
    if comp in ("for", "all"):
        v = v.replace("        or a\n        adc hl,de                ; HL = new current value (R8.5 Group 5 --\n                                   ; was a fixed `inc de`/STEP=1 before)\n        jp pe,.past_limit        ; STUDY (D11): the counter would wrap -> the loop is over\n", "        add hl,de\n")
    if comp in ("err", "all"):
        v = v.replace("; STUDY (D11): integer overflow is a clean runtime error 67 (NUMERIC OVERFLOW), never a silent wrap.\nVM_ERR_OVERFLOW:\n        ld a,67\n        jr VM_ERR_COMMON\n\n", "")
    wr("rom/exrom_v2_vm_core.asm", v)
    if comp in ("msg", "all"):
        s = rd("rom/exrom_v2_shell.asm")
        s = s.replace("    ld hl,V2_MSG_OVERFLOW        ; STUDY (D11)\n    cp 67\n    ret z\n", "")
        s = s.replace('\nV2_MSG_OVERFLOW: DB "NUMERIC OVERFLOW",0', "")
        wr("rom/exrom_v2_shell.asm", s)
    if comp in ("lex", "all"):
        c = rd("rom/exrom_v2_compiler.asm")
        base = subprocess.run(["git", "-C", SRC, "show", "7ae0599:rom/exrom_v2_compiler.asm"], capture_output=True, text=True).stdout
        wr("rom/exrom_v2_compiler.asm", base)

if len(sys.argv) > 2 and sys.argv[2] == "promote":
    prep(); revert("lex"); revert("msg"); revert("err"); measure("promote arithmetic+display only")
    prep(); revert("lex"); revert("msg"); revert("err")
    f = rd("rom/exrom_format.asm")
    base = subprocess.run(["git", "-C", SRC, "show", "7ae0599:rom/exrom_format.asm"], capture_output=True, text=True).stdout
    wr("rom/exrom_format.asm", base); measure("promote arithmetic, NO big display")
    sys.exit(0)
prep(); measure("d11-error (all components)")
for comp in ("add", "sub", "mul", "for", "lex", "msg"):
    prep()
    revert(comp)
    measure("  without %s" % comp)
prep(); revert("all"); measure("  all reverted (= baseline?)")

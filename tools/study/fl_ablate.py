import os, re, subprocess
SRC = os.path.expanduser("~/2068-Leap-study/flicker-i2"); TMP = os.path.expandvars("$CLAUDE_JOB_DIR/tmp/abl3")
def prep():
    subprocess.run(["rsync","-a","--delete","--exclude",".git","--exclude","build",SRC+"/",TMP+"/"],check=True); os.makedirs(TMP+"/build",exist_ok=True)
def measure(label):
    r=subprocess.run(["make","budget"],cwd=TMP,capture_output=True,text=True)
    d=dict(re.findall(r"^(Home ROM|EXROM):.*?(\d+) bytes free",r.stdout,re.M))
    print("%-34s HOME free %s EXROM free %s"%(label,d.get("Home ROM"),d.get("EXROM")),flush=True)
    if "Errors: 0" not in r.stdout: print(r.stdout[-300:])
prep(); measure("I1+I2 (refactored)")
prep()
p=TMP+"/rom/exrom_v2_shell.asm"; s=open(p).read()
a=s.index("; UP/DOWN.  (a) same record"); b=s.index("; V2_DRAW_STATUS -- R10 addition.")
s=s[:a]+s[b:]
s=s.replace("    dec b\n    jr nz,.nav\n    call V2_REDRAW_ACTIVE\n    ret nc                       ; done, carry clear\n    jr .full\n.nav:\n    call V2_REDRAW_NAV\n    ret nc\n.full:","    call V2_REDRAW_ACTIVE\n    ret nc\n.full:")
open(p,"w").write(s)
p=TMP+"/rom/exrom_editor.asm"; s=open(p).read()
s=s.replace("    ld   b, 2\n    ld   hl, V2_REDRAW_SCOPE\n    ld   (hl), b ","    ld   b, 2\n    ld   hl, V2_RD_NEWH\n    ld   (hl), b ")
open(p,"w").write(s)
measure("I1 only (refactored shared helpers)")

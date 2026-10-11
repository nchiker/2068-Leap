import os, re, subprocess, sys
SRC = os.path.expanduser("~/2068-Leap-study/lang-hw")
TMP = os.path.expandvars("$CLAUDE_JOB_DIR/tmp/abl2")
def prep():
    subprocess.run(["rsync","-a","--delete","--exclude",".git","--exclude","build",SRC+"/",TMP+"/"],check=True); os.makedirs(TMP+"/build",exist_ok=True)
def rd(p): return open(os.path.join(TMP,p)).read()
def wr(p,s): open(os.path.join(TMP,p),"w").write(s)
def measure(label):
    r=subprocess.run(["make","budget"],cwd=TMP,capture_output=True,text=True)
    d=dict(re.findall(r"^(Home ROM|EXROM):.*?(\d+) bytes free",r.stdout,re.M))
    print("%-30s HOME free %s EXROM free %s"%(label,d.get("Home ROM"),d.get("EXROM")),flush=True)
    if "Errors: 0" not in r.stdout: print(r.stdout[-300:])
def drop(name):
    v=rd("rom/exrom_v2_vm_core.asm"); c=rd("rom/exrom_v2_compiler.asm"); d=rd("rom/exrom_v2_decompiler.asm")
    if name=="IN":
        c=c.replace('    db 2, "IN", 1, 30, 0          ; STUDY: IN(port), full 16-bit port address\n',''); 
        v=v.replace("        dw BUILTIN_FN_IN        ; fn_index 30 (STUDY)\n","")
        a=v.index("; STUDY: IN(port)"); b=v.index("; STUDY: STICK(n)"); v=v[:a]+v[b:]
    if name=="STICK":
        c=c.replace('    db 5, "STICK", 1, 31, 0       ; STUDY: STICK(1|2), Timex joystick via AY port A\n','')
        v=v.replace("        dw BUILTIN_FN_STICK     ; fn_index 31 (STUDY)\n","")
        a=v.index("; STUDY: STICK(n)"); b=v.index("; STUDY: OUT port,value"); v=v[:a]+v[b:]
    if name=="OUT":
        c=c.replace('        db 3, "OUT", TOK_KW_OUT     ; STUDY\n','').replace("KEYWORD_TABLE_COUNT: equ 44","KEYWORD_TABLE_COUNT: equ 43")
        c=c.replace("        cp TOK_KW_OUT\n        jp z,.out\n","").replace(".out:\n        call COMPILE_OUT\n        jp .after_stmt\n","")
        a=c.index("; STUDY: OUT <port>,<value>."); b=c.index("; COMPILE_BEEP — BEEP <duration>"); c=c[:a]+c[b:]
        c=c.replace("EMIT_OP_OUT:                  ld a,67 : jp EMIT_BYTE  ; STUDY\n","")
        v=v.replace("        dw OP_OUT                                           ; 67  STUDY\n","").replace("        cp 68                   ; STUDY: 68 opcodes defined (OUT = 67)","        cp 67")
        a=v.index("; STUDY: OUT port,value"); b=v.index("VM_CALL_USR_TRAMPOLINE:\n        jp (hl)"); v=v[:a]+v[b:]
    # table count
    n=32-(name in ("IN","STICK"))
    c=c.replace("BUILTIN_FN_TABLE_COUNT: equ 32","BUILTIN_FN_TABLE_COUNT: equ %d"%n)
    wr("rom/exrom_v2_vm_core.asm",v); wr("rom/exrom_v2_compiler.asm",c)
prep(); measure("all three")
for n in ("OUT","IN","STICK"):
    prep(); drop(n); measure("without "+n)

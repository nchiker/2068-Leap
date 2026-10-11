import os, re, subprocess
SRC = os.path.expanduser("~/2068-Leap-study/lang-print"); TMP = os.path.expandvars("$CLAUDE_JOB_DIR/tmp/abl4")
def prep():
    subprocess.run(["rsync","-a","--delete","--exclude",".git","--exclude","build",SRC+"/",TMP+"/"],check=True); os.makedirs(TMP+"/build",exist_ok=True)
def rd(p): return open(os.path.join(TMP,p)).read()
def wr(p,s): open(os.path.join(TMP,p),"w").write(s)
def measure(label):
    r=subprocess.run(["make","budget"],cwd=TMP,capture_output=True,text=True)
    d=dict(re.findall(r"^(Home ROM|EXROM):.*?(\d+) bytes free",r.stdout,re.M))
    print("%-44s HOME free %s"%(label,d.get("Home ROM")),flush=True)
    if "Errors: 0" not in r.stdout: print(r.stdout[-400:])
prep(); measure("full (multi-item+bare+comma+INPUT prompt)")
# 1 no INPUT prompt
prep(); c=rd("rom/exrom_v2_compiler.asm")
a=c.index("        cp TOK_STRING             ; STUDY: INPUT \"prompt\"")
b=c.index(".no_prompt:\n")+len(".no_prompt:\n")
c=c[:a]+c[b:]; wr("rom/exrom_v2_compiler.asm",c); measure("without INPUT prompt")
# 2 no comma
prep(); c=rd("rom/exrom_v2_compiler.asm"); v=rd("rom/exrom_v2_vm_core.asm")
c=c.replace("        cp TOK_COMMA\n        jr z,.comma\n        cp TOK_SEMI\n        jr nz,.nl               ; no separator: the item ends the line\n        call LEX_NEXT_TOKEN\n        jr .after_sep\n.comma:\n        call LEX_NEXT_TOKEN\n        call EMIT_OP_PRINT_COMMA\n.after_sep:","        cp TOK_SEMI\n        jr nz,.nl\n        call LEX_NEXT_TOKEN\n.after_sep:")
c=c.replace("EMIT_OP_PRINT_COMMA:          ld a,68 : jp EMIT_BYTE  ; STUDY: tab to the next 16-column zone\n","")
a=v.index("; STUDY: ',' in a PRINT list"); b=v.index("        jp VM_RUN.loop\n",v.index(".next_line:",a))+len("        jp VM_RUN.loop\n")
v=v[:a]+v[b:]
v=v.replace("        dw OP_PRINT_COMMA                                   ; 68  STUDY\n","").replace("cp 69 ","cp 68 ")
wr("rom/exrom_v2_compiler.asm",c); wr("rom/exrom_v2_vm_core.asm",v); measure("without ',' zones")
# 3 no bare PRINT / end checks at start of item
prep(); c=rd("rom/exrom_v2_compiler.asm")
c=c.replace(""".item:
        ld a,(TOK_TYPE)
        or a
        jr z,.nl                ; end of source
        cp TOK_COLON
        jr z,.nl                ; end of statement / line
        cp TOK_KW_ENDP
        jr z,.nl
        sub TOK_KW_ELSE
        cp 2
        jr c,.nl                ; ELSE / ENDIF
        ld a,(TOK_TYPE)""",""".item:
        ld a,(TOK_TYPE)""")
wr("rom/exrom_v2_compiler.asm",c); measure("without bare PRINT")
# 4 factored TOK_ENDS_STMT
prep(); c=rd("rom/exrom_v2_compiler.asm")
c=c.replace(""".item:
        ld a,(TOK_TYPE)
        or a
        jr z,.nl                ; end of source
        cp TOK_COLON
        jr z,.nl                ; end of statement / line
        cp TOK_KW_ENDP
        jr z,.nl
        sub TOK_KW_ELSE
        cp 2
        jr c,.nl                ; ELSE / ENDIF
        ld a,(TOK_TYPE)""",""".item:
        call TOK_ENDS_STMT
        jr c,.nl
        ld a,(TOK_TYPE)""")
c=c.replace(""".after_sep:
        ld a,(TOK_TYPE)         ; a trailing separator ends the statement WITHOUT a newline
        or a
        ret z
        cp TOK_COLON
        ret z
        cp TOK_KW_ENDP
        ret z
        sub TOK_KW_ELSE
        cp 2
        ret c
        jr .item""",""".after_sep:
        call TOK_ENDS_STMT      ; a trailing separator ends the statement WITHOUT a newline
        ret c
        jr .item""")
c=c.replace("; COMPILE_LPRINT","""; Carry set = the current token ends a statement (end of source, ':'/line end, ENDP, ELSE, ENDIF).
TOK_ENDS_STMT:
        ld a,(TOK_TYPE)
        or a
        jr z,.yes
        cp TOK_COLON
        jr z,.yes
        cp TOK_KW_ENDP
        jr z,.yes
        sub TOK_KW_ELSE
        cp 2
        ret
.yes:
        scf
        ret

; COMPILE_LPRINT""",1)
wr("rom/exrom_v2_compiler.asm",c); measure("factored TOK_ENDS_STMT (shrink)")

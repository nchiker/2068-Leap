"""aopt / bopt / copt full builds (tightened common code, PAS_END)."""
import sys, os, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *
wt = sys.argv[1]; variant = sys.argv[2]; p = P(wt)
srcvariant = variant                      # which exrom_v2_arrstore_<x>.asm to use
variant = variant.rstrip("2")             # aopt2/bopt2/copt2 differ only in the bind routine
here = os.path.dirname(os.path.abspath(__file__))
equs = {"copt": """V2_EXROM_ARRSVC_ADDR EQU $C0E6
V2_EXROM_ARR_DIM_ADDR EQU V2_EXROM_ARRSVC_ADDR
V2_EXROM_ARR_DIM_STR_ADDR EQU V2_EXROM_ARRSVC_ADDR + 3
""", "bopt": """V2_EXROM_ARRSVC_ADDR EQU $C0E6
V2_EXROM_ARR_ADOPT_ADDR EQU V2_EXROM_ARRSVC_ADDR
V2_EXROM_ARR_ZERO_NUM_ADDR EQU V2_EXROM_ARRSVC_ADDR + 3
V2_EXROM_ARR_ZERO_STR_ADDR EQU V2_EXROM_ARRSVC_ADDR + 6
""", "aopt": ""}
if variant == "aopt":
    # no fixed-address slots at all
    p.sub("include/v2_layout.inc", "ARR2_SWAPPED:     equ $B81D", "ARR2_SWAPPED:     equ $B81D\nPAS_LEN:          equ $B81E   ; 2: bytes used by the Array Store at ARR2_BASE (0 = empty)")
    p.sub("rom/v2_exrom.asm", "    INCLUDE \"kernel/storage/storage.asm\"\n", "    INCLUDE \"rom/exrom_v2_arrstore.asm\"\n    INCLUDE \"kernel/storage/storage.asm\"\n")
else:
    layout_and_images(p, equs[variant], os.path.join(here, "exrom_v2_arrstore_%s.asm" % srcvariant))
svc = p.rd("rom/exrom_v2_arrstore.asm") if variant != "aopt" else open(os.path.join(here, "exrom_v2_arrstore_%s.asm" % srcvariant)).read()
ldr = open(os.path.join(here, "exrom_v2_arrstore_copt_loader.asm")).read()
p.wr("rom/exrom_v2_arrstore.asm", svc + "\n" + ldr)
export_loop(p); crossbank(p)
if variant == "copt":
    remove_op_dim(p)
elif variant == "aopt":
    home_dim_a_opt(p)
else:
    home_dim_b_opt(p)
shell_common_pasend(p)
# shared shell edits (same as mk_full)
p.cut(SH, "; V2_LOAD_ARRAY -- entry: V2_NAME_PTR/LEN (tape filename) and V2_ARRAY_\n; NAME_PTR/LEN/IS_STR (target array) already set. Write-once policy", "V2_LIST:")
p.sub(SH, """    ld b,a
    ld hl,(V2_NAME_PTR)
    ld de,STORAGE_LOAD_NAME_BUF
    ld c,10
.pad:
    ld a,b
    or a
    jr z,.space
    ld a,(hl)
    inc hl
    dec b
    jr .write
.space:
    ld a,' '
.write:
    ld (de),a
    inc de
    dec c
    jr nz,.pad
    ld hl,STORAGE_LOAD_NAME_BUF
    ld b,10
    jr .receive""", """    ld b,a
    ld hl,(V2_NAME_PTR)
    call V2_PAD_NAME
    ld hl,STORAGE_LOAD_NAME_BUF
    ld b,10
    jr .receive""")
p.sub(SH, """    cp 9
    jr c,.len_ok
    ld a,8
.len_ok:
    ld (V2_ARRAY_NAME_LEN),a""", """    cp IDENT_MAX_LEN+1
    jr nc,.bad
    ld (V2_ARRAY_NAME_LEN),a""")
s = p.rd(SH)
a = s.index("    ; case-insensitivity: ARRSYM_LOOKUP/STRARRSYM_LOOKUP now fold case")
b = s.index("    or a\n    ret\n.bad:\n    scf\n    ret\n\nV2_SAVE:")
p.wr(SH, s[:a] + s[b:])
p.sub(SH, "    call STORAGE_SAVE\n    ei\n    ld hl,V2_MSG_SAVED\n    jp V2_SHOW_MESSAGE\n.not_dimd:\n    ld hl,V2_MSG_ARRAY_NOT_DIMD\n    jp V2_SHOW_MESSAGE\n\n; V2_VERIFY",
          "    ld a,STORAGE_ARRAY_TYPE\n    ld (STORAGE_REQUEST_TYPE),a   ; D13\n    call STORAGE_SAVE\n    ei\n    ld hl,V2_MSG_SAVED\n    jp V2_SHOW_MESSAGE\n.not_dimd:\n    jp ARR_SAVE_STORE\n\n; V2_VERIFY")
p.sub(SH, 'V2_MSG_ARRAY_MISMATCH: DB "ARRAY ALREADY SET",0', 'V2_MSG_STORE_FULL: DB "ARRAY STORE FULL",0\nV2_MSG_BAD_ARRAY: DB "BAD ARRAY TAPE",0')
print("FULL-%s applied" % variant)

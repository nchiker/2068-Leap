"""Full architecture C (EXROM-owned, eager) incl. the common loader/saver, for measurement."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *
wt = sys.argv[1]; p = P(wt); here = os.path.dirname(os.path.abspath(__file__))
variant = sys.argv[2] if len(sys.argv) > 2 else "ce"
layout_and_images(p, """V2_EXROM_ARRSVC_ADDR EQU $C0E6          ; R10.9 2B: array service jp slots
V2_EXROM_ARR_DIM_ADDR EQU V2_EXROM_ARRSVC_ADDR
V2_EXROM_ARR_DIM_STR_ADDR EQU V2_EXROM_ARRSVC_ADDR + 3
""" if variant in ("ce", "copt") else """V2_EXROM_ARRSVC_ADDR EQU $C0E6
V2_EXROM_ARR_ADOPT_ADDR EQU V2_EXROM_ARRSVC_ADDR
V2_EXROM_ARR_ZERO_NUM_ADDR EQU V2_EXROM_ARRSVC_ADDR + 3
V2_EXROM_ARR_ZERO_STR_ADDR EQU V2_EXROM_ARRSVC_ADDR + 6
""", os.path.join(here, "exrom_v2_arrstore_%s.asm" % variant))
# service + loader in one file
svc = p.rd("rom/exrom_v2_arrstore.asm")
ldr = open(os.path.join(here, "exrom_v2_arrstore_loader.asm" if variant != "copt" else "exrom_v2_arrstore_copt_loader.asm")).read()
p.wr("rom/exrom_v2_arrstore.asm", svc + "\n" + ldr)
remove_op_dim(p); export_loop(p); crossbank(p)
if variant == "copt":
    shell_common_pasend(p)
else:
    shell_common(p)
# ---- shell edits ----
# 1. drop the old pool-path loader
p.cut(SH, "; V2_LOAD_ARRAY -- entry: V2_NAME_PTR/LEN (tape filename) and V2_ARRAY_\n; NAME_PTR/LEN/IS_STR (target array) already set. Write-once policy", "V2_LIST:")
# 2. V2_LOAD uses the shared name padding
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
# 3. names: up to 31 characters, no canonical copy
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
# 4. SAVE ARRAY: D13 type byte, and the store as a fallback source
p.sub(SH, "    call STORAGE_SAVE\n    ei\n    ld hl,V2_MSG_SAVED\n    jp V2_SHOW_MESSAGE\n.not_dimd:\n    ld hl,V2_MSG_ARRAY_NOT_DIMD\n    jp V2_SHOW_MESSAGE\n\n; V2_VERIFY",
          "    ld a,STORAGE_ARRAY_TYPE\n    ld (STORAGE_REQUEST_TYPE),a   ; D13\n    call STORAGE_SAVE\n    ei\n    ld hl,V2_MSG_SAVED\n    jp V2_SHOW_MESSAGE\n.not_dimd:\n    jp ARR_SAVE_STORE\n\n; V2_VERIFY")
# 5. messages
p.sub(SH, 'V2_MSG_ARRAY_MISMATCH: DB "ARRAY ALREADY SET",0', 'V2_MSG_STORE_FULL: DB "ARRAY STORE FULL",0\nV2_MSG_BAD_ARRAY: DB "BAD ARRAY TAPE",0')
print("FULL-%s applied" % variant)

"""Apply prototype VC (architecture C, lazy bind, EXROM-owned DIM) to a worktree."""
import sys, re, shutil, os
wt = sys.argv[1]
def rd(p): return open(os.path.join(wt,p)).read()
def wr(p,s): open(os.path.join(wt,p),"w").write(s)
def sub(p, old, new, count=1):
    s = rd(p)
    assert s.count(old) >= 1, (p, old[:60])
    if count == 1: assert s.count(old) == 1, (p, old[:60], s.count(old))
    wr(p, s.replace(old, new))

# 1. fixed addresses
sub("include/v2_ktab.inc", "    IFDEF V2_KTAB_HOME\n    MACRO V2_KTAB_ENTRY",
"""V2_EXROM_ARRSVC_ADDR EQU $C0E6          ; R10.9 2B: array service jp slots (4 x 3 B)
V2_EXROM_ARR_DIM_ADDR EQU V2_EXROM_ARRSVC_ADDR
V2_EXROM_ARR_DIM_STR_ADDR EQU V2_EXROM_ARRSVC_ADDR + 3
V2_EXROM_ARR_LAZY_NUM_ADDR EQU V2_EXROM_ARRSVC_ADDR + 6
V2_EXROM_ARR_LAZY_STR_ADDR EQU V2_EXROM_ARRSVC_ADDR + 9
    IFDEF V2_KTAB_HOME
    MACRO V2_KTAB_ENTRY""")
# 2. PAS_LEN
sub("include/v2_layout.inc", "ARR2_SWAPPED:     equ $B81D",
    "ARR2_SWAPPED:     equ $B81D\nPAS_LEN:          equ $B81E   ; 2: bytes used by the Array Store at ARR2_BASE (0 = empty)")
# 3. EXROM image
sub("rom/v2_exrom.asm", "    INCLUDE \"kernel/storage/storage.asm\"\n",
    "    ASSERT $ == V2_EXROM_ARRSVC_ADDR\n    INCLUDE \"rom/exrom_v2_arrstore.asm\"\n    INCLUDE \"kernel/storage/storage.asm\"\n")
shutil.copy(os.path.join(os.path.dirname(os.path.abspath(__file__)), "exrom_v2_arrstore_vc.asm"),
            os.path.join(wt, "rom/exrom_v2_arrstore.asm"))
# 4. vm_core
vm = "rom/exrom_v2_vm_core.asm"
sub(vm, "        dw OP_DIM                                           ; 63 (R10.7",
        "        dw V2_EXROM_ARR_DIM_ADDR                            ; 63 (R10.9: EXROM-owned DIM")
sub(vm, "        dw OP_DIM_STR                                       ; 64 (R10.7",
        "        dw V2_EXROM_ARR_DIM_STR_ADDR                        ; 64 (R10.9: EXROM-owned DIM$")
s = rd(vm)
a = s.index("OP_DIM:\n        ld hl,(VM_IP)")
b = s.index("; ---------------------------------------------------------------------------\n; R10.7 Dynamic Data Phase 2 -- string arrays")
s = s[:a] + s[b:]
a = s.index("OP_DIM_STR:\n        ld hl,(VM_IP)")
b = s.index("; ---------------------------------------------------------------------------\n; R8.5 Group 2 (closed out late) -- INPUT.")
s = s[:a] + s[b:]
wr(vm, s)
# lazy hooks
sub(vm, """        ld a,d
        or e
        scf
        ret z                     ; never DIM'd this run
        ex de,hl                  ; HL = descriptor addr
        ld de,ARR_DESC_DATA_OFF""", """        ld a,d
        or e
        call z,V2_EXROM_ARR_LAZY_NUM_ADDR ; R10.9: slot 0 -> bind from the Array Store
        ret c                     ; CF: still never DIM'd this run
        ex de,hl                  ; HL = descriptor addr
        ld de,ARR_DESC_DATA_OFF""")
sub(vm, """        ld a,d
        or e
        scf
        ret z                     ; never DIM'd this run
        ex de,hl                  ; HL = descriptor addr
        ld de,STRARR_DESC_WIDTH_OFF""", """        ld a,d
        or e
        call z,V2_EXROM_ARR_LAZY_STR_ADDR
        ret c                     ; CF: still never DIM'd this run
        ex de,hl                  ; HL = descriptor addr
        ld de,STRARR_DESC_WIDTH_OFF""")
# VM_INIT: segment 2 starts above the store
sub(vm, "        ld hl,ARR2_BASE\n        ld (ARR2_END),hl\n        jp VM_CARVE_TABLES",
        "        ld hl,(PAS_LEN)\n        ld de,ARR2_BASE\n        add hl,de\n        ld (ARR2_END),hl\n        jp VM_CARVE_TABLES")
# export for EXROM
wr(vm, rd(vm).rstrip("\n") + "\nVM_RUN_LOOP EQU VM_RUN.loop   ; R10.9: exported for the EXROM array service\n")
# 5. shell
sh = "rom/exrom_v2_shell.asm"
sub(sh, "    ld hl,ARR2_BASE              ; R10.7 P5.4: segment 2 (always-visible RAM at\n    ld (ARR2_END),hl             ; $E000) is emptied with the main pool",
        "    ld hl,(PAS_LEN)              ; R10.7 P5.4: segment 2 (always-visible RAM at\n    ld de,ARR2_BASE              ; $E000) is emptied with the main pool, but the\n    add hl,de                    ; Array Store below ARR2_END survives\n    ld (ARR2_END),hl")
sub(sh, "    call MEM_INIT_V2\n    call V2_RESET_EDIT\n    or a\n    ret\n.not_new:",
        "    ld hl,0\n    ld (PAS_LEN),hl              ; NEW (only) clears the Array Store\n    call MEM_INIT_V2\n    call V2_RESET_EDIT\n    or a\n    ret\n.not_new:")
sub(sh, "    ld hl,V2_MSG_NOMEM\n    cp 64\n    ret z\n    ld hl,V2_MSG_RUNTIME\n    ret",
        "    ld hl,V2_MSG_NOMEM\n    cp 64\n    ret z\n    ld hl,V2_MSG_ARRAY_SHAPE\n    cp 65\n    ret z\n    ld hl,V2_MSG_RUNTIME\n    ret")
sub(sh, 'V2_MSG_ARRAY_MISMATCH: DB "ARRAY ALREADY SET",0',
        'V2_MSG_ARRAY_MISMATCH: DB "ARRAY ALREADY SET",0\nV2_MSG_ARRAY_SHAPE: DB "ARRAY SIZE MISMATCH",0')
# 6. crossbank names
sub("tools/write_v2_crossbank.py", '    "SYM_RESET",\n', '    "SYM_RESET",\n    "NAME_CMP_FOLD",\n    "VM_DIM_COUNT_TMP",\n    "VM_STRARR_ADDR_TMP",\n    "VM_RUN_LOOP",\n    "VM_ARR_ADDR",\n'.replace('    "VM_ARR_ADDR",\n',''))
print("VC applied")

import os, sys
class P:
    def __init__(self, wt): self.wt = wt
    def rd(self, p): return open(os.path.join(self.wt, p)).read()
    def wr(self, p, s): open(os.path.join(self.wt, p), "w").write(s)
    def sub(self, p, old, new):
        s = self.rd(p)
        assert s.count(old) == 1, (p, old[:70], s.count(old))
        self.wr(p, s.replace(old, new))
    def cut(self, p, start, end):
        s = self.rd(p); a = s.index(start); b = s.index(end); self.wr(p, s[:a] + s[b:])
VM = "rom/exrom_v2_vm_core.asm"
SH = "rom/exrom_v2_shell.asm"

def layout_and_images(p, table_slots_equ, src_asm):
    p.sub("include/v2_ktab.inc", "    IFDEF V2_KTAB_HOME\n    MACRO V2_KTAB_ENTRY",
          table_slots_equ + "    IFDEF V2_KTAB_HOME\n    MACRO V2_KTAB_ENTRY")
    p.sub("include/v2_layout.inc", "ARR2_SWAPPED:     equ $B81D",
          "ARR2_SWAPPED:     equ $B81D\nPAS_LEN:          equ $B81E   ; 2: bytes used by the Array Store at ARR2_BASE (0 = empty)")
    p.sub("rom/v2_exrom.asm", "    INCLUDE \"kernel/storage/storage.asm\"\n",
          "    ASSERT $ == V2_EXROM_ARRSVC_ADDR\n    INCLUDE \"rom/exrom_v2_arrstore.asm\"\n    INCLUDE \"kernel/storage/storage.asm\"\n")
    import shutil
    shutil.copy(src_asm, os.path.join(p.wt, "rom/exrom_v2_arrstore.asm"))

def shell_common(p, post_init_call=True):
    p.sub(SH, "    ld hl,ARR2_BASE              ; R10.7 P5.4: segment 2 (always-visible RAM at\n    ld (ARR2_END),hl             ; $E000) is emptied with the main pool",
          "    ld hl,(PAS_LEN)              ; R10.7 P5.4: segment 2 (always-visible RAM at\n    ld de,ARR2_BASE              ; $E000) is emptied with the main pool, but the\n    add hl,de                    ; Array Store below ARR2_END survives\n    ld (ARR2_END),hl")
    p.sub(SH, "    call MEM_INIT_V2\n    call V2_RESET_EDIT\n    or a\n    ret\n.not_new:",
          "    ld hl,0\n    ld (PAS_LEN),hl              ; NEW (only) clears the Array Store\n    call MEM_INIT_V2\n    call V2_RESET_EDIT\n    or a\n    ret\n.not_new:")
    p.sub(SH, "    ld hl,V2_MSG_NOMEM\n    cp 64\n    ret z\n    ld hl,V2_MSG_RUNTIME\n    ret",
          "    ld hl,V2_MSG_NOMEM\n    cp 64\n    ret z\n    ld hl,V2_MSG_ARRAY_SHAPE\n    cp 65\n    ret z\n    ld hl,V2_MSG_RUNTIME\n    ret")
    p.sub(SH, 'V2_MSG_ARRAY_MISMATCH: DB "ARRAY ALREADY SET",0',
          'V2_MSG_ARRAY_MISMATCH: DB "ARRAY ALREADY SET",0\nV2_MSG_ARRAY_SHAPE: DB "ARRAY SIZE MISMATCH",0')
    if post_init_call:
        p.sub(SH, "    call KTAB_VM_INIT\n    ld hl,VM_CODE_BASE", "    call KTAB_VM_INIT\n    call ARR_RUN_INIT            ; R10.9 2B: Array Store bind (EXROM)\n    ld hl,VM_CODE_BASE")

def crossbank(p, extra=()):
    names = ["NAME_CMP_FOLD", "VM_DIM_COUNT_TMP", "VM_STRARR_ADDR_TMP", "VM_RUN_LOOP", "SYM_FIND"] + list(extra)
    p.sub("tools/write_v2_crossbank.py", '    "SYM_RESET",\n', '    "SYM_RESET",\n' + "".join('    "%s",\n' % n for n in names))

def export_loop(p):
    p.wr(VM, p.rd(VM).rstrip("\n") + "\nVM_RUN_LOOP EQU VM_RUN.loop   ; R10.9: exported for the EXROM array service\n")

def remove_op_dim(p):
    p.sub(VM, "        dw OP_DIM                                           ; 63 (R10.7",
              "        dw V2_EXROM_ARR_DIM_ADDR                            ; 63 (R10.9: EXROM-owned DIM")
    p.sub(VM, "        dw OP_DIM_STR                                       ; 64 (R10.7",
              "        dw V2_EXROM_ARR_DIM_STR_ADDR                        ; 64 (R10.9: EXROM-owned DIM$")
    p.cut(VM, "OP_DIM:\n        ld hl,(VM_IP)", "; ---------------------------------------------------------------------------\n; R10.7 Dynamic Data Phase 2 -- string arrays")
    p.cut(VM, "OP_DIM_STR:\n        ld hl,(VM_IP)", "; ---------------------------------------------------------------------------\n; R8.5 Group 2 (closed out late) -- INPUT.")

def shell_common_pasend(p):
    """PAS_END (absolute) flavour: cold-start init in V2_EXROM_ENTRY, NEW resets it."""
    p.sub("include/v2_layout.inc", "PAS_LEN:          equ $B81E   ; 2: bytes used by the Array Store at ARR2_BASE (0 = empty)",
          "PAS_END:          equ $B81E   ; 2: first byte past the Array Store (ARR2_BASE = empty); set at cold start and by NEW")
    p.sub(SH, "    ld hl,ARR2_BASE              ; R10.7 P5.4: segment 2 (always-visible RAM at\n    ld (ARR2_END),hl             ; $E000) is emptied with the main pool",
          "    ld hl,(PAS_END)              ; R10.7 P5.4: segment 2 (always-visible RAM at\n    ld (ARR2_END),hl             ; $E000) is emptied with the main pool, but the\n                                   ; Array Store below PAS_END survives")
    p.sub(SH, "    call MEM_INIT_V2\n    call V2_RESET_EDIT\n    or a\n    ret\n.not_new:",
          "    ld hl,ARR2_BASE\n    ld (PAS_END),hl              ; NEW (only) clears the Array Store\n    call MEM_INIT_V2\n    call V2_RESET_EDIT\n    or a\n    ret\n.not_new:")
    p.sub(SH, "    ld hl,V2_MSG_NOMEM\n    cp 64\n    ret z\n    ld hl,V2_MSG_RUNTIME\n    ret",
          "    ld hl,V2_MSG_NOMEM\n    cp 64\n    ret z\n    ld hl,V2_MSG_ARRAY_SHAPE\n    cp 65\n    ret z\n    ld hl,V2_MSG_RUNTIME\n    ret")
    p.sub(SH, 'V2_MSG_ARRAY_MISMATCH: DB "ARRAY ALREADY SET",0',
          'V2_MSG_ARRAY_MISMATCH: DB "ARRAY ALREADY SET",0\nV2_MSG_ARRAY_SHAPE: DB "ARRAY SIZE MISMATCH",0')
    p.sub(SH, "    call KTAB_VM_INIT\n    ld hl,VM_CODE_BASE", "    call KTAB_VM_INIT\n    call ARR_RUN_INIT            ; R10.9 2B: Array Store bind (EXROM)\n    ld hl,VM_CODE_BASE")
    p.sub("rom/v2_exrom.asm", "V2_EXROM_ENTRY:\n    jp V2_COMMAND_LOOP", "V2_EXROM_ENTRY:\n    ld hl,ARR2_BASE\n    ld (PAS_END),hl              ; cold start: the Array Store is empty\n    jp V2_COMMAND_LOOP")

def home_dim_a_opt(p):
    """A: adopt test + zero-fill inline in the HOME DIM handlers (PAS_END flavour)."""
    p.sub(VM, "        ld (VM_IP),hl\n        call ARENA_ALLOC_NUMERIC\n        jp VM_RUN.loop",
"""        ld (VM_IP),hl
        ld hl,(RT_ARRPTR_PTR)
        call VM_DIM_STORED        ; CF: slot already in the Array Store
        jp c,VM_RUN.loop
        call ARENA_ALLOC_NUMERIC
        ld a,(VM_HALTED)
        or a
        jp nz,VM_RUN.loop
        ld hl,0
        ld (VM_ARR_ELEM_TMP),hl
        call VM_ARR_ADDR          ; HL -> data[0]
        ld bc,(VM_DIM_COUNT_TMP)
        sla c
        rl b
        call MEM_FILL_ZERO        ; D12: DIM zero-fills
        jp VM_RUN.loop

; VM_DIM_STORED -- A = array index, HL = pointer-table base.  CF=1 if that slot
; already points into the Array Store.  Preserves A, DE.
VM_DIM_STORED:
        push af
        push de
        ld e,a
        ld d,0
        add hl,de
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld a,d
        cp ARR2_BASE >> 8
        jr c,.no
        ld hl,(PAS_END)
        or a
        sbc hl,de
        jr c,.no
        jr z,.no
        pop de
        pop af
        scf
        ret
.no:
        pop de
        pop af
        or a
        ret""")
    p.sub(VM, "        ld (VM_IP),hl\n        ld a,b             ; A = array index\n        call ARENA_ALLOC_STRING\n        jp VM_RUN.loop",
"""        ld (VM_IP),hl
        ld a,b             ; A = array index
        push bc
        ld hl,(RT_STRARRPTR_PTR)
        call VM_DIM_STORED
        pop bc
        jp c,VM_RUN.loop
        call ARENA_ALLOC_STRING
        ld a,(VM_HALTED)
        or a
        jp nz,VM_RUN.loop
        ld bc,(VM_STRARR_ADDR_TMP)
        push bc
        ld hl,0
        ld (VM_ARR_ELEM_TMP),hl
        call VM_STRARR_ADDR
        pop bc
        call MEM_FILL_ZERO
        jp VM_RUN.loop""")
    # VM_INIT: segment 2 starts above the store (same size as before: ld hl,(nn))
    p.sub(VM, "        ld hl,ARR2_BASE\n        ld (ARR2_END),hl\n        jp VM_CARVE_TABLES",
              "        ld hl,(PAS_END)\n        ld (ARR2_END),hl\n        jp VM_CARVE_TABLES")

def home_dim_b_opt(p):
    p.sub(VM, "        ld (VM_IP),hl\n        call ARENA_ALLOC_NUMERIC\n        jp VM_RUN.loop",
"""        ld (VM_IP),hl
        ld c,SYM_K_ARR
        push af
        push de
        call V2_EXROM_ARR_ADOPT_ADDR   ; CF: slot already in the Array Store
        pop de
        pop af
        jp c,VM_RUN.loop
        call ARENA_ALLOC_NUMERIC
        call V2_EXROM_ARR_ZERO_NUM_ADDR ; D12: DIM zero-fills (EXROM)
        jp VM_RUN.loop""")
    p.sub(VM, "        ld (VM_IP),hl\n        ld a,b             ; A = array index\n        call ARENA_ALLOC_STRING\n        jp VM_RUN.loop",
"""        ld (VM_IP),hl
        ld a,b             ; A = array index
        push bc
        ld c,SYM_K_SARR
        call V2_EXROM_ARR_ADOPT_ADDR
        pop bc
        jp c,VM_RUN.loop
        call ARENA_ALLOC_STRING
        call V2_EXROM_ARR_ZERO_STR_ADDR
        jp VM_RUN.loop""")
    p.sub(VM, "        ld hl,ARR2_BASE\n        ld (ARR2_END),hl\n        jp VM_CARVE_TABLES",
              "        ld hl,(PAS_END)\n        ld (ARR2_END),hl\n        jp VM_CARVE_TABLES")

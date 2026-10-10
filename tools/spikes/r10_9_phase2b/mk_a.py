import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *
wt = sys.argv[1]; p = P(wt); here = os.path.dirname(os.path.abspath(__file__))
# A: no HOME->EXROM call at all; EXROM image still needs the bind routine.
p.sub("include/v2_layout.inc", "ARR2_SWAPPED:     equ $B81D",
      "ARR2_SWAPPED:     equ $B81D\nPAS_LEN:          equ $B81E   ; 2: bytes used by the Array Store at ARR2_BASE (0 = empty)")
p.sub("rom/v2_exrom.asm", "    INCLUDE \"kernel/storage/storage.asm\"\n",
      "    INCLUDE \"rom/exrom_v2_arrstore.asm\"\n    INCLUDE \"kernel/storage/storage.asm\"\n")
import shutil; shutil.copy(os.path.join(here, "exrom_v2_arrstore_a.asm"), os.path.join(wt, "rom/exrom_v2_arrstore.asm"))
# HOME: adopt helper + zero-fill in the DIM handlers
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
        ld hl,(PAS_LEN)
        ld bc,ARR2_BASE
        add hl,bc
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
p.sub(VM, "        ld hl,ARR2_BASE\n        ld (ARR2_END),hl\n        jp VM_CARVE_TABLES",
          "        ld hl,(PAS_LEN)\n        ld de,ARR2_BASE\n        add hl,de\n        ld (ARR2_END),hl\n        jp VM_CARVE_TABLES")
shell_common(p)      # shell calls ARR_RUN_INIT after VM_INIT
export_loop(p); crossbank(p)
print("A applied")

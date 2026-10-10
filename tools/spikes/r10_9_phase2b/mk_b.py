import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *
wt = sys.argv[1]; p = P(wt); here = os.path.dirname(os.path.abspath(__file__))
layout_and_images(p, """V2_EXROM_ARRSVC_ADDR EQU $C0E6          ; R10.9 2B: array service jp slots (3 x 3 B)
V2_EXROM_ARR_ADOPT_ADDR EQU V2_EXROM_ARRSVC_ADDR
V2_EXROM_ARR_ZERO_NUM_ADDR EQU V2_EXROM_ARRSVC_ADDR + 3
V2_EXROM_ARR_ZERO_STR_ADDR EQU V2_EXROM_ARRSVC_ADDR + 6
""", os.path.join(here, "exrom_v2_arrstore_b.asm"))
# the B EXROM file begins with the scratch cells and ARR_RUN_INIT; the jp table sits after them,
# so move the table to the front (fixed address) via an ORG-free include order:
s = p.rd("rom/exrom_v2_arrstore.asm")
tbl = s[s.index("ARRSVC_TABLE:"):s.index("; ARR_ADOPT --")]
s = s.replace(tbl, "")
s = s.replace("ASV_IDX     EQU", tbl + "ASV_IDX     EQU", 1)
p.wr("rom/exrom_v2_arrstore.asm", s)
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
          "        ld hl,(PAS_LEN)\n        ld de,ARR2_BASE\n        add hl,de\n        ld (ARR2_END),hl\n        jp VM_CARVE_TABLES")
shell_common(p); export_loop(p); crossbank(p)
print("B applied")

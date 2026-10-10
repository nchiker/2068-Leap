"""C+ : CE plus the arena allocation cores moved (verbatim) into EXROM."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *
wt = sys.argv[1]; p = P(wt); here = os.path.dirname(os.path.abspath(__file__))
layout_and_images(p, """V2_EXROM_ARRSVC_ADDR EQU $C0E6          ; R10.9 2B: array service jp slots (2 x 3 B)
V2_EXROM_ARR_DIM_ADDR EQU V2_EXROM_ARRSVC_ADDR
V2_EXROM_ARR_DIM_STR_ADDR EQU V2_EXROM_ARRSVC_ADDR + 3
""", os.path.join(here, "exrom_v2_arrstore_ce.asm"))
remove_op_dim(p)
s = p.rd(VM)
a1 = s.index("; ARENA_ALLOC_NUMERIC -- shared numeric-array arena allocation core,")
b1 = s.index("; ---------------------------------------------------------------------------\n; R10.7 Dynamic Data Phase 2 -- string arrays")
blk1 = s[a1:b1]; s = s[:a1] + s[b1:]
p.wr(VM, s)
s = p.rd(VM)
a2 = s.index("; OP_DIM_STR -- DIM A$(n,w)'s own runtime allocation")
b2 = s.index("; ---------------------------------------------------------------------------\n; R8.5 Group 2 (closed out late) -- INPUT.")
blk2 = s[a2:b2]; s = s[:a2] + s[b2:]
p.wr(VM, s)
p.wr("rom/exrom_v2_arrstore.asm", p.rd("rom/exrom_v2_arrstore.asm") + "\n; ---- allocation cores, moved from HOME (verbatim) ----\n" + blk1 + blk2)
export_loop(p); shell_common(p)
crossbank(p, ["VM_STRARR_COUNT_TMP", "VM_STRARR_WIDTH_TMP", "VM_ERR_ARRAY_SPACE"])
cb = p.rd("tools/write_v2_crossbank.py")
cb = cb.replace('    "ARENA_ALLOC_NUMERIC",\n', '').replace('    "ARENA_ALLOC_STRING",\n', '')
p.wr("tools/write_v2_crossbank.py", cb)
print("C+ applied")

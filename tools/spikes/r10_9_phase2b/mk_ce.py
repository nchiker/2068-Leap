import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *
wt = sys.argv[1]; p = P(wt); here = os.path.dirname(os.path.abspath(__file__))
layout_and_images(p, """V2_EXROM_ARRSVC_ADDR EQU $C0E6          ; R10.9 2B: array service jp slots (2 x 3 B)
V2_EXROM_ARR_DIM_ADDR EQU V2_EXROM_ARRSVC_ADDR
V2_EXROM_ARR_DIM_STR_ADDR EQU V2_EXROM_ARRSVC_ADDR + 3
""", os.path.join(here, "exrom_v2_arrstore_ce.asm"))
remove_op_dim(p); export_loop(p); shell_common(p); crossbank(p)
print("CE applied")

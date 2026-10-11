; rom/test_v2_group6_math_run.asm -- RC: the run phase of rom/test_v2_group6_math.asm (every
; SGN/MOD/DIV/RND/POINT/ATTR/INT/PEEK/USR/LEN/CODE/VAL value is checked). Assembled with the
; calculator EXROM variant (tools/run_v2_standalone_tests.sh, calc_migrated_names), because VAL
; parses with the calculator; test_v2_group6_math.asm itself checks the decompiled text.
    DEFINE TEST_V2_PHASE_RUN
    INCLUDE "rom/test_v2_group6_math.asm"

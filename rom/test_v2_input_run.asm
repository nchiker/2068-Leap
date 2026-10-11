; rom/test_v2_input_run.asm -- RC: the run phase of rom/test_v2_input.asm (INPUT A / INPUT B$ with a
; scripted key stream; A must be TAG_INT 42, B$ "HI", four output lines). Assembled with the
; calculator EXROM variant (tools/run_v2_standalone_tests.sh, calc_migrated_names), because INPUT
; parses numbers with the calculator; test_v2_input.asm itself checks the decompiled text.
    DEFINE TEST_V2_PHASE_RUN
    INCLUDE "rom/test_v2_input.asm"

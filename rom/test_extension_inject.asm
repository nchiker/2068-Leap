; Test-only wrapper enabling the RAM-extension installer call in the reusable
; suite harness. The module bytes themselves are debugger-injected at $F400.
    DEFINE TEST_RAM_EXTENSION
    INCLUDE "rom/test_suite_inject.asm"

; Test-only wrapper: install a RAM extension, then perform MEM_INIT/NEW reset.
    DEFINE EDITOR_AUTO_OMIT_DEF_FN
    DEFINE TEST_RAM_EXTENSION
    DEFINE TEST_RAM_EXTENSION_CLEAR
    INCLUDE "rom/test_suite_inject.asm"

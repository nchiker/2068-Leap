; ============================================================================
; shared_lowrom_data.inc — immutable data shared by Home ROM and EXROM
;
; The Home call table ends at KTAB_MAGIC_ADDR.  The bytes immediately after
; its magic marker through $00FF are otherwise padding, while Home remains
; visible at these addresses when EXROM is paged into chunk 6.  Keeping these
; strings here therefore removes one copy from each ROM image.
; ============================================================================

    IFNDEF SHARED_LOWROM_DATA_INC
    DEFINE SHARED_LOWROM_DATA_INC

SHARED_LOWROM_BASE       EQU KTAB_MAGIC_ADDR + 1
MSG_ARRAY_NOT_DIMMED     EQU SHARED_LOWROM_BASE
MSG_INVALID_ARGUMENT     EQU MSG_ARRAY_NOT_DIMMED + 22
MSG_SYNTAX_ERROR         EQU MSG_INVALID_ARGUMENT + 17
KW_IF                    EQU MSG_SYNTAX_ERROR + 13
SHARED_LOWROM_END        EQU KW_IF + 3

    ASSERT SHARED_LOWROM_BASE == $00C8
    ASSERT SHARED_LOWROM_END <= $0100

    MACRO EMIT_SHARED_LOWROM_DATA
    ASSERT $ == SHARED_LOWROM_BASE
    DB "ARRAY NOT DIMENSIONED", 0
    DB "INVALID ARGUMENT", 0
    DB "SYNTAX ERROR", 0
    DB "IF", 0
    ASSERT $ == SHARED_LOWROM_END
    ENDM

    ENDIF

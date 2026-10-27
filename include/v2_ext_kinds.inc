; 6.1 (package ABI 2.1): the kind of a registered name, bits 7-6 of its signature byte (the
; registry record's argtypes byte, EXT2_REGISTER's C; bits 4-0 stay the argument types).
; Included by include/v2_package_abi.inc (packages) and kernel/extensions/ext_registry.asm.
    IFNDEF V2_EXT_KINDS_INC
    DEFINE V2_EXT_KINDS_INC
EXT_KIND_STMT           EQU $00     ; a statement: NAME a, b (every ABI 2.0 package)
EXT_KIND_FN             EQU $40     ; a numeric function: NAME(a, b), its value from EXT_CALL_RESULT
EXT_KIND_STR            EQU $C0     ; a string function: NAME$(a, b), EXT_CALL_RESULT -> [len][text]
EXT_KIND_MASK           EQU $C0
    ENDIF

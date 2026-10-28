; 6.1 (package ABI 2.1): the kind of a registered name, bits 7-6 of its signature byte (the
; registry record's argtypes byte, EXT2_REGISTER's C; bits 4-0 stay the argument types).
; Included by include/v2_package_abi.inc (packages) and kernel/extensions/ext_registry.asm.
    IFNDEF V2_EXT_KINDS_INC
    DEFINE V2_EXT_KINDS_INC
EXT_KIND_STMT           EQU $00     ; a statement: NAME a, b (every ABI 2.0 package)
EXT_KIND_FN             EQU $40     ; a numeric function: NAME(a, b), its value from EXT_CALL_RESULT
EXT_KIND_STR            EQU $C0     ; a string function: NAME$(a, b), EXT_CALL_RESULT -> [len][text]
EXT_KIND_MASK           EQU $C0
; 6.2 (ABI 2.1): bit 5, the float form. Its numeric arguments arrive as the addresses of 5-byte
; floats (an INT converted), and a numeric function's value is a float (EXT_CALL_RESULT -> its 5
; bytes). Its arguments are all numbers (bits 4-0 = 0; EXT2_REGISTER refuses anything else).
EXT_SIG_FLOAT           EQU $20
EXT_COUNT_MASK          EQU $07     ; the argument count in OP_CALL_EXT's operand byte (0-5)
; 6.2: FP_OP's operations (service 17, A on entry)
FOP_ADD                 EQU 0       ; x = x + y
FOP_SUB                 EQU 1       ; x = x - y
FOP_MUL                 EQU 2       ; x = x * y
FOP_DIV                 EQU 3       ; x = x / y
FOP_INT                 EQU 4       ; x = the 16-bit integer DE
FOP_TRUNC               EQU 5       ; HL = x truncated toward zero (CF: outside -32768..32767)
; 6.3: the runtime error codes a package may raise (VM_RAISE_ERROR, service 18, or VM_ERROR_CODE):
; its own, 12-31 (the VM's codes stay outside them), and three VM codes whose meaning it shares
EXT_ERR_FIRST           EQU 12
EXT_ERR_LAST            EQU 31
EXT_ERR_DIV0            EQU 5       ; division by zero
EXT_ERR_RANGE           EQU 15      ; argument out of range
EXT_ERR_FLOAT           EQU 67      ; a float result out of range (FP_OP raises it itself)
    ENDIF

; QUAL shrink prototype: RST $30 = tail jump to COMPILE_RAISE_ERROR. A tail `jp` must not leave
; a return address behind, so the vector drops the one RST pushed (inc sp twice: no flag or
; register effect) -- COMPILE_RAISE_ERROR's own `ret` then returns to the original caller,
; exactly as after `jp COMPILE_RAISE_ERROR`. Only unconditional `jp/jr COMPILE_RAISE_ERROR`
; sites use it.
    DS $0030 - $, $FF
    IFNDEF V2_RST_VM_ONLY
    inc sp
    inc sp
    jp COMPILE_RAISE_ERROR      ; RST $30
    ENDIF
    DS $0038 - $, $FF

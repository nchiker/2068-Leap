; QUAL shrink prototype (study/qualification-shrink): 1-byte RST calls for the hottest call
; targets, in the HOME padding between the reset vector and RST $28 (was $FF fill).
; Each vector is a plain `jp`: `rst n` = `call target` (same stack/register contract).
; V2_RST_VM_ONLY: a test image without the compiler gets the VM vectors only.
    ASSERT $ <= $0008
    DS $0008 - $, $FF
    IFNDEF V2_RST_VM_ONLY
    jp LEX_NEXT_TOKEN           ; RST $08
    ENDIF
    DS $0010 - $, $FF
    jp VM_POP                   ; RST $10
    DS $0018 - $, $FF
    jp VM_POP_COERCE_INT        ; RST $18
    DS $0020 - $, $FF
    IFNDEF V2_RST_VM_ONLY
    jp EMIT_BYTE                ; RST $20
    ENDIF
    DS $0028 - $, $FF

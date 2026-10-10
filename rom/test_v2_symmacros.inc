; ============================================================================
; rom/test_v2_symmacros.inc -- R10.7 P3 test helpers.
;
; The run-time tables are carved at RUN time from the compiler's counts, so
; tests can no longer read "SYMTAB_BASE + n" as an absolute address: the base
; is RT_SYMTAB_PTR (a RAM word). These macros reproduce what the old absolute
; forms did, with the same register effects (only the destination register is
; changed, DE/HL are preserved as the old single instructions preserved them;
; flags are clobbered).
;
;   TSYM_ADDR off  : HL = address of byte `off` of the numeric symbol table
;   TSYM_LD16 off  : HL = the 16-bit value stored at that byte offset
;   TSYM_LD8 off   : A  = the byte at that offset
; `off` is a byte offset, e.g. index*3 (tag) or index*3+1 (value low byte).
; ============================================================================
    MACRO TSYM_ADDR off
    push de
    ld   hl,(RT_SYMTAB_PTR)
    ld   de,off
    add  hl,de
    pop  de
    ENDM

    MACRO TSYM_LD16 off
    push de
    ld   hl,(RT_SYMTAB_PTR)
    ld   de,off
    add  hl,de
    ld   e,(hl)
    inc  hl
    ld   d,(hl)
    ex   de,hl
    pop  de
    ENDM

    MACRO TSYM_LD8 off
    push hl
    push de
    ld   hl,(RT_SYMTAB_PTR)
    ld   de,off
    add  hl,de
    ld   a,(hl)
    pop  de
    pop  hl
    ENDM

;   TSTR_ADDR off  : HL = address of byte `off` of the string table
;   TSTR_LD8 off   : A  = the byte at that offset
    MACRO TSTR_ADDR off
    push de
    ld   hl,(RT_STRTAB_PTR)
    ld   de,off
    add  hl,de
    pop  de
    ENDM

    MACRO TSTR_LD8 off
    push hl
    push de
    ld   hl,(RT_STRTAB_PTR)
    ld   de,off
    add  hl,de
    ld   a,(hl)
    pop  de
    pop  hl
    ENDM

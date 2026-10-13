; ============================================================================
; rom/test_v2_dynamic_arrays.asm — R10.7 dynamic-array redesign smoke
; test. Covers: multiple arrays, an array far larger than the old fixed
; 16-element ceiling, numeric indexing/bounds, and DIMN. Built on the
; shared production-shaped harness. Does NOT exercise DECOMPILE_PROGRAM
; (OP_DIM/widened OP_ARR_LOAD/STORE decompile support is a known,
; reported gap -- see docs/R10_7_CAPABILITY_RESTORATION.md) --
; TEST_V2_CUSTOM_CHECKS drives COMPILE/VM_RUN directly and asserts on
; real VM/memory state instead.
; ============================================================================

    DEFINE TEST_V2_CUSTOM_CHECKS
    INCLUDE "rom/test_v2_harness_home_head.inc"

; This test never exercises DECOMPILE_PROGRAM (see this file's own
; header) -- rom/exrom_v2_compiler.asm's own COMPILE_PROGRAM still
; unconditionally sets DECOMP_END_ADDR at the end of every compile.
DECOMP_END_ADDR: equ $9900

TEST_CUSTOM_MAIN:
    ; This harness's own TEST_COLD_START does NOT call the real kernel/
    ; memory.asm MEM_INIT (a stripped-down test-only cold start -- see
    ; that file's own header), and VM_INIT's own new R10.7 arena-reset
    ; line is guarded by IFDEF V2_PRODUCTION (which this harness does
    ; not define) -- so PROG_END/ARRAYS_END/VARS_START are otherwise
    ; genuinely uninitialized RAM here. Set them explicitly, matching
    ; what MEM_INIT/MEM_INIT_V2 do in production.
    ld   hl, PROG_AREA_START
    ld   (PROG_END), hl
    ld   (ARRAYS_END), hl
    ld   hl, V2_SOURCE_END
    ld   (VARS_START), hl

    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM

    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    ; Expected final state (see SOURCE_TEXT below):
    ;   A(0)=10, A(1)=20, A(199)=199*2=398 (a 200-element array, far past
    ;   the old fixed 16-element ceiling)
    ;   B(0)=7 (a second, independent array)
    ;   D = DIMN(A) = 200
    ;   E = A(0)+A(1)+A(199)+B(0)+D = 10+20+398+7+200 = 635
    call CHECK_RESULT
    jp   c, TEST_FAIL

    jp   TEST_PASS

; A/B are numeric arrays; E is a plain scalar used to carry the combined
; check value out where CHECK_RESULT can read it back via VM_LOAD_VAR-
; equivalent logic (SYMTAB lookup by compile-time index -- E is the
; FIRST scalar this program creates, so its SYMTAB index is 0).
SOURCE_TEXT:
    db "DIM A(200)", 13
    db "DIM B(3)", 13
    db "A(0)=10", 13
    db "A(1)=20", 13
    db "A(199)=199*2", 13
    db "B(0)=7", 13
    db "D=DIMN(A)", 13
    db "E=A(0)+A(1)+A(199)+B(0)+D", 13
    db 0

; ============================================================================
; CHECK_RESULT — reads E's own SYMTAB record directly (E is the first
; scalar CSYM_FIND_OR_CREATE ever assigns in this program, so its
; runtime SYMTAB index is 0 -- confirmed by this program's own
; compile order: A/B are ARRAYS (a separate symbol table, ARRSYMTAB,
; never touches SYMTAB's own index counter), D and E are the first two
; SCALARS, in that order).
; ============================================================================
CHECK_RESULT:
    ld   a, 1                      ; E's own SYMTAB index -- D (index 0)
                                     ; was created first, E second
    call VM_SYM_ADDR               ; HL -> E's own [tag:1][value_lo:1]
                                     ; [value_hi:1] record
    inc  hl                        ; skip tag, HL -> value_lo
    ld   e, (hl)
    inc  hl
    ld   d, (hl)                   ; DE = E's own value
    ld   hl, 635
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; Test-only stubs: this program never exercises PRINT/LPRINT/BEEP/
; SOUND/PAUSE/INPUT/extensions/real screen bitmap content (same
; discipline as rom/test_v2_shapes_circle.asm).
BASIC_STMT_LPRINT_EXROM:
    ret
SOUND_BEEP:
    ret
SOUND_EXROM:
    or a
    ret
IO_READ_KEY:
    xor a
    ret
INT_GET_FRAMES:
    ld hl,0
    ret

GFX_CLS:
    ret
GFX_PAINT_ATTR:
    ret
GFX_SET_BORDER:
    ret
GFX_WRITE_PIXEL:
    ret
GFX_LINE:
    ret
GFX_PRINT_STRING_ATTR:
    ret
GFX_SCROLL_OUTPUT_UP:
    ret
GFX_READ_PIXEL:
    xor a
    ret
GFX_CELL_ATTR_ADDR:
    scf
    ret
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/test_v2_harness_home_tail.inc"

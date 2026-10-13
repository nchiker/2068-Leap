; ============================================================================
; rom/test_v2_arrays.asm — Architecture B, R8.5 Group 4 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new DIM/
; array grammar (COMPILE_DIM/COMPILE_ARRAY_ASSIGN/COMPILE_FACTOR's own
; array-read case, ARRSYM_FIND_OR_CREATE/ARRSYM_LOOKUP) and
; rom/exrom_v2_vm_core.asm's new OP_ARR_LOAD/OP_ARR_STORE (the runtime
; element-address opcode pair, backed by the fixed-stride ARRTAB pool).
; NOT wired into the production BASIC dispatch or the shipping EXROM
; build. Built on the shared production-shaped test harness (rom/
; test_v2_harness_home_head.inc/_tail.inc + rom/test_v2_harness_exrom.
; asm) -- see that harness's own header for why (post-semantic-milestone
; test-infrastructure fix, docs/POST_R9_TEST_INFRASTRUCTURE.md).
;
; Source program compiled and executed:
;
;   DIM A(5)
;   DIM B(3)
;   A(0)=10
;   A(1)=20
;   A(4)=99
;   B(0)=A(1)+A(0)
;   X=A(4)
;   PRINT A(0)
;   PRINT A(1)
;   PRINT A(4)
;   PRINT B(0)
;   PRINT X
;
; Exercises: two DIM'd arrays (proving ARRSYMTAB assigns distinct runtime
; slots, not just accepting one), writes to element 0/1/4 of a 5-element
; array (element 4 being the real upper-bound element, not just element
; 0 -- catches an off-by-one in the bounds check that a same-element-
; every-time test would miss), an array element read used inside an
; ordinary arithmetic expression (B(0)=A(1)+A(0), proving array reads
; compose as an ordinary factor, not just a bare assignment source), an
; array element read used inside a scalar assignment (X=A(4)), and each
; array read again as a bare PRINT argument.
;
; Verification technique: reads ARRTAB directly (same "verify real
; computed values via direct memory reads BEFORE trusting decompiled
; text" two-step discipline rom/test_v2_relational.asm's own header
; established) -- confirms the actual bytes landed at the real ARRTAB_
; BASE + (array_index*ARRAY_MAX_ELEMS + elem_index)*2 address, not just
; that VM_RUN completed without error.
; ============================================================================

; R10.7 dynamic-array redesign: decompiler support for OP_DIM/the
; widened OP_ARR_LOAD/STORE operand is a known, reported gap (docs/
; R10_7_CAPABILITY_RESTORATION.md) -- decompile verification dropped
; from this test; TEST_CHECK_RESULT below (updated for the new ARR_
; PTR_TABLE-indirected arena layout) still verifies real computed
; values directly. Switched to TEST_V2_CUSTOM_CHECKS (was the default
; flow) so this test can explicitly initialize PROG_END/ARRAYS_END/
; VARS_START itself -- VM_INIT's own new R10.7 arena-reset line is
; guarded by IFDEF V2_PRODUCTION (this harness doesn't define it), and
; this harness's own TEST_COLD_START never called the real kernel/
; memory.asm MEM_INIT either (same real gap rom/test_v2_dynamic_
; arrays.asm's own header first found and fixed).
    DEFINE TEST_V2_CUSTOM_CHECKS
    INCLUDE "rom/test_v2_harness_home_head.inc"
    INCLUDE "rom/test_v2_symmacros.inc"
DECOMP_END_ADDR: equ $9900

TEST_CUSTOM_MAIN:
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
    call TEST_CHECK_RESULT
    jp   c, TEST_FAIL
    jp   TEST_PASS

SOURCE_TEXT:
    db "DIM A(5):DIM B(3):"
    db "A(0)=10:A(1)=20:A(4)=99:B(0)=A(1)+A(0):X=A(4):"
    db "Y=DIMN(A):Z=DIMN(B):"
    db "PRINT A(0):PRINT A(1):PRINT A(4):PRINT B(0):PRINT X", 0

; ============================================================================
; TEST_CHECK_RESULT — R10.7: direct arena reads through ARR_PTR_TABLE
; (array A is ARRSYMTAB/ARR_PTR_TABLE slot 0, array B is slot 1) instead
; of the old fixed ARRTAB_BASE+(slot*16+elem)*2 math -- ARR_ELEM reads
; the array's own arena descriptor address from ARR_PTR_TABLE first,
; then adds ARR_DESC_DATA_OFF(3)+elem*2. Then DIMN's own SYMTAB values
; (Y=DIMN(A)=5, Z=DIMN(B)=3 -- numeric symbol declaration order: X=0,
; Y=1, Z=2), then VM_OUTPUT_ROW (must be 5 -- one line per PRINT (0-4);
; the DIMs and the three array/scalar assignments don't print).
; ============================================================================
; ARR_ELEM — in: A=array slot, E=element index (0-255). out: HL=that
; element's real arena address. Destroys: AF, HL.
ARR_ELEM:
    push bc
    ld   l, a
    ld   h, 0
    add  hl, hl
    ld   bc, (RT_ARRPTR_PTR)
    add  hl, bc
    ld   c, (hl)
    inc  hl
    ld   b, (hl)                ; BC = this array's descriptor address
    ld   l, e
    ld   h, 0
    add  hl, hl                  ; elem*2
    ld   de, ARR_DESC_DATA_OFF
    add  hl, de
    add  hl, bc                   ; + descriptor base
    pop  bc
    ret

TEST_CHECK_RESULT:
    ld   a, 0
    ld   e, 0
    call ARR_ELEM
    ld   a, (hl)
    ld   e, a
    inc  hl
    ld   a, (hl)
    ld   d, a
    ex   de, hl
    ld   de, 10
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   a, 0
    ld   e, 1
    call ARR_ELEM
    ld   a, (hl)
    ld   e, a
    inc  hl
    ld   a, (hl)
    ld   d, a
    ex   de, hl
    ld   de, 20
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   a, 0
    ld   e, 4
    call ARR_ELEM
    ld   a, (hl)
    ld   e, a
    inc  hl
    ld   a, (hl)
    ld   d, a
    ex   de, hl
    ld   de, 99
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   a, 1
    ld   e, 0
    call ARR_ELEM
    ld   a, (hl)
    ld   e, a
    inc  hl
    ld   a, (hl)
    ld   d, a
    ex   de, hl
    ld   de, 30                ; A(1)+A(0) = 20+10
    or   a
    sbc  hl, de
    jr   nz, .fail
    TSYM_ADDR 1*3 + 1
    ld   a, (hl)
    cp   5
    jr   nz, .fail
    inc  hl
    ld   a, (hl)
    or   a
    jr   nz, .fail
    TSYM_ADDR 2*3 + 1
    ld   a, (hl)
    cp   3
    jr   nz, .fail
    inc  hl
    ld   a, (hl)
    or   a
    jr   nz, .fail
    ld   a, (VM_OUTPUT_ROW)
    cp   5
    jr   nz, .fail
    ret
.fail:
    scf
    ret

; Test-only stubs: this file's own test program never exercises LPRINT/
; BEEP/SOUND/PAUSE, and never registers or calls a loadable extension.
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
EXT2_LOOKUP:
    scf
    ret
EXT2_SLOT_ADDR:
    ret
EXT_CALL_ARG0: equ $8B00
EXT_CALL_ARG4: equ $8B00
EXT2_TABLE:    equ $8B00

; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; this test never checks real screen bitmap content.
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
GFX_SET_MODE:
    ret
GFX_SPRITE_CAPTURE:
    or a
    ret
GFX_SPRITE_DRAW:
    or a
    ret
GFX_READ_PIXEL:
    xor a
    ret
GFX_CELL_ATTR_ADDR:
    scf
    ret
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/test_v2_harness_home_tail.inc"

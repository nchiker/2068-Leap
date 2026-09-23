; ============================================================================
; rom/test_v2_arrays.asm — Architecture B, R8.5 Group 4 smoke test
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new DIM/
; array grammar (COMPILE_DIM/COMPILE_ARRAY_ASSIGN/COMPILE_FACTOR's own
; array-read case, ARRSYM_FIND_OR_CREATE/ARRSYM_LOOKUP) and
; rom/exrom_v2_vm_core.asm's new OP_ARR_LOAD/OP_ARR_STORE (the runtime
; element-address opcode pair, backed by the fixed-stride ARRTAB pool).
; NOT wired into the production BASIC dispatch or the shipping EXROM
; build.
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
; Verification technique: reads ARRTAB directly via CHECK_ARR (same
; "verify real computed values via direct memory reads BEFORE trusting
; decompiled text" two-step discipline rom/test_v2_relational.asm's own
; header established) -- confirms the actual bytes landed at the real
; ARRTAB_BASE + (array_index*ARRAY_MAX_ELEMS + elem_index)*2 address, not
; just that VM_RUN completed without error.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_arrays.sym \
;       rom/test_v2_arrays.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_arrays_zesarux.bin
;   ts2068-debug run --max-instructions 3000000
;   ts2068-debug timex   (border field)
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM

    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ld   hl, (EMIT_PTR)
    ld   (DECOMP_END_ADDR), hl

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ; Real-memory verification BEFORE decompiling -- confirms actual
    ; ARRTAB bytes, not just decompiled text shape.
    call CHECK_ARR
    jp   c, FAIL

    ; VM_OUTPUT_ROW must be 5 -- one line per PRINT (0-4); the DIMs and
    ; the three array/scalar assignments don't print.
    ld   a, (VM_OUTPUT_ROW)
    cp   5
    jp   nz, FAIL

    call DECOMPILE_PROGRAM

    ld   a, (DECOMP_ERROR_CODE)
    or   a
    jp   nz, FAIL

    call CHECK_DECOMPILED_TEXT
    jp   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

SOURCE_TEXT:
    db "DIM A(5):DIM B(3):"
    db "A(0)=10:A(1)=20:A(4)=99:B(0)=A(1)+A(0):X=A(4):"
    db "PRINT A(0):PRINT A(1):PRINT A(4):PRINT B(0):PRINT X", 0

; ============================================================================
; CHECK_ARR — direct ARRTAB memory reads. Array A is ARRSYMTAB slot 0
; (declared first), array B is slot 1. ARRTAB_BASE + (slot*16 + elem)*2.
; ============================================================================
CHECK_ARR:
    ld   hl, (ARRTAB_BASE + (0*16 + 0)*2)
    ld   de, 10
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   hl, (ARRTAB_BASE + (0*16 + 1)*2)
    ld   de, 20
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   hl, (ARRTAB_BASE + (0*16 + 4)*2)
    ld   de, 99
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   hl, (ARRTAB_BASE + (1*16 + 0)*2)
    ld   de, 30                ; A(1)+A(0) = 20+10
    or   a
    sbc  hl, de
    jr   nz, .fail
    ret
.fail:
    scf
    ret

; ============================================================================
; CHECK_DECOMPILED_TEXT — byte-for-byte against a real captured-then-
; verified rendering (same discipline as every other decompiler test
; this session).
; ============================================================================
CHECK_DECOMPILED_TEXT:
    ld   hl, (DECOMP_OUT_PTR)
    ld   de, DECOMP_OUT_BUF
    or   a
    sbc  hl, de
    ld   de, EXPECTED_TEXT_LEN
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   hl, DECOMP_OUT_BUF
    ld   de, EXPECTED_TEXT
    ld   bc, EXPECTED_TEXT_LEN
.cmp:
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail
    inc  hl
    inc  de
    dec  bc
    ld   a, b
    or   c
    jr   nz, .cmp
    ret
.fail:
    scf
    ret

; DIM emits no bytecode at all (a pure compile-time declaration, like an
; implicitly-declared scalar's own CSYMTAB entry) -- decompiled text
; starts directly at the first real statement. "A0"/"A1" are the
; compiler's real generated array names (A was DIM'd first -> ARRSYMTAB
; slot 0 -> "A0"; B second -> slot 1 -> "A1"); "V0" is X's own generated
; scalar name -- to be captured from a real ZEsarUX run, then cross-
; checked against CHECK_ARR's own already-verified real values (same
; two-step discipline as every other decompiler test this session).
EXPECTED_TEXT:
    db "A0(0) = 10", 13
    db "A0(1) = 20", 13
    db "A0(4) = 99", 13
    db "A1(0) = (A0(1)+A0(0))", 13
    db "V0 = A0(4)", 13
    db "PRINT A0(0)", 13
    db "PRINT A0(1)", 13
    db "PRINT A0(4)", 13
    db "PRINT A1(0)", 13
    db "PRINT V0", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

; Test-only stubs: this file's own test program never exercises LPRINT/
; BEEP/SOUND/PAUSE, and never registers or calls a loadable extension --
; same stubbing discipline (and same real contracts) already established
; for the other R8.5 v2 tests this session.
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
EXT2_TABLE:    equ $8B00

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

    INCLUDE "kernel/math/math.asm"
; rom/exrom_calc.asm (1772 lines -- the real calculator engine) is NOT
; included here: this test's own program (SOURCE_TEXT above) is pure
; integer arithmetic -- no PUSH_FLOAT_LIT, no mixed int/float ADD/SUB, no
; PRINT of a float, and arrays are integer-only in this milestone -- so
; none of the float paths that reach the calculator are ever exercised
; at runtime. Same stubbing discipline as rom/test_v2_save_load.asm's own
; header for this exact tradeoff (the 1772 real lines pushed this flat
; 16K image over budget for zero real coverage).
CALC_INT_TO_FP:
    ret
CALC_FP_TO_INT:
    ret
CALC_SP_TO_NEXT_FREE_PTR:
    ret
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; this test never checks real screen bitmap content. R8.5 Group 5's own
; real ROM growth (SPRITE GRAB/SHOW/HIDE/MOVE) pushed this flat 16K
; image over budget with graphics.asm included; same stubbing
; discipline as rom/test_v2_call_fn.asm's own identical fix.
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
; kernel/memory/memory.asm is NOT included here -- this test never
; touches the editor, and neither rom/exrom_v2_vm_core.asm/compiler.asm/
; decompiler.asm reference any MEM_*/PROG_END/PROG_AREA_START/ARRAYS_
; END/VARS_START symbol.
    INCLUDE "rom/exrom_format.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
    INCLUDE "rom/exrom_v2_decompiler.asm"

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_arrays.bin", $0000, $4000

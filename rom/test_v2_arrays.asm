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
; test-infrastructure fix, docs/v2/POST_R9_TEST_INFRASTRUCTURE.md).
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

    DEFINE TEST_V2_NEEDS_DECOMPILE
    DEFINE TEST_V2_CHECK_DECOMPILED_TEXT
    INCLUDE "rom/test_v2_harness_home_head.inc"

SOURCE_TEXT:
    db "DIM A(5):DIM B(3):"
    db "A(0)=10:A(1)=20:A(4)=99:B(0)=A(1)+A(0):X=A(4):"
    db "Y=DIMN(A):Z=DIMN(B):"
    db "PRINT A(0):PRINT A(1):PRINT A(4):PRINT B(0):PRINT X", 0

; ============================================================================
; TEST_CHECK_RESULT — direct ARRTAB memory reads (array A is ARRSYMTAB
; slot 0, array B is slot 1; ARRTAB_BASE + (slot*16 + elem)*2), then
; DIMN's own SYMTAB values (Y=DIMN(A)=5, Z=DIMN(B)=3 -- numeric symbol
; declaration order: X=0, Y=1, Z=2), then VM_OUTPUT_ROW (must be 5 --
; one line per PRINT (0-4); the DIMs and the three array/scalar
; assignments don't print).
; ============================================================================
TEST_CHECK_RESULT:
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
    ld   hl, SYMTAB_BASE + 1*3 + 1
    ld   a, (hl)
    cp   5
    jr   nz, .fail
    inc  hl
    ld   a, (hl)
    or   a
    jr   nz, .fail
    ld   hl, SYMTAB_BASE + 2*3 + 1
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

; ============================================================================
; TEST_CHECK_DECOMPILED — byte-for-byte against a real captured-then-
; verified rendering (same discipline as every other decompiler test).
; DIM itself still emits no bytecode at all (a pure compile-time
; declaration, like an implicitly-declared scalar's own CSYMTAB entry).
; Post-R9 DIM/decompiler correction (docs/v2/V2_SEMANTIC_CAPABILITY_
; AUDIT.md S14): the decompiler recovers each array's own declared size
; from the first OP_ARR_LOAD/STORE instruction that references it (every
; such instruction already bakes its own array's size in as a bounds-
; check operand) and synthesizes "DIM A<idx>(<size>)" lines up front,
; since bytecode carries no position for the original DIM statement(s).
; "A0"/"A1" are the compiler's real generated array names (A was DIM'd
; first -> ARRSYMTAB slot 0 -> "A0"; B second -> slot 1 -> "A1"); "V0"/
; "V1"/"V2" are X/Y/Z's own generated scalar names. "V1 = 5"/"V2 = 3"
; (not "DIMN(A0)"/"DIMN(A1)") are DIMN's own documented, deliberate
; decompile-fidelity limitation -- see COMPILE_DIMN's own header in rom/
; exrom_v2_compiler.asm: DIMN folds to a bare PUSH_I8 literal with no
; runtime opcode, so the fact that this value came from a DIMN() call is
; genuinely gone from the bytecode.
; ============================================================================
TEST_CHECK_DECOMPILED:
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

EXPECTED_TEXT:
    db "DIM A0(5)", 13
    db "DIM A1(3)", 13
    db "A0(0) = 10", 13
    db "A0(1) = 20", 13
    db "A0(4) = 99", 13
    db "A1(0) = (A0(1)+A0(0))", 13
    db "V0 = A0(4)", 13
    db "V1 = 5", 13
    db "V2 = 3", 13
    db "PRINT A0(0)", 13
    db "PRINT A0(1)", 13
    db "PRINT A0(4)", 13
    db "PRINT A1(0)", 13
    db "PRINT V0", 13
EXPECTED_TEXT_LEN: equ $-EXPECTED_TEXT

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

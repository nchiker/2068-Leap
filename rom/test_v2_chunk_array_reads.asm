; ============================================================================
; rom/test_v2_chunk_array_reads.asm -- R10.7 P3 regression test for a latent bug.
;
; DEFECT (found by the 40-array production run while sizing the run tables; it
; predates this milestone): LEX_NEXT_TOKEN clobbers BC whenever it refills the
; chunk buffer, but COMPILE_ARR_READ_COMMON keeps the array INDEX in B across
; the call that consumes the closing ')'. When that consumption lands on a
; refill boundary the emitted ARR_LOAD operand had index 0, so the read
; silently returned array 0's element: "R7 = A7(2)" gave A1(2).
;
; This flat image stores 16 numeric arrays (DIM + element assignment) and then
; 16 reads, one authoritative record each, so successive reads walk across
; every alignment of the 264-byte chunk window against the refill margin.
; Every R<k> must equal k.
; ============================================================================

    INCLUDE "include/hardware.inc"
    DEFINE V2_COMPACT_SYSVARS   ; R10.7 P5: drop V1-only sysvars (see include/sysvars.inc)
    INCLUDE "include/sysvars.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    INCLUDE "rom/v2_rst_vectors.inc"   ; QUAL shrink: RST call vectors
    INCLUDE "rom/v2_rst30.inc"         ; QUAL shrink: RST $30 (ends at $0038)
RST_38:
    ei
    reti
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call MEM_COLD_INIT

    ld   hl, PROGRAM
    ld   de, PROG_AREA_START
    ld   bc, PROGRAM_END - PROGRAM
    ldir
    ld   hl, PROG_AREA_START
    ld   de, PROGRAM_END - PROGRAM
    add  hl, de
    ld   (PROG_END), hl
    call SET_ARENA_VARS
    call DO_BUILD_SOURCE
    call COMPILER_INIT
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

    ld   b, 16                   ; B = loop counter
    ld   c, 1                    ; C = k
.check:
    push bc
    ld   a, c
    call CHECK_R
    pop  bc
    jp   c, FAIL
    inc  c
    djnz .check

    ; ---- second program: an out-of-range READ must be caught (VM error 10).
    ; The emitted count operand used to be 128 (DE clobbered), so DIM B(4) /
    ; Q = B(10) read past the array instead of raising the bounds error.
    ld   hl, PROGRAM2
    ld   de, PROG_AREA_START
    ld   bc, PROGRAM2_END - PROGRAM2
    ldir
    ld   hl, PROG_AREA_START
    ld   de, PROGRAM2_END - PROGRAM2
    add  hl, de
    ld   (PROG_END), hl
    call SET_ARENA_VARS
    call DO_BUILD_SOURCE
    call COMPILER_INIT
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM
    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, FAIL
    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN
    ld   a, (VM_ERROR_CODE)
    cp   10
    jp   nz, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

; CHECK_R -- A = k: the numeric symbol "R<k>" must hold k. Carry set on mismatch.
CHECK_R:
    ld   (CR_K), a
    ld   hl, NAMEBUF             ; build "R" + decimal(k)
    ld   (hl), 'R'
    inc  hl
    ld   a, (CR_K)
    cp   10
    jr   c, .one
    ld   (hl), '1'
    inc  hl
    sub  10
    add  a, '0'
    ld   (hl), a
    ld   b, 3
    jr   .find
.one:
    add  a, '0'
    ld   (hl), a
    ld   b, 2
.find:
    ld   hl, NAMEBUF
    ld   c, SYM_K_NUM
    call SYM_FIND
    jr   c, .bad
    call VM_SYM_ADDR
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   a, (CR_K)
    ld   l, a
    ld   h, 0
    or   a
    sbc  hl, de
    ret  z
.bad:
    scf
    ret

CR_K:     equ $9B00
NAMEBUF:  equ $9B02

; ============================================================================
; DO_BUILD_SOURCE / SET_ARENA_VARS -- exactly what production's own
; V2_BUILD_SOURCE / MEM_INIT_V2 (rom/exrom_v2_shell.asm) do, inlined here
; since that file is EXROM-resident shell code this flat test doesn't
; link (same as rom/test_v2_chunk_refill_boundary.asm's own precedent).
; ============================================================================
DO_BUILD_SOURCE:
    call MEM_LINE_FIRST
    ld   (CHUNK_NEXT_REC), hl
    ld   hl, CHUNK_BUF
    ld   (SRC_PTR), hl
    ld   (CHUNK_FILL_PTR), hl
    jp   CHUNK_REFILL

SET_ARENA_VARS:
    ld   (ARRAYS_END), hl
    ld   hl, V2_SOURCE_END
    ld   (VARS_START), hl
    ret

; ============================================================================
; CHECK_INT_VAR -- identical to rom/test_v2_chunk_refill_boundary.asm's
; own routine (CSYMTAB name scan -> SYMTAB value compare). Duplicated
; here rather than shared across files, matching this project's own
; existing convention of each standalone test being self-contained.
; In: HL = [len:1][name...], DE = expected value. Out: carry clear if
; found+TAG_INT+matches; carry set otherwise. Destroys: AF, BC, DE, HL.

PROGRAM:
    DW 10
    DB "DIM A1(4)", 13
    DW 10
    DB "A1(2) = 1", 13
    DW 10
    DB "DIM A2(4)", 13
    DW 10
    DB "A2(2) = 2", 13
    DW 10
    DB "DIM A3(4)", 13
    DW 10
    DB "A3(2) = 3", 13
    DW 10
    DB "DIM A4(4)", 13
    DW 10
    DB "A4(2) = 4", 13
    DW 10
    DB "DIM A5(4)", 13
    DW 10
    DB "A5(2) = 5", 13
    DW 10
    DB "DIM A6(4)", 13
    DW 10
    DB "A6(2) = 6", 13
    DW 10
    DB "DIM A7(4)", 13
    DW 10
    DB "A7(2) = 7", 13
    DW 10
    DB "DIM A8(4)", 13
    DW 10
    DB "A8(2) = 8", 13
    DW 10
    DB "DIM A9(4)", 13
    DW 10
    DB "A9(2) = 9", 13
    DW 11
    DB "DIM A10(4)", 13
    DW 12
    DB "A10(2) = 10", 13
    DW 11
    DB "DIM A11(4)", 13
    DW 12
    DB "A11(2) = 11", 13
    DW 11
    DB "DIM A12(4)", 13
    DW 12
    DB "A12(2) = 12", 13
    DW 11
    DB "DIM A13(4)", 13
    DW 12
    DB "A13(2) = 13", 13
    DW 11
    DB "DIM A14(4)", 13
    DW 12
    DB "A14(2) = 14", 13
    DW 11
    DB "DIM A15(4)", 13
    DW 12
    DB "A15(2) = 15", 13
    DW 11
    DB "DIM A16(4)", 13
    DW 12
    DB "A16(2) = 16", 13
    DW 11
    DB "R1 = A1(2)", 13
    DW 11
    DB "R2 = A2(2)", 13
    DW 11
    DB "R3 = A3(2)", 13
    DW 11
    DB "R4 = A4(2)", 13
    DW 11
    DB "R5 = A5(2)", 13
    DW 11
    DB "R6 = A6(2)", 13
    DW 11
    DB "R7 = A7(2)", 13
    DW 11
    DB "R8 = A8(2)", 13
    DW 11
    DB "R9 = A9(2)", 13
    DW 13
    DB "R10 = A10(2)", 13
    DW 13
    DB "R11 = A11(2)", 13
    DW 13
    DB "R12 = A12(2)", 13
    DW 13
    DB "R13 = A13(2)", 13
    DW 13
    DB "R14 = A14(2)", 13
    DW 13
    DB "R15 = A15(2)", 13
    DW 13
    DB "R16 = A16(2)", 13
PROGRAM_END:

PROGRAM2:
    DW 9
    DB "DIM B(4)", 13
    DW 10
    DB "Q = B(10)", 13
PROGRAM2_END:


; Local stubs for production EXROM-resident entry points this flat
; single-bank test doesn't link -- same stubbing discipline rom/test_v2_
; chunk_refill_boundary.asm's own header already established.
DECOMP_END_ADDR: DW 0
MEM_CLEAR_V2:
    ret
KTAB_CALC_EXIT_TRAMPOLINE:
    ret
IO_READ_KEY:
SOUND_BEEP:
SOUND_EXROM:
INT_GET_FRAMES:
EXT_CALL_ARG0:
EXT_CALL_ARG4:
EXT2_SLOT_ADDR:
BASIC_NUM_TO_STRING_EXROM:
BASIC_FLOAT_TO_STRING_EXROM:
GFX_PRINT_STRING_ATTR:
GFX_CLS:
GFX_PAINT_ATTR:
GFX_SET_BORDER:
GFX_WRITE_PIXEL:
GFX_LINE:
GFX_SCROLL_OUTPUT_UP:
GFX_READ_PIXEL:
GFX_CELL_ATTR_ADDR:
    ret
EXT2_LOOKUP:
    scf
    ret
IO_READ_KEY_NONBLOCK:
    xor  a
    ret

    INCLUDE "kernel/memory/memory.asm"
    INCLUDE "kernel/bank/bank.asm"
    INCLUDE "kernel/math/math.asm"
    INCLUDE "rom/exrom_calc.asm"
    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/test_v2_local_dim.inc"   ; R10.9 2C: test-only DIM handlers
    INCLUDE "rom/exrom_v2_compiler.asm"

    DS   $4000 - $, $FF
    SAVEBIN "test_v2_chunk_array_reads.bin", $0000, $4000


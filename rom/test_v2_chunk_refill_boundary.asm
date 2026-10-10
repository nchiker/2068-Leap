; ============================================================================
; rom/test_v2_chunk_refill_boundary.asm — R10.7 source-staging-architecture
; change (docs/v2/R10_7_SOURCE_STAGING_ARCHITECTURE_AUDIT.md): boundary
; coverage for the new CHUNK_SIZE=264/CHUNK_MARGIN=128 rolling-window
; compiler-input mechanism that replaced V2_SOURCE_STAGE's old full
; 4096-byte flatten.
;
; Unlike every other rom/test_v2_*.asm standalone test, this one does NOT
; set SRC_PTR directly to a SOURCE_TEXT buffer -- that bypasses chunking
; entirely (SRC_PTR outside [CHUNK_BUF, CHUNK_BUF+CHUNK_SIZE) is exactly
; the condition LEX_NEXT_TOKEN's own refill gate treats as "not chunked,
; skip"). This test hand-builds a REAL authoritative line-store program
; (length-prefixed records, same format KTAB_MEM_LINE_INSERT/MEM_LINE_
; NEXT use) directly at PROG_AREA_START, then drives exactly what V2_
; BUILD_SOURCE does (prime CHUNK_NEXT_REC/CHUNK_FILL_PTR/SRC_PTR, call
; CHUNK_REFILL) before compiling -- genuinely exercising the refill
; mechanism, not just the lexer's already-proven grammar.
;
; Flat single-bank build (same convention as rom/test_v2_vm_milestone01.
; asm, rom/test_v2_relational.asm) -- includes kernel/memory/memory.asm
; (so KERNEL_MEMORY_PRESENT is defined and CHUNK_APPEND_ONE_RECORD's real
; MEM_LINE_NEXT call is live, and MEM_LINE_FIRST/NEXT are directly
; callable, same bank, no KTAB needed here).
;
; TEST1 (main refill-stress program): three consecutive maximum-length
; (127 text chars) records, the first two colon-joined (two joins
; suppressed, proving multi-max-record colon continuation), then a
; feature sweep -- relational operators (<=, <>), IF/THEN/ELSE/ENDIF,
; FOR/NEXT, a forward GOTO label (fixup), a numeric array, PROC/CALL
; recursion, DEF FN, and a final three-record colon-continuation chain
; (Q=1: / Q=Q+1: / Q=Q+1) spread across separate physical records so the
; chain itself crosses a refill. Checked by walking CSYMTAB to find each
; variable by name, not a hand-counted SYMTAB offset.
;
; TEST2: true EOF / empty program (zero stored records) -- RUN must not
; crash; VM_ERROR_CODE must be 0 (a HALT-only program).
;
; TEST3: an unterminated string literal deliberately spanning three
; records -- must return (not hang), same graceful-degradation contract
; this mechanism was built to preserve.
;
; TEST4: a deliberate compile error, checking that CHUNK_CUR_REC_PTR (the
; state V2_JUMP_TO_ERROR_LINE now uses instead of a byte-offset walk)
; names the authoritative record actually containing the bad token.
;
; TEST5 (source preservation): byte-compares the authoritative line-store
; region used by TEST1, before vs. after that RUN, proving neither V2_
; BUILD_SOURCE's replacement nor CHUNK_REFILL ever write back into
; authoritative source.
; ============================================================================

    INCLUDE "include/hardware.inc"
    DEFINE V2_COMPACT_SYSVARS   ; R10.7 P5: drop V1-only sysvars (see include/sysvars.inc)
    INCLUDE "include/sysvars.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0038 - $, $FF
RST_38:
    ei
    reti
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call MEM_COLD_INIT

    ; --- TEST1: build the authoritative program in the line store ---
    ld   hl, TEST1_PROGRAM
    ld   de, PROG_AREA_START
    ld   bc, TEST1_PROGRAM_END - TEST1_PROGRAM
    ldir
    ld   hl, PROG_AREA_START
    ld   de, TEST1_PROGRAM_END - TEST1_PROGRAM
    add  hl, de
    ld   (PROG_END), hl
    call SET_ARENA_VARS

    ; snapshot authoritative source before RUN (TEST5)
    ld   hl, PROG_AREA_START
    ld   de, SNAPSHOT_BEFORE
    ld   bc, TEST1_PROGRAM_END - TEST1_PROGRAM
    ldir

    call COMPILE_STORED
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

    ; source preservation (TEST5): authoritative bytes must be unchanged
    ld   hl, PROG_AREA_START
    ld   de, SNAPSHOT_BEFORE
    ld   bc, TEST1_PROGRAM_END - TEST1_PROGRAM
    call MEMCMP
    jp   nz, FAIL

    ; per-variable checks, by name
    ld   hl, NAME_P
    ld   de, 3
    call CHECK_INT_VAR
    jp   c, FAIL

    ld   hl, NAME_F
    ld   de, 15
    call CHECK_INT_VAR
    jp   c, FAIL

    ld   hl, NAME_G
    ld   de, 42
    call CHECK_INT_VAR
    jp   c, FAIL

    ld   hl, NAME_R
    ld   de, 6
    call CHECK_INT_VAR
    jp   c, FAIL

    ld   hl, NAME_SQ16
    ld   de, 16
    call CHECK_INT_VAR
    jp   c, FAIL

    ld   hl, NAME_Q
    ld   de, 3
    call CHECK_INT_VAR
    jp   c, FAIL

    ; ---- TEST2: true EOF / empty program ----
    ld   hl, PROG_AREA_START
    ld   (PROG_END), hl
    call SET_ARENA_VARS
    call COMPILE_STORED
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

    ; ---- TEST3: unterminated string spanning three records ----
    ld   hl, TEST3_PROGRAM
    ld   de, PROG_AREA_START
    ld   bc, TEST3_PROGRAM_END - TEST3_PROGRAM
    ldir
    ld   hl, PROG_AREA_START
    ld   de, TEST3_PROGRAM_END - TEST3_PROGRAM
    add  hl, de
    ld   (PROG_END), hl
    call SET_ARENA_VARS
    call COMPILE_STORED         ; must return (not hang) -- reaching
                                  ; TEST4_SETUP below is the real assertion

    ; ---- TEST4: deliberate compile error + CHUNK_CUR_REC_PTR check ----
    ld   hl, TEST4_PROGRAM
    ld   de, PROG_AREA_START
    ld   bc, TEST4_PROGRAM_END - TEST4_PROGRAM
    ldir
    ld   hl, PROG_AREA_START
    ld   de, TEST4_PROGRAM_END - TEST4_PROGRAM
    add  hl, de
    ld   (PROG_END), hl
    call SET_ARENA_VARS
    call COMPILE_STORED
    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   z, FAIL                 ; this program MUST fail to compile

    ; walk the line store ourselves to find TEST4's second record (the
    ; one with the bad token) and compare its pointer to CHUNK_CUR_REC_PTR
    call MEM_LINE_FIRST
    call MEM_LINE_NEXT            ; HL = second record's own pointer
    ld   de, (CHUNK_CUR_REC_PTR)
    or   a
    sbc  hl, de
    jp   nz, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

; ============================================================================
; SET_ARENA_VARS -- exactly what production's own MEM_INIT_V2 (rom/
; exrom_v2_shell.asm) does for ARRAYS_END/VARS_START, inlined here since
; that file is EXROM-resident shell code this flat test doesn't link.
; Without this, VARS_START stays 0 (MEM_COLD_INIT just zeroes RAM), and
; OP_DIM's arena-exhaustion check ($ARRAYS_END+needed >= VARS_START)
; fails immediately for every array -- found live (VM_ERROR_CODE=16,
; VM_ERR_ARRAY_SPACE) via ts2068-debug, not an actual arena-exhaustion
; bug in the array code itself.
; In: HL = the just-set PROG_END value. Destroys: HL.
; ============================================================================
SET_ARENA_VARS:
    ld   (ARRAYS_END), hl
    ld   hl, V2_SOURCE_END
    ld   (VARS_START), hl
    ret

; ============================================================================
; COMPILE_STORED -- the shared "prime the chunk buffer from the stored program,
; reset the compiler, compile" sequence every TEST case below repeats (factored
; out in R10.7 P0 when HOME growth pushed this flat 16K image 15 bytes over).
; ============================================================================
COMPILE_STORED:
    call DO_BUILD_SOURCE
    call COMPILER_INIT
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    jp   COMPILE_PROGRAM

; ============================================================================
; DO_BUILD_SOURCE -- exactly what V2_BUILD_SOURCE (rom/exrom_v2_shell.asm)
; does, inlined here since that file is EXROM-resident shell code this
; flat single-bank test doesn't link.
; ============================================================================
DO_BUILD_SOURCE:
    call MEM_LINE_FIRST
    ld   (CHUNK_NEXT_REC), hl
    ld   hl, CHUNK_BUF
    ld   (SRC_PTR), hl
    ld   (CHUNK_FILL_PTR), hl
    jp   CHUNK_REFILL

; ============================================================================
; MEMCMP -- In: HL, DE = buffers, BC = length. Out: Z set if identical.
; Destroys: AF, BC, DE, HL.
; ============================================================================
MEMCMP:
.loop:
    ld   a, b
    or   c
    ret  z
    ld   a, (de)
    cp   (hl)
    ret  nz
    inc  hl
    inc  de
    dec  bc
    jr   .loop

; ============================================================================
; CHECK_INT_VAR -- finds a variable by name in CSYMTAB (the compile-time
; symbol table, which still holds names after compilation -- CSYM_REC_LEN
; =9, [name_len:1][name:8]) and compares its live SYMTAB_BASE record's
; value to the expected one.
; In:  HL = pointer to [len:1][name bytes...] (this file's NAME_* data),
;      DE = expected 16-bit value
; Out: carry clear if found, TAG_INT, and value matches; carry set
;      otherwise
; Destroys: AF, BC, DE, HL
; ============================================================================
CHECK_INT_VAR:
    ld   a, (hl)
    ld   (SEARCH_NAME_LEN), a
    inc  hl
    ld   (SEARCH_NAME_PTR), hl
    ld   (SEARCH_EXPECT), de
    ld   a, (SEARCH_NAME_LEN)    ; R10.7 P2: look the name up in the tagged
    ld   b, a                    ; symbol table (SYM_FIND) instead of walking a
    ld   hl, (SEARCH_NAME_PTR)   ; fixed 9-byte-record table by hand
    ld   c, SYM_K_NUM
    call SYM_FIND
    jr   c, .not_found
    ld   (SEARCH_INDEX), a
    jr   .found
.not_found:
    scf
    ret
.found:
    ld   a, (SEARCH_INDEX)
    ld   l, a
    ld   h, 0
    ld   d, h
    ld   e, l                     ; DE = index (1x)
    add  hl, hl                   ; HL = index*2
    add  hl, de                   ; HL = index*2 + index = index*3
    ld   de, (RT_SYMTAB_PTR)
    add  hl, de
    ld   a, (hl)
    cp   TAG_INT
    jr   nz, .mismatch
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   hl, (SEARCH_EXPECT)
    or   a
    sbc  hl, de
    ret  z
.mismatch:
    scf
    ret

; These must NOT be plain ROM-resident DB/DW data (this test's own first
; draft made exactly that mistake, the same already-documented lesson
; rom/test_v2_save_load.asm's own TEST_PROGRAM_LEN comment and this
; project's PRINT_ATTR_SCRATCH incident both warn about): $0000-$3FFF is
; this flat image's own write-protected Home ROM; `ld (addr),a` into it
; silently no-ops, so CHECK_INT_VAR's own writes never actually landed,
; and every lookup "failed" by always re-reading each cell's compile-
; time-initial value instead. Real RAM instead, well clear of
; SNAPSHOT_BEFORE's own 747-byte span ($9800-$9AEB).
SEARCH_NAME_LEN:  equ $9B00   ; 1 byte
SEARCH_NAME_PTR:  equ $9B01   ; 2 bytes
SEARCH_EXPECT:    equ $9B03   ; 2 bytes
SEARCH_INDEX:     equ $9B05   ; 1 byte

NAME_P:    DB 1, "P"
NAME_D:    DB 1, "D"
NAME_E:    DB 1, "E"
NAME_F:    DB 1, "F"
NAME_G:    DB 1, "G"
NAME_H:    DB 1, "H"
NAME_R:    DB 1, "R"
NAME_SQ16: DB 4, "SQ16"
NAME_Q:    DB 1, "Q"

SNAPSHOT_BEFORE: equ $9800   ; scratch, well clear of every VM table/
                              ; stack/registry workspace -- same address
                              ; rom/test_v2_ext_demo.asm already
                              ; established for this exact purpose

; ----------------------------------------------------------------------
; TEST1_PROGRAM -- hand-built line-store records: [len_lo][len_hi]
; [content...][$0D]. len = content byte count, INCLUDING the trailing
; $0D (matches V2_BLANK_RECORD's own "DB 1,0,$0D" convention: length 1
; for a record whose only content byte is the CR itself).
; ----------------------------------------------------------------------
TEST1_PROGRAM:
; three consecutive maximum-length (127 text char) records; the first
; two end in ':' (colon continuation, suppressed separator); the third
; ends in a space (ordinary record end, real separator follows).
    DW REC1_END - REC1
REC1:
    DB "P=1"
    DS 123, ' '
    DB ":", $0D
REC1_END:
    DW REC2_END - REC2
REC2:
    DB "P=P+1"
    DS 121, ' '
    DB ":", $0D
REC2_END:
    DW REC3_END - REC3
REC3:
    DB "P=P+1"
    DS 121, ' '
    DB $0D
REC3_END:
    DW REC4_END - REC4
REC4:
    DB "A=5:B=3", $0D
REC4_END:
    DW REC5_END - REC5
REC5:
    DB "IF A>B THEN C=1 ELSE C=2 ENDIF", $0D
REC5_END:
    DW REC6_END - REC6
REC6:
    DB "IF A<=3 THEN D=1 ELSE D=0 ENDIF", $0D
REC6_END:
    DW REC7_END - REC7
REC7:
    DB "IF A<>B THEN E=1 ELSE E=0 ENDIF", $0D
REC7_END:
    DW REC8_END - REC8
REC8:
    DB "F=0:FOR I=1 TO 5:F=F+I:NEXT I", $0D
REC8_END:
    DW REC9_END - REC9
REC9:
    DB "GOTO SKIP:G=999:SKIP:G=42", $0D
REC9_END:
    DW REC10_END - REC10
REC10:
    DB "DIM ARR(3):ARR(0)=7:ARR(1)=8:H=ARR(0)+ARR(1)", $0D
REC10_END:
    DW REC11_END - REC11
REC11:
    DB "PROC COUNT(N):IF N>0 THEN CALL COUNT(N-1) ENDIF:R=R+N:ENDP", $0D
REC11_END:
    DW REC12_END - REC12
REC12:
    DB "R=0:CALL COUNT(3)", $0D
REC12_END:
    DW REC13_END - REC13
REC13:
    DB "DEF FN SQ(X)=X*X", $0D
REC13_END:
    DW REC14_END - REC14
REC14:
    DB "SQ16=FN SQ(4)", $0D
REC14_END:
    DW REC15_END - REC15
REC15:
    DB "Q=1:", $0D
REC15_END:
    DW REC16_END - REC16
REC16:
    DB "Q=Q+1:", $0D
REC16_END:
    DW REC17_END - REC17
REC17:
    DB "Q=Q+1", $0D
REC17_END:
TEST1_PROGRAM_END:

; ----------------------------------------------------------------------
; TEST3_PROGRAM -- an unterminated string literal spanning three records.
; ----------------------------------------------------------------------
TEST3_PROGRAM:
    DW T3R1_END - T3R1
T3R1:
    DB 'Z$="UNTERMINATED', $0D
T3R1_END:
    DW T3R2_END - T3R2
T3R2:
    DB "MORE TEXT ON THE NEXT LINE", $0D
T3R2_END:
    DW T3R3_END - T3R3
T3R3:
    DB "AND A THIRD LINE TOO", $0D
T3R3_END:
TEST3_PROGRAM_END:

; ----------------------------------------------------------------------
; TEST4_PROGRAM -- a deliberate compile error on the second record.
; ----------------------------------------------------------------------
TEST4_PROGRAM:
    DW T4R1_END - T4R1
T4R1:
    DB "A=1", $0D
T4R1_END:
    DW T4R2_END - T4R2
T4R2:
    DB "A=*1", $0D                ; bad token: '*' cannot start an
                                   ; expression -- syntax error here
T4R2_END:
TEST4_PROGRAM_END:

; Local stubs for production EXROM-resident entry points this flat
; single-bank test doesn't link (same stubbing discipline rom/test_v2_
; vm_milestone01.asm's own header already established for these exact
; symbols -- none of them are reachable from this test's own program).
DECOMP_END_ADDR: DW 0
MEM_CLEAR_V2:
    ret
KTAB_CALC_EXIT_TRAMPOLINE:
    ret
; None of the stubs below are reachable from this test's own program
; (no INKEY$/PRINT/SOUND/FRAMES/EXT2 package use) -- same stubbing
; discipline as MEM_CLEAR_V2 above, used only to satisfy the linker
; since kernel/io, kernel/sound, kernel/interrupt, kernel/extensions,
; and rom/exrom_format aren't included here (keeping this flat image
; under its 16K cap).
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
; These two have a carry-flag contract their real callers actually test
; (EXT2_LOOKUP: carry set = no match, checked by COMPILE_STATEMENT_LIST's
; own extension-keyword lookahead before every single identifier
; statement; IO_READ_KEY_NONBLOCK: carry clear = a key is latched) -- a
; bare `ret` leaves carry at whatever it happened to be from the caller's
; own prior instruction, which silently misrouted "P" into COMPILE_EXT_
; CALL instead of a plain assignment the first time this test ran.
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
    INCLUDE "rom/exrom_v2_compiler.asm"

    DS   $4000 - $, $FF
    SAVEBIN "test_v2_chunk_refill_boundary.bin", $0000, $4000

; ============================================================================
; rom/test_v2_chunk_boundary_values.asm — R10.7 source-staging-architecture
; follow-up (docs/R10_7_SOURCE_STAGING_ARCHITECTURE_AUDIT.md §8.5):
; closes the two residual gaps the original rom/test_v2_chunk_refill_
; boundary.asm test flagged but didn't directly prove:
;
; TEST A: a long string literal (the longest a record can hold) that
; starts as the very first token after a refill. R10.9 Phase 2D changed
; the scenario this used to cover: a string can no longer span records
; (an unterminated string is a compile error on its own line), so
; LEX_SCAN_STRING has no mid-scan refill and the "closing quote is the
; first byte of a freshly-refilled chunk" case cannot occur any more.
; What remains to prove is that a maximal one-record string compiled
; straight after a refill is scanned whole and that parsing resumes
; after its closing quote. Engineered, not probabilistic: the padding
; record's appended length is exactly CHUNK_MARGIN (128), so priming
; stops after it and the string's first token triggers a fresh refill.
;
; TEST B: numeric AND string array element values, asserted (not merely
; "compiled and ran without error"), for a DIM+assign+read sequence that
; is compiled immediately after a refill.
;
; Same flat single-bank harness convention as rom/test_v2_chunk_refill_
; boundary.asm (kernel/memory+bank+math+calc+vm_core+compiler only, with
; the same local stubs for sound/io/interrupt/ext/graphics/format this
; flat image doesn't link) -- see that file's own header for why.
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
    INCLUDE "rom/v2_rst_vectors.inc"   ; QUAL shrink: RST call vectors
    INCLUDE "rom/v2_rst30.inc"         ; QUAL shrink: RST $30 (ends at $0038)
RST_38:
    ei
    reti
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00
    call MEM_COLD_INIT

    ; ---- TEST A: closing quote exactly at the refill boundary ----
    ld   hl, TESTA_PROGRAM
    ld   de, PROG_AREA_START
    ld   bc, TESTA_PROGRAM_END - TESTA_PROGRAM
    ldir
    ld   hl, PROG_AREA_START
    ld   de, TESTA_PROGRAM_END - TESTA_PROGRAM
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

    ; Y must be 1 -- only reachable if the compiler correctly resumed
    ; parsing right after the boundary-straddling string literal.
    ld   hl, NAME_Y
    ld   de, 1
    call CHECK_INT_VAR
    jp   c, FAIL

    ; X$'s stored length must be 31: RC (L3) -- the literal is the longest one
    ; accepted (a longer literal used to be cut to 31 silently; now it is compile
    ; error 70, TEST A2 below).
    xor  a                       ; X$ = STRSYMTAB/STRTAB index 0
    call STRLEN_AT_INDEX
    cp   31
    jp   nz, FAIL

    ; ---- TEST A2 (RC, L3): the original 118-byte literal straight after a refill ----
    ; It must be compile error 70 (literal too long). That code also proves the
    ; lexer scanned all 118 filler bytes to the real closing quote: a scan that
    ; stopped early would be error 64 (unterminated string) instead.
    ld   hl, TESTA2_PROGRAM
    ld   de, PROG_AREA_START
    ld   bc, TESTA2_PROGRAM_END - TESTA2_PROGRAM
    ldir
    ld   hl, PROG_AREA_START
    ld   de, TESTA2_PROGRAM_END - TESTA2_PROGRAM
    add  hl, de
    ld   (PROG_END), hl
    call SET_ARENA_VARS
    call DO_BUILD_SOURCE
    call COMPILER_INIT
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM
    ld   a, (COMPILE_ERROR_CODE)
    cp   70
    jp   nz, FAIL

    ; ---- TEST B: array element values across a refill ----
    ld   hl, TESTB_PROGRAM
    ld   de, PROG_AREA_START
    ld   bc, TESTB_PROGRAM_END - TESTB_PROGRAM
    ldir
    ld   hl, PROG_AREA_START
    ld   de, TESTB_PROGRAM_END - TESTB_PROGRAM
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

    ld   hl, NAME_NC1
    ld   de, 11
    call CHECK_INT_VAR
    jp   c, FAIL

    ld   hl, NAME_NC2
    ld   de, 22
    call CHECK_INT_VAR
    jp   c, FAIL

    ld   hl, NAME_NN
    ld   de, 33
    call CHECK_INT_VAR
    jp   c, FAIL

    ld   hl, NAME_NS1
    ld   de, EXPECT_HELLO
    ld   a, EXPECT_HELLO_LEN
    call CHECK_STR_VAR
    jp   c, FAIL

    ld   hl, NAME_NS2
    ld   de, EXPECT_WORLDWO
    ld   a, EXPECT_WORLDWO_LEN
    call CHECK_STR_VAR
    jp   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

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
    ld   e, l
    add  hl, hl
    add  hl, de                   ; HL = index*3
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

; ============================================================================
; CHECK_STR_VAR -- same name-scan shape as CHECK_INT_VAR, but against
; STRSYMTAB/STRTAB (STRSYM_REC_LEN=9: [name_len:1][name:8]; STRTAB
; records are [len:1][content:31] = 32B).
; In: HL = [len:1][name...], DE = expected content ptr, A = expected len.
; Out: carry clear if found and content matches; carry set otherwise.
; Destroys: AF, BC, DE, HL.
; ============================================================================
CHECK_STR_VAR:
    push af
    ld   a, (hl)
    ld   (SEARCH_NAME_LEN), a
    inc  hl
    ld   (SEARCH_NAME_PTR), hl
    ld   (SEARCH_EXPECT), de
    pop  af
    ld   (SEARCH_EXPECT_LEN), a
    ld   a, (SEARCH_NAME_LEN)    ; R10.7 P2: look the name up in the tagged
    ld   b, a                    ; symbol table (SYM_FIND) instead of walking a
    ld   hl, (SEARCH_NAME_PTR)   ; fixed 9-byte-record table by hand
    ld   c, SYM_K_STR
    call SYM_FIND
    jr   c, .not_found
    ld   (SEARCH_INDEX), a
    jr   .found
.not_found:
    scf
    ret
.found:
    ld   a, (SEARCH_INDEX)
    call STRTAB_ADDR_FOR_INDEX    ; HL = STRTAB record address
    ld   a, (SEARCH_EXPECT_LEN)
    cp   (hl)
    jr   nz, .mismatch
    inc  hl
    ld   de, (SEARCH_EXPECT)
    ld   b, a
    or   a
    jr   z, .strmatch
.strcmp:
    ld   a, (de)
    cp   (hl)
    jr   nz, .mismatch
    inc  hl
    inc  de
    djnz .strcmp
.strmatch:
    or   a
    ret
.mismatch:
    scf
    ret

; STRLEN_AT_INDEX -- In: A = STRTAB index. Out: A = that string's stored
; length byte. Destroys: HL.
STRLEN_AT_INDEX:
    call STRTAB_ADDR_FOR_INDEX
    ld   a, (hl)
    ret

; STRTAB_ADDR_FOR_INDEX -- In: A = index. Out: HL = STRTAB_BASE+index*32.
; Destroys: AF.
STRTAB_ADDR_FOR_INDEX:
    push bc
    ld   l, a
    ld   h, 0
    ld   b, h
    ld   c, l
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl
    add  hl, hl                   ; HL = index*32
    ld   bc, (RT_STRTAB_PTR)
    add  hl, bc
    pop  bc
    ret

SEARCH_NAME_LEN:    equ $9B00
SEARCH_NAME_PTR:    equ $9B01
SEARCH_EXPECT:      equ $9B03
SEARCH_INDEX:        equ $9B05
SEARCH_EXPECT_LEN:   equ $9B06

NAME_Y:   DB 1, "Y"
NAME_NC1: DB 3, "NC1"
NAME_NC2: DB 3, "NC2"
NAME_NN:  DB 2, "NN"
NAME_NS1: DB 3, "NS1"
NAME_NS2: DB 3, "NS2"

EXPECT_HELLO:     DB "HELLO"
EXPECT_HELLO_LEN: equ 5
EXPECT_WORLDWO:     DB "WORLDWO"
EXPECT_WORLDWO_LEN: equ 7

; ----------------------------------------------------------------------
; TESTA_PROGRAM -- RECA1 is padding: `Q=1` + 124 spaces = 127 content bytes,
; not ending in ':', so CHUNK_APPEND_ONE_RECORD appends a real $0D after it.
; Appended length = 127+1 = 128 = CHUNK_MARGIN exactly -- CHUNK_REFILL's
; priming loop stops right here (128 >= 128), so the chunk buffer holds only
; this record when compilation starts and the first token of RECA2 triggers a
; fresh refill. RECA2 is the longest record the editor allows (127 content
; bytes): `X$="`, 118 dots, `":Y=1`. LEX_SCAN_STRING must scan the 118 bytes
; without any mid-scan refill (the whole record is in the buffer) and parsing
; must resume at `:Y=1`.
; ----------------------------------------------------------------------
TESTA_PROGRAM:
    DW RECA1_END - RECA1
RECA1:
    DB "Q=1"
    DS 124, ' '                  ; 127 content bytes + CR = 128 = CHUNK_MARGIN
    DB $0D
RECA1_END:
    DW RECA2_END - RECA2
RECA2:
    DB 'X$="'
    DS 31, '.'                   ; RC (L3): the longest literal accepted
    DB '":Y=1', $0D
RECA2_END:
TESTA_PROGRAM_END:

; TESTA2_PROGRAM -- the same refill engineering with the original maximal record
; (127 content bytes: the longest record the editor allows): a 118-byte literal.
TESTA2_PROGRAM:
    DW RECA21_END - RECA21
RECA21:
    DB "Q=1"
    DS 124, ' '
    DB $0D
RECA21_END:
    DW RECA22_END - RECA22
RECA22:
    DB 'X$="'
    DS 118, '.'
    DB '":Y=1', $0D
RECA22_END:
TESTA2_PROGRAM_END:

; ----------------------------------------------------------------------
; TESTB_PROGRAM -- RECB_PAD's content is exactly 127 bytes ("Q=1" + 124
; spaces, not colon-terminated), appended length 128 = CHUNK_MARGIN
; exactly, so priming stops right after it (same mechanism as TESTA's
; RECA1). The very next token (the "DIM" that opens RECB1) therefore
; triggers a fresh refill before the array-defining statement sequence
; is compiled at all -- DIM/assign/read for both a numeric and a string
; array are compiled and run entirely from freshly-refilled chunk data.
; ----------------------------------------------------------------------
TESTB_PROGRAM:
    DW RECB_PAD_END - RECB_PAD
RECB_PAD:
    DB "Q=1"
    DS 124, ' '
    DB $0D
RECB_PAD_END:
    DW RECB1_END - RECB1
RECB1:
    DB "DIM NA(2):DIM SA$(2,8):NA(0)=11:NA(1)=22:", $0D
RECB1_END:
    DW RECB2_END - RECB2
RECB2:
    DB 'SA$(0)="HELLO":SA$(1)="WORLDWORLD":NC1=NA(0):NC2=NA(1):NN=NA(0)+NA(1):NS1$=SA$(0):NS2$=SA$(1)', $0D
RECB2_END:
TESTB_PROGRAM_END:

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
EXT_CALL_RESULT:
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
    SAVEBIN "test_v2_chunk_boundary_values.bin", $0000, $4000

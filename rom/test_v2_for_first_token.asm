; ============================================================================
; rom/test_v2_for_first_token.asm — minimal isolation test for the R10.7
; Phase 6 production-bug investigation: does "FOR i = 1 TO 20" / "PRINT i" /
; "NEXT i", stored as three SEPARATE (non-colon-joined) records with FOR as
; the literal first token of the whole program, compile cleanly through the
; real V2_BUILD_SOURCE/CHUNK_REFILL path? Live ts2068-debug reproduction
; against the production ROM showed COMPILE_ERROR_CODE=2 ("expected '='
; after identifier") for exactly this program; this isolates whether that
; is reproducible in a clean, uncontaminated environment, and whether it is
; specific to FOR being the program's first token (every passing chunk-
; refill test so far had FOR appear mid-record, after a colon-joined
; preceding statement, e.g. "F=0:FOR I=1 TO 5:...").
; ============================================================================

    INCLUDE "include/hardware.inc"
    DEFINE V2_COMPACT_SYSVARS   ; R10.7 P5: drop V1-only sysvars (see include/sysvars.inc)
    INCLUDE "include/sysvars.inc"

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

    ld   hl, PROGRAM
    ld   de, PROG_AREA_START
    ld   bc, PROGRAM_END - PROGRAM
    ldir
    ld   hl, PROG_AREA_START
    ld   de, PROGRAM_END - PROGRAM
    add  hl, de
    ld   (PROG_END), hl
    ld   (ARRAYS_END), hl
    ld   hl, V2_SOURCE_END
    ld   (VARS_START), hl

    call MEM_LINE_FIRST
    ld   (CHUNK_NEXT_REC), hl
    ld   hl, CHUNK_BUF
    ld   (SRC_PTR), hl
    ld   (CHUNK_FILL_PTR), hl
    call CHUNK_REFILL

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

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

; three SEPARATE records, FOR is the first token of the whole program.
PROGRAM:
    DB 16,0
    DB "FOR i = 1 TO 20", $0D
    DB 8,0
    DB "PRINT i", $0D
    DB 7,0
    DB "NEXT i", $0D
PROGRAM_END:

; stubs for symbols vm_core/compiler reference from modules this flat
; harness doesn't link (same convention as test_v2_chunk_refill_boundary.asm)
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
    INCLUDE "rom/exrom_v2_compiler.asm"

    DS   $4000 - $, $FF
    SAVEBIN "test_v2_for_first_token.bin", $0000, $4000

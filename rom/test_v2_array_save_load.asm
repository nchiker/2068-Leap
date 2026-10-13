; ============================================================================
; rom/test_v2_array_save_load.asm — Dynamic Data Phase 2: array
; persistence core-logic roundtrip test.
;
; Exercises the SAME lookup/serialize/allocate primitives rom/exrom_v2_
; shell.asm's V2_SAVE_ARRAY/V2_LOAD_ARRAY call (ARRSYM_LOOKUP, ARR_PTR_
; TABLE, ARENA_ALLOC_NUMERIC), directly, via the real STORAGE_SAVE/
; STORAGE_LOAD transport with the established deterministic test
; substitution (STORAGE_TEST_FAKE_SEND/RECEIVE -- same technique rom/
; test_v2_save_load.asm already validates this primitive with). Does
; NOT exercise rom/exrom_v2_shell.asm's own V2_SAVE_ARRAY/V2_LOAD_ARRAY/
; V2_SCAN_ARRAY_NAME (EXROM-resident shell dispatch, thin glue around
; this same core, validated separately via a real ZEsarUX production-
; ROM command-line check per docs/R10_7_CAPABILITY_RESTORATION.md).
;
; Round trip validated:
;   DIM A(5), A(0..4)=10,20,30,40,50 (real OP_DIM, real program compile)
;   -> resolve "A" via ARRSYM_LOOKUP -> SAVE the descriptor's own bytes
;   verbatim (real STORAGE_SAVE, fake transport) -> NEW (reset the
;   arena, so LOAD can't accidentally "pass" by reading stale correct
;   data back out of the same spot) -> receive directly into (ARRAYS_
;   END) (real STORAGE_LOAD, fake transport) -> parse the received
;   [dim_count][count] header -> ARENA_ALLOC_NUMERIC (real commit) ->
;   verify every element against the original values.
;
; Built on the shared production-shaped test harness (rom/test_v2_
; harness_home_head.inc/_tail.inc), same as rom/test_v2_save_load.asm;
; kernel/storage/storage.asm + rom/exrom_storage_test.asm are HOME-
; resident here (same bank as vm_core/compiler), matching that file's
; own precedent exactly.
; ============================================================================

    DEFINE STORAGE_TEST_FAKE_SEND
    DEFINE STORAGE_TEST_FAKE_RECEIVE
    DEFINE STORAGE_TEST_ROUNDTRIP

    DEFINE TEST_V2_CUSTOM_CHECKS
    INCLUDE "rom/test_v2_harness_home_head.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

DECOMP_END_ADDR: equ $9900

TEST_CUSTOM_MAIN:
    ; This harness's own TEST_COLD_START does NOT call the real kernel/
    ; memory.asm MEM_INIT -- see rom/test_v2_dynamic_arrays.asm's own
    ; identical header note. Set PROG_END/ARRAYS_END/VARS_START
    ; explicitly, matching what MEM_INIT/MEM_INIT_V2 do in production.
    ld   hl, PROG_AREA_START
    ld   (PROG_END), hl
    ld   (ARRAYS_END), hl
    ld   hl, V2_SOURCE_END
    ld   (VARS_START), hl

    ; Real, caught latent-uninitialized-RAM bug (same class the
    ; project's own R10.7 capability-restoration milestone already
    ; found and fixed for STORAGE_VERIFY_MODE in three other storage
    ; tests): this harness never calls MEM_COLD_INIT, and ZEsarUX does
    ; not guarantee zeroed RAM at boot either -- STORAGE_REPORT_
    ; PROGRESS unconditionally `jp (hl)`s through STORAGE_PROGRESS_HOOK
    ; whenever it's nonzero, so leaving it genuinely uninitialized here
    ; sent execution straight into garbage the first time STORAGE_SAVE
    ; called it (caught via a real ZEsarUX run: PC ended up inside
    ; V2_SOURCE_STAGE/TOK_KW_DEF's own data bytes, not code).
    xor  a
    ld   (STORAGE_PROGRESS_HOOK), a
    ld   (STORAGE_PROGRESS_HOOK+1), a

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

    ; ---- resolve "A" via the real compile-time symbol table ----
    ld   hl, ARRAY_NAME
    ld   b, 1
    call ARRSYM_LOOKUP
    jp   c, TEST_FAIL
    ld   (TEST_ARRAY_INDEX), a
    ld   c, a
    ld   h, 0
    ld   l, c
    add  hl, hl
    ld   de, (RT_ARRPTR_PTR)
    add  hl, de
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ld   a, d
    or   e
    jp   z, TEST_FAIL          ; never DIM'd this run -- a real bug if so
    push de                     ; descriptor address
    ld   hl, (ARR_SIZE_TMP)
    add  hl, hl                 ; count*2
    ld   de, ARR_DESC_DATA_OFF
    add  hl, de                 ; HL = real descriptor length
    ld   (TEST_DESC_LEN), hl
    pop  ix                     ; IX = descriptor address

    ; ---- SAVE: real STORAGE_SAVE, fake transport ----
    xor  a
    ld   (STORAGE_REQUEST_TYPE), a   ; the fake transport doesn't care
                                        ; about the real type value; any
                                        ; fixed value works here
    ld   hl, TEST_FILENAME
    ld   b, TEST_FILENAME_LEN
    ld   de, (TEST_DESC_LEN)
    call STORAGE_SAVE

    ; ---- NEW: reset the arena so LOAD can't accidentally "pass" by
    ; reading stale-but-correct data back out of the same spot ----
    ld   hl, (PROG_END)
    ld   (ARRAYS_END), hl

    ; ---- LOAD: real STORAGE_LOAD, fake transport, straight into the
    ; arena's own current free space ----
    ld   ix, (ARRAYS_END)
    ld   hl, 0                 ; wildcard filename (B=0)
    ld   b, 0
    ld   de, $1000              ; generous max length
    call STORAGE_LOAD
    jp   c, TEST_FAIL

    ; ---- parse the received [dim_count:1][count:2] header and commit
    ; via the real ARENA_ALLOC_NUMERIC (same core OP_DIM itself uses) ----
    ld   hl, (ARRAYS_END)
    inc  hl                     ; skip dim_count
    ld   e, (hl)
    inc  hl
    ld   d, (hl)                ; DE = received count
    ld   a, (TEST_ARRAY_INDEX)
    call ARENA_ALLOC_NUMERIC

    call CHECK_RESULT
    jp   c, TEST_FAIL

    jp   TEST_PASS

; A(0..4) = 10,20,30,40,50 -- five real, distinct, order-sensitive
; values (not all-equal) so a byte-order or offset-by-one bug in the
; SAVE/LOAD round trip would be caught, not masked.
SOURCE_TEXT:
    db "DIM A(5)", 13
    db "A(0)=10", 13
    db "A(1)=20", 13
    db "A(2)=30", 13
    db "A(3)=40", 13
    db "A(4)=50", 13
    db 0

ARRAY_NAME: db "A"
TEST_FILENAME: db "ARRTEST"
TEST_FILENAME_LEN: equ $-TEST_FILENAME
; TEST_DESC_LEN/TEST_ARRAY_INDEX must be REAL RAM, not plain ROM-
; resident dw/db data: $0000-$3FFF is the real, write-protected Home
; ROM image in this flat-build convention (same real bug rom/test_v2_
; save_load.asm's own header already documents and works around with
; its own TEST_PROGRAM_LEN) -- a `ld (TEST_DESC_LEN),hl` against a ROM
; address silently does nothing, so the later `ld de,(TEST_DESC_LEN)`
; read back the literal assembled 0, not the real computed length (a
; real bug caught here: BC ended up holding tens of thousands instead
; of 13, turning STORAGE_TEST_SEND_BLOCK's own `ldir` into a
; multi-million-instruction copy that looked exactly like a hang).
; $9800 matches rom/test_v2_ext_demo.asm's own already-established
; "confirmed clear of every VM table/stack/registry workspace" scratch
; address.
TEST_DESC_LEN: equ $9800
TEST_ARRAY_INDEX: equ $9802

; ============================================================================
; CHECK_RESULT — re-resolves the array's own data address via ARR_PTR_
; TABLE[TEST_ARRAY_INDEX] (exactly as live BASIC code would via OP_ARR_
; LOAD) and checks all five elements against the original values. Carry
; set on any mismatch.
; ============================================================================
CHECK_RESULT:
    ld   a, (TEST_ARRAY_INDEX)
    ld   l, a
    ld   h, 0
    add  hl, hl
    ld   de, (RT_ARRPTR_PTR)
    add  hl, de
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl
    ld   de, ARR_DESC_DATA_OFF
    add  hl, de                 ; HL -> element 0
    ld   de, EXPECTED_VALUES
    ld   b, 5
.loop:
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail
    inc  hl
    inc  de
    ld   a, (de)
    cp   (hl)
    jr   nz, .fail
    inc  hl
    inc  de
    djnz .loop
    or   a
    ret
.fail:
    scf
    ret

EXPECTED_VALUES: dw 10, 20, 30, 40, 50

; Test-only stubs: this test never exercises PRINT/LPRINT/BEEP/SOUND/
; PAUSE/INPUT/extensions/real screen bitmap content (same discipline as
; rom/test_v2_save_load.asm/rom/test_v2_dynamic_arrays.asm).
BASIC_STMT_LPRINT_EXROM:
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
IO_READ_KEY_NONBLOCK:
    xor a
    ret
; Test-only stub: this file's own test program never registers or calls
; a loadable extension.
EXT2_LOOKUP:
    scf
    ret
EXT2_SLOT_ADDR:
    ret
EXT_CALL_ARG0: equ $8B00
EXT_CALL_ARG4: equ $8B00
EXT2_TABLE:    equ $8B00

    INCLUDE "rom/exrom_format.asm"
    INCLUDE "kernel/storage/storage.asm"
    INCLUDE "rom/exrom_storage_test.asm"

    INCLUDE "rom/test_v2_harness_home_tail.inc"

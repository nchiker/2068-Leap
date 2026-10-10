; ============================================================================
; rom/test_v2_scalar_capacity32.asm — R10.7 item 7 (re-attempted) capacity
; regression test: numeric scalars 16->32, string scalars 4->8.
;
; The original item-7 attempt was implemented, built, and reverted after a
; real regression traced to an unrelated VM_ARR_VALUE_TMP/VM_INPUT_COUNT
; collision (docs/v2/R10_7_CAPABILITY_RESTORATION.md). This re-attempt (docs/
; v2/R10_7_CAPACITY_ARCHITECTURE_AUDIT.md) keeps the existing base tables
; (CSYMTAB_BASE/SYMTAB_BASE/STRSYMTAB_BASE/STRTAB_BASE) at their proven,
; unchanged addresses, and adds the extra capacity as a SEPARATE overflow
; tier instead of growing/shifting the base tables in place:
;   - SYMTAB_OVERFLOW_BASE/STRTAB_OVERFLOW_BASE live in the V2 source-
;     staging buffer ($9455-$A455), valid only from VM_INIT (after a
;     successful compile) until the next V2_BUILD_SOURCE call.
;   - CSYMTAB_OVERFLOW_A/B and STRSYMTAB_OVERFLOW (compile-time only) live
;     in genuinely-free, always-unused gaps elsewhere in the bank.
; VM_SYM_ADDR/VM_STR_ADDR/CSYM_ENTRY_ADDR/STRSYM_ENTRY_ADDR all branch to
; the right tier by index — this test exercises BOTH tiers directly, not
; just the base one 25/25 of the existing suite already covers.
;
; Source program compiled and executed: 32 distinct numeric scalars (A-Z,
; then A1-F1 — indices 0-31 in first-use order) each assigned its own
; 1-based position (A=1 .. F1=32), then F1 is reassigned to the sum of all
; 32 (528), exercising a read of every slot in both numeric tiers in one
; expression. Then 8 distinct string scalars (A$-H$, indices 0-7) are each
; assigned a distinct string, exercising both string tiers.
;
; CHECK_RESULT below reads back:
;   - A (index 0, base tier)          == 1
;   - U (index 20, overflow tier A)   == 21 (untouched by the final sum)
;   - F1 (index 31, overflow tier B)  == 528 (sum of all 32)
;   - A$ (index 0, base tier)         == "a"
;   - H$ (index 7, overflow tier)     == "hhhhhhhh"
;   - CSYM_COUNT == 32, STRSYM_COUNT == 8
; via the REAL VM_SYM_ADDR/VM_STR_ADDR routines (not a reimplemented flat
; formula), so this also proves the tiering logic itself, not just that
; the right numbers happen to come out.
; ============================================================================

    DEFINE TEST_V2_CUSTOM_CHECKS
    INCLUDE "rom/test_v2_harness_home_head.inc"

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

    call CHECK_RESULT
    jp   c, TEST_FAIL

    jp   TEST_PASS

SOURCE_TEXT:
    db "A=1:B=2:C=3:D=4:E=5:F=6:G=7:H=8:I=9:J=10:K=11:L=12:M=13:N=14:O=15:P=16:", 13
    db "Q=17:R=18:S=19:T=20:U=21:V=22:W=23:X=24:Y=25:Z=26:A1=27:B1=28:", 13
    db "C1=29:D1=30:E1=31:F1=32:", 13
    db "F1=A+B+C+D+E+F+G+H+I+J+K+L+M+N+O+P+Q+R+S+T+U+V+W+X+Y+Z+A1+B1+C1+D1+E1+F1:", 13
    db 'A$="a":B$="bb":C$="ccc":D$="dddd":', 13
    db 'E$="eeeee":F$="ffffff":G$="ggggggg":H$="hhhhhhhh"', 0

; ============================================================================
; CHECK_RESULT — carry set on any mismatch.
; ============================================================================
CHECK_RESULT:
    ; A (index 0, base tier) == 1
    ld   hl, NM_A
    ld   b, NM_A_LEN
    call CSYM_FIND_OR_CREATE
    call VM_SYM_ADDR
    call READ_NUM
    ld   de, 1
    call CHECK_NUM_EQ2
    ret  c

    ; U (index 20, overflow tier A) == 21, untouched by the final sum
    ld   hl, NM_U
    ld   b, NM_U_LEN
    call CSYM_FIND_OR_CREATE
    call VM_SYM_ADDR
    call READ_NUM
    ld   de, 21
    call CHECK_NUM_EQ2
    ret  c

    ; F1 (index 31, overflow tier B) == 528 (sum of all 32)
    ld   hl, NM_F1
    ld   b, NM_F1_LEN
    call CSYM_FIND_OR_CREATE
    call VM_SYM_ADDR
    call READ_NUM
    ld   de, 528
    call CHECK_NUM_EQ2
    ret  c

    ; A$ (index 0, base tier) == "a"
    ld   hl, NM_AS
    ld   b, NM_AS_LEN
    call STRSYM_FIND_OR_CREATE
    call VM_STR_ADDR
    ld   de, EXPECT_A
    call STRCHECK_CMP
    ret  c

    ; H$ (index 7, overflow tier) == "hhhhhhhh"
    ld   hl, NM_HS
    ld   b, NM_HS_LEN
    call STRSYM_FIND_OR_CREATE
    call VM_STR_ADDR
    ld   de, EXPECT_H
    call STRCHECK_CMP
    ret  c

    ld   a, (CSYM_COUNT)
    cp   32
    jr   nz, .bad
    ld   a, (STRSYM_COUNT)
    cp   8
    jr   nz, .bad
    or   a
    ret
.bad:
    scf
    ret

; READ_NUM -- input: HL -> SYMTAB record (tag+value). Output: HL = value.
; Destroys: AF, DE.
READ_NUM:
    inc  hl
    ld   e, (hl)
    inc  hl
    ld   d, (hl)
    ex   de, hl
    ret

; CHECK_NUM_EQ2 -- input: HL = actual value, DE = expected value. Output:
; carry set on mismatch. Destroys: AF, HL.
CHECK_NUM_EQ2:
    or   a
    sbc  hl, de
    ret  z
    scf
    ret

; STRCHECK_CMP -- HL -> live [len:1][content] record, DE -> expected
; [len:1][content] fixture. Carry set on any length/content mismatch.
STRCHECK_CMP:
    ld   a, (de)
    cp   (hl)
    scf
    ret  nz
    ld   b, a
    or   a
    ret  z
.loop:
    inc  hl
    inc  de
    ld   a, (de)
    cp   (hl)
    scf
    ret  nz
    djnz .loop
    or   a
    ret

NM_A: db "A"
NM_A_LEN: equ $-NM_A
NM_U: db "U"
NM_U_LEN: equ $-NM_U
NM_F1: db "F1"
NM_F1_LEN: equ $-NM_F1
NM_AS: db "A"
NM_AS_LEN: equ $-NM_AS
NM_HS: db "H"
NM_HS_LEN: equ $-NM_HS

EXPECT_A: db 1, "a"
EXPECT_H: db 8, "hhhhhhhh"

; Test-only stubs: this program never exercises PRINT/LPRINT/BEEP/
; SOUND/PAUSE/INPUT/extensions/real screen bitmap content (same
; discipline as rom/test_v2_identifier_length.asm).
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

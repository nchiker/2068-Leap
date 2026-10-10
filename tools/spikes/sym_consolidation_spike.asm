; ============================================================================
; tools/spikes/sym_consolidation_spike.asm -- R10.7 ROM-consolidation SPIKE.
; NON-PRODUCTION (not included by any Makefile target / production image).
;
; Question: how many bytes does ONE descriptor-driven symbol-table routine set
; cost, versus the production clones it would replace?  Production routines
; (sizes MEASURED from build/test_basic.sym, next-label distance):
;   CSYM_FIND_OR_CREATE 97 + CSYM_ENTRY_ADDR 43        (tiered, 3 tiers)
;   STRSYM_FIND_OR_CREATE 98 + STRSYM_ENTRY_ADDR 26    (tiered, 2 tiers)
;   ARRSYM  ENTRY 17 + SCAN 63 + FIND_OR_CREATE 61 + LOOKUP 23
;   STRARRSYM ENTRY 14 + SCAN 63 + FIND_OR_CREATE 66 + LOOKUP 28
;   = 599 B total (excludes shared SYM9_INDEX_MUL, SYM_BUMP_COUNT,
;     WRITE_NAME_FIELD, NAME_CMP_FOLD, which would remain).
;
; The spike implements the same semantics for FLAT tables (the layout that a
; lifetime zone makes possible) with a 6-byte descriptor per table:
;     +0 count_ptr(2)  +2 base(2)  +4 reclen(1)  +5 max(1)
; and keeps the production call contracts via thin wrappers, so no call site
; changes.  Helper stubs below are copies of the production helpers and are
; EXCLUDED from the measured generic size (production keeps its own).
; ============================================================================
    DEVICE NOSLOT64K

COUNT_C     EQU $8000
COUNT_S     EQU $8001
COUNT_A     EQU $8002
COUNT_SA    EQU $8003
SS_NAME     EQU $8010   ; 2
SS_LEN      EQU $8012   ; 1
SS_IDX      EQU $8013   ; 1
COMPILE_ERROR_CODE EQU $8014
RESULT      EQU $8015
ARR_SIZE_TMP EQU $8016  ; 2
STRARR_SIZE_TMP EQU $8018 ; 2
STRARR_WIDTH_TMP EQU $801A
TAB_C       EQU $9000   ; 32 x 9
TAB_S       EQU $9200   ; 8 x 9
TAB_A       EQU $9300   ; 16 x 11
TAB_SA      EQU $9400   ; 8 x 12
NAMEBUF     EQU $8100

    ORG 0
    di
    ld   sp,$FF00
    jp   TESTS

; ---------------- helper stubs (production copies; NOT counted) -------------
FOLD_UPPER:
    cp   'a'
    ret  c
    cp   'z'+1
    ret  nc
    and  $DF
    ret
NAME_CMP_FOLD:
.loop:
    ld a,(de)
    call FOLD_UPPER
    ld c,a
    ld a,(hl)
    call FOLD_UPPER
    cp c
    ret nz
    inc hl
    inc de
    djnz .loop
    ret
WRITE_NAME_FIELD:
    ld a,b
    ld (hl),a
    inc hl
    or a
    ret z
.copy_loop:
    ld a,(de)
    ld (hl),a
    inc hl
    inc de
    djnz .copy_loop
    ret
COMPILE_RAISE_ERROR:
    ld (COMPILE_ERROR_CODE),a
    xor a
    ret

; ---------------- descriptors: count_ptr, base, reclen, max ------------------
CSYM_DESC:   DW COUNT_C  : DW TAB_C  : DB 9  : DB 32
STRSYM_DESC: DW COUNT_S  : DW TAB_S  : DB 9  : DB 8
ARR_DESC:    DW COUNT_A  : DW TAB_A  : DB 11 : DB 16
STRARR_DESC: DW COUNT_SA : DW TAB_SA : DB 12 : DB 8

; ============================ GENERIC CORE (measured) =======================
GEN_BEGIN:
; SYM_SCAN: HL=name, B=len, IX=descriptor.
;   found    : carry clear, A=index, HL=entry address
;   not found: carry set,   A=count, HL=address of the next free slot
SYM_SCAN:
    ld   (SS_NAME),hl
    ld   a,b
    ld   (SS_LEN),a
    ld   l,(ix+0)
    ld   h,(ix+1)
    ld   c,(hl)             ; C = entries remaining
    ld   l,(ix+2)
    ld   h,(ix+3)           ; HL = entry
    xor  a
    ld   (SS_IDX),a
.next:
    ld   a,c
    or   a
    jr   z,.nf
    ld   a,(hl)
    cp   b
    jr   nz,.adv
    push hl
    push bc
    inc  hl
    ld   de,(SS_NAME)
    ld   a,b
    or   a
    jr   z,.cmp_done        ; zero-length: treat as match (as production)
    call NAME_CMP_FOLD
.cmp_done:
    pop  bc
    pop  hl
    jr   z,.found
.adv:
    ld   a,(ix+4)
    add  a,l
    ld   l,a
    jr   nc,.nc
    inc  h
.nc:
    ld   a,(SS_IDX)
    inc  a
    ld   (SS_IDX),a
    dec  c
    jr   .next
.found:
    ld   a,(SS_IDX)
    or   a                  ; carry clear
    ret
.nf:
    ld   a,(SS_IDX)
    scf
    ret

; SYM_CREATE: after a not-found SYM_SCAN (HL = free slot). Writes the name
; field, bumps the count. Out: A = new index, HL = entry+9 (first byte after
; the name field, for callers that store extra fields).
SYM_CREATE:
    ld   a,(SS_LEN)
    ld   b,a
    ld   de,(SS_NAME)
    call WRITE_NAME_FIELD   ; HL advanced past len+name bytes actually copied
    ; (production fields are fixed 9 wide: re-derive entry start)
    ld   l,(ix+0)
    ld   h,(ix+1)
    ld   a,(hl)
    inc  (hl)               ; count++ ; A = old count = new index
    push af
    ld   c,a
    call SYM_ENTRY
    ld   de,9
    add  hl,de
    pop  af
    ret

; SYM_ENTRY: C = index, IX = descriptor -> HL = entry address. Preserves C.
SYM_ENTRY:
    ld   l,(ix+2)
    ld   h,(ix+3)
    ld   a,c
    or   a
    ret  z
    ld   d,0
    ld   e,(ix+4)
.l:
    add  hl,de
    dec  a
    jr   nz,.l
    ret

; SYM_FIND_OR_CREATE (scalars): HL=name, B=len, IX=descriptor -> A=index.
; Table full: COMPILE_ERROR_CODE=1 and A=0 (production CSYM/STRSYM contract).
SYM_FIND_OR_CREATE:
    call SYM_SCAN
    ret  nc
    cp   (ix+5)
    jr   nz,.create
    ld   a,1
    ld   (COMPILE_ERROR_CODE),a
    xor  a
    ret
.create:
    jr   SYM_CREATE
GEN_END:

; ============================ WRAPPERS (measured) ===========================
WRAP_BEGIN:
CSYM_FIND_OR_CREATE:
    ld   ix,CSYM_DESC
    jr   SYM_FIND_OR_CREATE
STRSYM_FIND_OR_CREATE:
    ld   ix,STRSYM_DESC
    jr   SYM_FIND_OR_CREATE

ARRSYM_FIND_OR_CREATE:
    ld   ix,ARR_DESC
    call SYM_SCAN
    jr   c,.nf
    ld   a,38
    jp   COMPILE_RAISE_ERROR
.nf:
    cp   (ix+5)
    jr   nz,.create
    ld   a,39
    jp   COMPILE_RAISE_ERROR
.create:
    call SYM_CREATE
    ld   de,(ARR_SIZE_TMP)
    ld   (hl),e
    inc  hl
    ld   (hl),d
    ret
ARRSYM_LOOKUP:
    ld   ix,ARR_DESC
    call SYM_SCAN
    ret  c
    ld   de,9
    add  hl,de
    ld   e,(hl)
    inc  hl
    ld   d,(hl)
    ld   (ARR_SIZE_TMP),de
    or   a
    ret

STRARRSYM_FIND_OR_CREATE:
    ld   ix,STRARR_DESC
    call SYM_SCAN
    jr   c,.nf
    ld   a,38
    jp   COMPILE_RAISE_ERROR
.nf:
    cp   (ix+5)
    jr   nz,.create
    ld   a,39
    jp   COMPILE_RAISE_ERROR
.create:
    call SYM_CREATE
    push af                 ; A = new index must survive the width load
    ld   de,(STRARR_SIZE_TMP)
    ld   (hl),e
    inc  hl
    ld   (hl),d
    inc  hl
    ld   a,(STRARR_WIDTH_TMP)
    ld   (hl),a
    pop  af
    ret
STRARRSYM_LOOKUP:
    ld   ix,STRARR_DESC
    call SYM_SCAN
    ret  c
    ld   de,9
    add  hl,de
    ld   e,(hl)
    inc  hl
    ld   d,(hl)
    ld   (STRARR_SIZE_TMP),de
    inc  hl
    ld   a,(hl)
    ld   (STRARR_WIDTH_TMP),a
    or   a
    ret
WRAP_END:
DESC_BYTES EQU 4*6

; ================================== TESTS ===================================
T   MACRO n
    ld   a,n
    ld   (RESULT),a
    ENDM
NAME MACRO str
    ld   hl,.s
    jr   .go
.s: DB str
.go:
    ENDM

TESTS:
    xor  a
    ld   (COUNT_C),a
    ld   (COUNT_S),a
    ld   (COUNT_A),a
    ld   (COUNT_SA),a
    ld   (COMPILE_ERROR_CODE),a

    ; 1 scalar create gives sequential indices, find returns same (case-insens)
    T 1
    ld hl,N_ALPHA : ld b,5 : call CSYM_FIND_OR_CREATE : or a : jp nz,FAIL
    ld hl,N_BETA  : ld b,4 : call CSYM_FIND_OR_CREATE : cp 1 : jp nz,FAIL
    ld hl,N_ALPHA_L : ld b,5 : call CSYM_FIND_OR_CREATE : or a : jp nz,FAIL
    ld hl,N_BETA_U  : ld b,4 : call CSYM_FIND_OR_CREATE : cp 1 : jp nz,FAIL
    ld a,(COUNT_C) : cp 2 : jp nz,FAIL

    ; 2 same length different name is a different symbol
    T 2
    ld hl,N_GAMMA : ld b,5 : call CSYM_FIND_OR_CREATE : cp 2 : jp nz,FAIL

    ; 3 name field stored as len+bytes at base + idx*9
    T 3
    ld a,(TAB_C+9*2) : cp 5 : jp nz,FAIL
    ld a,(TAB_C+9*2+1) : cp 'g' : jp nz,FAIL

    ; 4 table full: 32 entries then the 33rd sets error code 1, A=0, no growth
    T 4
    ld   b,29                       ; 3 exist, add 29 distinct -> 32
    ld   c,0
.fill:
    push bc
    ld   a,c : add a,'a' : ld (NAMEBUF),a : ld a,'x' : ld (NAMEBUF+1),a
    ld   hl,NAMEBUF : ld b,2 : call CSYM_FIND_OR_CREATE
    pop  bc
    inc  c
    djnz .fill
    ld   a,(COUNT_C) : cp 32 : jp nz,FAIL
    ld   a,'z' : ld (NAMEBUF),a : ld a,'q' : ld (NAMEBUF+1),a
    ld   hl,NAMEBUF : ld b,2 : call CSYM_FIND_OR_CREATE
    or   a : jp nz,FAIL
    ld   a,(COMPILE_ERROR_CODE) : cp 1 : jp nz,FAIL
    ld   a,(COUNT_C) : cp 32 : jp nz,FAIL

    ; 5 string scalars independent table
    T 5
    ld hl,N_ALPHA : ld b,5 : call STRSYM_FIND_OR_CREATE : or a : jp nz,FAIL
    ld hl,N_BETA  : ld b,4 : call STRSYM_FIND_OR_CREATE : cp 1 : jp nz,FAIL
    ld a,(COUNT_S) : cp 2 : jp nz,FAIL

    ; 6 numeric array create (size stored), duplicate -> error 38, lookup size
    T 6
    ld hl,$0123 : ld (ARR_SIZE_TMP),hl
    ld hl,N_ALPHA : ld b,5 : call ARRSYM_FIND_OR_CREATE : or a : jp nz,FAIL
    ld hl,$0456 : ld (ARR_SIZE_TMP),hl
    ld hl,N_BETA : ld b,4 : call ARRSYM_FIND_OR_CREATE : cp 1 : jp nz,FAIL
    ld hl,0 : ld (ARR_SIZE_TMP),hl
    ld hl,N_BETA_U : ld b,4 : call ARRSYM_LOOKUP : jp c,FAIL : cp 1 : jp nz,FAIL
    ld hl,(ARR_SIZE_TMP) : ld de,$0456 : or a : sbc hl,de : jp nz,FAIL
    xor a : ld (COMPILE_ERROR_CODE),a
    ld hl,N_ALPHA : ld b,5 : call ARRSYM_FIND_OR_CREATE
    ld a,(COMPILE_ERROR_CODE) : cp 38 : jp nz,FAIL
    ld hl,N_GAMMA : ld b,5 : call ARRSYM_LOOKUP : jp nc,FAIL   ; not found

    ; 7 string array stores size AND width; lookup returns both
    T 7
    ld hl,$0020 : ld (STRARR_SIZE_TMP),hl : ld a,17 : ld (STRARR_WIDTH_TMP),a
    ld hl,N_GAMMA : ld b,5 : call STRARRSYM_FIND_OR_CREATE : or a : jp nz,FAIL
    ld hl,0 : ld (STRARR_SIZE_TMP),hl : xor a : ld (STRARR_WIDTH_TMP),a
    ld hl,N_GAMMA_L : ld b,5 : call STRARRSYM_LOOKUP : jp c,FAIL
    ld hl,(STRARR_SIZE_TMP) : ld de,$0020 : or a : sbc hl,de : jp nz,FAIL
    ld a,(STRARR_WIDTH_TMP) : cp 17 : jp nz,FAIL

    ; 8 array table full -> error 39
    T 8
    ld   b,14
    ld   c,0
.fa:
    push bc
    ld   a,c : add a,'a' : ld (NAMEBUF),a : ld a,'y' : ld (NAMEBUF+1),a
    ld   hl,NAMEBUF : ld b,2 : call ARRSYM_FIND_OR_CREATE
    pop  bc
    inc  c
    djnz .fa
    ld   a,(COUNT_A) : cp 16 : jp nz,FAIL
    xor  a : ld (COMPILE_ERROR_CODE),a
    ld   a,'z' : ld (NAMEBUF),a : ld a,'y' : ld (NAMEBUF+1),a
    ld   hl,NAMEBUF : ld b,2 : call ARRSYM_FIND_OR_CREATE
    ld   a,(COMPILE_ERROR_CODE) : cp 39 : jp nz,FAIL
    ld   a,(COUNT_A) : cp 16 : jp nz,FAIL

    ; 9 neighbouring table untouched by array fill (no overrun)
    T 9
    ld a,(TAB_S+9) : cp 4 : jp nz,FAIL         ; STRSYM[1] still len 4 ("beta")
    jp PASS

N_ALPHA:   DB "alpha"
N_ALPHA_L: DB "ALPHA"
N_BETA:    DB "beta"
N_BETA_U:  DB "BeTa"
N_GAMMA:   DB "gamma"
N_GAMMA_L: DB "GAMMA"

FAIL:
    ld a,2 : out ($FE),a
.f: halt
    jr .f
PASS:
    ld a,4 : out ($FE),a
.p: halt
    jr .p

    DISPLAY "GEN bytes (SCAN+CREATE+ENTRY+FOC): ", GEN_END-GEN_BEGIN
    DISPLAY "WRAPPER code bytes (4 tables incl arr/strarr tails): ", WRAP_END-WRAP_BEGIN
    DISPLAY "descriptor data bytes: ", DESC_BYTES
    DS $6000-$,0
    SAVEBIN "build/spikes/sym_consolidation_spike.bin",0,$6000

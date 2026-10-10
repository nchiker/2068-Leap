; ============================================================================
; tools/spikes/tagged_symtab_spike.asm -- R10.7 limits-architecture SPIKE.
; NON-PRODUCTION (not included by any Makefile target or production image).
;
; Proposal being measured: ONE append-only, variable-length, tagged symbol
; table (memory-limited, no per-kind caps) replacing CSYMTAB, STRSYMTAB,
; ARRSYMTAB, STRARRSYMTAB, LABELTAB and FIXUPTAB, with forward label
; references threaded THROUGH THE EMITTED CODE (each unresolved operand slot
; holds the previous slot's address; the label record holds the chain head),
; so there is no fixup table at all.
;
;   record = [rec_len:1][kind:1][namelen:1][index:1][name:namelen][extra:n]
;   table  = records..., terminated by a 0 byte; SYM_END -> that 0 byte.
;   kind   : 0 numeric scalar, 1 string scalar, 2 numeric array,
;            3 string array, 4 label/PROC/FN
;   index  : per-kind running count (the 1-byte operand the VM already uses)
;   extra  : array = size(2) [+ width(1)];  label = offset-or-chain(2)+defined(1)
;
; Production sizes replaced (MEASURED, build/test_basic.sym):
;   CSYM 97+43, STRSYM 98+26, ARRSYM 17+63+61+23, STRARRSYM 14+63+66+28 = 599
;   LABEL_DEFINE 62 + LABEL_LOOKUP 75 + FIXUP_RECORD 54 +
;   RESOLVE_ALL_FIXUPS 54 + FIXUP_ENTRY_ADDR 16 = 261          => 860 total
; ============================================================================
    DEVICE NOSLOT64K

SYM_TABLE   EQU $9000
SYM_LIMIT_V EQU $8000       ; 2  : table limit (exclusive)
SYM_END_V   EQU $8002       ; 2  : -> terminating 0 byte
SYM_COUNTS  EQU $8004       ; 5  : per-kind counts
SS_NAME     EQU $8010       ; 2
SS_KIND     EQU $8012       ; 1
COMPILE_ERROR_CODE EQU $8013
RESULT      EQU $8014
ARR_SIZE_TMP    EQU $8016   ; 2
STRARR_SIZE_TMP EQU $8018   ; 2
STRARR_WIDTH_TMP EQU $801A
CODE        EQU $A000       ; fake emitted-code buffer for label chains
NAMEBUF     EQU $8100

K_NUM EQU 0
K_STR EQU 1
K_ARR EQU 2
K_SARR EQU 3
K_LAB EQU 4

    ORG 0
    di
    ld   sp,$FF00
    jp   TESTS

; ---------- helper stubs (production copies; NOT counted) --------------------
FOLD_UPPER:
    cp 'a'
    ret c
    cp 'z'+1
    ret nc
    and $DF
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
COMPILE_RAISE_ERROR:
    ld (COMPILE_ERROR_CODE),a
    xor a
    ret

; ============================ GENERIC CORE (measured) =======================
CORE_BEGIN:
; SYM_INIT: empty table, base in HL, limit in DE
SYM_INIT:
    ld   (SYM_END_V),hl
    ld   (hl),0
    ld   (SYM_LIMIT_V),de
    ld   hl,SYM_COUNTS
    ld   b,5
.z: ld   (hl),0
    inc  hl
    djnz .z
    ret

; SYM_FIND: HL=name, B=len, C=kind.
;   found    : carry clear, A=index, HL=record start
;   not found: carry set,   A=next index for this kind, HL=free slot
SYM_FIND:
    ld   (SS_NAME),hl
    ld   hl,SYM_TABLE
.rec:
    ld   a,(hl)
    or   a
    jr   z,.nf
    push hl
    inc  hl
    ld   a,(hl)
    cp   c
    jr   nz,.skip
    inc  hl
    ld   a,(hl)
    cp   b
    jr   nz,.skip
    inc  hl
    inc  hl
    ld   de,(SS_NAME)
    push bc
    call NAME_CMP_FOLD
    pop  bc
    jr   nz,.skip
    pop  hl
    inc  hl
    inc  hl
    inc  hl
    ld   a,(hl)
    dec  hl
    dec  hl
    dec  hl
    or   a
    ret
.skip:
    pop  hl
    ld   e,(hl)
    ld   d,0
    add  hl,de
    jr   .rec
.nf:
    push hl
    ld   hl,SYM_COUNTS
    ld   e,c
    ld   d,0
    add  hl,de
    ld   a,(hl)
    pop  hl
    scf
    ret

; SYM_ADD: HL=free slot, C=kind, B=namelen, E=extra size (zero-filled);
;   name pointer in SS_NAME.  Carry set = table full (nothing changed).
;   Else carry clear, A=index, HL -> extra bytes.
SYM_ADD:
    ld   a,b
    add  a,4
    add  a,e
    ld   d,a                ; D = rec_len
    push hl
    push de
    ld   e,d
    ld   d,0
    add  hl,de
    inc  hl                 ; slot + rec_len + 1 (terminator included)
    ld   de,(SYM_LIMIT_V)
    or   a
    sbc  hl,de
    jr   c,.fits
    jr   z,.fits
    pop  de
    pop  hl
    scf
    ret
.fits:
    pop  de                 ; D=rec_len E=extra
    pop  hl                 ; slot
    ld   (hl),d
    inc  hl
    ld   (hl),c
    inc  hl
    ld   (hl),b
    inc  hl
    push hl
    push de
    ld   hl,SYM_COUNTS
    ld   e,c
    ld   d,0
    add  hl,de
    ld   a,(hl)
    inc  (hl)
    pop  de
    pop  hl
    ld   (hl),a             ; index
    inc  hl
    push af
    push de                 ; E = extra
    ex   de,hl              ; DE = dest
    ld   hl,(SS_NAME)
    ld   c,b
    ld   b,0
    ldir                    ; copy name
    ex   de,hl              ; HL = after name = extras
    pop  de                 ; E = extra
    push hl
    ld   a,e
    or   a
    jr   z,.noext
    ld   b,a
.zx:
    ld   (hl),0
    inc  hl
    djnz .zx
.noext:
    ld   (hl),0             ; terminator
    ld   (SYM_END_V),hl
    pop  hl                 ; HL -> extras
    pop  af                 ; A = index
    or   a                  ; carry clear
    ret

; SYM_FOC: find-or-create with no extras. HL=name, B=len, C=kind -> A=index.
; Table full: COMPILE_ERROR_CODE=1, A=0 (production CSYM/STRSYM contract).
SYM_FOC:
    call SYM_FIND
    ret  nc
    ld   e,0
    call SYM_ADD
    ret  nc
    ld   a,1
    ld   (COMPILE_ERROR_CODE),a
    xor  a
    ret
CORE_END:

; ===================== KIND WRAPPERS (measured) =============================
WRAP_BEGIN:
CSYM_FIND_OR_CREATE:
    ld   c,K_NUM
    jr   SYM_FOC
STRSYM_FIND_OR_CREATE:
    ld   c,K_STR
    jr   SYM_FOC

ARRSYM_FIND_OR_CREATE:
    ld   c,K_ARR
    call SYM_FIND
    jr   c,.nf
    ld   a,38
    jp   COMPILE_RAISE_ERROR
.nf:
    ld   e,2
    call SYM_ADD
    jr   nc,.ok
    ld   a,39
    jp   COMPILE_RAISE_ERROR
.ok:
    ld   de,(ARR_SIZE_TMP)
    ld   (hl),e
    inc  hl
    ld   (hl),d
    ret
ARRSYM_LOOKUP:
    ld   c,K_ARR
    call SYM_FIND
    ret  c
    push af
    ld   de,4
    add  hl,de
    ld   e,b
    ld   d,0
    add  hl,de              ; -> extras
    ld   e,(hl)
    inc  hl
    ld   d,(hl)
    ld   (ARR_SIZE_TMP),de
    pop  af
    or   a
    ret

STRARRSYM_FIND_OR_CREATE:
    ld   c,K_SARR
    call SYM_FIND
    jr   c,.nf
    ld   a,38
    jp   COMPILE_RAISE_ERROR
.nf:
    ld   e,3
    call SYM_ADD
    jr   nc,.ok
    ld   a,39
    jp   COMPILE_RAISE_ERROR
.ok:
    push af
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
    ld   c,K_SARR
    call SYM_FIND
    ret  c
    push af
    ld   de,4
    add  hl,de
    ld   e,b
    ld   d,0
    add  hl,de
    ld   e,(hl)
    inc  hl
    ld   d,(hl)
    ld   (STRARR_SIZE_TMP),de
    inc  hl
    ld   a,(hl)
    ld   (STRARR_WIDTH_TMP),a
    pop  af
    or   a
    ret

; ---- labels: extra = [value:2][defined:1] ----
; LABEL_REF: HL=name, B=len, DE=address of the 16-bit operand slot to fill.
;   Defined label  -> slot = its offset.
;   Undefined      -> slot = previous chain head; record head = this slot.
LABEL_REF:
    push de
    ld   c,K_LAB
    call SYM_FIND
    jr   nc,.have
    ld   e,3
    call SYM_ADD
    jr   nc,.have2
    pop  de
    ld   a,1
    ld   (COMPILE_ERROR_CODE),a
    ret
.have:
    ld   de,4
    add  hl,de
    ld   e,b
    ld   d,0
    add  hl,de
.have2:
    pop  de                 ; DE = slot address, HL -> extras
    inc  hl
    inc  hl
    ld   a,(hl)             ; defined?
    dec  hl
    dec  hl
    or   a
    jr   z,.fwd
    ld   a,(hl)
    ld   (de),a
    inc  hl
    inc  de
    ld   a,(hl)
    ld   (de),a
    ret
.fwd:
    ld   a,(hl)             ; old head -> slot
    ld   (de),a
    inc  hl
    inc  de
    ld   a,(hl)
    ld   (de),a
    dec  de
    ld   (hl),d             ; head = slot (hi)
    dec  hl
    ld   (hl),e             ; head = slot (lo)
    ret

; LABEL_DEFINE: HL=name, B=len, DE=offset value. Walks and patches any chain.
;   Error 40 if already defined.
LABEL_DEFINE:
    push de
    ld   c,K_LAB
    call SYM_FIND
    jr   nc,.have
    ld   e,3
    call SYM_ADD
    jr   c,.full
    jr   .set
.have:
    ld   de,4
    add  hl,de
    ld   e,b
    ld   d,0
    add  hl,de
    inc  hl
    inc  hl
    ld   a,(hl)
    dec  hl
    dec  hl
    or   a
    jr   z,.walk
    pop  de
    ld   a,40
    jp   COMPILE_RAISE_ERROR
.walk:
    pop  de                 ; DE = offset
    push de
    ld   c,(hl)
    inc  hl
    ld   b,(hl)             ; BC = chain head
    dec  hl                 ; HL -> value
.chain:
    ld   a,b
    or   c
    jr   z,.set
    ld   a,(bc)
    push af                 ; next slot lo
    inc  bc
    ld   a,(bc)
    push af                 ; next slot hi
    ld   a,d
    ld   (bc),a             ; slot+1 = offset hi
    dec  bc
    ld   a,e
    ld   (bc),a             ; slot+0 = offset lo
    pop  af
    ld   b,a
    pop  af
    ld   c,a
    jr   .chain
.set:
    pop  de
    ld   (hl),e
    inc  hl
    ld   (hl),d
    inc  hl
    ld   (hl),1
    ret
.full:
    pop  de
    ld   a,1
    ld   (COMPILE_ERROR_CODE),a
    ret

; LABEL_CHECK_ALL: after compile; A=0 ok, else A = 41 (an undefined label)
LABEL_CHECK_ALL:
    ld   hl,SYM_TABLE
.rec:
    ld   a,(hl)
    or   a
    ret  z                  ; A=0
    ld   e,a
    ld   d,0
    inc  hl
    ld   a,(hl)             ; kind
    dec  hl
    cp   K_LAB
    jr   nz,.next
    push hl
    add  hl,de
    dec  hl                 ; defined flag = last byte of the record
    ld   a,(hl)
    pop  hl
    or   a
    jr   nz,.next
    ld   a,41
    ret
.next:
    add  hl,de
    jr   .rec
WRAP_END:

; ================================== TESTS ===================================
T   MACRO n
    ld   a,n
    ld   (RESULT),a
    ENDM

TESTS:
    xor  a
    ld   (COMPILE_ERROR_CODE),a
    ld   hl,SYM_TABLE
    ld   de,SYM_TABLE+600
    call SYM_INIT

    T 1                     ; sequential per-kind indices, case-insens find
    ld hl,N_ALPHA : ld b,5 : call CSYM_FIND_OR_CREATE : or a : jp nz,FAIL
    ld hl,N_BETA  : ld b,4 : call CSYM_FIND_OR_CREATE : cp 1 : jp nz,FAIL
    ld hl,N_ALPHA_U : ld b,5 : call CSYM_FIND_OR_CREATE : or a : jp nz,FAIL
    ld hl,N_ALPHA : ld b,5 : call STRSYM_FIND_OR_CREATE : or a : jp nz,FAIL   ; same name, other kind
    ld a,(SYM_COUNTS) : cp 2 : jp nz,FAIL
    ld a,(SYM_COUNTS+1) : cp 1 : jp nz,FAIL

    T 2                     ; arrays: create, duplicate=38, lookup size
    ld hl,$0123 : ld (ARR_SIZE_TMP),hl
    ld hl,N_GAMMA : ld b,5 : call ARRSYM_FIND_OR_CREATE : or a : jp nz,FAIL
    ld hl,N_GAMMA_U : ld b,5 : xor a : ld (COMPILE_ERROR_CODE),a : call ARRSYM_FIND_OR_CREATE
    ld a,(COMPILE_ERROR_CODE) : cp 38 : jp nz,FAIL
    ld hl,0 : ld (ARR_SIZE_TMP),hl
    ld hl,N_GAMMA_U : ld b,5 : call ARRSYM_LOOKUP : jp c,FAIL : or a : jp nz,FAIL
    ld hl,(ARR_SIZE_TMP) : ld de,$0123 : or a : sbc hl,de : jp nz,FAIL

    T 3                     ; string arrays carry width
    ld hl,$0040 : ld (STRARR_SIZE_TMP),hl : ld a,17 : ld (STRARR_WIDTH_TMP),a
    ld hl,N_BETA : ld b,4 : call STRARRSYM_FIND_OR_CREATE : or a : jp nz,FAIL
    ld hl,0 : ld (STRARR_SIZE_TMP),hl : xor a : ld (STRARR_WIDTH_TMP),a
    ld hl,N_BETA : ld b,4 : call STRARRSYM_LOOKUP : jp c,FAIL
    ld hl,(STRARR_SIZE_TMP) : ld de,$0040 : or a : sbc hl,de : jp nz,FAIL
    ld a,(STRARR_WIDTH_TMP) : cp 17 : jp nz,FAIL

    T 4                     ; forward label chain: 3 refs then define -> all patched
    ld hl,N_LOOP : ld b,4 : ld de,CODE+0 : call LABEL_REF
    ld hl,N_LOOP : ld b,4 : ld de,CODE+10 : call LABEL_REF
    ld hl,N_LOOP : ld b,4 : ld de,CODE+20 : call LABEL_REF
    call LABEL_CHECK_ALL : cp 41 : jp nz,FAIL          ; undefined label detected
    ld hl,N_LOOP : ld b,4 : ld de,$1234 : call LABEL_DEFINE
    ld hl,(CODE+0)  : ld de,$1234 : or a : sbc hl,de : jp nz,FAIL
    ld hl,(CODE+10) : ld de,$1234 : or a : sbc hl,de : jp nz,FAIL
    ld hl,(CODE+20) : ld de,$1234 : or a : sbc hl,de : jp nz,FAIL
    call LABEL_CHECK_ALL : or a : jp nz,FAIL

    T 5                     ; backward reference to a defined label
    ld hl,N_LOOP : ld b,4 : ld de,CODE+30 : call LABEL_REF
    ld hl,(CODE+30) : ld de,$1234 : or a : sbc hl,de : jp nz,FAIL

    T 6                     ; duplicate definition rejected (40)
    xor a : ld (COMPILE_ERROR_CODE),a
    ld hl,N_LOOP : ld b,4 : ld de,$2222 : call LABEL_DEFINE
    ld a,(COMPILE_ERROR_CODE) : cp 40 : jp nz,FAIL

    T 7                     ; table full -> error 1, nothing corrupted
    ld hl,SYM_TABLE
    ld de,SYM_TABLE+60
    call SYM_INIT
    ld   b,40
    ld   c,0
.fill:
    push bc
    ld   a,c : add a,'a' : ld (NAMEBUF),a : ld a,'x' : ld (NAMEBUF+1),a
    ld   hl,NAMEBUF : ld b,2 : call CSYM_FIND_OR_CREATE
    pop  bc
    inc  c
    djnz .fill
    ld   a,(COMPILE_ERROR_CODE) : cp 1 : jp nz,FAIL
    ld   hl,(SYM_END_V) : ld a,(hl) : or a : jp nz,FAIL   ; still terminated
    ld   hl,(SYM_END_V) : ld de,SYM_TABLE+60 : or a : sbc hl,de : jp nc,FAIL  ; end < limit

    T 8                     ; many symbols (200) in a big table: indices run 0..199
    ld hl,SYM_TABLE : ld de,SYM_TABLE+3000 : call SYM_INIT
    xor a : ld (COMPILE_ERROR_CODE),a
    ld   c,0
.many:
    push bc
    ld   a,c : and $0F : add a,'a' : ld (NAMEBUF),a
    ld   a,c : rrca : rrca : rrca : rrca : and $0F : add a,'a' : ld (NAMEBUF+1),a
    ld   a,'z' : ld (NAMEBUF+2),a
    ld   hl,NAMEBUF : ld b,3 : call CSYM_FIND_OR_CREATE
    pop  bc
    cp   c : jp nz,FAIL            ; index == creation order
    inc  c
    ld   a,c : cp 200 : jr nz,.many
    ld   a,(SYM_COUNTS) : cp 200 : jp nz,FAIL
    ld   a,(COMPILE_ERROR_CODE) : or a : jp nz,FAIL
    jp PASS

N_ALPHA:   DB "alpha"
N_ALPHA_U: DB "ALPHA"
N_BETA:    DB "beta"
N_GAMMA:   DB "gamma"
N_GAMMA_U: DB "GAMMA"
N_LOOP:    DB "loop"

FAIL:
    ld a,2 : out ($FE),a
.f: halt
    jr .f
PASS:
    ld a,4 : out ($FE),a
.p: halt
    jr .p

    DISPLAY "CORE bytes (INIT+FIND+ADD+FOC): ", CORE_END-CORE_BEGIN
    DISPLAY "WRAPPERS bytes (num/str/arr/strarr/label ref+define+check): ", WRAP_END-WRAP_BEGIN
    DS $6000-$,0
    SAVEBIN "build/spikes/tagged_symtab_spike.bin",0,$6000

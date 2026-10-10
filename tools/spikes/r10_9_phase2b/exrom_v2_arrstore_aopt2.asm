; ============================================================================
; rom/exrom_v2_arrstore.asm -- R10.9 Phase 2B PROTOTYPE, architecture C
; (EXROM-owned), eager bind, TIGHTENED.  Service + loader/saver in one file.
;
; Store (segment 2, ARR2_BASE .. PAS_END):
;   entry = [len:2][kind:1 (2 num | 3 str)][namelen:1][name][descriptor]
;   descriptor = the tape body verbatim: [1][count:2]([width:1])[data]
; PAS_END is the absolute end of the store (ARR2_BASE when empty); it is set
; once at cold start (V2_EXROM_ENTRY) and by NEW.
; ============================================================================
ASV_KIND    EQU $B820   ; 1
ASV_IDX     EQU $B821   ; 1
ASV_ENT     EQU $B822   ; 2: entry being built / replaced
ASV_DESC    EQU $B824   ; 2: its descriptor
ASV_NL      EQU $B826   ; 2: its total length


; ---- store iteration -------------------------------------------------------
; ARR_NEXT: HL = entry -> HL = the following entry; then ARR_AT_END.
; ARR_AT_END: CF set when HL is at/after the end of the store (HL preserved).
ARR_NEXT:
    ld e,(hl)
    inc hl
    ld d,(hl)
    dec hl
    add hl,de
ARR_AT_END:
    ld de,(PAS_END)
    push hl
    or a
    sbc hl,de
    pop hl
    ccf
    ret

; ARR_SLOT -- A = array index, C = kind (2/3) -> HL = &pointer slot.  Clobbers DE.
ARR_SLOT:
    ld hl,(RT_ARRPTR_PTR)
    bit 0,c
    jr z,.num
    ld hl,(RT_STRARRPTR_PTR)
.num:
    ld e,a
    ld d,0
    add hl,de
    add hl,de
    ret

; ARR_RUN_INIT -- the shell calls this between VM_INIT and VM_RUN.
; Overflow arrays start above the store.  Then the program's ARRAY symbols are
; walked once (cost O(symbols + arrays x entries), not O(entries x symbols)) and
; each one that has a (kind, name) entry in the store is published in its pointer
; slot.  A declared size or width that differs from the stored one fails the run
; before it starts (error 65) with the store untouched.
ARR_RUN_INIT:
    ld a,(VM_HALTED)
    or a
    ret nz                      ; VM_INIT refused the run
    ld hl,(PAS_END)
    ld (ARR2_END),hl
    ld de,ARR2_BASE
    or a
    sbc hl,de
    ret z                       ; empty store: nothing to bind
    ld hl,(SYM_BASE_V)
.rec:
    ld a,(hl)
    or a
    ret z                       ; end of the compile symbol table
    push hl                     ; record
    inc hl
    ld c,(hl)                   ; kind
    ld a,c
    sub SYM_K_ARR
    cp 2
    jr nc,.next                 ; only numeric / string array symbols
    inc hl
    ld b,(hl)                   ; name length
    inc hl
    ld a,(hl)
    ld (ASV_IDX),a              ; array index
    inc hl                      ; -> name
    call ARR_FIND               ; NC: HL = store entry (keeps B, C)
    jr c,.next
    ld e,b
    ld d,0
    add hl,de
    ld de,4
    add hl,de                   ; HL = descriptor
    ld (ASV_DESC),hl
    inc hl                      ; -> stored count (+ width)
    pop de
    push de                     ; DE = symbol record
    ld a,b
    add a,4
    add a,e
    ld e,a
    jr nc,.nc
    inc d
.nc:                            ; DE -> declared size (+ width)
    ld b,c                      ; compare 2 bytes (numeric) / 3 (string)
.cmp:
    ld a,(de)
    cp (hl)
    jr nz,.mismatch
    inc hl
    inc de
    djnz .cmp
    ld a,(ASV_IDX)
    call ARR_SLOT               ; C = kind -> HL = &slot
    ld de,(ASV_DESC)
    ld (hl),e
    inc hl
    ld (hl),d
.next:
    pop hl
    ld e,(hl)
    ld d,0
    add hl,de
    jr .rec
.mismatch:
    pop hl
    ld a,65
    ld (VM_ERROR_CODE),a
    ld a,1
    ld (VM_HALTED),a
    ret


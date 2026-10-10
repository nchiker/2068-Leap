; ============================================================================
; Phase 2B PROTOTYPE -- the part of the Array Store that is COMMON to
; architectures A, B and C: LOAD ... ARRAY into the store (receive in the free
; tail, validate, atomically replace a same-name entry), SAVE ... ARRAY from
; the live array or the store, name handling.
; ============================================================================
ASV_NAME    EQU $B82D   ; 2: key name pointer for ARR_STORE_FIND
ASV_NLEN    EQU $B82F   ; 1: key name length
ASV_NL      EQU $B830   ; 2: total length of the entry being committed
ASV_EL      EQU $B832   ; 2: length of the entry being replaced

; V2_PAD_NAME -- B = filename length, HL = filename -> STORAGE_LOAD_NAME_BUF
; padded with spaces to 10 characters (shared by V2_LOAD and V2_LOAD_ARRAY).
V2_PAD_NAME:
    ld de,STORAGE_LOAD_NAME_BUF
    ld c,10
.pad:
    ld a,b
    or a
    jr z,.space
    ld a,(hl)
    inc hl
    dec b
    jr .write
.space:
    ld a,' '
.write:
    ld (de),a
    inc de
    dec c
    jr nz,.pad
    ret

; ARR_STORE_FIND -- HL = name, B = name length, C = kind (2/3).
; NC: HL = the entry; CF: not in the store.
ARR_STORE_FIND:
    ld (ASV_NAME),hl
    ld a,c
    ld (ASV_KIND),a
    ld a,b
    ld (ASV_NLEN),a
    ld hl,(PAS_LEN)
    ld de,ARR2_BASE
    add hl,de
    ld (ASV_END),hl
    ld hl,ARR2_BASE
.entry:
    ld (ASV_ENT),hl
    ld de,(ASV_END)
    or a
    sbc hl,de
    jr nc,.nf                   ; reached the end of the store
    ld hl,(ASV_ENT)
    inc hl
    inc hl
    ld a,(ASV_KIND)
    cp (hl)
    jr nz,.next
    inc hl
    ld a,(ASV_NLEN)
    cp (hl)
    jr nz,.next
    inc hl
    ld de,(ASV_NAME)
    ld b,a
    call NAME_CMP_FOLD
    jr nz,.next
    ld hl,(ASV_ENT)
    or a
    ret
.next:
    ld hl,(ASV_ENT)
    ld e,(hl)
    inc hl
    ld d,(hl)
    dec hl
    add hl,de
    jr .entry
.nf:
    scf
    ret

; ARR_VALIDATE -- HL = received descriptor, DE = received length,
; (V2_ARRAY_IS_STR) = kind.  CF = malformed.  Numeric: dim 1, count >= 1,
; length == 3 + 2*count.  String: dim 1, count >= 1, width >= 2, every element
; length byte <= min(width-1, 31) and the elements exactly fill the body.
ARR_VALIDATE:
    ld a,(hl)
    dec a
    jr nz,.bad                  ; dim_count must be 1
    inc hl
    ld c,(hl)
    inc hl
    ld b,(hl)                   ; BC = count
    inc hl
    ld a,b
    or c
    jr z,.bad
    cp 8
    jr nc,.bad                  ; count < 2048 (the store is 2 KB)
    ld a,(V2_ARRAY_IS_STR)
    or a
    jr nz,.string
    ld h,b
    ld l,c
    add hl,hl
    inc hl
    inc hl
    inc hl                      ; 3 + 2*count
    or a
    sbc hl,de
    ret z                       ; equal: CF clear
.bad:
    scf
    ret
.string:
    ld a,(hl)                   ; width
    cp 2
    jr c,.bad
    push af
    ld hl,(ASV_DESC)
    add hl,de
    ld (ASV_END),hl             ; end of the received body
    ld hl,(ASV_DESC)
    inc hl
    inc hl
    inc hl
    inc hl                      ; -> first element
    pop af
    ld e,a
    ld d,0                      ; DE = width
.elem:
    ld a,(hl)
    cp 32
    jr nc,.bad                  ; element length <= 31 (STRTAB slot)
    cp e
    jr nc,.bad                  ; and < width
    add hl,de
    jr c,.bad                   ; wrapped past $FFFF: not a real body
    dec bc
    ld a,b
    or c
    jr nz,.elem
    ld de,(ASV_END)
    or a
    sbc hl,de
    ret z                       ; the elements exactly fill the body
    jr .bad

; V2_LOAD_ARRAY -- entry: V2_NAME_PTR/LEN (tape filename) and V2_ARRAY_NAME_PTR/
; LEN/IS_STR (target array) set by V2_PARSE_NAME / V2_SCAN_ARRAY_NAME.
V2_LOAD_ARRAY:
    call V2_CLEAR_ARRAYS         ; live arrays may overlap the store tail
    ld hl,(PAS_LEN)
    ld de,ARR2_BASE
    add hl,de
    ld (ASV_ENT),hl              ; T: start of the new entry
    inc hl
    inc hl
    ld a,(V2_ARRAY_IS_STR)
    add a,2
    ld (hl),a                    ; kind
    inc hl
    ld a,(V2_ARRAY_NAME_LEN)
    ld (hl),a
    inc hl
    ld c,a
    ld b,0
    ex de,hl
    ld hl,(V2_ARRAY_NAME_PTR)
    ldir                         ; key name copied before EDIT_LINE_BUF is reused
    ld (ASV_DESC),de             ; descriptor goes here
    ld hl,ARR2_LIMIT
    or a
    sbc hl,de
    jp c,.full
    ld a,h
    or l
    jp z,.full
    ex de,hl                     ; DE = room for the descriptor
    ld ix,(ASV_DESC)
    ld a,(V2_NAME_LEN)
    ld b,a
    ld hl,(V2_NAME_PTR)
    push de
    call V2_PAD_NAME
    pop de
    ld a,STORAGE_ARRAY_TYPE
    ld (STORAGE_REQUEST_TYPE),a
    ld hl,STORAGE_LOAD_NAME_BUF
    ld b,10
    call STORAGE_LOAD
    ei
    jp c,.failed
    ld hl,(ASV_DESC)
    push de
    call ARR_VALIDATE
    pop de
    jp c,.bad
    ; NL = L + 4 + namelen
    ld a,(V2_ARRAY_NAME_LEN)
    ld c,a
    ld b,0
    ld hl,4
    add hl,bc
    add hl,de
    ld (ASV_NL),hl
    ex de,hl
    ld hl,(ASV_ENT)
    ld (hl),e
    inc hl
    ld (hl),d                    ; entry length field
    ; replace a same-name entry, atomically (the old one still exists here)
    ld hl,(ASV_ENT)
    ld bc,4
    add hl,bc                    ; the name copy inside the new entry
    ld a,(V2_ARRAY_NAME_LEN)
    ld b,a
    ld a,(V2_ARRAY_IS_STR)
    add a,2
    ld c,a
    call ARR_STORE_FIND
    jr c,.append
    ld e,(hl)
    inc hl
    ld d,(hl)
    dec hl                       ; HL = old entry E, DE = its length
    ld (ASV_EL),de
    push hl                      ; E (destination)
    add hl,de                    ; source = E + EL
    ex de,hl                     ; DE = source
    ld hl,(ASV_ENT)
    ld bc,(ASV_NL)
    add hl,bc                    ; HL = end of the new entry
    or a
    sbc hl,de
    ld b,h
    ld c,l                       ; BC = bytes to move down
    ld h,d
    ld l,e                       ; HL = source
    pop de                       ; DE = destination
    ldir
    ld hl,(PAS_LEN)
    ld de,(ASV_EL)
    or a
    sbc hl,de
    ld de,(ASV_NL)
    add hl,de
    ld (PAS_LEN),hl
    jr .loaded
.append:
    ld hl,(PAS_LEN)
    ld de,(ASV_NL)
    add hl,de
    ld (PAS_LEN),hl
.loaded:
    ld hl,V2_MSG_LOADED
    jp V2_SHOW_MESSAGE
.full:
    ld hl,V2_MSG_STORE_FULL
    jp V2_SHOW_MESSAGE
.bad:
    ld hl,V2_MSG_BAD_ARRAY
    jp V2_SHOW_MESSAGE
.failed:                         ; clean: the tail is scratch until PAS_LEN moves
    ld hl,V2_MSG_BAD_VERSION
    cp STORAGE_LOAD_BAD_VERSION
    jr z,.show
    ld hl,V2_MSG_ABORTED
    inc b
    dec b
    jr nz,.show
    ld hl,V2_MSG_LOAD_FAILED
.show:
    jp V2_SHOW_MESSAGE

; ARR_SAVE_STORE -- SAVE ... ARRAY of a name that is not a live array of the last
; compile: serve it from the store if it is there.
ARR_SAVE_STORE:
    ld a,(V2_ARRAY_IS_STR)
    add a,2
    ld c,a
    ld a,(V2_ARRAY_NAME_LEN)
    ld b,a
    ld hl,(V2_ARRAY_NAME_PTR)
    call ARR_STORE_FIND
    jr c,.none
    ld e,(hl)
    inc hl
    ld d,(hl)                    ; DE = entry length
    inc hl
    inc hl
    ld c,(hl)                    ; namelen
    inc hl
    ld b,0
    add hl,bc                    ; HL = descriptor
    push hl
    pop ix
    ex de,hl
    or a
    sbc hl,bc
    ld bc,4
    or a
    sbc hl,bc
    ex de,hl                     ; DE = descriptor length
    ld a,(V2_NAME_LEN)
    ld b,a
    ld hl,(V2_NAME_PTR)
    ld a,STORAGE_ARRAY_TYPE
    ld (STORAGE_REQUEST_TYPE),a
    call STORAGE_SAVE
    ei
    ld hl,V2_MSG_SAVED
    jp V2_SHOW_MESSAGE
.none:
    ld hl,V2_MSG_ARRAY_NOT_DIMD
    jp V2_SHOW_MESSAGE

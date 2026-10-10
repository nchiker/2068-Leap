; ---- common part (loader / saver), tightened -------------------------------
ASV_EL      EQU $B828   ; 2: length of the entry being replaced

; V2_PAD_NAME -- B = filename length, HL = filename -> STORAGE_LOAD_NAME_BUF
; padded with spaces to 10 characters (shared by V2_LOAD and V2_LOAD_ARRAY).
V2_PAD_NAME:
    ld de,STORAGE_LOAD_NAME_BUF
    ld c,10
.pad:
    ld a,' '
    inc b
    dec b
    jr z,.write
    ld a,(hl)
    inc hl
    dec b
.write:
    ld (de),a
    inc de
    dec c
    jr nz,.pad
    ret

; ARR_FIND -- HL = name, B = name length, C = kind (2/3).
; NC: HL = the entry; CF: not in the store.
ARR_FIND:
    push hl
    pop ix
    ld hl,ARR2_BASE
    call ARR_AT_END
.l:
    ret c
    push hl
    inc hl
    inc hl
    ld a,c
    cp (hl)
    jr nz,.n
    inc hl
    ld a,b
    cp (hl)
    jr nz,.n
    inc hl
    push ix
    pop de
    push bc
    call NAME_CMP_FOLD
    pop bc
    jr nz,.n
    pop hl
    or a
    ret
.n:
    pop hl
    call ARR_NEXT
    jr .l

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
    ld (ASV_NL),hl              ; end of the received body (scratch)
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
    ld de,(ASV_NL)
    or a
    sbc hl,de
    ret z                       ; the elements exactly fill the body
    jr .bad

; V2_LOAD_ARRAY -- entry: V2_NAME_PTR/LEN (tape filename) and V2_ARRAY_NAME_PTR/
; LEN/IS_STR (target array) set by V2_PARSE_NAME / V2_SCAN_ARRAY_NAME.
V2_LOAD_ARRAY:
    call V2_CLEAR_ARRAYS         ; live arrays may overlap the store tail
    ld hl,(PAS_END)
    ld (ASV_ENT),hl              ; start of the new entry
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
    push hl                      ; room for the descriptor
    ld a,(V2_NAME_LEN)
    ld b,a
    ld hl,(V2_NAME_PTR)
    call V2_PAD_NAME
    ld a,STORAGE_ARRAY_TYPE
    ld (STORAGE_REQUEST_TYPE),a
    ld ix,(ASV_DESC)
    pop de
    ld hl,STORAGE_LOAD_NAME_BUF
    ld b,10
    call STORAGE_LOAD
    ei
    jp c,.failed
    ld hl,(ASV_DESC)
    push de
    call ARR_VALIDATE
    pop de                       ; DE = received length
    jp c,.bad
    ld a,(V2_ARRAY_NAME_LEN)
    add a,4
    ld l,a
    ld h,0
    add hl,de                    ; NL = L + 4 + namelen
    ld (ASV_NL),hl
    ex de,hl
    ld hl,(ASV_ENT)
    ld (hl),e
    inc hl
    ld (hl),d                    ; entry length field
    ; replace a same-name entry atomically: the old one still exists here
    inc hl
    inc hl
    inc hl                       ; the name copy inside the new entry
    ld a,(V2_ARRAY_NAME_LEN)
    ld b,a
    ld a,(V2_ARRAY_IS_STR)
    add a,2
    ld c,a
    call ARR_FIND
    ld de,0
    jr c,.commit
    ld e,(hl)
    inc hl
    ld d,(hl)
    dec hl                       ; HL = old entry, DE = its length
    push hl                      ; destination
    add hl,de
    push de                      ; EL
    ex de,hl                     ; DE = source
    ld hl,(ASV_ENT)
    ld bc,(ASV_NL)
    add hl,bc                    ; end of the new entry
    or a
    sbc hl,de
    ld b,h
    ld c,l                       ; BC = bytes to move down
    ld h,d
    ld l,e                       ; HL = source
    pop de                       ; DE = EL ...
    ex (sp),hl                   ; HL = destination, (sp) = source
    ex de,hl                     ; DE = destination, HL = EL
    ex (sp),hl                   ; HL = source, (sp) = EL
    ldir
    pop de                       ; DE = EL
.commit:
    ld hl,(PAS_END)
    ld bc,(ASV_NL)
    add hl,bc
    or a
    sbc hl,de
    ld (PAS_END),hl
    ld hl,V2_MSG_LOADED
    jp V2_SHOW_MESSAGE
.full:
    ld hl,V2_MSG_STORE_FULL
    jp V2_SHOW_MESSAGE
.bad:
    ld hl,V2_MSG_BAD_ARRAY
    jp V2_SHOW_MESSAGE
.failed:                         ; clean: the tail is scratch until PAS_END moves
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
    call ARR_FIND
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

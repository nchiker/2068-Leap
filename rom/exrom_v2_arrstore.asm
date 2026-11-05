; ============================================================================
; rom/exrom_v2_arrstore.asm -- R10.9 Phase 2C: the persistent Array Store
; (architecture C: an EXROM-owned service with eager bind; see
; docs/R10_9_PHASE2B_REPORT.md and docs/R10_9_PHASE2C_REPORT.md).
;
; Store (segment 2, ARR2_BASE .. PAS_END):
;   entry = [len:2][kind:1 (2 numeric | 3 string)][namelen:1][name][descriptor]
;   descriptor = the tape body verbatim: [1][count:2]([width:1])[data]
; PAS_END is the absolute end of the store (ARR2_BASE when empty); it is set
; once at cold start (V2_EXROM_ENTRY) and by NEW -- never by MEM_INIT_V2.
; Scratch cells ASV_* and PAS_END live in include/v2_layout.inc.
;
; Contents: ARR_RUN_INIT (bind + validate, called by the shell between VM_INIT and
; VM_RUN and by CLEAR), ARR_OP_DIM / ARR_OP_DIM_STR (opcodes 63/64, reached through
; the two fixed jp slots below), ARR_FIND, the tape-array validator and loader
; (V2_LOAD_ARRAY), SAVE-from-store (ARR_SAVE_STORE) and V2_PAD_NAME.
;
; Invariants: the store never moves or changes size during a RUN; ARR2_END >= PAS_END
; at all times; every mutation (LOAD ... ARRAY, NEW) is prompt-time and first discards
; the live arrays and symbol table (V2_CLEAR_ARRAYS).
; ============================================================================

; Fixed-address slots called/jumped to from HOME (the opcode table).
ARRSVC_TABLE:
    jp ARR_OP_DIM
    jp ARR_OP_DIM_STR

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
    call V2_VERIFY_KTAB         ; the opcode table reaches ARR_DIM without a trampoline
    ld a,(VM_HALTED)
    or a
    ret nz                      ; VM_INIT refused the run
    ld hl,(PAS_END)
    ld (ARR2_END),hl
ARR_RUN_BIND:                   ; RC (session): bind the store without resetting segment 2
    xor a
    db $01                      ; ld bc,nn: swallows the 2-byte ld a,1 below (BC is free here)
ARR_RUN_CHECK:                  ; RC (session): only compare; CF = a declared size differs from the
    ld a,1                      ; stored one. Nothing is bound (the tables may not be carved yet)
    ld (ASV_CHECK),a
    ld hl,(PAS_END)
    ld a,h
    sub ARR2_BASE >> 8
    or l
    ret z                       ; PAS_END == ARR2_BASE: empty store, nothing to bind
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
    ld a,(ASV_CHECK)
    or a
    jr nz,.next
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
    ld a,(ASV_CHECK)
    or a
    scf
    ret nz                      ; check only: CF
    ld a,65
    jp VM_ERR_COMMON            ; error 65 (ARRAY SIZE MISMATCH), VM halted

; ---- opcodes 63 / 64: DIM a(n) / DIM a$(n,w) -------------------------------
ARR_OP_DIM:
    ld c,SYM_K_ARR
    jr ARR_DIM
ARR_OP_DIM_STR:
    ld c,SYM_K_SARR
ARR_DIM:                        ; C = kind
    ld hl,(VM_IP)
    ld a,(hl)
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    bit 0,c
    jr z,.nw
    ld b,(hl)                   ; width
    inc hl
.nw:
    ld (VM_IP),hl
    ld (ASV_IDX),a
    push bc
    push de
    call ARR_SLOT               ; (A = index, C = kind)
    ld e,(hl)
    inc hl
    ld d,(hl)                   ; DE = current slot
    ld a,d
    cp ARR2_BASE >> 8
    jr c,.alloc                 ; 0 or a main-pool array: allocate
    ex de,hl
    call ARR_AT_END
    jr c,.alloc                 ; at/after PAS_END: an overflow array, allocate
    pop de                      ; slot points into the store: adopted
    pop bc
    jp (iy)                     ; RC: VM_RUN.loop (IY, set by VM_RUN)
.alloc:
    pop de
    pop bc
    ld a,d                      ; QUAL (Q-04): more than 16383 elements can never fit (and would
    cp $40                      ; overflow count*2 / count*width): OUT OF MEMORY, nothing allocated
    jp nc,VM_ERR_ARRAY_SPACE
    ld a,c
    ld (ASV_KIND),a
    ld a,(ASV_IDX)
    bit 0,c
    jr nz,.str
    call ARENA_ALLOC_NUMERIC    ; HOME core, unchanged
    ld bc,(VM_DIM_COUNT_TMP)
    sla c
    rl b                        ; BC = count*2
    ld de,3
    jr .fill
.str:
    ld c,b
    call ARENA_ALLOC_STRING
    ld bc,(VM_STRARR_ADDR_TMP)  ; count*width, cached by the allocator
    ld de,4
.fill:
    ld a,(VM_HALTED)
    or a
    jp nz,VM_RUN_LOOP           ; allocation failed: error already raised
    push bc
    push de
    ld a,(ASV_KIND)
    ld c,a
    ld a,(ASV_IDX)
    call ARR_SLOT
    ld c,(hl)
    inc hl
    ld b,(hl)                   ; BC = descriptor
    pop hl
    add hl,bc                   ; HL = first data byte
    pop bc                      ; BC = data length
    call KTAB_MEM_FILL_ZERO     ; D12: DIM zero-fills
    jp (iy)                     ; RC: VM_RUN.loop (IY, set by VM_RUN)

; ---- tape side: name padding, lookup, validator, loader, saver ---------------

; V2_PAD_NAME -- B = filename length, HL = filename -> STORAGE_LOAD_NAME_BUF
; padded with spaces to 10 characters. V2_PAD_NAME_V: of the parsed name (V2_NAME_PTR/LEN),
; shared by V2_LOAD and V2_LOAD_ARRAY. Destroys AF, BC, DE, HL.
V2_PAD_NAME_V:
    ld a,(V2_NAME_LEN)
    ld b,a
    ld hl,(V2_NAME_PTR)
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
    cp 16
    jr nc,.bad                  ; count < 4096: every count that fits the store (ASSERT below);
                                ; 3 + 2*count and the string walk cannot pass $FFFF
    or c
    jr z,.bad                   ; count >= 1
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
    ld hl,(ASV_DESC)            ; (A = width is preserved by the loads/adds below)
    add hl,de
    ld (ASV_NL),hl              ; end of the received body (scratch)
    ld hl,(ASV_DESC)
    inc hl
    inc hl
    inc hl
    inc hl                      ; -> first element
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
    call V2_CLEAR_ARRAYS         ; live arrays and symbols go (the session ends); the store stays
    ld hl,(ARRAYS_END)           ; v2.2: the new entry is staged here, in the pool the LOAD has just emptied,
    inc hl                       ; past the empty symbol table, so a replacement needs room for only ONE
    inc hl                       ; copy and the store is untouched until the body is valid (the length
    ld bc,(V2_ARRAY_NAME_LEN)    ; field is filled after validation).  C = name length, B = IS_STR
    inc b
    inc b
    ld (hl),b                    ; kind
    inc hl
    ld (hl),c                    ; name length
    inc hl
    ld b,0
    ex de,hl
    ld hl,(V2_ARRAY_NAME_PTR)
    ldir                         ; key name copied before EDIT_LINE_BUF is reused
    ld (ASV_DESC),de             ; the descriptor follows the name (ARR_VALIDATE reads it)
    push de                      ; -> IX
    call V2_PAD_NAME_V
    ld a,STORAGE_ARRAY_TYPE
    ld (STORAGE_REQUEST_TYPE),a
    call .find                   ; DE = where the entry goes once a same-name one is gone (PAS_END - EL); B = name length
    ld a,(ARR2_LIMIT - 4) & $FF
    sub b                        ; (never borrows: ASSERT below)
    ld l,a
    ld h,(ARR2_LIMIT - 4) >> 8   ; HL = ARR2_LIMIT - 4 - namelen
    sbc hl,de                    ; = ARR2_LIMIT + EL - PAS_END - (namelen + 4): the room for the descriptor
    pop bc                       ; BC = the staged descriptor (flags kept)
    jr c,.full                   ; not even the key fits: nothing has been touched
    push bc
    pop ix
    ex de,hl                     ; DE = the store's room
    ld hl,V2_CODE_LIMIT          ; v2.2 (item C): the body is staged in the pool, which can be smaller than
    sbc hl,bc                    ; (NC) the store (7424 B): HL = the pool's room
    sbc hl,de
    add hl,de                    ; (CF as the sbc) CF: the pool's room is the smaller
    jr nc,.room
    ex de,hl
.room:                           ; DE = max body length: a longer tape is ARRAY STORE FULL (STORAGE_LOAD_TOO_LONG)
    ld hl,STORAGE_LOAD_NAME_BUF
    ld b,10
    call STORAGE_LOAD
    ei
    jr c,.failed
    ld hl,(ASV_DESC)
    push de
    call ARR_VALIDATE
    pop de                       ; DE = received length
    jr c,.bad
    ld a,(V2_ARRAY_NAME_LEN)
    add a,4
    ld l,a
    ld h,0
    add hl,de                    ; NL = L + 4 + namelen
    push hl                      ; (for the final copy)
    ex de,hl
    ld hl,(ARRAYS_END)
    ld (hl),e
    inc hl
    ld (hl),d                    ; the staged entry's length field
    ; commit: nothing in the store has changed up to here
    call .find                   ; DE = X; NC: HL = the old entry
    jr c,.add                    ; none: X = PAS_END
    ex de,hl                     ; HL = X, DE = the old entry (the destination)
    push hl
    sbc hl,de                    ; (NC) the bytes after the old entry; Z = it was the last
    jr z,.nomove                 ; (LDIR with BC = 0 would copy 64 KB)
    ld b,h
    ld c,l
    ld hl,(PAS_END)
    sbc hl,bc                    ; (NC) the source: the end of the old entry
    ldir
.nomove:
    pop de                       ; DE = X
.add:
    ld hl,(ARRAYS_END)           ; the staged entry
    pop bc                       ; NL
    ldir
    ld (PAS_END),de              ; DE = the end of the store
    ld hl,V2_MSG_LOADED
.show:
    jp V2_SHOW_MESSAGE
.full:
    ld hl,V2_MSG_STORE_FULL
    jr .show
.bad:
    ld hl,V2_MSG_BAD_ARRAY
    jr .show
.failed:                         ; clean: the store has not been touched
    ld hl,V2_MSG_BAD_VERSION
    inc a
    inc a                        ; $FE (STORAGE_LOAD_BAD_VERSION) -> 0
    jr z,.show
    inc a                        ; $FD (STORAGE_LOAD_TOO_LONG: the array is longer than the room) -> 0
    jr z,.full
    ld hl,V2_MSG_ABORTED
    inc b
    dec b
    jr nz,.show
    ld hl,V2_MSG_LOAD_FAILED
    jr .show

; .find -- the staged entry's kind, name length and name (ARRAYS_END + 2 ...): DE = X = PAS_END - the length of
; the store entry of that name (PAS_END if there is none; ARR_AT_END leaves it in DE); NC: HL = that entry.
; Keeps B = the name length.
.find:
    ld hl,(ARRAYS_END)
    inc hl
    inc hl
    ld c,(hl)                    ; kind
    inc hl
    ld b,(hl)                    ; name length
    inc hl
    call ARR_FIND                ; keeps B and C
    ret c                        ; none: DE = (PAS_END)
    ld e,(hl)
    inc hl
    ld d,(hl)
    dec hl                       ; DE = EL
    push hl
    ld hl,(PAS_END)
    sbc hl,de                    ; (NC from ARR_FIND)
    ex de,hl                     ; DE = X
    pop hl
    ret

    ASSERT V2_ARRAY_IS_STR = V2_ARRAY_NAME_LEN + 1
    ASSERT ((ARR2_LIMIT - 4) & $FF) >= IDENT_MAX_LEN
    ASSERT STORAGE_LOAD_BAD_VERSION = $FE && STORAGE_LOAD_TOO_LONG = $FD
    ; ARR_VALIDATE's count guard (high byte < 16) passes every count whose body fits the store
    ; (a numeric element is 2 bytes, a string element at least 2).
    ASSERT (ARR2_LIMIT - ARR2_BASE) / 2 < 16 * 256

; ARR_SAVE_STORE -- SAVE ... ARRAY of a name that is not a live array of the last
; compile: serve it from the store if it is there.  Finishes through V2_SAVE_ARRAY's own
; send tail (HL = descriptor length, descriptor address on the stack).
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
    push hl                      ; (popped into IX by .send)
    ex de,hl
    or a
    sbc hl,bc                    ; entry length - namelen
    dec hl
    dec hl
    dec hl
    dec hl                       ; - 4 = descriptor length
    jp V2_SAVE_ARRAY.send
.none:
    ld hl,V2_MSG_ARRAY_NOT_DIMD
    jp V2_SHOW_MESSAGE

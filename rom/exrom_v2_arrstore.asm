; ============================================================================
; rom/exrom_v2_arrstore.asm -- R10.9 Phase 2C: the persistent Array Store
; (architecture C: an EXROM-owned service with eager bind; see
; docs/v2/R10_9_PHASE2B_REPORT.md and docs/v2/R10_9_PHASE2C_REPORT.md).
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
    db $FE                      ; cp n: skips the ld a,1 below
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
    jp VM_RUN_LOOP
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
    jp VM_RUN_LOOP

; ---- tape side: name padding, lookup, validator, loader, saver ---------------

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
    cp 8
    jr nc,.bad                  ; count < 2048 (the store is 2 KB)
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
    call V2_CLEAR_ARRAYS         ; live arrays may overlap the store tail
    ld hl,(PAS_END)
    ld (ASV_ENT),hl              ; start of the new entry
    ld a,(V2_ARRAY_NAME_LEN)
    add a,4
    ld e,a
    ld d,0
    add hl,de                    ; HL = where the descriptor will go
    ld (ASV_DESC),hl
    ex de,hl
    ld hl,ARR2_LIMIT-1           ; room check BEFORE anything is written: the header
    or a                         ; and key name must not spill past the store
    sbc hl,de
    jp c,.full                   ; descriptor would start at/after ARR2_LIMIT
    inc hl
    push hl                      ; room for the descriptor (1..)
    ld hl,(ASV_ENT)
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
.show:
    jp V2_SHOW_MESSAGE
.full:
    ld hl,V2_MSG_STORE_FULL
    jr .show
.bad:
    ld hl,V2_MSG_BAD_ARRAY
    jr .show
.failed:                         ; clean: the tail is scratch until PAS_END moves
    ld hl,V2_MSG_BAD_VERSION
    cp STORAGE_LOAD_BAD_VERSION
    jr z,.show
    ld hl,V2_MSG_ABORTED
    inc b
    dec b
    jr nz,.show
    ld hl,V2_MSG_LOAD_FAILED
    jr .show

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

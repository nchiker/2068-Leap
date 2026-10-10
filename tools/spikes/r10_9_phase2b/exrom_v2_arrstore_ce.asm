; ============================================================================
; rom/exrom_v2_arrstore.asm -- R10.9 Phase 2B PROTOTYPE, architecture C
; (EXROM-owned), EAGER bind.  Bind / adopt / DIM / zero-fill only; the store
; loader, saver and compactor (identical in every architecture) are not here.
;
; Store (segment 2, ARR2_BASE .. ARR2_BASE+PAS_LEN):
;   entry = [len:2][kind:1 (2 num | 3 str)][namelen:1][name][descriptor]
;   descriptor = the tape body verbatim: [1][count:2]([width:1])[data]
; ============================================================================
ASV_IDX     EQU $B820   ; 1
ASV_KIND    EQU $B821   ; 1
ASV_END     EQU $B822   ; 2: first byte past the store
ASV_ENT     EQU $B824   ; 2: entry under inspection
ASV_DESC    EQU $B826   ; 2

; Fixed-address slots called/jumped to from HOME (the opcode table).
ARRSVC_TABLE:
    jp ARR_OP_DIM
    jp ARR_OP_DIM_STR

; ARR_RUN_INIT -- the shell calls this between VM_INIT and VM_RUN.
; Segment-2 overflow starts above the store, then every stored array whose
; (kind, name) is declared by the program is published in its pointer slot.
; A stored array whose declared size/width differs fails the run before it
; starts (error 65) with the store untouched.
ARR_RUN_INIT:
    ld a,(VM_HALTED)
    or a
    ret nz                      ; VM_INIT refused the run (tables did not fit)
    ld hl,(PAS_LEN)
    ld de,ARR2_BASE
    add hl,de
    ld (ARR2_END),hl            ; overflow arrays live above the store
    ld (ASV_END),hl
    ld hl,ARR2_BASE
.entry:
    ld de,(ASV_END)
    or a
    sbc hl,de
    ret nc                      ; end of store
    add hl,de
    ld (ASV_ENT),hl
    inc hl
    inc hl
    ld c,(hl)                   ; kind
    inc hl
    ld b,(hl)                   ; name length
    inc hl                      ; -> name
    call SYM_FIND               ; NC: A = index, HL = record (preserves B, C)
    jr c,.next                  ; the program does not declare it: inert
    ld (ASV_IDX),a
    ld a,c
    ld (ASV_KIND),a
    ld e,b
    ld d,0
    add hl,de
    ld de,4
    add hl,de
    ex de,hl                    ; DE -> declared size (+width)
    ld hl,(ASV_ENT)
    ld a,b
    add a,4
    ld c,a
    ld b,0
    add hl,bc                   ; HL = descriptor
    ld (ASV_DESC),hl
    inc hl                      ; -> stored count (+width)
    ld a,(ASV_KIND)
    ld b,a                      ; compare 2 bytes (numeric) / 3 (string)
.cmp:
    ld a,(de)
    cp (hl)
    jr nz,.mismatch
    inc hl
    inc de
    djnz .cmp
    ld a,(ASV_KIND)
    ld c,a
    ld a,(ASV_IDX)
    call ARR_SLOT               ; HL = &slot
    ld de,(ASV_DESC)
    ld (hl),e
    inc hl
    ld (hl),d
.next:
    ld hl,(ASV_ENT)
    ld e,(hl)
    inc hl
    ld d,(hl)
    dec hl
    add hl,de
    jr .entry
.mismatch:
    ld a,65
    ld (VM_ERROR_CODE),a
    ld a,1
    ld (VM_HALTED),a
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

; ---- opcode 63: DIM a(n)    operand [index:1][count:2] -------------------
ARR_OP_DIM:
    ld hl,(VM_IP)
    ld a,(hl)
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld (VM_IP),hl
    ld c,SYM_K_ARR
    jr ARR_DIM

; ---- opcode 64: DIM a$(n,w)  operand [index:1][count:2][width:1] ----------
ARR_OP_DIM_STR:
    ld hl,(VM_IP)
    ld a,(hl)
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld b,(hl)
    inc hl
    ld (VM_IP),hl
    ld c,SYM_K_SARR

; ARR_DIM -- A = index, C = kind, DE = count, B = width (strings).
; An array already bound to a store entry is adopted as is; anything else is
; allocated by the unchanged HOME allocator and zero-filled (D12).
ARR_DIM:
    push bc
    push de
    push af
    call ARR_SLOT
    ld e,(hl)
    inc hl
    ld d,(hl)                   ; DE = current slot
    ld a,d
    cp ARR2_BASE >> 8
    jr c,.alloc                 ; 0 or a main-pool array: allocate
    ld hl,(PAS_LEN)
    ld bc,ARR2_BASE
    add hl,bc
    or a
    sbc hl,de
    jr c,.alloc
    jr z,.alloc
    pop af                      ; slot points into the store: adopted
    pop de
    pop bc
    jp VM_RUN_LOOP
.alloc:
    pop af
    pop de
    pop bc
    bit 0,c
    jr nz,.str
    call ARENA_ALLOC_NUMERIC
    ld a,(VM_HALTED)
    or a
    jp nz,VM_RUN_LOOP
    ld hl,0
    ld (VM_ARR_ELEM_TMP),hl
    call VM_ARR_ADDR            ; HL -> data[0]
    ld bc,(VM_DIM_COUNT_TMP)
    sla c
    rl b                        ; BC = count*2
    jr .fill
.str:
    ld c,b
    call ARENA_ALLOC_STRING
    ld a,(VM_HALTED)
    or a
    jp nz,VM_RUN_LOOP
    ld bc,(VM_STRARR_ADDR_TMP)  ; count*width, cached by the allocator
    push bc
    ld hl,0
    ld (VM_ARR_ELEM_TMP),hl
    call VM_STRARR_ADDR         ; HL -> data[0]
    pop bc
.fill:
    call KTAB_MEM_FILL_ZERO
    jp VM_RUN_LOOP

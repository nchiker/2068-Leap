; ============================================================================
; rom/exrom_v2_arrstore.asm -- R10.9 Phase 2B PROTOTYPE (architecture C).
; Measurement / proof-of-concept only: bind, adopt, DIM and zero-fill.  The
; store LOADER / SAVER / compactor (identical in every architecture) is NOT
; here.
;
; Store (segment 2, ARR2_BASE .. ARR2_BASE+PAS_LEN):
;   entry = [len:2][kind:1 (2 num | 3 str)][namelen:1][name][descriptor]
;   descriptor = the tape body verbatim: [1][count:2]([width:1])[data]
; ============================================================================
ASV_IDX     EQU $B820   ; 1: array index being bound
ASV_KIND    EQU $B821   ; 1: SYM_K_ARR / SYM_K_SARR
ASV_NLEN    EQU $B822   ; 1: name length
ASV_NAME    EQU $B823   ; 2: -> name in the compile symbol record
ASV_EXTRA   EQU $B825   ; 2: -> declared size (+width) in that record
ASV_END     EQU $B827   ; 2: first byte past the store
ASV_ENT     EQU $B829   ; 2: entry under inspection
ASV_DESC    EQU $B82B   ; 2: matched descriptor

; Fixed-address entry slots (HOME jumps/calls through V2_EXROM_ARR_*_ADDR).
ARRSVC_TABLE:
    jp ARR_OP_DIM
    jp ARR_OP_DIM_STR
    jp ARR_LAZY_NUM
    jp ARR_LAZY_STR

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
    push de
    push af
    ld c,SYM_K_ARR
    call ARR_BIND               ; CF=0 adopted | CF=1: A=0 no entry, A=1 mismatch
    jr nc,.done
    or a
    jr nz,.mismatch
    pop af
    pop de
    call ARENA_ALLOC_NUMERIC    ; A=index, DE=count (HOME core, unchanged)
    ld a,(VM_HALTED)
    or a
    jp nz,VM_RUN_LOOP
    ld hl,0
    ld (VM_ARR_ELEM_TMP),hl
    call VM_ARR_ADDR            ; HL -> data[0] of the new array
    ld bc,(VM_DIM_COUNT_TMP)
    sla c
    rl b                        ; BC = count*2
    call KTAB_MEM_FILL_ZERO     ; D12: DIM zero-fills
    jp VM_RUN_LOOP
.done:
    pop af
    pop de
    jp VM_RUN_LOOP
.mismatch:
    pop af
    pop de
    jp ARR_ERR_SHAPE

; ---- opcode 64: DIM a$(n,w)  operand [index:1][count:2][width:1] ----------
ARR_OP_DIM_STR:
    ld hl,(VM_IP)
    ld b,(hl)
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
    inc hl
    ld c,(hl)
    inc hl
    ld (VM_IP),hl
    push bc
    push de
    ld a,b
    ld c,SYM_K_SARR
    call ARR_BIND
    jr nc,.done
    or a
    jr nz,.mismatch
    pop de
    pop bc
    ld a,b
    call ARENA_ALLOC_STRING     ; A=index, DE=count, C=width
    ld a,(VM_HALTED)
    or a
    jp nz,VM_RUN_LOOP
    ld bc,(VM_STRARR_ADDR_TMP)  ; count*width, cached by the allocator
    ld hl,0
    ld (VM_ARR_ELEM_TMP),hl
    push bc
    call VM_STRARR_ADDR         ; HL -> data[0]
    pop bc
    call KTAB_MEM_FILL_ZERO
    jp VM_RUN_LOOP
.done:
    pop de
    pop bc
    jp VM_RUN_LOOP
.mismatch:
    pop de
    pop bc
ARR_ERR_SHAPE:
    ld a,65
    ld (VM_ERROR_CODE),a
    ld a,1
    ld (VM_HALTED),a
    jp VM_RUN_LOOP

; ---- lazy bind: the "slot is 0" exit of VM_ARR_ADDR / VM_STRARR_ADDR -----
; Out: CF=0 bound, DE = descriptor; CF=1 not bound (caller raises error 10).
ARR_LAZY_NUM:
    ld a,(VM_ARR_INDEX_TMP)
    ld c,SYM_K_ARR
    jr ARR_BIND
ARR_LAZY_STR:
    ld a,(VM_STRARR_INDEX_TMP)
    ld c,SYM_K_SARR
; fall into ARR_BIND

; ARR_BIND -- A = array index, C = kind.  Look the array's name up in the
; compile symbol table, find the store entry with that (kind, name), check the
; declared size (+width) against the stored descriptor and publish its address
; in the run-time pointer slot.
; Out: CF=0 bound (DE = descriptor); CF=1, A=0 no store entry; CF=1, A=1 the
; entry exists but its size/width differ from the declaration.
ARR_BIND:
    ld (ASV_IDX),a
    ld a,c
    ld (ASV_KIND),a
    ld hl,(PAS_LEN)
    ld a,h
    or l
    jp z,.none                  ; empty store: ordinary programs pay ~30 T
    ld de,ARR2_BASE
    add hl,de
    ld (ASV_END),hl
    ; --- reverse symbol lookup: (kind, index) -> record ---
    ld a,(ASV_IDX)
    ld b,a
    ld hl,(SYM_BASE_V)
.sym:
    ld a,(hl)
    or a
    jp z,.none
    ld e,a
    ld d,0
    inc hl
    ld a,(ASV_KIND)
    cp (hl)
    jr nz,.symskip
    inc hl
    inc hl
    ld a,(hl)                   ; index
    cp b
    jr z,.symfound
    dec hl
    dec hl
.symskip:
    dec hl                      ; back to record start (HL was at +1 or +1)
    add hl,de
    jr .sym
.symfound:
    dec hl
    ld a,(hl)                   ; namelen
    ld (ASV_NLEN),a
    inc hl
    inc hl                      ; -> name (record +4)
    ld (ASV_NAME),hl
    ld e,a
    ld d,0
    add hl,de
    ld (ASV_EXTRA),hl
    ; --- walk the store ---
    ld hl,ARR2_BASE
.entry:
    ld (ASV_ENT),hl
    ld de,(ASV_END)
    or a
    sbc hl,de
    jp nc,.none
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
    jr z,.found
.next:
    ld hl,(ASV_ENT)
    ld e,(hl)
    inc hl
    ld d,(hl)
    dec hl
    add hl,de
    jr .entry
.found:
    ld (ASV_DESC),hl
    inc hl                      ; -> stored count (+ width)
    ld de,(ASV_EXTRA)
    ld a,(ASV_KIND)
    ld b,a                      ; kind 2 -> compare 2 bytes, kind 3 -> 3
.cmp:
    ld a,(de)
    cp (hl)
    jp nz,.mismatch
    inc hl
    inc de
    djnz .cmp
    ld hl,(RT_ARRPTR_PTR)
    ld a,(ASV_KIND)
    cp SYM_K_ARR
    jr z,.slot
    ld hl,(RT_STRARRPTR_PTR)
.slot:
    ld a,(ASV_IDX)
    ld e,a
    ld d,0
    add hl,de
    add hl,de
    ld de,(ASV_DESC)
    ld (hl),e
    inc hl
    ld (hl),d
    or a                        ; CF=0
    ret
.none:
    xor a
    scf
    ret
.mismatch:
    ld a,1
    scf
    ret

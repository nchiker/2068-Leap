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

; Fixed-address slots called from the (HOME) DIM handlers.
ARRSVC_TABLE:
    jp ARR_ADOPT
    jp ARR_ZERO_NUM
    jp ARR_ZERO_STR

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
; Overflow arrays start above the store; every stored array whose (kind, name)
; the program declares is published in its pointer slot.  A declared size or
; width that differs from the stored one fails the run before it starts
; (error 65) with the store untouched.
ARR_RUN_INIT:
    ld a,(VM_HALTED)
    or a
    ret nz                      ; VM_INIT refused the run
    ld hl,(PAS_END)
    ld (ARR2_END),hl
    ld hl,ARR2_BASE
    call ARR_AT_END
.entry:
    ret c
    push hl
    inc hl
    inc hl
    ld c,(hl)                   ; kind
    inc hl
    ld b,(hl)                   ; name length
    inc hl                      ; -> name
    call SYM_FIND               ; NC: A = index, HL = record (keeps B, C)
    jr c,.next
    ld (ASV_IDX),a
    ld a,c
    ld (ASV_KIND),a
    ld e,b
    ld d,0
    add hl,de
    ld de,4
    add hl,de
    ex de,hl                    ; DE -> declared size (+width)
    pop hl
    push hl
    ld a,b
    add a,4
    ld c,a
    ld b,0
    add hl,bc                   ; HL = descriptor
    ld (ASV_DESC),hl
    inc hl                      ; -> stored count (+width)
    ld a,(ASV_KIND)
    ld b,a                      ; 2 bytes (numeric) / 3 (string)
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
    pop hl
    call ARR_NEXT
    jr .entry
.mismatch:
    pop hl
    ld a,65
    ld (VM_ERROR_CODE),a
    ld a,1
    ld (VM_HALTED),a
    ret

; ARR_ADOPT -- A = index, C = kind.  CF=1: the slot already points into the
; Array Store (adopted at RUN start); CF=0: allocate.  Preserves A, B, DE.
ARR_ADOPT:
    push af
    push de
    call ARR_SLOT
    ld e,(hl)
    inc hl
    ld d,(hl)
    ld a,d
    cp ARR2_BASE >> 8
    jr c,.no
    ld hl,(PAS_END)
    or a
    sbc hl,de
    jr c,.no
    jr z,.no
    pop de
    pop af
    scf
    ret
.no:
    pop de
    pop af
    or a
    ret

; ARR_ZERO_NUM / ARR_ZERO_STR -- zero-fill the array the allocator just built.
ARR_ZERO_NUM:
    ld a,(VM_HALTED)
    or a
    ret nz
    ld hl,0
    ld (VM_ARR_ELEM_TMP),hl
    call VM_ARR_ADDR
    ld bc,(VM_DIM_COUNT_TMP)
    sla c
    rl b
    jp KTAB_MEM_FILL_ZERO
ARR_ZERO_STR:
    ld a,(VM_HALTED)
    or a
    ret nz
    ld bc,(VM_STRARR_ADDR_TMP)
    push bc
    ld hl,0
    ld (VM_ARR_ELEM_TMP),hl
    call VM_STRARR_ADDR
    pop bc
    jp KTAB_MEM_FILL_ZERO

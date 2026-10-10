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


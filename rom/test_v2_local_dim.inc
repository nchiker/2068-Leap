; ============================================================================
; rom/test_v2_local_dim.inc -- TEST-ONLY DIM handlers for the standalone component
; tests (R10.9 Phase 2C).
;
; Production DIM / DIM$ (opcodes 63 / 64) are owned by the EXROM Array Store service
; (rom/exrom_v2_arrstore.asm: adopt-or-allocate plus D12 zero-fill) and reached through
; two fixed EXROM slots, V2_EXROM_ARR_DIM_ADDR / V2_EXROM_ARR_DIM_STR_ADDR. The
; standalone harnesses build a HOME image with a private EXROM that has no Array Store
; service, so they bind those two names to the local handlers below: the original
; R10.7 allocate-only handlers plus the D12 zero-fill. They do NOT adopt stored
; arrays and do NOT exercise the production DIM code. Anything about the Array Store,
; adoption, bind-time validation or the real DIM handlers is covered on the real
; production image by tools/v2_prod_regress.py / tools/v2_known_defects.py.
;
; Include this file once, after rom/exrom_v2_vm_core.asm.
; ============================================================================
V2_EXROM_ARR_DIM_ADDR     EQU OP_DIM
V2_EXROM_ARR_DIM_STR_ADDR EQU OP_DIM_STR

OP_DIM:
        ld hl,(VM_IP)
        ld a,(hl)
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (VM_IP),hl
        call ARENA_ALLOC_NUMERIC
        ld a,(VM_HALTED)
        or a
        jp nz,VM_RUN.loop
        ld hl,(VM_IP)
        ld de,-3
        add hl,de
        ld a,(hl)                 ; array index operand
        ld hl,(RT_ARRPTR_PTR)
        ld bc,(VM_DIM_COUNT_TMP)
        sla c
        rl b                      ; BC = count*2
        ld de,3                   ; descriptor header
        jr LOCAL_DIM_FILL

OP_DIM_STR:
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
        ld a,b
        call ARENA_ALLOC_STRING
        ld a,(VM_HALTED)
        or a
        jp nz,VM_RUN.loop
        ld hl,(VM_IP)
        ld de,-4
        add hl,de
        ld a,(hl)                 ; array index operand
        ld hl,(RT_STRARRPTR_PTR)
        ld bc,(VM_STRARR_ADDR_TMP) ; count*width, cached by the allocator
        ld de,4
LOCAL_DIM_FILL:                   ; A = index, HL = pointer table, DE = header, BC = data length
        push de
        ld e,a
        ld d,0
        add hl,de
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)                 ; DE = descriptor
        pop hl
        add hl,de                 ; HL = first data byte
        call MEM_FILL_ZERO        ; D12: DIM zero-fills
        jp VM_RUN.loop

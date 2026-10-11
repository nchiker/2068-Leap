; ============================================================================
; rom/v2_saveall.asm -- RC (owner decision 2): SAVE "name" ALL, and the LOAD of such a tape.
; HOME-resident; the shell (rom/exrom_v2_shell.asm) drives it. Format, checks and lifecycle:
; docs/v2/V2_SAVE_ALL_FORMAT.md.
;
; A SAVE ... ALL tape is ONE ordinary program block (header type 0) whose header PROGLEN (the
; Spectrum "program part" length) is shorter than its data length. After the program comes the
; variable session -- the memory a stopped program's session occupies, as an exact image:
;   PROG_END .. ARRAYS_END   symbol table, session gap and array arena (they load in place)
;   W bytes                  VARS_START .. SESS_CODE_END: the run-time tables, the compile zone and
;                            the session's bytecode -- MOVED down to ARRAYS_END for the SAVE (and
;                            back afterwards, SA_UNBUILD), so no copy of it needs free memory
;   S bytes                  segment 2 (ARR2_BASE .. ARR2_END: Array Store + overflow arrays)
;   SA_K_LEN bytes           the session cells $B800 .. SA_AE (counts, table bases, ends, ...)
;   2                        the identity CRC (SA_ROM_CRC: HOME + EXROM + the package registry): the
;                            image is only valid with exactly the ROM and packages that wrote it
;   2                        the CRC-16/CCITT of every byte before it (program included)
; The image must end at or below V2_CODE_LIMIT (it may run past the pool into the zone and the free
; code space). LOAD (SA_RESTORE) changes nothing until the block CRC and the identity CRC match; then
; installs the cells, requires the addresses in them to form one nondecreasing chain (SA_CHAIN)
; and the block to be partitioned exactly as they describe, requires every array pointer (read in
; the image) to lie in the arena or segment 2, and only then installs segment 2 and moves the
; tables/zone/bytecode span up into place.
; Any failure after the CRCs restores the Array Store's end and reports the state unusable: the
; caller keeps the program and discards the variables.
; ============================================================================
SA_TAIL         equ SA_K_LEN + 4            ; the cells + the two CRCs
SA_END          equ SESS_SAVE               ; scratch (SESS_SAVE only serves an immediate statement):
SA_W            equ SESS_SAVE + 2           ;   the block end; W; S; the Array Store's end before the
SA_S            equ SESS_SAVE + 4           ;   load
SA_OLD_PAS      equ SESS_SAVE + 6

; SA_SIZES -- from the live cells: SA_W, SA_S; HL = W + S. Destroys AF, BC, DE.
SA_SIZES:
        ld hl,(SESS_CODE_END)
        ld de,(RT_SYMTAB_PTR)
        or a
        sbc hl,de
        ld (SA_W),hl
        ex de,hl
        ld hl,(ARR2_END)
        ld bc,-ARR2_BASE
        add hl,bc
        ld (SA_S),hl
        add hl,de
        ret

; SA_SEAL -- the end of SA_BUILD (rom/exrom_v2_shell.asm): DE = the end of the laid-out image (after
; the cells). Appends the identity CRC and the block CRC. Out: BC = the block length from PROG_AREA_START,
; CF clear.
SA_SEAL:
        push de
        call SA_ROM_CRC
        pop hl
        call SA_PUT_DE
        ex de,hl
        ld hl,PROG_AREA_START
        push de
        call SA_CRC_RANGE
        pop hl
        call SA_PUT_DE
        ld bc,-PROG_AREA_START
        add hl,bc
        ld b,h
        ld c,l
        or a
        ret

; SA_UNBUILD -- the span [ARRAYS_END, +W) moves up to [SESS_CODE_END - W, SESS_CODE_END) (= its home
; VARS_START .. SESS_CODE_END). Used after a SAVE / VERIFY (from V2_SHOW_MESSAGE, which keeps HL),
; and by SA_RESTORE. Keeps HL.
SA_UNBUILD:
        push hl
        xor a
        ld (SA_BUILT),a
        ld hl,(ARRAYS_END)
        ld bc,(SA_W)
        add hl,bc
        dec hl
        ld de,(SESS_CODE_END)
        dec de
        ld a,b
        or c
        jr z,.done
        lddr
.done:
        pop hl
        ret

; The addresses a session's cells hold, in the order they must lie in memory (each <= the next).
SA_CHAIN:
        dw PROG_END, SYM_BASE_V, PROG_END ; the symbol table starts at the program's end
        dw SYM_END_V, SESS_ARENA_BASE, ARRAYS_END
        dw RT_SYMTAB_PTR, RT_FLOATTAB_PTR, RT_STRTAB_PTR, RT_ARRPTR_PTR, RT_STRARRPTR_PTR
        dw SA_K_SRC_END, SA_K_CODE_BASE, SESS_CODE_END, SA_K_CODE_LIM
        dw SA_K_ARR2_BASE, PAS_END, ARR2_END, SA_K_ARR2_LIM
SA_CHAIN_N equ ($ - SA_CHAIN) / 2
SA_K_SRC_END:   dw V2_SOURCE_END
SA_K_CODE_BASE: dw VM_CODE_BASE
SA_K_CODE_LIM:  dw V2_CODE_LIMIT
SA_K_ARR2_BASE: dw ARR2_BASE
SA_K_ARR2_LIM:  dw ARR2_LIMIT

; SA_RESTORE -- a program block was loaded whose header PROGLEN (HL) is below its length (DE);
; PROG_END is already PROG_AREA_START + PROGLEN.
; Out: A = 0  restored: the saved session is the current one;
;      A = 1  the state cannot be used (another ROM, or inconsistent): keep the program only;
;      A = 2  the block CRC failed: nothing in the block can be trusted.
SA_RESTORE:
        push hl                           ; PROGLEN
        ld hl,PROG_AREA_START
        add hl,de
        ld (SA_END),hl
        ex de,hl                          ; DE = the end, HL = the length
        pop bc
        or a
        sbc hl,bc
        ld bc,SA_TAIL
        sbc hl,bc
        ld a,1
        ret c                             ; too short to hold the tail
        ex de,hl
        dec hl
        ld d,(hl)
        dec hl
        ld e,(hl)                         ; the stored block CRC
        push de
        push hl                           ; (its address)
        ex de,hl
        ld hl,PROG_AREA_START
        call SA_CRC_RANGE
        pop bc
        pop hl
        or a
        sbc hl,de
        ld a,2
        ret nz
        push bc
        call SA_ROM_CRC
        pop hl
        dec hl
        ld a,(hl)
        dec hl
        ld l,(hl)
        ld h,a                            ; the stored identity CRC
        sbc hl,de                         ; (no carry: SA_CRC_GO returns through `or c`)
        ld a,1
        ret nz                            ; written by another ROM
        ld hl,(PAS_END)
        ld (SA_OLD_PAS),hl
        ld hl,(SA_END)
        ld de,-SA_TAIL
        add hl,de
        ld de,SYM_COUNTS
        ld bc,SA_K_LEN
        ldir                              ; the session cells
        ld hl,(SA_AE)
        ld (ARRAYS_END),hl
        ld hl,SA_CHAIN
        call .word                        ; DE = the first word
        ld b,SA_CHAIN_N - 1
.chain:
        push de                           ; the previous word
        call .word                        ; DE = the next one
        ex (sp),hl                        ; HL = the previous, (sp) = the entry pointer
        push de
        ex de,hl
        or a
        sbc hl,de                         ; next - previous
        pop de
        pop hl
        jr c,.bad
        djnz .chain
        call SA_SIZES                     ; the block must be cut exactly as the cells say
        ld de,SA_TAIL
        add hl,de
        ld de,(ARRAYS_END)
        add hl,de
        ld de,(SA_END)
        sbc hl,de                         ; (no carry out of the adds)
        jr nz,.bad
        ld hl,V2_SOURCE_END               ; every array pointer -- read in the image, at ARRAYS_END +
        ld de,(RT_ARRPTR_PTR)             ; (its address - VARS_START) -- must be 0, in the arena or in
        sbc hl,de                         ; segment 2
        srl h
        rr l
        ld b,h
        ld c,l                            ; BC = how many
        ex de,hl
        ld de,(RT_SYMTAB_PTR)
        sbc hl,de                         ; (no carry: rr l shifted out a 0)
        ld de,(ARRAYS_END)
        add hl,de                         ; HL -> the first one
.ptr:
        ld a,b
        or c
        jr z,.ptrs_ok
        dec bc
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,d
        or e
        jr z,.ptr
        push hl
        ex de,hl
        ld de,(SESS_ARENA_BASE)
        sbc hl,de
        jr c,.ptr_bad
        add hl,de
        ld de,(ARRAYS_END)
        sbc hl,de
        jr c,.ptr_ok                      ; in the arena
        add hl,de
        ld de,ARR2_BASE
        sbc hl,de
        jr c,.ptr_bad
        add hl,de
        ld de,(ARR2_END)
        sbc hl,de
        jr c,.ptr_ok                      ; in segment 2
.ptr_bad:
        pop hl
.bad:
        ld hl,(SA_OLD_PAS)
        ld (PAS_END),hl                   ; the Array Store is untouched: keep its end
        ld a,1
        ret
.ptr_ok:
        pop hl
        jr .ptr
.ptrs_ok:
        ld hl,(ARRAYS_END)
        ld bc,(SA_W)
        add hl,bc
        ld de,ARR2_BASE
        ld bc,(SA_S)
        call SA_COPY                      ; the Array Store and the overflow arrays
        call SA_UNBUILD                   ; tables, zone and bytecode up into place
        ld hl,(RT_SYMTAB_PTR)
        ld (VARS_START),hl
        ld (VM_CSP),hl
        call VM_INIT_REGS
        xor a
        ret
.word:                                    ; HL -> a chain entry: DE = the word it names, HL += 2
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ex de,hl
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        ex de,hl
        ret

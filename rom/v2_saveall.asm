; ============================================================================
; rom/v2_saveall.asm -- RC (owner decision 2): SAVE "name" ALL, and the LOAD of such a tape.
; HOME-resident; the shell (rom/exrom_v2_shell.asm) drives it. Format, checks and lifecycle:
; docs/V2_SAVE_ALL_FORMAT.md.
;
; A SAVE ... ALL tape is a program block (header type 0) whose header PROGLEN (the Spectrum "program
; part" length) is shorter than its data length, FOLLOWED (v2.2; the format minor stays 1) by a second data block:
; segment 2, sent straight from its own address after a silent gap long enough for LOAD's checks of the
; first block (SA_GAP). Block 1 holds the program and then the variable session -- the memory a stopped
; program's session occupies, as an exact image:
;   PROG_END .. ARRAYS_END   symbol table, session gap and array arena (they load in place)
;   W bytes                  VARS_START .. SESS_CODE_END: the run-time tables, the compile zone and
;                            the session's bytecode -- MOVED down to ARRAYS_END for the SAVE (and
;                            back afterwards, SA_UNBUILD), so no copy of it needs free memory
;   SA_K_LEN bytes           the session cells $B800 .. SA_AE (counts, table bases, ends, ...)
;   2                        the CRC-16/CCITT of segment 2 (block 2's bytes)
;   2                        the identity CRC (SA_ROM_CRC: HOME + EXROM + the package registry): the
;                            image is only valid with exactly the ROM and packages that wrote it
;   2                        the CRC-16/CCITT of every byte of block 1 before it (program included)
; Block 2 is segment 2 (ARR2_BASE .. ARR2_END: Array Store + overflow arrays), S bytes, no copy.
; Block 1 must end at or below V2_CODE_LIMIT (it may run past the pool into the zone and the free
; code space). LOAD (SA_RESTORE) changes nothing until block 1's CRC and the identity CRC match; then
; installs the cells, requires the addresses in them to form one nondecreasing chain (SA_CHAIN)
; and block 1 to be partitioned exactly as they describe, and requires every array pointer (read in
; the image) to lie in the arena or segment 2. The shell then receives block 2 into segment 2
; (V2_RECV_S) and SA_FINISH checks its CRC and moves the tables/zone/bytecode span up into place.
; A failure before block 2 restores the Array Store's end and reports the state unusable (the caller
; keeps the program and discards the variables); a failure of block 2 or its CRC also empties the
; Array Store (segment 2 was written), with the same report.
; ============================================================================
SA_TAIL         equ SA_K_LEN + 6            ; the cells + the three CRCs (segment 2, identity, block 1)
SA_GAP_N        equ 4650                    ; SA_GAP: 4650 passes of 3,389 T = about 4.5 s at 3.5 MHz
SA_END          equ SESS_SAVE               ; scratch (SESS_SAVE only serves an immediate statement):
SA_W            equ SESS_SAVE + 2           ;   the block end; W; S; the Array Store's end before the
SA_S            equ SESS_SAVE + 4           ;   load
SA_OLD_PAS      equ SESS_SAVE + 6

; SA_SIZES -- from the live cells: SA_W, SA_S; HL = W (block 1 holds W; segment 2, S bytes, is block 2).
; Destroys AF, DE.
SA_SIZES:
        ld hl,(ARR2_END)
        ld a,h
        sub ARR2_BASE >> 8                ; (ARR2_BASE's low byte is 0: ASSERT below; ARR2_END >= ARR2_BASE,
        ld h,a                            ; so no borrow: CF clear for the sbc)
        ld (SA_S),hl
        ld hl,(SESS_CODE_END)
        ld de,(RT_SYMTAB_PTR)
        sbc hl,de
        ld (SA_W),hl
        ret
    ASSERT (ARR2_BASE & $FF) = 0

; SA_SEAL -- the end of SA_BUILD (rom/exrom_v2_shell.asm): DE = the end of the laid-out image (after
; the cells). Appends the segment-2 CRC, the identity CRC and the block CRC. Out: DE = block 1's length
; from PROG_AREA_START, CF clear.
SA_SEAL:
        push de
        call SA_CRC_S                     ; DE = the CRC of block 2
        pop hl
        call SA_PUT_DE
        push hl
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
        ex de,hl
        or a
        ret

; SA_GAP -- the silence between the two blocks of a SAVE ... ALL tape, long enough for LOAD's checks of
; block 1 (the block CRC and the identity CRC, about 3-4 s) to finish before the receiver listens for
; block 2's pilot (it then has its own 8.6 s of patience). Interrupts stay off. SPACE pressed: returns NC.
; Otherwise it falls into SA_S_SETUP: CF set, and IX, DE, A are block 2's.
SA_GAP:
        ld hl,SA_GAP_N
.big:
        ld b,0
.in:
        djnz .in                          ; 3,323 T
        ld a,$7F
        in a,(PORT_ULA)
        rra
        ret nc                            ; SPACE down
        dec hl
        ld a,h
        or l
        jr nz,.big                        ; (falls through with CF clear)
; SA_S_SETUP -- the registers for block 2 (segment 2, in place), for the shell's send, receive and verify:
; IX = ARR2_BASE, DE = SA_S bytes, A = the data block's flag. Complements the carry.
SA_S_SETUP:
        ccf
        ld ix,ARR2_BASE
        ld de,(SA_S)
        ld a,SA_FLAG_DATA
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

; SA_RESTORE -- a program block was loaded whose header PROGLEN (HL) is below its length (DE); BC =
; PROG_AREA_START. Sets PROG_END = PROG_AREA_START + PROGLEN.
; Out: flags NZ for every A but 0:
;      A = 0  block 1 is good (the cells are installed, the span is still down at ARRAYS_END; Z, NC): the caller
;              receives block 2 and calls SA_FINISH;
;      A = 1  the state cannot be used (another ROM, or inconsistent): keep the program only;
;      A = 2  the block CRC failed: nothing in the block can be trusted.
SA_RESTORE:
        push hl                           ; PROGLEN
        add hl,bc
        ld (PROG_END),hl                  ; the program part ends here
        ld h,b
        ld l,c                            ; (BC = PROG_AREA_START on entry)
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
        ld hl,(SA_OLD_PAS)                ; the Array Store is untouched: keep its end
.set_pas:                                 ; (also SA_FINISH.empty: HL = ARR2_BASE)
        ld (PAS_END),hl
        xor a
        inc a                             ; A = 1, and NZ: every return but "block 1 is good" is NZ
        ret
.ptr_ok:
        pop hl
        jr .ptr
.ptrs_ok:
        xor a                             ; block 1 is good; segment 2 (SA_S bytes) is block 2: the shell
        ret                               ; receives it (V2_RECV_S) and calls SA_FINISH
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

; SA_FINISH -- after SA_RESTORE returned 0 and the shell received block 2 straight into segment 2.
; In: CF = block 2 was not received whole (no tape, SPACE, a dropout, the transport checksum).
; Out: A = 0 restored (the span moved up, the session is the current one); A = 1 the state is unusable:
; segment 2 was written (or partly), so the Array Store is emptied; the caller keeps the program only.
SA_FINISH:
        jr c,.empty
        call SA_CRC_S                     ; DE = the CRC of what arrived
        ld hl,(SA_END)
        ld bc,-6                          ; [segment-2 CRC][identity CRC][block CRC] end the block
        add hl,bc
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
        or a
        sbc hl,de
        jr nz,.empty
        call SA_UNBUILD                   ; tables, zone and bytecode up into place
        ld hl,(RT_SYMTAB_PTR)
        ld (VARS_START),hl
        ld (VM_CSP),hl
        jp VM_INIT_REGS                   ; returns A = 0 (it ends with xor a and stores only)
.empty:
        ld hl,ARR2_BASE
        jr SA_RESTORE.set_pas             ; the Array Store emptied; A = 1

; SA_IS_ALL -- CF = the header just read (STORAGE_HEADER_BUF) is a SAVE ... ALL tape: PROGLEN below its length.
SA_IS_ALL:
        ld hl,(STORAGE_HEADER_BUF + SA_HDR_PROGLEN_OFF)
        ld de,(STORAGE_HEADER_BUF + SA_HDR_LEN_OFF)
        or a
        sbc hl,de
        ret

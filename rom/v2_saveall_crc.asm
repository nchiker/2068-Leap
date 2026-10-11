; rom/v2_saveall_crc.asm -- RC: the CRC routines of SAVE ... ALL (rom/v2_saveall.asm), placed in the
; HOME low-ROM space the production build no longer spends on the KTAB jump table.
; SA_CRC -- DE = CRC-16/CCITT (poly $1021, init $FFFF) of BC bytes at HL; SA_CRC_GO continues a CRC
; in DE; SA_CRC_RANGE: of [HL, DE). Destroys AF, BC, HL.
SA_CRC_RANGE:
        ex de,hl
        or a
        sbc hl,de
        ld b,h
        ld c,l
        ex de,hl
SA_CRC:
        ld de,$FFFF
SA_CRC_GO:
        ld a,b
        or c
        ret z
        ld a,(hl)
        xor d
        ld d,a
        push bc
        ld b,8
.bit:
        sla e
        rl d
        jr nc,.next
        ld a,d
        xor $10
        ld d,a
        ld a,e
        xor $21
        ld e,a
.next:
        djnz .bit
        pop bc
        inc hl
        dec bc
        jr SA_CRC_GO

; SA_ROM_CRC -- DE = the identity CRC a SAVE ... ALL image is valid for: HOME ($0000-$3FFF), EXROM
; ($C000-$DFFF, paged in by the shell) and the package registry (EXT2_TABLE: each slot's generation,
; name and entry). The saved bytecode names package statements by slot and generation, and the
; generation counter restarts at every boot, so another package could otherwise answer to them.
SA_ROM_CRC:
        ld hl,0
        ld bc,$4000
        call SA_CRC                       ; returns HL = $4000, BC = 0
        ld h,$C0
        ld b,$20
        call SA_CRC_GO
        ld hl,EXT2_TABLE
        ld bc,EXT2_MAX*EXT2_REC_LEN
        jr SA_CRC_GO
; (the two small helpers of rom/v2_saveall.asm, here for space)
SA_COPY:                                  ; BC bytes HL -> DE (BC may be 0)
        ld a,b
        or c
        ret z
        ldir
        ret
SA_PUT_DE:                                ; (HL) = DE, HL += 2
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ret


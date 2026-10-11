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

; SA_ROM_CRC -- DE = the CRC of HOME ($0000-$3FFF) then EXROM ($C000-$DFFF, paged in by the shell).
SA_ROM_CRC:
        ld hl,0
        ld bc,$4000
        call SA_CRC                       ; returns HL = $4000, BC = 0
        ld h,$C0
        ld b,$20
        jr SA_CRC_GO


; ============================================================================
; rom/printer_raster.asm — real ZX Printer raw hardware bit-bang layer
; (PORT_PRINTER protocol), extracted from rom/exrom_printer.asm's own
; real, hardware-validated implementation (see that file's own header
; for the full derivation/verification history against a real Timex
; Sinclair 2068 ROM disassembly and a real Fuse .pbm raster check --
; unchanged here, this is a direct port, not a reimplementation).
;
; Kept in its own file, separate from rom/ext_printer_module.asm's own
; higher-level BASIC-level LPRINT/LLIST logic, for two reasons: (1) real
; layering (raw electrical protocol vs. BASIC statement semantics);
; (2) testability -- PRINT_RASTER_ROW's own `.wait_paper` poll spins
; forever with no printer attached (confirmed real behavior, matching
; real Sinclair BASIC), so no automated ZEsarUX fixture can run it to
; completion. rom/test_v2_printer_module.asm includes its own stub
; instead of this file; the real production build includes this file.
; ============================================================================

PRINTER_MOTOR_STOP:
        ld a,%00000100
        out (PORT_PRINTER),a
        ret

; PRINT_RASTER_ROW ( HL = 32-byte row buffer, A = 1 for slow speed else
; 0 ). Bit-bangs one 256-dot raster row, MSB-first within each byte.
; Destroys: AF, BC, DE, HL
PRINT_RASTER_ROW:
        add a,a
        ld c,a
        out (PORT_PRINTER),a
.wait_paper:
        in a,(PORT_PRINTER)
        bit 6,a
        ret nz
        bit 7,a
        jr z,.wait_paper
        ld b,32
.byteloop:
        ld e,(hl)
        inc hl
        ld d,8
.bitloop:
        rlc e
        ld a,0
        jr nc,.stylus_off
        ld a,%10000000
.stylus_off:
        or c
        push af
.waitready:
        in a,(PORT_PRINTER)
        and 1
        jr z,.waitready
        pop af
        out (PORT_PRINTER),a
        dec d
        jr nz,.bitloop
        djnz .byteloop
        ret

; ============================================================================
; hardware.inc — symbolic constants for TS2068 hardware
; Every module includes this instead of hard-coding ports/addresses.
; ============================================================================

    IFNDEF HARDWARE_INC
    DEFINE HARDWARE_INC

; ---- ULA / display ----
PORT_ULA            EQU $FE     ; border/EAR/MIC, keyboard read (Spectrum-compatible)

PORT_ULAPLUS_SELECT EQU $BF3B   ; ULAplus register select (16-bit port)
PORT_ULAPLUS_DATA   EQU $FF3B   ; ULAplus register data (16-bit port)
ULAPLUS_MODE_GROUP EQU 64       ; bit 0 enables the standard palette

; ---- AY-3-8912 sound (TS2068 port pair) ----
; Confirmed 2026-08-22 from the real ROM disassembly's own SOUND command
; routine (M2127): register number OUT to $F5, data byte OUT to $F6 —
; exactly this placeholder's original guess, now load-bearing (rom/
; exrom_sound.asm's SOUND_EXROM).
PORT_AY_REG         EQU $F5     ; select AY register
PORT_AY_DATA        EQU $F6     ; write/read AY register data

; ---- TS2068 banking (Home / Exrom / Dock) ----
; Confirmed against the real port $F4/$FF description AND the real
; Timex Sinclair 2068 ROM Disassembly (David Anderson, 2023) — see
; docs/memory_map.md's EXROM section for the full sourced writeup.
; Horizontal Select Register: one bit per 8K chunk of the 64K address
; space (chunk N = $0000 + N*$2000, N=0-7; A13-A15 decode). 0 = that
; chunk comes from Home, 1 = from whichever alternate bank PORT_SCLD's
; own bit 7 currently selects (EXROM or Dock — see below). This
; project only ever pages chunk 6 ($C000-$DFFF) — see
; kernel/bank/bank.asm's BANK_PAGE_EXROM_IN/OUT, the only writers.
PORT_BANK_HOME      EQU $F4

; ---- SCLD Display Enhancement Control (Port $FF) ----
; Confirmed against the real TS2068 Technical Reference Manual (not
; guessed): a SHARED, multi-function register — bits 0-2 select the
; video mode, bit 6 is INTEN, bit 7 selects Extension ROM vs.
; cartridge banking (meaningful only for whichever chunk PORT_
; BANK_HOME currently marks as "not Home" — see that EQU above).
; GFX_SET_MODE and kernel/bank's BANK_PAGE_EXROM_IN are the only
; writers, and always go through PORT_FF_SHADOW (sysvars.inc) first —
; never OUT directly — so bits a given caller doesn't currently care
; about can never be silently zeroed by an unrelated change (video
; mode vs. EXROM select, sharing this same port, don't step on each
; other). Real confirmed byte values (see kernel/graphics's GFX_SET_
; MODE for the full mapping): 0 = Normal, 2 = High Resolution
; Graphics. (Bits 3-5, which the manual also documents as selecting a
; 64-Column-mode ink/paper pair, are unused now that mode was removed
; 2026-08-20.)
PORT_SCLD           EQU $FF

; ---- Screen geometry ----
SCREEN_ADDR         EQU $4000
ATTR_ADDR           EQU $5800
SECOND_DISPLAY_ADDR EQU $6000     ; The Second Display File, confirmed
                                 ; against the manual before any Z80
                                 ; touched it: in High Resolution
                                 ; Graphics mode (GFX_SET_ATTR_EXT)
                                 ; this is 6144 flat ATTRIBUTE bytes,
                                 ; 8x1 resolution (one byte per
                                 ; scanline row per character column,
                                 ; not per 8x8 cell). (64-Column mode,
                                 ; which used this same region as a
                                 ; second BITMAP, was removed
                                 ; 2026-08-20.)
SCREEN_WIDTH_CHARS  EQU 32
SCREEN_HEIGHT_CHARS EQU 24

    ENDIF

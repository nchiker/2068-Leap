; ============================================================================
; rom/v2_package_cbeep.asm -- MAINT (ClassicBEEP study): the original loudspeaker BEEP as a
; loadable package.  The main ROM's BEEP plays on the AY chip; this package brings back the
; TS2068's own speaker (port $FE bit 4), through the very routine V2 used to have in HOME:
; kernel/sound/sound.asm's SOUND_BEEP is assembled into the package unchanged (one cycle =
; 222 + 52 x pitch T-states, interrupts off while it sounds).
;
; Statement (package names are at most 8 characters: CLASSICBEEP cannot be registered):
;
;   CBEEP ms, semitones, border      default build (package ABI 2.0, as released)
;   CBEEP ms, semitones              -DCB_PIN_FE: needs PORT_FE_SHADOW pinned (ABI 2.1, see the study)
;   CBEEP cycles, pitch, border      -DCB_RAW: the old V2 raw BEEP (design A)
;
; ms: 0..32767 milliseconds (package arguments are 16-bit integers: no fractions of a second
; reach a package, so the duration is in thousandths); semitones -60..69 above middle C, as
; Sinclair BEEP.  Out of range, or more than 65535 cycles (4.6 s at +69): error 15.
; border: the border colour to keep while the speaker bit is toggled -- every write to port $FE
; also sets the border, and package ABI 2.0 does not let a package read the border V2 holds
; (PORT_FE_SHADOW is not a pinned cell).
;
; Pitch and length are computed in integers (no calculator: EXROM is paged out while a package
; runs): pitch = ((Q[n] >> octave) - 15) >> 2, cycles = ms x F[n] >> (22 - octave), tables for the
; lowest octave (-60..-49), calibrated for the real TS2068 clock (3.528 MHz).  Bit-exact model and
; accuracy: tools/maint/cbeep_model.py.
; ============================================================================
    INCLUDE "include/hardware.inc"
    INCLUDE "include/v2_package_abi.inc"   ; the ONLY HOME interface a package may use
    PKG_SVC_LIST
    PKG_CONST_LIST
    PKG_PIN_LIST
    DEVICE NOSLOT64K
    ORG EXTENSION_MODULE_BASE
    jp   CB_INSTALL
    INCLUDE "rom/ext_cbeep_module.asm"

V2_PACKAGE_CBEEP_END:
    ASSERT $ <= EXTENSION_MODULE_LIMIT
    IFDEF CB_RAW
    SAVEBIN "build/v2_package_cbeep_raw.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_CBEEP_END-EXTENSION_MODULE_BASE
    ELSE
    IFDEF CB_PIN_FE
    SAVEBIN "build/v2_package_cbeep_pin.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_CBEEP_END-EXTENSION_MODULE_BASE
    ELSE
    SAVEBIN "build/v2_package_cbeep.bin", EXTENSION_MODULE_BASE, V2_PACKAGE_CBEEP_END-EXTENSION_MODULE_BASE
    ENDIF
    ENDIF

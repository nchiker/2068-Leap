; ============================================================================
; rom/exrom_build.asm — the real EXROM image driver (produces exrom.bin)
;
; NEW (2026-08-19), when SAVE/LOAD's own migration (rom/exrom_storage.
; asm) needed to share the same 8K image as the checker (rom/exrom_
; checker.asm) — there's only one real rom1.bin, not a swappable
; second EXROM bank, so both subsystems have to be ONE compilation
; unit from here on. This file holds everything that used to open and
; close rom/exrom_checker.asm on its own: the shared includes, the
; jump-table generation, DEVICE/ORG, and the final SAVEBIN. The two
; content files contribute ONLY code/data now, no build machinery of
; their own — see each file's own header for what it contributes and
; why it's ordered where it is.
;
; ORDER MATTERS: rom/exrom_checker.asm must come first — it's the one
; that declares ALL SEVEN fixed entry stubs ($C000/$C006/$C00C for
; itself, $C012/$C018 for storage, $C01E for help, $C024 for the
; calculator) at the very top of the image, in address order, before
; any of the four files' real routine bodies start advancing `$` past
; those addresses. rom/exrom_storage.asm, rom/exrom_help.asm, and
; rom/exrom_calc.asm each just supply the labels their own stub jumps
; to (STORAGE_SAVE/STORAGE_LOAD, BASIC_SHOW_HELP, and CALC_EXROM_ENTRY
; respectively — forward references, fine, sjasmplus is multi-pass)
; and otherwise flow in naturally after whatever content precedes them.
;
; Build:
;   sjasmplus rom/exrom_build.asm    (produces exrom.bin — the real
;                                     rom1.bin; the old exrom_checker.
;                                     bin name is retired)
; Run:
;   fuse --machine ts2068 --rom-ts2068-0 test_basic.bin --rom-ts2068-1 exrom.bin
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"
    INCLUDE "include/keys.inc"           ; KEY_ENTER/KEY_CURSOR_*/KEY_
                                         ; DELETE* — needed by rom/
                                         ; exrom_editor.asm's own
                                         ; EDITOR_LOOP; no other content
                                         ; file here needed it before
    INCLUDE "include/exrom_jumptable.inc"
    KTAB_LIST                            ; on THIS side (no EXROM_
                                         ; JUMPTABLE_HOME_SIDE define),
                                         ; generates the KTAB_* EQUs
                                         ; both content files use —
                                         ; emits no code, safe before
                                         ; ORG

    DEVICE NOSLOT64K
    ORG $C000

    INCLUDE "rom/exrom_checker.asm"      ; all six entry stubs +
                                         ; EXROM_VERIFY_KTAB_MAGIC +
                                         ; the checker's own routine
                                         ; bodies + its KW_*/MSG_* data
    INCLUDE "rom/exrom_storage.asm"      ; STORAGE_SAVE/STORAGE_LOAD
    IFDEF STORAGE_TEST_FAKE_RECEIVE
        INCLUDE "rom/exrom_storage_test.asm"
    ENDIF
    INCLUDE "rom/exrom_format.asm"       ; shared formatting utilities
                                         ; and everything they call —
                                         ; the two entry stubs above
                                         ; already point here
    INCLUDE "rom/exrom_help.asm"         ; BASIC_SHOW_HELP and its
                                         ; topic tables/text — the
                                         ; $C01E entry stub above
                                         ; already points here
    INCLUDE "rom/exrom_calc.asm"         ; CALC_EXROM_ENTRY, the
                                         ; CALCULATE dispatcher, and
                                         ; CALC_TABLE — the $C024 entry
                                         ; stub above already points
                                         ; here
    INCLUDE "rom/exrom_sound.asm"        ; SOUND_EXROM — the $C048
                                         ; entry stub above already
                                         ; points here
    INCLUDE "rom/exrom_ulaplus.asm"      ; ULAPLUS/PALETTE — the shared
                                         ; $C0AE entry stub points here
    INCLUDE "rom/exrom_sprite.asm"        ; BASIC_STMT_SPRITE and
                                         ; everything it depends on —
                                         ; the $C054 entry stub above
                                         ; already points here
    INCLUDE "rom/exrom_strfuncs.asm"      ; STRFUNC_EXROM and the eight
                                         ; string function bodies —
                                         ; the $C05A entry stub above
                                         ; already points here
    INCLUDE "rom/exrom_editor.asm"        ; the full-screen editor,
                                         ; whole — the $C060-$C089
                                         ; entry stubs above already
                                         ; point here
    INCLUDE "rom/exrom_arrays.asm"        ; DIMN — the $C08A entry
                                         ; stub above already points
                                         ; here
    INCLUDE "rom/exrom_input.asm"         ; numeric/string INPUT — the
                                         ; $C0B4 entry stub points here
    INCLUDE "rom/exrom_dim.asm"           ; DIM allocator — the $C0BA
                                         ; entry stub points here
    INCLUDE "rom/exrom_highlight.asm"     ; multi-keyword bold-
                                         ; highlighting scan — the
                                         ; $C090 entry stub above
                                         ; already points here

    IFDEF STORAGE_TEST_FAKE_RECEIVE
        DS   $E000 - $, $FF
        SAVEBIN "exrom_storage_test.bin", $C000, $2000
    ELSE
        IFDEF EDITOR_TEST_EXROM
            INCLUDE "rom/exrom_editor_test_payload.asm"
            DS   $E000 - $, $FF
            SAVEBIN "exrom_editor_test.bin", $C000, $2000
        ELSE
            DS   $E000 - $, $FF          ; pad to a full 8K image
            SAVEBIN "exrom.bin", $C000, $2000
        ENDIF
    ENDIF

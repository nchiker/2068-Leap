; ============================================================================
; V2 PACKAGE ABI 2.0 -- the single source of truth.        (R10.9 Phase 1)
;
; Human-readable contract: docs/v2/PACKAGE_ABI.md.  This file is parsed by
; tools/v2_abi.py / tools/check_package_abi.py (make check) and consumed three
; ways, selected by which of these is defined when the lists are expanded:
;
;   PKG_ABI_HOME defined  (rom/v2_home.asm, the HOME image):
;       PKG_SVC_LIST   emits the service jump table (one `jp home_routine` per slot);
;       PKG_PIN_LIST / PKG_CONST_LIST   ASSERT that the real sysvar / constant
;                      still lives at the pinned address, so an edit that moves one
;                      FAILS THE BUILD instead of silently breaking saved packages.
;   PKG_ABI_HOME not defined  (rom/v2_package_*.asm, the package images):
;       PKG_SVC_LIST   defines each service name as the address of its table slot;
;       PKG_PIN_LIST / PKG_CONST_LIST   define each name as the pinned address.
;
; Packages therefore no longer include sysvars.inc or build/v2_crossbank.inc: a
; package can only name what is listed here (an unlisted HOME internal is an
; assembler "label not found" error), and a listed name resolves to a number that
; cannot move with the HOME build.
;
; RULES for editing this file (also in the doc):
;   * Never reorder, remove or repurpose a service slot or a pinned address.
;   * Appending a slot / pin is a MINOR change (PKG_ABI_MINOR += 1).
;   * Anything else is a MAJOR change (PKG_ABI_MAJOR += 1): every old package tape
;     is then rejected cleanly by STORAGE_LOAD, which is the point.
; ============================================================================
    IFNDEF V2_PACKAGE_ABI_INC
    DEFINE V2_PACKAGE_ABI_INC

; ---- versions (tape header "autostart" word; see docs/v2/PACKAGE_ABI.md s6) ----
; word = $8000 | (major << 8) | minor.  Bit 15 set keeps the field a legal "no
; autostart" value for stock BASIC tooling; major 0 / bit 15 clear = unversioned.
V2_TAPE_TAG             EQU $8000
PKG_ABI_MAJOR           EQU 2          ; "1" was the unversioned raw-address ABI (R7.5-R10.8)
PKG_ABI_MINOR           EQU 0
PKG_ABI_WORD            EQU V2_TAPE_TAG | (PKG_ABI_MAJOR << 8) | PKG_ABI_MINOR
V2_FORMAT_MAJOR         EQU 1          ; program (type 0) and array (type 8) tapes
V2_FORMAT_MINOR         EQU 1          ; RC: 1 = a program tape may carry its variables (SAVE ... ALL)
V2_FORMAT_WORD          EQU V2_TAPE_TAG | (V2_FORMAT_MAJOR << 8) | V2_FORMAT_MINOR

; ---- service jump table (HOME ROM padding after the KTAB) -------------------------
; $0092 magic, $0093 major, $0094 minor, $0095 slot count, $0096.. 3-byte `jp` slots.
PKG_SVC_HEADER          EQU $0092
PKG_SVC_MAGIC           EQU $5A
PKG_SVC_ENTRIES         EQU $0096
PKG_SVC_MAX_END         EQU $00F0      ; slots stay below this; $00F0-$00FF holds slot code
PKG_SVC_CODE            EQU $00F0
PKG_SVC_COUNT           EQU 16

; PKG_SVC <name the package uses>, <HOME routine the slot jumps to>
; Slot numbers are the order below.  APPEND ONLY.
PKG_SVC_INDEX           DEFL 0
    MACRO PKG_SVC pkgname, homename
    IFDEF PKG_ABI_HOME
        jp homename
    ELSE
pkgname EQU PKG_SVC_ENTRIES + 3*PKG_SVC_INDEX
    ENDIF
PKG_SVC_INDEX           DEFL PKG_SVC_INDEX + 1
    ENDM

    MACRO PKG_SVC_LIST
PKG_SVC_INDEX           DEFL 0
    PKG_SVC EXT2_REGISTER, EXT2_REGISTER                    ; 0
    PKG_SVC GFX_SET_MODE, GFX_SET_MODE                      ; 1
    PKG_SVC GFX_CHAR_TO_FONT_OFFSET, GFX_CHAR_TO_FONT_OFFSET ; 2
    PKG_SVC GFX_SPRITE_CAPTURE, GFX_SPRITE_CAPTURE          ; 3
    PKG_SVC GFX_SPRITE_DRAW, GFX_SPRITE_DRAW                ; 4
    PKG_SVC GFX_PLOT_CLIPPED, GFX_PLOT_CLIPPED              ; 5
    PKG_SVC GFX_READ_PIXEL, GFX_READ_PIXEL                  ; 6
    PKG_SVC GFX_WRITE_PIXEL, GFX_WRITE_PIXEL                ; 7
    PKG_SVC MEM_LINE_FIRST, MEM_LINE_FIRST                  ; 8
    PKG_SVC MEM_LINE_NEXT, MEM_LINE_NEXT                    ; 9
    PKG_SVC MATH_MULTIPLY16, MATH_MULTIPLY16                ; 10
    PKG_SVC MATH_NEGATE16, MATH_NEGATE16                    ; 11
    PKG_SVC VM_CLAMP_Y191, VM_CLAMP_Y191                    ; 12
    PKG_SVC VM_COMPUTE_PRINT_ATTR, VM_COMPUTE_PRINT_ATTR    ; 13
    PKG_SVC VM_NUM_TO_TEXT, PKG_NUM_TO_TEXT_SAFE            ; 14 (EXROM-safe wrapper, below)
    PKG_SVC VM_STR_ADDR, VM_STR_ADDR                        ; 15
    ENDM

; ---- reserved package scratch (not a HOME symbol: the SPRITE package addresses it with
; literals, see rom/ext_sprite_module.asm).  Call-scoped: valid only while a package
; statement runs; HOME/EXROM must never allocate anything in [BASE, END). ----------------
PKG_SCRATCH_BASE        EQU $BFB0
PKG_SCRATCH_END         EQU $BFBB

; ---- pinned constants ------------------------------------------------------------
    MACRO PKG_CONST name, value
    IFDEF PKG_ABI_HOME
    ASSERT name == value, "package ABI constant moved (see include/v2_package_abi.inc)"
    ELSE
name EQU value
    ENDIF
    ENDM

    MACRO PKG_CONST_LIST
    PKG_CONST EXTENSION_MODULE_BASE, $F400     ; package window (1 KB)
    PKG_CONST EXTENSION_MODULE_LIMIT, $F800
    PKG_CONST TAG_INT, 0
    PKG_CONST SPRITE_SLOT_MAX, 8
    PKG_CONST SPRITE_CELL_MAX, 4
    PKG_CONST SPRITE_SLOT_BYTES, 144
    PKG_CONST SPRITE_SLOT_IMG_BUF, $E800       ; sprite image store (chunk 7, never paged)
    PKG_CONST SPRITE_SLOT_BG_BUF, $EC80
    PKG_CONST GFX_FILL_VISITED, $C000          ; hidden chunk-6 RAM, valid only inside a package call
    PKG_CONST GFX_FILL_STACK, $D800
    PKG_CONST GFX_FILL_STACK_END, $DC00
    ENDM

; ---- pinned RAM cells ---------------------------------------------------------------
; PKG_PIN <symbol>, <address>, <size in bytes>
    MACRO PKG_PIN name, addr, size
    IFDEF PKG_ABI_HOME
    ASSERT name == addr, "package ABI RAM cell moved (see include/v2_package_abi.inc)"
    ELSE
name EQU addr
    ENDIF
    ENDM

    MACRO PKG_PIN_LIST
    ; -- call arguments: written by OP_CALL_EXT before the package statement runs --
    PKG_PIN EXT_CALL_ARG0, $BED8, 2                ; 2 B each, 16-bit values, little-endian
    PKG_PIN EXT_CALL_ARG1, $BEDA, 2
    PKG_PIN EXT_CALL_ARG2, $BEDC, 2
    PKG_PIN EXT_CALL_ARG3, $BEDE, 2
    PKG_PIN EXT_CALL_ARG4, $BEEC, 2                ; non-contiguous 5th argument
    ; -- error reporting: written by the package, read by VM_RUN's loop --
    PKG_PIN VM_ERROR_CODE, $B683, 1                ; 1 B
    PKG_PIN VM_HALTED, $B684, 1                    ; 1 B
    ; -- HOME state the package may read --
    PKG_PIN CURRENT_OVER, $8106, 1                 ; 1 B
    ; -- package-owned scratch that lives in HOME's sysvar block.  HOME never writes it,
    ;    EXCEPT the sprite state: MEM_INIT zeroes SPRITE_SLOT_DEFINED/SHOWN and
    ;    SPRITE_DISPLAY_DEPTH, and GFX_SPRITE_INVALIDATE (called by GFX_CLS, scrolling and
    ;    GFX_SET_MODE) zeroes SPRITE_SLOT_SHOWN and SPRITE_DISPLAY_DEPTH --
    PKG_PIN GFX_CIRCLE_XC, $8140, 1                ; SHAPES: 9 B  ($8140-$8148)
    PKG_PIN GFX_CIRCLE_YC, $8141, 1
    PKG_PIN GFX_CIRCLE_R, $8142, 1
    PKG_PIN GFX_CIRCLE_ATTR, $8143, 1
    PKG_PIN GFX_CIRCLE_OVER, $8144, 1
    PKG_PIN GFX_CIRCLE_X, $8145, 1
    PKG_PIN GFX_CIRCLE_Y, $8146, 1
    PKG_PIN GFX_CIRCLE_D, $8147, 2                 ; 2 B
    PKG_PIN GFX_FILL_SP, $814C, 2                  ; SHAPES: 6 B  ($814C-$8151)
    PKG_PIN GFX_FILL_TARGET, $814E, 1
    PKG_PIN GFX_FILL_ATTR, $814F, 1
    PKG_PIN GFX_FILL_X, $8150, 1
    PKG_PIN GFX_FILL_Y, $8151, 1
    PKG_PIN SPRITE_SLOT_DEFINED, $8185, 8          ; SPRITE: 6 tables x 8 B  ($8185-$81B4)
    PKG_PIN SPRITE_SLOT_SHOWN, $818D, 8
    PKG_PIN SPRITE_SLOT_W, $8195, 8
    PKG_PIN SPRITE_SLOT_H, $819D, 8
    PKG_PIN SPRITE_SLOT_ROW, $81A5, 8
    PKG_PIN SPRITE_SLOT_COL, $81AD, 8
    PKG_PIN SPRITE_DISPLAY_DEPTH, $81B5, 1         ; HOME also zeroes SHOWN/DEPTH on GFX_CLS, MODE, NEW
    PKG_PIN PRINT_ROW_BUF, $8232, 32                ; PRINTER: 32 B + 1 + 2 + 1 + 2 + 2  ($8232-$8259)
    PKG_PIN PRINT_ROW_IDX, $8252, 1
    PKG_PIN PRINT_CHUNK_ADDR, $8253, 2
    PKG_PIN PRINT_CHUNK_LEN, $8255, 1
    PKG_PIN PRINT_REMAINING, $8256, 2
    PKG_PIN PRINT_CUR_ADDR, $8258, 2
    ENDM

    ENDIF

; ============================================================================
; kernel/editor/editor.asm — Home-ROM compatibility adapter
;
; The production editor has one source of truth: rom/exrom_editor.asm.
; Production reaches external Home routines through KTAB_* jump-table
; entries because the editor executes from EXROM. Standalone Home-ROM test
; harnesses historically included this path and call those same routines
; directly. Map the eight external names here, then assemble the exact same
; editor body in either environment.
;
; Do not copy editor routines into this file. All behavior changes belong in
; rom/exrom_editor.asm so production and standalone tests cannot drift apart.
; ============================================================================

KTAB_GFX_CLS               EQU GFX_CLS
KTAB_GFX_INVERT_ATTR       EQU GFX_INVERT_ATTR
KTAB_GFX_PRINT_STRING      EQU GFX_PRINT_STRING
KTAB_IO_READ_KEY           EQU IO_READ_KEY
KTAB_MEM_FILL_ZERO         EQU MEM_FILL_ZERO
KTAB_MEM_LINE_DELETE_RANGE EQU MEM_LINE_DELETE_RANGE
KTAB_MEM_SHIFT_DOWN        EQU MEM_SHIFT_DOWN
KTAB_MEM_SHIFT_UP          EQU MEM_SHIFT_UP

    INCLUDE "rom/exrom_editor.asm"

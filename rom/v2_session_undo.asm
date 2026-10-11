; V2_SESSION_UNDO -- RC: back to the symbol table and run-time tables saved in SESS_SAVE (an immediate
; statement that failed to compile, or whose new slots did not fit). Flags are preserved.
V2_SESSION_UNDO:                        ; (in the old KTAB space of the production HOME image)
        ld hl,SESS_SAVE
        ld de,SYM_COUNTS
        ld bc,23
        ldir
        ld hl,(SYM_END_V)
        ld (hl),b                       ; the table's terminator
        ld hl,(RT_SYMTAB_PTR)
        ld (VARS_START),hl              ; the lowest table's base
        ret

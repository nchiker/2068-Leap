; ============================================================================
; rom/ext_printer_module.asm — loadable LPRINT/LLIST package (R8.5 Group
; 6 ROM reconciliation)
;
; LPRINT/LLIST were investigated (see this milestone's own real-
; measurement pass) and found to cost 174 bytes of V2-own resident glue
; (COMPILE_LPRINT/OP_LPRINT_NUM/STR/decompiler handlers) PLUS a real,
; previously-uncounted 253-byte dependency on the actual ZX-printer
; bit-banging logic in rom/exrom_printer.asm (unlike SPRITE, which
; never depended on its own V1 file, LPRINT's own resident opcodes
; tail-jumped directly into BASIC_STMT_LPRINT_EXROM). Following the
; SAME product principle already applied to SPRITE and MODE/ULAPLUS/
; PALETTE, this moves BOTH pieces into one loadable package, registered
; through the EXISTING R7.5 mechanism (kernel/extensions/ext_registry.
; asm's own EXT2_REGISTER/OP_CALL_EXT) -- LLIST is ENTIRELY NEW (it did
; not exist anywhere in V2 before this).
;
; TYPED ARGUMENTS: LPRINT is the first extension needing a STRING
; argument. Rather than special-case it, the R7.5 mechanism itself was
; generalized (kernel/extensions/ext_registry.asm's own EXT2_REC_LEN
; grew an argtypes bitmask; rom/exrom_v2_compiler.asm's COMPILE_EXT_
; CALL and rom/exrom_v2_decompiler.asm's .op_call_ext both consult it)
; -- see those files' own headers for the full account. LPRINT's own
; grammar (ONE argument, EITHER numeric or string, chosen by what the
; caller actually writes) is a genuine UNION type that a single fixed-
; per-position argtype bit can't express on its own, so rom/exrom_v2_
; compiler.asm's own COMPILE_LPRINT keeps a small resident peek-and-
; dispatch shell that resolves ONE of two internal registrations below
; (LPRINT for the numeric case, LPRINT$ for the string case -- only
; "LPRINT" is ever user-visible) -- see that routine's own header for
; why this is a real type-system limitation, not an avoided special
; case.
;
; KNOWN LIMITATION (float LPRINT): OP_CALL_EXT's own argument-passing
; ABI is, and always has been (R7.5's original design, matching V1's
; own extension ABI), plain-16-bit-int-only -- it discards the popped
; value's own tag before the exec routine ever runs. PRINT's own float
; support survives because OP_PRINT_NUM pops value+tag directly, never
; through this tag-blind path. LPRINT_NUM_EXEC below therefore treats
; every numeric argument as TAG_INT: "LPRINT 3.14" will NOT render the
; real decimal value (it has no way to know the popped value was really
; a FLOATTAB index, not a plain integer). This matches the "pure-
; integer" scope this project has already and repeatedly accepted for
; SGN/MOD/DIV/RND/PEEK/USR/LEN/CODE/VAL -- but unlike those, V1's own
; real LPRINT DID support floats (it shared PRINT's own evaluator), so
; this is flagged here as a genuine, deliberate, reported trade-off,
; not a silent regression. Preserving the tag through OP_CALL_EXT's own
; ABI would need a materially larger, more invasive change (either a
; wider argument-passing shape carrying a tag per argument, or a new
; resident opcode bridging the tag-aware VM_NUM_TO_TEXT conversion
; before the extension boundary) -- out of this pass's own scope;
; report this back for a decision before building it.
;
; LLIST: reuses the EXISTING resident DECOMPILE_PROGRAM (calling it
; directly, the same way this module calls kernel/graphics primitives
; directly -- no new decompiler ARCHITECTURE, per the user's own
; explicit direction) rather than reimplementing a second BASIC-listing
; engine. Does NOT impose the whole-program DECOMP_OUT_BUF 400-byte
; ceiling: rom/exrom_v2_decompiler.asm's own DECOMP_EMIT_NEWLINE grew a
; small, generic, opt-in streaming hook (DECOMP_LINE_CALLBACK) that
; fires after EVERY reconstructed line and resets DECOMP_OUT_PTR back
; to DECOMP_OUT_BUF -- LLIST_EXEC below sets that hook to PRT_LINE_HOOK
; before calling DECOMPILE_PROGRAM, so only ONE line's text needs to
; fit in the buffer at a time, streamed straight to the printer, however
; long the real program is. Every EXISTING caller of DECOMPILE_PROGRAM
; leaves the hook disabled (0) and sees identical whole-buffer behavior
; to before this addition.
;
; DECOMP_END_ADDR's own "caller contract" (previously only satisfied by
; test-harness COLD_START code) is now set automatically inside rom/
; exrom_v2_compiler.asm's own COMPILE_PROGRAM, from the real final
; EMIT_PTR -- so DECOMPILE_PROGRAM (and therefore LLIST, called at
; genuine runtime, long after any test harness setup) works correctly
; by construction; see that routine's own header.
;
; GLYPH LOOKUP: the real ZX-printer row renderer needs a character ->
; glyph mapping. rom/exrom_printer.asm's own real V1 implementation
; routes this through KTAB_BASIC_INPUT_SERVICE's D=6 selector solely
; because IT is permanently EXROM-resident while the real glyph table
; (kernel/graphics/graphics.asm's own GFX_CHAR_TO_FONT_OFFSET) is
; Home-resident -- a real ROM-banking constraint for code fixed in one
; bank calling into the other, not a basic.asm dependency (GFX_CHAR_TO_
; FONT_OFFSET itself has never been basic.asm-resident). A RAM-loaded
; module isn't fixed in either bank, so it calls GFX_CHAR_TO_FONT_
; OFFSET directly -- the exact same pattern rom/ext_sprite_module.asm
; already established for GFX_SPRITE_CAPTURE/GFX_SPRITE_DRAW (same
; file). This also means the loadable version has NO basic.asm
; dependency at all, unlike rom/exrom_printer.asm's own real KTAB path.
;
; ERROR REPORTING: OP_CALL_EXT doesn't check an extension's own return
; status (confirmed by reading its own body) -- PRT_RAISE writes VM_
; ERROR_CODE/VM_HALTED directly, same pattern rom/ext_sprite_module.asm
; and rom/ext_mode_module.asm already established.
; ============================================================================

; ---------------------------------------------------------------------------
; Module-private workspace. Real ZX-printer row-rendering scratch
; already exists as real, permanent sysvars (include/sysvars.inc's own
; PRINT_ROW_BUF..PRINT_LLIST_LINE, 42 bytes, added 2026-09-14 for
; exactly this purpose) -- reused directly, exactly like SPRITE_SLOT_*
; is reused directly by rom/ext_sprite_module.asm, needing ZERO new RAM
; for row rendering. PRINT_LLIST_LINE's own original purpose (a MEM_
; LINE_FIRST/NEXT walk cursor) doesn't apply here (V2 has no such
; stored-line list; LLIST_EXEC below walks DECOMP_OUT_BUF instead), so
; it's left unused rather than repurposed -- no need to fight over a
; single already-free 2-byte cell when RAM is otherwise abundant.
; ---------------------------------------------------------------------------

; PRT_RAISE -- input: A = this module's own error code. Sets VM_ERROR_
; CODE/VM_HALTED directly then returns via a plain ret; VM_RUN.loop
; notices VM_HALTED on its very next iteration. Destroys: AF.
PRT_RAISE:
        ld (VM_ERROR_CODE),a
        ld a,1
        ld (VM_HALTED),a
        ret

; ---------------------------------------------------------------------------
; PRINTER_MOTOR_STOP/PRINT_RASTER_ROW -- the raw hardware bit-bang layer
; (real PORT_PRINTER writes/polls). NOT included from this file:
; deliberately treated as an EXTERNAL dependency the including build/
; test provides, exactly the same shape rom/ext_sprite_module.asm
; already uses for GFX_SPRITE_CAPTURE/GFX_SPRITE_DRAW (defined in
; kernel/graphics/graphics.asm, never included BY the sprite module
; itself). Two reasons here: (1) real layering -- this file's own job
; is BASIC-level LPRINT/LLIST semantics (argument marshalling, text
; wrapping, chunking), not the raw electrical protocol, matching the
; same separation rom/exrom_printer.asm's own real file already had
; between PRINT_RASTER_ROW and the higher-level PRINTER_SEND_* routines
; above it; (2) testability -- PRINT_RASTER_ROW's own real `.wait_paper`
; poll spins forever with no printer attached (confirmed real behavior,
; matching real Sinclair BASIC -- see rom/exrom_printer.asm's own
; header), so no automated ZEsarUX fixture can run it to completion.
; The real, production copy lives in rom/printer_raster.asm (included
; by whatever build wires this module in); rom/test_v2_printer_module.
; asm includes its own stub instead, the same "stub the real file this
; specific test doesn't need/can't safely run" discipline this whole
; session already uses for kernel/graphics.asm et al.
;
; PRINTER_RENDER_ROW below is the one real adaptation from rom/
; exrom_printer.asm's own original: calls kernel/graphics's real GFX_
; CHAR_TO_FONT_OFFSET directly instead of going through the KTAB_BASIC_
; INPUT_SERVICE D=6 gateway (see this file's own header for why that's
; a real improvement, not a shortcut).
; ---------------------------------------------------------------------------

; PRINTER_RENDER_ROW ( -- ). Renders raster row PRINT_ROW_IDX (0-7) of
; the PRINT_CHUNK_LEN real characters at PRINT_CHUNK_ADDR into
; PRINT_ROW_BUF, space-padding columns past PRINT_CHUNK_LEN. A
; character with no glyph (GFX_CHAR_TO_FONT_OFFSET's own carry-set
; case) renders as a blank column, same treatment GFX_PUTCHAR gives it.
; Destroys: AF, BC, DE, HL
PRINTER_RENDER_ROW:
        xor a
        ld b,a
.colloop:
        ld a,b
        cp 32
        ret z
        ld a,(PRINT_CHUNK_LEN)
        cp b
        jr z,.usespace
        jr c,.usespace
        push bc
        ld hl,(PRINT_CHUNK_ADDR)
        ld c,b
        ld b,0
        add hl,bc
        ld a,(hl)
        pop bc
        jr .havechar
.usespace:
        ld a,' '
.havechar:
        push bc
        call GFX_CHAR_TO_FONT_OFFSET
        jr c,.noglyph
        ld a,(PRINT_ROW_IDX)
        ld e,a
        ld d,0
        add hl,de
        ld a,(hl)
        jr .storebyte
.noglyph:
        xor a
.storebyte:
        pop bc
        ld hl,PRINT_ROW_BUF
        ld e,b
        ld d,0
        add hl,de
        ld (hl),a
        inc b
        jr .colloop

; PRINTER_SEND_CHUNK ( -- ). Renders and sends the 8 raster rows of the
; PRINT_CHUNK_LEN-character chunk at PRINT_CHUNK_ADDR (rows 6-7 at slow
; speed), then stops the motor. Destroys: AF, BC, DE, HL
PRINTER_SEND_CHUNK:
        xor a
        ld (PRINT_ROW_IDX),a
.rowloop:
        call PRINTER_RENDER_ROW
        ld hl,PRINT_ROW_BUF
        ld a,(PRINT_ROW_IDX)
        cp 6
        jr c,.fastspeed
        ld a,1
        jr .callrow
.fastspeed:
        xor a
.callrow:
        call PRINT_RASTER_ROW
        ld a,(PRINT_ROW_IDX)
        inc a
        ld (PRINT_ROW_IDX),a
        cp 8
        jr c,.rowloop
        jp PRINTER_MOTOR_STOP

; PRINTER_SEND_TEXT ( HL = addr, BC = len -- ). Prints len characters
; wrapped into as many 32-column printed lines as needed (the last
; space-padded); len=0 still sends exactly one blank line. Destroys:
; AF, BC, DE, HL
PRINTER_SEND_TEXT:
        ld (PRINT_REMAINING),bc
        ld (PRINT_CUR_ADDR),hl
.lineloop:
        ld hl,(PRINT_REMAINING)
        ld a,h
        or a
        jr nz,.chunk32
        ld a,l
        cp 32
        jr nc,.chunk32
        ld (PRINT_CHUNK_LEN),a
        jr .havechunk
.chunk32:
        ld a,32
        ld (PRINT_CHUNK_LEN),a
.havechunk:
        ld hl,(PRINT_CUR_ADDR)
        ld (PRINT_CHUNK_ADDR),hl
        call PRINTER_SEND_CHUNK
        ld a,(PRINT_CHUNK_LEN)
        ld e,a
        ld d,0
        ld hl,(PRINT_CUR_ADDR)
        add hl,de
        ld (PRINT_CUR_ADDR),hl
        ld hl,(PRINT_REMAINING)
        or a
        sbc hl,de
        ld (PRINT_REMAINING),hl
        ld a,h
        or l
        jr nz,.lineloop
        ret

; ---------------------------------------------------------------------------
; LPRINT (numeric) — registered name "LPRINT", argcount=1, argtype=0.
; See this file's own header for the real, flagged float limitation.
; ---------------------------------------------------------------------------
PRT_LPRINT_NUM_NAME: db "LPRINT",0
PRT_LPRINT_NUM_EXEC:
        ld hl,(EXT_CALL_ARG0)
        ld a,TAG_INT
        call VM_NUM_TO_TEXT       ; HL = null-terminated decimal text
        push hl
        ld bc,0
.strlen:
        ld a,(hl)
        or a
        jr z,.havelen
        inc hl
        inc bc
        jr .strlen
.havelen:
        pop hl
        jp PRINTER_SEND_TEXT

; ---------------------------------------------------------------------------
; LPRINT (string) — registered name "LPRINT$" (never user-visible;
; rom/exrom_v2_compiler.asm's own COMPILE_LPRINT resolves this
; internally for a string-shaped argument -- see that routine's own
; header), argcount=1, argtype=1 (bit 0 set -- string).
; ---------------------------------------------------------------------------
PRT_LPRINT_STR_NAME: db "LPRINT$",0
PRT_LPRINT_STR_EXEC:
        ld hl,(EXT_CALL_ARG0)
        ld a,l
        call VM_STR_ADDR          ; HL -> record [len:1][content...]
        ld a,(hl)
        ld c,a
        ld b,0
        inc hl
        jp PRINTER_SEND_TEXT

; ---------------------------------------------------------------------------
; LLIST — registered name "LLIST", argcount=0. See this file's own
; header for the streaming design (no whole-program DECOMP_OUT_BUF size
; ceiling).
; ---------------------------------------------------------------------------
PRT_LLIST_NAME: db "LLIST",0
PRT_LLIST_EXEC:
        IFDEF V2_PRODUCTION
        ; The production editor and SAVE/LOAD retain authoritative source.
        ; Print its records directly, one line at a time, with no bytecode
        ; reconstruction or 400-byte decompiler output limit.
        call MEM_LINE_FIRST
.source_line:
        ld a,h
        or l
        ret z
        push hl
        ld c,(hl)
        dec c                      ; record length includes its CR
        ld b,0
        inc hl
        inc hl                     ; skip two-byte record length
        call PRINTER_SEND_TEXT
        pop hl
        call MEM_LINE_NEXT
        jr .source_line
        ELSE
        ld hl,PRT_LINE_HOOK
        ld (DECOMP_LINE_CALLBACK),hl
        call DECOMPILE_PROGRAM
        ld hl,0
        ld (DECOMP_LINE_CALLBACK),hl   ; always disable again, even on
                                          ; a decompile error below --
                                          ; never leave the hook armed
        ld a,(DECOMP_ERROR_CODE)
        or a
        ret z
        ld a,21                          ; module-private error code:
        jp PRT_RAISE                     ; LLIST's own decompile failed
                                            ; (malformed bytecode -- see
                                            ; DECOMP_ERROR_CODE's own
                                            ; real value table for which)

; PRT_LINE_HOOK -- DECOMP_LINE_CALLBACK's own target while LLIST_EXEC's
; call to DECOMPILE_PROGRAM is in progress. Reached via DECOMP_EMIT_
; NEWLINE's own `call DECOMP_CALL_LINE_HOOK` tail-dispatch trampoline
; (jp (hl), so this routine's own RET returns control to DECOMP_EMIT_
; NEWLINE, exactly like every other tail-dispatched routine in this
; project) after each reconstructed line (DECOMP_OUT_BUF[0..
; DECOMP_LINE_LEN)) is written -- DECOMP_LINE_LEN counts the line's own
; trailing CR, excluded here (a printed line doesn't need it sent to
; the printer; PRINTER_SEND_TEXT's own wrapping already terminates each
; printed line on its own). Destroys: AF, BC, DE, HL.
PRT_LINE_HOOK:
        ld a,(DECOMP_LINE_LEN)
        dec a
        ld c,a
        ld b,0
        ld hl,DECOMP_OUT_BUF
        jp PRINTER_SEND_TEXT
        ENDIF

; ---------------------------------------------------------------------------
; PRT_INSTALL — registers all 3 operations (LPRINT's 2 internal slots +
; LLIST). Call once (from whatever real loader eventually brings this
; module into RAM -- for now, this test's own COLD_START calls it
; directly, matching the sprite/mode modules' own demo pattern). Out:
; carry set on failure. Destroys: AF, BC, DE, HL.
; ---------------------------------------------------------------------------
PRT_INSTALL:
        ld hl,PRT_LPRINT_NUM_NAME
        ld de,PRT_LPRINT_NUM_EXEC
        ld b,1
        ld c,0                  ; argtype 0 = numeric
        call EXT2_REGISTER
        ret c
        ld hl,PRT_LPRINT_STR_NAME
        ld de,PRT_LPRINT_STR_EXEC
        ld b,1
        ld c,1                  ; argtype bit0 = string
        call EXT2_REGISTER
        ret c
        ld hl,PRT_LLIST_NAME
        ld de,PRT_LLIST_EXEC
        ld b,0
        ld c,0
        jp EXT2_REGISTER

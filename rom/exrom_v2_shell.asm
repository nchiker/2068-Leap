; R9 production V2 interaction. The generic plain-text line store is the
; durable program; VM_CODE_BASE is regenerated from it on every RUN.
V2_WORK_PTR EQU $BE70
V2_WORK_INDEX EQU $BE72
V2_DRAW_PTR EQU $BE74
V2_DRAW_ROW EQU $BE76
V2_DRAW_SUBROW EQU $BE77
V2_DRAW_LEN EQU $BE78
V2_DRAW_COL EQU $BE79
V2_CMD_PTR EQU $BE7A
V2_NAME_PTR EQU $BE7C
V2_NAME_LEN EQU $BE7E
; The retained EXROM editor's LEFT/RIGHT fast path reads this shared row.
V2_ACTIVE_ROW EQU BASIC_ACTIVE_ROW
V2_REQUEST_TYPE EQU $BE81
V2_PACKAGE_LEN EQU $BE82
; R10.9: the package ABI / tape format versions live in include/v2_package_abi.inc.
; R10 correction: single-error return-to-line (docs/v2/POST_R9_
; SEMANTIC_MILESTONE.md's own editor-audit findings). Placed in the
; $BE84-$BED7 reserved gap (R9_CUTOVER_LEDGER.md's RAM table) -- fixed
; EQUs, not sequential sysvars.inc offsets, so this costs no address
; shift anywhere else.
V2_RUN_IS_STORED EQU $BE84    ; 1 = the just-attempted RUN compiled from
                                ; the stored line-store via V2_BUILD_
                                ; SOURCE (V2_RUN_STORED); 0 = an
                                ; immediate colon-statement compiled
                                ; from EDIT_LINE_BUF (V2_RUN_IMMEDIATE),
                                ; which has no separate stored line to
                                ; jump to
V2_ERR_TARGET_OFS EQU $BE85   ; V2_JUMP_TO_ERROR_LINE's own target
                                ; staging-buffer byte offset (2 bytes)
V2_ERR_RUN_COUNT EQU $BE87    ; V2_JUMP_TO_ERROR_LINE's own running
                                ; staged-byte counter (2 bytes)

; R10 keyword-bolding: same documented $BE84-$BED7 reserved gap,
; placed right after the single-error return-to-line block above
; (both were prototyped in parallel, independently, and originally
; claimed the same $BE84 start address -- a trivial relocation, not a
; design conflict). V2_DRAW_BOLD_ENABLE gates V2_DRAW_TEXT's own
; bold-vs-plain dispatch per caller (LIST/settled rows: on; the
; actively-edited row: off, matching V1's own established UX -- see
; V2_KW_DETECT_SPANS's own header). KW_SPAN_TABLE holds up to
; KW_SPAN_MAX [start_offset][length] pairs, silently capped like this
; project's other small bounded tables.
V2_DRAW_BOLD_ENABLE EQU $BE89
V2_KW_LINE_BASE     EQU $BE8A
V2_KW_TABLE_BASE    EQU $BE8C
V2_KW_TABLE_COUNT   EQU $BE8E
V2_KW_WORD_START    EQU $BE8F
V2_KW_SCAN_RESUME   EQU $BE91
V2_KW_WORD_LEN      EQU $BE93
V2_KW_TMP_OFFSET    EQU $BE94
KW_SPAN_COUNT       EQU $BE95
KW_SPAN_TABLE       EQU $BE96
KW_SPAN_MAX: equ 8
; ($BE96 + 8*2 = $BEA6 -- next free byte for the status-line block
; below)

; R10 status-line/error-display: same shared gap, placed right after
; the keyword-bolding block above (also originally claimed $BE84
; independently).
V2_LINE_COUNT EQU $BEA6
V2_STATUS_BUF EQU $BEA8
; ($BEA8 + 20 = $BEBC -- 28 bytes of the original 84-byte gap
; ($BE84-$BED7) remain free after all three R10 editor additions)

; Dynamic Data Phase 2 -- SAVE/LOAD "name" ARRAY arrname. V2_PARSE_
; NAME's own new ARRAY-qualifier branch sets these the same way its
; existing EXT-qualifier branch already sets V2_REQUEST_TYPE. Placed in
; the same $BEBC-$BED7 remaining free span noted above.
V2_ARRAY_NAME_PTR EQU $BEBC
V2_ARRAY_NAME_LEN EQU $BEBE
V2_ARRAY_IS_STR   EQU $BEBF
; ($BEC0-$BECA were V2_ARRAY_INDEX / V2_RECEIVE_DEST / V2_ARRAY_NAME_CANON, used only by the
; pre-R10.9 pool-path V2_LOAD_ARRAY and its 8-character name fold; free again in Phase 2C.)

V2_COMMAND_LOOP:
    xor a
    ld (CURRENT_INK),a
    ld (CURRENT_BRIGHT),a
    ld (CURRENT_FLASH),a
    ld (CURRENT_INVERSE),a
    ld (CURRENT_OVER),a
    ld a,7
    ld (CURRENT_PAPER),a
    call KTAB_GFX_CLS
    ld a,7
    call KTAB_GFX_SET_BORDER
    xor a
    call KTAB_GFX_SET_MODE
    call V2_RESET_EDIT
    call STARTUP_CHIME          ; R10.7: one-time boot chime -- this is
                                  ; V2_COMMAND_LOOP's own one-time head,
                                  ; reached only from V2_EXROM_ENTRY, NOT
                                  ; the .loop re-entry point below that
                                  ; NEW/every return-to-editor actually
                                  ; uses (see V2_EXROM_ENTRY's own single
                                  ; caller, confirmed via `grep -n
                                  ; V2_COMMAND_LOOP rom/*.asm`)
    IFDEF V2_AUTOLOAD_TEST
    ; Test-only entry: start the production loader immediately after the
    ; emulator's tape-insert reset, while the real pilot is still playing.
    xor a
    ld (V2_REQUEST_TYPE),a
    ld (V2_NAME_LEN),a
    call V2_LOAD
    ENDIF
.loop:
    call EDITOR_INIT
    ld hl,V2_REDRAW
    ld (EDITOR_REDRAW_HOOK),hl
    ld hl,V2_NAV
    ld (EDITOR_NAV_HOOK),hl
    call V2_LOAD_EDIT
    ld hl,(CUR_EDIT_POS)
    ld a,h
    cp $FF
    jr nz,.edit_existing
    ld hl,(PROG_END)
.edit_existing:
    call EDITOR_ENTER
    ld a,(EDIT_LINE_BUF)
    or a
    jr z,.loop
    ld hl,(CUR_EDIT_POS)
    ld a,h
    cp $FF
    jr nz,.store
    call V2_DISPATCH
    jr nc,.loop
.store:
    call V2_CLEAR_ARRAYS         ; a previous RUN lowered VARS_START (its run-time
                                   ; tables); restore the ceiling before the fit check
    call V2_TOKENIZE
    ld hl,(CUR_EDIT_POS)
    ld a,h
    cp $FF
    jr nz,.have_pos
    ld hl,(PROG_END)
.have_pos:
    ld de,TOKEN_BUF
    call KTAB_MEM_LINE_STORE
    call V2_CLEAR_ARRAYS         ; R10.7 P0: the line store grows at PROG_END,
                                   ; exactly where DIM'd arrays live. Discard
                                   ; them AFTER the store (so ARRAYS_END ==
                                   ; the new PROG_END); V2_CLEAR_ARRAYS keeps
                                   ; the carry from the store intact
                                   ; (docs/v2/R10_7_WORKSPACE_MANAGER_
                                   ; FEASIBILITY.md s8)
    jr c,.no_space
    ld hl,(CUR_EDIT_POS)
    ld a,h
    cp $FF
    jr nz,.advance
    call V2_COUNT_LINES
    ld (CUR_EDIT_INDEX),de
    jr .loop
.advance:
    ld hl,(CUR_EDIT_INDEX)
    inc hl
    ld (CUR_EDIT_INDEX),hl
    call V2_SET_EDIT_FROM_INDEX
    jr .loop
.no_space:
    ld hl,V2_MSG_FULL
    call V2_SHOW_MESSAGE
    jr .loop

; Convert EDIT_LINE_BUF into the generic record format. This is the same
; verbatim copy V1 called tokenization, with no V1 language processing.
V2_TOKENIZE:
    ld hl,EDIT_LINE_BUF
    ld b,0
.count:
    ld a,(hl)
    or a
    jr z,.counted
    inc hl
    inc b
    jr .count
.counted:
    ld a,b
    inc a
    ld (TOKEN_BUF),a
    xor a
    ld (TOKEN_BUF+1),a
    ld hl,EDIT_LINE_BUF
    ld de,TOKEN_BUF+2
    ld a,b
    or a
    jr z,.end
.copy:
    ld a,(hl)
    ld (de),a
    inc hl
    inc de
    djnz .copy
.end:
    ld a,$0D
    ld (de),a
    ret

; ============================================================================
; STARTUP_CHIME -- R10.7: one-time boot acknowledgement, ported verbatim
; (same notes, same table, same values) from the sibling 2068-forth
; project's own STARTUP_CHIME (~/2068-forth/rom/forth_boot.asm), which
; already went through real live-audio (WAV/FFT) testing there: an old-
; Mac-style C4/E4/G4 chord, staggered entrance per AY channel with a
; volume ramp on attack/release so three square waves don't all snap on
; (and off) at once -- that produces an audible click plus clashing
; harmonics, not a clean chime (see 2068-forth's own header for the full
; before/after story). Same AY clock/period formula, same table-driven
; event walk. Two differences from the 2068-forth source, both just
; plumbing, not design: SOUND_EXROM (already EXROM-resident here, 1-16
; register range) in place of that project's SOUND_WRITE; and a direct
; (FRAMES) read in CHIME_DELAY below in place of a cross-ROM
; INT_GET_FRAMES call -- INT_GET_FRAMES itself lives in kernel/
; interrupt.asm, which is Home-resident and not reachable from EXROM
; without new KTAB plumbing, while FRAMES is a plain RAM sysvar already
; read directly from EXROM elsewhere (rom/exrom_payload.asm), so no new
; KTAB entry is needed for this.
;
; Channel A's tone-period FINE byte is chip register 0 -- SOUND_EXROM's
; own 1-16 range check (same real-ROM-derived range as 2068-forth's
; SOUND_WRITE) can never reach it, so it's written directly via OUT
; here, same as the 2068-forth original -- boot code writing the chip
; directly, not a violation of SOUND_EXROM's own public range contract.
;
; Called once from V2_COMMAND_LOOP's own one-time head (see that call
; site's own comment) -- never from .loop, so this never replays on
; NEW or any other return to the editor.
; ============================================================================
STARTUP_CHIME:
    ld   a, 0                       ; Channel A tone period, fine --
    out  (PORT_AY_REG), a           ; chip register 0, outside SOUND_
    ld   a, 165                     ; EXROM's own 1-16 range -- written
    out  (PORT_AY_DATA), a          ; directly instead

    ld   hl, CHIME_TABLE
.loop:
    ld   a, (hl)
    inc  hl
    cp   $FE
    ret  z
    cp   $FF
    jr   z, .delay
    ld   b, a
    ld   a, (hl)
    inc  hl
    ld   c, a
    call SOUND_EXROM
    jr   .loop
.delay:
    ld   a, (hl)
    inc  hl
    ld   b, a
    push hl                         ; CHIME_DELAY destroys HL -- protect
    call CHIME_DELAY                ; the table pointer across the call
    pop  hl
    jr   .loop

CHIME_TABLE:
    ; Channel A/B/C tone periods (C4/E4/G4, ~262/330/392 Hz); mixer (all
    ; three tones on, all noise off); all three channels silent until
    ; their own staggered attack below.
    DB   1,1,  2,78,  3,1,  4,25,  5,1,  7,248,  8,0,  9,0,  10,0
    ; staggered, ramped attack: A rolls in first, then B, then C, each
    ; fading up over 3 steps instead of snapping to full volume
    DB   8,4,  $FF,3,  8,8,  $FF,3,  8,12, $FF,3   ; gap before B enters
    DB   9,4,  $FF,3,  9,8,  $FF,3,  9,12, $FF,3   ; gap before C enters
    DB   10,4, $FF,3,  10,8, $FF,3,  10,12         ; full chord now sounding
    DB   $FF,22                      ; hold the full chord ~440ms
    ; release: all three fade down together
    DB   8,8,  9,8,  10,8,  $FF,3
    DB   8,4,  9,4,  10,4,  $FF,3
    DB   8,0,  9,0,  10,0            ; the AY holds its last register
                                     ; state indefinitely otherwise
    DB   $FE,0                       ; end of table

; CHIME_DELAY -- busy-waits until FRAMES has advanced by B ticks. Reads
; the FRAMES sysvar directly (see STARTUP_CHIME's own header for why,
; same as rom/exrom_payload.asm's existing precedent) instead of a
; cross-ROM INT_GET_FRAMES call.
; In: B = frame count. Destroys: AF, HL, DE
CHIME_DELAY:
    ld   h, 0
    ld   l, b
    ex   de, hl                     ; de = frame count to wait
    ld   hl, (FRAMES)               ; hl = current frames
    add  hl, de
    ex   de, hl                     ; de = target frame count
.wait:
    ld   hl, (FRAMES)               ; only touches hl -- de (target)
                                    ; survives across this loop
    or   a
    sbc  hl, de
    jr   c, .wait                   ; current < target -- keep waiting
    ret

V2_RESET_EDIT:
    ld hl,$FFFF
    ld (CUR_EDIT_POS),hl
    ld hl,0
    ld (CUR_EDIT_INDEX),hl
    ld (VIEW_TOP_INDEX),hl
    ret

V2_COUNT_LINES:
    call KTAB_MEM_LINE_FIRST
    ld de,0
.loop:
    ld a,h
    or l
    ret z
    inc de
    push de
    call KTAB_MEM_LINE_NEXT
    pop de
    jr .loop

; Input DE = zero-based record index; returns HL=record or $FFFF sentinel.
V2_FIND_INDEX:
    ld (V2_WORK_INDEX),de
    call KTAB_MEM_LINE_FIRST
.loop:
    ld de,(V2_WORK_INDEX)
    ld a,d
    or e
    ret z
    ld a,h
    or l
    jr z,.sentinel
    push hl
    ld hl,(V2_WORK_INDEX)
    dec hl
    ld (V2_WORK_INDEX),hl
    pop hl
    call KTAB_MEM_LINE_NEXT
    jr .loop
.sentinel:
    ld hl,$FFFF
    ret

; V2_JUMP_TO_ERROR_LINE -- R10 single-error return-to-line (an
; intentional V2 design DIFFERENT from V1: V1's static checker could
; collect and let the user browse up to 16 compile-time errors
; (CHECK_ERROR_LIST); V2's compiler stops at the first error, same as
; before, and this routine returns the cursor directly to that one
; source line. Full multi-error collection would need real compiler
; resynchronization/recovery -- deliberately deferred, not accidentally
; lost; not attempted here).
;
; R10.9 Phase 2D (defect D4): the lexer now counts source lines itself
; (LEX_LINE: one per CR token or LF continuation marker, see LEX_COUNT_LINE
; in rom/exrom_v2_compiler.asm), so the failing line is simply that count --
; no walk of the line store to match a record pointer. (R10.7 compared against
; CHUNK_CUR_REC_PTR, the most recently *appended* record, which runs up to the
; 128-byte chunk margin ahead of the failing token: the cursor landed on a
; later line, or on the last one.) Bit 15 of LEX_LINE is the lexer's "CR not
; counted yet" flag and is masked off. An error raised at end of source (an
; unterminated PROC, block IF or FOR; an undefined label, which is only checked
; there) leaves the count equal to the number of lines: the cursor lands on the
; empty line after the last one, where the missing NEXT / ENDIF / ENDP / label
; would be typed (V2_FIND_INDEX answers $FFFF = "the append position").
;
; Sets CUR_EDIT_INDEX/CUR_EDIT_POS to the located line via
; V2_SET_EDIT_FROM_INDEX -- the same mechanism arrow-key navigation
; already uses. V2_REDRAW's own existing VIEW_TOP_INDEX auto-scroll
; (see its own header) then brings the line into view on the very next
; redraw; no separate scrolling logic is needed here.
; Destroys: AF, DE, HL.
V2_JUMP_TO_ERROR_LINE:
    ld hl,(LEX_LINE)
    res 7,h
    ld (CUR_EDIT_INDEX),hl
    ; falls through into V2_SET_EDIT_FROM_INDEX (kept adjacent on purpose)

V2_SET_EDIT_FROM_INDEX:
    ld de,(CUR_EDIT_INDEX)
    call V2_FIND_INDEX
    ld a,h
    or l
    jr nz,.found
    ld hl,$FFFF
.found:
    ld (CUR_EDIT_POS),hl
    jr V2_LOAD_EDIT

V2_LOAD_EDIT:
    ld hl,(CUR_EDIT_POS)
    ld a,h
    cp $FF
    jr nz,.existing
    xor a
    ld (EDIT_LINE_BUF),a
    jr .reset
.existing:
    inc hl
    inc hl
    ld de,EDIT_LINE_BUF
    ld b,127
.copy:
    ld a,(hl)
    cp $0D
    jr z,.terminate
    ld (de),a
    inc hl
    inc de
    djnz .copy
.terminate:
    xor a
    ld (de),a
.reset:
    ld hl,0
    ld (EDIT_BUF_OFFSET),hl
    ret

; Reuse the canonical EXROM editor's navigation hook and line-store API.
V2_NAV:
    cp EDIR_DELETE_LINE
    jr z,.delete
    cp EDIR_INSERT_LINE
    jr z,.insert
    cp EDIR_UP
    jr z,.wrap_up
    cp EDIR_DOWN
    ret nz
.wrap_down:
    ld hl,EDIT_LINE_BUF
    call EDITOR_WRAP_CALC
    call EDITOR_WRAP_OFFSET_TO_ROWCOL
    ld a,(EDIT_WRAP_COUNT)
    dec a
    cp b
    jr z,.down
    inc b
    call EDITOR_WRAP_ROWCOL_TO_OFFSET
    ld (EDIT_BUF_OFFSET),a
    xor a
    ld (EDIT_BUF_OFFSET+1),a
    ret
.wrap_up:
    ld hl,EDIT_LINE_BUF
    call EDITOR_WRAP_CALC
    call EDITOR_WRAP_OFFSET_TO_ROWCOL
    ld a,b
    or a
    jr z,.up
    dec b
    call EDITOR_WRAP_ROWCOL_TO_OFFSET
    ld (EDIT_BUF_OFFSET),a
    xor a
    ld (EDIT_BUF_OFFSET+1),a
    ret
.down:
    call V2_COUNT_LINES
    ld hl,(CUR_EDIT_INDEX)
    or a
    sbc hl,de
    ret nc
    ld hl,(CUR_EDIT_INDEX)
    inc hl
    ld (CUR_EDIT_INDEX),hl
    jp V2_SET_EDIT_FROM_INDEX
.up:
    ld hl,(CUR_EDIT_INDEX)
    ld a,h
    or l
    ret z
    dec hl
    ld (CUR_EDIT_INDEX),hl
    jp V2_SET_EDIT_FROM_INDEX
.delete:
    ld hl,(CUR_EDIT_POS)
    ld a,h
    cp $FF
    ret z
    ld d,h
    ld e,l
    call KTAB_MEM_LINE_DELETE_RANGE
    call V2_COUNT_LINES
    ld hl,(CUR_EDIT_INDEX)
    or a
    sbc hl,de
    jr c,.delete_load
    ld (CUR_EDIT_INDEX),de
.delete_load:
    jp V2_SET_EDIT_FROM_INDEX
.insert:
    ld hl,(CUR_EDIT_POS)
    ld a,h
    cp $FF
    ret z
    ld de,V2_BLANK_RECORD
    call KTAB_MEM_LINE_INSERT
    ret c
    jp V2_LOAD_EDIT
V2_BLANK_RECORD: DB 1,0,$0D

; R10.7 source-staging-architecture change (docs/v2/R10_7_SOURCE_STAGING_
; ARCHITECTURE_AUDIT.md): V2_BUILD_SOURCE no longer flattens the whole
; stored program into V2_SOURCE_STAGE. It primes the small CHUNK_SIZE-byte
; rolling window instead; the lexer (rom/exrom_v2_compiler.asm) refills it
; one authoritative record at a time, via the HOME-resident CHUNK_REFILL,
; as it consumes the buffer. This file is EXROM-resident, CHUNK_REFILL is
; HOME-resident, hence the one new KTAB entry (KTAB_CHUNK_REFILL) for this
; single priming call -- CHUNK_REFILL's other two call sites are inside
; the lexer itself (same bank, direct, no trampoline needed).
V2_BUILD_SOURCE:
    call KTAB_MEM_LINE_FIRST
    ld (CHUNK_NEXT_REC),hl
    ld hl,CHUNK_BUF
    ld (SRC_PTR),hl
    ld (CHUNK_FILL_PTR),hl
    jp KTAB_CHUNK_REFILL

V2_RUN_STORED:
    call V2_BUILD_SOURCE
    ld hl,V2_SOURCE_STAGE
    ld a,1
    ld (V2_RUN_IS_STORED),a
    jr V2_COMPILE_RUN
V2_RUN_IMMEDIATE:
    xor a
    ld (V2_RUN_IS_STORED),a   ; an immediate colon-statement has no
                                ; separate stored line to jump to
    ld hl,EDIT_LINE_BUF+1
V2_COMPILE_RUN:
    ld (SRC_PTR),hl
    call KTAB_COMPILER_INIT
    ld hl,VM_CODE_BASE
    ld (EMIT_PTR),hl
    call KTAB_COMPILE_PROGRAM
    ld a,(COMPILE_ERROR_CODE)
    or a
    jr z,.compiled
    ; R10 correction: return the cursor to the (approximate) failing
    ; source line before showing the message, so dismissing SYNTAX
    ; ERROR lands the user back in context instead of wherever the
    ; editor happened to be before RUN. Compile-time only -- runtime
    ; errors have no source-position backreference from bytecode and
    ; remain a separate, documented, unresolved problem (see this
    ; routine's own header and docs/v2/POST_R9_SEMANTIC_MILESTONE.md's
    ; editor-audit findings).
    ld a,(V2_RUN_IS_STORED)
    or a
    jr z,.no_jump
    call V2_JUMP_TO_ERROR_LINE
.no_jump:
    ld a,(COMPILE_ERROR_CODE)
    call V2_COMPILE_MSG
    jp V2_SHOW_MESSAGE
.compiled:
    call KTAB_VM_INIT
    call ARR_RUN_INIT            ; R10.9 2B: Array Store bind (EXROM)
    ld hl,VM_CODE_BASE
    ld (VM_IP),hl
    call KTAB_GFX_CLS
    call KTAB_VM_RUN
    ld a,(VM_ERROR_CODE)
    or a
    jr z,.finished
    call V2_RUNTIME_MSG
    jp V2_SHOW_MESSAGE
.finished:
    jp KTAB_IO_READ_KEY

; Error-message selection (R10.7 P0: memory exhaustion and name/nesting
; limits are distinguishable from ordinary syntax/runtime errors).
; V2_COMPILE_MSG: A = COMPILE_ERROR_CODE -> HL = message.
; Compile codes: 60 nesting too deep, 61 identifier too long, 64 unexpected token, 1/39 more than 255
; symbols of a kind, and the capacity class {5,6,45,55,62} = out of memory.
V2_COMPILE_MSG:
    ld hl,V2_MSG_NAMELEN
    cp 61
    ret z
    ld hl,V2_MSG_NEST
    cp 60
    ret z
    ld hl,V2_MSG_UNEXPECTED
    cp 64                        ; R10.9 2D: unexpected token
    ret z
    ld hl,V2_MSG_TOOMANY
    cp 1
    ret z
    cp 39
    ret z
    ld hl,V2_MEMCODES
    ld bc,V2_MEMCODES_END-V2_MEMCODES
    cpir
    ld hl,V2_MSG_NOMEM
    ret z
    ld hl,V2_MSG_SYNTAX
    ret
V2_MEMCODES: DB 5,6,45,55,62
V2_MEMCODES_END:
; V2_RUNTIME_MSG: A = VM_ERROR_CODE -> HL = message. 2 and 6 are operand /
; control stack overflow, 64 is array-arena exhaustion.
V2_RUNTIME_MSG:
    ld hl,V2_MSG_STACK
    cp 2
    ret z
    cp 6
    ret z
    ld hl,V2_MSG_NOMEM
    cp 64
    ret z
    ld hl,V2_MSG_ARRAY_SHAPE
    cp 65
    ret z
    ld hl,V2_MSG_RUNTIME
    ret

V2_DISPATCH:
    ld hl,EDIT_LINE_BUF
    ld de,V2_KW_RUN
    call V2_MATCH_EXACT
    jr c,.not_run
    call V2_RUN_STORED
    or a
    ret
.not_run:
    ld hl,EDIT_LINE_BUF
    ld de,V2_KW_LIST
    call V2_MATCH_EXACT
    jr c,.not_list
    call V2_LIST
    or a
    ret
.not_list:
    ld hl,EDIT_LINE_BUF
    ld de,V2_KW_NEW
    call V2_MATCH_EXACT
    jr c,.not_new
    ld hl,ARR2_BASE
    ld (PAS_END),hl              ; NEW (only) clears the Array Store
    call MEM_INIT_V2
    call V2_RESET_EDIT
    or a
    ret
.not_new:
    ld hl,EDIT_LINE_BUF
    ld de,V2_KW_SAVE
    call V2_MATCH_PREFIX
    jr c,.not_save
    call V2_PARSE_NAME
    jr c,.bad_command
    ld a,(V2_REQUEST_TYPE)
    cp STORAGE_ARRAY_TYPE
    jr nz,.save_plain
    call V2_SAVE_ARRAY
    or a
    ret
.save_plain:
    call V2_SAVE
    or a
    ret
.not_save:
    ld hl,EDIT_LINE_BUF
    ld de,V2_KW_LOAD
    call V2_MATCH_PREFIX
    jr c,.not_load
    call V2_PARSE_NAME
    jr c,.bad_command
    ld a,(V2_REQUEST_TYPE)
    cp STORAGE_ARRAY_TYPE
    jr nz,.load_plain
    call V2_LOAD_ARRAY
    or a
    ret
.load_plain:
    call V2_LOAD
    or a
    ret
.not_load:
    ld hl,EDIT_LINE_BUF
    ld de,V2_KW_VERIFY
    call V2_MATCH_PREFIX
    jr c,.not_verify
    call V2_PARSE_NAME
    jr c,.bad_command
    call V2_VERIFY
    or a
    ret
.not_verify:
    ld a,(EDIT_LINE_BUF)
    cp ':'
    jr nz,.unknown
    call V2_RUN_IMMEDIATE
    or a
    ret
.bad_command:
    ld hl,V2_MSG_SYNTAX
    call V2_SHOW_MESSAGE
    or a
    ret
.unknown:
    scf
    ret

; EXROM can reset the generic line store without reaching the V1 ABI.
; V2_CLEAR_ARRAYS -- R10.7 P0/P3. Discards every DIM'd array and the compile
; symbol table (so "never DIM'd" is what SAVE/LOAD ... ARRAY see), and gives
; the pool its full height back. Called whenever the line store changes (ENTER-store, LOAD, NEW,
; CLEAR) so source text can never overwrite live array descriptors, and
; SAVE/LOAD ... ARRAY can never read stale ones. The two tables are
; contiguous (ASSERTed).
V2_CLEAR_ARRAYS:
    call SYM_RESET               ; the compile symbol table lives at PROG_END and
                                   ; is invalidated by the same events
    ld hl,(SYM_END_V)
    inc hl                       ; first byte after the (empty) table
    ld (ARRAYS_END),hl
    ld hl,V2_SOURCE_END          ; R10.7 P3: a RUN carves its run-time tables from
    ld (VARS_START),hl           ; the pool top (lowering VARS_START); any edit
    ld hl,(PAS_END)              ; R10.7 P5.4: segment 2 (always-visible RAM at
    ld (ARR2_END),hl             ; $E000) is emptied with the main pool, but the
                                   ; Array Store below PAS_END survives
    ret                          ; discards them, so the source may grow again

MEM_INIT_V2:
    ld hl,PROG_AREA_START
    ld (PROG_END),hl
    call V2_CLEAR_ARRAYS
    ld hl,V2_SOURCE_END
    ld (VARS_START),hl
    call KTAB_EXT2_CLEAR_ALL
    ld hl,0
    ld (V2_PACKAGE_LEN),hl
    ret

; MEM_CLEAR_V2 -- CLEAR statement, run-scoped (R10.9 Phase 2C, D8). Called by HOME's
; OP_CLEAR (EXROM is mapped during ordinary VM execution). It resets what the running
; program owns and nothing else: the carved run tables (scalars, floats, strings,
; array pointers) are zeroed in place, the ordinary-array arena restarts exactly as
; VM_INIT leaves it, and the persistent Array Store is rebound. It does NOT touch the
; compile symbol table or VARS_START (the tables stay valid), the control stack,
; the program, or loaded packages.
MEM_CLEAR_V2:
    ld hl,(SYM_END_V)
    inc hl
    ld (ARRAYS_END),hl           ; as VM_INIT: the arena starts past the symbol table
    ld hl,V2_SOURCE_END
    ld de,(VARS_START)
    or a
    sbc hl,de
    ld b,h
    ld c,l                       ; BC = carved block length
    ex de,hl                     ; HL = block start
    call KTAB_MEM_FILL_ZERO
    jp ARR_RUN_INIT              ; ARR2_END = PAS_END, rebind the stored arrays

V2_MATCH_EXACT:
    call V2_MATCH_PREFIX
    ret c
.trailing:
    ld a,(hl)
    or a
    ret z
    cp ' '
    jr nz,.fail
    inc hl
    jr .trailing
.fail:
    scf
    ret
V2_MATCH_PREFIX:
    ld a,(de)
    or a
    jr z,.matched
    ld b,a
    ld a,(hl)
    cp 'a'
    jr c,.compare
    cp 'z'+1
    jr nc,.compare
    sub 32
.compare:
    cp b
    jr nz,.fail
    inc hl
    inc de
    jr V2_MATCH_PREFIX
.matched:
    ld a,(hl)
    or a
    jr z,.success
    cp ' '
    jr nz,.fail
.success:
    or a
    ret
.fail:
    scf
    ret

; HL follows SAVE or LOAD. Return filename pointer and length.
V2_PARSE_NAME:
    xor a
    ld (V2_REQUEST_TYPE),a
.spaces:
    ld a,(hl)
    cp ' '
    jr nz,.quote
    inc hl
    jr .spaces
.quote:
    cp '"'
    jr nz,.bad
    inc hl
    ld (V2_NAME_PTR),hl
    ld b,0
.scan:
    ld a,(hl)
    cp '"'
    jr z,.closed
    or a
    jr z,.bad
    inc hl
    inc b
    ld a,b
    cp 11
    jr nc,.bad
    jr .scan
.closed:
    ld a,b
    ld (V2_NAME_LEN),a
    inc hl
.tail:
    ld a,(hl)
    or a
    ret z
    cp ' '
    jr nz,.qualifier
    inc hl
    jr .tail
.qualifier:
    ld de,V2_KW_EXT
    call V2_MATCH_EXACT
    jr c,.not_ext
    ld a,STORAGE_EXTENSION_TYPE
    ld (V2_REQUEST_TYPE),a
    or a
    ret
.not_ext:
    ld de,V2_KW_ARRAY
    call V2_MATCH_PREFIX      ; leaves HL right after "ARRAY" (its own
                                ; comparison loop advances HL per
                                ; matched char, same as every other
                                ; V2_MATCH_PREFIX call site)
    jr c,.bad
    call V2_SCAN_ARRAY_NAME
    jr c,.bad
    ld a,STORAGE_ARRAY_TYPE
    ld (V2_REQUEST_TYPE),a
    or a
    ret
.bad:
    scf
    ret

; V2_SCAN_ARRAY_NAME -- HL follows "ARRAY" (pointing at the space
; before the array name). Scans a bare array identifier: letters/
; digits, up to 8 significant characters, optionally ending in '$'
; (the SAME TOK_IDENT/TOK_STR_IDENT-by-trailing-'$' convention rom/
; exrom_v2_compiler.asm's own lexer uses, reused here rather than
; inventing a second way to spell "this is a string array"). Output:
; carry clear + V2_ARRAY_NAME_PTR/LEN set (LEN excludes a trailing '$')
; + V2_ARRAY_IS_STR = 0/1; carry set (bad command) if no valid name
; follows. Destroys: AF, B, HL.
V2_SCAN_ARRAY_NAME:
    xor a
    ld (V2_ARRAY_IS_STR),a
.spaces:
    ld a,(hl)
    cp ' '
    jr nz,.have_char
    inc hl
    jr .spaces
.have_char:
    cp 'A'
    jr c,.bad
    cp 'Z'+1
    jr c,.start_ok
    cp 'a'
    jr c,.bad
    cp 'z'+1
    jr nc,.bad
.start_ok:
    ld (V2_ARRAY_NAME_PTR),hl
    ld b,0
.scan:
    ld a,(hl)
    or a
    jr z,.done
    cp ' '
    jr z,.done
    cp '$'
    jr z,.dollar
    inc hl
    inc b
    jr .scan
.dollar:
    ld a,1
    ld (V2_ARRAY_IS_STR),a
.done:
    ld a,b
    or a
    jr z,.bad
    cp IDENT_MAX_LEN+1
    jr nc,.bad
    ld (V2_ARRAY_NAME_LEN),a
    or a
    ret
.bad:
    scf
    ret

V2_SAVE:
    ld a,(V2_REQUEST_TYPE)
    ld (STORAGE_REQUEST_TYPE),a
    or a
    jr z,.program
    ld de,(V2_PACKAGE_LEN)
    ld a,d
    or e
    jr z,.missing_package
    ld ix,EXTENSION_MODULE_BASE
    jr .call
.program:
    ld a,(V2_NAME_LEN)
    ld b,a
    ld de,(PROG_END)
    ld hl,PROG_AREA_START
    ex de,hl
    or a
    sbc hl,de
    ex de,hl
    ld hl,(V2_NAME_PTR)
    ld ix,PROG_AREA_START
.call:
    ld a,(V2_NAME_LEN)
    ld b,a
    ld hl,(V2_NAME_PTR)
    call STORAGE_SAVE
    ei
    ld hl,V2_MSG_SAVED
    jp V2_SHOW_MESSAGE
.missing_package:
    ld hl,V2_MSG_NO_PACKAGE
    jp V2_SHOW_MESSAGE

; ============================================================================
; Dynamic Data Phase 2 -- array persistence. SAVE "name" ARRAY arrname /
; LOAD "name" ARRAY arrname, reusing STORAGE_SAVE/STORAGE_LOAD's entire
; transport/checksum/retry machinery exactly as-is (same "write RAM
; verbatim" principle a saved program's own source text already uses).
; The array's own compile-time index/declared size come from ARRSYMTAB/
; STRARRSYMTAB -- the SAME real RAM the current program's own last
; compile left behind (COMPILER_INIT only resets it on the NEXT compile,
; not between a RUN finishing and a command typed afterward) -- reached
; here via the build/v2_crossbank.inc binding to rom/exrom_v2_compiler.
; asm's own ARRSYM_LOOKUP/STRARRSYM_LOOKUP, no new lookup logic
; duplicated. See docs/v2/R10_7_CAPABILITY_RESTORATION.md for the full
; design (stored object format, write-once LOAD policy).
; ============================================================================

; V2_SAVE_ARRAY -- entry: V2_NAME_PTR/LEN (tape filename) and V2_ARRAY_
; NAME_PTR/LEN/IS_STR (target array) already set by V2_PARSE_NAME/V2_
; SCAN_ARRAY_NAME.
V2_SAVE_ARRAY:
    ld a,(V2_ARRAY_IS_STR)
    or a
    jr nz,.string_array
    ld hl,(V2_ARRAY_NAME_PTR)
    ld a,(V2_ARRAY_NAME_LEN)
    ld b,a
    call ARRSYM_LOOKUP
    jr c,.not_dimd
    ld c,a
    ld h,0
    ld l,c
    add hl,hl
    ld de,(RT_ARRPTR_PTR)
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)             ; DE = descriptor address (0 = never DIM'd
                            ; this run, even though compile-time known)
    ld a,d
    or e
    jr z,.not_dimd
    push de                ; descriptor address, saved for IX below
    ld hl,(ARR_SIZE_TMP)
    add hl,hl               ; count*2
    ld de,ARR_DESC_DATA_OFF
    add hl,de                ; HL = total descriptor length
    jr .send
.string_array:
    ld hl,(V2_ARRAY_NAME_PTR)
    ld a,(V2_ARRAY_NAME_LEN)
    ld b,a
    call STRARRSYM_LOOKUP
    jr c,.not_dimd
    ld c,a
    ld h,0
    ld l,c
    add hl,hl
    ld de,(RT_STRARRPTR_PTR)
    add hl,de
    ld e,(hl)
    inc hl
    ld d,(hl)             ; DE = descriptor address
    ld a,d
    or e
    jr z,.not_dimd
    push de
    ld h,0
    ld a,(STRARR_WIDTH_TMP)
    ld l,a
    ld de,(STRARR_SIZE_TMP)
    call MATH_MULTIPLY16    ; HL = count*width
    ld de,STRARR_DESC_DATA_OFF
    add hl,de                ; HL = total descriptor length
.send:
    ex de,hl                ; DE = length
    pop ix                   ; IX = descriptor address
    ld hl,(V2_NAME_PTR)
    ld a,(V2_NAME_LEN)
    ld b,a
    ld a,STORAGE_ARRAY_TYPE
    ld (STORAGE_REQUEST_TYPE),a   ; D13
    call STORAGE_SAVE
    ei
    ld hl,V2_MSG_SAVED
    jp V2_SHOW_MESSAGE
.not_dimd:
    jp ARR_SAVE_STORE

; V2_VERIFY -- R10.25 class B item. VERIFY only ever applies to the
; program itself (stock BASIC has no "VERIFY package" concept), so this
; forces V2_REQUEST_TYPE=0 and reuses V2_LOAD's entire real name-parse/
; STORAGE_LOAD-call path unchanged; only STORAGE_VERIFY_MODE (consulted
; by STORAGE_LOAD's own data-block receive, and by V2_LOAD's own
; success/failure message branches above) distinguishes this from a
; real LOAD.
V2_VERIFY:
    xor a
    ld (V2_REQUEST_TYPE),a
    ld a,1
    ld (STORAGE_VERIFY_MODE),a
    jp V2_LOAD

V2_LOAD:
    ld a,(V2_REQUEST_TYPE)
    ld (STORAGE_REQUEST_TYPE),a
    or a
    jr z,.name
    ld a,(V2_NAME_LEN)
    or a
    jp z,.missing_name
.name:
    ld a,(V2_NAME_LEN)
    or a
    jr z,.wildcard
    ld b,a
    ld hl,(V2_NAME_PTR)
    call V2_PAD_NAME
    ld hl,STORAGE_LOAD_NAME_BUF
    ld b,10
    jr .receive
.wildcard:
    ld hl,(V2_NAME_PTR)
    ld b,0
.receive:
    ld a,(V2_REQUEST_TYPE)
    or a
    jr z,.program_receive
    call KTAB_EXT2_CLEAR_ALL
    ld hl,STORAGE_LOAD_NAME_BUF
    ld b,10
    ld de,EXTENSION_MODULE_LIMIT-EXTENSION_MODULE_BASE
    ld ix,EXTENSION_MODULE_BASE
    jr .load_call
.program_receive:
    ld de,V2_SOURCE_END-PROG_AREA_START
    ld ix,PROG_AREA_START
.load_call:
    call STORAGE_LOAD
    ei
    jr c,.failed
    ld a,(STORAGE_VERIFY_MODE)
    or a
    jp nz,.verified          ; VERIFY never touches PROG_END/VARS_START/
                               ; edit state -- V2_VERIFY already forced
                               ; V2_REQUEST_TYPE=0 (program-only), so the
                               ; package path below is never reached here
    ld a,(V2_REQUEST_TYPE)
    or a
    jr z,.program_loaded
    ld (V2_PACKAGE_LEN),de
    call EXTENSION_MODULE_BASE   ; R10.9: the ABI version word was already checked by
                                   ; STORAGE_LOAD against the header, before any byte of
                                   ; the package reached the window (docs/v2/PACKAGE_ABI.md s6)
    jr c,.invalid_package
    ld hl,V2_MSG_LOADED
    jp V2_SHOW_MESSAGE
.invalid_package:
    call KTAB_EXT2_CLEAR_ALL
    ld hl,0
    ld (V2_PACKAGE_LEN),hl
    ld hl,V2_MSG_LOAD_FAILED
    jp V2_SHOW_MESSAGE
.program_loaded:
    ld hl,PROG_AREA_START
    add hl,de
    ld (PROG_END),hl
    call V2_CLEAR_ARRAYS
    ld hl,V2_SOURCE_END
    ld (VARS_START),hl
    call V2_RESET_EDIT
    call V2_COUNT_LINES
    ld (CUR_EDIT_INDEX),de
    ld hl,V2_MSG_LOADED
    jp V2_SHOW_MESSAGE
.failed:
    ; R10.9 failure classes (STORAGE_LOAD: A = class, B = user-abort flag):
    ;   A=0        nothing was stored: program/package state untouched
    ;   A=$FF      destination was partly overwritten: the old program cannot be
    ;              trusted and cannot be restored (no staging buffer), so fall
    ;              into the known-safe empty state (same as NEW)
    ;   A=$FE      unsupported tape version: refused before any byte arrived
    ; STORAGE_LOAD never reports $FF in VERIFY mode, so VERIFY cannot wipe.
    push bc
    push af
    ld a,(V2_REQUEST_TYPE)
    or a
    jr z,.program_failed
    call KTAB_EXT2_CLEAR_ALL
    ld hl,0
    ld (V2_PACKAGE_LEN),hl
    pop af
    jr .classify
.program_failed:
    pop af
    cp STORAGE_LOAD_DATA_TOUCHED
    jr nz,.classify
    call MEM_INIT_V2
    call V2_RESET_EDIT
    xor a
.classify:
    pop bc
    cp STORAGE_LOAD_BAD_VERSION
    jr z,.bad_version
.clean_failure:                ; B = abort flag (0 when arriving from .verified)
    ld hl,V2_MSG_LOAD_FAILED
    ld a,(STORAGE_VERIFY_MODE)
    or a
    jr z,.pick_msg
    xor a
    ld (STORAGE_VERIFY_MODE),a
    ld hl,V2_MSG_VERIFY_FAILED
.pick_msg:
    ld a,b
    or a
    jr z,.show_msg
    ld hl,V2_MSG_ABORTED
.show_msg:
    jp V2_SHOW_MESSAGE
.missing_name:
    ld hl,V2_MSG_SYNTAX
    jp V2_SHOW_MESSAGE
.bad_version:                ; R10.9: header version word not ours; nothing was touched
    xor a
    ld (STORAGE_VERIFY_MODE),a
    ld hl,V2_MSG_BAD_VERSION
    jp V2_SHOW_MESSAGE
.verified:
    ; R10.9 (D2): the transport compared the first <tape length> bytes; the
    ; programs are only equal if the tape ALSO ends where the program does
    ; (DE = tape length).  A shorter or longer tape would otherwise verify
    ; against stale RAM or match a prefix.
    ld hl,PROG_AREA_START
    add hl,de
    ld de,(PROG_END)
    or a
    sbc hl,de
    jr nz,.clean_failure
    xor a
    ld (STORAGE_VERIFY_MODE),a
    ld hl,V2_MSG_VERIFIED
    jp V2_SHOW_MESSAGE

V2_LIST:
    call KTAB_GFX_CLS
    call KTAB_MEM_LINE_FIRST
    xor a
    ld (V2_DRAW_ROW),a
.loop:
    ld a,h
    or l
    jr z,.wait
    ld (V2_CMD_PTR),hl
    call V2_COPY_RECORD
    ld hl,DETOK_BUF
    call V2_KW_DETECT_SPANS
    ld a,1
    ld (V2_DRAW_BOLD_ENABLE),a
    ld hl,DETOK_BUF
    ld a,(V2_DRAW_ROW)
    ld b,a
    call V2_DRAW_TEXT
    ld a,(V2_DRAW_ROW)
    cp 23
    jr c,.next
    call KTAB_IO_READ_KEY
    call KTAB_GFX_CLS
    xor a
    ld (V2_DRAW_ROW),a
.next:
    ld hl,(V2_CMD_PTR)
    call KTAB_MEM_LINE_NEXT
    jr .loop
.wait:
    jp KTAB_IO_READ_KEY

V2_COPY_RECORD:
    inc hl
    inc hl
    ld de,DETOK_BUF
    ld b,127
.loop:
    ld a,(hl)
    cp $0D
    jr z,.end
    ld (de),a
    inc de
    inc hl
    djnz .loop
.end:
    xor a
    ld (de),a
    ret

; Draw a null-terminated line using the canonical editor's wrap table.
; B = starting physical row. V2_DRAW_ROW returns the next free row.
V2_DRAW_TEXT:
    ld (V2_DRAW_PTR),hl
    ld a,b
    ld (V2_DRAW_ROW),a
    call EDITOR_WRAP_CALC
    xor a
    ld (V2_DRAW_SUBROW),a
.row:
    ld a,(V2_DRAW_ROW)
    cp 23
    ret nc
    ld a,(EDIT_WRAP_COUNT)
    ld b,a
    ld a,(V2_DRAW_SUBROW)
    cp b
    ret nc
    ld e,a
    ld d,0
    ld hl,EDIT_WRAP_START
    add hl,de
    ld e,(hl)
    ld d,0
    ld hl,(V2_DRAW_PTR)
    add hl,de
    ld (V2_WORK_PTR),hl
    ld a,(V2_DRAW_SUBROW)
    ld e,a
    ld d,0
    ld hl,EDIT_WRAP_LEN
    add hl,de
    ld a,(hl)
    ld (V2_DRAW_LEN),a
    xor a
    ld (V2_DRAW_COL),a
.char:
    ld a,(V2_DRAW_COL)
    ld b,a
    ld a,(V2_DRAW_LEN)
    cp b
    jr z,.next_row
    ld hl,(V2_WORK_PTR)
    push hl
    ld de,(V2_DRAW_PTR)
    or a
    sbc hl,de                    ; HL = this char's absolute offset
                                    ; within the line (V2_WORK_PTR
                                    ; walks across sub-row wrap
                                    ; boundaries, V2_DRAW_PTR is the
                                    ; line's own fixed start)
    ld a,(V2_DRAW_BOLD_ENABLE)
    or a
    jr z,.plain_flag
    ld a,l
    call V2_KW_OFFSET_BOLD        ; carry set = this offset is inside
                                     ; a recorded keyword span
    jr .have_flag
.plain_flag:
    or a                           ; carry clear
.have_flag:
    pop hl
    ld a,(hl)
    ld e,a
    inc hl
    ld (V2_WORK_PTR),hl
    ld a,(V2_DRAW_ROW)
    ld b,a
    ld a,(V2_DRAW_COL)
    ld c,a
    ld a,e
    jr nc,.putchar_plain
    and $DF                       ; keyword span: display uppercase (the
                                    ; stored source keeps typed case)
    call KTAB_GFX_PUTCHAR_BOLD
    jr .char_done
.putchar_plain:
    call KTAB_GFX_PUTCHAR
.char_done:
    ld a,(V2_DRAW_COL)
    inc a
    ld (V2_DRAW_COL),a
    jr .char
.next_row:
    ld a,(V2_DRAW_ROW)
    inc a
    ld (V2_DRAW_ROW),a
    ld a,(V2_DRAW_SUBROW)
    inc a
    ld (V2_DRAW_SUBROW),a
    jp .row

; R10 keyword-bolding prototype -- V2-native replacement for V1's
; rom/exrom_highlight.asm (274 lines, EXROM-resident, never migrated to
; V2 production; its own rendering primitive GFX_PUTCHAR_BOLD DID
; survive, in kernel/graphics/graphics.asm, unlike its keyword-
; detection table-walk). Reuses the COMPILER's real KEYWORD_TABLE data
; (rom/exrom_v2_compiler.asm) with zero duplication, via the tiny
; KTAB_GET_KEYWORD_TABLE stub -- HOME is always visible regardless of
; EXROM's own paging state (kernel/bank/bank.asm: "Pages chunk 6
; ($C000-$DFFF) to EXROM. Every other chunk stays Home"), so this
; EXROM-resident scan lives entirely here and just reads HOME's table
; bytes directly once it has the real address, no bank-switch needed
; and no separate EXROM-local keyword-string copy required.
;
; Trigger matches V1's own established UX exactly: NOT live-as-you-
; type. Callers only invoke this for already-settled lines (V2_LIST,
; V2_REDRAW's .settled path) — the actively-edited row is always drawn
; plain (V2_DRAW_BOLD_ENABLE left at 0, no span detection performed).
;
; In: HL = null-terminated line text (uppercase BASIC source, matching
; KEYWORD_TABLE's own literal casing).
; Out: KW_SPAN_TABLE/KW_SPAN_COUNT populated (up to KW_SPAN_MAX entries,
; silently capped past that, same convention this project's other small
; bounded tables use). Destroys: AF, BC, DE, HL.
V2_KW_DETECT_SPANS:
    ld (V2_KW_LINE_BASE),hl
    xor a
    ld (KW_SPAN_COUNT),a
    call KTAB_GET_KEYWORD_TABLE     ; HL = real KEYWORD_TABLE address,
                                      ; A = KEYWORD_TABLE_COUNT
    ld (V2_KW_TABLE_BASE),hl
    ld (V2_KW_TABLE_COUNT),a
    ld hl,(V2_KW_LINE_BASE)
.scan:
    ld a,(hl)
    or a
    ret z
    cp '"'
    jr nz,.notquote
.string:
    inc hl                  ; string contents are never keywords
    ld a,(hl)
    or a
    ret z
    cp '"'
    jr nz,.string
    jp .advance
.notquote:
    and $DF             ; case-insensitivity: fold a copy for this A-Z
                         ; word-boundary test only -- (hl) itself (and
                         ; the span offsets recorded below) still point
                         ; at the real, as-typed source text
    cp 'A'
    jp c,.advance
    cp 'Z'+1
    jp nc,.advance
    ld (V2_KW_WORD_START),hl
.wordlen:
    inc hl
    ld a,(hl)
    cp '$'
    jr nz,.not_dollar
    inc hl                  ; string identifier suffix ("To$"): part of
    jr .wordlen_done        ; the word, so it can never equal a keyword
.not_dollar:
    cp '0'
    jr c,.wordlen_done
    cp '9'+1
    jr c,.wordlen           ; digits continue an identifier ("To1")
    and $DF
    cp 'A'
    jr c,.wordlen_done
    cp 'Z'+1
    jr c,.wordlen
.wordlen_done:
    ld (V2_KW_SCAN_RESUME),hl        ; one past the word's last char
    ld de,(V2_KW_WORD_START)
    or a
    sbc hl,de                         ; HL = word length
    ld a,l
    ld (V2_KW_WORD_LEN),a
    ld hl,(V2_KW_TABLE_BASE)
    ld a,(V2_KW_TABLE_COUNT)
    ld c,a
.try_entry:
    ld a,c
    or a
    jr z,.word_done                    ; exhausted the table, no match
    dec c
    ld a,(hl)                            ; this entry's own length byte
    inc hl                                ; HL -> entry text start
    ld b,a                                ; B = entry length (also the
                                            ; skip-forward distance on a
                                            ; length mismatch)
    ld a,(V2_KW_WORD_LEN)
    cp b
    jr nz,.skip_content
    push hl                                ; HL = entry text start
    ld de,(V2_KW_WORD_START)
.cmp:
    ld a,b
    or a
    jr z,.cmp_match
    ld a,(de)
    and $DF             ; case-insensitivity: KEYWORD_TABLE's own text is
                         ; always uppercase; fold the as-typed word's copy
                         ; to match without touching the source itself
    cp (hl)
    jr nz,.cmp_fail
    inc hl
    inc de
    dec b
    jr .cmp
.cmp_match:
    ld a,(hl)                               ; HL = matched token byte
    ld (V2_KW_TMP_OFFSET),a
    pop hl                                  ; discard the saved entry-
                                              ; text pointer (not needed
                                              ; again — we matched)
    jr .record_span
.cmp_fail:
    pop hl                                   ; HL = entry text start
                                               ; again (unadvanced)
    ld a,(V2_KW_WORD_LEN)
    ld b,a                                     ; B = entry length again
                                                 ; (equals word length,
                                                 ; that's why we compared)
.skip_content:
    ld a,b
    ld de,0
    ld e,a
    add hl,de                                   ; HL -> this entry's own
                                                  ; token byte
    inc hl                                        ; HL -> next entry's
                                                    ; own length byte
    jr .try_entry
.record_span:
    ld a,(KW_SPAN_COUNT)
    cp KW_SPAN_MAX
    jr nc,.word_done                              ; already full
    ld hl,KW_SPAN_TABLE
    ld d,0
    ld e,a
    add hl,de
    add hl,de                                      ; HL -> this span's
                                                      ; own [start][len]
                                                      ; pair (2 bytes/
                                                      ; entry)
    ld de,(V2_KW_WORD_START)
    ld bc,(V2_KW_LINE_BASE)
    push hl
    ex de,hl
    or a
    sbc hl,bc                                        ; HL = offset =
                                                        ; word_start -
                                                        ; line_base
    ld a,l
    pop hl
    ld (hl),a
    inc hl
    ld a,(V2_KW_WORD_LEN)
    ld (hl),a
    ld a,(KW_SPAN_COUNT)
    inc a
    ld (KW_SPAN_COUNT),a
    ld a,(V2_KW_TMP_OFFSET)
    cp TOK_KW_REM
    ret z                                          ; comment text follows
.word_done:
    ld hl,(V2_KW_SCAN_RESUME)
    jp .scan
.advance:
    inc hl
    jp .scan

; V2_KW_OFFSET_BOLD -- in: A = a character's absolute offset within the
; line V2_KW_DETECT_SPANS was last called on. Out: carry set if that
; offset falls inside a recorded [start,start+len) span. Destroys: AF,
; BC, HL.
V2_KW_OFFSET_BOLD:
    ld b,a
    ld a,(KW_SPAN_COUNT)
    or a
    ret z
    ld c,a
    ld hl,KW_SPAN_TABLE
.loop:
    ld a,b
    sub (hl)                              ; A = offset - start; carry
                                            ; set if offset < start
    jr c,.miss
    inc hl
    cp (hl)                                 ; (offset-start) vs len
    jr c,.hit                                ; in range -> bold
    jr .miss_after_len
.miss:
    inc hl
.miss_after_len:
    inc hl
    dec c
    jr nz,.loop
    or a
    ret
.hit:
    scf
    ret

; The editor hook redraws the authoritative source view.
V2_REDRAW:
    ld a,(V2_REDRAW_SCOPE)       ; STUDY (flicker): typing/backspace only changed the active line
    or a
    jr z,.full
    ld b,a
    xor a
    ld (V2_REDRAW_SCOPE),a
    dec b
    jr nz,.nav
    call V2_REDRAW_ACTIVE
    ret nc                       ; done, carry clear
    jr .full
.nav:
    call V2_REDRAW_NAV
    ret nc
.full:
    call KTAB_GFX_CLS
    ld a,22
    ld (V2_ACTIVE_ROW),a
    call V2_COUNT_LINES
    ld (V2_LINE_COUNT),de   ; R10: was already computed here and
                              ; discarded every redraw; now cached for
                              ; V2_DRAW_STATUS below, no extra traversal
    ld hl,(CUR_EDIT_INDEX)
    ld a,h
    or a
    jr nz,.scroll
    ld a,l
    cp 20
    jr c,.top
.scroll:
    ld de,20
    or a
    sbc hl,de
    jr .view_ready
.top:
    ld hl,0
.view_ready:
    ld (VIEW_TOP_INDEX),hl
    ex de,hl
    call V2_FIND_INDEX
    xor a
    ld (V2_DRAW_ROW),a
.record:
    ld a,h
    or l
    jr z,.sentinel
    ld (V2_CMD_PTR),hl
    ld de,(CUR_EDIT_POS)
    or a
    sbc hl,de
    ld hl,(V2_CMD_PTR)
    jr nz,.settled
    ld a,(V2_DRAW_ROW)
    ld (V2_ACTIVE_ROW),a
    xor a
    ld (V2_DRAW_BOLD_ENABLE),a    ; the actively-edited row is always
                                    ; drawn plain, matching V1's own
                                    ; established UX (see V2_KW_DETECT_
                                    ; SPANS's own header)
    ld hl,EDIT_LINE_BUF
    jr .draw
.settled:
    call V2_COPY_RECORD
    ld hl,DETOK_BUF
    call V2_KW_DETECT_SPANS
    ld a,1
    ld (V2_DRAW_BOLD_ENABLE),a
    ld hl,DETOK_BUF
.draw:
    ld a,(V2_DRAW_ROW)
    ld b,a
    call V2_DRAW_TEXT
    ld hl,(V2_CMD_PTR)
    call KTAB_MEM_LINE_NEXT
    ld a,(V2_DRAW_ROW)
    cp 23
    jr c,.record
    jr .cursor
.sentinel:
    ld hl,(CUR_EDIT_POS)
    ld a,h
    cp $FF
    jr nz,.cursor
    ld a,(V2_DRAW_ROW)
    ld (V2_ACTIVE_ROW),a
    xor a
    ld (V2_DRAW_BOLD_ENABLE),a
    ld hl,EDIT_LINE_BUF
    ld a,(V2_DRAW_ROW)
    ld b,a
    call V2_DRAW_TEXT
.cursor:
    call V2_DRAW_STATUS      ; R10: status/line-position indicator,
                               ; row 23 -- runs on every redraw,
                               ; regardless of which exit path below
                               ; this block takes
    ld hl,EDIT_LINE_BUF
    call EDITOR_WRAP_CALC
    ld a,(EDIT_WRAP_COUNT)       ; STUDY: remembered for the selective paths' geometry checks
    ld (V2_RD_WRAPS),a
    ld hl,(CUR_EDIT_INDEX)
    ld (V2_RD_INDEX),hl
    call EDITOR_WRAP_OFFSET_TO_ROWCOL
    ld a,(V2_ACTIVE_ROW)
    add a,b
    cp 23
    ret nc
    ld b,a
    jp KTAB_GFX_INVERT_ATTR

; ---- STUDY (flicker, audit I1/I2): selective redraw -------------------------------------------------
; Cache kept by every redraw: V2_ACTIVE_ROW (first row of the active line), V2_RD_WRAPS (its row count),
; V2_RD_INDEX (its index).  The editor sets V2_REDRAW_SCOPE: 1 = text of the active line changed (typing,
; backspace); 2 = UP/DOWN.  Each selective routine checks the geometry itself and returns carry SET when it
; cannot prove that nothing else on the screen moves -> V2_REDRAW then does the full redraw.

; In: A = first row, C = number of rows.  Clears each row < 23 (bitmap) and restores the text attribute
; $38 (this also removes the inverted cursor cell).  Destroys AF BC DE HL.
V2_RD_CLEAR_ROWS:
.row:
    cp 23
    ret nc
    push af
    push bc
    ld b,a
    call KTAB_GFX_CLEAR_ROW_TEXT
    pop bc
    pop af
    push af
    push bc
    ld l,a
    ld h,0
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl
    add hl,hl                    ; row * 32
    ld de,ATTR_ADDR
    add hl,de
    ld d,h
    ld e,l
    inc de
    ld (hl),%00111000
    ld bc,31
    ldir
    pop bc
    pop af
    inc a
    dec c
    jr nz,.row
    ret

; Draw EDIT_LINE_BUF plain at V2_ACTIVE_ROW and put the cursor on it.  Out: carry clear.
V2_RD_DRAW_ACTIVE:
    xor a
    ld (V2_DRAW_BOLD_ENABLE),a   ; the active row is always drawn plain
    ld hl,EDIT_LINE_BUF
    ld a,(V2_ACTIVE_ROW)
    ld b,a
    call V2_DRAW_TEXT
    ld hl,(CUR_EDIT_INDEX)
    ld (V2_RD_INDEX),hl
    call V2_RD_CURSOR
    or a
    ret

; Cursor cell of the active line (inverted attribute), if it is on screen.
V2_RD_CURSOR:
    ld hl,EDIT_LINE_BUF
    call EDITOR_WRAP_CALC
    call EDITOR_WRAP_OFFSET_TO_ROWCOL
    ld a,(V2_ACTIVE_ROW)
    add a,b
    cp 23
    ret nc
    ld b,a
    jp KTAB_GFX_INVERT_ATTR

; Typing / backspace: same record, same view, same row count -> redo only the active line's rows.
V2_REDRAW_ACTIVE:
    ld hl,EDIT_LINE_BUF
    call EDITOR_WRAP_CALC
    ld a,(EDIT_WRAP_COUNT)
    ld hl,V2_RD_WRAPS
    cp (hl)
    scf
    ret nz                       ; the rows below would move
.redo_active:
    ld c,a
    ld a,(V2_ACTIVE_ROW)
    call V2_RD_CLEAR_ROWS
    jr V2_RD_DRAW_ACTIVE

; UP/DOWN.  (a) same record (cursor moved between wrapped rows): the cursor only.  (b) the neighbouring
; record while both indices are <= 20 (the view top stays 0) and neither line changes height: redraw the
; old line as a settled (keyword-bold) line, the new one as the active line, the status, the cursor.
V2_REDRAW_NAV:
    ld hl,(CUR_EDIT_INDEX)
    ld de,(V2_RD_INDEX)
    or a
    sbc hl,de                    ; HL = new - old
    jr nz,.moved
    ld a,(V2_RD_WRAPS)           ; (a): the cursor only
    jr V2_REDRAW_ACTIVE.redo_active   ; (rows are redone too: text unchanged, so the identical picture)
.moved:
    ld b,0                       ; B = 0 for DOWN, 1 for UP
    dec hl
    ld a,h
    or l
    jr z,.dir
    inc hl
    inc hl                       ; HL = new - old + 1
    ld a,h
    or l
    jp nz,.full
    inc b
.dir:
    ld hl,(CUR_EDIT_INDEX)
    ld de,21
    or a
    sbc hl,de
    jp nc,.full                  ; new index > 20: the view may scroll
    ld hl,(V2_RD_INDEX)
    ld de,21
    or a
    sbc hl,de
    jp nc,.full
    push bc                      ; B = direction
    ld de,(V2_RD_INDEX)
    call V2_FIND_INDEX           ; HL = the OLD record, or $FFFF = it was the append line
    ld (V2_CMD_PTR),hl
    ld a,h
    and l
    inc a
    jr z,.old_blank
    call V2_COPY_RECORD          ; DETOK_BUF = its text
    ld hl,DETOK_BUF
    call EDITOR_WRAP_CALC
    ld a,(EDIT_WRAP_COUNT)
    ld hl,V2_RD_WRAPS
    cp (hl)
    jp nz,.full_pop              ; the old line is not drawn the way the record would be
.old_blank:
    ld hl,EDIT_LINE_BUF
    call EDITOR_WRAP_CALC        ; the NEW line's height
    ld a,(EDIT_WRAP_COUNT)
    ld (V2_RD_NEWH),a
    pop bc
    ld a,(V2_ACTIVE_ROW)
    dec b
    jr z,.up
    ld hl,V2_RD_WRAPS            ; DOWN: new row = old row + old height
    add a,(hl)
    cp 23
    jp nc,.full
    jr .rows
.up:
    ld hl,V2_RD_NEWH             ; UP: new row = old row - new height
    sub (hl)
    jp c,.full
.rows:
    ld (V2_RD_NEWROW),a
    ld a,(V2_ACTIVE_ROW)         ; the old line: clear its rows, redraw it settled
    ld hl,V2_RD_WRAPS
    ld c,(hl)
    call V2_RD_CLEAR_ROWS
    ld hl,(V2_CMD_PTR)
    ld a,h
    and l
    inc a
    jr z,.new                    ; the old line was the empty append line: nothing to draw
    ld hl,DETOK_BUF              ; (a record: DETOK_BUF still holds its text)
    call V2_KW_DETECT_SPANS
    ld a,1
    ld (V2_DRAW_BOLD_ENABLE),a
    ld hl,DETOK_BUF
    ld a,(V2_ACTIVE_ROW)
    ld b,a
    call V2_DRAW_TEXT
.new:
    ld a,(V2_RD_NEWROW)
    ld (V2_ACTIVE_ROW),a
    ld a,(V2_RD_NEWH)
    ld (V2_RD_WRAPS),a
    ld c,a
    ld a,(V2_ACTIVE_ROW)
    call V2_RD_CLEAR_ROWS
    call V2_DRAW_STATUS          ; "LINE n/m": n changed (m cannot: UP/DOWN do not add or remove lines)
    jp V2_RD_DRAW_ACTIVE
.full_pop:
    pop bc
.full:
    scf
    ret

; V2_DRAW_STATUS -- R10 addition. Composes "LINE n/m" (n = 1-based
; cursor line position, m = total line count) into V2_STATUS_BUF and
; draws it on row 23, the one row V2_REDRAW's own main draw loop never
; writes to (it stops at row 22 -- `cp 23` above/in the main loop). Same
; row V1's own BASIC_DRAW_STATUS_LINE reserved, but computed fresh from
; V2's own generic line-store state (CUR_EDIT_INDEX/V2_LINE_COUNT), not
; restored V1 position-addressed tracking.
V2_DRAW_STATUS:
    ld hl,V2_STATUS_PREFIX
    ld de,V2_STATUS_BUF
    call V2_STATUS_APPEND
    push de
    ld hl,(CUR_EDIT_INDEX)
    inc hl                    ; n = CUR_EDIT_INDEX + 1 (1-based)
    ex de,hl
    call BASIC_NUM_TO_STRING_EXROM  ; HL -> formatted n text
    pop de
    call V2_STATUS_APPEND
    ld a,'/'
    ld (de),a
    inc de
    push de
    ld hl,(V2_LINE_COUNT)
    ex de,hl
    call BASIC_NUM_TO_STRING_EXROM  ; HL -> formatted m text
    pop de
    call V2_STATUS_APPEND
    xor a
    ld (de),a
    ld b,23
    call KTAB_GFX_CLEAR_ROW_TEXT    ; R10.7: bitmap-only clear -- leaves
                                      ; the status-bar attribute (set by
                                      ; V2_STATUS_SET_BAR_ATTR below) in
                                      ; place instead of resetting it to
                                      ; ATTR_DEFAULT and back, same anti-
                                      ; flicker reasoning as GFX_CLEAR_
                                      ; ROW_TEXT's own header
    ld hl,V2_STATUS_BUF
    ld b,23
    ld c,0
    call KTAB_GFX_PRINT_STRING
    jp V2_STATUS_SET_BAR_ATTR

; Copies a null-terminated string at (hl) into (de), advancing de past
; the copied bytes (not including the terminator -- callers append
; several pieces in sequence and write one final null themselves).
V2_STATUS_APPEND:
    ld a,(hl)
    or a
    ret z
    ld (de),a
    inc hl
    inc de
    jr V2_STATUS_APPEND

V2_STATUS_PREFIX: DB "LINE ",0

; Local aliases for kernel/graphics/graphics.asm's own canonical attribute
; constants (ATTR_STATUS_BAR = $07, ATTR_SWATCH_RED/_GREEN/_BLUE) -- EXROM
; doesn't INCLUDE graphics.asm (only Home does), so these values aren't
; otherwise visible here. EQUs, not data -- zero byte cost, and values are
; cross-checked against graphics.asm's own comments (PAPER/INK bit layout)
; rather than re-derived.
V2_ATTR_STATUS_BAR   EQU $07   ; PAPER 0 (black), INK 7 (white)
V2_ATTR_SWATCH_RED   EQU $10   ; PAPER 2 (red),   INK 0
V2_ATTR_SWATCH_GREEN EQU $20   ; PAPER 4 (green), INK 0
V2_ATTR_SWATCH_BLUE  EQU $08   ; PAPER 1 (blue),  INK 0

; ============================================================================
; V2_STATUS_SET_BAR_ATTR -- R10.7: restores V1's persistent black/white
; inverse status-bar treatment plus the three-cell RGB branding swatch
; (echoing the real TS2068's "PERSONAL COLOR COMPUTER" logo) on top of
; V2's own existing status/message routing (V2_DRAW_STATUS/V2_SHOW_
; MESSAGE), per docs/v2/R10_7_UX_PARITY_INVESTIGATION.md's Option C.
;
; RGB design note (per that investigation's own preference order): a
; single character cell has exactly ONE attribute byte -- PAPER and INK,
; two colors total, confirmed from GFX_SET_ATTR/GFX_ATTR_SWAP's own bit
; layout (kernel/graphics/graphics.asm) -- not three independent colors,
; so a one-cell three-line red/green/blue mark is not something standard
; TS2068 attribute hardware can show at all, cheaply or otherwise. A
; thin-line multi-cell version would still need new font glyph bitmap
; data (FONT_TABLE growth) for no functional gain over the original
; design, which needs none -- V1's three solid-color blocks (PAPER-only
; cells, applied to blank space characters already drawn by GFX_PUTCHAR/
; GFX_CLEAR_ROW_TEXT) are already the cheapest option and are what's
; restored here, unchanged, still columns 29-31, never more.
;
; Called from both V2_DRAW_STATUS and V2_SHOW_MESSAGE, always AFTER
; their own GFX_CLEAR_ROW_TEXT (bitmap-only) + GFX_PRINT_STRING -- never
; GFX_CLEAR_ROW, which would reset the attribute back to ATTR_DEFAULT
; first, same anti-flicker ordering V1's own BASIC_PRINT_STATUS_TEXT
; used. Idempotent and cheap enough to call unconditionally every time
; rather than tracking whether it's already set.
; In: none  Out: none  Destroys: AF, BC
; ============================================================================
V2_STATUS_SET_BAR_ATTR:
    ld   c, 0
.bar_loop:
    push bc
    ld   a, V2_ATTR_STATUS_BAR
    ld   b, 23
    call KTAB_GFX_SET_ATTR
    pop  bc
    inc  c
    ld   a, c
    cp   29
    jr   c, .bar_loop
    push bc
    ld   a, V2_ATTR_SWATCH_RED
    ld   b, 23
    call KTAB_GFX_SET_ATTR
    pop  bc
    inc  c
    push bc
    ld   a, V2_ATTR_SWATCH_GREEN
    ld   b, 23
    call KTAB_GFX_SET_ATTR
    pop  bc
    inc  c
    ld   a, V2_ATTR_SWATCH_BLUE
    ld   b, 23
    jp   KTAB_GFX_SET_ATTR

; R10 correction: previously cleared the WHOLE screen before showing an
; error/status message, hiding the program view (compile-time errors)
; or the program's own PRINT output (runtime errors) -- a regression
; behind V1's own already-superseded full-screen design (V1's own
; status-line comment records it moved away from exactly this after
; direct user feedback: "you need to see the whole program AND the
; current error at the same time"). Now clears and prints only row 23
; (GFX_CLEAR_ROW, already KTAB-wired, no new cross-bank plumbing),
; leaving the surrounding view intact -- the SAME row 23 V2_DRAW_STATUS
; above uses, since V2_REDRAW's next call naturally redraws the status
; line back over a dismissed message; no separate arbitration needed.
V2_SHOW_MESSAGE:
    push hl
    ld b,23
    call KTAB_GFX_CLEAR_ROW_TEXT    ; R10.7: bitmap-only, same reasoning
                                      ; as V2_DRAW_STATUS's own comment --
                                      ; preserves the status-bar attribute
                                      ; instead of flashing back to
                                      ; ATTR_DEFAULT first
    pop hl
    ld b,23
    ld c,0
    call KTAB_GFX_PRINT_STRING
    call V2_STATUS_SET_BAR_ATTR      ; idempotent -- also covers the case
                                      ; a message is shown before any
                                      ; V2_DRAW_STATUS call has set it
    jp KTAB_IO_READ_KEY

V2_KW_RUN: DB "RUN",0
V2_KW_LIST: DB "LIST",0
V2_KW_NEW: DB "NEW",0
V2_KW_SAVE: DB "SAVE",0
V2_KW_LOAD: DB "LOAD",0
V2_KW_VERIFY: DB "VERIFY",0
V2_KW_EXT: DB "EXT",0
V2_KW_ARRAY: DB "ARRAY",0
V2_MSG_SYNTAX: DB "SYNTAX ERROR",0
V2_MSG_RUNTIME: DB "RUNTIME ERROR",0
V2_MSG_FULL: DB "PROGRAM FULL",0
V2_MSG_NOMEM: DB "OUT OF MEMORY",0
V2_MSG_STACK: DB "STACK OVERFLOW",0
V2_MSG_NAMELEN: DB "NAME TOO LONG",0
V2_MSG_NEST: DB "NESTING TOO DEEP",0
V2_MSG_UNEXPECTED: DB "UNEXPECTED TOKEN",0
V2_MSG_TOOMANY: DB "TOO MANY VARIABLES",0
V2_MSG_SAVED: DB "SAVED",0
V2_MSG_LOADED: DB "LOADED",0
V2_MSG_LOAD_FAILED: DB "LOAD FAILED",0
V2_MSG_NO_PACKAGE: DB "NO PACKAGE",0
V2_MSG_ARRAY_NOT_DIMD: DB "ARRAY NOT DIMD",0
V2_MSG_STORE_FULL: DB "ARRAY STORE FULL",0
V2_MSG_BAD_ARRAY: DB "BAD ARRAY TAPE",0
V2_MSG_ARRAY_SHAPE: DB "ARRAY SIZE MISMATCH",0
V2_MSG_VERIFIED: DB "VERIFIED",0
V2_MSG_VERIFY_FAILED: DB "VERIFY FAILED",0
V2_MSG_BAD_VERSION: DB "BAD TAPE VERSION",0
V2_MSG_ABORTED: DB "ABORTED",0

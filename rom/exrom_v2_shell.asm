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
V2_PACKAGE_ABI_VERSION EQU 1
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
    call V2_TOKENIZE
    ld hl,(CUR_EDIT_POS)
    ld a,h
    cp $FF
    jr nz,.have_pos
    ld hl,(PROG_END)
.have_pos:
    ld de,TOKEN_BUF
    call KTAB_MEM_LINE_STORE
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

V2_SET_EDIT_FROM_INDEX:
    ld de,(CUR_EDIT_INDEX)
    call V2_FIND_INDEX
    ld a,h
    or l
    jr nz,.found
    ld hl,$FFFF
.found:
    ld (CUR_EDIT_POS),hl
    jp V2_LOAD_EDIT

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

; Each stored line becomes one CR-separated segment in compiler input.
; A 4096-byte stored program always produces less than 4096 staged bytes.
V2_BUILD_SOURCE:
    call KTAB_MEM_LINE_FIRST
    ld de,V2_SOURCE_STAGE
.next:
    ld a,h
    or l
    jr z,.done
    push hl
    inc hl
    inc hl
.copy:
    ld a,(hl)
    cp $0D
    jr z,.end_line
    ld (de),a
    inc de
    inc hl
    jr .copy
.end_line:
    ; A trailing colon already separates the next statement. Suppress the
    ; extra CR in that case, including for a label definition on its own
    ; source line. REM still consumes through the next actual line ending.
    ld a,e
    cp LOW V2_SOURCE_STAGE
    jr nz,.check_last
    ld a,d
    cp HIGH V2_SOURCE_STAGE
    jr z,.append_cr
.check_last:
    dec de
    ld a,(de)
    inc de
    cp ':'
    jr z,.next_record
.append_cr:
    ld a,$0D
    ld (de),a
    inc de
.next_record:
    pop hl
    push de
    call KTAB_MEM_LINE_NEXT
    pop de
    ld a,h
    or l
    jr z,.done
    jr .next
.done:
    xor a
    ld (de),a
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
; Input: SRC_PTR = wherever the just-failed COMPILE_PROGRAM's own
; lexer stopped (V2_SOURCE_STAGE-relative). This is close to, not
; always exactly at, the real failing token -- most of the compiler's
; own "ld a,(COMPILE_ERROR_CODE) / or a / jp nz,<bail>" sites unwind
; without a further LEX_NEXT_TOKEN call once the error is set, so
; SRC_PTR is left at or just past the real error -- the same kind of
; imprecision any line-based error system has, and good enough for
; "return to the vicinity of the error," which is this routine's own
; whole job.
;
; Mechanism: re-walks the line store with the SAME copy-length shape
; V2_BUILD_SOURCE already uses, counting staged bytes until the running
; total reaches SRC_PTR's own offset from V2_SOURCE_STAGE. Deliberately
; NOT shared code with V2_BUILD_SOURCE (kept as one small, self-
; contained routine instead) so a future multi-error redesign can
; replace just this one routine without touching the staging-buffer
; builder -- per this milestone's own instruction to keep the
; implementation cleanly separable. One real simplification versus
; V2_BUILD_SOURCE's own exact logic: this routine always counts a
; line's own separator as 1 byte, even on the trailing-colon case where
; V2_BUILD_SOURCE itself suppresses the extra CR -- a deliberate,
; disclosed approximation (occasionally off by one stored line for
; colon-joined continuations), not a bug, since exact recompilation-
; equivalent accounting isn't needed for a best-effort jump.
;
; Sets CUR_EDIT_INDEX/CUR_EDIT_POS to the located line via
; V2_SET_EDIT_FROM_INDEX -- the same mechanism arrow-key navigation
; already uses. V2_REDRAW's own existing VIEW_TOP_INDEX auto-scroll
; (see its own header) then brings the line into view on the very next
; redraw; no separate scrolling logic is needed here.
;
; If SRC_PTR's own offset runs past the last stored line (a real,
; if unusual, possibility -- e.g. an error reported at the implicit
; end-of-program), CUR_EDIT_INDEX is simply left at the last index it
; reached (the final line), not some undefined value.
; Destroys: AF, DE, HL.
V2_JUMP_TO_ERROR_LINE:
    ld hl,(SRC_PTR)
    ld de,V2_SOURCE_STAGE
    or a
    sbc hl,de
    ld (V2_ERR_TARGET_OFS),hl
    ld hl,0
    ld (V2_ERR_RUN_COUNT),hl
    ld (CUR_EDIT_INDEX),hl
    call KTAB_MEM_LINE_FIRST
.next:
    ld a,h
    or l
    jr z,.done
    push hl
    inc hl
    inc hl
.measure:
    ld a,(hl)
    cp $0D
    jr z,.measured
    inc hl
    ld de,(V2_ERR_RUN_COUNT)
    inc de
    ld (V2_ERR_RUN_COUNT),de
    jr .measure
.measured:
    ld hl,(V2_ERR_TARGET_OFS)
    ld de,(V2_ERR_RUN_COUNT)
    or a
    sbc hl,de
    jr c,.found              ; target < running count -> this line
    jr z,.found               ; target == running count -> this line
    ld hl,(V2_ERR_RUN_COUNT)
    inc hl                     ; account for the line's own separator
    ld (V2_ERR_RUN_COUNT),hl
    pop hl                      ; restore current record pointer
    call KTAB_MEM_LINE_NEXT
    ld a,h
    or l
    jr z,.done
    push hl
    ld hl,(CUR_EDIT_INDEX)
    inc hl
    ld (CUR_EDIT_INDEX),hl
    pop hl
    jr .next
.found:
    pop hl                     ; balance .next's own push hl
.done:
    jp V2_SET_EDIT_FROM_INDEX

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
    ld hl,V2_MSG_SYNTAX
    jp V2_SHOW_MESSAGE
.compiled:
    call KTAB_VM_INIT
    ld hl,VM_CODE_BASE
    ld (VM_IP),hl
    call KTAB_GFX_CLS
    call KTAB_VM_RUN
    ld a,(VM_ERROR_CODE)
    or a
    jr z,.finished
    ld hl,V2_MSG_RUNTIME
    jp V2_SHOW_MESSAGE
.finished:
    jp KTAB_IO_READ_KEY

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
    call V2_LOAD
    or a
    ret
.not_load:
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
MEM_INIT_V2:
    ld hl,PROG_AREA_START
    ld (PROG_END),hl
    ld (ARRAYS_END),hl
    ld hl,V2_SOURCE_END
    ld (VARS_START),hl
    call KTAB_EXT2_CLEAR_ALL
    ld hl,0
    ld (V2_PACKAGE_LEN),hl
    ret

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
    jr c,.bad
    ld a,STORAGE_EXTENSION_TYPE
    ld (V2_REQUEST_TYPE),a
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
    ld de,STORAGE_LOAD_NAME_BUF
    ld c,10
.pad:
    ld a,b
    or a
    jr z,.space
    ld a,(hl)
    inc hl
    dec b
    jr .write
.space:
    ld a,' '
.write:
    ld (de),a
    inc de
    dec c
    jr nz,.pad
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
    ld a,(V2_REQUEST_TYPE)
    or a
    jr z,.program_loaded
    ld (V2_PACKAGE_LEN),de
    ld hl,(STORAGE_HEADER_BUF+STORAGE_HEADER_AUTOSTART_OFF)
    ld a,h
    or a
    jr nz,.invalid_package
    ld a,l
    cp V2_PACKAGE_ABI_VERSION
    jr nz,.invalid_package
    call EXTENSION_MODULE_BASE
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
    ld hl,V2_SOURCE_END
    ld (VARS_START),hl
    call V2_RESET_EDIT
    call V2_COUNT_LINES
    ld (CUR_EDIT_INDEX),de
    ld hl,V2_MSG_LOADED
    jp V2_SHOW_MESSAGE
.failed:
    push af
    ld a,(V2_REQUEST_TYPE)
    or a
    jr z,.program_failed
    call KTAB_EXT2_CLEAR_ALL
    ld hl,0
    ld (V2_PACKAGE_LEN),hl
    pop af
    jr .clean_failure
.program_failed:
    pop af
    inc a
    jr nz,.clean_failure
    call MEM_INIT_V2
    call V2_RESET_EDIT
.clean_failure:
    ld hl,V2_MSG_LOAD_FAILED
    jp V2_SHOW_MESSAGE
.missing_name:
    ld hl,V2_MSG_SYNTAX
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
    cp 'A'
    jp c,.advance
    cp 'Z'+1
    jp nc,.advance
    ld (V2_KW_WORD_START),hl
.wordlen:
    inc hl
    ld a,(hl)
    cp 'A'
    jr c,.wordlen_done
    cp 'Z'+1
    jr c,.wordlen
.wordlen_done:
    ld (V2_KW_SCAN_RESUME),hl        ; one past the word's last letter
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
    cp (hl)
    jr nz,.cmp_fail
    inc hl
    inc de
    dec b
    jr .cmp
.cmp_match:
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
    call EDITOR_WRAP_OFFSET_TO_ROWCOL
    ld a,(V2_ACTIVE_ROW)
    add a,b
    cp 23
    ret nc
    ld b,a
    jp KTAB_GFX_INVERT_ATTR

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
    call KTAB_GFX_CLEAR_ROW
    ld hl,V2_STATUS_BUF
    ld b,23
    ld c,0
    jp KTAB_GFX_PRINT_STRING

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
    call KTAB_GFX_CLEAR_ROW
    pop hl
    ld b,23
    ld c,0
    call KTAB_GFX_PRINT_STRING
    jp KTAB_IO_READ_KEY

V2_KW_RUN: DB "RUN",0
V2_KW_LIST: DB "LIST",0
V2_KW_NEW: DB "NEW",0
V2_KW_SAVE: DB "SAVE",0
V2_KW_LOAD: DB "LOAD",0
V2_KW_EXT: DB "EXT",0
V2_MSG_SYNTAX: DB "SYNTAX ERROR",0
V2_MSG_RUNTIME: DB "RUNTIME ERROR",0
V2_MSG_FULL: DB "PROGRAM FULL",0
V2_MSG_SAVED: DB "SAVED",0
V2_MSG_LOADED: DB "LOADED",0
V2_MSG_LOAD_FAILED: DB "LOAD FAILED",0
V2_MSG_NO_PACKAGE: DB "NO PACKAGE",0

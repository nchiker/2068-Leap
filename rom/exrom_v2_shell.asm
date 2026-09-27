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

V2_RUN_STORED:
    call V2_BUILD_SOURCE
    ld hl,V2_SOURCE_STAGE
    jr V2_COMPILE_RUN
V2_RUN_IMMEDIATE:
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
    ld a,(hl)
    ld e,a
    inc hl
    ld (V2_WORK_PTR),hl
    ld a,(V2_DRAW_ROW)
    ld b,a
    ld a,(V2_DRAW_COL)
    ld c,a
    ld a,e
    call KTAB_GFX_PUTCHAR
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
    jr .row

; The editor hook redraws the authoritative source view.
V2_REDRAW:
    call KTAB_GFX_CLS
    ld a,22
    ld (V2_ACTIVE_ROW),a
    call V2_COUNT_LINES
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
    ld hl,EDIT_LINE_BUF
    jr .draw
.settled:
    call V2_COPY_RECORD
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
    ld hl,EDIT_LINE_BUF
    ld a,(V2_DRAW_ROW)
    ld b,a
    call V2_DRAW_TEXT
.cursor:
    ld hl,EDIT_LINE_BUF
    call EDITOR_WRAP_CALC
    call EDITOR_WRAP_OFFSET_TO_ROWCOL
    ld a,(V2_ACTIVE_ROW)
    add a,b
    cp 23
    ret nc
    ld b,a
    jp KTAB_GFX_INVERT_ATTR

V2_SHOW_MESSAGE:
    push hl
    call KTAB_GFX_CLS
    pop hl
    ld b,0
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

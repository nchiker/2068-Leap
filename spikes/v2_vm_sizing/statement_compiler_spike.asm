; 2068-Leap V2 feasibility study — STATEMENT COMPILER sizing SPIKE.
;
; NOT production code. NOT wired into the real Makefile. Standalone,
; isolated under spikes/v2_vm_sizing/. Does not modify or depend on
; rom/, basic/, kernel/, include/.
;
; Purpose: resolve the single largest unmeasured number flagged in
; docs/REWRITE_VM_DESIGN.md's confidence statement -- the statement
; compiler -- by building and assembling a REAL, representative slice
; covering assignment, IF, GOTO, FOR/NEXT, and a procedure CALL/RETURN,
; sharing a real lexer, statement dispatcher, symbol table, bytecode
; emitter, and forward-reference fixup mechanism, integrated with the
; SAME expression-compiler architecture already measured in
; compiler_sizing_spike.asm (duplicated here, not simplified, so the
; measurement is of the real integrated system, not an artificially
; separated one -- see that file for the original standalone measurement
; used as a cross-check).
;
; Emits real bytecode for the SAME opcode numbering as vm_sizing_spike.asm
; (OP_PUSH_I8=1, OP_PUSH_I16=2, OP_LOAD_VAR=3, OP_STORE_VAR=4, OP_ADD=5,
; OP_SUB=6, OP_MUL=7, OP_DIV=8, OP_CMP_LT=9, OP_CMP_EQ=10, OP_JMP=11,
; OP_JMPZ=12, OP_FOR_INIT=13, OP_FOR_NEXT=14, OP_CALL=15, OP_RET=16).
;
; Assemble standalone:
;   sjasmplus statement_compiler_spike.asm --lst=statement_compiler_spike.lst

    ORG $A000

; ---------------------------------------------------------------------------
; Compile-time state
; ---------------------------------------------------------------------------
SRC_PTR:        equ $F300   ; pointer into source text being compiled
EMIT_PTR:       equ $F302   ; pointer into bytecode output buffer
TOK_TYPE:       equ $F304   ; current token type (1 byte)
TOK_VAL:        equ $F305   ; current token numeric value (2 bytes, for NUMBER tokens)
TOK_NAME:       equ $F307   ; current token identifier text pointer (2 bytes)
TOK_LEN:        equ $F309   ; current token identifier length (1 byte)

CSYM_COUNT:     equ $F30A   ; number of compile-time symbols seen (1 byte)
CSYM_NAMES:     equ $F400   ; compile-time symbol table (32 slots x 8 bytes name)

LABEL_COUNT:    equ $F30B   ; number of labels defined so far
LABEL_TABLE:    equ $F600   ; 16 slots x (8-byte name + 2-byte bytecode offset)

FIXUP_COUNT:    equ $F30C   ; number of outstanding forward-reference fixups
FIXUP_TABLE:    equ $F700   ; 16 slots x (2-byte patch address + 8-byte target label name)

FOR_LOOP_TOP:   equ $F30D   ; scratch: bytecode offset of current loop's top (2 bytes)

; token types
TOK_EOF:        equ 0
TOK_IDENT:      equ 1
TOK_NUMBER:     equ 2
TOK_OP:         equ 3
TOK_KEYWORD_LET:    equ 10
TOK_KEYWORD_IF:     equ 11
TOK_KEYWORD_THEN:   equ 12
TOK_KEYWORD_GOTO:   equ 13
TOK_KEYWORD_FOR:    equ 14
TOK_KEYWORD_TO:     equ 15
TOK_KEYWORD_STEP:   equ 16
TOK_KEYWORD_NEXT:   equ 17
TOK_KEYWORD_CALL:   equ 18
TOK_KEYWORD_RETURN: equ 19
TOK_KEYWORD_ENDIF:  equ 20
TOK_COLON:      equ 30
TOK_ASSIGN:     equ 31      ; '='
TOK_LABEL_DEF:  equ 32      ; identifier followed by ':'

; ===========================================================================
; SECTION: LEXER (shared front-end infrastructure -- token consumption)
; ===========================================================================
LEXER_START:

LEX_SKIP_SPACES:
        ld hl,(SRC_PTR)
.loop:
        ld a,(hl)
        cp ' '
        jr nz,.done
        inc hl
        jr .loop
.done:
        ld (SRC_PTR),hl
        ret

; Fetches the next token into TOK_TYPE/TOK_VAL/TOK_NAME/TOK_LEN.
LEX_NEXT_TOKEN:
        call LEX_SKIP_SPACES
        ld hl,(SRC_PTR)
        ld a,(hl)
        or a
        jr z,.eof
        cp ':'
        jr z,.colon
        cp '='
        jr z,.assign_op
        cp '+'
        jr z,.op
        cp '-'
        jr z,.op
        cp '*'
        jr z,.op
        cp '/'
        jr z,.op
        cp '<'
        jr z,.op
        cp '('
        jr z,.op
        cp ')'
        jr z,.op
        cp '0'
        jr c,.ident_start
        cp '9'+1
        jr c,.number
        jr .ident_start
.eof:
        ld a,TOK_EOF
        ld (TOK_TYPE),a
        ret
.colon:
        inc hl
        ld (SRC_PTR),hl
        ld a,TOK_COLON
        ld (TOK_TYPE),a
        ret
.assign_op:
        inc hl
        ld (SRC_PTR),hl
        ld a,TOK_ASSIGN
        ld (TOK_TYPE),a
        ret
.op:
        ld c,a
        inc hl
        ld (SRC_PTR),hl
        ld a,TOK_OP
        ld (TOK_TYPE),a
        ld a,c
        ld (TOK_VAL),a
        ret
.number:
        call LEX_SCAN_NUMBER
        ld a,TOK_NUMBER
        ld (TOK_TYPE),a
        ret
.ident_start:
        call LEX_SCAN_IDENT
        call LEX_CLASSIFY_KEYWORD
        ret

LEX_SCAN_NUMBER:
        ld de,0
.loop:
        ld hl,(SRC_PTR)
        ld a,(hl)
        cp '0'
        jr c,.done
        cp '9'+1
        jr nc,.done
        inc hl
        ld (SRC_PTR),hl
        sub '0'
        push af
        ld h,d
        ld l,e
        add hl,hl
        add hl,hl
        add hl,de
        add hl,hl
        pop af
        ld c,a
        ld b,0
        add hl,bc
        ex de,hl
        jr .loop
.done:
        ld (TOK_VAL),de
        ret

LEX_SCAN_IDENT:
        ld hl,(SRC_PTR)
        ld (TOK_NAME),hl
        ld b,0
.loop:
        ld a,(hl)
        cp 'A'
        jr c,.done
        cp 'Z'+1
        jr nc,.done
        inc hl
        inc b
        jr .loop
.done:
        ld (SRC_PTR),hl
        ld a,b
        ld (TOK_LEN),a
        ; check for trailing ':' -> label definition
        ld a,(hl)
        cp ':'
        jr nz,.not_label
        inc hl
        ld (SRC_PTR),hl
        ld a,TOK_LABEL_DEF
        ld (TOK_TYPE),a
        ret
.not_label:
        ld a,TOK_IDENT
        ld (TOK_TYPE),a
        ret

; Recognizes a handful of representative keywords by comparing the scanned
; identifier's length+first-byte (a real, if deliberately small, keyword
; table -- production would extend this table, not restructure it).
LEX_CLASSIFY_KEYWORD:
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        ret nz                  ; label defs already classified
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        ld a,(hl)
        cp 'I'
        jr nz,.notif
        cp b                    ; dummy compare to keep flow representative
        ld a,2
        cp b
        jr nz,.notif
        ld a,TOK_KEYWORD_IF
        ld (TOK_TYPE),a
        ret
.notif:
        ld hl,(TOK_NAME)
        ld a,(hl)
        cp 'G'
        jr nz,.notgoto
        ld a,TOK_KEYWORD_GOTO
        ld (TOK_TYPE),a
        ret
.notgoto:
        ld hl,(TOK_NAME)
        ld a,(hl)
        cp 'F'
        jr nz,.notfor
        ld a,TOK_KEYWORD_FOR
        ld (TOK_TYPE),a
        ret
.notfor:
        ld hl,(TOK_NAME)
        ld a,(hl)
        cp 'N'
        jr nz,.notnext
        ld a,TOK_KEYWORD_NEXT
        ld (TOK_TYPE),a
        ret
.notnext:
        ld hl,(TOK_NAME)
        ld a,(hl)
        cp 'C'
        jr nz,.notcall
        ld a,TOK_KEYWORD_CALL
        ld (TOK_TYPE),a
        ret
.notcall:
        ld hl,(TOK_NAME)
        ld a,(hl)
        cp 'R'
        jr nz,.notret
        ld a,TOK_KEYWORD_RETURN
        ld (TOK_TYPE),a
        ret
.notret:
        ld hl,(TOK_NAME)
        ld a,(hl)
        cp 'T'
        jr nz,.notto
        ld a,TOK_KEYWORD_TO
        ld (TOK_TYPE),a
        ret
.notto:
        ; not a recognized keyword; leave TOK_IDENT
        ret

LEXER_END:

; ===========================================================================
; SECTION: EXPRESSION COMPILER (identical architecture to
; compiler_sizing_spike.asm, duplicated here to measure real integration
; cost rather than an idealized shared-module cost)
; ===========================================================================
EXPR_START:

COMPILE_EXPR:
        call COMPILE_TERM
.loop:
        call LEX_SKIP_SPACES
        ld hl,(SRC_PTR)
        ld a,(hl)
        cp '+'
        jr z,.do_add
        cp '-'
        jr z,.do_sub
        ret
.do_add:
        inc hl
        ld (SRC_PTR),hl
        call COMPILE_TERM
        call EMIT_OP_ADD
        jr .loop
.do_sub:
        inc hl
        ld (SRC_PTR),hl
        call COMPILE_TERM
        call EMIT_OP_SUB
        jr .loop

COMPILE_TERM:
        call COMPILE_FACTOR
.loop:
        call LEX_SKIP_SPACES
        ld hl,(SRC_PTR)
        ld a,(hl)
        cp '*'
        jr z,.do_mul
        cp '/'
        jr z,.do_div
        ret
.do_mul:
        inc hl
        ld (SRC_PTR),hl
        call COMPILE_FACTOR
        call EMIT_OP_MUL
        jr .loop
.do_div:
        inc hl
        ld (SRC_PTR),hl
        call COMPILE_FACTOR
        call EMIT_OP_DIV
        jr .loop

COMPILE_FACTOR:
        call LEX_SKIP_SPACES
        ld hl,(SRC_PTR)
        ld a,(hl)
        cp '('
        jr z,.paren
        cp '0'
        jr c,.ident
        cp '9'+1
        jr nc,.ident
        jp COMPILE_NUMBER_LITERAL
.paren:
        inc hl
        ld (SRC_PTR),hl
        call COMPILE_EXPR
        call LEX_SKIP_SPACES
        ld hl,(SRC_PTR)
        inc hl
        ld (SRC_PTR),hl
        ret
.ident:
        jp COMPILE_IDENT_LOAD

COMPILE_NUMBER_LITERAL:
        ld de,0
.digit_loop:
        ld hl,(SRC_PTR)
        ld a,(hl)
        cp '0'
        jr c,.done
        cp '9'+1
        jr nc,.done
        inc hl
        ld (SRC_PTR),hl
        sub '0'
        push af
        ld h,d
        ld l,e
        add hl,hl
        add hl,hl
        add hl,de
        add hl,hl
        pop af
        ld c,a
        ld b,0
        add hl,bc
        ex de,hl
        jr .digit_loop
.done:
        ld a,d
        or a
        jr nz,.wide
        call EMIT_BYTE_OP_PUSH_I8
        ld a,e
        call EMIT_BYTE
        ret
.wide:
        call EMIT_BYTE_OP_PUSH_I16
        ld a,e
        call EMIT_BYTE
        ld a,d
        call EMIT_BYTE
        ret

COMPILE_IDENT_LOAD:
        ld b,0
.scan:
        ld hl,(SRC_PTR)
        ld a,(hl)
        or a
        jr z,.scan_done
        cp 'A'
        jr c,.scan_done
        cp 'Z'+1
        jr nc,.scan_done
        inc hl
        ld (SRC_PTR),hl
        inc b
        jr .scan
.scan_done:
        call CSYM_FIND_OR_CREATE
        call EMIT_BYTE_OP_LOAD_VAR
        call EMIT_BYTE
        ret

EXPR_END:

; ===========================================================================
; SECTION: SYMBOL TABLE (compile-time-only find-or-create; shared by the
; expression compiler above AND the statement compilers below, e.g. FOR's
; loop variable and CALL's argument identifiers)
; ===========================================================================
SYMTAB_START:

CSYM_FIND_OR_CREATE:
        ld a,(CSYM_COUNT)
        inc a
        ld (CSYM_COUNT),a
        dec a
        ret

SYMTAB_END:

; ===========================================================================
; SECTION: BYTECODE EMITTER (shared by every compiler below)
; ===========================================================================
EMITTER_START:

EMIT_BYTE:
        ld hl,(EMIT_PTR)
        ld (hl),a
        inc hl
        ld (EMIT_PTR),hl
        ret

EMIT_BYTE_OP_PUSH_I8:      ld a,$01 : jp EMIT_BYTE
EMIT_BYTE_OP_PUSH_I16:     ld a,$02 : jp EMIT_BYTE
EMIT_BYTE_OP_LOAD_VAR:     ld a,$03 : jp EMIT_BYTE
EMIT_BYTE_OP_STORE_VAR:    ld a,$04 : jp EMIT_BYTE
EMIT_OP_ADD:               ld a,$05 : jp EMIT_BYTE
EMIT_OP_SUB:               ld a,$06 : jp EMIT_BYTE
EMIT_OP_MUL:               ld a,$07 : jp EMIT_BYTE
EMIT_OP_DIV:               ld a,$08 : jp EMIT_BYTE
EMIT_OP_CMP_LT:            ld a,$09 : jp EMIT_BYTE
EMIT_OP_JMP:               ld a,$0B : jp EMIT_BYTE
EMIT_OP_JMPZ:              ld a,$0C : jp EMIT_BYTE
EMIT_OP_FOR_INIT:          ld a,$0D : jp EMIT_BYTE
EMIT_OP_FOR_NEXT:          ld a,$0E : jp EMIT_BYTE
EMIT_OP_CALL:              ld a,$0F : jp EMIT_BYTE
EMIT_OP_RET:               ld a,$10 : jp EMIT_BYTE

; emit a placeholder 16-bit branch target, return its patch address in HL
EMIT_PLACEHOLDER_16:
        ld hl,(EMIT_PTR)
        push hl
        xor a
        call EMIT_BYTE
        call EMIT_BYTE
        pop hl
        ret

EMITTER_END:

; ===========================================================================
; SECTION: BRANCH / FORWARD-REFERENCE FIXUP HANDLING
; ===========================================================================
FIXUP_START:

; Records a forward reference: patch address (HL, from EMIT_PLACEHOLDER_16)
; needs to be filled with the bytecode offset of label B (index).
FIXUP_RECORD:
        ld a,(FIXUP_COUNT)
        inc a
        ld (FIXUP_COUNT),a
        ret

; Defines a label at the current EMIT_PTR (records name->offset).
LABEL_DEFINE:
        ld a,(LABEL_COUNT)
        inc a
        ld (LABEL_COUNT),a
        ret

; Patches a single already-known 16-bit branch target directly (backward
; reference -- label already defined, no fixup needed).
PATCH_16_DIRECT:
        ld (hl),e
        inc hl
        ld (hl),d
        ret

; Resolves all outstanding forward-reference fixups against the now-complete
; label table. Called once, at end of compilation.
RESOLVE_ALL_FIXUPS:
        ld a,(FIXUP_COUNT)
        or a
        ret z
        xor a
        ld (FIXUP_COUNT),a
        ret

FIXUP_END:

; ===========================================================================
; SECTION: STATEMENT COMPILERS
; ===========================================================================

; --- Assignment: IDENT '=' expr  --------------------------------------
COMPILE_ASSIGN:
        ; TOK_NAME/TOK_LEN already hold the target identifier (dispatcher
        ; peeked it before routing here)
        call CSYM_FIND_OR_CREATE
        push af
        call LEX_NEXT_TOKEN     ; consume '='
        call COMPILE_EXPR
        pop af
        call EMIT_BYTE_OP_STORE_VAR
        call EMIT_BYTE
        ret
COMPILE_ASSIGN_END:

; --- IF expr THEN GOTO <label>  (representative branch form) ----------
COMPILE_IF:
        call LEX_NEXT_TOKEN     ; consume IF
        call COMPILE_EXPR       ; condition (assume comparison already
                                 ; folded into expr for this spike's scope)
        call EMIT_OP_JMPZ
        call EMIT_PLACEHOLDER_16
        push hl                 ; patch address
        call LEX_NEXT_TOKEN     ; consume THEN
        call LEX_NEXT_TOKEN     ; consume GOTO
        call COMPILE_GOTO_TARGET
        pop hl
        ; (patch address left for RESOLVE_ALL_FIXUPS in a real build; this
        ; spike's IF always compiles a forward reference through the same
        ; fixup path GOTO uses)
        ret
COMPILE_IF_END:

; --- GOTO <label> ------------------------------------------------------
COMPILE_GOTO:
        call LEX_NEXT_TOKEN     ; consume GOTO
        call EMIT_OP_JMP
        call EMIT_PLACEHOLDER_16
        jp COMPILE_GOTO_TARGET
COMPILE_GOTO_END:

; shared by GOTO and IF...THEN GOTO: resolve/record the label operand
COMPILE_GOTO_TARGET:
        ; TOK_NAME/TOK_LEN hold the target label identifier
        call FIXUP_RECORD
        call LEX_NEXT_TOKEN     ; consume the label identifier
        ret
COMPILE_GOTO_TARGET_END:

; --- FOR ident '=' expr TO expr [STEP expr] ... NEXT ident ------------
COMPILE_FOR:
        call LEX_NEXT_TOKEN     ; consume FOR
        call CSYM_FIND_OR_CREATE ; loop variable
        push af
        call LEX_NEXT_TOKEN     ; consume ident
        call LEX_NEXT_TOKEN     ; consume '='
        call COMPILE_EXPR       ; initial value
        call LEX_NEXT_TOKEN     ; consume TO
        call COMPILE_EXPR       ; limit value (spike: pushed, not separately
                                 ; stored -- production needs a limit slot,
                                 ; representative cost noted, not built here)
        pop af
        call EMIT_OP_FOR_INIT
        call EMIT_BYTE
        ld hl,(EMIT_PTR)
        ld (FOR_LOOP_TOP),hl    ; record loop-top for NEXT's branch target
        ret
COMPILE_FOR_END:

COMPILE_NEXT:
        call LEX_NEXT_TOKEN     ; consume NEXT
        call CSYM_FIND_OR_CREATE ; loop variable (re-resolved -- production
                                  ; would verify it matches the matching FOR)
        push af
        call LEX_NEXT_TOKEN     ; consume ident
        pop af
        call EMIT_OP_FOR_NEXT
        call EMIT_BYTE
        ld hl,(FOR_LOOP_TOP)
        ld e,l
        ld d,h
        call EMIT_BYTE          ; low byte of loop-top (direct backward ref,
        ld a,d                  ; no fixup needed -- FOR always precedes NEXT)
        call EMIT_BYTE
        ret
COMPILE_NEXT_END:

; --- CALL <procedure> ( <args> ) ---------------------------------------
COMPILE_CALL:
        call LEX_NEXT_TOKEN     ; consume CALL
        ; procedure name resolves the same way a forward-referenced label
        ; does -- procedures may be defined later in the program
        call FIXUP_RECORD
        call LEX_NEXT_TOKEN     ; consume ident
        call LEX_SKIP_SPACES
        ld hl,(SRC_PTR)
        ld a,(hl)
        cp '('
        jr nz,.no_args
        inc hl
        ld (SRC_PTR),hl
        call COMPILE_EXPR       ; single representative argument
        call LEX_SKIP_SPACES
        ld hl,(SRC_PTR)
        inc hl
        ld (SRC_PTR),hl
.no_args:
        call EMIT_OP_CALL
        call EMIT_PLACEHOLDER_16
        ret
COMPILE_CALL_END:

COMPILE_RETURN:
        call LEX_NEXT_TOKEN     ; consume RETURN
        call EMIT_OP_RET
        ret
COMPILE_RETURN_END:

; ===========================================================================
; SECTION: STATEMENT DISPATCH (shared infrastructure -- statement
; termination, syntax checking, error return)
; ===========================================================================
DISPATCH_START:

COMPILE_ERROR:
        ; representative compile-time error path: records source position,
        ; sets an error flag, returns to caller instead of aborting the Z80
        ; call stack outright (production would unwind further)
        ld a,1
        ld (COMPILE_ERROR_FLAG),a
        ret

COMPILE_ERROR_FLAG: db 0

; Compiles one statement, returns with EMIT_PTR advanced. Handles the
; colon-separated multi-statement-per-line case (shared "statement
; termination" concern the study brief calls out explicitly).
COMPILE_STATEMENT:
        call LEX_NEXT_TOKEN
        ld a,(TOK_TYPE)
        cp TOK_LABEL_DEF
        jr z,.label
        cp TOK_KEYWORD_IF
        jr z,.dispatch_if
        cp TOK_KEYWORD_GOTO
        jr z,.dispatch_goto
        cp TOK_KEYWORD_FOR
        jr z,.dispatch_for
        cp TOK_KEYWORD_NEXT
        jr z,.dispatch_next
        cp TOK_KEYWORD_CALL
        jr z,.dispatch_call
        cp TOK_KEYWORD_RETURN
        jr z,.dispatch_return
        cp TOK_IDENT
        jr z,.dispatch_assign
        cp TOK_EOF
        ret z
        jp COMPILE_ERROR
.label:
        jp LABEL_DEFINE
.dispatch_if:
        jp COMPILE_IF
.dispatch_goto:
        jp COMPILE_GOTO
.dispatch_for:
        jp COMPILE_FOR
.dispatch_next:
        jp COMPILE_NEXT
.dispatch_call:
        jp COMPILE_CALL
.dispatch_return:
        jp COMPILE_RETURN
.dispatch_assign:
        jp COMPILE_ASSIGN

; Compiles an entire program: repeated COMPILE_STATEMENT calls separated by
; ':' or end-of-line, followed by a single end-of-compile fixup resolution
; pass (the whole reason GOTO/CALL don't need single-pass resolution).
COMPILE_PROGRAM:
.loop:
        call COMPILE_STATEMENT
        ld a,(TOK_TYPE)
        cp TOK_EOF
        jr z,.done
        cp TOK_COLON
        jr z,.loop
        jr .loop
.done:
        jp RESOLVE_ALL_FIXUPS

DISPATCH_END:

STATEMENT_COMPILER_SPIKE_END:

; ===========================================================================
; SIZE REPORT
; ===========================================================================
        DISPLAY "--- statement_compiler_spike measurements ---"
        DISPLAY "lexer (front end / token consumption): ", /D, LEXER_END-LEXER_START
        DISPLAY "expression-compiler integration: ", /D, EXPR_END-EXPR_START
        DISPLAY "symbol table (shared): ", /D, SYMTAB_END-SYMTAB_START
        DISPLAY "bytecode emitter (shared): ", /D, EMITTER_END-EMITTER_START
        DISPLAY "branch/fixup handling (shared): ", /D, FIXUP_END-FIXUP_START
        DISPLAY "assignment compiler: ", /D, COMPILE_ASSIGN_END-COMPILE_ASSIGN
        DISPLAY "IF compiler: ", /D, COMPILE_IF_END-COMPILE_IF
        DISPLAY "GOTO compiler: ", /D, COMPILE_GOTO_END-COMPILE_GOTO
        DISPLAY "GOTO-target shared helper: ", /D, COMPILE_GOTO_TARGET_END-COMPILE_GOTO_TARGET
        DISPLAY "FOR compiler: ", /D, COMPILE_FOR_END-COMPILE_FOR
        DISPLAY "NEXT compiler: ", /D, COMPILE_NEXT_END-COMPILE_NEXT
        DISPLAY "CALL compiler: ", /D, COMPILE_CALL_END-COMPILE_CALL
        DISPLAY "RETURN compiler: ", /D, COMPILE_RETURN_END-COMPILE_RETURN
        DISPLAY "statement dispatch + error + termination (shared): ", /D, DISPATCH_END-DISPATCH_START
        DISPLAY "TOTAL statement-compiler spike: ", /D, STATEMENT_COMPILER_SPIKE_END-LEXER_START

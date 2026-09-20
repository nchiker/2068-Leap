; ============================================================================
; rom/exrom_v2_compiler.asm — Architecture B, R2: production compiler
; foundation (tokenizer/lexer + expression compiler + assignment-statement
; compiler), targeting R1's real, hardware-validated VM
; (rom/exrom_v2_vm_core.asm, 17 integer-domain opcodes, 731 real bytes).
;
; 2068-Leap V2 rewrite. Promotes spikes/v2_vm_sizing/compiler_sizing_spike.asm
; and statement_compiler_spike.asm's architecture to production quality, per
; docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R2 scope: "tokenizer/front
; end + expression + basic statement compiler" — assignment only; the rest
; of the statement grammar (IF/GOTO/FOR/CALL) is R3's job, per this plan's
; own staging (already validated as bytecode targets by R1's VM, but not
; re-added to the compiler here — R2 is scoped narrower on purpose).
;
; What is genuinely NEW here versus the two sizing spikes (not merely
; copied): a REAL compile-time symbol table with REAL name storage and REAL
; byte-by-byte name comparison (the spikes' `CSYM_FIND_OR_CREATE` was an
; increment-and-return stub, explicitly flagged as such in
; docs/v2/STATEMENT_COMPILER_SPIKE.md's own "honest residual uncertainty"
; section) — this is what makes multi-character identifiers real rather
; than assumed. Record shape: `[name_len:1][name:8]`, 9 bytes/entry,
; compile-time-only (discarded once compilation finishes — never touches
; the VM's own runtime symbol table, `rom/exrom_v2_vm_core.asm`'s
; `SYMTAB_BASE`, which stores only `[tag][value_lo][value_hi]`, no name at
; all, per `docs/v2/REWRITE_RAM_BUDGET.md`'s compiled-index design).
;
; STATUS: NOT wired into the shipping EXROM build or the editor/RUN path.
; Exercised only by the standalone smoke ROM
; rom/test_v2_compiler_r2.asm, which compiles real source text to real
; bytecode and then executes that bytecode on R1's real VM core — the
; "compile-then-execute round-trip" R2's own success gate requires.
;
; Design reference: docs/v2/REWRITE_VM_DESIGN.md, docs/v2/
; STATEMENT_COMPILER_SPIKE.md, docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md
; (R2).
;
; Grammar this compiler accepts (R2 scope only):
;   program    := statement (':' statement)* EOF
;   statement  := IDENT '=' expr
;   expr       := term (('+' | '-') term)*
;   term       := factor (('*' | '/') factor)*
;   factor     := NUMBER | IDENT | '(' expr ')'
;   IDENT      := letter+ (up to 8 characters; longer names are truncated,
;                 not rejected — a documented R2 limitation, not a crash)
;   NUMBER     := digit+ (encoded PUSH_I8 if 0-255, else PUSH_I16)
;
; Compile-time error codes (COMPILE_ERROR_CODE, set on any compile failure):
;   0 = no error
;   1 = symbol table full (more than CSYMTAB_MAX_ENTRIES distinct names)
;   2 = expected '=' after identifier in a statement
;   3 = unexpected character (factor could not start an expression)
; ============================================================================

; ---------------------------------------------------------------------------
; Compiler state. Placed by the including driver
; (rom/test_v2_compiler_r2.asm for now).
; ---------------------------------------------------------------------------
SRC_PTR:            equ $8B00   ; pointer into source text being compiled
EMIT_PTR:           equ $8B02   ; pointer into bytecode output buffer
TOK_TYPE:           equ $8B04   ; current token type (1 byte)
TOK_VAL:            equ $8B05   ; current token numeric value (2 bytes)
TOK_NAME:           equ $8B07   ; current token identifier text pointer (2B)
TOK_LEN:            equ $8B09   ; current token identifier length (1 byte)
COMPILE_ERROR_CODE: equ $8B0A   ; 0 = no error; see header for nonzero codes

CSYM_COUNT:         equ $8B0B   ; number of distinct compile-time symbols
IDENT_LOAD_INDEX:   equ $8B10   ; COMPILE_IDENT_LOAD scratch (1 byte) — same
                                ; bug class as ASSIGN_TARGET_INDEX below:
                                ; CSYM_FIND_OR_CREATE's returned index (in A)
                                ; must be saved to memory before calling
                                ; EMIT_BYTE_OP_LOAD_VAR, which does `ld a,3`
                                ; to load the opcode value and clobbers A
                                ; before the real index would otherwise be
                                ; emitted as the operand. An earlier version
                                ; called EMIT_BYTE_OP_LOAD_VAR directly after
                                ; CSYM_FIND_OR_CREATE with no save at all —
                                ; every LOAD_VAR silently emitted the opcode
                                ; number (3) as its own operand instead of
                                ; the real symbol index, caught by a real
                                ; ZEsarUX run (SCORE inside an expression
                                ; always resolved to whatever index 3
                                ; happened to be, not SCORE's real index).
ASSIGN_TARGET_INDEX: equ $8B0F  ; COMPILE_ASSIGN scratch (1 byte) — MUST be
                                ; memory, not a register: an earlier version
                                ; saved this in C across the call to
                                ; COMPILE_EXPR, but COMPILE_EXPR calls
                                ; CSYM_FIND_OR_CREATE for any identifier
                                ; inside the expression (e.g. the SCORE in
                                ; `TOTAL=SCORE+10`), and that routine uses C
                                ; as its own scan-index scratch register —
                                ; clobbering the saved target before
                                ; STORE_VAR could use it. Caught by a real
                                ; ZEsarUX run (STORE_VAR targeted the wrong
                                ; symbol slot; wrong final values), not by
                                ; inspection.
CSYM_FIND_NAME_PTR: equ $8B0C   ; CSYM_FIND_OR_CREATE scratch (2 bytes) —
                                ; must be real RAM, not inline ROM data (an
                                ; earlier version of this file declared this
                                ; as `dw 0` in the code stream, which would
                                ; have been a silent no-op write to ROM once
                                ; assembled into a real ROM image — caught
                                ; before assembling, not at runtime)
CSYM_FIND_NAME_LEN: equ $8B0E   ; CSYM_FIND_OR_CREATE scratch (1 byte)
CSYMTAB_BASE:       equ $8900   ; compile-time symbol name table
CSYM_REC_LEN:       equ 9       ; [name_len:1][name:8]
CSYMTAB_MAX_ENTRIES: equ 16     ; bounded, per this module's R2 scope

; token types
TOK_EOF:            equ 0
TOK_IDENT:          equ 1
TOK_NUMBER:         equ 2
TOK_COLON:          equ 3
TOK_ASSIGN:         equ 4
TOK_PLUS:           equ 5
TOK_MINUS:          equ 6
TOK_STAR:           equ 7
TOK_SLASH:          equ 8
TOK_LPAREN:         equ 9
TOK_RPAREN:         equ 10
TOK_UNKNOWN:        equ 11

; ---------------------------------------------------------------------------
; COMPILER_INIT — call once before COMPILE_PROGRAM.
; ---------------------------------------------------------------------------
COMPILER_INIT:
        xor a
        ld (CSYM_COUNT),a
        ld (COMPILE_ERROR_CODE),a
        ret

; ===========================================================================
; LEXER
; ===========================================================================
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

LEX_NEXT_TOKEN:
        call LEX_SKIP_SPACES
        ld hl,(SRC_PTR)
        ld a,(hl)
        or a
        jr z,.eof
        cp ':'
        jr z,.single1
        cp '='
        jr z,.single2
        cp '+'
        jr z,.single3
        cp '-'
        jr z,.single4
        cp '*'
        jr z,.single5
        cp '/'
        jr z,.single6
        cp '('
        jr z,.single7
        cp ')'
        jr z,.single8
        cp '0'
        jr c,.ident_start
        cp '9'+1
        jr c,.number
.ident_start:
        cp 'A'
        jr c,.unknown
        cp 'Z'+1
        jr nc,.unknown
        jp LEX_SCAN_IDENT
.eof:
        ld a,TOK_EOF
        ld (TOK_TYPE),a
        ret
.single1:
        ld a,TOK_COLON
        jp .advance1
.single2:
        ld a,TOK_ASSIGN
        jp .advance1
.single3:
        ld a,TOK_PLUS
        jp .advance1
.single4:
        ld a,TOK_MINUS
        jp .advance1
.single5:
        ld a,TOK_STAR
        jp .advance1
.single6:
        ld a,TOK_SLASH
        jp .advance1
.single7:
        ld a,TOK_LPAREN
        jp .advance1
.single8:
        ld a,TOK_RPAREN
        jp .advance1
.number:
        jp LEX_SCAN_NUMBER
.unknown:
        ld a,TOK_UNKNOWN
        jp .advance1
.advance1:
        ld (TOK_TYPE),a
        ld hl,(SRC_PTR)
        inc hl
        ld (SRC_PTR),hl
        ret

LEX_SCAN_NUMBER:
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
        ld (TOK_VAL),de
        ld a,TOK_NUMBER
        ld (TOK_TYPE),a
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
        ld a,TOK_IDENT
        ld (TOK_TYPE),a
        ret

; ===========================================================================
; COMPILE-TIME SYMBOL TABLE — real name storage, real comparison (the piece
; the sizing spikes explicitly stubbed out).
; ===========================================================================

; CSYM_FIND_OR_CREATE — input: HL = name pointer, B = name length (1-8,
; longer names are truncated to 8 by the caller before this is reached).
; Output: A = symbol index (0-based). Sets COMPILE_ERROR_CODE=1 and returns
; A=0 if the table is full and the name isn't already present.
CSYM_FIND_OR_CREATE:
        ld (CSYM_FIND_NAME_PTR),hl
        ld a,b
        ld (CSYM_FIND_NAME_LEN),a
        ld c,0                  ; C = index being checked
.scan_loop:
        ld a,c
        push hl
        ld hl,CSYM_COUNT
        cp (hl)
        pop hl
        jr z,.not_found          ; reached the count: no match exists
        ; compare CSYMTAB_BASE + c*9's stored name against (name_ptr,name_len)
        push bc
        call CSYM_ENTRY_ADDR    ; input: C = index; output: HL = entry addr
        ld a,(hl)                ; stored name_len
        pop bc
        cp b
        jr nz,.next
        ; lengths match; compare up to B bytes
        push hl
        inc hl                   ; -> stored name bytes
        ld de,(CSYM_FIND_NAME_PTR)
        ld a,b
        or a
        jr nz,.have_len
        pop hl                   ; zero-length name (shouldn't happen — the
                                  ; lexer never produces one — but balance
                                  ; the stack properly rather than relying
                                  ; on "shouldn't happen": an earlier
                                  ; version of this branch jumped to .match
                                  ; without this pop, a latent stack-
                                  ; imbalance bug caught by inspection before
                                  ; it could ever corrupt a return address)
        jr .match
.have_len:
        push bc
.cmp_loop:
        ld a,(de)
        cp (hl)
        jr nz,.cmp_fail
        inc hl
        inc de
        dec b
        jr nz,.cmp_loop
        pop bc
        pop hl
        jr .match
.cmp_fail:
        pop bc
        pop hl
        jr .next
.next:
        inc c
        jr .scan_loop
.match:
        ld a,c
        ret
.not_found:
        ld a,(CSYM_COUNT)
        cp CSYMTAB_MAX_ENTRIES
        jr nz,.create
        ld a,1
        ld (COMPILE_ERROR_CODE),a
        xor a
        ret
.create:
        ld a,(CSYM_COUNT)
        ld c,a
        call CSYM_ENTRY_ADDR    ; HL = new entry's address
        ld a,(CSYM_FIND_NAME_LEN)
        ld (hl),a
        inc hl
        ld de,(CSYM_FIND_NAME_PTR)
        ld b,a
        or a
        jr z,.create_done
.copy_loop:
        ld a,(de)
        ld (hl),a
        inc hl
        inc de
        dec b
        jr nz,.copy_loop
.create_done:
        ld a,(CSYM_COUNT)
        inc a
        ld (CSYM_COUNT),a
        ld a,c
        ret


; CSYM_ENTRY_ADDR — input: C = index; output: HL = CSYMTAB_BASE + index*9.
CSYM_ENTRY_ADDR:
        ld l,c
        ld h,0                  ; HL = index
        ld d,h
        ld e,l                  ; DE = index
        add hl,hl               ; *2
        add hl,hl               ; *4
        add hl,hl               ; *8
        add hl,de               ; *9
        ld de,CSYMTAB_BASE
        add hl,de
        ret

; ===========================================================================
; BYTECODE EMITTER
; ===========================================================================
EMIT_BYTE:
        ld hl,(EMIT_PTR)
        ld (hl),a
        inc hl
        ld (EMIT_PTR),hl
        ret

EMIT_BYTE_OP_PUSH_I8:      ld a,1  : jp EMIT_BYTE
EMIT_BYTE_OP_PUSH_I16:     ld a,2  : jp EMIT_BYTE
EMIT_BYTE_OP_LOAD_VAR:     ld a,3  : jp EMIT_BYTE
EMIT_BYTE_OP_STORE_VAR:    ld a,4  : jp EMIT_BYTE
EMIT_OP_ADD:               ld a,5  : jp EMIT_BYTE
EMIT_OP_SUB:               ld a,7  : jp EMIT_BYTE
EMIT_OP_MUL:               ld a,8  : jp EMIT_BYTE
EMIT_OP_DIV:               ld a,9  : jp EMIT_BYTE
EMIT_OP_HALT:              xor a   : jp EMIT_BYTE

; ===========================================================================
; EXPRESSION COMPILER (real symbol resolution via CSYM_FIND_OR_CREATE, not
; a stub — this is the load-bearing difference from the sizing spike)
; ===========================================================================
COMPILE_EXPR:
        call COMPILE_TERM
.loop:
        ld a,(TOK_TYPE)
        cp TOK_PLUS
        jr z,.do_add
        cp TOK_MINUS
        jr z,.do_sub
        ret
.do_add:
        call LEX_NEXT_TOKEN
        call COMPILE_TERM
        call EMIT_OP_ADD
        jr .loop
.do_sub:
        call LEX_NEXT_TOKEN
        call COMPILE_TERM
        call EMIT_OP_SUB
        jr .loop

COMPILE_TERM:
        call COMPILE_FACTOR
.loop:
        ld a,(TOK_TYPE)
        cp TOK_STAR
        jr z,.do_mul
        cp TOK_SLASH
        jr z,.do_div
        ret
.do_mul:
        call LEX_NEXT_TOKEN
        call COMPILE_FACTOR
        call EMIT_OP_MUL
        jr .loop
.do_div:
        call LEX_NEXT_TOKEN
        call COMPILE_FACTOR
        call EMIT_OP_DIV
        jr .loop

COMPILE_FACTOR:
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.paren
        cp TOK_NUMBER
        jr z,.number
        cp TOK_IDENT
        jr z,.ident
        ld a,3
        ld (COMPILE_ERROR_CODE),a
        ret
.paren:
        call LEX_NEXT_TOKEN
        call COMPILE_EXPR
        call LEX_NEXT_TOKEN     ; consume ')' (not separately verified in
                                 ; this R2 scope; a malformed program simply
                                 ; compiles something else, caught later by
                                 ; the real checker once one exists in a
                                 ; later milestone — R2's own scope is the
                                 ; happy path, per its "callable standalone"
                                 ; framing in the implementation plan)
        ret
.number:
        call COMPILE_NUMBER_LITERAL
        call LEX_NEXT_TOKEN
        ret
.ident:
        call COMPILE_IDENT_LOAD
        call LEX_NEXT_TOKEN
        ret

COMPILE_NUMBER_LITERAL:
        ld de,(TOK_VAL)
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
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        cp 9
        jr c,.len_ok
        ld a,8                  ; truncate to 8 (documented R2 limitation)
.len_ok:
        ld b,a
        call CSYM_FIND_OR_CREATE
        ld (IDENT_LOAD_INDEX),a
        call EMIT_BYTE_OP_LOAD_VAR
        ld a,(IDENT_LOAD_INDEX)
        call EMIT_BYTE
        ret

; ===========================================================================
; STATEMENT COMPILER (R2 scope: assignment only)
; ===========================================================================
COMPILE_ASSIGN:
        ; entry: TOK_TYPE=TOK_IDENT, TOK_NAME/TOK_LEN describe the target
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        cp 9
        jr c,.len_ok
        ld a,8
.len_ok:
        ld b,a
        call CSYM_FIND_OR_CREATE
        ld (ASSIGN_TARGET_INDEX),a   ; memory, not a register — see the
                                       ; equ's own comment for why
        call LEX_NEXT_TOKEN     ; consume the identifier
        ld a,(TOK_TYPE)
        cp TOK_ASSIGN
        jr z,.have_assign
        ld a,2
        ld (COMPILE_ERROR_CODE),a
        ret
.have_assign:
        call LEX_NEXT_TOKEN     ; consume '='
        call COMPILE_EXPR
        call EMIT_BYTE_OP_STORE_VAR
        ld a,(ASSIGN_TARGET_INDEX)
        call EMIT_BYTE
        ret

; ===========================================================================
; PROGRAM COMPILER — repeated assignment statements separated by ':',
; terminated by EOF, followed by a HALT opcode.
; ===========================================================================
COMPILE_PROGRAM:
        call LEX_NEXT_TOKEN
.loop:
        ld a,(TOK_TYPE)
        cp TOK_EOF
        jr z,.done
        cp TOK_IDENT
        jr nz,.done              ; anything else ends compilation cleanly in
                                  ; this R2 scope (no error statements exist
                                  ; yet to dispatch to)
        call COMPILE_ASSIGN
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        ld a,(TOK_TYPE)
        cp TOK_COLON
        jr nz,.done
        call LEX_NEXT_TOKEN
        jr .loop
.done:
        call EMIT_OP_HALT
        ret

COMPILER_END:

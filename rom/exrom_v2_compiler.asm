; ============================================================================
; rom/exrom_v2_compiler.asm — Architecture B, R2+R3: production compiler
; (tokenizer/lexer + expression compiler + assignment/GOTO/IF/FOR/NEXT
; statement compilers + a real label table and forward-reference fixup
; mechanism), targeting R1's real, hardware-validated VM
; (rom/exrom_v2_vm_core.asm, 17 integer-domain opcodes, 731 real bytes).
;
; 2068-Leap V2 rewrite. R2 (assignment-only) is real-hardware-validated —
; see docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R2 section. This
; revision adds R3's scope: GOTO, IF...THEN GOTO, FOR/NEXT, and the label/
; fixup mechanism GOTO's forward references need. Promotes
; spikes/v2_vm_sizing/statement_compiler_spike.asm's branch/loop/fixup
; architecture to production quality (that spike's fixup routines were
; explicitly stubbed — count-only, no real label table or patch-writing —
; per docs/v2/STATEMENT_COMPILER_SPIKE.md's own "honest residual
; uncertainty" section; this file's `LABEL_DEFINE`/`LABEL_LOOKUP`/
; `FIXUP_RECORD`/`RESOLVE_ALL_FIXUPS` are real). Procedures (`CALL`/`RET`)
; remain R4's scope, per the implementation plan's own staging, even
; though R1's VM already supports them — R3 is scoped narrower on purpose.
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
; ============================================================================
; *** STANDING CONVENTION — READ THIS BEFORE ADDING OR EDITING ANY CODE ***
;
;   NEVER KEEP A VALUE LIVE IN A REGISTER ACROSS A `call`.
;   Save it to a dedicated memory scratch cell FIRST, reload it AFTER.
;
; This is not a style preference — it is the single most-repeated real bug
; class in this entire rewrite, found via actual ZEsarUX execution FIVE
; separate times across R2/R3/R5/R6 (see docs/v2/
; ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R2/R3/R5/R6 sections for the full
; account of each: R2's assignment-target-in-C, R2's load-opcode-clobbering-
; the-index, R3's RESOLVE_ALL_FIXUPS counter, R3's COMPILE_NEXT offset, R5's
; FOUR string-op instances, R6's THREE float instances — this file and its
; VM-core counterpart, rom/exrom_v2_vm_core.asm, share this exact history).
; Every instance had the same shape: a routine that "looks safe" to call —
; nothing about its name or call site hints otherwise — turns out to use
; HL/DE/BC/AF as its OWN internal scratch, silently destroying whatever the
; caller was holding there (e.g. EMIT_BYTE uses HL as EMIT_PTR internally;
; VM_STR_ADDR/VM_POP use DE internally; VM_FLOAT_ADDR/CALC_SP_TO_NEXT_
; FREE_PTR use DE/HL internally).
;
; Before writing `call SOMETHING` with a value you still need afterward in
; a register: (1) check that callee's own header comment for a "Destroys:"
; line — if it doesn't have one, read its body before trusting it; (2) if
; in ANY doubt, save the value to memory first regardless. This matters
; MORE, not less, in R7 onward: platform routines (graphics/sprite/sound/
; input) are exactly this kind of register-heavy helper this bug class
; thrives on, and most of them predate this rewrite and were never audited
; for it.
; ============================================================================
;
; Grammar this compiler accepts (R2+R3 scope):
;   program    := statement (':' statement)* EOF
;   statement  := IDENT ':'                          (label definition)
;               | IDENT '=' expr                     (assignment)
;               | 'GOTO' IDENT                        (branch, R3)
;               | 'IF' expr 'THEN' 'GOTO' IDENT        (conditional branch, R3
;                 — block IF/ENDIF is deferred, per the implementation
;                 plan's own staging)
;               | 'FOR' IDENT '=' expr 'TO' expr       (loop start, R3 —
;                 fixed STEP=1, matching R1's VM's own FOR_NEXT opcode;
;                 SINGLE ACTIVE LOOP ONLY, matching R1's VM's own single
;                 VM_FOR_LIMIT slot — nested FOR/NEXT is a documented
;                 limitation, not a silent gap, see the loop-compiler
;                 section's own header note below)
;               | 'NEXT' IDENT                         (loop end, R3)
;               | 'PROC' IDENT '(' IDENT ')' ':' statement (':' statement)*
;                 'ENDP'                               (procedure decl, R4 —
;                 one by-value parameter, no separate local-variable frame;
;                 see the procedure-compiler section's own header note)
;               | 'CALL' IDENT '(' expr ')'             (procedure call, R4)
;   expr       := term (('+' | '-') term)*
;   term       := factor (('*' | '/') factor)*
;   factor     := NUMBER | IDENT | '(' expr ')'
;   IDENT      := letter+ (up to 8 characters; longer names are truncated,
;                 not rejected — a documented limitation, not a crash;
;                 GOTO/IF/THEN/FOR/TO/NEXT/PROC/ENDP/CALL are reserved and
;                 cannot be used as variable/label names, per
;                 LEX_CLASSIFY_KEYWORD)
;   NUMBER     := digit+ (encoded PUSH_I8 if 0-255, else PUSH_I16)
;
; Compile-time error codes (COMPILE_ERROR_CODE, set on any compile failure):
;   0  = no error
;   1  = symbol table full (more than CSYMTAB_MAX_ENTRIES distinct names)
;   2  = expected '=' after identifier in a statement
;   3  = unexpected character (factor could not start an expression)
;   5  = label table full (more than LABELTAB_MAX_ENTRIES distinct labels)
;   6  = fixup table full (more than FIXUPTAB_MAX_ENTRIES outstanding
;        forward references at once — all resolved in one pass at the end,
;        so this is a "how many distinct forward-referenced labels can be
;        outstanding simultaneously" bound, not a total-GOTO-count bound)
;   7  = undefined label (a GOTO/IF...THEN GOTO/CALL referenced a name that
;        was never defined as a label or procedure anywhere in the program)
;   8  = expected THEN after an IF condition
;   9  = expected GOTO after THEN (block IF is not yet supported — see the
;        grammar above)
;   10 = expected a loop variable after FOR or NEXT
;   11 = expected TO after a FOR loop's initial value
;   12 = expected a label name after GOTO (or after IF...THEN GOTO)
;   13 = expected a procedure name after CALL
;   14 = expected '(' after a CALL's procedure name
;   15 = expected ')' after a CALL's argument
;   16 = unterminated PROC (hit EOF instead of ENDP)
;   17 = expected a procedure name after PROC
;   18 = expected '(' after a PROC's procedure name
;   19 = expected a parameter name after PROC's '('
;   20 = expected ')' after a PROC's parameter name
;   21 = expected ':' before a PROC's body
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

; --- R3 additions: labels, forward-reference fixups, FOR/NEXT loop state ---
LABEL_COUNT:        equ $8B11   ; number of labels defined so far
LABELTAB_BASE:      equ $8A00   ; [name_len:1][name:8][offset:2] = 11B/entry
LABEL_REC_LEN:       equ 11
LABELTAB_MAX_ENTRIES: equ 8

FIXUP_COUNT:        equ $8B12   ; number of outstanding forward-reference fixups
FIXUPTAB_BASE:      equ $8A60   ; [patch_addr:2][name_len:1][name:8] = 11B/entry
FIXUP_REC_LEN:       equ 11
FIXUPTAB_MAX_ENTRIES: equ 8

LABEL_FIND_NAME_PTR: equ $8B17  ; LABEL_LOOKUP/LABEL_DEFINE scratch (2 bytes)
LABEL_FIND_NAME_LEN: equ $8B19  ; (1 byte) — same "must be RAM, not
                                  ; register-or-inline-data" discipline as
                                  ; CSYM_FIND_NAME_PTR/LEN above
LABEL_LOOKUP_RESULT: equ $8B1A  ; LABEL_LOOKUP output (2 bytes): resolved
                                  ; offset if found
FOR_LOOP_TOP_OFFSET: equ $8B1C  ; COMPILE_FOR/COMPILE_NEXT scratch (2 bytes):
                                  ; the loop body's starting bytecode offset.
                                  ; SINGLE ACTIVE LOOP ONLY — matches R1's VM
                                  ; core's own single VM_FOR_LIMIT slot
                                  ; (rom/exrom_v2_vm_core.asm's header
                                  ; comment). Nested FOR/NEXT is a KNOWN,
                                  ; DOCUMENTED limitation of this milestone,
                                  ; not silently unsupported — a future
                                  ; refinement would need both this compiler
                                  ; and the VM's loop-limit storage to become
                                  ; a real stack, not a single scalar. R3's
                                  ; own worked examples (REWRITE_RAM_BUDGET.md's
                                  ; SMALL/TYPICAL programs) do not require
                                  ; nested loops, so this scope cut does not
                                  ; block R3's actual success gate.
FOR_LOOP_VAR_INDEX: equ $8B1E    ; COMPILE_FOR/COMPILE_NEXT scratch (1 byte)
BRANCH_PATCH_TMP:   equ $8B1F   ; COMPILE_BRANCH_TARGET scratch (2 bytes)
FIXUP_PATCH_TMP:    equ $8B21   ; FIXUP_RECORD scratch (2 bytes)
FIXUP_NAME_PTR_TMP: equ $8B23   ; FIXUP_RECORD scratch (2 bytes)
FIXUP_NAME_LEN_TMP: equ $8B25   ; FIXUP_RECORD scratch (1 byte)
RESOLVE_PATCH_TMP:  equ $8B26   ; RESOLVE_ALL_FIXUPS scratch (2 bytes)
STMT_IDENT_NAME_PTR: equ $8B28  ; COMPILE_PROGRAM scratch (2 bytes): the
                                  ; current statement's leading identifier
                                  ; name, saved BEFORE the one-token
                                  ; lookahead that decides label-def vs.
                                  ; assignment overwrites TOK_NAME
STMT_IDENT_NAME_LEN: equ $8B2A   ; (1 byte)
RESOLVE_FIXUP_INDEX: equ $8B2B   ; RESOLVE_ALL_FIXUPS scratch (1 byte) —
                                  ; see that routine's own comment for why
                                  ; this must be memory, not just C
FOR_NEXT_HIGH_TMP:   equ $8B2C   ; COMPILE_NEXT scratch (1 byte) — see that
                                   ; routine's own comment for why
IF_SKIP_PATCH_TMP:   equ $8B2D   ; COMPILE_IF scratch (2 bytes): the
                                   ; false-branch's own patch address,
                                   ; distinct from BRANCH_PATCH_TMP (the
                                   ; true-branch's target)
PROC_SKIP_PATCH_TMP: equ $8B2F   ; COMPILE_PROC scratch (2 bytes): the
                                   ; skip-over-the-body JMP's patch address
PROC_PARAM_INDEX_TMP: equ $8B31  ; COMPILE_PROC scratch (1 byte): the
                                   ; procedure's single parameter's symbol
                                   ; index, saved across the body compile

; --- R5 addition: string variables. A SEPARATE compile-time name table
; from CSYMTAB above — "A" (numeric) and "A$" (string) are different
; identifiers with independent index spaces, matching the runtime VM's
; own separate SYMTAB/STRTAB split (rom/exrom_v2_vm_core.asm). ---
STRSYM_COUNT:        equ $8B32  ; number of distinct string symbols
STRSYMTAB_BASE:      equ $8B60  ; compile-time string-symbol name table
STRSYM_REC_LEN:      equ 9      ; [name_len:1][name:8], same shape as CSYMTAB
STRSYMTAB_MAX_ENTRIES: equ 4    ; matches STRTAB_MAX_VARS in the VM core —
                                  ; the compiler and the VM must agree on
                                  ; this bound; it is not independently
                                  ; enforced by either side against the
                                  ; other, a documented coupling, not a gap
STRSYM_FIND_NAME_PTR: equ $8B33 ; STRSYM_FIND_OR_CREATE scratch (2 bytes)
STRSYM_FIND_NAME_LEN: equ $8B35 ; (1 byte)
CSTR_LIT_LEN_TMP:    equ $8B36  ; COMPILE_STR_FACTOR scratch (1 byte): a
                                  ; string literal's clamped length, saved
                                  ; across the EMIT_BYTE_OP_PUSH_STR_LIT
                                  ; call that would otherwise clobber A
CSTR_IDENT_INDEX_TMP: equ $8B37 ; COMPILE_STR_FACTOR scratch (1 byte): a
                                  ; string variable's resolved index, saved
                                  ; across the EMIT_BYTE_OP_PUSH_I16 call
CSTR_ASSIGN_TARGET_TMP: equ $8B38 ; COMPILE_STR_ASSIGN scratch (1 byte)

; --- R6 addition: decimal literals ---
CNUM_DIVISOR_TMP:   equ $8B39   ; LEX_SCAN_NUMBER scratch (2 bytes): running
                                  ; 10^(fractional digits) accumulator
TOK_FLOAT_DIVISOR:  equ $8B3B   ; token field (2 bytes): companion to
                                  ; TOK_VAL for a TOK_FLOAT_NUMBER token

; every one of the scratch cells above is real RAM (not a register
; held across a call, not inline ROM data) — the two bug classes this
; module has already found and fixed once each (docs/v2/
; ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R2 section) are treated as a
; standing discipline for every routine added in R3, not just the ones
; that already broke

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
; token 12 intentionally unused: an earlier version had a TOK_LABEL_DEF
; here, produced by the lexer via character-adjacency guessing. Removed —
; see LEX_SCAN_IDENT's and COMPILE_PROGRAM's own comments for why (a real
; bug, caught by a real ZEsarUX run). Label detection is now done purely
; by COMPILE_PROGRAM's one-token lookahead, using ordinary TOK_IDENT/
; TOK_COLON tokens.
TOK_KW_GOTO:        equ 13
TOK_KW_IF:          equ 14
TOK_KW_THEN:        equ 15
TOK_KW_FOR:         equ 16
TOK_KW_TO:          equ 17
TOK_KW_NEXT:        equ 18
TOK_LT:             equ 19   ; '<' — comparison operator (R3 addition)
TOK_KW_PROC:        equ 20   ; R4 addition
TOK_KW_ENDP:        equ 21
TOK_KW_CALL:        equ 22
TOK_STRING:         equ 23   ; a "quoted" string literal (R5 addition)
TOK_STR_IDENT:      equ 24   ; a NAME$ string-variable identifier (R5)
TOK_FLOAT_NUMBER:   equ 25   ; a decimal literal, e.g. "10.5" (R6 addition)
TOK_COMMA:          equ 26   ; ',' — argument separator (R7 addition,
                               ; needed for PLOT x,y; nothing before R7
                               ; had a multi-argument statement)
TOK_KW_CLS:         equ 27   ; R7 additions below: the graphics/system
TOK_KW_BORDER:      equ 28    ; command family
TOK_KW_INK:         equ 29
TOK_KW_PAPER:       equ 30
TOK_KW_PLOT:        equ 31
TOK_KW_LINE:        equ 32   ; R7 Phase 2: the REAL remainder of this
TOK_KW_BEEP:        equ 33    ; ROM's own graphics/system statement set
TOK_KW_SOUND:       equ 34    ; (checked against include/checker_
TOK_KW_POKE:        equ 35    ; keywords.inc, V1's own real, current
TOK_KW_PAUSE:       equ 36    ; dialect -- CIRCLE/FILL were removed from
TOK_KW_RANDOMISE:   equ 37    ; this ROM 2026-09-19 (ROM budget), DRAW/OUT
                               ; never existed here, and the real
                               ; keyword is RANDOMISE, not RANDOMIZE --
                               ; ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's
                               ; own R7 planning text, written before
                               ; this investigation, named the wrong set)

; ---------------------------------------------------------------------------
; COMPILER_INIT — call once before COMPILE_PROGRAM.
; ---------------------------------------------------------------------------
COMPILER_INIT:
        xor a
        ld (CSYM_COUNT),a
        ld (COMPILE_ERROR_CODE),a
        ld (LABEL_COUNT),a       ; R3 addition — an earlier version of this
        ld (FIXUP_COUNT),a       ; routine never zeroed these two, so a
        ld (STRSYM_COUNT),a      ; R5 addition — same bug, same fix,
                                  ; found again: a second compile within
                                  ; the same ZEsarUX session (RAM is NOT
                                  ; cleared by `reset`, only CPU registers
                                  ; are) inherited whatever LABEL_COUNT/
                                  ; FIXUP_COUNT/STRSYM_COUNT a prior run had
                                  ; left behind, producing
                                  ; duplicate-looking label-table entries
                                  ; and eventually a real "table full"
                                  ; error — caught by a real ZEsarUX run
                                  ; showing LABEL_COUNT=8 after only 2 real
                                  ; LABEL_DEFINE calls (confirmed via a
                                  ; write watchpoint), not by inspection
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
        cp '<'
        jr z,.single9
        cp ','
        jr z,.single10
        cp '"'
        jr z,.string_lit
        cp '0'
        jr c,.ident_start
        cp '9'+1
        jr c,.number
        jr .ident_start          ; letters and anything else above '9'
                                   ; fall through here — an earlier version
                                   ; had NO explicit jump here at all and
                                   ; instead relied on `.ident_start:`
                                   ; textually following these digit checks
                                   ; (true before this R5 addition), but
                                   ; inserting `.string_lit`'s own label
                                   ; between the digit checks and
                                   ; `.ident_start` silently redirected
                                   ; every letter into the string-literal
                                   ; scanner instead. Caught by a real
                                   ; ZEsarUX run: the very first identifier
                                   ; in the test program ("A$") was
                                   ; misread as a string literal starting
                                   ; mid-token. Fixed with an explicit jump
                                   ; rather than relying on adjacency again.
.ident_start:
        cp 'A'
        jr c,.unknown
        cp 'Z'+1
        jr nc,.unknown
        jp LEX_SCAN_IDENT
.string_lit:
        jp LEX_SCAN_STRING
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
.single9:
        ld a,TOK_LT
        jp .advance1
.single10:
        ld a,TOK_COMMA
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

; LEX_SCAN_NUMBER — R6 addition: also recognizes an optional '.' followed
; by more digits (a decimal literal). The integer and fractional digits
; accumulate into the SAME running value DE (i.e. "10.5" accumulates as
; if scanning "105"); a separate CNUM_DIVISOR_TMP tracks 10^(number of
; fractional digits seen), starting at 1 (meaning "no fractional part").
; If the divisor is still 1 when digit-scanning ends, this is a plain
; TOK_NUMBER (unchanged behavior, unchanged token type, for every program
; that predates R6); otherwise it's TOK_FLOAT_NUMBER, with TOK_VAL holding
; the digits and TOK_FLOAT_DIVISOR holding the divisor — COMPILE_FACTOR
; combines them into a real float at runtime via the calculator, not at
; compile time (this compiler never decodes or encodes the calculator's
; own float byte format itself).
LEX_SCAN_NUMBER:
        ld de,0
        ld hl,1
        ld (CNUM_DIVISOR_TMP),hl
.int_digit_loop:
        ld hl,(SRC_PTR)
        ld a,(hl)
        cp '0'
        jr c,.check_dot
        cp '9'+1
        jr nc,.check_dot
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
        jr .int_digit_loop
.check_dot:
        ld hl,(SRC_PTR)
        ld a,(hl)
        cp '.'
        jr nz,.done
        inc hl
        ld (SRC_PTR),hl
.frac_digit_loop:
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
        ld hl,(CNUM_DIVISOR_TMP)
        ld b,h
        ld c,l
        add hl,hl
        add hl,hl
        add hl,bc
        add hl,hl               ; divisor *= 10
        ld (CNUM_DIVISOR_TMP),hl
        jr .frac_digit_loop
.done:
        ld (TOK_VAL),de
        ld hl,(CNUM_DIVISOR_TMP)
        ld a,l
        cp 1
        jr nz,.is_float
        ld a,h
        or a
        jr nz,.is_float
        ld a,TOK_NUMBER
        ld (TOK_TYPE),a
        ret
.is_float:
        ld (TOK_FLOAT_DIVISOR),hl
        ld a,TOK_FLOAT_NUMBER
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
        ; Label detection is NOT done here (an earlier version checked for
        ; an immediately-following ':' right in the lexer — a real bug: an
        ; expression-internal identifier reference that happens to be
        ; immediately followed by a statement-separator ':', e.g. the
        ; "COUNT" in "TOTAL+COUNT:COUNT=COUNT+1", was misclassified as a
        ; label definition, silently eating the ':' and corrupting
        ; compilation. Caught by a real ZEsarUX run: COMPILE_ERROR_CODE=3
        ; with the second operand of an ADD missing from the emitted
        ; bytecode. Label definitions are now detected exclusively by
        ; COMPILE_PROGRAM's own one-token lookahead at genuine statement
        ; boundaries — see that routine — never by the lexer guessing from
        ; character adjacency, which cannot distinguish "statement start"
        ; from "the middle of an expression" on its own.)
        ;
        ; R5 addition: a trailing '$' (no space, matching classic BASIC's
        ; own NAME$ string-variable convention) makes this a TOK_STR_IDENT
        ; instead of a plain TOK_IDENT — a distinct token type, not a flag
        ; on the same one, so every existing dispatch site that only
        ; expects TOK_IDENT is structurally unaffected by strings existing
        ; at all. Keyword classification is skipped for string identifiers
        ; (no keyword in this grammar ends in '$').
        ld a,(hl)
        cp '$'
        jr nz,.plain_ident
        inc hl
        ld (SRC_PTR),hl
        ld a,b
        ld (TOK_LEN),a
        ld a,TOK_STR_IDENT
        ld (TOK_TYPE),a
        ret
.plain_ident:
        ld (SRC_PTR),hl
        ld a,b
        ld (TOK_LEN),a
        ld a,TOK_IDENT
        ld (TOK_TYPE),a
        call LEX_CLASSIFY_KEYWORD
        ret

; LEX_SCAN_STRING — a "quoted" string literal (R5 addition). No escape
; sequences (a documented happy-path gap, matching this project's own
; established scope discipline for every milestone so far). An
; unterminated string (EOF before a closing '"') stops at EOF rather than
; consuming past it — a real, deliberate bounds check, not an oversight.
LEX_SCAN_STRING:
        ld hl,(SRC_PTR)
        inc hl                   ; skip the opening '"'
        ld (TOK_NAME),hl
        ld b,0
.loop:
        ld a,(hl)
        cp '"'
        jr z,.done
        or a
        jr z,.done               ; unterminated: stop at EOF, don't consume it
        inc hl
        inc b
        jr .loop
.done:
        ld a,(hl)
        cp '"'
        jr nz,.no_skip           ; stopped at EOF, not a real closing quote
        inc hl
.no_skip:
        ld (SRC_PTR),hl
        ld a,b
        ld (TOK_LEN),a
        ld a,TOK_STRING
        ld (TOK_TYPE),a
        ret

; LEX_CLASSIFY_KEYWORD — if TOK_NAME/TOK_LEN spell one of GOTO/IF/THEN/FOR/
; TO/NEXT exactly, overrides TOK_TYPE to that keyword's token type. Real
; table-driven match (length check + full byte-for-byte compare — never a
; first-letter shortcut, so e.g. "FOO" is never misclassified as FOR).
;
; An earlier version of this routine was an ad-hoc chain of length-guarded
; branches (try GOTO, then NEXT, then IF, then TO, then THEN, then FOR).
; It had a real, live bug: the length-4 branch tried GOTO, and on failure
; jumped straight to a NEXT check that unconditionally returned on its own
; failure — THEN (also length 4) was dead code, never reachable, for any
; input. Caught by a real ZEsarUX run: every "IF...THEN GOTO" in a real
; compiled program failed with COMPILE_ERROR_CODE=8 ("expected THEN"),
; because "THEN" was never actually recognized as a keyword at all — it
; lexed as a perfectly ordinary 4-letter identifier instead. Rewritten as a
; real table loop specifically so this class of "one candidate's failure
; path forgets to fall through to the next candidate" bug structurally
; cannot happen again — the loop tries every entry unconditionally.
LEX_CLASSIFY_KEYWORD:
        ld hl,KEYWORD_TABLE
        ld b,KEYWORD_TABLE_COUNT
.loop:
        ld a,(TOK_LEN)
        cp (hl)                  ; stored length
        jr nz,.next
        push hl
        inc hl                    ; -> keyword text
        ld de,(TOK_NAME)
        ld c,a                    ; C = length to compare
.cmp_loop:
        ld a,(de)
        cp (hl)                  ; CP only supports (hl), not (de)
        jr nz,.cmp_fail
        inc hl
        inc de
        dec c
        jr nz,.cmp_loop
        ; match: the token-type byte sits 10 bytes past the entry's start
        ; (1 length byte + 9 text bytes, fixed width regardless of the
        ; keyword's real length — widened from 6 to 9 in R7 Phase 2 to
        ; fit "RANDOMISE", the longest keyword this compiler recognizes
        ; so far)
        pop hl
        ld de,10
        add hl,de
        ld a,(hl)
        ld (TOK_TYPE),a
        ret
.cmp_fail:
        pop hl
.next:
        ld de,KEYWORD_ENTRY_LEN
        add hl,de
        dec b
        jr nz,.loop
        ret                       ; no match — TOK_TYPE stays TOK_IDENT

KEYWORD_ENTRY_LEN:  equ 11        ; [len:1][text:9, unused tail ignored][token:1]
KEYWORD_TABLE_COUNT: equ 20

; Every row is exactly KEYWORD_ENTRY_LEN (11) bytes: [len][9 text bytes,
; zero-padded][token]. Generated and byte-counted mechanically (a Python
; one-liner, not by hand) after R7 Phase 2 widened this table for the
; second time (4->6->9 text bytes) — the R7 Phase 1 version of this table
; had a real, self-caught padding-count bug in this same spot (PAPER's
; row was one zero byte short) found by re-deriving every row's zero
; count programmatically instead of trusting manual arithmetic a second
; time.
KEYWORD_TABLE:
        db 4, "GOTO", 0, 0, 0, 0, 0, TOK_KW_GOTO
        db 2, "IF", 0, 0, 0, 0, 0, 0, 0, TOK_KW_IF
        db 2, "TO", 0, 0, 0, 0, 0, 0, 0, TOK_KW_TO
        db 4, "THEN", 0, 0, 0, 0, 0, TOK_KW_THEN
        db 3, "FOR", 0, 0, 0, 0, 0, 0, TOK_KW_FOR
        db 4, "NEXT", 0, 0, 0, 0, 0, TOK_KW_NEXT
        db 4, "PROC", 0, 0, 0, 0, 0, TOK_KW_PROC
        db 4, "ENDP", 0, 0, 0, 0, 0, TOK_KW_ENDP
        db 4, "CALL", 0, 0, 0, 0, 0, TOK_KW_CALL
        db 3, "CLS", 0, 0, 0, 0, 0, 0, TOK_KW_CLS      ; R7 Phase 1
        db 6, "BORDER", 0, 0, 0, TOK_KW_BORDER
        db 3, "INK", 0, 0, 0, 0, 0, 0, TOK_KW_INK
        db 5, "PAPER", 0, 0, 0, 0, TOK_KW_PAPER
        db 4, "PLOT", 0, 0, 0, 0, 0, TOK_KW_PLOT
        db 4, "LINE", 0, 0, 0, 0, 0, TOK_KW_LINE       ; R7 Phase 2
        db 4, "BEEP", 0, 0, 0, 0, 0, TOK_KW_BEEP
        db 5, "SOUND", 0, 0, 0, 0, TOK_KW_SOUND
        db 4, "POKE", 0, 0, 0, 0, 0, TOK_KW_POKE
        db 5, "PAUSE", 0, 0, 0, 0, TOK_KW_PAUSE
        db 9, "RANDOMISE", TOK_KW_RANDOMISE

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
; COMPILE-TIME STRING SYMBOL TABLE (R5 addition) — identical shape and
; register discipline to CSYM_FIND_OR_CREATE/CSYM_ENTRY_ADDR above, over a
; separate name table (STRSYMTAB_BASE) and count (STRSYM_COUNT), since
; string identifiers ("A$") are a distinct namespace from numeric ones
; ("A") — reusing the proven register discipline directly rather than
; re-deriving it, since that discipline is exactly what R2/R3's real bugs
; were about getting right.
; ===========================================================================

; STRSYM_FIND_OR_CREATE — input: HL = name pointer, B = name length (1-8,
; longer names are truncated to 8 by the caller before this is reached).
; Output: A = symbol index (0-based). Sets COMPILE_ERROR_CODE=1 and returns
; A=0 if the table is full and the name isn't already present.
STRSYM_FIND_OR_CREATE:
        ld (STRSYM_FIND_NAME_PTR),hl
        ld a,b
        ld (STRSYM_FIND_NAME_LEN),a
        ld c,0                  ; C = index being checked
.scan_loop:
        ld a,c
        push hl
        ld hl,STRSYM_COUNT
        cp (hl)
        pop hl
        jr z,.not_found          ; reached the count: no match exists
        ; compare STRSYMTAB_BASE + c*9's stored name against (name_ptr,name_len)
        push bc
        call STRSYM_ENTRY_ADDR    ; input: C = index; output: HL = entry addr
        ld a,(hl)                ; stored name_len
        pop bc
        cp b
        jr nz,.next
        ; lengths match; compare up to B bytes
        push hl
        inc hl                   ; -> stored name bytes
        ld de,(STRSYM_FIND_NAME_PTR)
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
        ld a,(STRSYM_COUNT)
        cp STRSYMTAB_MAX_ENTRIES
        jr nz,.create
        ld a,1
        ld (COMPILE_ERROR_CODE),a
        xor a
        ret
.create:
        ld a,(STRSYM_COUNT)
        ld c,a
        call STRSYM_ENTRY_ADDR    ; HL = new entry's address
        ld a,(STRSYM_FIND_NAME_LEN)
        ld (hl),a
        inc hl
        ld de,(STRSYM_FIND_NAME_PTR)
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
        ld a,(STRSYM_COUNT)
        inc a
        ld (STRSYM_COUNT),a
        ld a,c
        ret


; STRSYM_ENTRY_ADDR — input: C = index; output: HL = STRSYMTAB_BASE + index*9.
STRSYM_ENTRY_ADDR:
        ld l,c
        ld h,0                  ; HL = index
        ld d,h
        ld e,l                  ; DE = index
        add hl,hl               ; *2
        add hl,hl               ; *4
        add hl,hl               ; *8
        add hl,de               ; *9
        ld de,STRSYMTAB_BASE
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
EMIT_OP_JMP:               ld a,6  : jp EMIT_BYTE
EMIT_OP_JMPZ:              ld a,12 : jp EMIT_BYTE
EMIT_OP_FOR_INIT:          ld a,13 : jp EMIT_BYTE
EMIT_OP_FOR_NEXT:          ld a,14 : jp EMIT_BYTE
EMIT_OP_CMP_LT:            ld a,10 : jp EMIT_BYTE
EMIT_OP_CMP_EQ:            ld a,11 : jp EMIT_BYTE
EMIT_OP_CALL:              ld a,15 : jp EMIT_BYTE
EMIT_OP_RET:               ld a,16 : jp EMIT_BYTE
EMIT_BYTE_OP_PUSH_STR_LIT: ld a,17 : jp EMIT_BYTE
EMIT_OP_STORE_STR_VAR:     ld a,18 : jp EMIT_BYTE
EMIT_OP_STR_CONCAT:        ld a,19 : jp EMIT_BYTE
EMIT_OP_STR_CMP_LT:        ld a,20 : jp EMIT_BYTE
EMIT_OP_STR_CMP_EQ:        ld a,21 : jp EMIT_BYTE
EMIT_BYTE_OP_PUSH_FLOAT_LIT: ld a,22 : jp EMIT_BYTE
EMIT_OP_CLS:                ld a,23 : jp EMIT_BYTE
EMIT_OP_BORDER:              ld a,24 : jp EMIT_BYTE
EMIT_OP_INK:                 ld a,25 : jp EMIT_BYTE
EMIT_OP_PAPER:                ld a,26 : jp EMIT_BYTE
EMIT_OP_PLOT:                 ld a,27 : jp EMIT_BYTE
EMIT_OP_LINE:                  ld a,28 : jp EMIT_BYTE
EMIT_OP_BEEP:                   ld a,29 : jp EMIT_BYTE
EMIT_OP_SOUND:                   ld a,30 : jp EMIT_BYTE
EMIT_OP_POKE:                     ld a,31 : jp EMIT_BYTE
EMIT_OP_PAUSE:                     ld a,32 : jp EMIT_BYTE
EMIT_OP_RANDOMISE:                  ld a,33 : jp EMIT_BYTE

; EMIT_PLACEHOLDER_16 — writes two dummy zero bytes (a forward-reference
; branch target not yet known), returns the ABSOLUTE address of the first
; of those two bytes in HL, for RESOLVE_ALL_FIXUPS to patch later.
EMIT_PLACEHOLDER_16:
        ld hl,(EMIT_PTR)
        push hl
        xor a
        call EMIT_BYTE
        call EMIT_BYTE
        pop hl
        ret

; ===========================================================================
; EXPRESSION COMPILER (real symbol resolution via CSYM_FIND_OR_CREATE, not
; a stub — this is the load-bearing difference from the sizing spike)
;
; comparison := additive (('<' | '=') additive)?     (R3 addition — a single
;               optional trailing comparison, not chained/associative,
;               matching classic BASIC's own IF-condition shape; needed so
;               IF's condition can be more than "any nonzero integer")
; additive   := term (('+' | '-') term)*
; ===========================================================================
COMPILE_EXPR:                   ; top level: comparison
        call COMPILE_ADDITIVE
        ld a,(TOK_TYPE)
        cp TOK_LT
        jr z,.do_lt
        cp TOK_ASSIGN            ; '=' doubles as equality inside an
                                  ; expression, same token classic BASIC
                                  ; reuses for assignment vs. comparison by
                                  ; context — COMPILE_ASSIGN/COMPILE_FOR
                                  ; already consume assignment's own '='
                                  ; themselves, before COMPILE_EXPR is ever
                                  ; called for their right-hand side, so any
                                  ; '=' COMPILE_EXPR itself sees is
                                  ; genuinely a comparison
        jr z,.do_eq
        ret
.do_lt:
        call LEX_NEXT_TOKEN
        call COMPILE_ADDITIVE
        call EMIT_OP_CMP_LT
        ret
.do_eq:
        call LEX_NEXT_TOKEN
        call COMPILE_ADDITIVE
        call EMIT_OP_CMP_EQ
        ret

COMPILE_ADDITIVE:
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
        cp TOK_FLOAT_NUMBER
        jr z,.float_number
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
.float_number:
        call COMPILE_FLOAT_LITERAL
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

; COMPILE_FLOAT_LITERAL — emits PUSH_FLOAT_LIT's 4-byte operand: TOK_VAL
; (the literal's digits) then TOK_FLOAT_DIVISOR (10^fractional-digits),
; both as plain 2-byte little-endian values. The VM computes value/
; divisor as a real float at runtime, via the calculator — this compiler
; never encodes a float itself.
COMPILE_FLOAT_LITERAL:
        call EMIT_BYTE_OP_PUSH_FLOAT_LIT
        ld de,(TOK_VAL)
        ld a,e
        call EMIT_BYTE
        ld a,d
        call EMIT_BYTE
        ld de,(TOK_FLOAT_DIVISOR)
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
; COMPILE_ASSIGN_CONTINUED — entry: STMT_IDENT_NAME_PTR/LEN describe the
; assignment target (saved by COMPILE_PROGRAM's dispatcher BEFORE its own
; one-token lookahead decided this statement isn't a label definition);
; TOK_TYPE is already the token immediately after the target identifier
; (typically TOK_ASSIGN) — the dispatcher's lookahead already fetched it,
; so this routine does NOT consume the identifier itself again. Splitting
; the routine this way (rather than having it re-read TOK_NAME/TOK_LEN and
; call LEX_NEXT_TOKEN itself, as an earlier version did) is what makes the
; label-vs-assignment lookahead unambiguous — see COMPILE_PROGRAM and
; LEX_SCAN_IDENT's own header comment for the real bug this replaced.
COMPILE_ASSIGN_CONTINUED:
        ld hl,(STMT_IDENT_NAME_PTR)
        ld a,(STMT_IDENT_NAME_LEN)
        cp 9
        jr c,.len_ok
        ld a,8
.len_ok:
        ld b,a
        call CSYM_FIND_OR_CREATE
        ld (ASSIGN_TARGET_INDEX),a   ; memory, not a register — see the
                                       ; equ's own comment for why
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
; STRING EXPRESSION/STATEMENT COMPILERS (R5 addition)
;
; str_expr   := str_factor ('+' str_factor)*      (concatenation chain —
;               only '+' for strings, no '-'/'*'/'/'
; str_factor := STRING | STR_IDENT
;
; A string "value" is always its STRTAB index, pushed as an ordinary
; TAG_INT 2-byte value via the existing PUSH_I16 opcode — see
; rom/exrom_v2_vm_core.asm's own R5 header note for why no new operand-
; stack tag was needed for this.
; ===========================================================================

COMPILE_STR_EXPR:
        call COMPILE_STR_FACTOR
.loop:
        ld a,(TOK_TYPE)
        cp TOK_PLUS
        jr nz,.done
        call LEX_NEXT_TOKEN
        call COMPILE_STR_FACTOR
        call EMIT_OP_STR_CONCAT
        jr .loop
.done:
        ret

COMPILE_STR_FACTOR:
        ld a,(TOK_TYPE)
        cp TOK_STRING
        jr z,.literal
        cp TOK_STR_IDENT
        jr z,.ident
        ld a,3                   ; unexpected character (factor could not
        ld (COMPILE_ERROR_CODE),a ; start a string expression)
        ret
.literal:
        ld a,(TOK_LEN)
        cp 32
        jr c,.lit_len_ok
        ld a,31                  ; clamp to the runtime record's real cap —
                                   ; the VM's own OP_PUSH_STR_LIT assumes
                                   ; this invariant already holds, per its
                                   ; own header note
.lit_len_ok:
        ld (CSTR_LIT_LEN_TMP),a
        call EMIT_BYTE_OP_PUSH_STR_LIT
        ld a,(CSTR_LIT_LEN_TMP)
        call EMIT_BYTE            ; the length byte
        ld de,(TOK_NAME)          ; DE, not HL — EMIT_BYTE uses HL
                                    ; internally as the EMIT_PTR pointer,
                                    ; clobbering it; an earlier version kept
                                    ; the source content pointer in HL
                                    ; across the copy loop's own EMIT_BYTE
                                    ; calls, so only the literal's first
                                    ; byte ever made it into the bytecode
                                    ; correctly — caught by a real ZEsarUX
                                    ; run decoding the actual compiled
                                    ; bytes (the sixth real register-
                                    ; clobber-across-an-EMIT_BYTE-call bug
                                    ; found this way across R2-R5; see
                                    ; COMPILE_NUMBER_LITERAL's own use of DE
                                    ; for the exact same reason, already
                                    ; correct since R2 — this routine just
                                    ; didn't follow that existing example)
        ld a,(CSTR_LIT_LEN_TMP)
        or a
        jr z,.lit_no_content
        ld b,a
.lit_copy_loop:
        ld a,(de)
        call EMIT_BYTE
        inc de
        djnz .lit_copy_loop
.lit_no_content:
        call LEX_NEXT_TOKEN
        ret
.ident:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        cp 9
        jr c,.len_ok
        ld a,8
.len_ok:
        ld b,a
        call STRSYM_FIND_OR_CREATE
        ld (CSTR_IDENT_INDEX_TMP),a
        call EMIT_BYTE_OP_PUSH_I16
        ld a,(CSTR_IDENT_INDEX_TMP)
        call EMIT_BYTE
        xor a
        call EMIT_BYTE            ; high byte: always 0, indices are small
        call LEX_NEXT_TOKEN
        ret

; COMPILE_STR_ASSIGN — STR_IDENT '=' str_expr
COMPILE_STR_ASSIGN:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        cp 9
        jr c,.len_ok
        ld a,8
.len_ok:
        ld b,a
        call STRSYM_FIND_OR_CREATE
        ld (CSTR_ASSIGN_TARGET_TMP),a
        call LEX_NEXT_TOKEN       ; consume the string identifier
        ld a,(TOK_TYPE)
        cp TOK_ASSIGN
        jr z,.have_assign
        ld a,2
        ld (COMPILE_ERROR_CODE),a
        ret
.have_assign:
        call LEX_NEXT_TOKEN       ; consume '='
        call COMPILE_STR_EXPR
        call EMIT_OP_STORE_STR_VAR
        ld a,(CSTR_ASSIGN_TARGET_TMP)
        call EMIT_BYTE
        ret

; ===========================================================================
; LABEL TABLE + FORWARD-REFERENCE FIXUPS (R3 addition)
;
; Register discipline for every routine below matches CSYM_FIND_OR_CREATE's
; already-validated pattern exactly (R2's own two real bugs were both
; "a value needed after a call was left in a register instead of memory" —
; treated as a standing rule here, not just a lesson for the routines that
; already broke).
; ===========================================================================

; LABEL_ENTRY_ADDR — input: C = index; output: HL = LABELTAB_BASE + index*11.
LABEL_ENTRY_ADDR:
        ld l,c
        ld h,0
        ld d,h
        ld e,l                  ; DE = index
        add hl,hl               ; *2
        add hl,hl               ; *4
        add hl,hl               ; *8
        add hl,de                ; *9
        add hl,de                ; *10
        add hl,de                ; *11
        ld de,LABELTAB_BASE
        add hl,de
        ret

; FIXUP_ENTRY_ADDR — input: C = index; output: HL = FIXUPTAB_BASE + index*11.
FIXUP_ENTRY_ADDR:
        ld l,c
        ld h,0
        ld d,h
        ld e,l
        add hl,hl
        add hl,hl
        add hl,hl
        add hl,de
        add hl,de
        add hl,de
        ld de,FIXUPTAB_BASE
        add hl,de
        ret

; LABEL_DEFINE — input: HL = name pointer, B = name length. Records the
; CURRENT EMIT_PTR, as an offset relative to VM_CODE_BASE, under this name.
LABEL_DEFINE:
        ld (LABEL_FIND_NAME_PTR),hl
        ld a,b
        ld (LABEL_FIND_NAME_LEN),a
        ld a,(LABEL_COUNT)
        cp LABELTAB_MAX_ENTRIES
        jr nz,.have_room
        ld a,5                  ; label table full
        ld (COMPILE_ERROR_CODE),a
        ret
.have_room:
        ld c,a
        call LABEL_ENTRY_ADDR   ; HL -> new entry
        ld a,(LABEL_FIND_NAME_LEN)
        ld (hl),a
        inc hl
        ld b,a
        ld de,(LABEL_FIND_NAME_PTR)
        or a
        jr z,.name_written
.copy_loop:
        ld a,(de)
        ld (hl),a
        inc hl
        inc de
        dec b
        jr nz,.copy_loop
.name_written:
        ; recompute the entry address fresh rather than trust HL's position
        ; after the variable-length copy loop above
        ld a,(LABEL_COUNT)
        ld c,a
        call LABEL_ENTRY_ADDR
        ld de,9
        add hl,de                ; -> offset field (past name_len + 8 name bytes)
        push hl                   ; save the offset field's address
        ld hl,(EMIT_PTR)
        ld de,VM_CODE_BASE
        or a
        sbc hl,de                 ; HL = relative offset
        ex de,hl                  ; DE = relative offset
        pop hl                    ; HL = offset field's address (restored)
        ld (hl),e
        inc hl
        ld (hl),d
        ld a,(LABEL_COUNT)
        inc a
        ld (LABEL_COUNT),a
        ret

; LABEL_LOOKUP — input: HL = name pointer, B = name length. Output: carry
; SET if found (LABEL_LOOKUP_RESULT holds the resolved relative offset),
; carry CLEAR if not found (not yet defined — caller records a fixup).
LABEL_LOOKUP:
        ld (LABEL_FIND_NAME_PTR),hl
        ld a,b
        ld (LABEL_FIND_NAME_LEN),a
        ld c,0
.scan_loop:
        ld a,c
        push hl
        ld hl,LABEL_COUNT
        cp (hl)
        pop hl
        jr z,.not_found
        push bc
        call LABEL_ENTRY_ADDR
        ld a,(hl)                ; stored name_len
        pop bc
        cp b
        jr nz,.next
        push hl
        inc hl
        ld de,(LABEL_FIND_NAME_PTR)
        ld a,b
        or a
        jr nz,.have_len
        pop hl
        jr .found_at_c
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
        jr .found_at_c
.cmp_fail:
        pop bc
        pop hl
        jr .next
.next:
        inc c
        jr .scan_loop
.found_at_c:
        ; recompute the entry address fresh, then read its offset field
        call LABEL_ENTRY_ADDR
        ld de,9
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (LABEL_LOOKUP_RESULT),de
        scf
        ret
.not_found:
        or a
        ret

; FIXUP_RECORD — input: HL = patch address (absolute RAM address), DE =
; label name pointer, B = label name length. Records a forward reference,
; resolved once by RESOLVE_ALL_FIXUPS at the end of compilation.
FIXUP_RECORD:
        ld (FIXUP_PATCH_TMP),hl
        ld (FIXUP_NAME_PTR_TMP),de
        ld a,b
        ld (FIXUP_NAME_LEN_TMP),a
        ld a,(FIXUP_COUNT)
        cp FIXUPTAB_MAX_ENTRIES
        jr nz,.have_room
        ld a,6                  ; fixup table full
        ld (COMPILE_ERROR_CODE),a
        ret
.have_room:
        ld c,a
        call FIXUP_ENTRY_ADDR   ; HL -> new entry
        ld de,(FIXUP_PATCH_TMP)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld a,(FIXUP_NAME_LEN_TMP)
        ld (hl),a
        inc hl
        ld b,a
        ld de,(FIXUP_NAME_PTR_TMP)
        or a
        jr z,.done
.copy_loop:
        ld a,(de)
        ld (hl),a
        inc hl
        inc de
        dec b
        jr nz,.copy_loop
.done:
        ld a,(FIXUP_COUNT)
        inc a
        ld (FIXUP_COUNT),a
        ret

; RESOLVE_ALL_FIXUPS — called once, at the end of COMPILE_PROGRAM. Patches
; every outstanding forward reference now that every label has been
; defined. Sets COMPILE_ERROR_CODE=7 (undefined label) and returns early
; if any fixup's label was never defined anywhere in the program.
RESOLVE_ALL_FIXUPS:
        ld c,0
.loop:
        ld a,c
        ld hl,FIXUP_COUNT
        cp (hl)
        ret z
        ld (RESOLVE_FIXUP_INDEX),a  ; save the OUTER loop's own fixup
                                     ; index in memory before calling
                                     ; LABEL_LOOKUP, which uses C as its
                                     ; own internal scan-index scratch and
                                     ; does not restore it — an earlier
                                     ; version kept this index only in C
                                     ; across that call, so a successful
                                     ; lookup (which naturally leaves C
                                     ; equal to whatever LABELTAB index it
                                     ; matched, not the fixup index) sent
                                     ; this loop into a bogus extra
                                     ; iteration over garbage fixup-table
                                     ; memory, producing a spurious
                                     ; "undefined label" error even though
                                     ; the real lookup had already
                                     ; succeeded and patched correctly.
                                     ; Root-caused by single-stepping the
                                     ; actual instruction sequence on real
                                     ; ZEsarUX hardware, not by inspection —
                                     ; the bug was invisible without
                                     ; watching C's value survive (or not)
                                     ; across the call.
        call FIXUP_ENTRY_ADDR   ; HL -> entry: [patch_lo][patch_hi][name_len][name...]
        ld e,(hl)
        inc hl
        ld d,(hl)                ; DE = patch address
        inc hl
        ld a,(hl)                ; name_len
        inc hl                    ; HL -> name bytes (LABEL_LOOKUP's own input)
        ld b,a                    ; B = name length (LABEL_LOOKUP's own input)
        ld (RESOLVE_PATCH_TMP),de
        call LABEL_LOOKUP
        jr nc,.undefined
        ld de,(RESOLVE_PATCH_TMP)
        ld hl,(LABEL_LOOKUP_RESULT)
        ld a,l
        ld (de),a
        inc de
        ld a,h
        ld (de),a
        ld a,(RESOLVE_FIXUP_INDEX)
        inc a
        ld c,a
        jr .loop
.undefined:
        ld a,7
        ld (COMPILE_ERROR_CODE),a
        ret

; ===========================================================================
; BRANCH STATEMENT COMPILERS (R3 addition: GOTO, IF...THEN GOTO)
; ===========================================================================

; COMPILE_BRANCH_TARGET — shared by COMPILE_GOTO and COMPILE_IF. Input:
; HL = the branch opcode's placeholder patch address (from
; EMIT_PLACEHOLDER_16); current token must be TOK_IDENT (the label name).
; Resolves immediately if the label is already defined (backward
; reference), otherwise records a fixup for RESOLVE_ALL_FIXUPS to patch
; later (forward reference).
COMPILE_BRANCH_TARGET:
        ld (BRANCH_PATCH_TMP),hl
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call LABEL_LOOKUP
        jr c,.resolved
        ld hl,(BRANCH_PATCH_TMP)
        ld de,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call FIXUP_RECORD
        call LEX_NEXT_TOKEN     ; consume the label identifier
        ret
.resolved:
        ld hl,(BRANCH_PATCH_TMP)
        ld de,(LABEL_LOOKUP_RESULT)
        ld (hl),e
        inc hl
        ld (hl),d
        call LEX_NEXT_TOKEN     ; consume the label identifier
        ret

; ===========================================================================
; PLATFORM INTEGRATION (R7 addition) — graphics/system command family.
; Each compiles "KEYWORD <expr>[,<expr>]" into: <expr bytecode>... then one
; native-call opcode, exactly the "parse N numeric args, emit one native-
; call opcode" shape docs/v2/STATEMENT_COMPILER_SPIKE.md's own sizing
; already assumed for this family. No new expression grammar needed —
; COMPILE_EXPR (already real since R2) handles every argument.
; ===========================================================================

; COMPILE_CLS — CLS (no arguments)
COMPILE_CLS:
        call LEX_NEXT_TOKEN     ; consume CLS
        call EMIT_OP_CLS
        ret

; COMPILE_BORDER / COMPILE_INK / COMPILE_PAPER — KEYWORD <expr>, one
; numeric argument, identical shape, differing only in which opcode gets
; emitted — same "shared body, thin per-keyword stub" precedent
; BASIC_STMT_INK/PAPER's own V1 implementation already established
; (basic.asm), applied here to the V2 compiler instead.
COMPILE_BORDER:
        call LEX_NEXT_TOKEN     ; consume BORDER
        call COMPILE_EXPR       ; argument -> VM operand stack
        call EMIT_OP_BORDER
        ret

COMPILE_INK:
        call LEX_NEXT_TOKEN     ; consume INK
        call COMPILE_EXPR
        call EMIT_OP_INK
        ret

COMPILE_PAPER:
        call LEX_NEXT_TOKEN     ; consume PAPER
        call COMPILE_EXPR
        call EMIT_OP_PAPER
        ret

; COMPILE_PLOT — PLOT <expr>,<expr>  (x, then y — matches V1's own
; BASIC_STMT_PLOT reading order; OP_PLOT's own header note explains why
; it pops y before x)
COMPILE_PLOT:
        call LEX_NEXT_TOKEN     ; consume PLOT
        call COMPILE_EXPR       ; x -> VM operand stack
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.have_comma
        ld a,22                  ; expected ',' between PLOT's x and y
        ld (COMPILE_ERROR_CODE),a
        ret
.have_comma:
        call LEX_NEXT_TOKEN     ; consume ','
        call COMPILE_EXPR       ; y -> VM operand stack
        call EMIT_OP_PLOT
        ret

; ===========================================================================
; R7 PHASE 2 — the real remainder of this ROM's own graphics/system
; statement set (checked against include/checker_keywords.inc, not
; against ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's own original R7
; planning text, which named CIRCLE/FILL/DRAW/OUT/RANDOMIZE — CIRCLE and
; FILL were removed from this ROM 2026-09-19 for ROM budget, DRAW/OUT
; never existed here, and the real keyword is RANDOMISE). Same shape as
; Phase 1's CLS/BORDER/INK/PAPER/PLOT throughout: parse N args via the
; already-real COMPILE_EXPR, emit one native-call opcode.
; ===========================================================================

; COMPILE_LINE — LINE <x0>,<y0> TO <x1>,<y1>  (matches V1's own
; BASIC_STMT_LINE/BASIC_PARSE_LINE_ARGS argument order and "TO" keyword)
COMPILE_LINE:
        call LEX_NEXT_TOKEN     ; consume LINE
        call COMPILE_EXPR       ; x0
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.have_comma1
        ld a,23                  ; expected ',' after LINE's x0
        ld (COMPILE_ERROR_CODE),a
        ret
.have_comma1:
        call LEX_NEXT_TOKEN     ; consume ','
        call COMPILE_EXPR       ; y0
        ld a,(TOK_TYPE)
        cp TOK_KW_TO
        jr z,.have_to
        ld a,24                  ; expected TO in LINE
        ld (COMPILE_ERROR_CODE),a
        ret
.have_to:
        call LEX_NEXT_TOKEN     ; consume TO
        call COMPILE_EXPR       ; x1
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.have_comma2
        ld a,25                  ; expected ',' after LINE's x1
        ld (COMPILE_ERROR_CODE),a
        ret
.have_comma2:
        call LEX_NEXT_TOKEN     ; consume ','
        call COMPILE_EXPR       ; y1
        call EMIT_OP_LINE
        ret

; COMPILE_BEEP — BEEP <duration>,<pitch>  (matches V1's own
; BASIC_STMT_BEEP argument order)
COMPILE_BEEP:
        call LEX_NEXT_TOKEN     ; consume BEEP
        call COMPILE_EXPR       ; duration
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.have_comma
        ld a,26                  ; expected ',' in BEEP
        ld (COMPILE_ERROR_CODE),a
        ret
.have_comma:
        call LEX_NEXT_TOKEN
        call COMPILE_EXPR       ; pitch
        call EMIT_OP_BEEP
        ret

; COMPILE_SOUND — SOUND <register>,<data>  (matches V1's own
; BASIC_STMT_SOUND argument order)
COMPILE_SOUND:
        call LEX_NEXT_TOKEN     ; consume SOUND
        call COMPILE_EXPR       ; register
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.have_comma
        ld a,26                  ; expected ',' in SOUND (same code as
                                   ; BEEP's -- both are "expected comma
                                   ; between a statement's two args",
                                   ; the same real condition either way)
        ld (COMPILE_ERROR_CODE),a
        ret
.have_comma:
        call LEX_NEXT_TOKEN
        call COMPILE_EXPR       ; data
        call EMIT_OP_SOUND
        ret

; COMPILE_POKE — POKE <address>,<value>  (matches V1's own
; BASIC_STMT_POKE argument order)
COMPILE_POKE:
        call LEX_NEXT_TOKEN     ; consume POKE
        call COMPILE_EXPR       ; address
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.have_comma
        ld a,26
        ld (COMPILE_ERROR_CODE),a
        ret
.have_comma:
        call LEX_NEXT_TOKEN
        call COMPILE_EXPR       ; value
        call EMIT_OP_POKE
        ret

; COMPILE_PAUSE — PAUSE <n>  (one argument, same shape as BORDER/INK/
; PAPER above)
COMPILE_PAUSE:
        call LEX_NEXT_TOKEN     ; consume PAUSE
        call COMPILE_EXPR
        call EMIT_OP_PAUSE
        ret

; COMPILE_RANDOMISE — RANDOMISE <n>
COMPILE_RANDOMISE:
        call LEX_NEXT_TOKEN     ; consume RANDOMISE
        call COMPILE_EXPR
        call EMIT_OP_RANDOMISE
        ret

; COMPILE_GOTO — GOTO <label>
COMPILE_GOTO:
        call LEX_NEXT_TOKEN     ; consume GOTO
        call EMIT_OP_JMP
        call EMIT_PLACEHOLDER_16   ; HL = patch address
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_target
        ld a,12                 ; expected a label name after GOTO
        ld (COMPILE_ERROR_CODE),a
        ret
.have_target:
        call COMPILE_BRANCH_TARGET
        ret

; COMPILE_IF — IF <expr> THEN GOTO <label>  (block IF/ENDIF is out of R3's
; scope, per the implementation plan's own staging)
; IF cond THEN GOTO label compiles as:
;   <cond>
;   JMPZ  <skip>          ; false -> skip over the GOTO entirely
;   JMP   <label>         ; true  -> take the branch
;   <skip>:               ; false fell through to here
; An earlier version emitted only the JMPZ, with the label's OWN resolved
; offset as its operand — backwards: JMPZ branches when the popped value
; IS zero, so that compiled "jump to label when the condition is FALSE",
; the opposite of "IF...THEN GOTO"'s meaning. Caught by decoding the real
; compiled bytecode after a real ZEsarUX run (VM_ERROR_CODE=1, illegal
; opcode, from branching to a nonsense address once the loop's inverted
; exit condition ran long enough) — not by inspection.
; COMPILE_IF's condition may be numeric (COMPILE_EXPR, unchanged) or a
; string comparison (R5 addition) — detected by peeking whether the
; condition's first token is a string-shaped factor (STRING or STR_IDENT);
; BASIC expressions are always either all-numeric or all-string, never
; mixed, so this one-token peek is sufficient and unambiguous.
COMPILE_IF:
        call LEX_NEXT_TOKEN     ; consume IF
        ld a,(TOK_TYPE)
        cp TOK_STRING
        jr z,.str_condition
        cp TOK_STR_IDENT
        jr z,.str_condition
        call COMPILE_EXPR       ; numeric condition (unchanged)
        jr .condition_done
.str_condition:
        call COMPILE_STR_EXPR
        ld a,(TOK_TYPE)
        cp TOK_LT
        jr z,.str_lt
        cp TOK_ASSIGN
        jr z,.str_eq
        ld a,3                   ; unexpected character (expected a string
        ld (COMPILE_ERROR_CODE),a ; comparison operator)
        ret
.str_lt:
        call LEX_NEXT_TOKEN
        call COMPILE_STR_EXPR
        call EMIT_OP_STR_CMP_LT
        jr .condition_done
.str_eq:
        call LEX_NEXT_TOKEN
        call COMPILE_STR_EXPR
        call EMIT_OP_STR_CMP_EQ
.condition_done:
        call EMIT_OP_JMPZ
        call EMIT_PLACEHOLDER_16   ; HL = patch address for the "skip" target
        ld (IF_SKIP_PATCH_TMP),hl
        ld a,(TOK_TYPE)
        cp TOK_KW_THEN
        jr z,.have_then
        ld a,8                   ; expected THEN
        ld (COMPILE_ERROR_CODE),a
        ret
.have_then:
        call LEX_NEXT_TOKEN     ; consume THEN
        ld a,(TOK_TYPE)
        cp TOK_KW_GOTO
        jr z,.have_goto
        ld a,9                   ; expected GOTO
        ld (COMPILE_ERROR_CODE),a
        ret
.have_goto:
        call LEX_NEXT_TOKEN     ; consume GOTO
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_target
        ld a,12
        ld (COMPILE_ERROR_CODE),a
        ret
.have_target:
        call EMIT_OP_JMP
        call EMIT_PLACEHOLDER_16   ; HL = patch address for the real target
        call COMPILE_BRANCH_TARGET ; resolves/fixups; also consumes the
                                     ; label identifier token
        ; patch the "skip" target to land HERE — right after the JMP —
        ; so a false condition falls through past the GOTO instead of
        ; taking it.
        ld hl,(EMIT_PTR)
        ld de,VM_CODE_BASE
        or a
        sbc hl,de                 ; HL = relative offset (current position)
        ex de,hl                  ; DE = relative offset
        ld hl,(IF_SKIP_PATCH_TMP)
        ld (hl),e
        inc hl
        ld (hl),d
        ret

; ===========================================================================
; LOOP STATEMENT COMPILERS (R3 addition: FOR/NEXT)
;
; SINGLE ACTIVE LOOP ONLY — matches R1's VM core's own single VM_FOR_LIMIT
; slot (rom/exrom_v2_vm_core.asm's own header comment on OP_FOR_INIT).
; Nested FOR/NEXT is a known, documented limitation, not a silent gap: a
; future refinement would need both this compiler's FOR_LOOP_TOP_OFFSET/
; FOR_LOOP_VAR_INDEX and the VM's VM_FOR_LIMIT to become real stacks. R3's
; own success gate (a real nontrivial program compiling and running,
; testing the compiled-branch/GOTO-catastrophe-fix claim at scale) does not
; require nested loops.
; ===========================================================================

; COMPILE_FOR — FOR <ident> = <expr> TO <expr>  (fixed STEP=1; explicit
; STEP is also deferred, matching R1's VM core's own FOR_NEXT opcode, which
; only supports STEP=1)
COMPILE_FOR:
        call LEX_NEXT_TOKEN     ; consume FOR
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_var
        ld a,10                  ; expected a loop variable
        ld (COMPILE_ERROR_CODE),a
        ret
.have_var:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call CSYM_FIND_OR_CREATE
        ld (FOR_LOOP_VAR_INDEX),a
        call LEX_NEXT_TOKEN     ; consume the identifier
        ld a,(TOK_TYPE)
        cp TOK_ASSIGN
        jr z,.have_assign
        ld a,2
        ld (COMPILE_ERROR_CODE),a
        ret
.have_assign:
        call LEX_NEXT_TOKEN     ; consume '='
        call COMPILE_EXPR       ; initial value -> VM operand stack
        ld a,(TOK_TYPE)
        cp TOK_KW_TO
        jr z,.have_to
        ld a,11                  ; expected TO
        ld (COMPILE_ERROR_CODE),a
        ret
.have_to:
        call LEX_NEXT_TOKEN     ; consume TO
        call COMPILE_EXPR       ; limit value -> VM operand stack
        call EMIT_OP_FOR_INIT
        ld a,(FOR_LOOP_VAR_INDEX)
        call EMIT_BYTE
        ld hl,(EMIT_PTR)
        ld de,VM_CODE_BASE
        or a
        sbc hl,de                ; HL = loop body's start, relative offset
        ld (FOR_LOOP_TOP_OFFSET),hl
        ret

; COMPILE_NEXT — NEXT <ident>
COMPILE_NEXT:
        call LEX_NEXT_TOKEN     ; consume NEXT
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_var
        ld a,10
        ld (COMPILE_ERROR_CODE),a
        ret
.have_var:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call CSYM_FIND_OR_CREATE   ; resolves to the SAME index as the
                                    ; matching FOR by construction (a real
                                    ; name lookup, not a separate mechanism)
                                    ; — this R3 scope does not separately
                                    ; verify the name matches the innermost
                                    ; open FOR, since only one loop can be
                                    ; active at a time anyway (see this
                                    ; section's header note)
        ld (FOR_LOOP_VAR_INDEX),a
        call LEX_NEXT_TOKEN     ; consume the identifier
        call EMIT_OP_FOR_NEXT
        ld a,(FOR_LOOP_VAR_INDEX)
        call EMIT_BYTE
        ld hl,(FOR_LOOP_TOP_OFFSET)
        ld a,h
        ld (FOR_NEXT_HIGH_TMP),a  ; EMIT_BYTE itself uses HL internally (as
                                    ; the EMIT_PTR pointer) — an earlier
                                    ; version kept this offset's high byte
                                    ; in H across the low byte's EMIT_BYTE
                                    ; call, which clobbers HL, so "ld a,h"
                                    ; afterward read EMIT_PTR's own high
                                    ; byte (e.g. $90) instead of the
                                    ; intended offset high byte ($00) —
                                    ; caught by a real ZEsarUX run: FOR_NEXT
                                    ; branched to a wildly wrong absolute
                                    ; address instead of the loop top,
                                    ; producing VM_ERROR_CODE=1 (illegal
                                    ; opcode) shortly after. Same bug class
                                    ; as COMPILE_ASSIGN's and
                                    ; COMPILE_IDENT_LOAD's earlier fixes —
                                    ; save to memory before any call that
                                    ; can clobber the register you still
                                    ; need.
        ld a,l
        call EMIT_BYTE
        ld a,(FOR_NEXT_HIGH_TMP)
        call EMIT_BYTE
        ret

; ===========================================================================
; PROGRAM COMPILER — dispatches each statement to the right compiler,
; separated by ':', terminated by EOF, followed by a HALT opcode and one
; final fixup-resolution pass.
; ===========================================================================
; COMPILE_STATEMENT_LIST — compiles statements separated by ':' until
; TOK_EOF or TOK_KW_ENDP, WITHOUT consuming either (the caller inspects
; TOK_TYPE afterward to tell which one it was — COMPILE_PROGRAM expects
; EOF; COMPILE_PROC's body expects ENDP and treats EOF as an error). Entry
; assumes the current token is already primed (the caller has already
; called LEX_NEXT_TOKEN at least once) — this is what lets the SAME
; routine serve both the top-level program and a procedure body, which
; enter it at different points in an already-in-progress token stream, not
; just "the next statement's real logic. Sharing one dispatch means a bug
; fixed here (like COMPILE_PROGRAM's earlier ones) is fixed everywhere a
; statement can appear, not just at the top level.
COMPILE_STATEMENT_LIST:
.loop:
        ld a,(TOK_TYPE)
        cp TOK_EOF
        jp z,.done
        cp TOK_KW_ENDP
        jp z,.done
        cp TOK_KW_GOTO
        jp z,.goto                ; jp, not jr -- R7's new dispatch clauses
                                    ; below pushed these existing handler
                                    ; bodies out of jr's +-127 range (a real
                                    ; assembler error caught at build time,
                                    ; not a runtime bug, but the same
                                    ; underlying lesson STATEMENT_COMPILER_
                                    ; SPIKE-era code already learned once:
                                    ; jp is the safe default for a branch
                                    ; whose target's distance isn't fixed
                                    ; for the file's whole lifetime)
        cp TOK_KW_IF
        jp z,.if
        cp TOK_KW_FOR
        jp z,.for
        cp TOK_KW_NEXT
        jp z,.next_stmt
        cp TOK_KW_PROC
        jp z,.proc
        cp TOK_KW_CALL
        jp z,.call_stmt
        cp TOK_KW_CLS
        jr z,.cls
        cp TOK_KW_BORDER
        jr z,.border
        cp TOK_KW_INK
        jr z,.ink
        cp TOK_KW_PAPER
        jr z,.paper
        cp TOK_KW_PLOT
        jr z,.plot
        cp TOK_KW_LINE
        jp z,.line
        cp TOK_KW_BEEP
        jp z,.beep
        cp TOK_KW_SOUND
        jp z,.sound
        cp TOK_KW_POKE
        jp z,.poke
        cp TOK_KW_PAUSE
        jp z,.pause
        cp TOK_KW_RANDOMISE
        jp z,.randomise
        cp TOK_IDENT
        jp z,.ident_stmt
        cp TOK_STR_IDENT
        jp z,.str_ident_stmt
        jp .done                  ; anything else ends compilation cleanly
                                   ; in this scope (no error-recovery exists
                                   ; yet — a later milestone's job)
.cls:
        call COMPILE_CLS
        jp .after_stmt
.border:
        call COMPILE_BORDER
        jp .after_stmt
.ink:
        call COMPILE_INK
        jp .after_stmt
.paper:
        call COMPILE_PAPER
        jp .after_stmt
.plot:
        call COMPILE_PLOT
        jp .after_stmt
.line:
        call COMPILE_LINE
        jp .after_stmt
.beep:
        call COMPILE_BEEP
        jp .after_stmt
.sound:
        call COMPILE_SOUND
        jp .after_stmt
.poke:
        call COMPILE_POKE
        jp .after_stmt
.pause:
        call COMPILE_PAUSE
        jp .after_stmt
.randomise:
        call COMPILE_RANDOMISE
        jp .after_stmt
.str_ident_stmt:
        call COMPILE_STR_ASSIGN
        jp .after_stmt
.ident_stmt:
        ; genuine one-token lookahead: save this identifier's name, then
        ; fetch the NEXT token. If it's ':', this was a label definition —
        ; the ':' is consumed as an ordinary TOK_COLON here, not specially
        ; by the lexer, so an expression-internal identifier immediately
        ; followed by a statement-separator ':' is never affected (this
        ; lookahead only ever runs at genuine statement start). Otherwise,
        ; the peeked token IS the token COMPILE_ASSIGN_CONTINUED needs as
        ; "whatever follows the target identifier" — no re-fetch needed.
        ld hl,(TOK_NAME)
        ld (STMT_IDENT_NAME_PTR),hl
        ld a,(TOK_LEN)
        ld (STMT_IDENT_NAME_LEN),a
        call LEX_NEXT_TOKEN
        ld a,(TOK_TYPE)
        cp TOK_COLON
        jr z,.label
        call COMPILE_ASSIGN_CONTINUED
        jp .after_stmt
.label:
        ld hl,(STMT_IDENT_NAME_PTR)
        ld a,(STMT_IDENT_NAME_LEN)
        ld b,a
        call LABEL_DEFINE
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        call LEX_NEXT_TOKEN        ; consume the ':', fetch the next
                                    ; statement's first token
        jp .loop
.goto:
        call COMPILE_GOTO
        jp .after_stmt
.if:
        call COMPILE_IF
        jp .after_stmt
.for:
        call COMPILE_FOR
        jp .after_stmt
.next_stmt:
        call COMPILE_NEXT
        jp .after_stmt
.proc:
        call COMPILE_PROC
        jp .after_stmt
.call_stmt:
        call COMPILE_CALL_STMT
.after_stmt:
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        ld a,(TOK_TYPE)
        cp TOK_COLON
        jr nz,.done
        call LEX_NEXT_TOKEN
        jp .loop
.done:
        ret

; COMPILE_PROGRAM — the top-level entry point. Primes the first token,
; compiles the whole program via COMPILE_STATEMENT_LIST (which must stop
; on EOF, not ENDP — a stray ENDP with no matching PROC is simply where
; compilation ends, in this scope's happy-path error handling), emits the
; final HALT, and resolves every outstanding forward reference.
COMPILE_PROGRAM:
        call LEX_NEXT_TOKEN
        call COMPILE_STATEMENT_LIST
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        call EMIT_OP_HALT
        call RESOLVE_ALL_FIXUPS
        ret

; ===========================================================================
; PROCEDURE STATEMENT COMPILERS (R4 addition: PROC/ENDP, CALL)
;
; PROC name(param) : <body> ENDP   compiles as:
;   JMP <skip>              ; sequential fall-through skips the whole body
;   <name label, defined HERE>:
;   STORE_VAR param         ; consumes the argument the caller pushed
;   <body statements>
;   RET
;   <skip>:                 ; sequential execution resumes here
;
; The procedure's own name is registered in the SAME label table GOTO
; uses (LABEL_DEFINE/LABEL_LOOKUP/FIXUP_RECORD) — a CALL to a
; not-yet-defined procedure (e.g. one PROC calling another declared later
; in the program) is resolved by the exact same forward-reference fixup
; mechanism as a forward GOTO, not a separate mechanism.
;
; One parameter, by value, matching this milestone's own scoped-down goal
; (`ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s R4: "by-value parameters,
; one level of locals" — the parameter is a plain symbol slot, overwritten
; on each call; there is no separate local-variable stack frame, keeping
; this proportionate to the modest committed scope rather than building a
; general activation-record system). Recursion is mechanically possible
; (R1's VM call stack is a real, bounds-checked stack, not a single
; scalar), but is not separately tested by this milestone.
; ===========================================================================

COMPILE_PROC:
        call LEX_NEXT_TOKEN     ; consume PROC
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_name
        ld a,17                  ; expected a procedure name
        ld (COMPILE_ERROR_CODE),a
        ret
.have_name:
        ld hl,(TOK_NAME)
        ld (STMT_IDENT_NAME_PTR),hl
        ld a,(TOK_LEN)
        ld (STMT_IDENT_NAME_LEN),a
        call LEX_NEXT_TOKEN     ; consume the procedure name
        call EMIT_OP_JMP
        call EMIT_PLACEHOLDER_16   ; HL = patch address for the skip-over
        ld (PROC_SKIP_PATCH_TMP),hl
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.have_lparen
        ld a,18                  ; expected '(' after procedure name
        ld (COMPILE_ERROR_CODE),a
        ret
.have_lparen:
        call LEX_NEXT_TOKEN     ; consume '('
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_param
        ld a,19                  ; expected a parameter name
        ld (COMPILE_ERROR_CODE),a
        ret
.have_param:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call CSYM_FIND_OR_CREATE
        ld (PROC_PARAM_INDEX_TMP),a
        call LEX_NEXT_TOKEN     ; consume the parameter name
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        ld a,20                  ; expected ')' after the parameter
        ld (COMPILE_ERROR_CODE),a
        ret
.have_rparen:
        call LEX_NEXT_TOKEN     ; consume ')'
        ld a,(TOK_TYPE)
        cp TOK_COLON
        jr z,.have_colon
        ld a,21                  ; expected ':' before the procedure body
        ld (COMPILE_ERROR_CODE),a
        ret
.have_colon:
        ; define the CALL-entry label HERE — at the bytecode position that
        ; consumes the caller's pushed argument — not at PROC's own
        ; position (where the skip-JMP lives, never a valid call target).
        ld hl,(STMT_IDENT_NAME_PTR)
        ld a,(STMT_IDENT_NAME_LEN)
        ld b,a
        call LABEL_DEFINE
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        call EMIT_BYTE_OP_STORE_VAR
        ld a,(PROC_PARAM_INDEX_TMP)
        call EMIT_BYTE
        call LEX_NEXT_TOKEN     ; consume ':', prime the body's first token
        call COMPILE_STATEMENT_LIST
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        ld a,(TOK_TYPE)
        cp TOK_KW_ENDP
        jr z,.have_endp
        ld a,16                  ; unterminated PROC (hit EOF, not ENDP)
        ld (COMPILE_ERROR_CODE),a
        ret
.have_endp:
        call EMIT_OP_RET
        ld hl,(EMIT_PTR)
        ld de,VM_CODE_BASE
        or a
        sbc hl,de                 ; HL = relative offset (current position)
        ex de,hl                  ; DE = relative offset
        ld hl,(PROC_SKIP_PATCH_TMP)
        ld (hl),e
        inc hl
        ld (hl),d
        call LEX_NEXT_TOKEN     ; consume ENDP, fetch whatever follows
        ret

; COMPILE_CALL_STMT — CALL name(arg)
;
; Deliberately does NOT reuse COMPILE_BRANCH_TARGET (GOTO/IF's shared
; resolver): that routine ends by consuming the label identifier token,
; which here has already been consumed earlier (to reach the argument
; expression and the closing ')') — reusing it verbatim would eat an extra
; token it shouldn't. The resolve/fixup logic itself (look up, patch
; immediately if found, else record a fixup) is duplicated in miniature
; rather than awkwardly parameterized, since it's small.
COMPILE_CALL_STMT:
        call LEX_NEXT_TOKEN     ; consume CALL
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_name
        ld a,13                  ; expected a procedure name after CALL
        ld (COMPILE_ERROR_CODE),a
        ret
.have_name:
        ld hl,(TOK_NAME)
        ld (STMT_IDENT_NAME_PTR),hl
        ld a,(TOK_LEN)
        ld (STMT_IDENT_NAME_LEN),a
        call LEX_NEXT_TOKEN     ; consume the procedure name
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.have_lparen
        ld a,14                  ; expected '(' after the procedure name
        ld (COMPILE_ERROR_CODE),a
        ret
.have_lparen:
        call LEX_NEXT_TOKEN     ; consume '('
        call COMPILE_EXPR       ; argument -> pushed onto the VM operand stack
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        ld a,15                  ; expected ')' after the argument
        ld (COMPILE_ERROR_CODE),a
        ret
.have_rparen:
        call LEX_NEXT_TOKEN     ; consume ')'
        call EMIT_OP_CALL
        call EMIT_PLACEHOLDER_16   ; HL = patch address
        ld (BRANCH_PATCH_TMP),hl
        ld hl,(STMT_IDENT_NAME_PTR)
        ld a,(STMT_IDENT_NAME_LEN)
        ld b,a
        call LABEL_LOOKUP
        jr c,.resolved
        ld hl,(BRANCH_PATCH_TMP)
        ld de,(STMT_IDENT_NAME_PTR)
        ld a,(STMT_IDENT_NAME_LEN)
        ld b,a
        call FIXUP_RECORD
        ret
.resolved:
        ld hl,(BRANCH_PATCH_TMP)
        ld de,(LABEL_LOOKUP_RESULT)
        ld (hl),e
        inc hl
        ld (hl),d
        ret

COMPILER_END:

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
;   9  = expected ELSE or ENDIF to close a block IF's own THEN/ELSE body
;        (R8.5 Group 3 -- was "expected GOTO after THEN" before block IF
;        existed; "THEN GOTO" is still supported unchanged, but anything
;        else after THEN now starts a block IF body instead of failing)
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
;   22 = expected ',' between PLOT's x and y
;   23 = expected ',' after LINE's x0
;   24 = expected TO in LINE
;   25 = expected ',' after LINE's x1
;   26 = retired (was "expected ',' in BEEP/SOUND/POKE" -- unified into
;        code 22, COMPILE_EXPECT_COMMA_EXPR's own code, once BEEP/
;        SOUND/POKE/PLOT/PALETTE all switched to that shared helper as
;        part of this milestone's own R10-class consolidation)
;   28 = expected ',' between an extension call's own arguments
;   29 = expected '(' after a built-in function name (R8.5 Group 1)
;   30 = expected ',' between a built-in function's own arguments
;   31 = expected ')' to close a built-in function call
;   32 = expected an identifier after DIM (R8.5 Group 4)
;   33 = expected '(' after a DIM array name
;   34 = DIM size must be a literal integer (a compile-time constant —
;        this dialect's arrays are statically sized, unlike V1's runtime-
;        evaluated DIM expression; a real, deliberate V2 simplification)
;   35 = DIM size must be >= 1
;   36 = DIM size exceeds ARRAY_MAX_ELEMS (the fixed runtime pool's own
;        per-array cap)
;   37 = expected ')' to close a DIM declaration
;   38 = array already DIM'd (redeclaring an existing array name is an
;        error, unlike a scalar, which is silently auto-vivified)
;   39 = array symbol table full (more than ARRSYMTAB_MAX_ENTRIES distinct
;        arrays declared)
;   40 = expected '(' after an array name used as a value
;   41 = expected ')' to close an array index
;   42 = array assignment target was never DIM'd
;   43 = expected an identifier or string identifier after INPUT
;   44 = expected FOR after EXIT
;   45 = too many EXIT FOR statements in one loop (more than
;        EXITFOR_MAX outstanding at once)
;   46 = expected '(' after DIMN (R8.5 Group 6)
;   47 = DIMN's argument is not a DIM'd array name
;   48 = expected ')' to close DIMN
; ============================================================================

; ---------------------------------------------------------------------------
; Compiler state. Placed by the including driver
; (rom/test_v2_compiler_r2.asm for now).
; ---------------------------------------------------------------------------
SRC_PTR:            equ $BA00   ; pointer into source text being compiled
EMIT_PTR:           equ $BA02   ; pointer into bytecode output buffer
TOK_TYPE:           equ $BA04   ; current token type (1 byte)
TOK_VAL:            equ $BA05   ; current token numeric value (2 bytes)
TOK_NAME:           equ $BA07   ; current token identifier text pointer (2B)
TOK_LEN:            equ $BA09   ; current token identifier length (1 byte)
COMPILE_ERROR_CODE: equ $BA0A   ; 0 = no error; see header for nonzero codes

CSYM_COUNT:         equ $BA0B   ; number of distinct compile-time symbols
IDENT_LOAD_INDEX:   equ $BA10   ; COMPILE_IDENT_LOAD scratch (1 byte) — same
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
ASSIGN_TARGET_INDEX: equ $BA0F  ; COMPILE_ASSIGN scratch (1 byte) — MUST be
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
CSYM_FIND_NAME_PTR: equ $BA0C   ; CSYM_FIND_OR_CREATE scratch (2 bytes) —
                                ; must be real RAM, not inline ROM data (an
                                ; earlier version of this file declared this
                                ; as `dw 0` in the code stream, which would
                                ; have been a silent no-op write to ROM once
                                ; assembled into a real ROM image — caught
                                ; before assembling, not at runtime)
CSYM_FIND_NAME_LEN: equ $BA0E   ; CSYM_FIND_OR_CREATE scratch (1 byte)
CSYMTAB_BASE:       equ $B800   ; compile-time symbol name table
CSYM_REC_LEN:       equ 9       ; [name_len:1][name:8]
CSYMTAB_MAX_ENTRIES: equ 16     ; bounded, per this module's R2 scope

; --- R3 additions: labels, forward-reference fixups, FOR/NEXT loop state ---
LABEL_COUNT:        equ $BA11   ; number of labels defined so far
LABELTAB_BASE:      equ $B900   ; [name_len:1][name:8][offset:2] = 11B/entry
LABEL_REC_LEN:       equ 11
LABELTAB_MAX_ENTRIES: equ 8

FIXUP_COUNT:        equ $BA12   ; number of outstanding forward-reference fixups
FIXUPTAB_BASE:      equ $B960   ; [patch_addr:2][name_len:1][name:8] = 11B/entry
FIXUP_REC_LEN:       equ 11
FIXUPTAB_MAX_ENTRIES: equ 8

LABEL_FIND_NAME_PTR: equ $BA17  ; LABEL_LOOKUP/LABEL_DEFINE scratch (2 bytes)
LABEL_FIND_NAME_LEN: equ $BA19  ; (1 byte) — same "must be RAM, not
                                  ; register-or-inline-data" discipline as
                                  ; CSYM_FIND_NAME_PTR/LEN above
LABEL_LOOKUP_RESULT: equ $BA1A  ; LABEL_LOOKUP output (2 bytes): resolved
                                  ; offset if found
FOR_LOOP_TOP_OFFSET: equ $BA1C  ; COMPILE_FOR/COMPILE_NEXT scratch (2 bytes):
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
FOR_LOOP_VAR_INDEX: equ $BA1E    ; COMPILE_FOR/COMPILE_NEXT scratch (1 byte)
BRANCH_PATCH_TMP:   equ $BA1F   ; COMPILE_BRANCH_TARGET scratch (2 bytes)
FIXUP_PATCH_TMP:    equ $BA21   ; FIXUP_RECORD scratch (2 bytes)
FIXUP_NAME_PTR_TMP: equ $BA23   ; FIXUP_RECORD scratch (2 bytes)
FIXUP_NAME_LEN_TMP: equ $BA25   ; FIXUP_RECORD scratch (1 byte)
RESOLVE_PATCH_TMP:  equ $BA26   ; RESOLVE_ALL_FIXUPS scratch (2 bytes)
STMT_IDENT_NAME_PTR: equ $BA28  ; COMPILE_PROGRAM scratch (2 bytes): the
                                  ; current statement's leading identifier
                                  ; name, saved BEFORE the one-token
                                  ; lookahead that decides label-def vs.
                                  ; assignment overwrites TOK_NAME
STMT_IDENT_NAME_LEN: equ $BA2A   ; (1 byte)
RESOLVE_FIXUP_INDEX: equ $BA2B   ; RESOLVE_ALL_FIXUPS scratch (1 byte) —
                                  ; see that routine's own comment for why
                                  ; this must be memory, not just C
FOR_NEXT_HIGH_TMP:   equ $BA2C   ; COMPILE_NEXT scratch (1 byte) — see that
                                   ; routine's own comment for why
IF_SKIP_PATCH_TMP:   equ $BA2D   ; COMPILE_IF scratch (2 bytes): the
                                   ; false-branch's own patch address,
                                   ; distinct from BRANCH_PATCH_TMP (the
                                   ; true-branch's target)
PROC_SKIP_PATCH_TMP: equ $BA2F   ; COMPILE_PROC scratch (2 bytes): the
                                   ; skip-over-the-body JMP's patch address
PROC_PARAM_INDEX_TMP: equ $BA31  ; COMPILE_PROC scratch (1 byte): the
                                   ; procedure's single parameter's symbol
                                   ; index, saved across the body compile

; --- R5 addition: string variables. A SEPARATE compile-time name table
; from CSYMTAB above — "A" (numeric) and "A$" (string) are different
; identifiers with independent index spaces, matching the runtime VM's
; own separate SYMTAB/STRTAB split (rom/exrom_v2_vm_core.asm). ---
STRSYM_COUNT:        equ $BA32  ; number of distinct string symbols
STRSYMTAB_BASE:      equ $BA60  ; compile-time string-symbol name table
STRSYM_REC_LEN:      equ 9      ; [name_len:1][name:8], same shape as CSYMTAB
STRSYMTAB_MAX_ENTRIES: equ 4    ; matches STRTAB_MAX_VARS in the VM core —
                                  ; the compiler and the VM must agree on
                                  ; this bound; it is not independently
                                  ; enforced by either side against the
                                  ; other, a documented coupling, not a gap
STRSYM_FIND_NAME_PTR: equ $BA33 ; STRSYM_FIND_OR_CREATE scratch (2 bytes)
STRSYM_FIND_NAME_LEN: equ $BA35 ; (1 byte)
CSTR_LIT_LEN_TMP:    equ $BA36  ; COMPILE_STR_FACTOR scratch (1 byte): a
                                  ; string literal's clamped length, saved
                                  ; across the EMIT_BYTE_OP_PUSH_STR_LIT
                                  ; call that would otherwise clobber A
CSTR_IDENT_INDEX_TMP: equ $BA37 ; COMPILE_STR_FACTOR scratch (1 byte): a
                                  ; string variable's resolved index, saved
                                  ; across the EMIT_BYTE_OP_PUSH_I16 call
CSTR_ASSIGN_TARGET_TMP: equ $BA38 ; COMPILE_STR_ASSIGN scratch (1 byte)

; --- R6 addition: decimal literals ---
CNUM_DIVISOR_TMP:   equ $BA39   ; LEX_SCAN_NUMBER scratch (2 bytes): running
                                  ; 10^(fractional digits) accumulator
TOK_FLOAT_DIVISOR:  equ $BA3B   ; token field (2 bytes): companion to
                                  ; TOK_VAL for a TOK_FLOAT_NUMBER token
CEXT_SLOT:          equ $BA3D   ; R7.5 (COMPILE_EXT_CALL) scratch, 1
CEXT_GEN:           equ $BA3E   ; byte each unless noted: the matched
CEXT_ARGCOUNT:      equ $BA3F   ; extension's own slot id/generation/
CEXT_REMAINING:     equ $BA40   ; argcount, and a countdown while
                                  ; compiling that many comma-separated
                                  ; argument expressions

; R8.5 Group 1 -- built-in (resident) function-call grammar. Same
; "resolve a name to a small compile-time index" idea R7.5's own
; extension registry uses, but simpler: no runtime generation check --
; resident functions are compiled in, never unloaded/reloaded.
BFN_FOUND_ARGCOUNT: equ $BA41   ; BUILTIN_FN_FIND's own output: the
                                  ; matched function's declared argcount
CFN_INDEX:          equ $BA42   ; COMPILE_FACTOR.fn_call scratch, 1 byte
CFN_ARGCOUNT:       equ $BA43   ; each: the matched function's own
CFN_REMAINING:      equ $BA44   ; index/argcount, and a countdown while
                                  ; compiling that many comma-separated
                                  ; argument expressions (same shape as
                                  ; CEXT_SLOT/CEXT_GEN/CEXT_ARGCOUNT/
                                  ; CEXT_REMAINING above, deliberately)
BFN_FOUND_ARGTYPE:  equ $BA58   ; R8.5 Group 6 -- BUILTIN_FN_FIND's own
                                  ; output: bits 0-1 = per-argument-
                                  ; position type (bit N set = argument N
                                  ; is a string expression, tested via
                                  ; the shared VM_TEST_ARGTYPE_BIT -- LEN/
                                  ; CODE/VAL originally used this as a
                                  ; flat 0/1 boolean, still correct for
                                  ; their own single argument); bit 7 =
                                  ; SET means this function's RESULT is a
                                  ; string (CHR$/STR$/UPPER$/LOWER$/
                                  ; LEFT$/RIGHT$/INKEY$), clear means
                                  ; numeric (every function through Group
                                  ; 6's original LEN/CODE/VAL). Placed in
                                  ; the free gap
                                  ; between EXITFOR_PATCH_TABLE ($BA50 +
                                  ; 4*2=8 bytes = $BA58) and STRSYMTAB_
                                  ; BASE ($BA60) -- every byte from $BA41
                                  ; through $BA57 is already spoken for.
CFN_ARGTYPE:        equ $BA59   ; COMPILE_FACTOR.fn_call's own copy of
                                  ; the above, same shape as CFN_INDEX/
                                  ; CFN_ARGCOUNT/CFN_REMAINING
CEXT_ARGTYPES:      equ $BA5A   ; R8.5 (generic typed extension args,
                                  ; printer-package ROM reconciliation)
                                  ; -- COMPILE_EXT_CALL's own copy of the
                                  ; matched extension's argtypes bitmask
                                  ; (one bit per argument position, bit
                                  ; N set = argument N is a STRING
                                  ; expression; same "0=numeric,1=string"
                                  ; convention BFN_FOUND_ARGTYPE/
                                  ; CFN_ARGTYPE already established for
                                  ; BUILTIN_FN, generalized here to
                                  ; multiple argument positions since an
                                  ; extension can have several arguments
                                  ; of different types, unlike a single-
                                  ; argument built-in function)
DIMN_SIZE_TMP:      equ $BA5B   ; R8.5 Group 6 (DIMN) -- COMPILE_DIMN's
                                  ; own copy of ARR_SIZE_TMP (ARRSYM_
                                  ; LOOKUP's own output), parked here
                                  ; before LEX_NEXT_TOKEN gets a chance
                                  ; to run (same "copy a shared scratch
                                  ; cell immediately, don't trust it to
                                  ; survive a call" discipline this
                                  ; whole rewrite keeps needing).

; R8.5 Group 3 -- block IF/ELSE/ENDIF.
IF_ELSE_SKIP_PATCH_TMP: equ $BA45  ; COMPILE_IF_BLOCK scratch (2 bytes):
                                     ; the "skip the ELSE body" JMP's own
                                     ; patch address, same role as
                                     ; PROC_SKIP_PATCH_TMP above but for
                                     ; the THEN-body's own trailing jump

; R8.5 Group 4 -- DIM/array grammar. Arrays are a SEPARATE compile-time
; name table from CSYMTAB/STRSYMTAB (own lexical namespace, like strings
; are) because "already DIM'd" is checked, unlike a scalar's silent
; auto-vivification. Sizes are compile-time-constant literals only (a
; real, deliberate V2 simplification vs. V1's runtime-evaluated DIM
; expression) — this is what makes a fixed-stride runtime pool
; (rom/exrom_v2_vm_core.asm's ARRTAB) possible with no allocator at all,
; the same "resolve to a small index at compile time" philosophy this
; whole rewrite already uses for scalars/strings/labels.
ARRSYM_COUNT:        equ $BA47   ; number of distinct arrays DIM'd so far
ARRSYM_FIND_NAME_PTR: equ $BA48  ; ARRSYM_FIND_OR_CREATE/ARRSYM_LOOKUP
ARRSYM_FIND_NAME_LEN: equ $BA4A   ; scratch (2+1 bytes) — same "must be
                                    ; real RAM" discipline as CSYM_FIND_
                                    ; NAME_PTR/LEN above
ARR_SIZE_TMP:        equ $BA4B   ; COMPILE_DIM's own validated size /
                                    ; ARRSYM_LOOKUP's found-array size
                                    ; output (1 byte)
CARR_INDEX:          equ $BA4C   ; COMPILE_ARRAY_ASSIGN/COMPILE_FACTOR's
CARR_SIZE:           equ $BA4D    ; own array-read scratch (1 byte each):
                                    ; the matched array's runtime index and
                                    ; declared size, saved to memory BEFORE
                                    ; compiling the index/value sub-
                                    ; expressions (which themselves call
                                    ; ARRSYM_LOOKUP/CSYM_FIND_OR_CREATE and
                                    ; would otherwise clobber ARR_SIZE_TMP/
                                    ; ARRSYM_FIND_NAME_PTR — same bug class
                                    ; as ASSIGN_TARGET_INDEX's own header)
CINPUT_INDEX_TMP:     equ $BA4E   ; COMPILE_INPUT scratch (1 byte): the
                                    ; resolved target's index, saved to
                                    ; memory before EMIT_BYTE -- a fresh
                                    ; dedicated cell rather than reusing
                                    ; IDENT_LOAD_INDEX/CSTR_IDENT_INDEX_TMP,
                                    ; after two real memory-cell-aliasing
                                    ; bugs already found this session (see
                                    ; the decompiler's own DECOMP_TMP_LEN/
                                    ; DECOMP_EMIT_CHAR bug this same
                                    ; milestone) — not worth the risk to
                                    ; save one equ.
EXITFOR_COUNT:        equ $BA4F  ; R8.5 Group 5 -- number of outstanding
                                    ; EXIT FOR patch addresses for the
                                    ; loop CURRENTLY being compiled, reset
                                    ; to 0 at COMPILE_FOR's own start (no
                                    ; nesting support — same single-
                                    ; active-loop scope FOR/NEXT already
                                    ; has — so this never needs to be
                                    ; saved/restored across a nested loop)
EXITFOR_PATCH_TABLE:  equ $BA50   ; free gap between EXITFOR_COUNT and
                                    ; STRSYMTAB_BASE ($BA60) — 4 slots *
                                    ; 2 bytes = 8 bytes, checked directly
                                    ; against every other v2 file's own
                                    ; equ's before placing this
EXITFOR_MAX:          equ 4
ARRSYMTAB_BASE:       equ $B890   ; compile-time array name table (free
                                    ; gap between CSYMTAB_BASE+16*9=$B890
                                    ; and LABELTAB_BASE=$B900 — checked
                                    ; directly against every other v2 file's
                                    ; own equ's before placing this)
ARRSYM_REC_LEN:       equ 10      ; [name_len:1][name:8][size:1]
ARRSYMTAB_MAX_ENTRIES: equ 4      ; MUST match rom/exrom_v2_vm_core.asm's
                                    ; own ARRAY_MAX_COUNT — an array's
                                    ; ARRSYMTAB creation order (0-based) IS
                                    ; its runtime ARRTAB slot index, baked
                                    ; directly into OP_ARR_LOAD/STORE's own
                                    ; operand byte at compile time
; ARRAY_MAX_ELEMS itself is NOT redefined here -- rom/exrom_v2_vm_core.asm
; already defines it, and every v2 test file includes that module before
; this one (the same established cross-file equ-sharing convention this
; compiler already relies on for VM_CODE_BASE); a second `equ` with the
; same name is a real duplicate-label build error, not a style choice.

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
TOK_KW_PRINT:       equ 38   ; R8.5 additions below: the text I/O
TOK_KW_LPRINT:      equ 39    ; system, plus END/STOP/REM (see docs/v2/
TOK_KW_END:         equ 40     ; ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's
TOK_KW_STOP:        equ 41      ; own R8.5 section for the real capability
TOK_KW_REM:         equ 42       ; audit this covers)
; R8.5 Group 3 -- the full relop set (this dialect only ever had '<' and
; '=' before) plus AND/OR/NOT.
TOK_GT:             equ 43   ; '>'
TOK_LE:             equ 44   ; '<='
TOK_GE:             equ 45   ; '>='
TOK_NE:             equ 46   ; '<>'
TOK_KW_AND:         equ 47
TOK_KW_OR:          equ 48
TOK_KW_NOT:         equ 49
TOK_KW_ELSE:        equ 50   ; block IF's own ELSE (ELSEIF compiles as
                               ; "ELSE IF", not a separate keyword --
                               ; matches this dialect's existing "no
                               ; special-cased grammar shapes" preference)
TOK_KW_ENDIF:       equ 51
TOK_KW_DIM:         equ 52   ; R8.5 Group 4 -- array declaration
TOK_KW_INPUT:       equ 53   ; R8.5 Group 2 -- closed out late (see the
                               ; implementation plan's own status note)
TOK_KW_STEP:        equ 54   ; R8.5 Group 5 -- FOR...STEP
TOK_KW_EXIT:        equ 55   ; R8.5 Group 5 -- EXIT FOR (V1's own real
                               ; grammar is "EXIT FOR", not bare EXIT --
                               ; confirmed against basic.asm's own
                               ; BASIC_STMT_EXIT header)
; TOK_KW_MODE/ULAPLUS/PALETTE (56-58) removed -- these are no longer
; resident statement keywords (product decision, same principle as the
; earlier SPRITE-to-loadable-module move). Token values 56-58 are now
; unused, kept unassigned rather than renumbered (nothing else depends
; on token-value contiguity).

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
        ld (ARRSYM_COUNT),a      ; R8.5 Group 4 addition — same bug class,
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
        cp $0D
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
        cp '>'
        jr z,.gt_start
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
        ; R8.5 Group 3 -- '<' now needs one character of lookahead: '<='
        ; and '<>' are both real relops this dialect never supported
        ; before (only bare '<' and '=' existed). Bare '<' remains the
        ; fallback, unchanged.
        ld hl,(SRC_PTR)
        inc hl
        ld a,(hl)
        cp '='
        jr z,.lt_eq
        cp '>'
        jr z,.lt_gt
        ld a,TOK_LT
        jp .advance1
.lt_eq:
        ld a,TOK_LE
        jp .advance2
.lt_gt:
        ld a,TOK_NE
        jp .advance2
.gt_start:
        ; R8.5 Group 3 -- '>' didn't exist as a token at all before this;
        ; '>=' is the only two-character form.
        ld hl,(SRC_PTR)
        inc hl
        ld a,(hl)
        cp '='
        jr z,.gt_eq
        ld a,TOK_GT
        jp .advance1
.gt_eq:
        ld a,TOK_GE
        jp .advance2
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
.advance2:
        ld (TOK_TYPE),a
        ld hl,(SRC_PTR)
        inc hl
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

; R8 identifier cleanup: a leading letter, then any mix of letters and
; DIGITS (classic BASIC's own convention -- "A1", "TOTAL2", "P3" are
; all valid identifiers; a digit still can't START one, since the
; lexer's own caller only reaches LEX_SCAN_IDENT after already deciding
; the current character looks like an identifier start). Previously
; letters-only -- first surfaced as a real, load-bearing gap during
; R7.5 (this compiler's own decompiler synthesizes names like "V0"/"L25"
; that were NOT re-lexable by this SAME compiler without this fix,
; breaking R8's own decompile-then-recompile round-trip claim) and
; again this session (a PROC named "ADD1" failed to compile at all).
LEX_SCAN_IDENT:
        ld hl,(SRC_PTR)
        ld (TOK_NAME),hl
        ld b,0
.loop:
        ld a,(hl)
        cp 'A'
        jr c,.maybe_digit
        cp 'Z'+1
        jr nc,.maybe_digit
        inc hl
        inc b
        jr .loop
.maybe_digit:
        ld a,b
        or a
        jr z,.done            ; a digit can't START an identifier
        ld a,(hl)
        cp '0'
        jr c,.done
        cp '9'+1
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
; VARIABLE-STRIDE table (bounded ROM consolidation pass): each row is
; now exactly [len:1][text:len][token:1], no fixed-width zero padding
; -- the OLD fixed-11-byte-per-row layout (padded to fit "RANDOMISE",
; the longest keyword) wasted (9-real_len) bytes on every SHORTER
; keyword ("IF"/"TO"/"OR" each wasted 7 of their own 11 bytes), 169
; bytes of pure padding across all 34 rows, real-measured via a direct
; before/after size comparison. The scan below tracks each row's own
; real length in C throughout (both to compare text AND, on ANY
; mismatch -- wrong length or a failed char compare partway through --
; to skip however many text bytes remain unconsumed plus the trailing
; token byte, landing exactly on the next row). B remains the untouched
; OUTER row counter throughout (only C is used for the inner per-
; character work), same B/C separation this file's own COMPILE_EXT_
; CALL-family code already relies on elsewhere.
LEX_CLASSIFY_KEYWORD:
        ld hl,KEYWORD_TABLE
        ld b,KEYWORD_TABLE_COUNT
.loop:
        ld a,(hl)                ; A = this row's own real length
        inc hl                    ; HL -> keyword text
        ld c,a                    ; C = length (full row length here;
                                     ; becomes "remaining unconsumed"
                                     ; once the compare loop starts)
        ld a,(TOK_LEN)
        cp c
        jr nz,.skip                ; length mismatch -- C already holds
                                     ; the full row length to skip
        ld de,(TOK_NAME)
        ld a,c
        or a
        jr z,.matched                ; zero-length keyword (never
                                        ; occurs in practice; kept safe)
.cmp_loop:
        ld a,(de)
        cp (hl)                  ; CP only supports (hl), not (de)
        jr nz,.skip                ; mismatch partway through -- C
                                     ; already holds the remaining
                                     ; unconsumed length to skip
        inc hl
        inc de
        dec c
        jr nz,.cmp_loop
.matched:
        ; HL is now exactly at the token byte (text-start + the row's
        ; own real length) -- no fixed offset to add, unlike the old
        ; padded layout.
        ld a,(hl)
        ld (TOK_TYPE),a
        ret
.skip:
        ld a,c
        or a
        jr z,.skip_done
        inc hl
        dec c
        jr .skip
.skip_done:
        inc hl                    ; skip the token byte too -- HL now
                                     ; -> the next row's own length byte
        dec b
        jr nz,.loop
        ret                       ; no match — TOK_TYPE stays TOK_IDENT

KEYWORD_TABLE_COUNT: equ 34

; Each row is [len:1][text:len][token:1], variable-stride (bounded ROM
; consolidation pass -- converted from a fixed-11-byte padded layout
; via a Python one-liner, not by hand, 169 bytes of pure zero-padding
; recovered; see LEX_CLASSIFY_KEYWORD's own header for the real scan
; this needs). The OLD fixed-width layout's own R7 Phase 1 version had
; a real, self-caught padding-count bug in this same spot (PAPER's row
; was one zero byte short) -- moot now that there is no padding to
; miscount.
KEYWORD_TABLE:
        db 4, "GOTO", TOK_KW_GOTO
        db 2, "IF", TOK_KW_IF
        db 2, "TO", TOK_KW_TO
        db 4, "THEN", TOK_KW_THEN
        db 3, "FOR", TOK_KW_FOR
        db 4, "NEXT", TOK_KW_NEXT
        db 4, "PROC", TOK_KW_PROC
        db 4, "ENDP", TOK_KW_ENDP
        db 4, "CALL", TOK_KW_CALL
        db 3, "CLS", TOK_KW_CLS      ; R7 Phase 1
        db 6, "BORDER", TOK_KW_BORDER
        db 3, "INK", TOK_KW_INK
        db 5, "PAPER", TOK_KW_PAPER
        db 4, "PLOT", TOK_KW_PLOT
        db 4, "LINE", TOK_KW_LINE       ; R7 Phase 2
        db 4, "BEEP", TOK_KW_BEEP
        db 5, "SOUND", TOK_KW_SOUND
        db 4, "POKE", TOK_KW_POKE
        db 5, "PAUSE", TOK_KW_PAUSE
        db 9, "RANDOMISE", TOK_KW_RANDOMISE
        db 5, "PRINT", TOK_KW_PRINT        ; R8.5
        db 6, "LPRINT", TOK_KW_LPRINT
        db 3, "END", TOK_KW_END
        db 4, "STOP", TOK_KW_STOP
        db 3, "REM", TOK_KW_REM
        db 3, "AND", TOK_KW_AND      ; R8.5 Group 3
        db 2, "OR", TOK_KW_OR
        db 3, "NOT", TOK_KW_NOT
        db 4, "ELSE", TOK_KW_ELSE
        db 5, "ENDIF", TOK_KW_ENDIF
        db 3, "DIM", TOK_KW_DIM       ; R8.5 Group 4
        db 5, "INPUT", TOK_KW_INPUT          ; R8.5 Group 2
        db 4, "STEP", TOK_KW_STEP          ; R8.5 Group 5
        db 4, "EXIT", TOK_KW_EXIT
        ; MODE/ULAPLUS/PALETTE keyword rows removed (product decision,
        ; same principle as the earlier SPRITE-to-loadable-module move):
        ; these are now a loadable extension package (rom/ext_mode_
        ; module.asm), reached via the ordinary TOK_IDENT/extension-
        ; registry dispatch path (COMPILE_EXT_CALL), not resident
        ; statement keywords.

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
        IFDEF V2_PRODUCTION
        ; Stop at the first byte beyond the reserved bytecode region.
        ; Once full, keep EMIT_PTR stationary so later emit attempts
        ; cannot corrupt resident VM state while the parser unwinds.
        push af
        push de
        ld hl,(EMIT_PTR)
        ld de,V2_CODE_LIMIT
        or a
        sbc hl,de
        jr c,.space
        pop de
        pop af
        push af
        ld a,55              ; production bytecode capacity exceeded
        ld (COMPILE_ERROR_CODE),a
        pop af
        ret
.space:
        pop de
        pop af
        ENDIF
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
EMIT_OP_CALL_EXT:                     ld a,34 : jp EMIT_BYTE
EMIT_OP_PRINT_NUM:                      ld a,35 : jp EMIT_BYTE  ; R8.5
EMIT_OP_PRINT_STR:                       ld a,36 : jp EMIT_BYTE
EMIT_OP_CALL_FN:                            ld a,39 : jp EMIT_BYTE  ; R8.5 Group 1
EMIT_OP_ARR_LOAD:                           ld a,48 : jp EMIT_BYTE  ; R8.5 Group 4
EMIT_OP_ARR_STORE:                          ld a,49 : jp EMIT_BYTE  ; R8.5 Group 4
EMIT_OP_INPUT_NUM:                          ld a,50 : jp EMIT_BYTE  ; R8.5 Group 2
EMIT_OP_INPUT_STR:                          ld a,51 : jp EMIT_BYTE  ; R8.5 Group 2
EMIT_OP_CMP_LE:                              ld a,40 : jp EMIT_BYTE  ; R8.5 Group 3
EMIT_OP_CMP_GT:                               ld a,41 : jp EMIT_BYTE
EMIT_OP_CMP_GE:                                ld a,42 : jp EMIT_BYTE
EMIT_OP_CMP_NE:                                 ld a,43 : jp EMIT_BYTE
EMIT_OP_AND:                                     ld a,44 : jp EMIT_BYTE
EMIT_OP_OR:                                       ld a,45 : jp EMIT_BYTE
EMIT_OP_NOT:                                       ld a,46 : jp EMIT_BYTE
EMIT_OP_JMP_ELSE:                                    ld a,47 : jp EMIT_BYTE  ; R8.5 Group 3
                                                       ; -- COMPILE_IF_BLOCK's own
                                                       ; else-skip jump. Runtime-
                                                       ; identical to plain JMP (same
                                                       ; VM_OP_TABLE entry, rom/
                                                       ; exrom_v2_vm_core.asm's own
                                                       ; header explains why), but a
                                                       ; DISTINCT opcode number so the
                                                       ; decompiler can tell it apart
                                                       ; from a bare user GOTO
                                                       ; unambiguously -- no heuristic
                                                       ; byte-pattern guessing needed.

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
; ===========================================================================
; R8.5 Group 3 -- boolean-OR is now COMPILE_EXPR's own top level (was
; COMPILE_RELATIONAL, i.e. bare comparison, before this milestone).
; Precedence, loosest to tightest: OR, AND, NOT, relational, additive,
; term, factor -- the usual order (NOT binds tighter than AND/OR, a
; relational binds tighter than NOT so "NOT A<B" parses as "NOT (A<B)",
; matching every mainstream BASIC's own convention, not "(NOT A)<B").
; ===========================================================================
COMPILE_EXPR:
        call COMPILE_BOOL_AND
.loop:
        ld a,(TOK_TYPE)
        cp TOK_KW_OR
        jr nz,.done
        call LEX_NEXT_TOKEN
        call COMPILE_BOOL_AND
        call EMIT_OP_OR
        jr .loop
.done:
        ret

COMPILE_BOOL_AND:
        call COMPILE_BOOL_NOT
.loop:
        ld a,(TOK_TYPE)
        cp TOK_KW_AND
        jr nz,.done
        call LEX_NEXT_TOKEN
        call COMPILE_BOOL_NOT
        call EMIT_OP_AND
        jr .loop
.done:
        ret

COMPILE_BOOL_NOT:
        ld a,(TOK_TYPE)
        cp TOK_KW_NOT
        jr nz,COMPILE_RELATIONAL
        call LEX_NEXT_TOKEN
        call COMPILE_BOOL_NOT   ; recurses on itself, not COMPILE_RELATIONAL
                                  ; directly, so "NOT NOT X" (double
                                  ; negation) also parses, same reasoning
                                  ; COMPILE_FACTOR's own unary-minus
                                  ; recursion already uses
        call EMIT_OP_NOT
        ret

; COMPILE_RELATIONAL — bare comparison (was COMPILE_EXPR's own whole body
; before this milestone). The full relop set: <, <=, =, >=, >, <>.
COMPILE_RELATIONAL:
        call COMPILE_ADDITIVE
        ld a,(TOK_TYPE)
        cp TOK_LT
        jr z,.do_lt
        cp TOK_LE
        jr z,.do_le
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
        cp TOK_GE
        jr z,.do_ge
        cp TOK_GT
        jr z,.do_gt
        cp TOK_NE
        jr z,.do_ne
        ret
.do_lt:
        call LEX_NEXT_TOKEN
        call COMPILE_ADDITIVE
        call EMIT_OP_CMP_LT
        ret
.do_le:
        call LEX_NEXT_TOKEN
        call COMPILE_ADDITIVE
        call EMIT_OP_CMP_LE
        ret
.do_eq:
        call LEX_NEXT_TOKEN
        call COMPILE_ADDITIVE
        call EMIT_OP_CMP_EQ
        ret
.do_ge:
        call LEX_NEXT_TOKEN
        call COMPILE_ADDITIVE
        call EMIT_OP_CMP_GE
        ret
.do_gt:
        call LEX_NEXT_TOKEN
        call COMPILE_ADDITIVE
        call EMIT_OP_CMP_GT
        ret
.do_ne:
        call LEX_NEXT_TOKEN
        call COMPILE_ADDITIVE
        call EMIT_OP_CMP_NE
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

; R8.5 addition: unary minus. Binds to the immediate FACTOR (recurses
; into itself, not COMPILE_EXPR/COMPILE_TERM), matching standard
; precedence -- "-2*3" compiles as "(-2)*3", not "-(2*3)". No new
; opcode: "-X" compiles as "PUSH_I8 0" then X's own bytecode then SUB
; (0-X = -X), reusing the existing, already-correct int/float-promoting
; OP_SUB wholesale -- the same "no opcode is more correct than one
; that's just a spelling of an existing one" reasoning this session's
; own PRINT float-negation already used (VM_NUM_TO_TEXT's own header).
COMPILE_FACTOR:
        ld a,(TOK_TYPE)
        cp TOK_MINUS
        jr z,.unary_minus
        cp TOK_LPAREN
        jr z,.paren
        cp TOK_NUMBER
        jr z,.number
        cp TOK_FLOAT_NUMBER
        jr z,.float_number
        cp TOK_IDENT
        jr z,.ident
        ld a,3
        jp COMPILE_RAISE_ERROR
.unary_minus:
        call LEX_NEXT_TOKEN     ; consume '-'
        call EMIT_BYTE_OP_PUSH_I8
        xor a
        call EMIT_BYTE           ; push literal 0
        call COMPILE_FACTOR      ; the operand -X applies to
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        call EMIT_OP_SUB
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
        ; R8.5 Group 6 (DIMN) -- DIMN(name) returns an array's declared
        ; size, a real COMPILE-TIME CONSTANT (an array's size is fully
        ; known the moment DIM runs it through ARRSYM_FIND_OR_CREATE,
        ; long before this reference is ever compiled). Checked here,
        ; before BUILTIN_FN_FIND, because its own argument is a bare
        ; ARRAY NAME, not a general expression -- BUILTIN_FN_TABLE's
        ; grammar has no way to express that. Costs zero VM_CORE
        ; growth: the result folds straight into a PUSH_I8, no runtime
        ; opcode needed at all (unlike LEN/CODE/VAL etc).
        ld a,(TOK_LEN)
        cp 4
        jr nz,.not_dimn
        ld hl,(TOK_NAME)
        ld de,DIMN_KEYWORD_TEXT
        ld b,4
.dimn_cmp:
        ld a,(de)
        cp (hl)
        jr nz,.not_dimn
        inc hl
        inc de
        djnz .dimn_cmp
        jp COMPILE_DIMN
.not_dimn:
        call BUILTIN_FN_FIND
        jr nc,.not_builtin_fn
        ; R8.5 Group 6 (string-result functions) -- BUILTIN_FN_FIND
        ; matches on name TEXT alone, and a string-result function's
        ; name text (e.g. "CHR", stored without its "$") can coincide
        ; with a plain NUMERIC variable of the same name (TOK_IDENT
        ; "CHR" and TOK_STR_IDENT "CHR$" are distinct, never-colliding
        ; tokens per LEX_SCAN_IDENT's own hard '$'-suffix split -- see
        ; its header). BFN_FOUND_ARGTYPE's bit 7 (set = this function's
        ; RESULT is a string) disambiguates: only a bit-7-clear (numeric-
        ; result) match is a real call here; a bit-7-set match just means
        ; a same-named ordinary numeric identifier was typed, and falls
        ; through to the plain-identifier path below like any other name.
        push af                  ; A = fn_index, preserved across the
                                    ; result-type check (BFN_FOUND_ARGTYPE
                                    ; read below doesn't touch it, but the
                                    ; bit test clobbers A itself)
        ld a,(BFN_FOUND_ARGTYPE)
        bit 7,a
        jr z,.is_num_result
        pop af
        jr .not_builtin_fn
.is_num_result:
        pop af
        jr .fn_call
.not_builtin_fn:
        ; R8.5 Group 4 -- an identifier that names a DIM'd array, used as
        ; a VALUE, is an array read: "IDENT(expr)". Checked after builtin
        ; functions (a distinct, reserved namespace) but before the
        ; ordinary scalar-load path -- an array name is never also a
        ; valid scalar name (ARRSYM/CSYM are separate tables, but this
        ; grammar-level check is what actually keeps them from being
        ; used interchangeably).
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call ARRSYM_LOOKUP
        jr nc,.arr_read
        call COMPILE_IDENT_LOAD
        call LEX_NEXT_TOKEN
        ret
.arr_read:
        ld (CARR_INDEX),a         ; memory, not a register initially -- but
        ld a,(ARR_SIZE_TMP)        ; see the real bug this became anyway,
        ld (CARR_SIZE),a           ; below
        call LEX_NEXT_TOKEN         ; consume the array name, fetch next
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.arr_have_lparen
        ld a,40
        jp COMPILE_RAISE_ERROR
.arr_have_lparen:
        call LEX_NEXT_TOKEN          ; consume '('
        ; BUG FOUND (real hardware, R8.5 Group 4): the index sub-expression
        ; compiled next can itself contain a NESTED array read (e.g.
        ; "A(B(0))") -- COMPILE_FACTOR's own .arr_read branch for that
        ; inner read overwrites this SAME CARR_INDEX/CARR_SIZE pair before
        ; this outer read's own EMIT below gets to use them. Same "shared
        ; scratch clobbered by a nested compile call" bug class
        ; COMPILE_IF_BLOCK already hit and fixed with hardware-stack push/
        ; pop (see its own header) -- applying the identical fix here:
        ; park this read's own index/size in BC, not memory, across the
        ; recursive COMPILE_EXPR call.
        ld a,(CARR_INDEX)
        ld b,a
        ld a,(CARR_SIZE)
        ld c,a
        push bc
        call COMPILE_EXPR
        pop bc
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.arr_have_rparen
        ld a,41
        jp COMPILE_RAISE_ERROR
.arr_have_rparen:
        call LEX_NEXT_TOKEN           ; consume ')'
        call EMIT_OP_ARR_LOAD
        ld a,b
        call EMIT_BYTE
        ld a,c
        call EMIT_BYTE
        ret
.fn_call:
        ld (CFN_INDEX),a
        ld a,(BFN_FOUND_ARGCOUNT)
        ld (CFN_ARGCOUNT),a
        ld (CFN_REMAINING),a
        ld a,(BFN_FOUND_ARGTYPE)
        ld (CFN_ARGTYPE),a
        call LEX_NEXT_TOKEN       ; consume the function name
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.fn_have_lparen
        ld a,29                    ; expected '(' after a built-in
        ld (COMPILE_ERROR_CODE),a   ; function name
        ret
.fn_have_lparen:
        call LEX_NEXT_TOKEN         ; consume '('
        ld a,(CFN_REMAINING)
        or a
        jr z,.fn_rparen              ; 0-arg function (none exist yet,
                                       ; kept general for group 6)
.fn_arg_loop:
        ; this argument's own 0-based index = argcount - remaining (same
        ; technique COMPILE_EXT_CALL's own arg_loop already established
        ; for the identical need -- generalized here from LEN/CODE/VAL's
        ; original single flat flag, now that LEFT$/RIGHT$ (Group 6)
        ; need two ARGUMENTS of DIFFERENT types in the same call: a flat
        ; boolean can't express "arg 0 is a string, arg 1 is numeric")
        ld a,(CFN_ARGCOUNT)
        ld b,a
        ld a,(CFN_REMAINING)
        ld c,a
        ld a,b
        sub c
        ld b,a                      ; B = rotate count for the bit test
        ld a,(CFN_ARGTYPE)
        call VM_TEST_ARGTYPE_BIT    ; Z = numeric, NZ = string (shared
                                       ; with COMPILE_EXT_CALL/the
                                       ; decompiler's identical need)
        ; R8.5 Group 6 -- a function call used AS an argument to
        ; another function call (e.g. "LEN(UPPER$(A$))") recurses back
        ; into THIS SAME routine through the COMPILE_EXPR/COMPILE_STR_
        ; EXPR call below, which overwrites CFN_INDEX/CFN_ARGCOUNT/
        ; CFN_REMAINING/CFN_ARGTYPE with the INNER call's own values --
        ; this scratch is shared, not reentrant. Real bug, found via a
        ; real ZEsarUX run: "LEN(UPPER$(A$))" raised compile error 30
        ; ("expected ',' between arguments") because the outer LEN's
        ; own CFN_REMAINING had been clobbered to the inner UPPER$
        ; call's own final value (0) by the time control returned here,
        ; so decrementing it produced -1 instead of the outer's real
        ; remaining count. Fixed the same way COMPILE_FACTOR.arr_read's
        ; own CARR_INDEX/CARR_SIZE fix already established for the
        ; identical nested-array-read problem: park this iteration's
        ; own state on the hardware stack across the recursive call,
        ; not in the shared memory cells a nested call will reuse.
        ld a,(CFN_INDEX)
        ld d,a
        ld a,(CFN_ARGCOUNT)
        ld e,a
        push de
        ld a,(CFN_REMAINING)
        ld d,a
        ld a,(CFN_ARGTYPE)
        ld e,a
        push de
        jr z,.fn_arg_num
        call COMPILE_STR_EXPR         ; LEN/CODE/VAL/UPPER$/LOWER$/LEFT$/
                                        ; RIGHT$ (Group 6): this argument
                                        ; is a string expression
        jr .fn_arg_restore
.fn_arg_num:
        call COMPILE_EXPR
.fn_arg_restore:
        pop de
        ld a,e
        ld (CFN_ARGTYPE),a
        ld a,d
        ld (CFN_REMAINING),a
        pop de
        ld a,e
        ld (CFN_ARGCOUNT),a
        ld a,d
        ld (CFN_INDEX),a
.fn_arg_done:
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        ld a,(CFN_REMAINING)
        dec a
        ld (CFN_REMAINING),a
        or a
        jr z,.fn_rparen
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.fn_have_comma
        ld a,30                     ; expected ',' between a built-in
        ld (COMPILE_ERROR_CODE),a    ; function's own arguments
        ret
.fn_have_comma:
        call LEX_NEXT_TOKEN
        jr .fn_arg_loop
.fn_rparen:
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.fn_have_rparen
        ld a,31                      ; expected ')' to close a built-in
        ld (COMPILE_ERROR_CODE),a     ; function call
        ret
.fn_have_rparen:
        call LEX_NEXT_TOKEN            ; consume ')'
        call EMIT_OP_CALL_FN
        ld a,(CFN_INDEX)
        call EMIT_BYTE
        ret

; ===========================================================================
; R8.5 Group 1 -- built-in (resident) function-call grammar. Compile-
; time name resolution, same "linear scan a fixed table" pattern
; LEX_CLASSIFY_KEYWORD already established for statement keywords, but
; against a SEPARATE table (a function name is never a statement
; keyword or vice versa in this dialect, so no ambiguity). Entry layout
; matches KEYWORD_TABLE's own shape: [len:1][text:8, zero-padded]
; [argcount:1][fn_index:1][argtype:1] = 12 bytes/row. argtype (added
; for LEN/CODE/VAL): 0 = this function's arguments are numeric
; (COMPILE_EXPR), 1 = string (COMPILE_STR_EXPR) -- the function's own
; RESULT is always numeric either way (OP_CALL_FN always pushes back
; through the same TAG_INT/TAG_FLOAT path), only the ARGUMENT grammar
; differs.
; ===========================================================================
; VARIABLE-STRIDE table (bounded ROM consolidation pass, same technique
; LEX_CLASSIFY_KEYWORD's own header explains in full): each row is now
; [len:1][text:len][argcount:1][fn_index:1][argtype:1], no fixed-8-byte
; zero-padded text field. 60 bytes of pure padding recovered, real-
; measured via a direct before/after size comparison.
BUILTIN_FN_FIND:               ; input: TOK_NAME/TOK_LEN (current, not
                                 ; yet consumed, identifier token).
                                 ; Output: carry set + A = fn_index +
                                 ; BFN_FOUND_ARGCOUNT/BFN_FOUND_ARGTYPE
                                 ; = the matched function's own
                                 ; argcount/argtype, if found; carry
                                 ; clear (A/BFN_FOUND_ARGCOUNT/
                                 ; BFN_FOUND_ARGTYPE unchanged) if this
                                 ; identifier does not name a built-in
                                 ; function.
                                 ; Destroys: AF, BC, DE, HL.
        ld hl,BUILTIN_FN_TABLE
        ld b,BUILTIN_FN_TABLE_COUNT
.loop:
        ld a,(hl)                 ; A = this row's own real length
        inc hl                     ; HL -> name text
        ld c,a                     ; C = length (full, then remaining
                                      ; unconsumed once compare starts)
        ld a,(TOK_LEN)
        cp c
        jr nz,.skip                 ; length mismatch -- C already
                                      ; holds the full row length to skip
        ld de,(TOK_NAME)
        ld a,c
        or a
        jr z,.matched                ; zero-length name (never occurs
                                        ; in practice; kept safe)
.cmp_loop:
        ld a,(de)
        cp (hl)
        jr nz,.skip                  ; mismatch partway -- C already
                                       ; holds the remaining length to skip
        inc hl
        inc de
        dec c
        jr nz,.cmp_loop
.matched:
        ; HL is now exactly at argcount (text-start + the row's own
        ; real length) -- no fixed offset to add, unlike the old
        ; padded-to-8 layout.
        ld a,(hl)
        ld (BFN_FOUND_ARGCOUNT),a
        inc hl
        ld c,(hl)                 ; fn_index, parked in C (B is this
                                     ; loop's own counter, no longer
                                     ; needed once matched)
        inc hl
        ld a,(hl)
        ld (BFN_FOUND_ARGTYPE),a
        ld a,c
        scf
        ret
.skip:
        ld a,c
        or a
        jr z,.skip_text_done
        inc hl
        dec c
        jr .skip
.skip_text_done:
        inc hl
        inc hl
        inc hl                     ; skip argcount+fn_index+argtype ->
                                      ; HL now -> next row's own length
                                      ; byte
        dec b
        jr nz,.loop
        or a                       ; clear carry -- not a built-in
        ret                          ; function name

BUILTIN_FN_TABLE_COUNT: equ 25

; fn_index 0 = ABS (rom/exrom_v2_vm_core.asm's own BUILTIN_FN_ABS).
; Group 6 appends the remaining ~24 functions to this same table --
; only the table grows, BUILTIN_FN_FIND/COMPILE_FACTOR's own .fn_call
; grammar above needs no change per function added.
;
; SGN/MOD/DIV/RND (fn_index 1-4): confirmed via this milestone's own
; reuse audit AND a direct check of basic.asm's own real dispatch
; (BASIC_EVAL_PRIMARY.call_sgn/.call_mod/.call_div/.call_rnd) -- each
; is a THIN wrapper calling a real kernel/math/math.asm primitive
; (MATH_SGN16/MOD16/DIVIDE16/RND16) on plain 16-bit integers. V1's own
; comment at .call_int confirms this whole function family is
; deliberately integer-only ("this is a pure-integer BASIC") -- V2
; matching that is full capability preservation, not a new scope cut.
BUILTIN_FN_TABLE:
    db 3, "ABS", 1, 0, 0
    db 3, "SGN", 1, 1, 0
    db 3, "MOD", 2, 2, 0
    db 3, "DIV", 2, 3, 0
    db 3, "RND", 1, 4, 0

; POINT/ATTR/INT (fn_index 5-7): confirmed via basic.asm's own real
; dispatch (.call_point/.call_attr/.call_int) -- POINT/ATTR are thin
; adapters onto real, unmodified kernel/graphics/graphics.asm primitives
; (GFX_READ_PIXEL/GFX_CELL_ATTR_ADDR), same forgiving out-of-range-
; returns-0 behavior V1 already established (not an error condition);
; INT is a true no-op (V1's own comment: "this is a pure-integer BASIC,
; so every value is already its own INT()").
    db 5, "POINT", 2, 5, 0
    db 4, "ATTR", 2, 6, 0
    db 3, "INT", 1, 7, 0

; PEEK/USR (fn_index 8-9): confirmed via basic.asm's own real dispatch
; (.call_peek/.call_usr) -- both read/jump raw caller-supplied
; addresses directly, deliberately outside any kernel/ API (same
; reasoning V1 already documents). V1's own BASIC_CHECK_ONLY guards for
; both (real bugs where V1's live-typing checker evaluates expressions
; during static checking) don't apply here -- V2 compiles ahead of
; time and never evaluates an expression at compile time.
    db 4, "PEEK", 1, 8, 0
    db 3, "USR", 1, 9, 0

; LEN/CODE/VAL (fn_index 10-12): confirmed via basic.asm's own real
; dispatch (.str_arg_len/.str_arg_code and CODE/VAL's own STRING_
; FUNCTION_TABLE ARGC_STR1 entries) -- the first built-ins whose
; ARGUMENT is a string expression, not numeric (argtype=1 below routes
; COMPILE_FACTOR.fn_call's own argument loop through COMPILE_STR_EXPR
; instead of COMPILE_EXPR). The RESULT is still numeric either way --
; OP_CALL_FN's own dispatch/push-result mechanism needs no change.
; VAL reuses V2's own existing VM_PARSE_INPUT_INT (already used by
; OP_INPUT_NUM) rather than porting basic.asm's own separate parser.
    db 3, "LEN", 1, 10, 1
    db 4, "CODE", 1, 11, 1
    db 3, "VAL", 1, 12, 1

; CHR$/STR$/UPPER$/LOWER$/LEFT$/RIGHT$/INKEY$ (fn_index 13-19): the
; first built-ins whose RESULT is a string, not numeric -- reached from
; COMPILE_STR_FACTOR.ident, never COMPILE_FACTOR.ident (see both
; routines' own headers for the full name-collision reasoning). argtype
; byte generalized (this pass) to a real bitmask: bits 0-1 = per-
; position argument type (bit N set = argument N is a string
; expression), bit 7 = SET meaning this function's own RESULT is a
; string (a plain TAG_INT-tagged STRTAB index, per this VM's established
; string-value convention -- OP_CALL_FN's push mechanism needs no
; change for this). Table text stored WITHOUT the trailing '$'
; (TOK_STR_IDENT's own TOK_NAME/TOK_LEN already excludes it -- see
; LEX_SCAN_IDENT). Names/argcounts/handler bodies confirmed against
; rom/exrom_strfuncs.asm's real, already-proven transform algorithms
; (CHR$/STR$/UPPER$/LOWER$/LEFT$/RIGHT$ logic) -- but rom/exrom_v2_vm_
; core.asm's own handlers are fresh, V2-native rewrites on V2's own
; tag-aware VM_POP/VM_STR_ADDR/STRTAB-temp-slot convention, NOT direct
; calls into that V1 file, which has real basic.asm-resident
; dependencies (INKEY$'s own KTAB_IO_READ_KEY_NONBLOCK gateway) already
; confirmed NOT reusable post-R9 by this milestone's own INPUT work
; (see docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's Group 2 status
; note) -- INKEY$ instead reaches kernel/io/io.asm's own real, already-
; kernel-resident IO_READ_KEY_NONBLOCK directly, matching INPUT's own
; precedent exactly.
    db 3, "CHR", 1, 13, $80
    db 3, "STR", 1, 14, $80
    db 5, "UPPER", 1, 15, $81
    db 5, "LOWER", 1, 16, $81
    db 4, "LEFT", 2, 17, $81
    db 5, "RIGHT", 2, 18, $81
    db 5, "INKEY", 0, 19, $80

; SQR (fn_index 20): int-only argument, RESULT is always a real float
; (bit 7 clear -- unlike CHR$/STR$/etc above, SQR's result is numeric,
; matching V1's own real SQR(n) contract exactly. See rom/exrom_v2_vm_
; core.asm's own BUILTIN_FN_SQR for the real Newton-Raphson body).
    db 3, "SQR", 1, 20, 0

; PI (fn_index 21): 0 args, always a real float.
    db 2, "PI", 0, 21, 0
; RAD/DEG (fn_index 22-23): int-only argument, always a real float.
    db 3, "RAD", 1, 22, 0
    db 3, "DEG", 1, 23, 0
; SIN (fn_index 24): int-only argument (degrees), always a real float.
    db 3, "SIN", 1, 24, 0

; BUG FOUND (real hardware, R8.5 Group 5): a literal 128-255 has TOK_VAL
; high byte 0, so this used to take the PUSH_I8 path below -- but
; OP_PUSH_I8's own runtime handler sign-extends any byte with bit 7 set
; (a deliberate, correct trick for small negative values reached via
; unary minus's own "PUSH_I8 0, PUSH_I8 <magnitude>, SUB" pattern, where
; <magnitude> is always < 128). A DIRECTLY WRITTEN literal like "200"
; has no such sign context -- it silently became -56 at runtime. Caught
; via a real ZEsarUX run + a real decompile: "PALETTE 5,200" decompiled
; back as "PALETTE 5,-56". Pre-existing since R2 (affects PLOT/POKE/any
; byte-range literal >=128), not introduced by Group 5 -- just the
; first test in this session to happen to use one. Fixed by routing
; 128-255 through PUSH_I16 instead (3 bytes instead of 2, but always
; correct); 0-127 still uses PUSH_I8 unchanged.
COMPILE_NUMBER_LITERAL:
        ld de,(TOK_VAL)
        ld a,d
        or a
        jr nz,.wide
        ld a,e
        bit 7,a
        jr nz,.wide            ; 128-255 -- PUSH_I8 would sign-extend
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
        ; R8.5 Group 4 -- "IDENT(" at statement start is always an array
        ; assignment (a bare array READ can never be a whole statement,
        ; so there is no ambiguity), checked BEFORE the scalar CSYM_FIND_
        ; OR_CREATE call below — an array name must never be registered
        ; as a scalar symbol too.
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jp z,COMPILE_ARRAY_ASSIGN
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
        jp COMPILE_RAISE_ERROR
.have_assign:
        call LEX_NEXT_TOKEN     ; consume '='
        call COMPILE_EXPR
        call EMIT_BYTE_OP_STORE_VAR
        ld a,(ASSIGN_TARGET_INDEX)
        call EMIT_BYTE
        ret

; ===========================================================================
; R8.5 Group 4 -- DIM/array grammar.
;   dim_stmt   := 'DIM' IDENT '(' NUMBER ')'
;   array_read := IDENT '(' expr ')'                 (a COMPILE_FACTOR case)
;   array_asgn := IDENT '(' expr ')' '=' expr         (a statement)
; Arrays are integer-only (TAG_INT) in this milestone — the dominant real
; use case, and the one the runtime element-address opcode (VM core's
; OP_ARR_LOAD/OP_ARR_STORE) is scoped to; string arrays are not part of
; this group's scope (V1's own real DIM supported both, but archived its
; multi-dimensional support the same way — see rom/exrom_arrays.asm's own
; header — after measuring the real win wasn't worth its own budget cost;
; a future group can extend this table-driven shape to STRTAB-indexed
; arrays if the re-audit finds it's still missing).
; ===========================================================================

; COMPILE_DIM — entry: TOK_TYPE is TOK_KW_DIM (not yet consumed).
COMPILE_DIM:
        call LEX_NEXT_TOKEN       ; consume DIM, fetch the array name
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_ident
        ld a,32
        jp COMPILE_RAISE_ERROR
.have_ident:
        ld hl,(TOK_NAME)
        ld (ARRSYM_FIND_NAME_PTR),hl
        ld a,(TOK_LEN)
        cp 9
        jr c,.len_ok
        ld a,8
.len_ok:
        ld (ARRSYM_FIND_NAME_LEN),a
        call LEX_NEXT_TOKEN       ; consume the name, fetch next
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.have_lparen
        ld a,33
        jp COMPILE_RAISE_ERROR
.have_lparen:
        call LEX_NEXT_TOKEN       ; consume '(', fetch the size literal
        ld a,(TOK_TYPE)
        cp TOK_NUMBER
        jr z,.have_size
        ld a,34
        jp COMPILE_RAISE_ERROR
.have_size:
        ld a,(TOK_VAL)            ; low byte -- DIM sizes never legitimately
                                    ; exceed ARRAY_MAX_ELEMS (16), so TOK_VAL's
                                    ; high byte is never inspected
        or a
        jr nz,.size_nonzero
        ld a,35
        jp COMPILE_RAISE_ERROR
.size_nonzero:
        cp ARRAY_MAX_ELEMS+1
        jr c,.size_ok
        ld a,36
        jp COMPILE_RAISE_ERROR
.size_ok:
        ld (ARR_SIZE_TMP),a
        call LEX_NEXT_TOKEN       ; consume the size literal, fetch next
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        ld a,37
        jp COMPILE_RAISE_ERROR
.have_rparen:
        call LEX_NEXT_TOKEN       ; consume ')'
        ld hl,(ARRSYM_FIND_NAME_PTR)
        ld a,(ARRSYM_FIND_NAME_LEN)
        ld b,a
        call ARRSYM_FIND_OR_CREATE
        ret

; COMPILE_ARRAY_ASSIGN — entry: STMT_IDENT_NAME_PTR/LEN describe the
; array name (already consumed); TOK_TYPE is already TOK_LPAREN (already
; fetched by COMPILE_ASSIGN_CONTINUED's own one-token lookahead) -- same
; "identifier already consumed, don't re-fetch" contract that routine
; itself follows.
COMPILE_ARRAY_ASSIGN:
        ld hl,(STMT_IDENT_NAME_PTR)
        ld a,(STMT_IDENT_NAME_LEN)
        ld b,a
        call ARRSYM_LOOKUP
        jr nc,.found
        ld a,42
        jp COMPILE_RAISE_ERROR
.found:
        ; BUG FOUND (real hardware, R8.5 Group 4), TWO layers deep:
        ; (1) both sub-expressions compiled below can contain their OWN
        ; array reads (e.g. "B(0)=A(1)+A(0)") -- COMPILE_FACTOR's own
        ; .arr_read branch reuses this SAME CARR_INDEX/CARR_SIZE pair,
        ; silently overwriting this outer assignment's own target before
        ; EMIT_OP_ARR_STORE below got to use it. (2) A first attempt fixed
        ; that by parking the target in BC across EACH COMPILE_EXPR call
        ; separately (push immediately before, pop immediately after) --
        ; but LEX_NEXT_TOKEN (called to consume ')' and '=' BETWEEN the two
        ; calls) turned out to ALSO destroy BC (it scans the next token via
        ; LEX_CLASSIFY_KEYWORD, which uses B/C as its own table-scan
        ; counters) -- so the SECOND push captured already-clobbered
        ; garbage, not the real target (caught via a real ZEsarUX run:
        ; B(0)=A(1)+A(0) wrote 30 into A(0) instead of B(0); single-
        ; stepping showed BC=0000, not 0005, already corrupted at the
        ; second `push bc`, before COMPILE_EXPR for the value even ran).
        ; Real fix: ONE push spanning the ENTIRE rest of this routine
        ; (every LEX_NEXT_TOKEN and both COMPILE_EXPR calls), with exactly
        ; ONE pop, on EVERY exit path, right before the single point BC is
        ; actually used -- the same "balance every exit path" discipline
        ; COMPILE_IF_BLOCK's own header already documents, now proven to
        ; matter even when no further nested recursion is directly visible
        ; at the call site.
        ld b,a
        ld a,(ARR_SIZE_TMP)
        ld c,a
        push bc
        call LEX_NEXT_TOKEN        ; consume '(', fetch the index expr's
                                     ; first token
        call COMPILE_EXPR
        ld a,(COMPILE_ERROR_CODE)
        or a
        jr nz,.err_pop
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        ld a,41
        ld (COMPILE_ERROR_CODE),a
        jr .err_pop
.have_rparen:
        call LEX_NEXT_TOKEN         ; consume ')'
        ld a,(TOK_TYPE)
        cp TOK_ASSIGN
        jr z,.have_assign
        ld a,2
        ld (COMPILE_ERROR_CODE),a
        jr .err_pop
.have_assign:
        call LEX_NEXT_TOKEN          ; consume '='
        call COMPILE_EXPR             ; value expr -- pushed ON TOP of the
                                        ; already-compiled index expr, the
                                        ; order OP_ARR_STORE's own runtime
                                        ; handler expects (pops value first)
        ld a,(COMPILE_ERROR_CODE)
        or a
        jr nz,.err_pop
        pop bc
        call EMIT_OP_ARR_STORE
        ld a,b
        call EMIT_BYTE
        ld a,c
        call EMIT_BYTE
        ret
.err_pop:
        pop bc
        ret

; COMPILE_DIMN — DIMN(name): entry point is COMPILE_FACTOR.ident's own
; "DIMN" text check above (not a BUILTIN_FN_TABLE entry -- see that
; check's own header for why). TOK_TYPE is TOK_IDENT holding "DIMN"
; itself, not yet consumed.
;
; Decompile-fidelity note (a real, deliberate scope limitation, not an
; oversight): because DIMN folds to a bare PUSH_I8 literal with no
; runtime opcode at all, the fact that this value came from "DIMN(name)"
; is genuinely gone from the bytecode -- decompiling a program that used
; DIMN() shows the equivalent literal integer instead, not the original
; call. The recompiled program is numerically identical and behaves
; the same; only the reconstructed SOURCE TEXT differs, matching this
; project's own established "valid, re-lexable, not necessarily byte-
; identical" decompile bar, just for a larger class of input than
; earlier examples (e.g. unary minus's own "(0-X)" rendering).
COMPILE_DIMN:
        call LEX_NEXT_TOKEN       ; consume DIMN
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.have_lparen
        ld a,46                    ; expected '(' after DIMN
        jp COMPILE_RAISE_ERROR
.have_lparen:
        call LEX_NEXT_TOKEN         ; consume '('
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_ident
        ld a,47                     ; DIMN's argument must be a DIM'd
        jp COMPILE_RAISE_ERROR       ; array name
.have_ident:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call ARRSYM_LOOKUP
        jr nc,.have_size
        ld a,47                     ; not a DIM'd array (same code --
        jp COMPILE_RAISE_ERROR       ; same real failure either way)
.have_size:
        ld a,(ARR_SIZE_TMP)
        ld (DIMN_SIZE_TMP),a
        call LEX_NEXT_TOKEN         ; consume the array name
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        ld a,48                      ; expected ')' to close DIMN
        jp COMPILE_RAISE_ERROR
.have_rparen:
        call LEX_NEXT_TOKEN           ; consume ')'
        call EMIT_BYTE_OP_PUSH_I8
        ld a,(DIMN_SIZE_TMP)
        jp EMIT_BYTE

DIMN_KEYWORD_TEXT: db "DIMN"

; ARRSYM_ENTRY_ADDR — input: C = index. Output: HL = ARRSYMTAB_BASE +
; index*ARRSYM_REC_LEN(10).
ARRSYM_ENTRY_ADDR:
        ld l,c
        ld h,0
        add hl,hl                ; *2
        ld d,h
        ld e,l                    ; DE = *2
        add hl,hl                 ; *4
        add hl,hl                 ; *8
        add hl,de                  ; *8 + *2 = *10
        ld de,ARRSYMTAB_BASE
        add hl,de
        ret

; ARRSYM_FIND_OR_CREATE — input: HL = name ptr, B = name len; ARR_SIZE_TMP
; = the just-validated DIM size. Output: COMPILE_ERROR_CODE set (38 =
; already DIM'd, 39 = table full) on failure; on success, a new entry
; exists with this name and size. Destroys: AF, BC, DE, HL.
ARRSYM_FIND_OR_CREATE:
        ld (ARRSYM_FIND_NAME_PTR),hl
        ld a,b
        ld (ARRSYM_FIND_NAME_LEN),a
        ld c,0
.scan_loop:
        ld a,c
        push hl
        ld hl,ARRSYM_COUNT
        cp (hl)
        pop hl
        jr z,.not_found
        push bc
        call ARRSYM_ENTRY_ADDR
        ld a,(hl)
        pop bc
        cp b
        jr nz,.next
        push hl
        inc hl
        ld de,(ARRSYM_FIND_NAME_PTR)
        ld a,b
        or a                     ; zero-length name -- shouldn't happen (the
        jr nz,.have_len            ; lexer never produces one), but balance
        pop hl                      ; the stack properly rather than relying
        jr .already                  ; on "shouldn't happen" (same discipline
                                       ; CSYM_FIND_OR_CREATE's own comment
                                       ; explains)
.have_len:
        push bc
.cmp_loop:
        ld a,(de)
        cp (hl)
        jr nz,.cmp_fail
        inc hl
        inc de
        djnz .cmp_loop
        pop bc
        pop hl
        jr .already
.cmp_fail:
        pop bc
        pop hl
.next:
        inc c
        jr .scan_loop
.already:
        ld a,38
        jp COMPILE_RAISE_ERROR
.not_found:
        ld a,(ARRSYM_COUNT)
        cp ARRSYMTAB_MAX_ENTRIES
        jr nz,.create
        ld a,39
        jp COMPILE_RAISE_ERROR
.create:
        ld a,(ARRSYM_COUNT)
        ld c,a
        call ARRSYM_ENTRY_ADDR
        ld a,(ARRSYM_FIND_NAME_LEN)
        ld (hl),a
        inc hl
        ld de,(ARRSYM_FIND_NAME_PTR)
        ld b,a
        or a
        jr z,.write_size
.copy_loop:
        ld a,(de)
        ld (hl),a
        inc hl
        inc de
        dec b
        jr nz,.copy_loop
.write_size:
        ld a,(ARRSYM_COUNT)
        ld c,a
        call ARRSYM_ENTRY_ADDR
        ld de,9
        add hl,de
        ld a,(ARR_SIZE_TMP)
        ld (hl),a
        ld a,(ARRSYM_COUNT)
        inc a
        ld (ARRSYM_COUNT),a
        ret

; ARRSYM_LOOKUP — input: HL = name ptr, B = name len. Output: carry clear
; + A = array index + ARR_SIZE_TMP = that array's declared size, if a
; DIM'd array with this exact name exists; carry set (A/ARR_SIZE_TMP
; unchanged) otherwise. Read-only -- never creates an entry (DIM is the
; only writer). Destroys: AF, BC, DE, HL.
ARRSYM_LOOKUP:
        ld (ARRSYM_FIND_NAME_PTR),hl
        ld a,b
        ld (ARRSYM_FIND_NAME_LEN),a
        ld c,0
.scan_loop:
        ld a,c
        push hl
        ld hl,ARRSYM_COUNT
        cp (hl)
        pop hl
        jr z,.not_found
        push bc
        call ARRSYM_ENTRY_ADDR
        ld a,(hl)
        pop bc
        cp b
        jr nz,.next
        push hl
        inc hl
        ld de,(ARRSYM_FIND_NAME_PTR)
        ld a,b
        or a
        jr nz,.have_len
        pop hl
        jr .found
.have_len:
        push bc
.cmp_loop:
        ld a,(de)
        cp (hl)
        jr nz,.cmp_fail
        inc hl
        inc de
        djnz .cmp_loop
        pop bc
        pop hl
        jr .found
.cmp_fail:
        pop bc
        pop hl
.next:
        inc c
        jr .scan_loop
.found:
        push bc
        call ARRSYM_ENTRY_ADDR
        ld de,9
        add hl,de
        ld a,(hl)
        ld (ARR_SIZE_TMP),a
        pop bc
        ld a,c
        or a
        ret
.not_found:
        scf
        ret

; ===========================================================================
; R8.5 Group 2 (closed out late) -- INPUT.
;   input_stmt := 'INPUT' (IDENT | STR_IDENT)
; A numeric target auto-vivifies via CSYM_FIND_OR_CREATE (same as a bare
; assignment); a string target via STRSYM_FIND_OR_CREATE (same as a
; string assignment) -- INPUT is not required to target an ALREADY-
; assigned variable, matching V1's own real behavior.
; ===========================================================================
COMPILE_INPUT:
        call LEX_NEXT_TOKEN       ; consume INPUT, fetch the target token
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.numeric
        cp TOK_STR_IDENT
        jr z,.string
        ld a,43
        jp COMPILE_RAISE_ERROR
.numeric:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        cp 9
        jr c,.num_len_ok
        ld a,8
.num_len_ok:
        ld b,a
        call CSYM_FIND_OR_CREATE
        ld (CINPUT_INDEX_TMP),a
        call LEX_NEXT_TOKEN        ; consume the target identifier
        call EMIT_OP_INPUT_NUM
        ld a,(CINPUT_INDEX_TMP)
        call EMIT_BYTE
        ret
.string:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        cp 9
        jr c,.str_len_ok
        ld a,8
.str_len_ok:
        ld b,a
        call STRSYM_FIND_OR_CREATE
        ld (CINPUT_INDEX_TMP),a
        call LEX_NEXT_TOKEN        ; consume the target identifier
        call EMIT_OP_INPUT_STR
        ld a,(CINPUT_INDEX_TMP)
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
        ; R8.5 Group 6 (string-result functions) -- mirrors COMPILE_
        ; FACTOR.ident's own identical check (see its header for the
        ; full reasoning): BUILTIN_FN_FIND matches by name text alone,
        ; TOK_NAME/TOK_LEN already excludes this TOK_STR_IDENT's own
        ; trailing '$' (LEX_SCAN_IDENT's contract), so a match here is
        ; only a REAL string-function call if BFN_FOUND_ARGTYPE's bit 7
        ; is SET (result is a string) -- a bit-7-clear match means a
        ; same-named ordinary STRING VARIABLE was typed (e.g. "ABS$"),
        ; which falls through to the plain-string-identifier path below.
        call BUILTIN_FN_FIND
        jr nc,.plain_str_ident
        push af                  ; A = fn_index, preserved across the
                                    ; result-type check below
        ld a,(BFN_FOUND_ARGTYPE)
        bit 7,a
        jr z,.not_str_result
        pop af
        jp COMPILE_FACTOR.fn_call   ; same grammar/emit COMPILE_FACTOR's
                                       ; own numeric-context call uses --
                                       ; OP_CALL_FN's result is always
                                       ; pushed as a plain TAG_INT value
                                       ; either way (a string RESULT is
                                       ; just a STRTAB index, per this
                                       ; VM's own established convention),
                                       ; so no separate string-context
                                       ; emit path is needed
.not_str_result:
        pop af
.plain_str_ident:
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
        jp COMPILE_RAISE_ERROR
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
        jp COMPILE_RAISE_ERROR
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
        jp COMPILE_RAISE_ERROR
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
        jp COMPILE_RAISE_ERROR

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
; ===========================================================================
; R10-class consolidation, pulled forward once the real ROM budget went
; negative (see this milestone's own reconciliation-phase commits):
; COMPILE_1ARG_STMT is the shared body every "consume keyword, compile
; one expression, emit one opcode" statement compiler already had
; independently (found via this milestone's own deep consolidation
; audit). HL = the target EMIT_OP_<X> routine's address; tail-jumps
; into it via `jp (hl)` once the argument is compiled, so that
; routine's own `ret` returns straight to COMPILE_1ARG_STMT's caller.
; ===========================================================================
COMPILE_1ARG_STMT:
        push hl                  ; save the emit target -- LEX_NEXT_TOKEN/
                                   ; COMPILE_EXPR both freely destroy HL
        call LEX_NEXT_TOKEN
        call COMPILE_EXPR
        pop hl
        jp (hl)

COMPILE_BORDER:
        ld hl,EMIT_OP_BORDER
        jp COMPILE_1ARG_STMT

COMPILE_INK:
        ld hl,EMIT_OP_INK
        jp COMPILE_1ARG_STMT

COMPILE_PAPER:
        ld hl,EMIT_OP_PAPER
        jp COMPILE_1ARG_STMT

; COMPILE_EXPECT_COMMA_EXPR — expects the current token to be ',',
; consumes it, then compiles the following expression (tail-calls
; COMPILE_EXPR, so its own `ret` returns straight to THIS routine's
; caller). Shared by every 2-arg comma-separated statement compiler.
COMPILE_EXPECT_COMMA_EXPR:
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.have_comma
        ld a,22
        jp COMPILE_RAISE_ERROR
.have_comma:
        call LEX_NEXT_TOKEN
        jp COMPILE_EXPR

; COMPILE_PLOT — PLOT <expr>,<expr>  (x, then y — matches V1's own
; BASIC_STMT_PLOT reading order; OP_PLOT's own header note explains why
; it pops y before x)
COMPILE_PLOT:
        call LEX_NEXT_TOKEN     ; consume PLOT
        call COMPILE_EXPR       ; x -> VM operand stack
        call COMPILE_EXPECT_COMMA_EXPR  ; y -> VM operand stack
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        call EMIT_OP_PLOT
        ret

; R8.5 Group 5's own resident MODE/ULAPLUS/PALETTE removed (product
; decision, following the same principle that moved SPRITE off resident
; ROM): specialized/optional hardware facilities don't need to consume
; permanent ROM. MODE/ULAPLUS/PALETTE are now a loadable R7.5-style
; extension package (rom/ext_mode_module.asm) using the exact same
; EXT2_REGISTER/OP_CALL_EXT mechanism the sprite module already
; established -- see that module's own header for the architecture.

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
        jp COMPILE_RAISE_ERROR
.have_comma1:
        call LEX_NEXT_TOKEN     ; consume ','
        call COMPILE_EXPR       ; y0
        ld a,(TOK_TYPE)
        cp TOK_KW_TO
        jr z,.have_to
        ld a,24                  ; expected TO in LINE
        jp COMPILE_RAISE_ERROR
.have_to:
        call LEX_NEXT_TOKEN     ; consume TO
        call COMPILE_EXPR       ; x1
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.have_comma2
        ld a,25                  ; expected ',' after LINE's x1
        jp COMPILE_RAISE_ERROR
.have_comma2:
        call LEX_NEXT_TOKEN     ; consume ','
        call COMPILE_EXPR       ; y1
        call EMIT_OP_LINE
        ret

; COMPILE_BEEP — BEEP <duration>,<pitch>  (matches V1's own
; BASIC_STMT_BEEP argument order). "Expected comma" now reports code
; 22 (COMPILE_EXPECT_COMMA_EXPR's own code) rather than its own former
; 26 -- both were always "expected comma between a statement's two
; args", the same real condition either way; unifying it is what lets
; this reuse the shared helper.
COMPILE_BEEP:
        call LEX_NEXT_TOKEN     ; consume BEEP
        call COMPILE_EXPR       ; duration
        call COMPILE_EXPECT_COMMA_EXPR  ; pitch
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        call EMIT_OP_BEEP
        ret

; COMPILE_SOUND — SOUND <register>,<data>  (matches V1's own
; BASIC_STMT_SOUND argument order)
COMPILE_SOUND:
        call LEX_NEXT_TOKEN     ; consume SOUND
        call COMPILE_EXPR       ; register
        call COMPILE_EXPECT_COMMA_EXPR  ; data
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        call EMIT_OP_SOUND
        ret

; COMPILE_POKE — POKE <address>,<value>  (matches V1's own
; BASIC_STMT_POKE argument order)
COMPILE_POKE:
        call LEX_NEXT_TOKEN     ; consume POKE
        call COMPILE_EXPR       ; address
        call COMPILE_EXPECT_COMMA_EXPR  ; value
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        call EMIT_OP_POKE
        ret

; COMPILE_PAUSE — PAUSE <n>  (one argument, same shape as BORDER/INK/
; PAPER above)
COMPILE_PAUSE:
        ld hl,EMIT_OP_PAUSE
        jp COMPILE_1ARG_STMT

; COMPILE_RANDOMISE — RANDOMISE <n>
COMPILE_RANDOMISE:
        ld hl,EMIT_OP_RANDOMISE
        jp COMPILE_1ARG_STMT

; ===========================================================================
; R8.5 -- PRINT/LPRINT <string-expr | numeric-expr>. ONE argument,
; auto-detected by peeking the first token exactly the way COMPILE_IF
; already does for its own condition -- matching basic/basic.asm's own
; real BASIC_EVAL_PRINT_ARG grammar (no comma/semicolon item list, no
; ";"-suppressed newline: this dialect's PRINT never had either).
; ===========================================================================
COMPILE_PRINT:
        call LEX_NEXT_TOKEN     ; consume PRINT
        ld a,(TOK_TYPE)
        cp TOK_STRING
        jr z,.str_arg
        cp TOK_STR_IDENT
        jr z,.str_arg
        call COMPILE_EXPR
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        call EMIT_OP_PRINT_NUM
        ret
.str_arg:
        call COMPILE_STR_EXPR
        call EMIT_OP_PRINT_STR
        ret

; COMPILE_LPRINT -- printer-package ROM reconciliation: LPRINT is no
; longer a resident opcode. Its own real body (rom/exrom_printer.asm's
; BASIC_STMT_LPRINT_EXROM) moved to a loadable extension package (rom/
; ext_printer_module.asm), registered through the SAME R7.5 EXT2_
; REGISTER/OP_CALL_EXT mechanism SPRITE/MODE already use.
;
; WHY THIS SHELL STAYS RESIDENT (a real limitation, not an avoided
; special case): the new generic typed-argument mechanism (see
; COMPILE_EXT_CALL's own header) gives each argument POSITION a FIXED
; type, chosen once at registration time -- exactly right for GRAB's
; own shape (5 arguments, each always the same type) but NOT expressive
; enough for LPRINT's real grammar, where the SAME single argument
; position can be EITHER a numeric or a string expression depending on
; what the caller actually writes (a union, not a fixed per-position
; type). Resolving that union at compile time genuinely needs to peek
; the argument's own shape BEFORE deciding which registered slot to
; target -- there is no way to express "this argument is numeric OR
; string" as a single registry argtypes bit. So this routine keeps
; exactly the same peek PRINT/COMPILE_PRINT already does, but resolves
; ONE of two internal extension names (LPRINT_NUM_NAME for the numeric
; case, LPRINT_STR_NAME for the string case -- the module registers
; both; only "LPRINT" is ever user-visible, since COMPILE_STATEMENT_
; LIST's own TOK_KW_LPRINT dispatch is what reaches this routine, not
; the generic identifier-driven EXT2_LOOKUP path) and emits a plain
; OP_CALL_EXT, argcount=1, the same encoding COMPILE_EXT_CALL's own
; `.emit:` tail produces -- just without that routine's own `call LEX_
; NEXT_TOKEN` (there is no separate keyword token left to consume here;
; LPRINT itself was already consumed by this routine's own first line).
COMPILE_LPRINT:
        call LEX_NEXT_TOKEN     ; consume LPRINT
        ld a,(TOK_TYPE)
        cp TOK_STRING
        jr z,.str_arg
        cp TOK_STR_IDENT
        jr z,.str_arg
        ld hl,LPRINT_NUM_NAME
        ld b,LPRINT_NUM_NAME_LEN
        call EXT2_LOOKUP
        jr c,.not_loaded
        call COMPILE_LPRINT_RESOLVE_SLOT
        call COMPILE_EXPR
        jr COMPILE_LPRINT_EMIT
.str_arg:
        ld hl,LPRINT_STR_NAME
        ld b,LPRINT_STR_NAME_LEN
        call EXT2_LOOKUP
        jr c,.not_loaded
        call COMPILE_LPRINT_RESOLVE_SLOT
        call COMPILE_STR_EXPR
        jr COMPILE_LPRINT_EMIT
.not_loaded:
        ld a,32                  ; LPRINT used but the printer package
        ld (COMPILE_ERROR_CODE),a  ; isn't loaded/registered
        ret

LPRINT_NUM_NAME: db "LPRINT",0
LPRINT_NUM_NAME_LEN: equ $-LPRINT_NUM_NAME-1
LPRINT_STR_NAME: db "LPRINT$",0
LPRINT_STR_NAME_LEN: equ $-LPRINT_STR_NAME-1

; COMPILE_LPRINT_RESOLVE_SLOT -- input: A = slot id (from EXT2_LOOKUP).
; Parks CEXT_SLOT/CEXT_GEN exactly like COMPILE_EXT_CALL's own entry
; does, reused here since COMPILE_LPRINT_EMIT's own tail is otherwise
; identical to COMPILE_EXT_CALL's `.emit:`. Destroys: AF, HL.
COMPILE_LPRINT_RESOLVE_SLOT:
        ld (CEXT_SLOT),a
        call EXT2_SLOT_ADDR
        ld a,(hl)
        ld (CEXT_GEN),a
        ld a,1
        ld (CEXT_ARGCOUNT),a    ; bounded ROM consolidation pass: set
                                  ; here so COMPILE_LPRINT_EMIT below can
                                  ; just reuse COMPILE_EXT_CALL's own
                                  ; `.emit:` tail instead of duplicating
                                  ; its 3x "ld a,(CEXT_x):call EMIT_BYTE"
                                  ; sequence
        ret

; COMPILE_LPRINT_EMIT -- shared tail for both COMPILE_LPRINT branches:
; checks COMPILE_ERROR_CODE (set by the just-compiled argument
; expression), then emits OP_CALL_EXT [slot][gen][argcount=1] -- same
; operand shape COMPILE_EXT_CALL's own `.emit:` produces, so .op_call_
; ext's existing generic decompile path needs no LPRINT-specific code
; at all.
COMPILE_LPRINT_EMIT:
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        jp COMPILE_EXT_CALL.emit  ; CEXT_SLOT/CEXT_GEN/CEXT_ARGCOUNT
                                     ; already set (COMPILE_LPRINT_
                                     ; RESOLVE_SLOT above) -- reuses the
                                     ; SAME 3x "ld a,(CEXT_x):call
                                     ; EMIT_BYTE" tail COMPILE_EXT_CALL's
                                     ; own generic path already has,
                                     ; rather than a second copy

; COMPILE_GOTO — GOTO <label>
COMPILE_GOTO:
        call LEX_NEXT_TOKEN     ; consume GOTO
        call EMIT_OP_JMP
        call EMIT_PLACEHOLDER_16   ; HL = patch address
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_target
        ld a,12                 ; expected a label name after GOTO
        jp COMPILE_RAISE_ERROR
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
        jp COMPILE_RAISE_ERROR
.have_then:
        call LEX_NEXT_TOKEN     ; consume THEN
        ld a,(TOK_TYPE)
        cp TOK_KW_GOTO
        jr z,.have_goto
        jp COMPILE_IF_BLOCK      ; R8.5 Group 3 -- anything other than
                                    ; GOTO after THEN is the start of a
                                    ; block IF's own THEN-body (see
                                    ; COMPILE_IF_BLOCK's own header)
.have_goto:
        call LEX_NEXT_TOKEN     ; consume GOTO
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_target
        ld a,12
        jp COMPILE_RAISE_ERROR
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
; COMPILE_IF_BLOCK — R8.5 Group 3. Entry: THEN has already been consumed;
; TOK_TYPE is the first token of the THEN-body (COMPILE_IF's own
; .have_then dispatches here for anything other than GOTO). IF_SKIP_
; PATCH_TMP already holds JMPZ's own false-branch patch address.
;
;   IF <cond> THEN <then-body> ENDIF
;   IF <cond> THEN <then-body> ELSE <else-body> ENDIF
;
; Reuses COMPILE_STATEMENT_LIST recursively for each body, exactly the
; way COMPILE_PROC already reuses it for a PROC body -- COMPILE_
; STATEMENT_LIST's own top-level loop now also stops on TOK_KW_ELSE/
; TOK_KW_ENDIF (added alongside its existing TOK_EOF/TOK_KW_ENDP stops).
; ELSEIF is not a separate keyword: "ELSE IF <cond2> THEN ... ENDIF"
; nested inside an ELSE-body reaches the same result (one more ENDIF per
; nesting level) — reusing an existing grammar shape rather than adding
; a special-cased chain-flattening one, same preference this dialect's
; grammar already shows elsewhere (see e.g. COMPILE_FACTOR's own unary-
; minus reusing OP_SUB instead of a dedicated opcode).
; ===========================================================================
; NESTING SAFETY: IF_SKIP_PATCH_TMP/IF_ELSE_SKIP_PATCH_TMP are single
; shared memory cells, but COMPILE_IF_BLOCK is genuinely recursive (an
; IF nested inside another IF's own THEN/ELSE body, via COMPILE_
; STATEMENT_LIST's own reentrant reuse) -- a naive read of either cell
; AFTER the recursive COMPILE_STATEMENT_LIST call returns would get the
; INNER call's own value, not this invocation's, silently leaving the
; outer IF's own placeholder forever unpatched (stuck at 0 -- a real
; bug found via a real ZEsarUX run: a JMPZ decompiling with target 0,
; traced back to exactly this). Fixed by saving each patch address on
; the hardware stack IMMEDIATELY (before the recursive call that could
; clobber the shared cell), and popping it back only once it's actually
; needed again -- carefully balanced on every exit path, including
; every error return, since an unbalanced push would corrupt the next
; `ret`'s own return address.
COMPILE_IF_BLOCK:
        ld hl,(IF_SKIP_PATCH_TMP)
        push hl                        ; save THIS invocation's own patch
                                         ; address across the recursive call
        call COMPILE_STATEMENT_LIST   ; compiles the THEN-body
        ld a,(COMPILE_ERROR_CODE)
        or a
        jr nz,.err_pop1
        ld a,(TOK_TYPE)
        cp TOK_KW_ELSE
        jr z,.have_else
        cp TOK_KW_ENDIF
        jr z,.have_endif
        ld a,9                   ; expected ELSE or ENDIF
        ld (COMPILE_ERROR_CODE),a
        pop hl
        ret
.err_pop1:
        pop hl
        ret
.have_else:
        ; the THEN-body's own real execution must skip over the ELSE-
        ; body entirely once it finishes -- emit that jump BEFORE
        ; patching the THEN-body's own false-branch target, which is
        ; the ELSE-body's own start (right here), not past it. Uses the
        ; dedicated OP_JMP_ELSE opcode, not plain JMP -- see its own
        ; EMIT_OP_JMP_ELSE header for why.
        call EMIT_OP_JMP_ELSE
        call EMIT_PLACEHOLDER_16
        ld (IF_ELSE_SKIP_PATCH_TMP),hl  ; not yet at risk -- the ELSE-body's
                                          ; own recursive call hasn't
                                          ; happened yet
        ld hl,(EMIT_PTR)
        ld de,VM_CODE_BASE
        or a
        sbc hl,de
        ex de,hl                          ; DE = relative offset
        pop hl                              ; HL = our own saved THEN-body
                                              ; patch address (balances the
                                              ; entry push)
        ld (hl),e
        inc hl
        ld (hl),d
        ld hl,(IF_ELSE_SKIP_PATCH_TMP)
        push hl                            ; save THIS invocation's own
                                             ; else-skip patch address
                                             ; across the ELSE-body's own
                                             ; recursive call
        call LEX_NEXT_TOKEN            ; consume ELSE
        call COMPILE_STATEMENT_LIST     ; compiles the ELSE-body
        ld a,(COMPILE_ERROR_CODE)
        or a
        jr nz,.err_pop2
        ld a,(TOK_TYPE)
        cp TOK_KW_ENDIF
        jr z,.else_have_endif
        ld a,9
        ld (COMPILE_ERROR_CODE),a
        pop hl
        ret
.err_pop2:
        pop hl
        ret
.else_have_endif:
        ld hl,(EMIT_PTR)
        ld de,VM_CODE_BASE
        or a
        sbc hl,de
        ex de,hl
        pop hl                            ; HL = our own saved else-skip
                                            ; patch address
        ld (hl),e
        inc hl
        ld (hl),d
        call LEX_NEXT_TOKEN                ; consume ENDIF
        ret
.have_endif:
        ld hl,(EMIT_PTR)
        ld de,VM_CODE_BASE
        or a
        sbc hl,de
        ex de,hl
        pop hl                            ; HL = our own saved THEN-body
                                            ; patch address (balances the
                                            ; entry push)
        ld (hl),e
        inc hl
        ld (hl),d
        call LEX_NEXT_TOKEN             ; consume ENDIF
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
        xor a
        ld (EXITFOR_COUNT),a     ; R8.5 Group 5 -- reset for THIS loop; no
                                   ; nesting support (see FOR/NEXT's own
                                   ; single-active-loop scope), so this
                                   ; never needs saving/restoring
        call LEX_NEXT_TOKEN     ; consume FOR
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_var
        ld a,10                  ; expected a loop variable
        jp COMPILE_RAISE_ERROR
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
        jp COMPILE_RAISE_ERROR
.have_assign:
        call LEX_NEXT_TOKEN     ; consume '='
        call COMPILE_EXPR       ; initial value -> VM operand stack
        ld a,(TOK_TYPE)
        cp TOK_KW_TO
        jr z,.have_to
        ld a,11                  ; expected TO
        jp COMPILE_RAISE_ERROR
.have_to:
        call LEX_NEXT_TOKEN     ; consume TO
        call COMPILE_EXPR       ; limit value -> VM operand stack
        ld a,(TOK_TYPE)
        cp TOK_KW_STEP
        jr z,.have_step
        call EMIT_BYTE_OP_PUSH_I8   ; R8.5 Group 5 -- no STEP written:
        ld a,1                       ; compile a literal step of 1, same
        call EMIT_BYTE                ; as OP_FOR_INIT/OP_FOR_NEXT always
        jr .emit_init                  ; expect a real step operand now
.have_step:
        call LEX_NEXT_TOKEN     ; consume STEP
        call COMPILE_EXPR       ; step value -> VM operand stack
.emit_init:
        call EMIT_OP_FOR_INIT
        ld a,(FOR_LOOP_VAR_INDEX)
        call EMIT_BYTE
        ld hl,(EMIT_PTR)
        ld de,VM_CODE_BASE
        or a
        sbc hl,de                ; HL = loop body's start, relative offset
        ld (FOR_LOOP_TOP_OFFSET),hl
        ret

; COMPILE_EXIT_FOR — EXIT FOR. Compiles to a plain JMP whose target is
; patched once COMPILE_NEXT knows the loop's real exit address (the same
; "record a patch address now, resolve it later" shape GOTO's own
; FIXUPTAB already uses, but scoped to the SINGLE currently-compiling
; loop rather than a named label — no nesting support, matching FOR/
; NEXT's own existing scope).
COMPILE_EXIT_FOR:
        call LEX_NEXT_TOKEN     ; consume EXIT
        ld a,(TOK_TYPE)
        cp TOK_KW_FOR
        jr z,.have_for
        ld a,44
        jp COMPILE_RAISE_ERROR
.have_for:
        ld a,(EXITFOR_COUNT)
        cp EXITFOR_MAX
        jr nz,.record
        ld a,45
        jp COMPILE_RAISE_ERROR
.record:
        call EMIT_OP_JMP
        call EMIT_PLACEHOLDER_16
        ld (BRANCH_PATCH_TMP),hl   ; this JMP's own operand address
        ld a,(EXITFOR_COUNT)
        ld hl,EXITFOR_PATCH_TABLE
        ld c,a
        ld b,0
        add hl,bc
        add hl,bc                  ; HL = EXITFOR_PATCH_TABLE + index*2
        ld de,(BRANCH_PATCH_TMP)
        ld (hl),e
        inc hl
        ld (hl),d
        ld a,(EXITFOR_COUNT)
        inc a
        ld (EXITFOR_COUNT),a
        call LEX_NEXT_TOKEN         ; consume FOR
        ret

; COMPILE_NEXT — NEXT <ident>
COMPILE_NEXT:
        call LEX_NEXT_TOKEN     ; consume NEXT
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_var
        ld a,10
        jp COMPILE_RAISE_ERROR
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
        ; R8.5 Group 5 -- resolve every pending EXIT FOR from this loop's
        ; own body now: the loop's real exit point is exactly here, the
        ; first bytecode position past NEXT's own operand (the same
        ; position OP_FOR_NEXT's own .past_limit falls through to at
        ; runtime).
        ld hl,(EMIT_PTR)
        ld de,VM_CODE_BASE
        or a
        sbc hl,de                 ; HL = relative exit offset
        ld (RESOLVE_PATCH_TMP),hl
        ld a,(EXITFOR_COUNT)
        or a
        ret z
        ld b,a
        ld hl,EXITFOR_PATCH_TABLE
.patch_loop:
        push bc
        push hl
        ld e,(hl)
        inc hl
        ld d,(hl)                 ; DE = this slot's own patch address
        ex de,hl                  ; HL = patch address
        ld de,(RESOLVE_PATCH_TMP)
        ld (hl),e
        inc hl
        ld (hl),d
        pop hl
        pop bc
        inc hl
        inc hl
        djnz .patch_loop
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
        cp TOK_COLON
        jp z,.skip_separator
        cp TOK_EOF
        jp z,.done
        cp TOK_KW_ENDP
        jp z,.done
        cp TOK_KW_ELSE            ; R8.5 Group 3 -- a block IF's own
        jp z,.done                  ; ELSE/ENDIF is exactly the same
        cp TOK_KW_ENDIF              ; "closing keyword ends the nested
        jp z,.done                    ; statement list" shape ENDP
                                        ; already established for PROC
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
        cp TOK_KW_PRINT
        jp z,.print
        cp TOK_KW_LPRINT
        jp z,.lprint
        cp TOK_KW_END
        jp z,.end_stmt
        cp TOK_KW_STOP
        jp z,.end_stmt
        cp TOK_KW_REM
        jp z,.rem
        cp TOK_KW_DIM
        jp z,.dim
        cp TOK_KW_INPUT
        jp z,.input
        cp TOK_KW_EXIT
        jp z,.exit_for
        cp TOK_IDENT
        jp z,.ident_stmt
        cp TOK_STR_IDENT
        jp z,.str_ident_stmt
        jp .done                  ; anything else ends compilation cleanly
                                   ; in this scope (no error-recovery exists
                                   ; yet — a later milestone's job)
.skip_separator:
        call LEX_NEXT_TOKEN
        jp .loop
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
.print:
        call COMPILE_PRINT
        jp .after_stmt
.lprint:
        call COMPILE_LPRINT
        jp .after_stmt
.end_stmt:
        call LEX_NEXT_TOKEN     ; consume END/STOP
        call EMIT_OP_HALT
        jp .after_stmt
.rem:
        ; REM is a pure comment -- everything to the end of this
        ; statement is discarded, matching basic/basic.asm's own
        ; BASIC_STMT_REM exactly ("the dispatcher already advanced HL
        ; past REM... nothing further needs to happen"). No opcode is
        ; emitted at all -- a REM line simply contributes nothing to
        ; the compiled bytecode, so it cannot appear in decompiled
        ; output either (matching this project's own established
        ; "decompiled text is a valid, not byte-identical, re-
        ; rendering" bar -- a REM's own comment text was never
        ; semantically meaningful to begin with).
        ld hl,(SRC_PTR)
.rem_scan:
        ld a,(hl)
        or a
        jr z,.rem_done
        cp $0D
        jr z,.rem_done
        inc hl
        jr .rem_scan
.rem_done:
        ld (SRC_PTR),hl
        call LEX_NEXT_TOKEN
        jp .after_stmt
.str_ident_stmt:
        call COMPILE_STR_ASSIGN
        jp .after_stmt
.dim:
        call COMPILE_DIM
        jp .after_stmt
.input:
        call COMPILE_INPUT
        jp .after_stmt
.exit_for:
        call COMPILE_EXIT_FOR
        jp .after_stmt
.ident_stmt:
        ; R7.5 addition: BEFORE assuming this identifier starts an
        ; assignment or a label definition, check whether its exact name
        ; matches a currently-registered V2-native extension (kernel/
        ; extensions/ext_registry.asm) — extension keywords take
        ; priority over "just a variable name," matching V1's own
        ; BASIC_TRY_EXTENSION ordering (checked before BASIC_TRY_
        ; ASSIGNMENT there too). This is safe to check at COMPILE time
        ; (not just runtime) because compiling happens with the same
        ; extension module(s) already loaded that running the equivalent
        ; V1 line would have needed — the same precondition V1 itself
        ; already imposes (see the regression suite's own `*_unloaded`
        ; tests). If nothing matches, this identifier is genuinely just
        ; a variable/label, exactly as before this addition.
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call EXT2_LOOKUP
        jr c,.not_extension
        call COMPILE_EXT_CALL
        jp .after_stmt
.not_extension:
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
; COMPILE_PROGRAM — real entry: HL=SRC_PTR, EMIT_PTR already set to
; VM_CODE_BASE by the caller (COMPILER_INIT's own contract, unchanged).
;
; DECOMP_END_ADDR is now set HERE, automatically, from the real final
; EMIT_PTR, rather than being a "caller must remember" convention.
; Before this, every single caller across every rom/test_v2_*.asm file
; (and, eventually, whatever real V2 command-loop integration replaces
; them at R9) had to manually do `ld hl,(EMIT_PTR): ld (DECOMP_END_
; ADDR),hl` right after calling this -- a real, easy-to-forget
; duplicated step (rom/exrom_v2_decompiler.asm's own DECOMP_END_ADDR
; comment used to document it only as a "CALLER CONTRACT"). Folding it
; in here makes DECOMPILE_PROGRAM (and now LLIST, which calls it at
; genuine RUNTIME, long after any test harness's own COLD_START) work
; correctly by construction, with no separate step to remember.
COMPILE_PROGRAM:
        call LEX_NEXT_TOKEN
        call COMPILE_STATEMENT_LIST
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        call EMIT_OP_HALT
        call RESOLVE_ALL_FIXUPS
        ld hl,(EMIT_PTR)
        ld (DECOMP_END_ADDR),hl
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
        jp COMPILE_RAISE_ERROR
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
        jp COMPILE_RAISE_ERROR
.have_lparen:
        call LEX_NEXT_TOKEN     ; consume '('
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_param
        ld a,19                  ; expected a parameter name
        jp COMPILE_RAISE_ERROR
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
        jp COMPILE_RAISE_ERROR
.have_rparen:
        call LEX_NEXT_TOKEN     ; consume ')'
        ld a,(TOK_TYPE)
        cp TOK_COLON
        jr z,.have_colon
        ld a,21                  ; expected ':' before the procedure body
        jp COMPILE_RAISE_ERROR
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
        jp COMPILE_RAISE_ERROR
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
        jp COMPILE_RAISE_ERROR
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
        jp COMPILE_RAISE_ERROR
.have_lparen:
        call LEX_NEXT_TOKEN     ; consume '('
        call COMPILE_EXPR       ; argument -> pushed onto the VM operand stack
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        ld a,15                  ; expected ')' after the argument
        jp COMPILE_RAISE_ERROR
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

; ===========================================================================
; COMPILE_EXT_CALL — R7.5, extended for typed arguments (printer-package
; ROM reconciliation). Called with A = the matched extension's slot id
; (from EXT2_LOOKUP, kernel/extensions/ext_registry.asm), TOK_TYPE still
; the un-consumed identifier token. Compiles "KEYWORD <expr>[,<expr>]*"
; (argcount comma-separated expressions, read from the matched slot's
; own registration -- no V1-shaped "grammar 0/1/3" special-casing; any
; argcount 0-4 uses this one path) and emits OP_CALL_EXT with the
; resolved [slot_id][generation][argcount] operand.
;
; TYPED ARGUMENTS: the registry record now also carries an argtypes
; bitmask (one bit per argument position, bit N set = argument N is a
; STRING expression, compiled via COMPILE_STR_EXPR instead of
; COMPILE_EXPR) -- generalizes the SAME concept rom/exrom_v2_compiler.
; asm's own BUILTIN_FN_TABLE argtype column already established for
; LEN/CODE/VAL (R8.5 Group 6), just per-ARGUMENT-POSITION here instead
; of per-function, since an extension can have several arguments of
; different types (LPRINT: exactly one argument, either type). The
; VM's own OP_CALL_EXT needed NO change for this -- it only ever pops
; and stores raw 16-bit values, and a string "value" is already just a
; plain STRTAB index pushed via the ordinary PUSH_I16 opcode (same
; convention every other string-carrying V2 opcode already uses); the
; type distinction is purely a COMPILE-TIME (which grammar to parse)
; and DECOMPILE-TIME (how to render the fragment back) concern.
; ===========================================================================
COMPILE_EXT_CALL:
        ld (CEXT_SLOT),a
        call EXT2_SLOT_ADDR      ; HL -> registry record
        ld a,(hl)                  ; generation
        ld (CEXT_GEN),a
        push hl
        ld de,12
        add hl,de
        ld a,(hl)                   ; argcount
        ld (CEXT_ARGCOUNT),a
        inc hl
        ld a,(hl)                   ; argtypes bitmask
        ld (CEXT_ARGTYPES),a
        pop hl
        ld a,(CEXT_ARGCOUNT)
        ld (CEXT_REMAINING),a
        call LEX_NEXT_TOKEN         ; consume the extension keyword
        ld a,(CEXT_REMAINING)
        or a
        jr z,.emit                  ; 0-argument extension — nothing to
                                    ; compile, straight to the opcode
.arg_loop:
        ; this argument's own 0-based index = argcount - remaining
        ld a,(CEXT_ARGCOUNT)
        ld b,a
        ld a,(CEXT_REMAINING)
        ld c,a
        ld a,b
        sub c
        ld b,a                      ; B = rotate count for the bit test
        ld a,(CEXT_ARGTYPES)
        call VM_TEST_ARGTYPE_BIT  ; Z = numeric, NZ = string (bounded
                                    ; ROM consolidation pass -- shared
                                    ; with the decompiler's identical
                                    ; need, see rom/exrom_v2_vm_core.
                                    ; asm's own header)
        jr z,.arg_numeric
        call COMPILE_STR_EXPR
        jr .arg_checked
.arg_numeric:
        call COMPILE_EXPR
.arg_checked:
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        ld a,(CEXT_REMAINING)
        dec a
        ld (CEXT_REMAINING),a
        or a
        jr z,.emit
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.have_comma
        ld a,28                     ; expected ',' between an
                                    ; extension call's own arguments
        jp COMPILE_RAISE_ERROR
.have_comma:
        call LEX_NEXT_TOKEN         ; consume ','
        jr .arg_loop
.emit:
        call EMIT_OP_CALL_EXT
        ld a,(CEXT_SLOT)
        call EMIT_BYTE
        ld a,(CEXT_GEN)
        call EMIT_BYTE
        ld a,(CEXT_ARGCOUNT)
        call EMIT_BYTE
        ret

; COMPILE_TEST_ARGTYPE_BIT removed (bounded ROM consolidation pass) --
; was byte-identical to rom/exrom_v2_decompiler.asm's own DECOMP_TEST_
; ARGTYPE_BIT; both now share ONE real copy, rom/exrom_v2_vm_core.asm's
; own VM_TEST_ARGTYPE_BIT (see that routine's own header for the full
; account, including the real C-register clobber bug originally found
; and fixed in the decompiler's own copy of this logic). COMPILE_EXT_
; CALL's own call site below was updated to call it there instead.

; COMPILE_RAISE_ERROR -- bounded ROM consolidation pass: 41 separate
; "ld a,N / ld (COMPILE_ERROR_CODE),a / ret" sites (each 6 bytes) across
; this file were mechanically identical past the literal error code --
; replaced with "ld a,N / jp COMPILE_RAISE_ERROR" (5 bytes) sharing
; this one real tail. A tail JUMP (not call): each site's own `ret` was
; returning to THAT SITE's own caller, not to itself, so this must be
; reached via `jp`, whose own `ret` then pops the SAME return address
; already on the stack -- semantically identical to the original inline
; "set the code, then ret" either way. The other ~13 error sites in
; this file do MORE than just set-and-return (e.g. popping a saved
; value, jumping to shared cleanup) and were deliberately left alone --
; only the exact "set-then-immediately-return" shape was touched.
; Input: A = error code. Destroys: nothing else.
COMPILE_RAISE_ERROR:
        ld (COMPILE_ERROR_CODE),a
        ret

COMPILER_END:

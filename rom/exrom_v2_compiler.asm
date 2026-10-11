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
;   (50-63: see the individual COMPILE_RAISE_ERROR sites; 55, 60-62 are the
;    capacity/nesting/name-length classes shown by V2_COMPILE_MSG)
;   64 = unexpected token (R10.9 2D): something that is neither a statement nor
;        the ':' / end of line / closer that must follow one -- stray ENDIF/
;        ELSE/ENDP/THEN/TO/')', trailing junk, a missing ':', an unterminated
;        string literal. Message UNEXPECTED TOKEN.
;   65 = FOR without NEXT (R10.9 2D): a FOR frame was still open at end of source
;   66 = expected ')' to close a parenthesised expression (R10.9 2D)
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
                                ; must be real RAM, not inline ROM data (an
                                ; earlier version of this file declared this
                                ; as `dw 0` in the code stream, which would
                                ; have been a silent no-op write to ROM once
                                ; assembled into a real ROM image — caught
                                ; before assembling, not at runtime)
                                  ; 0-15 (unchanged address/size from R2)
; R10.7 item 7 overflow tiers: 144 contiguous extra bytes (16 more entries
; * 9B) do not fit in any single genuinely-free gap in this densely-packed
; bank (the largest, $B890-$B900, is only 112 bytes), so entries 16-31 are
; split across two confirmed-free, always-unused gaps instead of relocating
; CSYMTAB_BASE itself (which would cascade-shift LABELTAB/FIXUPTAB/CFOR_
; STACK/SRC_PTR and everything after them — out of scope for this change;
; see the audit's own Option-D reasoning). CSYM_ENTRY_ADDR below picks the
; right tier; this is a compile-time-only lookup, so the extra branch has
; no runtime-performance cost (the audit's performance constraint is about
; RUNTIME variable access, not compile-time identifier resolution).
                                  ; free gap between CSYMTAB_BASE's own
                                  ; real end ($B890) and LABELTAB_BASE
                                  ; ($B900), confirmed free by direct
                                  ; address-collision grep across every
                                  ; v2 file's own equ's before placing this
                                  ; gap between STRSYMTAB_BASE's own real
                                  ; end ($BA84) and DECOMP_FRAG_BASE
                                  ; ($BB00), same confirmed-free discipline

; --- R3 additions: labels, forward-reference fixups, FOR/NEXT loop state ---


                                  ; register-or-inline-data" discipline as
                                  ; CSYM_FIND_NAME_PTR/LEN above
                                  ; offset if found
FOR_LOOP_TOP_OFFSET: equ $BA1C  ; COMPILE_FOR/COMPILE_NEXT scratch (2 bytes):
                                  ; the INNERMOST currently-open loop's own
                                  ; body-starting bytecode offset — i.e. the
                                  ; top-of-FOR_STACK's own cached copy, kept
                                  ; as a plain cell (not re-read from the
                                  ; stack on every use) purely because
                                  ; COMPILE_NEXT/COMPILE_EXIT_FOR already
                                  ; read it this way; COMPILE_FOR/COMPILE_NEXT
                                  ; keep it synchronized with FOR_STACK on
                                  ; every push/pop (see CFOR_STACK_BASE below).
                                  ; Post-R9 nested-FOR/NEXT correction: real
                                  ; nesting up to FOR_NEST_MAX deep is now
                                  ; supported (was a KNOWN, DOCUMENTED single-
                                  ; active-loop limitation before this
                                  ; milestone; see docs/v2/
                                  ; V2_SEMANTIC_CAPABILITY_AUDIT.md S9).
FOR_LOOP_VAR_INDEX: equ $BA1E    ; COMPILE_FOR/COMPILE_NEXT scratch (1 byte):
                                  ; same "innermost loop's own cached copy"
                                  ; role as FOR_LOOP_TOP_OFFSET above.
FOR_FRAME_ADDR_TMP:   equ $B9E9  ; COMPILE_FOR/COMPILE_NEXT scratch (2 bytes): a frame
                                   ; address parked across a call that would clobber it
NEXT_VAR_INDEX_TMP:   equ $B9EB  ; COMPILE_NEXT scratch (1 byte): this NEXT's own variable index
BRANCH_PATCH_TMP:   equ $BA1F   ; COMPILE_BRANCH_TARGET scratch (2 bytes)
RESOLVE_PATCH_TMP:  equ $BA26   ; RESOLVE_ALL_FIXUPS scratch (2 bytes)
STMT_IDENT_NAME_PTR: equ $BA28  ; COMPILE_PROGRAM scratch (2 bytes): the
                                  ; current statement's leading identifier
                                  ; name, saved BEFORE the one-token
                                  ; lookahead that decides label-def vs.
                                  ; assignment overwrites TOK_NAME
STMT_IDENT_NAME_LEN: equ $BA2A   ; (1 byte)
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
                                  ; entries 0-3 (unchanged address/size)
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
; R10.7: widened to 2 bytes (was 1); relocated next to ARR_SIZE_TMP/
; CARR_SIZE above -- the old $BA5B would now collide with rom/exrom_v2_
; vm_core.asm's own VM_EXT_EXEC_PTR at $BA5C.
DIMN_SIZE_TMP:      equ $BDD4   ; R8.5 Group 6 (DIMN) -- COMPILE_DIMN's
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
                                    ; real RAM" discipline as CSYM_FIND_
                                    ; NAME_PTR/LEN above
; R10.7: widened to 2 bytes (was 1); relocated to the old, now-abandoned
; CSYMTAB_BASE address ($B800, freed by that table's own R10.7
; relocation above) rather than widening in place, which would collide
; with CARR_INDEX/CINPUT_INDEX_TMP immediately following at the old
; $BA4C/$BA4E. Placed right after STRARRSYMTAB_BASE's own end
; ($BD70+96=$BDD0) -- CSYMTAB_BASE reverted to its original $B800 (item
; 7's scalar/string/recursion capacity increases were reverted after a
; real regression was found and not safely isolated in time; see docs/
; v2/R10_7_CAPABILITY_RESTORATION.md), so $B800 is no longer free.
ARR_SIZE_TMP:        equ $BDD0   ; COMPILE_DIM's own validated size /
                                    ; ARRSYM_LOOKUP's found-array size
                                    ; output (2 bytes)
CARR_INDEX:          equ $BA4C   ; COMPILE_ARRAY_ASSIGN/COMPILE_FACTOR's
CARR_SIZE:           equ $BDD2    ; R10.7 -- widened to 2 bytes (was 1),
                                    ; relocated next to ARR_SIZE_TMP above
                                    ; for the same reason. own array-read scratch:
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
                                    ; EXIT FOR patch addresses for the
                                    ; loop CURRENTLY being compiled. Post-
                                    ; R9 nested-FOR/NEXT correction: this
                                    ; remains a SINGLE cell (only one loop
                                    ; is ever "currently compiling" at a
                                    ; time in this single-pass compiler),
                                    ; but its value is now saved into the
                                    ; new FOR_STACK frame on entry to a
                                    ; nested FOR and restored from there
                                    ; once that nested loop's own NEXT
                                    ; closes — see CFOR_STACK_BASE below.
; R10.7 dynamic-array redesign: relocated right after the also-relocated
; CSYMTAB_BASE ($BBA0+32*9=$BCC0); the old $B890 free-gap placement no
; longer fits once CSYMTAB itself grew (item 7). REC_LEN widened 10->11
; ([name_len:1][name:8][size_lo:1][size_hi:1] -- size is now 16-bit,
; arena-bounded, not a fixed 16-element ceiling) and MAX_ENTRIES raised
; 4->16 -- an array's compile-time creation order is still its runtime
; ARR_PTR_TABLE slot index (rom/exrom_v2_vm_core.asm), just no longer
; ALSO its fixed runtime-pool slot (that pool no longer exists).

; R10.7 item 3 -- string arrays. Same shape as ARRSYMTAB, plus a 1-byte
; per-element width field (DIM A$(n,w)'s own "w"). Placed right after
; ARRSYMTAB ($BCC0+16*11=$BD70).
; ARRAY_MAX_ELEMS itself is NOT redefined here -- rom/exrom_v2_vm_core.asm
; already defines it, and every v2 test file includes that module before
; this one (the same established cross-file equ-sharing convention this
; compiler already relies on for VM_CODE_BASE); a second `equ` with the
; same name is a real duplicate-label build error, not a style choice.

; Dynamic Data Phase 2 -- string-array compiler scratch. Placed in the
; real free span confirmed by direct address-collision grep: DIMN_
; SIZE_TMP (above) ends at $BDD6; rom/exrom_v2_decompiler.asm's own next
; cell starts at $BE00 -- $BDD6-$BDFF (42 bytes) is genuinely free.
                                       ; DIM'd so far (1 byte)
                                       ; ARRSYM_FIND_NAME_PTR/LEN above
STRARR_SIZE_TMP:         equ $BDDA  ; COMPILE_DIM_STR's own validated
                                       ; count / STRARRSYM_LOOKUP's found
                                       ; count output (2 bytes)
STRARR_WIDTH_TMP:        equ $BDDC  ; COMPILE_DIM_STR's own validated
                                       ; width / STRARRSYM_LOOKUP's found
                                       ; width output (1 byte)
; ($BDDD-$BDDF deliberately left unused here -- the string-array read/
; assign index+count scratch now reuses CARR_INDEX/CARR_SIZE directly,
; shared with the numeric path, same discipline as VM_ARR_ELEM_TMP's own
; cross-kind reuse on the VM side; see COMPILE_ARR_READ_COMMON/COMPILE_
; ARR_ASSIGN_COMMON below.)
COMPILE_ARR_ASSIGN_IS_STR: equ $BDE0 ; COMPILE_ARR_ASSIGN_COMMON/COMPILE_
                                       ; ARR_READ_COMMON's own selector
                                       ; (1 byte): 0 = numeric (COMPILE_
                                       ; EXPR/EMIT_OP_ARR_STORE/LOAD),
                                       ; nonzero = string (COMPILE_STR_
                                       ; EXPR/EMIT_OP_STRARR_STORE/LOAD) --
                                       ; shared tail factored out of
                                       ; COMPILE_ARRAY_ASSIGN/COMPILE_
                                       ; STRARR_ASSIGN and COMPILE_FACTOR.
                                       ; arr_read/COMPILE_STR_FACTOR.
                                       ; strarr_read during the Dynamic
                                       ; Data Phase 2 HOME-budget shrink
                                       ; pass (identical skeletons, only
                                       ; the value-expression compiler and
                                       ; emitted opcode differ)

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
; earlier SPRITE-to-loadable-module move). Token value 58 stays
; unassigned; 56-57 are reused below by DEF FN reintegration (post-R9,
; docs/v2/deffn_design/README.md) -- confirmed free by this same removal.
TOK_KW_DEF:         equ 56   ; DEF FN name(param) = expr
TOK_KW_FN:          equ 57   ; FN name(arg), as an expression factor
TOK_KW_FLASH:       equ 58   ; R10.7 attribute setters (R10.25 class B)
TOK_KW_BRIGHT:      equ 59
TOK_KW_OVER:        equ 60
TOK_KW_INVERSE:     equ 61
TOK_KW_AT:          equ 62   ; R10.7 standalone cursor statements
TOK_KW_TAB:         equ 63
TOK_KW_CLEAR:       equ 64   ; R10.7
TOK_KW_OUT:         equ 65   ; STUDY
TOK_SEMI:           equ 66   ; STUDY: ';' (PRINT/INPUT separator)

; ---------------------------------------------------------------------------
; COMPILER_INIT — call once before COMPILE_PROGRAM.
; ---------------------------------------------------------------------------
COMPILER_INIT:
        xor a
        ld (COMPILE_ERROR_CODE),a
        ld h,a                   ; R10.9 2D: restart the source-line counter
        ld l,a
        ld (LEX_LINE),hl
        call SYM_RESET           ; R10.7 P2: empty tagged symbol table at PROG_END
        ret

; ===========================================================================
; LEXER
; ===========================================================================
; LEX_SKIP_SPACES -- skips spaces and LF ($0A). R10.9 2D (defect D4): CHUNK_APPEND_ONE_RECORD
; writes an LF where a record that ends in ':' would have had its CR; it is white space to the
; lexer but it still ends a source line, so it raises LEX_NEWLINE_PENDING.
;
; LEX_LINE (bits 0-14) is the zero-based index of the source line the lexer is on, which is the
; line-store index of the line responsible for an error raised while the current token is on it
; (V2_JUMP_TO_ERROR_LINE). Bit 15, LEX_NEWLINE_PENDING, means "a line end was consumed and not
; yet counted": a CR token sets it, LEX_NEXT_TOKEN_CORE applies it when the NEXT token is
; fetched. So while the CR itself is the current token -- "x = 1 +" cut off at its end of line --
; LEX_LINE still names its own line. (A CR and an LF can never be adjacent, so one flag is enough.)
LEX_NEWLINE_PENDING: equ 7       ; bit number, in the high byte of LEX_LINE
LEX_SKIP_SPACES:
        ld hl,(SRC_PTR)
.loop:
        ld a,(hl)
        cp ' '
        jr z,.next
        cp $0A
        jr nz,.done
        push hl
        ld hl,LEX_LINE+1
        set LEX_NEWLINE_PENDING,(hl)
        pop hl
.next:
        inc hl
        jr .loop
.done:
        ld (SRC_PTR),hl
        ret

; HL_OUTSIDE_CHUNK_BUF -- shared bounds check (R10.7 source-staging-
; architecture change), used by both LEX_NEXT_TOKEN's refill gate and
; LEX_SCAN_STRING's mid-scan guard. A single unsigned range test serves
; both "HL < CHUNK_BUF" and "HL >= CHUNK_BUF+CHUNK_SIZE": when HL <
; CHUNK_BUF, HL-CHUNK_BUF wraps to a large value that the second
; subtraction also correctly rejects, so no separate short-circuit check
; is needed for that case.
; In:  HL = pointer to test
; Out: carry SET if HL is outside [CHUNK_BUF, CHUNK_BUF+CHUNK_SIZE);
;      carry CLEAR if inside. HL preserved.
; Destroys: AF, DE.
HL_OUTSIDE_CHUNK_BUF:
        push hl
        ld de,CHUNK_BUF
        or a
        sbc hl,de
        ld de,CHUNK_SIZE
        or a
        sbc hl,de               ; carry set here means (HL-CHUNK_BUF) <
                                ; CHUNK_SIZE, i.e. INSIDE -- flip it
        ccf
        pop hl
        ret

; Deliberately NOT gated on V2_RUN_IS_STORED (an exrom_v2_shell.asm flag
; the real shell always sets, but every rom/test_v2_*.asm standalone
; harness does not -- they call COMPILER_INIT/set SRC_PTR directly, so
; that flag would be whatever uninitialized RAM happens to hold). Instead
; this checks where SRC_PTR itself actually points: only inside the chunk
; buffer does refill logic apply -- immediate-mode compiles (SRC_PTR=
; EDIT_LINE_BUF+1) and every standalone test's own SOURCE_TEXT buffer
; fall outside that range and skip this unconditionally, correctly, with
; no dependency on any other flag.
; LEX_NEXT_TOKEN -- fetch the next token into TOK_*. Preserves BC and DE.
; R10.7 P3: the chunk-buffer refill gate in the core below always loads DE
; (CHUNK_MARGIN) and a refill clobbers BC, but callers keep live values in
; BC/DE across this call -- COMPILE_ARR_READ_COMMON holds the array INDEX in B
; and the declared COUNT in DE while it consumes the closing ')'. Without this
; wrapper every array READ emitted count = 128 (the VM validates indices
; against that operand, so out-of-range reads of indices up to 127 went
; unchecked) and, when the ')' sat on a refill boundary, index 0 (the read
; silently returned array 0's element).
LEX_NEXT_TOKEN:
        push bc
        push de
        call LEX_NEXT_TOKEN_CORE
        pop de
        pop bc
        ret

LEX_NEXT_TOKEN_CORE:
        ld hl,(SRC_PTR)
        call HL_OUTSIDE_CHUNK_BUF
        jr c,.no_refill_check
        ld hl,(CHUNK_FILL_PTR)
        ld de,(SRC_PTR)
        or a
        sbc hl,de
        ld de,CHUNK_MARGIN
        or a
        sbc hl,de
        jr nc,.no_refill_check
        call CHUNK_REFILL
.no_refill_check:
        call LEX_SKIP_SPACES
        ld hl,(LEX_LINE)         ; R10.9 2D: count the line end (CR token or LF) just consumed
        bit LEX_NEWLINE_PENDING,h
        jr z,.no_pending
        res LEX_NEWLINE_PENDING,h
        inc hl
        ld (LEX_LINE),hl
.no_pending:
        ld hl,(SRC_PTR)
        ld a,(hl)
        or a
        jr z,.eof
        cp ':'
        jr z,.single1
        cp $0D
        jp z,.newline
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
        jp z,.single10
        cp ';'
        jp z,.semi
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
        and $DF                  ; case-insensitivity: fold a COPY of A
                                  ; for this routing test only -- purely a
                                  ; "does this byte start an identifier?"
                                  ; range check, not an equality compare,
                                  ; so the blind fold is safe here (see
                                  ; FOLD_UPPER's own header for why that
                                  ; distinction matters); LEX_SCAN_IDENT
                                  ; re-reads the real, unfolded byte from
                                  ; (SRC_PTR) itself, so nothing here
                                  ; leaks into stored/compared text. This
                                  ; gate was the ACTUAL reason lowercase
                                  ; BASIC failed end to end (found by this
                                  ; session's own dedicated case-
                                  ; insensitivity test): LEX_SCAN_IDENT's
                                  ; own internal loop already accepted
                                  ; lowercase, but execution never reached
                                  ; it for a lowercase-led token, because
                                  ; THIS gate rejected it first.
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
.newline:
        ld hl,LEX_LINE+1         ; R10.9 2D: a CR is a ':' token that also ends a line
        set LEX_NEWLINE_PENDING,(hl)
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
.semi:
        ld a,TOK_SEMI
        jp .advance1
.number:
        jr LEX_SCAN_NUMBER
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
        call LEX_ACCUM_DIGIT     ; STUDY (D11): shared, range-checked accumulate
        jr nc,.int_digit_loop
        jr LEX_NUMBER_TOO_BIG
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
        call LEX_ACCUM_DIGIT
        jr c,LEX_NUMBER_TOO_BIG
        ld hl,(CNUM_DIVISOR_TMP)
        ld a,h                   ; QUAL (Q-09): the divisor 10^k is 16-bit; a 5th fractional digit
        cp $27                   ; (divisor already 10000 = $2710) wrapped it (0.00001 -> -3.2183 after
        jr nc,LEX_NUMBER_TOO_BIG ; *100000): error 64, as for an over-long mantissa (L-A)
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
        bit 7,d                  ; STUDY: a decimal mantissa >= 32768 would become negative
        jr nz,LEX_NUMBER_TOO_BIG
        ld (TOK_FLOAT_DIVISOR),hl
        ld a,TOK_FLOAT_NUMBER
        ld (TOK_TYPE),a
        ret

; STUDY (D11, literal policy L-A): DE = DE*10 + A (A = digit 0-9).  Carry set = the value would exceed 65535
; (the literal no longer fits the 16-bit TOK_VAL: before, it wrapped modulo 65536 without a word).
; 32768..65535 stay accepted as 16-bit address patterns (POKE 65000,... / USR(61440) keep working);
; a decimal literal's mantissa is limited to 32767 in LEX_SCAN_NUMBER (it is divided as a SIGNED INT16).
; Destroys AF BC HL.
LEX_ACCUM_DIGIT:
        ld c,a
        ld hl,6554
        or a
        sbc hl,de               ; DE >= 6554 -> x10 cannot fit
        jr c,.ovf
        jr z,.ovf
        ld h,d
        ld l,e
        add hl,hl
        add hl,hl
        add hl,de
        add hl,hl               ; HL = DE*10 (<= 65530)
        ld b,0
        add hl,bc
        jr c,.ovf
        ex de,hl
        or a
        ret
.ovf:
        scf
        ret
; The oversized literal is reported where it is: an unexpected token, error 64, on its own line.
LEX_NUMBER_TOO_BIG:
        ld a,TOK_UNKNOWN
        ld (TOK_TYPE),a
        jp ERR_UNEXPECTED_TOKEN

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
; NOTE on case-insensitivity (R10.7 phase 2b): an earlier version of this
; fix canonicalized TOK_NAME here (uppercasing into a single shared fixed
; buffer and repointing TOK_NAME at it). That broke real-ZEsarUX-tested
; nested-compile recursion (PROC/CALL, DEF FN): several call sites save
; TOK_NAME's own POINTER value across a later LEX_NEXT_TOKEN call (e.g.
; STMT_IDENT_NAME_PTR, parked across COMPILE_EXPR for nested "FN other(
; ...)" calls) and expect the pointed-to BYTES to remain stable in the
; meantime -- true when TOK_NAME points into the immutable source text
; (the original, pre-this-fix design), false once it points into one
; shared buffer that the very next identifier/keyword scan overwrites.
; Fix instead applied at the narrower, genuinely-safe point: every
; identifier/keyword NAME COMPARISON folds case on the fly (mirroring
; this project's own already-proven V2_MATCH_PREFIX/V2_MATCH_EXACT
; pattern in rom/exrom_v2_shell.asm), while TOK_NAME keeps pointing at
; real source text throughout, exactly as before. See LEX_CLASSIFY_
; KEYWORD and each symbol table's own FIND_OR_CREATE/LOOKUP compare loop.
;
; FOLD_UPPER -- A -> A folded to uppercase if (and only if) it is
; currently a lowercase letter ('a'-'z'); every other byte (digits, '$',
; punctuation) passes through completely UNCHANGED. A blind "and $DF" is
; UNSAFE wherever the result is compared for exact equality against a
; second byte: '$' (0x24) and every decimal digit (0x30-0x39) each have
; bit 5 set, so an unconditional AND $DF silently corrupts them (a real
; regression found by this session's own regression suite: ext_registry.
; asm's EXT2_LOOKUP uses "LPRINT$" as an internal registration name, and
; a blind fold turned its own '$' into 0x04, permanently failing to
; match its own stored copy; the same blind mistake would have broken
; any symbol name containing a digit, e.g. the decompiler's own
; generated "V0"/"L25" style names). Safe to use a blind "and $DF" only
; for a pure range-MEMBERSHIP test ("is this inside 'A'-'Z'?") where the
; folded result is never itself compared for equality against another
; byte -- LEX_SCAN_IDENT's own `.loop` classification fold above
; qualifies; this routine is for every other case. Destroys: F.
FOLD_UPPER:
        cp 'a'
        ret c
        cp 'z'+1
        ret nc
        and $DF
        ret
; CLAMP_IDENT_LEN -- A = an identifier's length -> A clamped to IDENT_MAX_LEN
; (31). R10.7: a longer name is an explicit compile error (61), never silently
; truncated (two long names sharing a prefix used to merge into one variable).
; Compilation continues with the clamped length so exactly one error is
; reported. SYM_FIND applies it to every symbol lookup; STASH_IDENT_NAME needs
; it for its own bounded copy. Preserves every register but A and F.
CLAMP_IDENT_LEN:
        cp IDENT_MAX_LEN+1
        ret c
        ld a,61
        call COMPILE_RAISE_ERROR
        ld a,IDENT_MAX_LEN
        ret

; NAME_CMP_FOLD -- shared case-insensitive name-compare inner loop, used
; by CSYM/STRSYM/ARRSYM/STRARRSYM_FIND_OR_CREATE's own linear scans and
; LABEL_LOOKUP alike (identical ~16-17 byte loop body previously
; duplicated 5x; HOME-budget shrink pass). Input: HL/DE = the two name
; pointers to compare, B = remaining length (>=1, caller's own stack-
; saved copy -- this routine does not touch the hardware stack itself,
; just an ordinary call/ret, so the caller's surrounding push bc/pop bc
; is unaffected). Output: Z set if every byte matched after case-
; folding (HL/DE left one past the last compared byte); Z clear on the
; first mismatch (HL/DE left AT the mismatching pair, matching this
; loop's own prior in-place behavior, in case any caller ever wants it).
; Destroys: AF, BC, HL, DE (HL/DE are also outputs, advanced in place).
NAME_CMP_FOLD:
.loop:
        ld a,(de)
        call FOLD_UPPER
        ld c,a
        ld a,(hl)
        call FOLD_UPPER
        cp c
        ret nz
        inc hl
        inc de
        djnz .loop
        ret

LEX_SCAN_IDENT:
        ld hl,(SRC_PTR)
        ld (TOK_NAME),hl
        ld b,0
.loop:
        ld a,(hl)
        and $DF                  ; case-insensitivity: fold lowercase to
                                  ; uppercase for this A-Z classification
                                  ; test only (safe for digits/punctuation
                                  ; too -- they fall outside 'A'-'Z' either
                                  ; way); the source byte at (hl) itself is
                                  ; untouched, only this copy in A
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
        jp LEX_CLASSIFY_KEYWORD

; LEX_SCAN_STRING — a "quoted" string literal (R5 addition). No escape
; sequences (a documented happy-path gap, matching this project's own
; established scope discipline for every milestone so far).
;
; R10.9 Phase 2D (defect D3): a string never spans a source line. A control
; character (NUL = end of source, CR / LF = end of line) before the closing '"'
; makes the token TOK_UNKNOWN, left unconsumed, and raises error 64 at once, so an
; unterminated string is a compile error on its own line instead of silently
; swallowing the following lines (the pre-2D behaviour, which also made line
; counting impossible).
; Because a string now lies inside one record, and records are appended to the
; chunk buffer whole, the scan can never run off the loaded data: the mid-scan
; CHUNK_REFILL logic R10.7 needed for multi-record strings is gone.
LEX_SCAN_STRING:
        ld hl,(SRC_PTR)
        inc hl                   ; skip the opening '"'
        ld (TOK_NAME),hl
        ld b,0
.loop:
        ld a,(hl)
        cp '"'
        jr z,.closed
        cp ' '
        jr c,.unterminated
        inc hl
        inc b
        jr .loop
.closed:
        inc hl                   ; consume the closing quote
        ld (SRC_PTR),hl
        ld a,b
        ld (TOK_LEN),a
        ld a,TOK_STRING
        ld (TOK_TYPE),a
        ret
.unterminated:
        ld (SRC_PTR),hl
        ld a,TOK_UNKNOWN
        ld (TOK_TYPE),a
        jp ERR_UNEXPECTED_TOKEN

; ============================================================================
; CHUNK_APPEND_ONE_RECORD -- R10.7 source-staging-architecture change
; (docs/v2/R10_7_SOURCE_STAGING_ARCHITECTURE_AUDIT.md). Appends exactly one
; authoritative line-store record (CHUNK_NEXT_REC) to the chunk buffer at
; CHUNK_FILL_PTR: strips the record's 2-byte length header, copies content
; up to its own trailing $0D, then applies the SAME colon-continuation
; suppression the old whole-program V2_BUILD_SOURCE always used (append a
; real $0D unless the content just copied ends in ':', and unless nothing
; has been written yet at all -- this second case only arises for a
; genuinely empty-content record, not "is this chunk's first record",
; since CHUNK_FILL_PTR can equal CHUNK_BUF after a mid-program compaction
; too). R10.9 2D: a suppressed CR is replaced by an LF ($0A), which the
; lexer skips as white space but counts as a line end (LEX_LINE), so
; every record contributes exactly one terminator and the lexer's line
; count is the line-store index. Advances CHUNK_FILL_PTR and advances
; CHUNK_NEXT_REC to its successor. If that successor is 0 (no more
; records), appends the true EOF $00 sentinel immediately.
; In:  none (reads CHUNK_NEXT_REC/CHUNK_FILL_PTR)
; Out: none
; Destroys: AF, BC, DE, HL
; ============================================================================
CHUNK_APPEND_ONE_RECORD:
        ld hl,(CHUNK_NEXT_REC)
        push hl
        inc hl
        inc hl
        ld de,(CHUNK_FILL_PTR)
.copy:
        ld a,(hl)
        cp $0D
        jr z,.end_line
        ld (de),a
        inc de
        inc hl
        jr .copy
.end_line:
        ld a,e
        cp LOW CHUNK_BUF
        jr nz,.check_last
        ld a,d
        cp HIGH CHUNK_BUF
        jr z,.append_cr
.check_last:
        dec de
        ld a,(de)
        inc de
        cp ':'
        ld a,$0A                 ; a record ending in ':' continues the statement
        jr z,.store_end
.append_cr:
        ld a,$0D
.store_end:
        ld (de),a
        inc de
.next_record:
        ld (CHUNK_FILL_PTR),de
        pop hl
    IFDEF KERNEL_MEMORY_PRESENT
        call MEM_LINE_NEXT
    ELSE
        ; kernel/memory.asm isn't linked in this build (a compiler-only
        ; standalone test harness -- see KERNEL_MEMORY_PRESENT's own
        ; header comment). CHUNK_REFILL is bounds-checked and never
        ; actually called in that configuration; this exists only so the
        ; reference to MEM_LINE_NEXT doesn't become a hard link error.
        ld hl,0
    ENDIF
        ld (CHUNK_NEXT_REC),hl
        ld a,h
        or l
        ret nz
        ld de,(CHUNK_FILL_PTR)
        xor a
        ld (de),a
        ; R10.7 Phase 6 production-bug fix: the EOF terminator byte just
        ; written at CHUNK_FILL_PTR was never included in the buffer's
        ; own tracked [SRC_PTR, CHUNK_FILL_PTR) remainder range (this
        ; write doesn't advance CHUNK_FILL_PTR past it) -- so any LATER
        ; CHUNK_REFILL call (every LEX_NEXT_TOKEN does one) compacts the
        ; still-unread remainder down to CHUNK_BUF but leaves the NUL
        ; behind, uncopied, replaced at its new post-compaction position
        ; by whatever stale byte already sat there from an earlier fill.
        ; The lexer then reads that stale byte as if it were more source
        ; text instead of stopping at end-of-program -- found live via
        ; ts2068-debug on a real "FOR i = 1 TO 20 / PRINT i / NEXT i"
        ; three-line program: compiled correctly through FOR and up to
        ; PRINT, then spuriously failed with COMPILE_ERROR_CODE=2 after
        ; NEXT once the lexer ran into the lost terminator's garbage.
        ; Advancing CHUNK_FILL_PTR past the NUL here means it IS inside
        ; the remainder every subsequent compaction preserves.
        inc de
        ld (CHUNK_FILL_PTR),de
        ret

; ============================================================================
; CHUNK_REFILL -- shared refill core for both the between-token top-up
; (LEX_NEXT_TOKEN) and the mid-string-scan boundary case (LEX_SCAN_STRING).
; Compacts the buffer (discards bytes before the current anchor, which the
; caller has placed in SRC_PTR -- either the real SRC_PTR, or the string
; scan's own TOK_NAME, temporarily, per LEX_SCAN_STRING's own comment),
; shifting the still-needed remainder down to CHUNK_BUF, then appends
; records one at a time until at least CHUNK_MARGIN bytes are available or
; no more records remain. SRC_PTR always ends this call equal to CHUNK_BUF.
; KTAB entry (KTAB_CHUNK_REFILL) exists solely so EXROM-resident
; V2_BUILD_SOURCE can reach this HOME-resident routine for the initial
; priming fill; the lexer's own two call sites below are same-bank, direct.
; In:  SRC_PTR = anchor (earliest buffer byte that must survive)
; Out: SRC_PTR = CHUNK_BUF
; Destroys: AF, BC, DE, HL
; ============================================================================
CHUNK_REFILL:
        ld hl,(CHUNK_FILL_PTR)
        ld de,(SRC_PTR)
        or a
        sbc hl,de
        ld b,h
        ld c,l
        ld a,b
        or c
        jr z,.no_remainder
        push bc                  ; LDIR decrements BC to 0 as it completes
                                  ; -- save the remainder length across it,
                                  ; or the add hl,bc below silently uses 0
                                  ; instead of the real shifted length (the
                                  ; one real bug this mechanism's first
                                  ; implementation had: the next-appended
                                  ; record's own bytes ended up overwriting
                                  ; the just-shifted remainder at CHUNK_BUF
                                  ; instead of following it, since
                                  ; CHUNK_FILL_PTR came out equal to
                                  ; CHUNK_BUF; found live via ts2068-debug
                                  ; single-stepping, not by inspection).
        ld hl,(SRC_PTR)
        ld de,CHUNK_BUF
        ldir
        pop bc
.no_remainder:
        ld hl,CHUNK_BUF
        ld (SRC_PTR),hl
        add hl,bc
        ld (CHUNK_FILL_PTR),hl
.fill_loop:
        ld hl,(CHUNK_NEXT_REC)
        ld a,h
        or l
        jr z,.done
        ld hl,(CHUNK_FILL_PTR)
        ld de,CHUNK_BUF
        or a
        sbc hl,de
        ld de,CHUNK_MARGIN
        or a
        sbc hl,de
        jr nc,.done
        call CHUNK_APPEND_ONE_RECORD
        jr .fill_loop
.done:
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
        call FOLD_UPPER           ; case-insensitivity: fold the as-typed
                                  ; source byte; KEYWORD_TABLE's own text
                                  ; is always stored uppercase already
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

; V2_GET_KEYWORD_TABLE -- R10 keyword-bolding prototype. Exposed via
; KTAB_GET_KEYWORD_TABLE (include/v2_ktab.inc) so EXROM-resident redraw
; code can locate the real KEYWORD_TABLE data below without duplicating
; it: HOME occupies a disjoint, always-visible address range from
; EXROM's own $C000-$DFFF chunk (kernel/bank/bank.asm's own header:
; "Every other chunk stays Home"), so EXROM code can read HOME ROM data
; directly once it knows the real address -- this one tiny stub is the
; only thing that needs to live in HOME; the actual scan/match logic
; lives in EXROM (rom/exrom_v2_shell.asm's V2_KW_DETECT_SPANS).
; Out: HL = KEYWORD_TABLE address, A = KEYWORD_TABLE_COUNT.
V2_GET_KEYWORD_TABLE:
        ld hl,KEYWORD_TABLE
        ld a,KEYWORD_TABLE_COUNT
        ret

KEYWORD_TABLE_COUNT: equ 44  ; R10.7 adds FLASH/BRIGHT/OVER/INVERSE/AT/
                             ; TAB/CLEAR (7) on top of the post-R9 DEF
                             ; FN reintegration count below

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
        db 3, "DEF", TOK_KW_DEF       ; post-R9 DEF FN reintegration
        db 2, "FN", TOK_KW_FN
        db 5, "FLASH", TOK_KW_FLASH   ; R10.7 capability restoration
        db 6, "BRIGHT", TOK_KW_BRIGHT
        db 4, "OVER", TOK_KW_OVER
        db 7, "INVERSE", TOK_KW_INVERSE
        db 2, "AT", TOK_KW_AT
        db 3, "TAB", TOK_KW_TAB
        db 5, "CLEAR", TOK_KW_CLEAR
        db 3, "OUT", TOK_KW_OUT     ; STUDY

; ===========================================================================
; COMPILE-TIME SYMBOL TABLE — real name storage, real comparison (the piece
; the sizing spikes explicitly stubbed out).
; ===========================================================================

; The tagged compile symbol table (CSYM/STRSYM/ARRSYM/STRARRSYM find-or-create,
; lookup and the SYM_FIND/SYM_ADD core) lives in rom/exrom_v2_symtab.asm.
    INCLUDE "rom/exrom_v2_symtab.asm"

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

EMIT_BYTE_OP_PUSH_I8:      ld a,1  : jr EMIT_BYTE
EMIT_BYTE_OP_PUSH_I16:     ld a,2  : jr EMIT_BYTE
EMIT_BYTE_OP_LOAD_VAR:     ld a,3  : jr EMIT_BYTE
EMIT_BYTE_OP_STORE_VAR:    ld a,4  : jr EMIT_BYTE
EMIT_OP_ADD:               ld a,5  : jr EMIT_BYTE
EMIT_OP_SUB:               ld a,7  : jr EMIT_BYTE
EMIT_OP_MUL:               ld a,8  : jr EMIT_BYTE
EMIT_OP_DIV:               ld a,9  : jr EMIT_BYTE
EMIT_OP_HALT:              xor a   : jr EMIT_BYTE
EMIT_OP_JMP:               ld a,6  : jr EMIT_BYTE
EMIT_OP_JMPZ:              ld a,12 : jr EMIT_BYTE
EMIT_OP_FOR_INIT:          ld a,13 : jr EMIT_BYTE
EMIT_OP_FOR_NEXT:          ld a,14 : jr EMIT_BYTE
EMIT_OP_CMP_LT:            ld a,10 : jr EMIT_BYTE
EMIT_OP_CMP_EQ:            ld a,11 : jr EMIT_BYTE
EMIT_OP_CALL:              ld a,15 : jr EMIT_BYTE
EMIT_OP_RET:               ld a,16 : jr EMIT_BYTE
EMIT_BYTE_OP_PUSH_STR_LIT: ld a,17 : jr EMIT_BYTE
EMIT_OP_STORE_STR_VAR:     ld a,18 : jr EMIT_BYTE
EMIT_OP_STR_CONCAT:        ld a,19 : jr EMIT_BYTE
EMIT_OP_STR_CMP_LT:        ld a,20 : jr EMIT_BYTE
EMIT_OP_STR_CMP_EQ:        ld a,21 : jr EMIT_BYTE
EMIT_BYTE_OP_PUSH_FLOAT_LIT: ld a,22 : jr EMIT_BYTE
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
EMIT_OP_FOR_POP:                            ld a,55 : jp EMIT_BYTE  ; post-R9
                                             ; nested FOR/NEXT (52-54 stay
                                             ; reserved for DEF FN)
EMIT_OP_PARAM_BIND:                         ld a,56 : jp EMIT_BYTE  ; post-R9
                                             ; PROC/DEF FN recursion safety
EMIT_OP_PARAM_UNBIND:                       ld a,57 : jp EMIT_BYTE
; DEF FN reintegration (post-R9, docs/v2/deffn_design/README.md):
; opcodes 52/53/54 are runtime-IDENTICAL to JMP/CALL/RET (literally the
; same VM_OP_TABLE handler at those slots) -- purely a compile-time/
; decompile-time disambiguation, the same precedent OP_JMP_ELSE (47)
; already established.
EMIT_OP_JMP_DEFFN:                          ld a,52 : jp EMIT_BYTE
EMIT_OP_CALL_UDF:                           ld a,53 : jp EMIT_BYTE
EMIT_OP_RET_DEFFN:                          ld a,54 : jp EMIT_BYTE
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
EMIT_OP_FLASH:      ld a,37 : jp EMIT_BYTE  ; R10.7
EMIT_OP_BRIGHT:      ld a,38 : jp EMIT_BYTE  ; R10.7
EMIT_OP_OVER:         ld a,58 : jp EMIT_BYTE  ; R10.7
EMIT_OP_INVERSE:       ld a,59 : jp EMIT_BYTE  ; R10.7
EMIT_OP_AT:             ld a,60 : jp EMIT_BYTE  ; R10.7
EMIT_OP_TAB:             ld a,61 : jp EMIT_BYTE  ; R10.7
EMIT_OP_CLEAR:            ld a,62 : jp EMIT_BYTE  ; R10.7
EMIT_OP_DIM:               ld a,63 : jp EMIT_BYTE  ; R10.7 dynamic arrays
EMIT_OP_DIM_STR:            ld a,64 : jp EMIT_BYTE  ; Dynamic Data Phase 2
EMIT_OP_STRARR_LOAD:         ld a,65 : jp EMIT_BYTE  ; -- string arrays
EMIT_OP_STRARR_STORE:         ld a,66 : jp EMIT_BYTE
EMIT_OP_OUT:                  ld a,67 : jp EMIT_BYTE  ; STUDY
EMIT_OP_NL:                   ld a,68 : jp EMIT_BYTE  ; STUDY: end the PRINT line
EMIT_OP_PRINT_COMMA:          ld a,69 : jp EMIT_BYTE  ; STUDY: tab to the next 16-column zone

; COMPILE_RELATIVE_OFFSET — R10.5 shrink: factors out the "current
; bytecode position, relative to VM_CODE_BASE" computation duplicated at
; nine call sites (label/fixup patching, IF/FOR/PROC skip-jump targets).
; Output: HL = EMIT_PTR - VM_CODE_BASE. Flags are the raw sbc result;
; no caller here branches on them, only uses HL/DE afterward. Behavior
; unchanged; see docs/v2/R10_5_SHRINK.md.
COMPILE_RELATIVE_OFFSET:
        ld hl,(EMIT_PTR)
        ld de,VM_CODE_BASE
        or a
        sbc hl,de
        ret

; EMIT_PLACEHOLDER_16 — writes two dummy zero bytes (a forward-reference
; branch target not yet known), returns the ABSOLUTE address of the first
; of those two bytes in HL, for RESOLVE_ALL_FIXUPS to patch later.
EMIT_PLACEHOLDER_16:
        ld hl,(EMIT_PTR)
        push hl
        xor a
        rst $20
        rst $20
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
        call COMPILE_STACK_CHECK
        ret c
        call COMPILE_BOOL_AND
.loop:
        ld a,(TOK_TYPE)
        cp TOK_KW_OR
        jr nz,.done
        rst $08
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
        rst $08
        call COMPILE_BOOL_NOT
        call EMIT_OP_AND
        jr .loop
.done:
        ret

COMPILE_BOOL_NOT:
        ld a,(TOK_TYPE)
        cp TOK_KW_NOT
        jr nz,COMPILE_RELATIONAL
        rst $08
        call COMPILE_BOOL_NOT   ; recurses on itself, not COMPILE_RELATIONAL
                                  ; directly, so "NOT NOT X" (double
                                  ; negation) also parses, same reasoning
                                  ; COMPILE_FACTOR's own unary-minus
                                  ; recursion already uses
        jp EMIT_OP_NOT

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
        rst $08
        call COMPILE_ADDITIVE
        jp EMIT_OP_CMP_LT
.do_le:
        rst $08
        call COMPILE_ADDITIVE
        jp EMIT_OP_CMP_LE
.do_eq:
        rst $08
        call COMPILE_ADDITIVE
        jp EMIT_OP_CMP_EQ
.do_ge:
        rst $08
        call COMPILE_ADDITIVE
        jp EMIT_OP_CMP_GE
.do_gt:
        rst $08
        call COMPILE_ADDITIVE
        jp EMIT_OP_CMP_GT
.do_ne:
        rst $08
        call COMPILE_ADDITIVE
        jp EMIT_OP_CMP_NE

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
        rst $08
        call COMPILE_TERM
        call EMIT_OP_ADD
        jr .loop
.do_sub:
        rst $08
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
        rst $08
        call COMPILE_FACTOR
        call EMIT_OP_MUL
        jr .loop
.do_div:
        rst $08
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
        cp TOK_KW_FN
        jp z,.udf_call           ; post-R9 DEF FN reintegration
        ld a,3
        rst $30
.unary_minus:
        rst $08                 ; consume '-'
        ld a,(TOK_TYPE)          ; QUAL (Q-05): -<integer literal> is folded at compile time. With
        cp TOK_NUMBER            ; literal rule L-A, `-32768` used to compile as 0 - $8000, which the
        jr nz,.neg_expr          ; D11 promotion turned into +32768.0000
        ld hl,(TOK_VAL)
        call MATH_NEGATE16
        ld (TOK_VAL),hl
        jr .number
.neg_expr:
        call EMIT_BYTE_OP_PUSH_I8
        xor a
        rst $20                  ; push literal 0
        call COMPILE_FACTOR      ; the operand -X applies to
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        jp EMIT_OP_SUB
.paren:
        rst $08
        call COMPILE_EXPR
        ld a,(TOK_TYPE)         ; R10.9 2D (defect D3): ')' is now required
        cp TOK_RPAREN
        jp z,LEX_NEXT_TOKEN     ; consume ')'
        ld a,66                 ; expected ')' to close a parenthesised expression
        rst $30
.number:
        call COMPILE_NUMBER_LITERAL
        jp LEX_NEXT_TOKEN
.float_number:
        call COMPILE_FLOAT_LITERAL
        jp LEX_NEXT_TOKEN
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
        ld de,(TOK_NAME)
        ld hl,DIMN_KEYWORD_TEXT
        ld b,4
.dimn_cmp:
        ld a,(de)
        call FOLD_UPPER           ; case-insensitivity fix (R10.7 dormant-
                                  ; ROM audit, docs/v2/R10_7_DORMANT_ROM_
                                  ; CONSOLIDATION_AUDIT.md): this hand-
                                  ; rolled compare was missed when every
                                  ; other name-compare site in this file
                                  ; got FOLD_UPPER -- "dimn(x)"/"Dimn(x)"
                                  ; silently fell through to being parsed
                                  ; as a plain identifier instead of the
                                  ; DIMN builtin. DIMN_KEYWORD_TEXT is a
                                  ; constant, already uppercase (like
                                  ; KEYWORD_TABLE), so this single-side
                                  ; fold mirrors LEX_CLASSIFY_KEYWORD's
                                  ; own proven pattern exactly.
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
        jp LEX_NEXT_TOKEN
.arr_read:
        push af                    ; A = array index, preserve across the
        xor a                        ; flag-set below
        ld (COMPILE_ARR_ASSIGN_IS_STR),a
        pop af
        ld hl,(ARR_SIZE_TMP)
        jp COMPILE_ARR_READ_COMMON
.fn_call:
        ld (CFN_INDEX),a
        ld a,(BFN_FOUND_ARGCOUNT)
        ld (CFN_ARGCOUNT),a
        ld (CFN_REMAINING),a
        ld a,(BFN_FOUND_ARGTYPE)
        ld (CFN_ARGTYPE),a
        rst $08                   ; consume the function name
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.fn_have_lparen
        ld a,29                    ; expected '(' after a built-in
        rst $30
.fn_have_lparen:
        rst $08                     ; consume '('
        ld a,(CFN_INDEX)
        cp 25                        ; FREE: "FREE()" or "FREE(n)" (P5.5)
        jr nz,.fn_not_free
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.fn_not_free
        ld a,29
        ld (CFN_INDEX),a
        ld a,1
        ld (CFN_ARGCOUNT),a
        ld (CFN_REMAINING),a
.fn_not_free:
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
        rst $30
.fn_have_comma:
        rst $08
        jr .fn_arg_loop
.fn_rparen:
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.fn_have_rparen
        ld a,31                      ; expected ')' to close a built-in
        rst $30
.fn_have_rparen:
        rst $08                        ; consume ')'
        call EMIT_OP_CALL_FN
        ld a,(CFN_INDEX)
        jp EMIT_BYTE

; .udf_call — FN name(arg), as an expression factor (post-R9 DEF FN
; reintegration, docs/v2/deffn_design/README.md). Resolved via the SAME
; LABEL_LOOKUP/FIXUP_RECORD forward-reference machinery GOTO/CALL
; already use (not a new mechanism) -- mirrors COMPILE_CALL_STMT's own
; resolve/fixup logic almost verbatim, differing only in what opcode it
; emits and that it's an expression factor, not a statement.
.udf_call:
        rst $08                 ; consume FN
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.udf_have_name
        ld a,50                  ; expected a function name (shared with
        rst $30                   ; DEF FN's own identical error)
.udf_have_name:
        call STASH_IDENT_AND_PEEK
        cp TOK_LPAREN
        jr z,.udf_have_lparen
        ld a,51                  ; expected '(' after a name
        rst $30
.udf_have_lparen:
        rst $08                 ; consume '('
        ; Because compiling the argument expression can itself
        ; recursively compile a NESTED "FN othername(...)" call using the
        ; SAME shared STMT_IDENT_NAME_PTR/LEN scratch cells, park this
        ; call's own name on the hardware stack first -- the exact
        ; nested-call scratch-clobber lesson Group 6's CFN_INDEX/
        ; ARGCOUNT/REMAINING/ARGTYPE fix (.fn_call above) and COMPILE_
        ; FACTOR.arr_read's CARR_INDEX/SIZE fix already taught this
        ; project, applied here proactively before any bug manifested
        ; (docs/v2/deffn_design/README.md's own documented precaution
        ; from the original experiment).
        ;
        ; R10.7 source-staging-architecture change: STMT_IDENT_NAME_PTR
        ; is now always STMT_IDENT_NAME_BUF (a fixed address STASH_IDENT_
        ; AND_PEEK writes into, never the live chunk buffer -- see that
        ; routine's own header). Parking just the POINTER value no longer
        ; protects anything, since it is now a constant; what must be
        ; parked is the BUFFER'S OWN CONTENT, since a nested call's own
        ; STASH_IDENT_AND_PEEK overwrites that same fixed buffer. Parked/
        ; restored as a whole-buffer block copy (see below).
        call COMPILE_EXPR_KEEPNAME ; argument -> VM operand stack (stashed name preserved)
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.udf_have_rparen
        ld a,53                  ; expected ')'
        rst $30
.udf_have_rparen:
        rst $08                 ; consume ')'
        call EMIT_OP_CALL_UDF
        call EMIT_PLACEHOLDER_16   ; HL = patch address
        ex de,hl                 ; DE = the operand slot just emitted
        ld hl,(STMT_IDENT_NAME_PTR)
        ld a,(STMT_IDENT_NAME_LEN)
        ld b,a
        jp LABEL_REF             ; defined: patched now; else threaded on the chain

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
; COMPILE_ARR_READ_COMMON — shared array-read skeleton for both numeric
; (A(expr)) and string (A$(expr)) array reads, factored out of
; COMPILE_FACTOR's own .arr_read branch and COMPILE_STR_FACTOR's
; .strarr_read branch during the Dynamic Data Phase 2 HOME-budget
; shrink pass (identical skeleton, differing only in which opcode gets
; emitted -- selected via COMPILE_ARR_ASSIGN_IS_STR, set by the caller,
; the same flag cell COMPILE_ARR_ASSIGN_COMMON already uses). Input:
; A = array index, HL = declared element count; the array NAME token is
; still the CURRENT token (not yet consumed).
;
; BUG FOUND (real hardware, R8.5 Group 4): the index sub-expression
; compiled next can itself contain a NESTED array read (e.g.
; "A(B(0))") -- this same CARR_INDEX/CARR_SIZE pair would otherwise be
; overwritten by that inner read before this outer read's own EMIT
; below gets to use it. Same "shared scratch clobbered by a nested
; compile call" bug class COMPILE_IF_BLOCK already hit and fixed with
; hardware-stack push/pop (see its own header) -- applying the
; identical fix here: park this read's own index (B) and count (DE)
; across the recursive COMPILE_EXPR call.
COMPILE_ARR_READ_COMMON:
        ld (CARR_INDEX),a
        ld (CARR_SIZE),hl
        rst $08                     ; consume the array name, fetch next
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.have_lparen
        ld a,40
        rst $30
.have_lparen:
        rst $08                      ; consume '('
        ld a,(CARR_INDEX)
        ld b,a
        ld de,(CARR_SIZE)
        push bc
        push de
        call COMPILE_EXPR
        pop de
        pop bc
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        ld a,41
        rst $30
.have_rparen:
        rst $08                       ; consume ')'
        ld a,(COMPILE_ARR_ASSIGN_IS_STR)
        or a
        jr nz,.emit_str
        call EMIT_OP_ARR_LOAD
        jr EMIT_ARR_OPERAND
.emit_str:
        call EMIT_OP_STRARR_LOAD
        jr EMIT_ARR_OPERAND

; EMIT_ARR_OPERAND — shared [index:1][count:2] bytecode-operand emit,
; the common tail of both COMPILE_ARR_READ_COMMON and COMPILE_ARR_
; ASSIGN_COMMON (same three bytes, same order, after either an ARR_LOAD/
; STORE or STRARR_LOAD/STORE opcode byte has already been emitted by the
; caller). Input: B = array index, D/E = declared count, high/low.
EMIT_ARR_OPERAND:
        ld a,b
        rst $20
        ld a,e
        rst $20
        ld a,d
        jp EMIT_BYTE

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
        call FOLD_UPPER           ; case-insensitivity: fold the as-typed
                                  ; source byte only -- BUILTIN_FN_TABLE's
                                  ; own text is always stored uppercase
                                  ; already, and C is this loop's own live
                                  ; remaining-length countdown (not saved
                                  ; around the loop the way CSYM/STRSYM/
                                  ; ARRSYM/STRARRSYM/LABELTAB's B-countdown
                                  ; loops push/pop BC), so it must not be
                                  ; used as fold scratch here
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

BUILTIN_FN_TABLE_COUNT: equ 32

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
; MID$ (fn_index 28): R10.7, R10.25 class C. 3 args (s$, start, len);
; only arg0 is a string (argtype $81, same bit layout as LEFT$/RIGHT$ --
; bit0 set = arg0 string, bit7 set = result string; bits 1-2 clear =
; start/len are both numeric).
    db 3, "MID", 3, 28, $81
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
; FREE (fn_index 25): 0 args, always a real int — R10.25 class B item,
; wraps kernel/memory/memory.asm's own MEM_FREE_BYTES (already labeled
; "Backs BASIC's FREE()" in its own header).
    db 4, "FREE", 0, 25, 0
; FREE(n) (fn_index 29): R10.7 P5.5 -- same name, one argument. BUILTIN_FN_FIND
; always matches the 0-arg row above first; .fn_have_lparen switches to this
; index when the call has an argument. FREE(1) = bytes free in array segment 2.
    db 4, "FREE", 1, 29, 0
; COS/TAN (fn_index 26-27): R10.7, R10.25 class C. Int-only argument
; (matching RAD/DEG/SIN's own contract), always a real float result.
    db 3, "COS", 1, 26, 0
    db 3, "TAN", 1, 27, 0
    db 2, "IN", 1, 30, 0          ; STUDY: IN(port), full 16-bit port address
    db 5, "STICK", 1, 31, 0       ; STUDY: STICK(1|2), Timex joystick via AY port A

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
        jp EMIT_BYTE
.wide:
        call EMIT_BYTE_OP_PUSH_I16
        ld a,e
        rst $20
        ld a,d
        jp EMIT_BYTE

; COMPILE_FLOAT_LITERAL — emits PUSH_FLOAT_LIT's 4-byte operand: TOK_VAL
; (the literal's digits) then TOK_FLOAT_DIVISOR (10^fractional-digits),
; both as plain 2-byte little-endian values. The VM computes value/
; divisor as a real float at runtime, via the calculator — this compiler
; never encodes a float itself.
COMPILE_FLOAT_LITERAL:
        call EMIT_BYTE_OP_PUSH_FLOAT_LIT
        ld de,(TOK_VAL)
        ld a,e
        rst $20
        ld a,d
        rst $20
        ld de,(TOK_FLOAT_DIVISOR)
        ld a,e
        rst $20
        ld a,d
        jp EMIT_BYTE

COMPILE_IDENT_LOAD:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
.len_ok:
        ld b,a
        call CSYM_FIND_OR_CREATE
        ld (IDENT_LOAD_INDEX),a
        call EMIT_BYTE_OP_LOAD_VAR
        ld a,(IDENT_LOAD_INDEX)
        jp EMIT_BYTE

; STASH_IDENT_NAME -- copies the CURRENT identifier token (TOK_NAME/
; TOK_LEN) into the fixed STMT_IDENT_NAME_BUF/STMT_IDENT_NAME_PTR/LEN
; cells, clamped to 8 bytes (same clamp every FIND_OR_CREATE/LOOKUP call
; site already applies). Does NOT advance the lexer -- callers that also
; need the next token call LEX_NEXT_TOKEN themselves afterward (see
; STASH_IDENT_AND_PEEK below, and COMPILE_PROC/COMPILE_DEF_FN's own
; "have_name" labels, which used to inline this exact copy with a bare
; pointer instead of calling it -- see this routine's own R10.7 note).
;
; R10.7 source-staging-architecture change: this now COPIES the
; identifier's bytes into a fixed buffer rather than just storing a
; pointer into the live chunk buffer. Any subsequent LEX_NEXT_TOKEN call
; can trigger a refill; the identifier just scanned is already behind
; SRC_PTR by then (outside the region a refill preserves), so a bare
; pointer into the old buffer position would read wrong, overwritten
; content by the time a caller actually uses it for a symbol-table
; lookup (LABEL_DEFINE, CSYM_FIND_OR_CREATE, etc.). Found live (an array
; assignment failed "never DIM'd" even though DIM had already run, and
; separately a GOTO/PROC/DEF-FN label failed "undefined" even though it
; was defined) via ts2068-debug single-stepping, not by inspection.
; COMPILE_PROC and COMPILE_DEF_FN each had their OWN inline copy of the
; old, unsafe pattern (not routed through the shared helper at all) --
; both now call this routine instead, fixing all three sites at once and
; removing the duplication.
; Destroys: AF, BC, DE, HL.
STASH_IDENT_NAME:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        call CLAMP_IDENT_LEN          ; R10.7 P2: an over-long name is error 61, never
        ld (STMT_IDENT_NAME_LEN),a ; silently truncated (the label/PROC/FN sites
                                   ; used to pass the UNclamped length)
        ld de,STMT_IDENT_NAME_BUF
        or a
        jr z,.copy_done
        ld b,a
.copy:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .copy
.copy_done:
        ld hl,STMT_IDENT_NAME_BUF
        ld (STMT_IDENT_NAME_PTR),hl
        ret

; STASH_IDENT_AND_PEEK -- shared one-token-lookahead prologue: saves the
; CURRENT identifier token via STASH_IDENT_NAME above, consumes it, and
; returns A = the NEXT token's own TOK_TYPE (already fetched) for the
; caller to test -- identical logic previously duplicated across DEF FN/
; PROC/CALL name parsing and the numeric/string statement-identifier
; dispatch (HOME-budget shrink pass).
; Destroys: AF, BC, DE, HL.
STASH_IDENT_AND_PEEK:
        call STASH_IDENT_NAME
        rst $08
        ld a,(TOK_TYPE)
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
.len_ok:
        ld b,a
        call CSYM_FIND_OR_CREATE
        ld (ASSIGN_TARGET_INDEX),a   ; memory, not a register — see the
                                       ; equ's own comment for why
        ld a,(TOK_TYPE)
        cp TOK_ASSIGN
        jr z,.have_assign
        jp ERR_EXPECTED_ASSIGN
.have_assign:
        rst $08                 ; consume '='
        call COMPILE_EXPR
        call EMIT_BYTE_OP_STORE_VAR
        ld a,(ASSIGN_TARGET_INDEX)
        jp EMIT_BYTE

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
        rst $08                   ; consume DIM, fetch the array name
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_ident
        cp TOK_STR_IDENT          ; Dynamic Data Phase 2 -- DIM A$(n[,w])
        jr z,COMPILE_DIM_STR
        ld a,32
        rst $30
.have_ident:
        ; R10.7 source-staging-architecture change: this used to stash
        ; TOK_NAME directly into ARRSYM_FIND_NAME_PTR (ARRSYM_FIND_OR_
        ; CREATE's own internal scratch cell, borrowed here as a
        ; premature cache) and read it back after the '('/size/')'
        ; tokens below were consumed -- a bare pointer into the live
        ; chunk buffer, exactly STMT_IDENT_NAME_PTR's own bug class (see
        ; STASH_IDENT_NAME's header). A refill during any of those
        ; intervening LEX_NEXT_TOKEN calls could relocate the array
        ; name's own bytes before ARRSYM_FIND_OR_CREATE ever read them.
        ; Found live: "DIM ARR(3):ARR(0)=11" failed "array assignment
        ; target was never DIM'd" even though DIM had just run, the
        ; exact symptom the original STMT_IDENT_NAME_PTR bug produced.
        ; STASH_IDENT_NAME copies into the same safe, fixed buffer that
        ; mechanism already uses.
        call STASH_IDENT_NAME
        rst $08                   ; consume the name, fetch next
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.have_lparen
        ld a,33
        rst $30
.have_lparen:
        rst $08                   ; consume '(', fetch the size literal
        ld a,(TOK_TYPE)
        cp TOK_NUMBER
        jr z,.have_size
        jp ERR_DIM_EXPECTED_NUMBER
.have_size:
        ; R10.7 dynamic-array redesign: size is now a full 16-bit value
        ; (TOK_VAL, both bytes) -- no more fixed ARRAY_MAX_ELEMS ceiling
        ; (arena-allocated now, not a fixed pool; real capacity is
        ; whatever OP_DIM's own runtime arena-exhaustion check allows).
        ld hl,(TOK_VAL)
        ld a,h
        or l
        jr nz,.size_nonzero
        ld a,35
        rst $30
.size_nonzero:
        ld (ARR_SIZE_TMP),hl
        rst $08                   ; consume the size literal, fetch next
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        jp ERR_DIM_EXPECTED_SEP
.have_rparen:
        rst $08                   ; consume ')'
        ld hl,(STMT_IDENT_NAME_PTR)   ; the safe copy (see .have_ident)
        ld a,(STMT_IDENT_NAME_LEN)
        ld b,a
        call ARRSYM_FIND_OR_CREATE
        ; R10.7: DIM now emits real bytecode (OP_DIM), unlike the old
        ; fixed-pool design where DIM did zero runtime work. A holds
        ; the new array's own index (ARRSYM_FIND_OR_CREATE's own
        ; return contract, updated above) -- parked on the stack BEFORE
        ; reading COMPILE_ERROR_CODE below (real bug caught here: an
        ; earlier version read COMPILE_ERROR_CODE into A first, silently
        ; clobbering the real index with 0 before it was ever saved --
        ; every array after the first one then compiled with index 0).
        push af
        ld a,(COMPILE_ERROR_CODE)
        or a
        jr z,.dim_emit
        pop af                    ; balance the stack on every exit path
        ret                        ; already DIM'd / table full -- no
                                     ; bytecode to emit
.dim_emit:
        call EMIT_OP_DIM
        pop af
        ld de,(ARR_SIZE_TMP)      ; DE, not HL -- EMIT_BYTE destroys HL
                                     ; (real bug caught here: an earlier
                                     ; version used HL and had the high
                                     ; byte's own `ld a,h` read EMIT_
                                     ; PTR's own just-advanced value
                                     ; instead of the real size)
        jp EMIT_IDX_COUNT         ; array index + count, low/high byte

; COMPILE_DIM_STR -- DIM A$(n[,w]). Mirrors COMPILE_DIM exactly, plus an
; optional comma-width argument -- real, stock Sinclair BASIC syntax
; (DIM A$(n,w) declares n strings of w characters each on a real
; Spectrum, see docs/v2/R10_7_ARRAY_ARCHITECTURE_AUDIT.md Part 2 item 2
; for why this syntax was chosen over inventing a new one). No width
; given defaults to STRARR_DEFAULT_WIDTH. Entry: TOK_TYPE is TOK_STR_
; IDENT (the array name, not yet consumed).
STRARR_DEFAULT_WIDTH: equ 16  ; [len:1][content:15] -- a deliberately
                                ; modest default (not the scalar STRTAB's
                                ; 31-byte cap): enough for a short label/
                                ; name, cheap enough that DIM A$(n) alone
                                ; doesn't silently commit n*31 bytes of
                                ; arena the program never asked for
COMPILE_DIM_STR:
        ; R10.7 source-staging-architecture change: see COMPILE_DIM's own
        ; ".have_ident" comment -- same bug, same fix (this routine has
        ; even more intervening LEX_NEXT_TOKEN calls than COMPILE_DIM,
        ; since it also parses an optional comma-width argument).
        call STASH_IDENT_NAME
        rst $08                   ; consume the array name, fetch next
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.have_lparen
        ld a,33
        rst $30
.have_lparen:
        rst $08                   ; consume '(', fetch the size literal
        ld a,(TOK_TYPE)
        cp TOK_NUMBER
        jr z,.have_size
        jp ERR_DIM_EXPECTED_NUMBER
.have_size:
        ld hl,(TOK_VAL)
        ld a,h
        or l
        jr nz,.size_nonzero
        ld a,35
        rst $30
.size_nonzero:
        ld (STRARR_SIZE_TMP),hl
        ld a,STRARR_DEFAULT_WIDTH
        ld (STRARR_WIDTH_TMP),a
        rst $08                   ; consume the size literal, fetch next
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.have_comma
        cp TOK_RPAREN
        jr z,.have_rparen
        jr ERR_DIM_EXPECTED_SEP
.have_comma:
        rst $08                   ; consume ',', fetch the width literal
        ld a,(TOK_TYPE)
        cp TOK_NUMBER
        jr z,.have_width
        jr ERR_DIM_EXPECTED_NUMBER
.have_width:
        ld hl,(TOK_VAL)
        ld a,h
        or a
        jr nz,.width_range_err    ; width must fit one byte
        ld a,l
        cp 2
        jr nc,.width_ok           ; a width<2 record has no room for any
                                     ; content at all (length byte only)
.width_range_err:
        jr ERR_DIM_EXPECTED_NUMBER
.width_ok:
        ld (STRARR_WIDTH_TMP),a
        rst $08                    ; consume the width literal, fetch next
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        jr ERR_DIM_EXPECTED_SEP
.have_rparen:
        rst $08                    ; consume ')'
        ld hl,(STMT_IDENT_NAME_PTR)   ; the safe copy (see this routine's
        ld a,(STMT_IDENT_NAME_LEN)    ; own top-of-routine comment)
        ld b,a
        call STRARRSYM_FIND_OR_CREATE
        ; A holds the new array's own index (same "park it on the stack
        ; before reading COMPILE_ERROR_CODE" fix COMPILE_DIM's own header
        ; already documents the real bug for)
        push af
        ld a,(COMPILE_ERROR_CODE)
        or a
        jr z,.dim_emit
        pop af
        ret
.dim_emit:
        call EMIT_OP_DIM_STR
        pop af
        ld de,(STRARR_SIZE_TMP)   ; DE, not HL -- EMIT_BYTE destroys HL
        call EMIT_IDX_COUNT       ; array index + count, low/high byte
        ld a,(STRARR_WIDTH_TMP)
        jp EMIT_BYTE              ; width

; EMIT_IDX_COUNT — shared [index:1][count_lo:1][count_hi:1] bytecode-
; operand emit, the common tail of both COMPILE_DIM's and COMPILE_DIM_
; STR's own .dim_emit (COMPILE_DIM_STR emits one further width byte of
; its own afterward). Input: A = array index, DE = declared count.
EMIT_IDX_COUNT:
        rst $20
        ld a,e
        rst $20
        ld a,d
        jp EMIT_BYTE

; Shared one-error-code stubs -- each of these exact "ld a,N / jp
; COMPILE_RAISE_ERROR" pairs was duplicated 3-4 times across COMPILE_
; DIM/COMPILE_DIM_STR/COMPILE_ARR_ASSIGN_COMMON (identical literal
; error code, identical raise call); factored out during the Dynamic
; Data Phase 2 HOME-budget shrink pass.
ERR_DIM_EXPECTED_NUMBER: ld a,34 : jp COMPILE_RAISE_ERROR
ERR_DIM_EXPECTED_SEP:    ld a,37 : jp COMPILE_RAISE_ERROR
ERR_EXPECTED_ASSIGN:     ld a,2  : jp COMPILE_RAISE_ERROR
ERR_UNEXPECTED_TOKEN:    ld a,64 : jp COMPILE_RAISE_ERROR   ; R10.9 2D

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
        rst $30
.found:
        ld b,a
        ld de,(ARR_SIZE_TMP)      ; R10.7 -- widened to 2 bytes (was in C)
        xor a
        ld (COMPILE_ARR_ASSIGN_IS_STR),a
        jr COMPILE_ARR_ASSIGN_COMMON

; COMPILE_ARR_ASSIGN_COMMON — shared array-assignment skeleton for both
; numeric (A(expr)=expr) and string (A$(expr)=str_expr) targets,
; factored out of COMPILE_ARRAY_ASSIGN/COMPILE_STRARR_ASSIGN during the
; Dynamic Data Phase 2 HOME-budget shrink pass (identical skeleton,
; differing only in which value-expression compiler and which opcode get
; emitted -- selected via COMPILE_ARR_ASSIGN_IS_STR, set by the caller).
; Input: B = array index, DE = declared element count, TOK_TYPE is
; already TOK_LPAREN (not yet consumed).
;
; BUG FOUND (real hardware, R8.5 Group 4), TWO layers deep: (1) both
; sub-expressions compiled below can contain their OWN array reads
; (e.g. "B(0)=A(1)+A(0)") -- COMPILE_FACTOR's own .arr_read branch
; reuses this SAME CARR_INDEX/CARR_SIZE pair, silently overwriting this
; outer assignment's own target before EMIT_OP_ARR_STORE below got to
; use it. (2) A first attempt fixed that by parking the target in BC
; across EACH COMPILE_EXPR call separately (push immediately before,
; pop immediately after) -- but LEX_NEXT_TOKEN (called to consume ')'
; and '=' BETWEEN the two calls) turned out to ALSO destroy BC (it
; scans the next token via LEX_CLASSIFY_KEYWORD, which uses B/C as its
; own table-scan counters) -- so the SECOND push captured already-
; clobbered garbage, not the real target (caught via a real ZEsarUX
; run: B(0)=A(1)+A(0) wrote 30 into A(0) instead of B(0); single-
; stepping showed BC=0000, not 0005, already corrupted at the second
; `push bc`, before COMPILE_EXPR for the value even ran). Real fix: ONE
; push spanning the ENTIRE rest of this routine (every LEX_NEXT_TOKEN
; and both value-expr compiles), with exactly ONE pop, on EVERY exit
; path, right before the single point BC is actually used -- the same
; "balance every exit path" discipline COMPILE_IF_BLOCK's own header
; already documents, now proven to matter even when no further nested
; recursion is directly visible at the call site.
COMPILE_ARR_ASSIGN_COMMON:
        push bc                    ; B = array index (C unused/don't-care)
        push de                    ; D/E = declared size, low/high
        rst $08                    ; consume '(', fetch the index expr's
                                     ; first token
        call COMPILE_EXPR
        ld a,(COMPILE_ERROR_CODE)
        or a
        jr nz,.err_pop
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        ld a,41
        jr .raise_err
.have_rparen:
        rst $08                     ; consume ')'
        ld a,(TOK_TYPE)
        cp TOK_ASSIGN
        jr z,.have_assign
        ld a,2
        jr .raise_err
.have_assign:
        rst $08                      ; consume '='
        ld a,(COMPILE_ARR_ASSIGN_IS_STR)
        or a
        jr nz,.str_value
        call COMPILE_EXPR             ; value expr -- pushed ON TOP of the
        jr .value_done                 ; already-compiled index expr, the
.str_value:                             ; order OP_ARR_STORE/OP_STRARR_
        call COMPILE_STR_EXPR           ; STORE's own runtime handler
.value_done:                             ; expects (pops value first)
        ld a,(COMPILE_ERROR_CODE)
        or a
        jr nz,.err_pop
        pop de
        pop bc
        ld a,(COMPILE_ARR_ASSIGN_IS_STR)
        or a
        jr nz,.emit_str
        call EMIT_OP_ARR_STORE
        jp EMIT_ARR_OPERAND
.emit_str:
        call EMIT_OP_STRARR_STORE
        jp EMIT_ARR_OPERAND
.raise_err:
        ld (COMPILE_ERROR_CODE),a
.err_pop:
        pop de
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
        rst $08                   ; consume DIMN
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.have_lparen
        ld a,46                    ; expected '(' after DIMN
        rst $30
.have_lparen:
        rst $08                     ; consume '('
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_ident
        ld a,47                     ; DIMN's argument must be a DIM'd
        rst $30                      ; array name
.have_ident:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call ARRSYM_LOOKUP
        jr nc,.have_size
        ld a,47                     ; not a DIM'd array (same code --
        rst $30                      ; same real failure either way)
.have_size:
        ld hl,(ARR_SIZE_TMP)      ; R10.7 -- widened to 2 bytes (was 1)
        ld (DIMN_SIZE_TMP),hl
        rst $08                     ; consume the array name
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        ld a,48                      ; expected ')' to close DIMN
        rst $30
.have_rparen:
        rst $08                       ; consume ')'
        ; R10.7: always PUSH_I16, not PUSH_I8 -- a DIM'd size of 128+
        ; (routine, now that the old 16-element ceiling is gone) would
        ; sign-extend through PUSH_I8 (OP_PUSH_I8's own real behavior,
        ; confirmed via a real ZEsarUX run: DIMN(A) after DIM A(200)
        ; came back as -56, not 200) -- same fix COMPILE_FACTOR's own
        ; numeric-literal path already applies for values 128-255.
        call EMIT_BYTE_OP_PUSH_I16
        ld de,(DIMN_SIZE_TMP)     ; DE, not HL -- EMIT_BYTE destroys HL
        ld a,e
        rst $20
        ld a,d
        jp EMIT_BYTE

DIMN_KEYWORD_TEXT: db "DIMN"

; ===========================================================================
; R8.5 Group 2 (closed out late) -- INPUT.
;   input_stmt := 'INPUT' (IDENT | STR_IDENT)
; A numeric target auto-vivifies via CSYM_FIND_OR_CREATE (same as a bare
; assignment); a string target via STRSYM_FIND_OR_CREATE (same as a
; string assignment) -- INPUT is not required to target an ALREADY-
; assigned variable, matching V1's own real behavior.
; ===========================================================================
COMPILE_INPUT:
        rst $08                   ; consume INPUT, fetch the target token
        ld a,(TOK_TYPE)
        cp TOK_STRING             ; STUDY: INPUT "prompt"; v  /  INPUT "prompt", v
        jr nz,.no_prompt
        call COMPILE_STR_EXPR
        call EMIT_OP_PRINT_STR    ; the prompt: printed without a newline, INPUT echoes after it
        ld a,(TOK_TYPE)
        cp TOK_SEMI
        jr z,.prompt_sep
        cp TOK_COMMA
        jr z,.prompt_sep
        ld a,22                   ; expected ';' or ',' after the prompt
        rst $30
.prompt_sep:
        rst $08
.no_prompt:
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.numeric
        cp TOK_STR_IDENT
        jr z,.string
        ld a,43
        rst $30
.numeric:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
.num_len_ok:
        ld b,a
        call CSYM_FIND_OR_CREATE
        ld (CINPUT_INDEX_TMP),a
        rst $08                    ; consume the target identifier
        call EMIT_OP_INPUT_NUM
        ld a,(CINPUT_INDEX_TMP)
        jp EMIT_BYTE
.string:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
.str_len_ok:
        ld b,a
        call STRSYM_FIND_OR_CREATE
        ld (CINPUT_INDEX_TMP),a
        rst $08                    ; consume the target identifier
        call EMIT_OP_INPUT_STR
        ld a,(CINPUT_INDEX_TMP)
        jp EMIT_BYTE

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
        rst $08
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
        rst $30
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
        rst $20                   ; the length byte
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
        rst $20
        inc de
        djnz .lit_copy_loop
.lit_no_content:
        jp LEX_NEXT_TOKEN
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
        ; Dynamic Data Phase 2 -- a string-array NAME used as a value is
        ; a string-array read, "STR_IDENT(expr)". Checked by NAME lookup
        ; (STRARRSYMTAB is a separate lexical namespace from STRSYMTAB),
        ; same precedent as COMPILE_FACTOR.ident's own ARRSYM_LOOKUP
        ; check before its plain-scalar fallback.
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
.plen_ok:
        ld b,a
        push bc                   ; preserve the clamped length across
                                   ; STRARRSYM_LOOKUP (destroys BC) so the
                                   ; fallback path below doesn't need to
                                   ; recompute it (HOME-budget shrink pass,
                                   ; D7, docs/v2/R10_7_DORMANT_ROM_
                                   ; CONSOLIDATION_AUDIT.md) -- only HL
                                   ; needs reloading, a genuine second
                                   ; input to STRSYM_FIND_OR_CREATE
        call STRARRSYM_LOOKUP
        pop bc
        jr nc,.strarr_read
        ld hl,(TOK_NAME)
.len_ok:
        call STRSYM_FIND_OR_CREATE
        ld (CSTR_IDENT_INDEX_TMP),a
        call EMIT_BYTE_OP_PUSH_I16
        ld a,(CSTR_IDENT_INDEX_TMP)
        rst $20
        xor a
        rst $20                   ; high byte: always 0, indices are small
        jp LEX_NEXT_TOKEN
.strarr_read:
        ; thin wrapper around the shared COMPILE_ARR_READ_COMMON skeleton
        ; (see its own header) -- flag set to select the string opcode.
        push af                    ; A = array index, preserve across the
        ld a,1                       ; flag-set below
        ld (COMPILE_ARR_ASSIGN_IS_STR),a
        pop af
        ld hl,(STRARR_SIZE_TMP)
        jp COMPILE_ARR_READ_COMMON

; COMPILE_STR_IDENT_STMT — entry: TOK_TYPE is TOK_STR_IDENT (the
; statement-starting string identifier, not yet consumed). Same one-
; token lookahead .ident_stmt already uses to disambiguate a numeric
; array assignment from a plain scalar one (Dynamic Data Phase 2,
; mirrored here for string targets): "STR_IDENT(" is always a string-
; array assignment. A separate CALLed routine (not inlined into .str_
; ident_stmt itself) so the two tail-jumps below return to the
; DISPATCHER's own call site, not to whichever of THIS routine's own
; callers happened to be on the stack -- same reasoning COMPILE_ASSIGN_
; CONTINUED's own existence already documents for the numeric case.
COMPILE_STR_IDENT_STMT:
        call STASH_IDENT_AND_PEEK
        cp TOK_LPAREN
        jr z,COMPILE_STRARR_ASSIGN
        jr COMPILE_STR_ASSIGN_CONTINUED

; COMPILE_STR_ASSIGN_CONTINUED — entry: STMT_IDENT_NAME_PTR/LEN describe
; the string-variable assignment target (already consumed by the
; dispatcher's own one-token lookahead, Dynamic Data Phase 2 addition --
; see .str_ident_stmt below); TOK_TYPE is already the token immediately
; after it (typically TOK_ASSIGN). Same split COMPILE_ASSIGN_CONTINUED
; already uses for numeric targets, needed here for the same reason:
; disambiguating a plain string assignment from a string-ARRAY assignment
; needs to see whether '(' follows the name, which only the dispatcher's
; existing lookahead already has in hand.
COMPILE_STR_ASSIGN_CONTINUED:
        ld hl,(STMT_IDENT_NAME_PTR)
        ld a,(STMT_IDENT_NAME_LEN)
        ld b,a
        call STRSYM_FIND_OR_CREATE
        ld (CSTR_ASSIGN_TARGET_TMP),a
        ld a,(TOK_TYPE)
        cp TOK_ASSIGN
        jr z,.have_assign
        jp ERR_EXPECTED_ASSIGN
.have_assign:
        rst $08                   ; consume '='
        call COMPILE_STR_EXPR
        call EMIT_OP_STORE_STR_VAR
        ld a,(CSTR_ASSIGN_TARGET_TMP)
        jp EMIT_BYTE

; COMPILE_STRARR_ASSIGN — Dynamic Data Phase 2: A$(expr) = str_expr.
; Thin wrapper around the shared COMPILE_ARR_ASSIGN_COMMON skeleton (see
; its own header) -- STRARRSYM_LOOKUP in place of ARRSYM_LOOKUP, flag set
; to select the string value-compiler/opcode. Entry: STMT_IDENT_NAME_
; PTR/LEN describe the array name (already consumed); TOK_TYPE is
; already TOK_LPAREN.
COMPILE_STRARR_ASSIGN:
        ld hl,(STMT_IDENT_NAME_PTR)
        ld a,(STMT_IDENT_NAME_LEN)
        ld b,a
        call STRARRSYM_LOOKUP
        jr nc,.found
        ld a,42
        rst $30
.found:
        ld b,a
        ld de,(STRARR_SIZE_TMP)
        ld a,1
        ld (COMPILE_ARR_ASSIGN_IS_STR),a
        jp COMPILE_ARR_ASSIGN_COMMON

; ===========================================================================
; LABEL TABLE + FORWARD-REFERENCE FIXUPS (R3 addition)
;
; Register discipline for every routine below matches CSYM_FIND_OR_CREATE's
; already-validated pattern exactly (R2's own two real bugs were both
; "a value needed after a call was left in a register instead of memory" —
; treated as a standing rule here, not just a lesson for the routines that
; already broke).
; ===========================================================================

; COMPILE_BRANCH_TARGET — shared by COMPILE_GOTO and COMPILE_IF. Input:
; HL = the branch opcode's placeholder patch address (from
; EMIT_PLACEHOLDER_16); current token must be TOK_IDENT (the label name).
; Resolves immediately if the label is already defined (backward
; reference), otherwise records a fixup for RESOLVE_ALL_FIXUPS to patch
; later (forward reference).
COMPILE_BRANCH_TARGET:
        ex de,hl                 ; DE = the operand slot just emitted
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call LABEL_REF           ; defined: patched now; else threaded on the chain
        jp LEX_NEXT_TOKEN ; consume the label identifier

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
        rst $08                 ; consume CLS
        jp EMIT_OP_CLS

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
        rst $08
        call COMPILE_EXPR
        pop hl
        jp (hl)

COMPILE_BORDER:
        ld hl,EMIT_OP_BORDER
        jr COMPILE_1ARG_STMT

COMPILE_INK:
        ld hl,EMIT_OP_INK
        jr COMPILE_1ARG_STMT

COMPILE_PAPER:
        ld hl,EMIT_OP_PAPER
        jr COMPILE_1ARG_STMT

; COMPILE_FLASH/BRIGHT/OVER/INVERSE — same 1-arg shape as COMPILE_INK/
; PAPER above (R10.7 attribute setters, R10.25 class B).
COMPILE_FLASH:
        ld hl,EMIT_OP_FLASH
        jr COMPILE_1ARG_STMT

COMPILE_BRIGHT:
        ld hl,EMIT_OP_BRIGHT
        jr COMPILE_1ARG_STMT

COMPILE_OVER:
        ld hl,EMIT_OP_OVER
        jr COMPILE_1ARG_STMT

COMPILE_INVERSE:
        ld hl,EMIT_OP_INVERSE
        jr COMPILE_1ARG_STMT

; COMPILE_TAB — TAB <expr>, one numeric argument (R10.7).
COMPILE_TAB:
        ld hl,EMIT_OP_TAB
        jr COMPILE_1ARG_STMT

; COMPILE_AT — AT <expr>,<expr>, same 2-arg comma shape as COMPILE_PLOT.
COMPILE_AT:
        rst $08                 ; consume AT
        call COMPILE_EXPR       ; row -> VM operand stack
        call COMPILE_EXPECT_COMMA_EXPR  ; col -> VM operand stack
        jp EMIT_OP_AT

; COMPILE_CLEAR — CLEAR, no arguments (R10.7).
COMPILE_CLEAR:
        rst $08                 ; consume CLEAR
        jp EMIT_OP_CLEAR

; COMPILE_EXPECT_COMMA_EXPR — expects the current token to be ',',
; consumes it, then compiles the following expression (tail-calls
; COMPILE_EXPR, so its own `ret` returns straight to THIS routine's
; caller). Shared by every 2-arg comma-separated statement compiler.
COMPILE_EXPECT_COMMA_EXPR:
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.have_comma
        ld a,22
        rst $30
.have_comma:
        rst $08
        jp COMPILE_EXPR

; STUDY (shrink): <KEYWORD> <expr>,<expr>.  HL = the emit routine for the opcode (as COMPILE_1ARG_STMT).
COMPILE_2ARG_STMT:
        push hl
        rst $08                 ; consume the keyword
        call COMPILE_EXPR       ; first argument
        call COMPILE_EXPECT_COMMA_EXPR  ; second argument
        pop hl
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        jp (hl)

; COMPILE_PLOT — PLOT <expr>,<expr>  (x, then y — matches V1's own
; BASIC_STMT_PLOT reading order; OP_PLOT's own header note explains why
; it pops y before x)
COMPILE_PLOT:
        ld hl,EMIT_OP_PLOT
        jr COMPILE_2ARG_STMT

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
        rst $08                 ; consume LINE
        call COMPILE_EXPR       ; x0
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.have_comma1
        ld a,23                  ; expected ',' after LINE's x0
        rst $30
.have_comma1:
        rst $08                 ; consume ','
        call COMPILE_EXPR       ; y0
        ld a,(TOK_TYPE)
        cp TOK_KW_TO
        jr z,.have_to
        ld a,24                  ; expected TO in LINE
        rst $30
.have_to:
        rst $08                 ; consume TO
        call COMPILE_EXPR       ; x1
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.have_comma2
        ld a,25                  ; expected ',' after LINE's x1
        rst $30
.have_comma2:
        rst $08                 ; consume ','
        call COMPILE_EXPR       ; y1
        jp EMIT_OP_LINE

; STUDY: OUT <port>,<value>.  The port is the FULL 16-bit address (BC), not just the low byte.
COMPILE_OUT:
        ld hl,EMIT_OP_OUT
        jr COMPILE_2ARG_STMT

; COMPILE_BEEP — BEEP <duration>,<pitch>  (matches V1's own
; BASIC_STMT_BEEP argument order). "Expected comma" now reports code
; 22 (COMPILE_EXPECT_COMMA_EXPR's own code) rather than its own former
; 26 -- both were always "expected comma between a statement's two
; args", the same real condition either way; unifying it is what lets
; this reuse the shared helper.
COMPILE_BEEP:
        ld hl,EMIT_OP_BEEP
        jr COMPILE_2ARG_STMT

; COMPILE_SOUND — SOUND <register>,<data>  (matches V1's own
; BASIC_STMT_SOUND argument order)
COMPILE_SOUND:
        ld hl,EMIT_OP_SOUND
        jr COMPILE_2ARG_STMT

; COMPILE_POKE — POKE <address>,<value>  (matches V1's own
; BASIC_STMT_POKE argument order)
COMPILE_POKE:
        ld hl,EMIT_OP_POKE
        jr COMPILE_2ARG_STMT

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
        rst $08                 ; consume PRINT
.item:
        ld a,(TOK_TYPE)
        or a
        jr z,.nl                ; end of source
        cp TOK_COLON
        jr z,.nl                ; end of statement / line
        cp TOK_KW_ENDP
        jr z,.nl
        sub TOK_KW_ELSE
        cp 2
        jr c,.nl                ; ELSE / ENDIF
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
        jr .sep
.str_arg:
        call COMPILE_STR_EXPR
        call EMIT_OP_PRINT_STR
.sep:
        ld a,(TOK_TYPE)
        cp TOK_COMMA
        jr z,.comma
        cp TOK_SEMI
        jr nz,.nl               ; no separator: the item ends the line
        rst $08
        jr .after_sep
.comma:
        rst $08
        call EMIT_OP_PRINT_COMMA
.after_sep:
        ld a,(TOK_TYPE)         ; a trailing separator ends the statement WITHOUT a newline
        or a
        ret z
        cp TOK_COLON
        ret z
        cp TOK_KW_ENDP
        ret z
        sub TOK_KW_ELSE
        cp 2
        ret c
        jr .item
.nl:
        jp EMIT_OP_NL

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
        rst $08                 ; consume LPRINT
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
        rst $30

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
        rst $08                 ; consume GOTO
        call EMIT_OP_JMP
        call EMIT_PLACEHOLDER_16   ; HL = patch address
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_target
        ld a,12                 ; expected a label name after GOTO
        rst $30
.have_target:
        jp COMPILE_BRANCH_TARGET

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
        rst $08                 ; consume IF
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
        rst $30
.str_lt:
        rst $08
        call COMPILE_STR_EXPR
        call EMIT_OP_STR_CMP_LT
        jr .condition_done
.str_eq:
        rst $08
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
        rst $30
.have_then:
        rst $08                 ; consume THEN
        ld a,(TOK_TYPE)
        cp TOK_KW_GOTO
        jr z,.have_goto
        jr COMPILE_IF_BLOCK      ; R8.5 Group 3 -- anything other than
                                    ; GOTO after THEN is the start of a
                                    ; block IF's own THEN-body (see
                                    ; COMPILE_IF_BLOCK's own header)
.have_goto:
        rst $08                 ; consume GOTO
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_target
        ld a,12
        rst $30
.have_target:
        call EMIT_OP_JMP
        call EMIT_PLACEHOLDER_16   ; HL = patch address for the real target
        call COMPILE_BRANCH_TARGET ; resolves/fixups; also consumes the
                                     ; label identifier token
        ; patch the "skip" target to land HERE — right after the JMP —
        ; so a false condition falls through past the GOTO instead of
        ; taking it.
        call COMPILE_RELATIVE_OFFSET  ; HL = relative offset (current position)
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
        call COMPILE_RELATIVE_OFFSET
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
        rst $08                        ; consume ELSE
        call COMPILE_STATEMENT_LIST     ; compiles the ELSE-body
        ld a,(COMPILE_ERROR_CODE)
        or a
        jr nz,.err_pop2
        ld a,(TOK_TYPE)
        cp TOK_KW_ENDIF
        jr z,.else_have_endif
        ld a,9
        ld (COMPILE_ERROR_CODE),a
.err_pop2:
        pop hl
        ret
.else_have_endif:
        call COMPILE_RELATIVE_OFFSET
        ex de,hl
        pop hl                            ; HL = our own saved else-skip
                                            ; patch address
        ld (hl),e
        inc hl
        ld (hl),d
        jp LEX_NEXT_TOKEN ; consume ENDIF
.have_endif:
        call COMPILE_RELATIVE_OFFSET
        ex de,hl
        pop hl                            ; HL = our own saved THEN-body
                                            ; patch address (balances the
                                            ; entry push)
        ld (hl),e
        inc hl
        ld (hl),d
        jp LEX_NEXT_TOKEN ; consume ENDIF

; ===========================================================================
; LOOP STATEMENT COMPILERS (R3 addition: FOR/NEXT)
;
; Post-R9 nested-FOR/NEXT correction (docs/v2/V2_SEMANTIC_CAPABILITY_AUDIT.md
; S9): real nesting up to FOR_NEST_MAX deep, via the FOR_STACK frame table
; declared above. Each open loop's own body-offset/var-index/EXITFOR state
; is pushed on COMPILE_FOR and popped on its matching COMPILE_NEXT, so an
; inner loop's own compilation can never corrupt an outer loop's state —
; the single-scratch-cell design this replaced silently compiled wrong
; bytecode for any ordinarily-nested FOR (was a KNOWN, DOCUMENTED
; limitation, not a silent gap, before this milestone).
; ===========================================================================

; COMPILE_FOR — FOR <ident> = <expr> TO <expr>  (explicit STEP optional,
; defaults to a literal 1)
COMPILE_FOR:
        call CSTK_PUSH           ; R10.7 P2: loop frames live on the memory-limited
        ret c                    ; compile stack (no FOR_NEST_MAX); carry = no room
        ld (FOR_FRAME_ADDR_TMP),hl
        inc hl
        inc hl
        inc hl                   ; HL -> frame+3 (exit-chain head)
        xor a
        ld (hl),a
        inc hl
        ld (hl),a                ; no EXIT FOR recorded yet
        inc hl
        ld de,(LEX_LINE)         ; STUDY: the line of this FOR (frame+5), for a missing NEXT
        res 7,d
        ld (hl),e
        inc hl
        ld (hl),d
        rst $08                 ; consume FOR
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_var
        ld a,10                  ; expected a loop variable
        rst $30
.have_var:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call CSYM_FIND_OR_CREATE
        ld (FOR_LOOP_VAR_INDEX),a
        ld hl,(FOR_FRAME_ADDR_TMP)
        ld (hl),a                  ; frame+0 = var_index
        rst $08                 ; consume the identifier
        ld a,(TOK_TYPE)
        cp TOK_ASSIGN
        jr z,.have_assign
        jp ERR_EXPECTED_ASSIGN
.have_assign:
        rst $08                 ; consume '='
        call COMPILE_EXPR       ; initial value -> VM operand stack
        ld a,(TOK_TYPE)
        cp TOK_KW_TO
        jr z,.have_to
        ld a,11                  ; expected TO
        rst $30
.have_to:
        rst $08                 ; consume TO
        call COMPILE_EXPR       ; limit value -> VM operand stack
        ld a,(TOK_TYPE)
        cp TOK_KW_STEP
        jr z,.have_step
        call EMIT_BYTE_OP_PUSH_I8   ; R8.5 Group 5 -- no STEP written:
        ld a,1                       ; compile a literal step of 1, same
        rst $20                       ; as OP_FOR_INIT/OP_FOR_NEXT always
        jr .emit_init                  ; expect a real step operand now
.have_step:
        rst $08                 ; consume STEP
        call COMPILE_EXPR       ; step value -> VM operand stack
.emit_init:
        call EMIT_OP_FOR_INIT
        ld a,(FOR_LOOP_VAR_INDEX)
        rst $20
        call EMIT_PLACEHOLDER_16 ; QUAL (Q-07): skip-the-body target, the first node of this
        ex de,hl                 ; loop's EXIT chain (frame+3/+4), so NEXT patches it with the
        ld hl,(FOR_FRAME_ADDR_TMP) ; FOR_POP address like an EXIT FOR
        inc hl
        inc hl
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        call COMPILE_RELATIVE_OFFSET  ; HL = loop body's start, relative offset
        ld (FOR_LOOP_TOP_OFFSET),hl
        ex de,hl                  ; DE = top offset
        ld hl,(FOR_FRAME_ADDR_TMP)
        inc hl                     ; -> frame+1 (top_offset lo)
        ld (hl),e
        inc hl
        ld (hl),d                  ; frame+1,+2 = top_offset
        ret

; COMPILE_EXIT_FOR — EXIT FOR. Compiles to a plain JMP whose target is
; patched once COMPILE_NEXT knows the loop's real exit address (the same
; "record a patch address now, resolve it later" shape GOTO's own
; FIXUPTAB already uses). Post-R9: scoped to the innermost open loop's
; own per-depth exit-patch table, not a single shared one.
COMPILE_EXIT_FOR:
        rst $08                 ; consume EXIT
        ld a,(TOK_TYPE)
        cp TOK_KW_FOR
        jr z,.have_for
        ld a,44
        rst $30
.have_for:
        call CSTK_TOP            ; innermost open FOR frame
        jr nz,.record
        ld a,63                  ; EXIT FOR with no FOR open
        rst $30
.record:
        push hl                  ; the frame
        call EMIT_OP_JMP
        call EMIT_PLACEHOLDER_16 ; HL = this JMP's own operand slot
        ex de,hl                 ; DE = slot
        pop hl
        inc hl
        inc hl
        inc hl                   ; HL -> frame+3 (chain head)
        ld c,(hl)
        inc hl
        ld b,(hl)                ; BC = previous head
        ld (hl),d
        dec hl
        ld (hl),e                ; head = this slot
        ex de,hl                 ; HL = slot
        ld (hl),c
        inc hl
        ld (hl),b                ; slot = previous head (0 ends the chain)
        jp LEX_NEXT_TOKEN ; consume FOR

; COMPILE_NEXT — NEXT <ident>
COMPILE_NEXT:
        rst $08                 ; consume NEXT
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_var
        ld a,10
        rst $30
.have_var:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call CSYM_FIND_OR_CREATE   ; A = this NEXT's own referenced var index
        ld (NEXT_VAR_INDEX_TMP),a
        ; post-R9: verify this NEXT's variable matches the innermost open
        ; FOR (docs/v2/V2_SEMANTIC_CAPABILITY_AUDIT.md S9 -- previously
        ; unchecked entirely: "this R3 scope does not verify the name
        ; matches the innermost open FOR").
        call CSTK_TOP                ; HL = innermost open frame
        jr z,.mismatch               ; NEXT with no FOR open at all
        ld a,(hl)                   ; A = that loop's own var_index
        ld b,a
        ld a,(NEXT_VAR_INDEX_TMP)
        cp b
        jr nz,.mismatch
        jr .verified
.mismatch:
        ld a,56                     ; NEXT variable doesn't match the
                                      ; innermost open FOR
        rst $30
.verified:
        ld a,(NEXT_VAR_INDEX_TMP)
        ld (FOR_LOOP_VAR_INDEX),a
        rst $08                 ; consume the identifier
        call EMIT_OP_FOR_NEXT
        ld a,(FOR_LOOP_VAR_INDEX)
        rst $20
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
        rst $20
        ld a,(FOR_NEXT_HIGH_TMP)
        rst $20
        ; R8.5 Group 5 -- resolve every pending EXIT FOR from this loop's
        ; own body now: the loop's real exit point is exactly here, the
        ; first bytecode position past NEXT's own operand -- the SAME
        ; position both OP_FOR_NEXT's own .past_limit fall-through AND
        ; (post-R9) the OP_FOR_POP opcode emitted just below land on, so
        ; the loop's own FOR_STACK frame is popped exactly once regardless
        ; of which path exits the loop.
        call COMPILE_RELATIVE_OFFSET  ; HL = relative exit offset
        push hl                   ; the exit offset every EXIT FOR jumps to
        call CSTK_TOP             ; HL = the loop being closed (destroys DE)
        pop de                    ; DE = the exit offset
        push hl
        inc hl
        inc hl
        inc hl
        ld c,(hl)
        inc hl
        ld b,(hl)                 ; BC = head of this loop's EXIT FOR chain
.patch_loop:
        ld a,b
        or c
        jr z,.no_exits
        ld a,(bc)
        ld l,a
        inc bc
        ld a,(bc)
        ld h,a                    ; HL = next slot in the chain
        ld a,d
        ld (bc),a                 ; slot+1 = exit offset hi
        dec bc
        ld a,e
        ld (bc),a                 ; slot+0 = exit offset lo
        ld b,h
        ld c,l
        jr .patch_loop
.no_exits:
        call EMIT_OP_FOR_POP
        pop hl                    ; the frame being closed
        ld de,CSTK_FRAME_LEN
        add hl,de
        ld (SYM_LIMIT_V),hl       ; pop it
        ld de,V2_SOURCE_END
        or a
        sbc hl,de
        ret z                     ; no enclosing loop left
        ld hl,(SYM_LIMIT_V)       ; the now-innermost frame
        ld a,(hl)
        ld (FOR_LOOP_VAR_INDEX),a
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (FOR_LOOP_TOP_OFFSET),de
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
        call COMPILE_STACK_CHECK
        ret c
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
        cp TOK_KW_DEF
        jp z,.def_fn
        cp TOK_KW_CLS
        jp z,.cls
        cp TOK_KW_BORDER
        jp z,.border
        cp TOK_KW_INK
        jp z,.ink
        cp TOK_KW_PAPER
        jp z,.paper
        cp TOK_KW_PLOT
        jp z,.plot
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
        cp TOK_KW_FLASH
        jp z,.flash
        cp TOK_KW_BRIGHT
        jp z,.bright
        cp TOK_KW_OVER
        jp z,.over
        cp TOK_KW_INVERSE
        jp z,.inverse
        cp TOK_KW_AT
        jp z,.at
        cp TOK_KW_TAB
        jp z,.tab
        cp TOK_KW_CLEAR
        jp z,.clear
        cp TOK_KW_OUT
        jp z,.out
        cp TOK_IDENT
        jp z,.ident_stmt
        cp TOK_STR_IDENT
        jp z,.str_ident_stmt
        jp ERR_UNEXPECTED_TOKEN   ; R10.9 2D (defect D3): anything else is not a
                                   ; statement. It used to end compilation
                                   ; "cleanly" and silently drop the rest of
                                   ; the program.
.skip_separator:
        rst $08
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
.flash:
        call COMPILE_FLASH
        jp .after_stmt
.bright:
        call COMPILE_BRIGHT
        jp .after_stmt
.over:
        call COMPILE_OVER
        jp .after_stmt
.inverse:
        call COMPILE_INVERSE
        jp .after_stmt
.at:
        call COMPILE_AT
        jp .after_stmt
.tab:
        call COMPILE_TAB
        jp .after_stmt
.clear:
        call COMPILE_CLEAR
        jp .after_stmt
.out:
        call COMPILE_OUT
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
        rst $08                 ; consume END/STOP
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
        cp $0A                   ; R10.9 2D: end of a line that ends in ':'
        jr z,.rem_done
        inc hl
        jr .rem_scan
.rem_done:
        ld (SRC_PTR),hl
        rst $08
        jp .loop                 ; R10.9 2D: not .after_stmt -- a comment that ends at
                                  ; an LF is followed by the next line's first token
                                  ; with no ':' between them
.str_ident_stmt:
        call COMPILE_STR_IDENT_STMT
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
        call STASH_IDENT_AND_PEEK
        cp TOK_COLON
        jr z,.label
        call COMPILE_ASSIGN_CONTINUED
        jp .after_stmt
.label:
        ld a,(LEX_LINE+1)        ; STUDY: a line end is also a TOK_COLON (the lexer's record
        bit LEX_NEWLINE_PENDING,a ; separator) -- an identifier alone on its line is NOT a label
        jp nz,ERR_UNEXPECTED_TOKEN ; definition (that needs a real ':'); it used to be accepted silently,
                                   ; so a mistyped or unsupported command word did nothing
        ld hl,(STMT_IDENT_NAME_PTR)
        ld a,(STMT_IDENT_NAME_LEN)
        ld b,a
        call LABEL_DEFINE
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        rst $08                    ; consume the ':', fetch the next
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
        jp .after_stmt
.def_fn:
        call COMPILE_DEF_FN
.after_stmt:
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        ld a,(TOK_TYPE)
        cp TOK_COLON
        jr nz,.not_colon
        rst $08
        jp .loop
.not_colon:
        ; R10.9 2D (defect D3): a statement must be followed by ':' / end of
        ; line, or by the token that closes the enclosing list (end of source,
        ; ENDP, ELSE, ENDIF). Anything else is trailing junk or a missing ':'.
        or a                      ; TOK_EOF
        ret z
        cp TOK_KW_ENDP
        ret z
        sub TOK_KW_ELSE           ; TOK_KW_ELSE, TOK_KW_ENDIF are adjacent
        cp 2
        ret c
        jp ERR_UNEXPECTED_TOKEN
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
        rst $08
        call COMPILE_STATEMENT_LIST
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        ; R10.9 2D (defect D3): the list may only stop at end of source. A stray
        ; ENDP / ELSE / ENDIF closes nothing, and a FOR frame still open means
        ; its NEXT never came.
        ld a,(TOK_TYPE)
        or a                      ; TOK_EOF
        jp nz,ERR_UNEXPECTED_TOKEN
        call CSTK_TOP
        jr z,.no_open_for
        ld de,5                   ; STUDY: report it where the FOR is, not at the end of the source
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (LEX_LINE),de
        ld a,65                   ; FOR without NEXT
        rst $30
.no_open_for:
        call EMIT_OP_HALT
        call LABEL_CHECK_ALL
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
        rst $08                 ; consume PROC
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_name
        ld a,17                  ; expected a procedure name
        rst $30
.have_name:
        call STASH_IDENT_NAME
        rst $08                 ; consume the procedure name
        call EMIT_OP_JMP
        call EMIT_PLACEHOLDER_16   ; HL = patch address for the skip-over
        ld (PROC_SKIP_PATCH_TMP),hl
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.have_lparen
        ld a,18                  ; expected '(' after procedure name
        rst $30
.have_lparen:
        rst $08                 ; consume '('
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_param
        ld a,19                  ; expected a parameter name
        rst $30
.have_param:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call CSYM_FIND_OR_CREATE
        ld (PROC_PARAM_INDEX_TMP),a
        rst $08                 ; consume the parameter name
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        ld a,20                  ; expected ')' after the parameter
        rst $30
.have_rparen:
        rst $08                 ; consume ')'
        ld a,(TOK_TYPE)
        cp TOK_COLON
        jr z,.have_colon
        ld a,21                  ; expected ':' before the procedure body
        rst $30
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
        ; post-R9 PROC/DEF-FN recursion-safety correction (docs/v2/
        ; V2_SEMANTIC_CAPABILITY_AUDIT.md S11): OP_PARAM_BIND replaces
        ; the plain OP_STORE_VAR that used to bind the parameter here --
        ; it also saves the parameter's OLD value so a recursive call
        ; can't silently clobber an outer invocation's own copy. The
        ; matching OP_PARAM_UNBIND (below, right before RET) restores it.
        call EMIT_OP_PARAM_BIND
        ld a,(PROC_PARAM_INDEX_TMP)
        rst $20
        rst $08                 ; consume ':', prime the body's first token
        ld hl,(PROC_SKIP_PATCH_TMP)  ; QUAL (Q-11): a PROC or DEF FN defined inside this body reuses
        push hl                       ; both cells; park them across the body (the enclosing ENDP
        ld a,(PROC_PARAM_INDEX_TMP)   ; used to unbind the inner parameter and patch the inner skip)
        push af
        call COMPILE_STATEMENT_LIST
        pop af
        ld (PROC_PARAM_INDEX_TMP),a
        pop hl
        ld (PROC_SKIP_PATCH_TMP),hl
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        ld a,(TOK_TYPE)
        cp TOK_KW_ENDP
        jr z,.have_endp
        ld a,16                  ; unterminated PROC (hit EOF, not ENDP)
        rst $30
.have_endp:
        call EMIT_OP_PARAM_UNBIND
        ld a,(PROC_PARAM_INDEX_TMP)
        rst $20
        call EMIT_OP_RET
        call COMPILE_RELATIVE_OFFSET  ; HL = relative offset (current position)
        ex de,hl                  ; DE = relative offset
        ld hl,(PROC_SKIP_PATCH_TMP)
        ld (hl),e
        inc hl
        ld (hl),d
        jp LEX_NEXT_TOKEN ; consume ENDP, fetch whatever follows

; COMPILE_EXPR_KEEPNAME -- COMPILE_EXPR with the stashed identifier (STMT_IDENT_NAME_BUF/LEN) preserved:
; compiling the expression can re-stash it (a nested "FN name(...)"), so its content is parked on the
; hardware stack across the call (R10.7: the buffer is 32 bytes, so a block copy).  Shared by .udf_call and
; COMPILE_CALL_STMT.  Destroys: AF, BC, DE, HL.
COMPILE_EXPR_KEEPNAME:
        ld hl,-(STMT_IDENT_NAME_BUF_LEN+1)
        add hl,sp
        ld sp,hl                 ; reserve buffer + length byte below our return address
        ex de,hl
        ld hl,STMT_IDENT_NAME_BUF
        ld bc,STMT_IDENT_NAME_BUF_LEN
        ldir
        ld a,(STMT_IDENT_NAME_LEN)
        ld (de),a
        call COMPILE_EXPR
        ld hl,0
        add hl,sp
        ld de,STMT_IDENT_NAME_BUF
        ld bc,STMT_IDENT_NAME_BUF_LEN
        ldir
        ld a,(hl)
        ld (STMT_IDENT_NAME_LEN),a
        inc hl
        ld sp,hl                 ; release the parked copy
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
        rst $08                 ; consume CALL
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_name
        ld a,13                  ; expected a procedure name after CALL
        rst $30
.have_name:
        call STASH_IDENT_AND_PEEK
        cp TOK_LPAREN
        jr z,.have_lparen
        ld a,14                  ; expected '(' after the procedure name
        rst $30
.have_lparen:
        rst $08                 ; consume '('
        call COMPILE_EXPR_KEEPNAME ; argument -> pushed onto the VM operand stack. STUDY: a nested
                                   ; "FN f(x)" in the argument re-stashes STMT_IDENT_NAME_* (it used
                                   ; to leave "f" there, so the CALL was emitted for the wrong name)
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        ld a,15                  ; expected ')' after the argument
        rst $30
.have_rparen:
        rst $08                 ; consume ')'
        call EMIT_OP_CALL
        call EMIT_PLACEHOLDER_16   ; HL = patch address
        ex de,hl                 ; DE = the operand slot just emitted
        ld hl,(STMT_IDENT_NAME_PTR)
        ld a,(STMT_IDENT_NAME_LEN)
        ld b,a
        jp LABEL_REF             ; defined: patched now; else threaded on the chain

; ===========================================================================
; COMPILE_DEF_FN — DEF FN name(param) = expr (post-R9 reintegration,
; docs/v2/deffn_design/README.md). Reuses PROC's own compile-once
; JMP-skip + LABEL_DEFINE-at-the-real-entry-position + PARAM_BIND/
; PARAM_UNBIND shape almost verbatim (PROC_SKIP_PATCH_TMP/PROC_PARAM_
; INDEX_TMP scratch, same reentrant parameter mechanism -- see rom/
; exrom_v2_vm_core.asm's own header on VM_PARAM_SAVE_SP). The one real
; difference: the body is a single EXPR, not a statement list, and its
; result is left on the VM operand stack across RET_DEFFN on purpose --
; exactly what FN's own call-site factor needs (see .udf_call in
; COMPILE_FACTOR below).
; ===========================================================================
COMPILE_DEF_FN:
        rst $08                 ; consume DEF
        ld a,(TOK_TYPE)
        cp TOK_KW_FN
        jr z,.have_fn
        ld a,49                  ; expected FN after DEF
        rst $30
.have_fn:
        rst $08                 ; consume FN
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_name
        ld a,50                  ; expected a function name
        rst $30
.have_name:
        call STASH_IDENT_NAME
        rst $08                 ; consume the function name
        call EMIT_OP_JMP_DEFFN
        call EMIT_PLACEHOLDER_16   ; HL = patch address for the skip-over
        ld (PROC_SKIP_PATCH_TMP),hl
        ld a,(TOK_TYPE)
        cp TOK_LPAREN
        jr z,.have_lparen
        ld a,51                  ; expected '(' after a name
        rst $30
.have_lparen:
        rst $08                 ; consume '('
        ld a,(TOK_TYPE)
        cp TOK_IDENT
        jr z,.have_param
        ld a,52                  ; expected a parameter name
        rst $30
.have_param:
        ld hl,(TOK_NAME)
        ld a,(TOK_LEN)
        ld b,a
        call CSYM_FIND_OR_CREATE
        ld (PROC_PARAM_INDEX_TMP),a
        rst $08                 ; consume the parameter name
        ld a,(TOK_TYPE)
        cp TOK_RPAREN
        jr z,.have_rparen
        ld a,53                  ; expected ')'
        rst $30
.have_rparen:
        rst $08                 ; consume ')'
        ld a,(TOK_TYPE)
        cp TOK_ASSIGN
        jr z,.have_assign
        ld a,54                  ; expected '=' before body
        rst $30
.have_assign:
        ; define the CALL-entry label HERE -- at the PARAM_BIND position,
        ; the real call target -- same convention COMPILE_PROC's own
        ; identical comment already established.
        ld hl,(STMT_IDENT_NAME_PTR)
        ld a,(STMT_IDENT_NAME_LEN)
        ld b,a
        call LABEL_DEFINE
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        call EMIT_OP_PARAM_BIND
        ld a,(PROC_PARAM_INDEX_TMP)
        rst $20
        rst $08                 ; consume '=', prime the body expr's own
                                  ; first token
        call COMPILE_EXPR       ; body -> result left on the VM operand
                                  ; stack, on purpose (RET_DEFFN pops
                                  ; nothing else)
        ld a,(COMPILE_ERROR_CODE)
        or a
        ret nz
        call EMIT_OP_PARAM_UNBIND
        ld a,(PROC_PARAM_INDEX_TMP)
        rst $20
        call EMIT_OP_RET_DEFFN
        call COMPILE_RELATIVE_OFFSET  ; HL = relative offset (current position)
        ex de,hl                  ; DE = relative offset
        ld hl,(PROC_SKIP_PATCH_TMP)
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
        rst $08                     ; consume the extension keyword
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
        rst $30
.have_comma:
        rst $08                     ; consume ','
        jr .arg_loop
.emit:
        call EMIT_OP_CALL_EXT
        ld a,(CEXT_SLOT)
        rst $20
        ld a,(CEXT_GEN)
        rst $20
        ld a,(CEXT_ARGCOUNT)
        jp EMIT_BYTE

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
        push hl                 ; preserves every register (callers continue
        ld hl,COMPILE_ERROR_CODE ; after an error and some keep B/C live)
        inc (hl)                ; R10.7 P0: the FIRST error is the real one; a
        dec (hl)                ; cascade of follow-on errors must not replace
        jr nz,.keep             ; it (the nesting guard below relies on this)
        ld (hl),a
.keep:
        pop hl
        ret

; COMPILE_STACK_CHECK -- R10.7 P0. The compiler recurses on the Z80 stack
; (parentheses, IF blocks, unary chains). Nothing used to stop a deeply
; nested program from running the stack down into the package window at
; $F400-$F7FF. Returns carry set (after raising error 60) when SP is below
; V2_COMPILE_STACK_FLOOR; the caller returns at once without recursing, and
; the first-error-wins rule in COMPILE_RAISE_ERROR keeps code 60 as the
; reported error. Floor $FA00 leaves 512 bytes above the package window for
; unguarded unary/NOT chains (<= 127 chars), helper calls and interrupts.
; MEASURED: 12 nested parentheses used 174 bytes (12-14 B per level).
COMPILE_STACK_CHECK:
        ld hl,0
        add hl,sp
        ld a,h
        cp V2_COMPILE_STACK_FLOOR >> 8
        ret nc
        ld a,60
        call COMPILE_RAISE_ERROR
        scf
        ret
V2_COMPILE_STACK_FLOOR: equ $FA00

COMPILER_END:

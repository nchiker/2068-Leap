; ============================================================================
; rom/exrom_v2_decompiler.asm — Architecture B, R8 Phase 1: bytecode
; decompiler ("LIST" side of the editor/compiler interface)
;
; 2068-Leap V2 rewrite. Walks compiled V2 bytecode (rom/exrom_v2_vm_core.asm's
; own opcode encoding) and reconstructs valid, re-compilable BASIC-like
; source text — the piece docs/v2/V2_ARCHITECTURE.md's own diagram calls
; out as "LIST/EDIT reconstructing text via a small decompiler" and
; docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R8 section flags as
; "not yet built in any spike."
;
; STANDING CONVENTION (see rom/exrom_v2_vm_core.asm's own header for the
; full account): never keep a value live in a register across a `call`;
; save to memory first; check the callee's own "Destroys:" line.
;
; SCOPE, an honest partial completion (R8 Phase 1, mirroring R7's own
; Phase 1/Phase 2 split): decompiles the R1-R3 numeric/control-flow core
; -- HALT/PUSH_I8/PUSH_I16/LOAD_VAR/STORE_VAR/ADD/SUB/MUL/DIV/CMP_LT/
; CMP_EQ/JMP/JMPZ/FOR_INIT/FOR_NEXT. Deliberately NOT yet covered here:
; strings (R5), floats (R6), the native-call/platform family (R7), and
; procedures (R4's CALL/RET) -- each is a real, scoped extension of the
; SAME mechanism built here (mechanical for strings/floats/native-calls;
; procedures need real additional design for detecting PROC/ENDP body
; boundaries in bytecode, since that isn't tagged explicitly) -- not
; attempted this pass, per the same "ship a real, tested slice, document
; the honest remainder" discipline R7 Phase 1 already established.
;
; DESIGN: variable NAMES are never preserved in bytecode by design
; (rom/exrom_v2_vm_core.asm's own SYMTAB stores [tag][value] only, per
; docs/v2/REWRITE_RAM_BUDGET.md's compiled-index design) -- this
; decompiler does not try to recover the user's original spelling. It
; SYNTHESIZES names from the symbol index (V0, V1, V2, ...) instead. This
; is a real, deliberate, documented compatibility break: decompiled text
; is a VALID re-rendering, not a byte-identical one -- exactly the bar
; ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's own R8 "Tests" line already
; sets ("a valid, if not necessarily byte-identical, re-rendering").
; Branch targets are likewise synthesized as "L<bytecode-address>" labels
; (GOTO's own original label spelling isn't preserved either, for the
; same reason: LABELTAB_BASE is compile-time-only scratch, not part of
; the persisted bytecode).
;
; ALGORITHM: a classic stack-based bytecode-to-source decompiler, two
; passes. Pass 1 (DECOMP_COLLECT_LABELS) walks the bytecode once,
; recording every distinct JMP/JMPZ target address, so pass 2 knows where
; to emit a synthetic label. Pass 2 (DECOMPILE_PROGRAM) walks it again:
; value-producing opcodes (PUSH_I8/PUSH_I16/LOAD_VAR/ADD/SUB/MUL/DIV/
; CMP_LT/CMP_EQ) push a TEXT FRAGMENT (not a VM value) onto a small
; fragment stack; statement-terminating opcodes (STORE_VAR/HALT/FOR_INIT/
; FOR_NEXT) pop the fragments they need and emit a full output line.
;
; IF...THEN GOTO is pattern-matched, not decompiled opcode-by-opcode:
; rom/exrom_v2_compiler.asm's COMPILE_IF always emits the SAME fixed
; shape (<cond>, JMPZ skip, JMP target, skip:), so a JMPZ whose own
; target is EXACTLY 3 bytes past the JMP immediately following it is
; unambiguously that shape's own signature — reversed back to "IF <cond>
; THEN GOTO L<target>" as one statement, consuming both opcodes together.
; A JMPZ that does NOT match this shape has no meaning in THIS compiler's
; own current output (COMPILE_IF is JMPZ's only user) and is a real,
; caught decompile error rather than silently guessed at.
; ============================================================================

; ---------------------------------------------------------------------------
; Workspace — placed at $8C00-$8F70, immediately after
; rom/exrom_v2_compiler.asm's own STRSYMTAB_BASE (the last thing below
; VM_CODE_BASE $9000) and well clear of it, in space nothing else
; claims. NOT the $8000-$8370 range an earlier draft of this file used:
; that range was believed empty from a grep across only
; rom/exrom_v2_*.asm's own `equ`s, but include/sysvars.inc's real
; DEFS-allocated sysvars (confirmed from a real build's own .sym file)
; run continuously from $8000 through $8454 with zero gaps -- DIV_
; DIVIDEND/DIV_QUOT/DIV_COUNTER/MATH_SIGN (kernel/math/math.asm's own
; MATH_DIVIDE16 scratch, used by this file's own DECOMP_EMIT_UINT16 for
; decimal conversion) land at $8126-$812B, squarely inside the old
; DECOMP_OUT_BUF -- a real, confirmed bug: every GOTO/IF...THEN GOTO
; label whose digit-conversion ran AFTER other text had already been
; written into that exact byte range came out with that text stomped.
; Found via a real ts2068-debug run (not single-stepping, which never
; happened to execute far enough past the corrupting call to reveal
; it) plus a deterministic tools/z80sim replay for independent
; confirmation. docs/v2/REWRITE_RAM_BUDGET.md's own "$8455-$BFFF usable
; pool" figure is the real boundary -- $8000-$8454 is 100% sysvars, not
; scratch space, regardless of what any single rom/exrom_v2_*.asm file's
; own `equ`s do or don't mention. This file's own workspace now reuses
; the tail of the compiler's own scratch region instead (compile and
; decompile never run concurrently -- LIST happens between RUN/COMPILE
; calls, never during one -- the same lifecycle reasoning already
; established for VM_STACK/VM_CALL_STACK-style reuse elsewhere in this
; codebase), landing in space nothing else claims at all.
; ---------------------------------------------------------------------------
DECOMP_FRAG_MAX:      equ 8       ; fragment stack depth — matches
                                    ; VM_STACK's own depth; well-formed
                                    ; bytecode from THIS project's own
                                    ; compiler never needs more
DECOMP_FRAG_TEXT_MAX: equ 31       ; bytes of text per fragment (matches
                                    ; STRTAB's own 31-byte cap — an
                                    ; already-precedented bound in this
                                    ; codebase, not a new invention).
                                    ; Real, honest, bounded limitation:
                                    ; an expression whose reconstructed
                                    ; text would exceed this is a real,
                                    ; caught decompile error, not a
                                    ; silent truncation — acceptable for
                                    ; this milestone's own scope (R1-R3's
                                    ; own test coverage never nests
                                    ; arithmetic more than one level deep)
DECOMP_FRAG_REC_LEN:  equ 32       ; 1 length byte + 31 text
DECOMP_FRAG_BASE:     equ $8C00   ; 8*32 = 256 bytes, ends $8D00
DECOMP_OUT_BUF:       equ $8D00   ; reconstructed text output (400
                                    ; bytes, ends $8E90 — generous for
                                    ; this milestone's own test program)
; R8 Phase 2 (strings/floats/native-calls/procedures) scratch, added
; below — placed in the 112-byte gap between DECOMP_OUT_BUF's own real
; end ($8E90) and DECOMP_LABEL_TABLE ($8F00), space this file already
; owns outright (kernel/extensions/ext_registry.asm's own EXT2_TABLE
; sits at $8F70+, past this file's own highest address, not here).
DECOMP_ARG_PTR0:      equ $8E90   ; up to 4 popped-argument fragment
DECOMP_ARG_PTR1:      equ $8E92   ; pointers (2 bytes each) -- LINE's
DECOMP_ARG_PTR2:      equ $8E94   ; own 4-argument shape is the widest
DECOMP_ARG_PTR3:      equ $8E96   ; native-call statement this covers
DECOMP_ARG_LEN0:      equ $8E98   ; the matching 4 lengths (1 byte each)
DECOMP_ARG_LEN1:      equ $8E99
DECOMP_ARG_LEN2:      equ $8E9A
DECOMP_ARG_LEN3:      equ $8E9B
DECOMP_EXT_SLOT:      equ $8E9C   ; OP_CALL_EXT's own slot-id operand
                                    ; byte, parked across the registry
                                    ; readback (1 byte)
DECOMP_EXT_ARGCOUNT:  equ $8E9D   ; OP_CALL_EXT's own argcount operand
                                    ; byte (1 byte)
DECOMP_FLOAT_TOTAL:   equ $8E9E   ; PUSH_FLOAT_LIT's own total-digit-
                                    ; position count (1 byte)
DECOMP_ENDIF_HIT:     equ $8EA1   ; R8.5 Group 3 -- DECOMP_CHECK_ENDIF_
                                    ; HERE's own result (1 byte): how
                                    ; many "ENDIF" markers it emitted at
                                    ; the current address (0 = none)
DECOMP_ENDIF_SAVE_PTR: equ $8EA2  ; DECOMP_CHECK_ENDIF_HERE's own loop
                                    ; state (slot pointer, 2 bytes),
                                    ; parked in memory (never the
                                    ; hardware stack) across its own call
                                    ; to DECOMP_EMIT_TEXT -- same real
                                    ; bug class this file's own .op_jmpz
                                    ; header already documents finding
DECOMP_ARR_INDEX_TMP: equ $8EA5  ; R8.5 Group 4 -- .op_arr_load/.op_arr_store
                                    ; scratch (1 byte): the operand's own
                                    ; array index, saved to memory before
                                    ; DECOMP_FRAG_POP (which destroys
                                    ; AF/DE/HL, same discipline as every
                                    ; other handler in this file)
DECOMP_FN_ARGCOUNT:   equ $8EA6  ; R8.5 Group 6 -- .op_call_fn's own
                                    ; DECOMP_BUILTIN_FN_NAME readback
                                    ; (1 byte): how many argument
                                    ; fragments to pop/re-render, same
                                    ; role DECOMP_EXT_ARGCOUNT plays for
                                    ; .op_call_ext
DECOMP_FN_ARGTYPE:    equ $8EA7  ; R8.5 Group 6 (LEN/CODE/VAL) -- the
                                    ; matched function's own argtype (1
                                    ; byte): 0 = numeric, 1 = string
                                    ; (needs DECOMP_STR_OPERAND applied
                                    ; to each popped argument fragment)
DECOMP_ENDIF_SAVE_CNT: equ $8EA4  ; the matching remaining-slot-count
                                    ; (1 byte)
DECOMP_END_ADDR:      equ $8E9F   ; (2 bytes) R8.5 addition: the real
                                    ; end of the compiled program (the
                                    ; caller's own EMIT_PTR at the time
                                    ; it called COMPILE_PROGRAM -- see
                                    ; DECOMPILE_PROGRAM's own updated
                                    ; contract below). HALT (opcode 0)
                                    ; is no longer "the whole program's
                                    ; own end" by construction once
                                    ; END/STOP (R8.5) compile to it too
                                    ; -- a real, mid-program END/STOP is
                                    ; valid V1 behavior (stops execution
                                    ; early; the program TEXT, and any
                                    ; bytecode reachable only via GOTO,
                                    ; continues past it) that the
                                    ; original "HALT always ends the
                                    ; walk" logic would have silently
                                    ; truncated from decompiled output.
DECOMP_LABEL_TABLE:   equ $8F00   ; up to 16 distinct jump-target
                                    ; addresses, 2 bytes each (32 bytes,
                                    ; ends $8F20) — collected by the
                                    ; pre-pass below
DECOMP_LABEL_MAX:     equ 16
; R8.5 Group 3 -- block IF/ELSE/ENDIF reconstruction. A pending "ENDIF"
; marker is recorded (relative bytecode address -> emit "ENDIF" there)
; for every block-IF's own JMPZ; OP_JMP_ELSE (the dedicated, decompiler-
; unambiguous opcode COMPILE_IF_BLOCK's own else-skip jump compiles to,
; distinct from a bare user GOTO's plain JMP) cancels that marker and
; emits "ELSE" instead, in its place, when the walk reaches it -- see
; DECOMP_CHECK_ENDIF_HERE/.op_jmp_else's own header for the full
; algorithm.
DECOMP_ENDIF_MARKERS: equ $8F20   ; up to 8 slots, 2 bytes each (16
                                    ; bytes, ends $8F30); an unused slot
                                    ; holds $FFFF (never a real relative
                                    ; bytecode address)
DECOMP_ENDIF_MAX:     equ 8
DECOMP_LABEL_COUNT:   equ $8F30   ; 1 byte
DECOMP_IP:            equ $8F32   ; current bytecode read pointer (2B)
DECOMP_OUT_PTR:       equ $8F34   ; current output write pointer (2B)
DECOMP_FRAG_SP:       equ $8F36   ; fragment stack depth, 0-8 (1 byte)
DECOMP_ERROR_CODE:    equ $8F37   ; 0 = no error; see values below
DECOMP_TMP_A:         equ $8F38   ; general-purpose 2-byte scratch,
                                    ; reused across several routines
                                    ; below (never live across more than
                                    ; one call at a time — each routine's
                                    ; own body says exactly how it uses it)
DECOMP_TMP_B:         equ $8F3A   ; a second general-purpose 2-byte
                                    ; scratch, same reasoning
DECOMP_TMP_LEN:       equ $8F3C   ; 1-byte length scratch
DECOMP_COMBINE_BUF:   equ $8F40   ; scratch buffer for building a binary
                                    ; expression's combined text ("(A+B)")
                                    ; before pushing it as one new
                                    ; fragment (32 bytes, matching a
                                    ; fragment record's own size)
DECOMP_COMBINE_LEN:   equ $8F60   ; running length while building into
                                    ; DECOMP_COMBINE_BUF (1 byte)
DECOMP_NUM_VAL:       equ $8F61   ; DECOMP_EMIT_INT16 scratch (2 bytes):
                                    ; the value still being converted
DECOMP_NUM_QUOT:      equ $8F63   ; DECOMP_EMIT_INT16 scratch (2 bytes):
                                    ; this iteration's quotient
DECOMP_NUM_DIGITS:    equ $8F65   ; up to 5 decimal digits, built least-
                                    ; significant first (5 bytes)
DECOMP_NUM_DIGCOUNT:  equ $8F6A   ; how many digits are in the buffer
                                    ; above (1 byte)

; ---------------------------------------------------------------------------
; DECOMP_ERROR_CODE values:
;   0 = no error
;   1 = fragment stack overflow (malformed/adversarial bytecode — never
;       expected from this project's own compiler)
;   2 = fragment stack underflow (same)
;   3 = illegal/not-yet-decompilable opcode (R4/R5/R6/R7's own opcodes —
;       see this file's own header for the honest, scoped-out remainder)
;   4 = a combined expression's reconstructed text exceeded
;       DECOMP_FRAG_TEXT_MAX
;   5 = label table full (more than DECOMP_LABEL_MAX distinct jump
;       targets)
;   6 = a JMPZ was found that does NOT match EITHER of COMPILE_IF's own
;       two fixed shapes (single-line "THEN GOTO", or R8.5 Group 3's
;       block IF) — JMPZ has no other meaning in this compiler's
;       current output
;   7 = ENDIF-marker table full (more than DECOMP_ENDIF_MAX outstanding
;       block IFs open at once — R8.5 Group 3)
; ---------------------------------------------------------------------------

; ===========================================================================
; DECOMP_FRAG_ADDR — index (A) -> HL = record address
; (DECOMP_FRAG_BASE + index*32). Destroys: AF, DE, HL.
; ===========================================================================
DECOMP_FRAG_ADDR:
        ld l,a
        ld h,0
        add hl,hl               ; *2
        add hl,hl               ; *4
        add hl,hl               ; *8
        add hl,hl               ; *16
        add hl,hl               ; *32
        ld de,DECOMP_FRAG_BASE
        add hl,de
        ret

; ===========================================================================
; DECOMP_FRAG_PUSH — input: HL = source text pointer, C = length
; (<=DECOMP_FRAG_TEXT_MAX). Copies the fragment onto the stack.
; Destroys: AF, BC, DE, HL.
; ===========================================================================
DECOMP_FRAG_PUSH:
        ld (DECOMP_TMP_A),hl     ; park source ptr — DECOMP_FRAG_ADDR
                                   ; below uses HL/DE as its own scratch
        ld a,c
        ld (DECOMP_TMP_LEN),a
        ld a,(DECOMP_FRAG_SP)
        cp DECOMP_FRAG_MAX
        jp nc,DECOMP_ERR_FRAG_OVERFLOW
        call DECOMP_FRAG_ADDR     ; HL -> dest record (A = current SP,
                                    ; the right index to push at)
        ld a,(DECOMP_TMP_LEN)
        ld (hl),a                 ; write length byte
        inc hl
        ex de,hl                   ; DE -> dest text
        ld hl,(DECOMP_TMP_A)        ; HL -> source text (recovered)
        ld a,(DECOMP_TMP_LEN)
        ld c,a
        ld b,0
        or a
        jr z,.no_copy
        ldir
.no_copy:
        ld a,(DECOMP_FRAG_SP)
        inc a
        ld (DECOMP_FRAG_SP),a
        ret

; ===========================================================================
; DECOMP_FRAG_POP — output: HL = text pointer, C = length. The popped
; fragment's bytes remain physically present at that address until the
; NEXT push reuses the same slot — callers must consume (copy/emit) it
; before pushing anything new. Destroys: AF, DE, HL (and sets C).
; ===========================================================================
DECOMP_FRAG_POP:
        ld a,(DECOMP_FRAG_SP)
        or a
        jp z,DECOMP_ERR_FRAG_UNDERFLOW
        dec a
        ld (DECOMP_FRAG_SP),a
        call DECOMP_FRAG_ADDR      ; HL -> record
        ld c,(hl)                   ; C = length
        inc hl                       ; HL -> text
        ret

; ===========================================================================
; DECOMP_EMIT_TEXT — input: HL = text pointer, C = length. Appends to
; DECOMP_OUT_BUF. Destroys: AF, BC, DE, HL.
; ===========================================================================
DECOMP_EMIT_TEXT:
        ld a,c
        or a
        ret z
        ld de,(DECOMP_OUT_PTR)
.loop:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        dec c
        jr nz,.loop
        ld (DECOMP_OUT_PTR),de
        ret

; DECOMP_EMIT_CHAR — input: A = character. Destroys: AF, BC, DE, HL.
DECOMP_EMIT_CHAR:
        ld (DECOMP_TMP_LEN),a    ; reuse as a 1-byte source buffer
        ld hl,DECOMP_TMP_LEN
        ld c,1
        call DECOMP_EMIT_TEXT
        ret

; ===========================================================================
; DECOMP_COMBINE_RESET / DECOMP_COMBINE_CHAR / DECOMP_COMBINE_TEXT —
; build text into DECOMP_COMBINE_BUF (tracked by DECOMP_COMBINE_LEN)
; rather than the output buffer directly, so a binary op's "(A+B)" can be
; measured and bound-checked BEFORE being pushed as one new fragment.
; ===========================================================================
DECOMP_COMBINE_RESET:
        xor a
        ld (DECOMP_COMBINE_LEN),a
        ret

; input: A = character. Destroys: AF, HL.
DECOMP_COMBINE_CHAR:
        push af
        ld a,(DECOMP_COMBINE_LEN)
        ld l,a
        ld h,0
        ld de,DECOMP_COMBINE_BUF
        add hl,de
        pop af
        ld (hl),a
        ld a,(DECOMP_COMBINE_LEN)
        inc a
        ld (DECOMP_COMBINE_LEN),a
        ret

; input: HL = text pointer, A = length. Destroys: AF, BC, DE, HL.
DECOMP_COMBINE_TEXT:
        or a
        ret z
        ld b,a
.loop:
        ld a,(hl)
        push hl
        push bc
        call DECOMP_COMBINE_CHAR
        pop bc
        pop hl
        inc hl
        djnz .loop
        ret

; ===========================================================================
; DECOMP_EMIT_INT16 — input: HL = signed 16-bit value. Emits decimal
; ASCII to the OUTPUT buffer directly (via DECOMP_EMIT_TEXT), a leading
; '-' for negative values. Destroys: AF, BC, DE, HL.
; ===========================================================================
; ===========================================================================
; R10-class consolidation, pulled forward into R8.5 once the real ROM
; budget went negative (see this milestone's own reconciliation-phase
; commit): DECOMP_EMIT_INT16, DECOMP_EMIT_UINT16, DECOMP_VARNAME_FRAG,
; and DECOMP_INT_FRAG each independently reimplemented the SAME div-
; by-10 digit-accumulation loop (found via this milestone's own deep
; consolidation audit). DECOMP_COMPUTE_DIGITS below is that loop,
; factored out ONCE; DECOMP_EMIT_DIGITS/DECOMP_COMBINE_DIGITS are the
; two thin emission tails (straight to the output buffer, or into the
; combine buffer for a FRAG producer) every caller already needed.
; Every caller's own sign-handling/zero-prefix/wrapping logic is
; UNCHANGED -- only the digit computation itself moved.
; ===========================================================================

; DECOMP_COMPUTE_DIGITS — input: HL = UNSIGNED 16-bit value. Output:
; DECOMP_NUM_DIGITS/DECOMP_NUM_DIGCOUNT filled with this value's
; decimal digit characters, most-significant-first storage order
; (matches every original caller's own layout, so DECOMP_EMIT_DIGITS/
; DECOMP_COMBINE_DIGITS below can walk it unchanged). value=0 is NOT
; special-cased here (unlike the original callers' own top-level "is
; it zero" branch) -- callers still check that themselves before
; calling, same division of responsibility as before, just the
; nonzero digit loop itself shared. Destroys: AF, BC, DE, HL.
DECOMP_COMPUTE_DIGITS:
        ld (DECOMP_NUM_VAL),hl
        xor a
        ld (DECOMP_NUM_DIGCOUNT),a
.divloop:
        ld hl,(DECOMP_NUM_VAL)
        ld a,h
        or l
        ret z
        ld de,10
        call MATH_DIVIDE16        ; HL = quotient (real, already-
                                    ; verified platform primitive —
                                    ; reused, not reimplemented)
        ld (DECOMP_NUM_QUOT),hl
        ld de,10
        call MATH_MULTIPLY16       ; HL = quotient*10
        ld de,(DECOMP_NUM_VAL)      ; DE = the value THIS iteration
                                     ; started with (not yet overwritten
                                     ; — DECOMP_NUM_VAL is only updated
                                     ; below, after this remainder calc)
        ld a,e
        sub l
        ld l,a
        ld a,d
        sbc a,h
        ld h,a                       ; HL = value - quotient*10 =
                                       ; remainder (0-9)
        ld a,l
        add a,'0'
        push af                        ; save the digit character
        ld hl,DECOMP_NUM_DIGCOUNT
        ld a,(hl)
        ld e,a
        ld d,0
        ld hl,DECOMP_NUM_DIGITS
        add hl,de
        pop af
        ld (hl),a                       ; store into the digit buffer
        ld a,(DECOMP_NUM_DIGCOUNT)
        inc a
        ld (DECOMP_NUM_DIGCOUNT),a
        ld hl,(DECOMP_NUM_QUOT)
        ld (DECOMP_NUM_VAL),hl
        jr .divloop

; DECOMP_EMIT_DIGITS — emits DECOMP_NUM_DIGITS[0..DIGCOUNT-1] straight
; to the output buffer, most-significant digit first. Destroys: AF,
; BC, DE, HL.
DECOMP_EMIT_DIGITS:
        ld a,(DECOMP_NUM_DIGCOUNT)
        ld b,a
.loop:
        dec b
        ld hl,DECOMP_NUM_DIGITS
        ld e,b
        ld d,0
        add hl,de
        ld a,(hl)
        push bc
        call DECOMP_EMIT_CHAR
        pop bc
        ld a,b
        or a
        jr nz,.loop
        ret

; DECOMP_COMBINE_DIGITS — same as DECOMP_EMIT_DIGITS but into the
; combine buffer (for a FRAG producer). Destroys: AF, BC, DE, HL.
DECOMP_COMBINE_DIGITS:
        ld a,(DECOMP_NUM_DIGCOUNT)
        ld b,a
.loop:
        dec b
        ld hl,DECOMP_NUM_DIGITS
        ld e,b
        ld d,0
        add hl,de
        ld a,(hl)
        push bc
        call DECOMP_COMBINE_CHAR
        pop bc
        ld a,b
        or a
        jr nz,.loop
        ret

DECOMP_EMIT_INT16:
        bit 7,h
        jr z,.positive
        xor a
        sub l
        ld l,a
        ld a,0
        sbc a,h
        ld h,a                   ; HL = -HL (two's complement negate)
        ld (DECOMP_TMP_A),hl      ; park before emitting '-' --
                                    ; DECOMP_EMIT_CHAR destroys HL (both
                                    ; every OTHER instance of this exact
                                    ; bug class already found in this
                                    ; file); currently unreachable in
                                    ; practice (every real caller only
                                    ; ever passes a small non-negative
                                    ; index), fixed anyway for the next
                                    ; caller that doesn't
        ld a,'-'
        call DECOMP_EMIT_CHAR
        ld hl,(DECOMP_TMP_A)
.positive:
        ld a,h
        or l
        jr nz,.nonzero
        ld a,'0'
        jp DECOMP_EMIT_CHAR
.nonzero:
        call DECOMP_COMPUTE_DIGITS
        jp DECOMP_EMIT_DIGITS

; ===========================================================================
; DECOMP_EMIT_VARNAME — input: A = SYMTAB index. Emits "V<index>" to the
; output buffer (synthesized name — see this file's own header for why).
; Destroys: AF, BC, DE, HL.
; ===========================================================================
DECOMP_EMIT_VARNAME:
        push af                  ; DECOMP_EMIT_CHAR destroys BC (its own
                                    ; "Destroys" line) -- parking the index
                                    ; in C across that call was the real
                                    ; bug found here by a real run: every
                                    ; STORE_VAR/LOAD_VAR past the first
                                    ; decompiled a wrong (garbage) index.
                                    ; The hardware stack, not a register,
                                    ; is what actually survives the call.
        ld a,'V'
        call DECOMP_EMIT_CHAR
        pop af
        ld l,a
        ld h,0
        call DECOMP_EMIT_INT16
        ret

; DECOMP_VARNAME_FRAG — same as DECOMP_EMIT_VARNAME, but builds the text
; into DECOMP_COMBINE_BUF (via DECOMP_COMBINE_RESET/CHAR) and pushes it
; as a new fragment instead of emitting straight to the output buffer —
; used by LOAD_VAR, which produces a VALUE (a fragment), not a statement.
; Input: A = SYMTAB index. Destroys: AF, BC, DE, HL.
DECOMP_VARNAME_FRAG:
        ld (DECOMP_TMP_LEN),a    ; park the index — DECOMP_COMBINE_RESET
                                    ; touches no registers that matter
                                    ; here, but this keeps the pattern
                                    ; consistent and safe regardless
        call DECOMP_COMBINE_RESET
        ld a,'V'
        call DECOMP_COMBINE_CHAR
        ld a,(DECOMP_TMP_LEN)
        ld l,a
        ld h,0
        ld a,h
        or l
        jr nz,.nonzero
        ld a,'0'
        call DECOMP_COMBINE_CHAR
        jr .done
.nonzero:
        call DECOMP_COMPUTE_DIGITS
        call DECOMP_COMBINE_DIGITS
.done:
        ld a,(DECOMP_COMBINE_LEN)
        ld c,a
        ld hl,DECOMP_COMBINE_BUF
        call DECOMP_FRAG_PUSH
        ret

; ===========================================================================
; DECOMP_INT_FRAG — input: HL = signed 16-bit value. Pushes its decimal
; text (a leading '-' if negative, no other prefix) as a new fragment —
; used by PUSH_I8/PUSH_I16. Same digit algorithm as DECOMP_EMIT_INT16/
; DECOMP_VARNAME_FRAG, built into the combine buffer instead of emitted
; straight to output. Destroys: AF, BC, DE, HL.
; ===========================================================================
DECOMP_INT_FRAG:
        call DECOMP_COMBINE_RESET
        bit 7,h
        jr z,.positive
        xor a
        sub l
        ld l,a
        ld a,0
        sbc a,h
        ld h,a                        ; HL = abs(value)
        ld (DECOMP_TMP_A),hl           ; park it -- DECOMP_COMBINE_CHAR
                                         ; destroys HL (its own "Destroys"
                                         ; line), so emitting '-' AFTER
                                         ; negating but BEFORE reloading
                                         ; would silently lose the negated
                                         ; value; found by re-checking this
                                         ; exact call sequence, the same
                                         ; class of bug already found (and
                                         ; fixed) twice elsewhere in this
                                         ; file, this time in Phase 1's own
                                         ; code -- never triggered by
                                         ; Phase 1's own test program,
                                         ; which never decompiled a
                                         ; negative literal
        ld a,'-'
        call DECOMP_COMBINE_CHAR
        ld hl,(DECOMP_TMP_A)
.positive:
        ld a,h
        or l
        jr nz,.nonzero
        ld a,'0'
        call DECOMP_COMBINE_CHAR
        jr .done
.nonzero:
        call DECOMP_COMPUTE_DIGITS
        call DECOMP_COMBINE_DIGITS
.done:
        ld a,(DECOMP_COMBINE_LEN)
        ld c,a
        ld hl,DECOMP_COMBINE_BUF
        call DECOMP_FRAG_PUSH
        ret

; ===========================================================================
; Binary-op decompile — six thin stubs sharing DECOMP_BINARY_OP. Pops
; B's fragment then A's (B was pushed last), builds "(A<op>B)" in the
; combine buffer, pushes it as one new fragment.
; ===========================================================================
DECOMP_OP_PTR:  equ $8F6B
DECOMP_OP_LEN:  equ $8F6D
DECOMP_BLEN:    equ $8F6E
DECOMP_LABEL_HIT: equ $8F6F  ; DECOMP_CHECK_LABEL_HERE's own result flag
                               ; (1 byte): 1 if it emitted "Lxxxx:" at the
                               ; current address, 0 otherwise -- lets
                               ; DECOMPILE_PROGRAM's own main loop know
                               ; whether to follow it with a newline

DECOMP_BINARY_OP:               ; input: HL = operator text, B = length
        ld (DECOMP_OP_PTR),hl
        ld a,b
        ld (DECOMP_OP_LEN),a
        call DECOMP_FRAG_POP     ; HL = B's text, C = B's length
        ld (DECOMP_TMP_B),hl
        ld a,c
        ld (DECOMP_BLEN),a
        call DECOMP_FRAG_POP     ; HL = A's text, C = A's length
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_TMP_LEN),a
        call DECOMP_COMBINE_RESET
        ld a,'('
        call DECOMP_COMBINE_CHAR
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_TMP_LEN)
        call DECOMP_COMBINE_TEXT
        ld hl,(DECOMP_OP_PTR)
        ld a,(DECOMP_OP_LEN)
        call DECOMP_COMBINE_TEXT
        ld hl,(DECOMP_TMP_B)
        ld a,(DECOMP_BLEN)
        call DECOMP_COMBINE_TEXT
        ld a,')'
        call DECOMP_COMBINE_CHAR
        ld a,(DECOMP_COMBINE_LEN)
        cp DECOMP_FRAG_TEXT_MAX+1
        jp nc,DECOMP_ERR_EXPR_TOO_LONG
        ld c,a
        ld hl,DECOMP_COMBINE_BUF
        call DECOMP_FRAG_PUSH
        ret

STR_PLUS:  db "+"
STR_MINUS: db "-"
STR_STAR:  db "*"
STR_SLASH: db "/"
STR_LT:    db "<"
STR_EQ:    db "="
STR_LE:    db "<="
STR_GT:    db ">"
STR_GE:    db ">="
STR_NE:    db "<>"
STR_AND:   db " AND "
STR_OR:    db " OR "
STR_NOT:   db "NOT "
STR_NOT_LEN: equ $-STR_NOT

DECOMP_OP_ADD:
        ld hl,STR_PLUS
        ld b,1
        jp DECOMP_BINARY_OP
DECOMP_OP_SUB:
        ld hl,STR_MINUS
        ld b,1
        jp DECOMP_BINARY_OP
DECOMP_OP_MUL:
        ld hl,STR_STAR
        ld b,1
        jp DECOMP_BINARY_OP
DECOMP_OP_DIV:
        ld hl,STR_SLASH
        ld b,1
        jp DECOMP_BINARY_OP
DECOMP_OP_CMPLT:
        ld hl,STR_LT
        ld b,1
        jp DECOMP_BINARY_OP
DECOMP_OP_CMPEQ:
        ld hl,STR_EQ
        ld b,1
        jp DECOMP_BINARY_OP

; R8.5 Group 3 -- the remaining relops, plus AND/OR/NOT.
DECOMP_OP_CMPLE:
        ld hl,STR_LE
        ld b,2
        jp DECOMP_BINARY_OP
DECOMP_OP_CMPGT:
        ld hl,STR_GT
        ld b,1
        jp DECOMP_BINARY_OP
DECOMP_OP_CMPGE:
        ld hl,STR_GE
        ld b,2
        jp DECOMP_BINARY_OP
DECOMP_OP_CMPNE:
        ld hl,STR_NE
        ld b,2
        jp DECOMP_BINARY_OP
DECOMP_OP_AND:
        ld hl,STR_AND
        ld b,5
        jp DECOMP_BINARY_OP
DECOMP_OP_OR:
        ld hl,STR_OR
        ld b,4
        jp DECOMP_BINARY_OP
DECOMP_OP_NOT:
        ld hl,STR_NOT
        ld b,STR_NOT_LEN
        jp DECOMP_UNARY_OP

; DECOMP_UNARY_OP -- input: HL = operator text (trailing space already
; included, e.g. "NOT "), B = length. Pops ONE fragment, wraps it as
; "(OP <arg>)", pushes the result as a new fragment. Same shape as
; DECOMP_BINARY_OP, but for a one-operand opcode.
DECOMP_UNARY_OP:
        ld (DECOMP_OP_PTR),hl
        ld a,b
        ld (DECOMP_OP_LEN),a
        call DECOMP_FRAG_POP     ; HL = operand text, C = length
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_TMP_LEN),a
        call DECOMP_COMBINE_RESET
        ld a,'('
        call DECOMP_COMBINE_CHAR
        ld hl,(DECOMP_OP_PTR)
        ld a,(DECOMP_OP_LEN)
        call DECOMP_COMBINE_TEXT
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_TMP_LEN)
        call DECOMP_COMBINE_TEXT
        ld a,')'
        call DECOMP_COMBINE_CHAR
        ld a,(DECOMP_COMBINE_LEN)
        cp DECOMP_FRAG_TEXT_MAX+1
        jp nc,DECOMP_ERR_EXPR_TOO_LONG
        ld c,a
        ld hl,DECOMP_COMBINE_BUF
        call DECOMP_FRAG_PUSH
        ret

; ===========================================================================
; DECOMP_RECORD_LABEL — input: DE = target bytecode address. Adds it to
; DECOMP_LABEL_TABLE if not already present. Destroys: AF, BC, DE, HL.
; ===========================================================================
DECOMP_RECORD_LABEL:
        ld (DECOMP_TMP_A),de
        ld a,(DECOMP_LABEL_COUNT)
        or a
        jr z,.append
        ld b,a
        ld hl,DECOMP_LABEL_TABLE
.scan:
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,(DECOMP_TMP_A)
        cp e
        jr nz,.next
        ld a,(DECOMP_TMP_A+1)
        cp d
        jr z,.found          ; already recorded
.next:
        dec b
        jr nz,.scan
.append:
        ld a,(DECOMP_LABEL_COUNT)
        cp DECOMP_LABEL_MAX
        jp nc,DECOMP_ERR_LABEL_TABLE_FULL
        ld l,a
        ld h,0
        add hl,hl                ; index*2
        ld de,DECOMP_LABEL_TABLE
        add hl,de
        ld de,(DECOMP_TMP_A)
        ld (hl),e
        inc hl
        ld (hl),d
        ld a,(DECOMP_LABEL_COUNT)
        inc a
        ld (DECOMP_LABEL_COUNT),a
.found:
        ret

; ===========================================================================
; DECOMP_SKIP_OPERAND — input: A = opcode (already consumed from
; DECOMP_IP). Advances DECOMP_IP past that opcode's own operand bytes
; (0/1/2/3, per its real width — JMP/JMPZ are NOT skipped here; the
; caller handles their own 2-byte target specially, since it needs the
; VALUE, not just the width). Anything outside this decompiler's own
; supported set (opcode >= 15, i.e. R4's CALL/RET onward) is a real,
; caught error. Destroys: AF, HL.
; ===========================================================================
DECOMP_SKIP_OPERAND:
        cp 0                     ; HALT
        jp z,.w0
        cp 5                      ; ADD
        jp z,.w0
        cp 7                      ; SUB
        jp z,.w0
        cp 8                      ; MUL
        jp z,.w0
        cp 9                      ; DIV
        jp z,.w0
        cp 10                     ; CMP_LT
        jp z,.w0
        cp 11                     ; CMP_EQ
        jp z,.w0
        cp 16                     ; RET (R4)
        jp z,.w0
        cp 19                     ; STR_CONCAT (R5)
        jp z,.w0
        cp 20                     ; STR_CMP_LT (R5)
        jp z,.w0
        cp 21                     ; STR_CMP_EQ (R5)
        jp z,.w0
        cp 23                     ; CLS (R7)
        jp z,.w0
        cp 24                     ; BORDER (R7)
        jp z,.w0
        cp 25                     ; INK (R7)
        jp z,.w0
        cp 26                     ; PAPER (R7)
        jp z,.w0
        cp 27                     ; PLOT (R7)
        jp z,.w0
        cp 28                     ; LINE (R7 Phase 2)
        jp z,.w0
        cp 29                     ; BEEP (R7 Phase 2)
        jp z,.w0
        cp 30                     ; SOUND (R7 Phase 2)
        jp z,.w0
        cp 31                     ; POKE (R7 Phase 2)
        jp z,.w0
        cp 32                     ; PAUSE (R7 Phase 2)
        jp z,.w0
        cp 33                     ; RANDOMISE (R7 Phase 2)
        jp z,.w0
        cp 35                     ; PRINT_NUM (R8.5)
        jp z,.w0
        cp 36                     ; PRINT_STR (R8.5)
        jp z,.w0
        cp 37                     ; LPRINT_NUM (R8.5)
        jp z,.w0
        cp 38                     ; LPRINT_STR (R8.5)
        jp z,.w0
        cp 40                     ; CMP_LE (R8.5 Group 3)
        jp z,.w0
        cp 41                     ; CMP_GT
        jp z,.w0
        cp 42                     ; CMP_GE
        jp z,.w0
        cp 43                     ; CMP_NE
        jp z,.w0
        cp 44                     ; AND
        jp z,.w0
        cp 45                     ; OR
        jp z,.w0
        cp 46                     ; NOT
        jp z,.w0
        cp 1                      ; PUSH_I8
        jr z,.w1
        cp 3                      ; LOAD_VAR
        jr z,.w1
        cp 4                      ; STORE_VAR
        jr z,.w1
        cp 13                     ; FOR_INIT
        jr z,.w1
        cp 18                     ; STORE_STR_VAR (R5)
        jr z,.w1
        cp 39                     ; CALL_FN (R8.5 Group 1)
        jr z,.w1
        cp 50                     ; INPUT_NUM (R8.5 Group 2)
        jr z,.w1
        cp 51                     ; INPUT_STR (R8.5 Group 2)
        jr z,.w1
        cp 2                      ; PUSH_I16
        jr z,.w2
        cp 15                     ; CALL (R4)
        jr z,.w2
        cp 47                     ; JMP_ELSE (R8.5 Group 3)
        jr z,.w2
        cp 48                     ; ARR_LOAD (R8.5 Group 4)
        jr z,.w2
        cp 49                     ; ARR_STORE (R8.5 Group 4)
        jr z,.w2
        cp 52                     ; MODE (R8.5 Group 5)
        jp z,.w0
        cp 53                     ; ULAPLUS (R8.5 Group 5)
        jp z,.w0
        cp 54                     ; PALETTE (R8.5 Group 5)
        jp z,.w0
        cp 14                     ; FOR_NEXT
        jr z,.w3
        cp 34                     ; CALL_EXT (R7.5)
        jr z,.w3
        cp 22                     ; PUSH_FLOAT_LIT (R6)
        jr z,.w4
        cp 17                     ; PUSH_STR_LIT (R5) -- variable width
        jr z,.wstr
        jp DECOMP_ERR_UNSUPPORTED_OPCODE
.w0:
        ret
.w1:
        ld hl,(DECOMP_IP)
        inc hl
        ld (DECOMP_IP),hl
        ret
.w2:
        ld hl,(DECOMP_IP)
        inc hl
        inc hl
        ld (DECOMP_IP),hl
        ret
.w3:
        ld hl,(DECOMP_IP)
        inc hl
        inc hl
        inc hl
        ld (DECOMP_IP),hl
        ret
.w4:
        ld hl,(DECOMP_IP)
        inc hl
        inc hl
        inc hl
        inc hl
        ld (DECOMP_IP),hl
        ret
; .wstr — 1 length byte + that many content bytes (matches OP_PUSH_
; STR_LIT's own real bytecode shape).
.wstr:
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld e,a
        ld d,0
        add hl,de
        ld (DECOMP_IP),hl
        ret

; ===========================================================================
; DECOMP_COLLECT_LABELS — Pass 1. Walks the bytecode from VM_CODE_BASE,
; recording every JMP/JMPZ target address. Destroys: AF, BC, DE, HL.
; ===========================================================================
DECOMP_COLLECT_LABELS:
        xor a
        ld (DECOMP_LABEL_COUNT),a
        ld hl,VM_CODE_BASE
        ld (DECOMP_IP),hl
.loop:
        ld a,(DECOMP_ERROR_CODE)
        or a
        ret nz
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld (DECOMP_IP),hl
        cp 0                      ; HALT -- R8.5: no longer synonymous
        jr nz,.not_halt            ; with "walk over" (END/STOP compile
                                     ; to it too, and a mid-program one
                                     ; is real, valid bytecode); same
                                     ; DECOMP_END_ADDR cutoff DECOMPILE_
                                     ; PROGRAM's own .op_halt uses
        ld hl,(DECOMP_IP)
        ld de,(DECOMP_END_ADDR)
        or a
        sbc hl,de
        ret z
        jr .loop
.not_halt:
        cp 6                       ; JMP
        jr z,.target
        cp 12                       ; JMPZ
        jr z,.jmpz_target
        call DECOMP_SKIP_OPERAND
        jr .loop
.target:
        ld hl,(DECOMP_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (DECOMP_IP),hl
        call DECOMP_RECORD_LABEL
        jr .loop
; R8.5 Group 3 -- a JMPZ's own target is only a genuine, real label if
; it matches COMPILE_IF's OLD "THEN GOTO" shape (the very next opcode
; is JMP, AND this JMPZ's own target equals that JMP's own address+3 --
; same check .op_jmpz's own runtime handler uses, Pass 2). Recording it
; then matches existing, already-relied-upon behavior (see e.g. rom/
; test_v2_editor_integration.asm's own captured EXPECTED_TEXT, which
; documents the resulting "Lxxx:" landing right after a THEN GOTO
; statement). Block IF's own JMPZ target is purely structural (tracked
; separately by DECOMPILE_PROGRAM's own ENDIF-marker mechanism) and
; must NOT also get a spurious "Lxxx:" label here.
.jmpz_target:
        ld hl,(DECOMP_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (DECOMP_IP),hl          ; DE = JMPZ target, HL -> candidate JMP
        ld (DECOMP_TMP_A),de
        ld a,(hl)
        cp 6
        jr nz,.loop                 ; not JMP -- block-IF shape, no label
        ld de,VM_CODE_BASE
        or a
        sbc hl,de                    ; HL = relative candidate-JMP addr
        ld de,3
        add hl,de                     ; HL = relative candidate-JMP addr+3
        ex de,hl                      ; DE = relative candidate-JMP addr+3
        ld hl,(DECOMP_TMP_A)           ; HL = JMPZ's own target (relative)
        or a
        sbc hl,de
        jr nz,.loop                     ; target mismatch -- block-IF shape
        ld de,(DECOMP_TMP_A)
        call DECOMP_RECORD_LABEL
        jr .loop

; ===========================================================================
; DECOMP_EMIT_UINT16 — input: HL = UNSIGNED 16-bit value. Emits decimal
; ASCII straight to the output buffer — used for bytecode addresses
; (always positive, and can exceed 32767, so DECOMP_EMIT_INT16's signed
; interpretation would be wrong here). Destroys: AF, BC, DE, HL.
; ===========================================================================
DECOMP_EMIT_UINT16:
        ld a,h
        or l
        jr nz,.nonzero
        ld a,'0'
        jp DECOMP_EMIT_CHAR
.nonzero:
        call DECOMP_COMPUTE_DIGITS
        jp DECOMP_EMIT_DIGITS

; DECOMP_EMIT_LABELNAME — input: DE = bytecode address. Emits "L<addr>"
; straight to the output buffer. Destroys: AF, BC, DE, HL.
DECOMP_EMIT_LABELNAME:
        push de                  ; DECOMP_EMIT_CHAR destroys DE (its own
                                    ; "Destroys" line) -- the plain
                                    ; `ex de,hl` after that call was
                                    ; recovering already-clobbered garbage,
                                    ; not the real target. Same bug class
                                    ; as DECOMP_EMIT_VARNAME's own fix
                                    ; above, found the same way: a real
                                    ; run producing garbled label digits.
        ld a,'L'
        call DECOMP_EMIT_CHAR
        pop hl
        call DECOMP_EMIT_UINT16
        ret

; DECOMP_CHECK_LABEL_HERE — input: HL = current bytecode position as a
; RELATIVE offset from VM_CODE_BASE (NOT DECOMP_IP's own absolute value
; directly -- DECOMP_LABEL_TABLE holds relative offsets, matching the raw
; JMP/JMPZ operand bytes DECOMP_COLLECT_LABELS records them from; the
; caller converts). If it matches a recorded label target, emits
; "L<addr>:" to the output
; buffer and sets DECOMP_LABEL_HIT to 1 (so DECOMPILE_PROGRAM's own
; caller knows to follow it with a newline before the statement text);
; otherwise sets DECOMP_LABEL_HIT to 0. Destroys: AF, BC, DE, HL.
DECOMP_CHECK_LABEL_HERE:
        ld (DECOMP_TMP_A),hl
        xor a
        ld (DECOMP_LABEL_HIT),a
        ld a,(DECOMP_LABEL_COUNT)
        or a
        ret z
        ld b,a
        ld hl,DECOMP_LABEL_TABLE
.loop:
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,(DECOMP_TMP_A)
        cp e
        jr nz,.next
        ld a,(DECOMP_TMP_A+1)
        cp d
        jr nz,.next
        ld de,(DECOMP_TMP_A)
        call DECOMP_EMIT_LABELNAME
        ld a,':'
        call DECOMP_EMIT_CHAR
        ld a,1
        ld (DECOMP_LABEL_HIT),a
        ret
.next:
        dec b
        jr nz,.loop
        ret

; ===========================================================================
; R8.5 Group 3 -- block IF/ELSE/ENDIF reconstruction support. See
; DECOMP_ENDIF_MARKERS's own header for the full algorithm; summary: a
; block-IF's own JMPZ (once its target fails the OLD "THEN GOTO" shape
; check) records a pending "ENDIF here" marker at its own relative
; target address. If the THEN-body turns out to end with the dedicated
; OP_JMP_ELSE opcode (only COMPILE_IF_BLOCK's own else-skip jump
; compiles to it — never a bare user GOTO), that marker is cancelled
; and "ELSE" is emitted directly in its place, with a NEW pending
; "ENDIF here" marker recorded at OP_JMP_ELSE's own target instead.
; ===========================================================================

; DECOMP_RECORD_ENDIF_MARKER — input: HL = relative bytecode address.
; Appends it to the first free ($FFFF) DECOMP_ENDIF_MARKERS slot.
; Destroys: AF, BC, DE, HL.
DECOMP_RECORD_ENDIF_MARKER:
        ld (DECOMP_TMP_A),hl
        ld hl,DECOMP_ENDIF_MARKERS
        ld b,DECOMP_ENDIF_MAX
.loop:
        ld a,(hl)
        cp $FF
        jr nz,.next
        inc hl
        ld a,(hl)
        cp $FF
        jr nz,.next2
        dec hl
        ld de,(DECOMP_TMP_A)
        ld (hl),e
        inc hl
        ld (hl),d
        ret
.next2:
        dec hl
.next:
        inc hl
        inc hl
        djnz .loop
        jp DECOMP_ERR_ENDIF_TABLE_FULL

; DECOMP_CANCEL_ENDIF_MARKER — input: HL = relative bytecode address to
; find and clear back to $FFFF, WITHOUT emitting anything (used when an
; OP_JMP_ELSE turns a tentative "ENDIF here" marker into "ELSE" instead).
; Silently does nothing if no matching marker exists (should never
; happen for well-formed compiler output; not worth a hard error over).
; Destroys: AF, BC, DE, HL.
DECOMP_CANCEL_ENDIF_MARKER:
        ld (DECOMP_TMP_A),hl
        ld hl,DECOMP_ENDIF_MARKERS
        ld b,DECOMP_ENDIF_MAX
.loop:
        ld a,(hl)
        cp $FF
        jr z,.next
        ld a,(DECOMP_TMP_A)
        cp (hl)
        jr nz,.next
        push hl
        inc hl
        ld a,(DECOMP_TMP_A+1)
        cp (hl)
        pop hl
        jr nz,.next
        ld (hl),$FF
        inc hl
        ld (hl),$FF
        dec hl
        ret                       ; a bytecode address is only ever
                                     ; recorded once (one JMPZ owns it),
                                     ; so the first match is the only one
.next:
        inc hl
        inc hl
        djnz .loop
        ret

; DECOMP_CHECK_ENDIF_HERE — input: HL = current relative bytecode
; address. Emits "ENDIF" (NOT followed by a newline -- same convention
; DECOMP_CHECK_LABEL_HERE's own "Lxxx:" text uses; the caller emits the
; newline) and clears every matching slot back to $FFFF, for every
; DECOMP_ENDIF_MARKERS entry equal to HL (normally at most one, but a
; deeply-nested IF whose own ENDIF coincides exactly with an enclosing
; IF's own ENDIF -- e.g. "IF a THEN IF b THEN x ENDIF ENDIF" with no
; trailing statement after the inner ENDIF -- legitimately stacks more
; than one at the same address). Sets DECOMP_ENDIF_HIT to the count
; emitted (0 if none). Destroys: AF, BC, DE, HL.
DECOMP_CHECK_ENDIF_HERE:
        ld (DECOMP_TMP_A),hl
        xor a
        ld (DECOMP_ENDIF_HIT),a
        ld hl,DECOMP_ENDIF_MARKERS
        ld b,DECOMP_ENDIF_MAX
.loop:
        ld a,(hl)
        cp $FF
        jr z,.next
        ld a,(DECOMP_TMP_A)
        cp (hl)
        jr nz,.next
        push hl
        inc hl
        ld a,(DECOMP_TMP_A+1)
        cp (hl)
        pop hl
        jr nz,.next
        ; match -- clear this slot, emit "ENDIF". HL/B are parked in
        ; memory across the call below, never the hardware stack (see
        ; this routine's own header, and .op_jmpz's, for why).
        ld (hl),$FF
        inc hl
        ld (hl),$FF
        dec hl
        ld (DECOMP_ENDIF_SAVE_PTR),hl
        ld a,b
        ld (DECOMP_ENDIF_SAVE_CNT),a
        ld hl,STR_ENDIF
        ld c,STR_ENDIF_LEN
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE     ; each stacked ENDIF needs its OWN
                                       ; newline -- two matches at the
                                       ; same address (a real, legitimate
                                       ; case: nested IFs both closing at
                                       ; the same point) must not
                                       ; concatenate into the single
                                       ; un-reparseable identifier
                                       ; "ENDIFENDIF" (a real bug found
                                       ; via a real ZEsarUX run)
        ld a,(DECOMP_ENDIF_HIT)
        inc a
        ld (DECOMP_ENDIF_HIT),a
        ld hl,(DECOMP_ENDIF_SAVE_PTR)
        ld a,(DECOMP_ENDIF_SAVE_CNT)
        ld b,a
.next:
        inc hl
        inc hl
        djnz .loop
        ret

; DECOMP_EMIT_NEWLINE — emits a CR (13) line terminator, the same
; convention `DECOMPILE_PROGRAM` uses to separate every reconstructed
; source line. Destroys: AF, BC, DE, HL.
DECOMP_EMIT_NEWLINE:
        ld a,13
        jp DECOMP_EMIT_CHAR

; ===========================================================================
; Decompile-error handlers — each sets DECOMP_ERROR_CODE (see the value
; table in this file's own header block) and returns; every caller checks
; DECOMP_ERROR_CODE and unwinds rather than continuing on bad state. Real,
; caught errors on malformed/unsupported bytecode, never a silent guess.
; ===========================================================================
DECOMP_ERR_FRAG_OVERFLOW:
        ld a,1
        ld (DECOMP_ERROR_CODE),a
        ret

DECOMP_ERR_FRAG_UNDERFLOW:
        ld a,2
        ld (DECOMP_ERROR_CODE),a
        ret

DECOMP_ERR_UNSUPPORTED_OPCODE:
        ld a,3
        ld (DECOMP_ERROR_CODE),a
        ret

DECOMP_ERR_EXPR_TOO_LONG:
        ld a,4
        ld (DECOMP_ERROR_CODE),a
        ret

DECOMP_ERR_LABEL_TABLE_FULL:
        ld a,5
        ld (DECOMP_ERROR_CODE),a
        ret

DECOMP_ERR_BAD_JMPZ_SHAPE:
        ld a,6
        ld (DECOMP_ERROR_CODE),a
        ret

DECOMP_ERR_ENDIF_TABLE_FULL:
        ld a,7
        ld (DECOMP_ERROR_CODE),a
        ret

; ===========================================================================
; DECOMPILE_PROGRAM — the decompiler's own top-level entry point ("Pass 2"
; from this file's own header). Assumes VM_CODE_BASE holds a real,
; well-formed program this SAME project's compiler produced (per this
; file's header, malformed/adversarial bytecode is a real caught error,
; not a security boundary this routine defends). Walks the bytecode once
; (after DECOMP_COLLECT_LABELS's own pre-pass), reconstructing one output
; source line per statement-terminating opcode into DECOMP_OUT_BUF,
; CR-terminated (DECOMP_EMIT_NEWLINE).
;
; CALLER CONTRACT (R8.5 addition): DECOMP_END_ADDR must be set to the
; real compiled program's own end address (the caller's own EMIT_PTR
; right after COMPILE_PROGRAM finished) BEFORE calling this. HALT
; (opcode 0) is no longer synonymous with "the whole program's own
; end" now that R8.5's END/STOP compile to it too -- a mid-program
; END/STOP is real, valid, and must not silently truncate whatever
; bytecode follows it (reachable via GOTO, or simply the rest of the
; source the user wrote). The walk now only truly stops once DECOMP_IP
; reaches DECOMP_END_ADDR (see .op_halt below); every HALT encountered
; before that renders as "END" and the walk continues.
;
; Output: DECOMP_OUT_BUF holds the reconstructed text; DECOMP_OUT_PTR
; holds one-past-the-end (so length = DECOMP_OUT_PTR - DECOMP_OUT_BUF);
; DECOMP_ERROR_CODE is 0 on success, nonzero on a real decode error (the
; partial output already emitted before the error is not meaningful and
; must not be trusted by the caller).
;
; IF...THEN GOTO's own JMPZ+JMP pair (see header) is consumed as ONE
; statement by the JMPZ case below; a JMPZ that doesn't match COMPILE_IF's
; fixed shape is DECOMP_ERR_BAD_JMPZ_SHAPE, since JMPZ has no other
; producer in this compiler's current output. A bare JMP (never preceded
; by a matching JMPZ, since a real one is already consumed above) is
; always COMPILE_GOTO's own output -- "GOTO L<target>".
;
; Destroys everything; this is a top-level driver, not a callee with a
; documented register contract to preserve.
; ===========================================================================
DECOMPILE_PROGRAM:
        call DECOMP_COLLECT_LABELS
        ld a,(DECOMP_ERROR_CODE)
        or a
        ret nz
        xor a
        ld (DECOMP_ERROR_CODE),a
        ld (DECOMP_FRAG_SP),a
        ld hl,DECOMP_OUT_BUF
        ld (DECOMP_OUT_PTR),hl
        ld hl,VM_CODE_BASE
        ld (DECOMP_IP),hl
        ; R8.5 Group 3 -- every DECOMP_ENDIF_MARKERS slot starts $FFFF
        ; ("unused"; never a real relative bytecode address)
        ld hl,DECOMP_ENDIF_MARKERS
        ld b,DECOMP_ENDIF_MAX
.endif_init:
        ld (hl),$FF
        inc hl
        ld (hl),$FF
        inc hl
        djnz .endif_init
.loop:
        ld hl,(DECOMP_IP)           ; DECOMP_IP is an ABSOLUTE bytecode
                                      ; pointer, but every JMP/JMPZ operand
                                      ; in the bytecode itself (and every
                                      ; entry DECOMP_COLLECT_LABELS records
                                      ; from them) is a RELATIVE offset from
                                      ; VM_CODE_BASE (OP_JMP's own runtime
                                      ; handler adds VM_CODE_BASE itself) --
                                      ; convert before comparing, or every
                                      ; "is a label here" check silently
                                      ; never matches. Found the same units
                                      ; mismatch independently in the JMPZ
                                      ; shape-check below, via a real run.
        ld de,VM_CODE_BASE
        or a
        sbc hl,de                    ; HL = relative offset
        call DECOMP_CHECK_LABEL_HERE
        ld a,(DECOMP_LABEL_HIT)
        or a
        jr z,.no_label
        call DECOMP_EMIT_NEWLINE
.no_label:
        ; R8.5 Group 3 -- same idea as the label check just above, but
        ; for pending "ENDIF here" markers (see DECOMP_ENDIF_MARKERS's
        ; own header). Re-derives the relative address rather than
        ; reusing HL from above -- DECOMP_CHECK_LABEL_HERE's own
        ; "Destroys: ... HL" already invalidated it.
        ld hl,(DECOMP_IP)
        ld de,VM_CODE_BASE
        or a
        sbc hl,de
        call DECOMP_CHECK_ENDIF_HERE  ; each match already emits its own
                                        ; trailing newline internally (see
                                        ; its own header) -- unlike the
                                        ; label check above, nothing more
                                        ; to do here
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld (DECOMP_IP),hl
        cp 0                     ; HALT -- .op_halt decides whether the
        jp z,.op_halt              ; walk truly ends (see its own header)
        cp 1
        jp z,.op_push_i8
        cp 2
        jp z,.op_push_i16
        cp 3
        jp z,.op_load_var
        cp 4
        jp z,.op_store_var
        cp 5
        jp z,.op_add
        cp 6
        jp z,.op_jmp
        cp 7
        jp z,.op_sub
        cp 8
        jp z,.op_mul
        cp 9
        jp z,.op_div
        cp 10
        jp z,.op_cmplt
        cp 11
        jp z,.op_cmpeq
        cp 12
        jp z,.op_jmpz
        cp 13
        jp z,.op_for_init
        cp 14
        jp z,.op_for_next
        cp 15
        jp z,.op_call
        cp 16
        jp z,.op_ret
        cp 17
        jp z,.op_push_str_lit
        cp 18
        jp z,.op_store_str_var
        cp 19
        jp z,.op_str_concat
        cp 20
        jp z,.op_str_cmplt
        cp 21
        jp z,.op_str_cmpeq
        cp 22
        jp z,.op_push_float_lit
        cp 23
        jp z,.op_cls
        cp 24
        jp z,.op_border
        cp 25
        jp z,.op_ink
        cp 26
        jp z,.op_paper
        cp 27
        jp z,.op_plot
        cp 28
        jp z,.op_line
        cp 29
        jp z,.op_beep
        cp 30
        jp z,.op_sound
        cp 31
        jp z,.op_poke
        cp 32
        jp z,.op_pause
        cp 33
        jp z,.op_randomise
        cp 34
        jp z,.op_call_ext
        cp 35
        jp z,.op_print_num
        cp 36
        jp z,.op_print_str
        cp 37
        jp z,.op_lprint_num
        cp 38
        jp z,.op_lprint_str
        cp 39
        jp z,.op_call_fn
        cp 40
        jp z,.op_cmple
        cp 41
        jp z,.op_cmpgt
        cp 42
        jp z,.op_cmpge
        cp 43
        jp z,.op_cmpne
        cp 44
        jp z,.op_and
        cp 45
        jp z,.op_or
        cp 46
        jp z,.op_not
        cp 47
        jp z,.op_jmp_else
        cp 48
        jp z,.op_arr_load
        cp 49
        jp z,.op_arr_store
        cp 50
        jp z,.op_input_num
        cp 51
        jp z,.op_input_str
        cp 52
        jp z,.op_mode
        cp 53
        jp z,.op_ulaplus
        cp 54
        jp z,.op_palette
        jp DECOMP_ERR_UNSUPPORTED_OPCODE

.op_halt:
        ; See DECOMPILE_PROGRAM's own updated header: HALT alone no
        ; longer means "the whole program's own end". If this is the
        ; program's REAL final HALT (DECOMP_IP now equals the caller's
        ; own DECOMP_END_ADDR), stop for real; otherwise this is a
        ; mid-program END/STOP -- emit it as text and keep walking.
        ld hl,(DECOMP_IP)
        ld de,(DECOMP_END_ADDR)
        or a
        sbc hl,de
        ret z
        ld hl,STR_END
        ld c,STR_END_LEN
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

.op_push_i8:
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld (DECOMP_IP),hl
        ld l,a
        ld h,0
        bit 7,a
        jr z,.pi8_pos
        ld h,$FF
.pi8_pos:
        call DECOMP_INT_FRAG
        jp DECOMPILE_PROGRAM.loop

.op_push_i16:
        ld hl,(DECOMP_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (DECOMP_IP),hl
        ex de,hl
        call DECOMP_INT_FRAG
        jp DECOMPILE_PROGRAM.loop

.op_load_var:
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld (DECOMP_IP),hl
        call DECOMP_VARNAME_FRAG
        jp DECOMPILE_PROGRAM.loop

.op_store_var:
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld (DECOMP_IP),hl
        ld (DECOMP_TMP_LEN),a       ; park the symtab index (1-byte cell)
        call DECOMP_FRAG_POP         ; HL = value text, C = its length
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_TMP_B),a           ; park length (low byte only used)
        ld a,(DECOMP_TMP_LEN)
        call DECOMP_EMIT_VARNAME      ; "V<idx>" straight to output
        ld a,' '
        call DECOMP_EMIT_CHAR
        ld a,'='
        call DECOMP_EMIT_CHAR
        ld a,' '
        call DECOMP_EMIT_CHAR
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_TMP_B)
        ld c,a
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

.op_add:
        call DECOMP_OP_ADD
        jp DECOMPILE_PROGRAM.loop
.op_sub:
        call DECOMP_OP_SUB
        jp DECOMPILE_PROGRAM.loop
.op_mul:
        call DECOMP_OP_MUL
        jp DECOMPILE_PROGRAM.loop
.op_div:
        call DECOMP_OP_DIV
        jp DECOMPILE_PROGRAM.loop
.op_cmplt:
        call DECOMP_OP_CMPLT
        jp DECOMPILE_PROGRAM.loop
.op_cmpeq:
        call DECOMP_OP_CMPEQ
        jp DECOMPILE_PROGRAM.loop

; Bare JMP -- either COMPILE_GOTO's own output (a JMPZ-paired JMP is
; already consumed whole by .op_jmpz below, and never falls through to
; here), OR COMPILE_PROC's own skip-jump (R4 addition): PROC compiles to
; "JMP skip / STORE_VAR paramidx / <body> / RET / skip:" -- the skip-JMP
; immediately followed by a STORE_VAR is that shape's own unambiguous
; signature (STORE_VAR never otherwise directly follows a JMP's operand
; in this compiler's real output), the same "peek the next opcode"
; technique .op_jmpz already uses for IF...THEN GOTO. Emits "PROC
; P<entry>(V<paramidx>)" and consumes the STORE_VAR as part of the
; header (COMPILE_PROC's own compiler auto-emits it the same way,
; outside the user's own PROC(...) text) -- body statements then
; decompile normally until RET (.op_ret below) closes it with "ENDP".
.op_jmp:
        ld hl,(DECOMP_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (DECOMP_IP),hl          ; DE = target (relative bytecode offset,
                                     ; unused in the PROC case); HL -> the
                                     ; candidate STORE_VAR opcode byte
        ld a,(hl)
        cp 4                        ; STORE_VAR
        jr z,.jmp_proc_header
        ld hl,STR_GOTO
        ld c,STR_GOTO_LEN
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_LABELNAME  ; consumes DE itself (see its own header)
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop
.jmp_proc_header:
        ld hl,(DECOMP_IP)           ; HL = absolute entry address (the
                                      ; STORE_VAR opcode's own position --
                                      ; COMPILE_PROC's own LABEL_DEFINE
                                      ; call places the CALL-entry label
                                      ; exactly here, not at the JMP)
        ld de,VM_CODE_BASE
        or a
        sbc hl,de                    ; HL = relative entry address
        ld (DECOMP_TMP_A),hl         ; park it -- DECOMP_EMIT_TEXT/CHAR
                                       ; below clobber HL
        ld hl,(DECOMP_IP)
        inc hl                        ; skip the STORE_VAR opcode byte itself
        ld a,(hl)                     ; the parameter's own symtab index
        ld (DECOMP_ARG_LEN0),a        ; NOT DECOMP_TMP_LEN -- EMIT_CHAR
                                        ; uses THAT cell as its own internal
                                        ; scratch, and EMIT_UINT16 calls
                                        ; EMIT_CHAR internally too, so both
                                        ; calls below would silently
                                        ; clobber the param index before
                                        ; DECOMP_EMIT_VARNAME ever reads
                                        ; it -- same hazard already found
                                        ; and fixed in .op_call/.op_store_
                                        ; str_var above; DECOMP_ARG_LEN0 is
                                        ; a cell neither EMIT_CHAR nor
                                        ; EMIT_UINT16 ever touches
        inc hl                         ; consume its 1-byte operand too
        ld (DECOMP_IP),hl
        ld hl,STR_PROC
        ld c,STR_PROC_LEN
        call DECOMP_EMIT_TEXT
        ld a,'P'
        call DECOMP_EMIT_CHAR
        ld hl,(DECOMP_TMP_A)
        call DECOMP_EMIT_UINT16
        ld a,'('
        call DECOMP_EMIT_CHAR
        ld a,(DECOMP_ARG_LEN0)
        call DECOMP_EMIT_VARNAME
        ld a,')'
        call DECOMP_EMIT_CHAR
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

; JMP_ELSE -- R8.5 Group 3. Always COMPILE_IF_BLOCK's own else-skip
; jump (a bare user GOTO always compiles to plain JMP, opcode 6, never
; this opcode -- see EMIT_OP_JMP_ELSE's own header). Cancels the
; tentative "ENDIF here" marker its own enclosing JMPZ recorded --
; exactly at this instruction's own end address, by construction, no
; lookup ambiguity -- emits "ELSE" in its place, and records a NEW
; "ENDIF here" marker at ITS OWN target instead (where the whole
; if/else really ends). Never emits "GOTO", unlike .op_jmp above --
; that is the whole reason this opcode exists.
.op_jmp_else:
        ld hl,(DECOMP_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (DECOMP_IP),hl          ; DE = this JMP_ELSE's own target
        ld (DECOMP_TMP_B),de        ; park the real ENDIF target
        ld hl,(DECOMP_IP)
        ld de,VM_CODE_BASE
        or a
        sbc hl,de                   ; HL = this instruction's own end
                                      ; address, relative -- exactly
                                      ; where the cancelled marker lives
        call DECOMP_CANCEL_ENDIF_MARKER
        ld hl,STR_ELSE
        ld c,STR_ELSE_LEN
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE
        ld hl,(DECOMP_TMP_B)
        call DECOMP_RECORD_ENDIF_MARKER
        ld a,(DECOMP_ERROR_CODE)
        or a
        ret nz
        jp DECOMPILE_PROGRAM.loop

; CALL -- a call SITE (COMPILE_CALL_STMT's own output): "<arg>" was
; already pushed by a preceding COMPILE_EXPR, so this pops exactly one
; fragment. The 2-byte operand is the SAME relative address .jmp_proc_
; header above names "P<entry>" from, so the two always agree by
; construction (both come from the one real bytecode address the
; compiler itself resolved the call to).
; NOTE: DECOMP_TMP_LEN is not safe to hold a caller's own value across a
; `call DECOMP_EMIT_CHAR` -- that routine uses DECOMP_TMP_LEN AS ITS OWN
; internal 1-byte source buffer (see its own body), even though its
; "Destroys" line only lists registers; a caller-held value parked there
; is silently overwritten. Found here (the arg text's own length,
; parked in DECOMP_TMP_LEN, was being clobbered by the 'P'/'(' DECOMP_
; EMIT_CHAR calls in between) by re-auditing every new handler in this
; file for the pattern after finding the same hazard in DECOMP_STR_
; OPERAND's own caller (.op_store_str_var, fixed above) -- DECOMP_ARG_
; LEN0 used instead, a cell nothing here calls into.
.op_call:
        ld hl,(DECOMP_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (DECOMP_IP),hl           ; DE = relative target address
        ld (DECOMP_TMP_B),de
        call DECOMP_FRAG_POP        ; HL = arg text, C = length
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_ARG_LEN0),a
        ld hl,STR_CALL
        ld c,STR_CALL_LEN
        call DECOMP_EMIT_TEXT
        ld a,'P'
        call DECOMP_EMIT_CHAR
        ld hl,(DECOMP_TMP_B)
        call DECOMP_EMIT_UINT16
        ld a,'('
        call DECOMP_EMIT_CHAR
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_ARG_LEN0)
        ld c,a
        call DECOMP_EMIT_TEXT
        ld a,')'
        call DECOMP_EMIT_CHAR
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

; RET -- always COMPILE_PROC's own ENDP output (the only RET producer in
; this compiler). Emits "ENDP"; the next opcode processed is naturally
; the position right after RET, which equals the enclosing PROC's own
; skip-JMP target -- consistent by construction, no extra bookkeeping
; needed here.
.op_ret:
        ld hl,STR_ENDP
        ld c,STR_ENDP_LEN
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

; JMPZ -- must match COMPILE_IF's fixed shape: the very next bytecode
; byte (right after this JMPZ's own 2-byte operand) is opcode 6 (JMP),
; AND this JMPZ's own target equals that JMP's OWN address + 3 (1 opcode
; byte + 2 operand bytes -- i.e. "the instruction right after the JMP").
; A JMPZ that doesn't match is a real, caught DECOMP_ERR_BAD_JMPZ_SHAPE
; (see this file's own header: JMPZ has no other producer).
; NOTE: every parked value below lives in DECOMP_TMP_A/DECOMP_TMP_B (memory),
; never the hardware stack, across any `call` -- DECOMP_FRAG_POP and
; DECOMP_EMIT_TEXT/CHAR/VARNAME can each reach a DECOMP_ERR_* handler, whose
; own `ret` unwinds directly back to whoever called DECOMPILE_PROGRAM (the
; same "abort via ret" convention every other error path in this file
; already relies on); an outstanding hardware-stack push at that moment
; would be popped as a bogus return address instead. Keeping everything
; that must survive a `call` in memory instead sidesteps that entirely.
.op_jmpz:
        ld hl,(DECOMP_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (DECOMP_IP),hl          ; DE = this JMPZ's own target, HL -> just
                                     ; past its operand (the candidate JMP,
                                     ; OR the block-IF's own THEN-body start)
        ld (DECOMP_TMP_B),de        ; park the JMPZ target
        ld a,(hl)
        cp 6                        ; must be JMP for the OLD "THEN GOTO"
        jr nz,.block_if               ; shape; anything else means R8.5
                                        ; Group 3's block-IF shape instead
        ld (DECOMP_TMP_A),hl        ; park the candidate JMP's own address
        inc hl
        ld c,(hl)
        inc hl
        ld b,(hl)                   ; BC = the JMP's own operand (the real
                                     ; GOTO target -- what IF...THEN GOTO
                                     ; actually branches to)
        ld hl,(DECOMP_TMP_A)         ; absolute candidate-JMP address --
        ld de,VM_CODE_BASE            ; convert to a relative offset first
        or a                           ; (same units mismatch as the main
        sbc hl,de                      ; loop's own label check above: the
                                         ; JMPZ operand in DECOMP_TMP_B is
                                         ; a RELATIVE offset, straight from
                                         ; the bytecode)
        ld de,3
        add hl,de                    ; HL = relative candidate-JMP addr + 3
        ex de,hl                     ; DE = relative candidate-JMP addr + 3
        ld hl,(DECOMP_TMP_B)          ; HL = this JMPZ's own target (already
                                        ; relative)
        or a
        sbc hl,de
        jr nz,.block_if               ; target mismatch -- block-IF shape
        ; shape confirmed -- BC (the real GOTO target) is still valid here
        ; (no call has happened yet in this handler); park it in memory
        ; before the calls below can clobber it.
        ld (DECOMP_TMP_B),bc
        ld hl,(DECOMP_TMP_A)
        ld de,3
        add hl,de                   ; consume the JMP too (3 more bytes:
        ld (DECOMP_IP),hl            ; opcode + 2-byte operand)
        call DECOMP_FRAG_POP        ; HL = condition text, C = length
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_TMP_LEN),a
        ld hl,STR_IF
        ld c,STR_IF_LEN
        call DECOMP_EMIT_TEXT
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_TMP_LEN)
        ld c,a
        call DECOMP_EMIT_TEXT
        ld hl,STR_THEN_GOTO
        ld c,STR_THEN_GOTO_LEN
        call DECOMP_EMIT_TEXT
        ld de,(DECOMP_TMP_B)         ; DE = the real GOTO target
        call DECOMP_EMIT_LABELNAME
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop
; R8.5 Group 3 -- block IF. DECOMP_TMP_B already holds this JMPZ's own
; (relative) target; DECOMP_IP is already correctly positioned right
; after the operand (the THEN-body's own start -- the walk continues
; into it immediately below, no recursion needed, same "one flat pass"
; approach the rest of this file already uses). Emits "IF <cond> THEN"
; and records a tentative "ENDIF here" marker at the JMPZ's own target;
; .op_jmp_else cancels it and substitutes "ELSE" if the THEN-body turns
; out to have one.
.block_if:
        ld hl,(DECOMP_TMP_B)
        call DECOMP_RECORD_ENDIF_MARKER
        ld a,(DECOMP_ERROR_CODE)
        or a
        ret nz
        call DECOMP_FRAG_POP        ; HL = condition text, C = length
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_TMP_LEN),a
        ld hl,STR_IF
        ld c,STR_IF_LEN
        call DECOMP_EMIT_TEXT
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_TMP_LEN)
        ld c,a
        call DECOMP_EMIT_TEXT
        ld hl,STR_THEN
        ld c,STR_THEN_LEN
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

; FOR_INIT: 1-byte symtab-index operand; pops TWO fragments (limit was
; pushed last by COMPILE_FOR, so it pops first) -- "FOR V<idx> = <init>
; TO <limit>".
.op_for_init:
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld (DECOMP_IP),hl
        ld (DECOMP_ARR_INDEX_TMP),a   ; symtab index -- NOT DECOMP_TMP_LEN:
                                        ; DECOMP_EMIT_CHAR reuses THAT cell
                                        ; as its own internal scratch (see
                                        ; this file's own .op_arr_store bug
                                        ; this same milestone) -- avoided
                                        ; here on purpose, not by luck
        call DECOMP_FRAG_POP        ; HL = step text, C = length (R8.5
                                       ; Group 5 -- pushed last at compile
                                       ; time, so popped first here)
        ld (DECOMP_OP_PTR),hl
        ld a,c
        ld (DECOMP_OP_LEN),a
        call DECOMP_FRAG_POP        ; HL = limit text, C = length
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_TMP_B),a
        call DECOMP_FRAG_POP        ; HL = init text, C = length
        ld (DECOMP_ARG_PTR0),hl
        ld a,c
        ld (DECOMP_ARG_LEN0),a
        ld hl,STR_FOR
        ld c,STR_FOR_LEN
        call DECOMP_EMIT_TEXT
        ld a,(DECOMP_ARR_INDEX_TMP)
        call DECOMP_EMIT_VARNAME
        ld a,' '
        call DECOMP_EMIT_CHAR
        ld a,'='
        call DECOMP_EMIT_CHAR
        ld a,' '
        call DECOMP_EMIT_CHAR
        ld hl,(DECOMP_ARG_PTR0)
        ld a,(DECOMP_ARG_LEN0)
        ld c,a
        call DECOMP_EMIT_TEXT       ; init text
        ld hl,STR_TO
        ld c,STR_TO_LEN
        call DECOMP_EMIT_TEXT
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_TMP_B)
        ld c,a
        call DECOMP_EMIT_TEXT       ; limit text
        ld hl,STR_STEP
        ld c,STR_STEP_LEN
        call DECOMP_EMIT_TEXT
        ld hl,(DECOMP_OP_PTR)
        ld a,(DECOMP_OP_LEN)
        ld c,a
        call DECOMP_EMIT_TEXT       ; step text -- always rendered, even
                                      ; for a STEP-less FOR (which compiles
                                      ; a literal 1) -- "valid, not byte-
                                      ; identical" re-rendering, same bar
                                      ; this whole file already uses
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

; NEXT: 3-byte operand [symtab_index:1][branch_target:2] -- the branch
; target is a fixed, implicit "jump back to this loop's own FOR_INIT-
; following address" (COMPILE_FOR/COMPILE_NEXT's own shape, always),
; carrying no extra information the reconstructed "NEXT V<idx>" text
; needs to show.
.op_for_next:
        ld hl,(DECOMP_IP)
        ld a,(hl)                    ; symtab index byte
        inc hl
        inc hl
        inc hl
        ld (DECOMP_IP),hl           ; skip the 3-byte operand wholesale
        ld hl,STR_NEXT
        ld c,STR_NEXT_LEN
        push af
        call DECOMP_EMIT_TEXT
        pop af
        call DECOMP_EMIT_VARNAME
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

; ===========================================================================
; R8 PHASE 2 -- strings (R5), floats (R6), and the native-call/platform
; family (R7/R7.5), the real remainder this file's own header flagged as
; deliberately out of Phase 1's scope.
; ===========================================================================

; PUSH_STR_LIT -- operand: [len:1][content:len]. Pushes a quoted string
; literal fragment ("..."). A literal whose own quoted text (2 quote
; chars + up to 31 content bytes) would exceed DECOMP_FRAG_TEXT_MAX is a
; real, caught DECOMP_ERR_EXPR_TOO_LONG, same bound every other fragment
; already respects.
.op_push_str_lit:
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld (DECOMP_TMP_LEN),a        ; content length
        ld (DECOMP_IP),hl            ; DECOMP_IP -> content start (parked;
                                       ; final advance happens below)
        call DECOMP_COMBINE_RESET
        ld a,'"'
        call DECOMP_COMBINE_CHAR
        ld a,(DECOMP_TMP_LEN)
        or a
        jr z,.psl_no_content
        ld hl,(DECOMP_IP)
        call DECOMP_COMBINE_TEXT     ; A = length (already in A), HL =
                                       ; content start
.psl_no_content:
        ld a,'"'
        call DECOMP_COMBINE_CHAR
        ld a,(DECOMP_COMBINE_LEN)
        cp DECOMP_FRAG_TEXT_MAX+1
        jp nc,DECOMP_ERR_EXPR_TOO_LONG
        ld hl,(DECOMP_IP)             ; advance DECOMP_IP past the content
        ld a,(DECOMP_TMP_LEN)
        ld e,a
        ld d,0
        add hl,de
        ld (DECOMP_IP),hl
        ld a,(DECOMP_COMBINE_LEN)
        ld c,a
        ld hl,DECOMP_COMBINE_BUF
        call DECOMP_FRAG_PUSH
        jp DECOMPILE_PROGRAM.loop

; STORE_STR_VAR -- operand: [target_idx:1]. Pops one fragment
; (reinterpreted via DECOMP_STR_OPERAND above), emits "S<idx>$ =
; <text>".
.op_store_str_var:
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld (DECOMP_IP),hl
        ld (DECOMP_ARG_LEN0),a        ; target strsym index -- NOT
                                        ; DECOMP_TMP_LEN: DECOMP_STR_
                                        ; OPERAND below uses THAT cell as
                                        ; its own internal scratch when it
                                        ; takes the reinterpret path, which
                                        ; would silently overwrite the
                                        ; target index before it's used --
                                        ; a real bug of the exact class
                                        ; already found and fixed twice
                                        ; earlier in this file, caught by
                                        ; re-reading this call chain rather
                                        ; than by a run this time
        call DECOMP_FRAG_POP          ; HL = value text, C = length
        call DECOMP_STR_OPERAND       ; HL = text, C = length (reinterpreted
                                        ; if needed)
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_TMP_B),a
        ld a,'S'
        call DECOMP_EMIT_CHAR
        ld a,(DECOMP_ARG_LEN0)
        ld l,a                        ; DECOMP_EMIT_INT16 wants a 16-bit
        ld h,0                         ; value in HL, not A -- a real bug,
                                         ; found by re-reading this call
                                         ; (DECOMP_EMIT_VARNAME's own
                                         ; correct L=A/H=0 pattern, just
                                         ; above, was the tell)
        call DECOMP_EMIT_INT16
        ld a,'$'
        call DECOMP_EMIT_CHAR
        ld a,' '
        call DECOMP_EMIT_CHAR
        ld a,'='
        call DECOMP_EMIT_CHAR
        ld a,' '
        call DECOMP_EMIT_CHAR
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_TMP_B)
        ld c,a
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

.op_str_concat:
        ld hl,STR_PLUS
        ld b,1
        call DECOMP_STR_BINARY_OP
        jp DECOMPILE_PROGRAM.loop
.op_str_cmplt:
        ld hl,STR_LT
        ld b,1
        call DECOMP_STR_BINARY_OP
        jp DECOMPILE_PROGRAM.loop
.op_str_cmpeq:
        ld hl,STR_EQ
        ld b,1
        call DECOMP_STR_BINARY_OP
        jp DECOMPILE_PROGRAM.loop

; PUSH_FLOAT_LIT -- operand: [value:2][divisor:2] (rom/exrom_v2_
; compiler.asm's own COMPILE_FLOAT_LITERAL: divisor is always
; 10^fractional-digit-count). Reconstructs decimal text directly from
; value/divisor -- no need for the real calculator's own float-to-string
; formatter, since this encoding is exactly "digits + where the point
; goes", not a general binary float. divisor is looked up against the
; 5 real values COMPILE_FLOAT_LITERAL can ever produce (1/10/100/1000/
; 10000 -- a 16-bit unsigned divisor can't reach 100000); anything else
; is real, caught, malformed bytecode (DECOMP_ERR_UNSUPPORTED_OPCODE,
; reused here as "this isn't a shape this compiler ever emits", same as
; its use for a genuinely unknown opcode byte).
.op_push_float_lit:
        ld hl,(DECOMP_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (DECOMP_TMP_A),de          ; value (signed)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (DECOMP_IP),hl
        ld a,e
        cp 1
        jr nz,.fdiv_not1
        ld a,d
        or a
        jr nz,.fdiv_not1
        xor a
        jr .fdiv_known
.fdiv_not1:
        ld hl,10                     ; `sbc hl,de` needs carry cleared
        or a                          ; before EVERY comparison, not just
        sbc hl,de                     ; the first -- a real bug: the 2nd
        jr z,.fdiv_is10                ; through 4th comparisons below
        ld hl,100                       ; were silently using whatever
        or a                              ; carry the PREVIOUS `sbc` left
        sbc hl,de                         ; set, corrupting the divisor
        jr z,.fdiv_is100                   ; match for 100/1000/10000 --
        ld hl,1000                          ; found via a real run (100
        or a                                  ; failed to match "3.14"'s
        sbc hl,de                             ; own real divisor)
        jr z,.fdiv_is1000
        ld hl,10000
        or a
        sbc hl,de
        jr z,.fdiv_is10000
        jp DECOMP_ERR_UNSUPPORTED_OPCODE
.fdiv_is10:    ld a,1 : jr .fdiv_known
.fdiv_is100:   ld a,2 : jr .fdiv_known
.fdiv_is1000:  ld a,3 : jr .fdiv_known
.fdiv_is10000: ld a,4
.fdiv_known:
        ld (DECOMP_TMP_LEN),a         ; fracdigits (0-4)
        call DECOMP_COMBINE_RESET
        ld hl,(DECOMP_TMP_A)
        bit 7,h
        jr z,.fpos
        xor a
        sub l
        ld l,a
        ld a,0
        sbc a,h
        ld h,a                        ; HL = abs(value)
        ld (DECOMP_NUM_VAL),hl         ; park it BEFORE emitting '-' --
                                         ; DECOMP_COMBINE_CHAR destroys HL;
                                         ; same fix as DECOMP_INT_FRAG's
                                         ; own (see that routine's header)
        ld a,'-'
        call DECOMP_COMBINE_CHAR
        ld hl,(DECOMP_NUM_VAL)
.fpos:
        ld (DECOMP_NUM_VAL),hl
        xor a
        ld (DECOMP_NUM_DIGCOUNT),a
.fdivloop:
        ld hl,(DECOMP_NUM_VAL)
        ld a,h
        or l
        jr z,.femit
        ld de,10
        call MATH_DIVIDE16
        ld (DECOMP_NUM_QUOT),hl
        ld de,10
        call MATH_MULTIPLY16
        ld de,(DECOMP_NUM_VAL)
        ld a,e
        sub l
        ld l,a
        ld a,d
        sbc a,h
        ld h,a
        ld a,l
        add a,'0'
        push af
        ld hl,DECOMP_NUM_DIGCOUNT
        ld a,(hl)
        ld e,a
        ld d,0
        ld hl,DECOMP_NUM_DIGITS
        add hl,de
        pop af
        ld (hl),a
        ld a,(DECOMP_NUM_DIGCOUNT)
        inc a
        ld (DECOMP_NUM_DIGCOUNT),a
        ld hl,(DECOMP_NUM_QUOT)
        ld (DECOMP_NUM_VAL),hl
        jr .fdivloop
.femit:
        ; total digit positions = max(digcount, fracdigits+1); emit
        ; most-significant first, inserting '.' right after the last
        ; INTEGER-part digit (fracdigits>0 only).
        ld a,(DECOMP_TMP_LEN)
        inc a                          ; fracdigits+1
        ld b,a
        ld a,(DECOMP_NUM_DIGCOUNT)
        cp b
        jr nc,.have_total
        ld a,b
.have_total:
        ld (DECOMP_FLOAT_TOTAL),a      ; own dedicated scratch cell --
                                         ; not an assumed-free adjacent
                                         ; byte (DECOMP_NUM_DIGCOUNT+1 is
                                         ; actually DECOMP_OP_PTR's own
                                         ; low byte, a real collision this
                                         ; file already paid for once with
                                         ; a much worse instance of the
                                         ; same mistake -- see this file's
                                         ; own header)
        ld b,a                          ; B = position, counting down
                                         ; from totaldigits
.femit_loop:
        dec b
        ld a,b
        ld hl,DECOMP_NUM_DIGCOUNT
        cp (hl)                         ; A(=B) - digcount; carry set iff
                                          ; B < digcount (a real digit
                                          ; exists at this position -- valid
                                          ; indices are 0..digcount-1, so
                                          ; B == digcount is ALREADY out of
                                          ; range and must zero-pad too;
                                          ; the original `cp b` (digcount-B)
                                          ; missed exactly that boundary --
                                          ; a real off-by-one caught by
                                          ; re-checking this arithmetic by
                                          ; hand, not by a run)
        jr nc,.femit_zero                ; B >= digcount -> a zero
        ld hl,DECOMP_NUM_DIGITS
        ld e,b
        ld d,0
        add hl,de
        ld a,(hl)
        jr .femit_have_digit
.femit_zero:
        ld a,'0'
.femit_have_digit:
        push bc
        call DECOMP_COMBINE_CHAR
        pop bc
        ld a,(DECOMP_TMP_LEN)          ; fracdigits
        cp b
        jr nz,.femit_no_point
        ld a,(DECOMP_TMP_LEN)
        or a
        jr z,.femit_no_point            ; fracdigits=0 -> no point at all
        ld a,'.'
        call DECOMP_COMBINE_CHAR
.femit_no_point:
        ld a,b
        or a
        jr nz,.femit_loop
        ld a,(DECOMP_COMBINE_LEN)
        cp DECOMP_FRAG_TEXT_MAX+1
        jp nc,DECOMP_ERR_EXPR_TOO_LONG
        ld c,a
        ld hl,DECOMP_COMBINE_BUF
        call DECOMP_FRAG_PUSH
        jp DECOMPILE_PROGRAM.loop

; ===========================================================================
; NATIVE-CALL/PLATFORM FAMILY (R7/R7.5) -- every argument was already
; pushed onto the operand stack by an ordinary COMPILE_EXPR before the
; opcode itself, so the opcode's OWN bytecode operand is always empty;
; decompiling is purely "pop N fragments, emit KEYWORD arg1,arg2,...".
; ===========================================================================

.op_cls:
        ld hl,STR_CLS
        ld c,STR_CLS_LEN
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

.op_border:
        ld hl,STR_BORDER
        ld (DECOMP_TMP_A),hl
        ld a,STR_BORDER_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_1ARG_STMT
        jp DECOMPILE_PROGRAM.loop
.op_ink:
        ld hl,STR_INK
        ld (DECOMP_TMP_A),hl
        ld a,STR_INK_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_1ARG_STMT
        jp DECOMPILE_PROGRAM.loop
.op_paper:
        ld hl,STR_PAPER
        ld (DECOMP_TMP_A),hl
        ld a,STR_PAPER_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_1ARG_STMT
        jp DECOMPILE_PROGRAM.loop
.op_pause:
        ld hl,STR_PAUSE
        ld (DECOMP_TMP_A),hl
        ld a,STR_PAUSE_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_1ARG_STMT
        jp DECOMPILE_PROGRAM.loop
.op_randomise:
        ld hl,STR_RANDOMISE
        ld (DECOMP_TMP_A),hl
        ld a,STR_RANDOMISE_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_1ARG_STMT
        jp DECOMPILE_PROGRAM.loop

; OP_PLOT pops y then x (compiler pushed x,y) -- "leftmost" in
; DECOMP_EMIT_2ARG_STMT's own sense is x, matching "PLOT x,y".
.op_plot:
        ld hl,STR_PLOT
        ld (DECOMP_TMP_A),hl
        ld a,STR_PLOT_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_2ARG_STMT
        jp DECOMPILE_PROGRAM.loop
; OP_BEEP pops pitch then duration (compiler pushed duration,pitch) --
; "leftmost" is duration, matching "BEEP duration,pitch".
.op_beep:
        ld hl,STR_BEEP
        ld (DECOMP_TMP_A),hl
        ld a,STR_BEEP_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_2ARG_STMT
        jp DECOMPILE_PROGRAM.loop
; OP_SOUND pops data then register (compiler pushed register,data) --
; "leftmost" is register, matching "SOUND register,data".
.op_sound:
        ld hl,STR_SOUND
        ld (DECOMP_TMP_A),hl
        ld a,STR_SOUND_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_2ARG_STMT
        jp DECOMPILE_PROGRAM.loop
; OP_POKE pops value then address (compiler pushed address,value) --
; "leftmost" is address, matching "POKE address,value".
.op_poke:
        ld hl,STR_POKE
        ld (DECOMP_TMP_A),hl
        ld a,STR_POKE_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_2ARG_STMT
        jp DECOMPILE_PROGRAM.loop

; LINE pops y1,x1,y0,x0 (compiler pushed x0,y0,x1,y1, matching "LINE
; x0,y0 TO x1,y1"'s own reading order).
.op_line:
        call DECOMP_FRAG_POP          ; y1
        ld (DECOMP_ARG_PTR0),hl
        ld a,c
        ld (DECOMP_ARG_LEN0),a
        call DECOMP_FRAG_POP          ; x1
        ld (DECOMP_ARG_PTR1),hl
        ld a,c
        ld (DECOMP_ARG_LEN1),a
        call DECOMP_FRAG_POP          ; y0
        ld (DECOMP_ARG_PTR2),hl
        ld a,c
        ld (DECOMP_ARG_LEN2),a
        call DECOMP_FRAG_POP          ; x0
        ld (DECOMP_ARG_PTR3),hl
        ld a,c
        ld (DECOMP_ARG_LEN3),a
        ld hl,STR_LINE
        ld c,STR_LINE_LEN
        call DECOMP_EMIT_TEXT
        ld hl,(DECOMP_ARG_PTR3)        ; x0
        ld a,(DECOMP_ARG_LEN3)
        ld c,a
        call DECOMP_EMIT_TEXT
        ld a,','
        call DECOMP_EMIT_CHAR
        ld hl,(DECOMP_ARG_PTR2)        ; y0
        ld a,(DECOMP_ARG_LEN2)
        ld c,a
        call DECOMP_EMIT_TEXT
        ld hl,STR_LINE_TO
        ld c,STR_LINE_TO_LEN
        call DECOMP_EMIT_TEXT
        ld hl,(DECOMP_ARG_PTR1)        ; x1
        ld a,(DECOMP_ARG_LEN1)
        ld c,a
        call DECOMP_EMIT_TEXT
        ld a,','
        call DECOMP_EMIT_CHAR
        ld hl,(DECOMP_ARG_PTR0)        ; y1
        ld a,(DECOMP_ARG_LEN0)
        ld c,a
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

; ===========================================================================
; CALL_EXT (R7.5) -- operand: [slot_id:1][generation:1][argcount:1].
; Unlike every OTHER identifier this decompiler synthesizes, an
; extension's real NAME survives: it's stored in kernel/extensions/
; ext_registry.asm's own EXT2_TABLE, live at decompile time exactly like
; it is at call time (the registry isn't compile-time-only scratch --
; see that file's own header), so this reads it straight from there
; instead of manufacturing "P<addr>"-style syntax. generation is not
; re-emitted (recompiling re-resolves it fresh from the CURRENT
; registry state, the same as the original source did).
; ===========================================================================
.op_call_ext:
        ld hl,(DECOMP_IP)
        ld a,(hl)
        ld (DECOMP_EXT_SLOT),a
        inc hl
        inc hl                          ; skip slot_id + generation
        ld a,(hl)
        ld (DECOMP_EXT_ARGCOUNT),a
        inc hl
        ld (DECOMP_IP),hl
        ; slot*EXT2_REC_LEN + EXT2_TABLE -> record; [gen:1][name_len:1]
        ; [name:8][exec:2][argcount:1]
        ld a,(DECOMP_EXT_SLOT)
        ld l,a
        ld h,0
        ld d,h
        ld e,l
        add hl,hl                        ; *2
        add hl,hl                        ; *4
        add hl,hl                        ; *8
        add hl,de                        ; *9  (EXT2_REC_LEN = 13,
        add hl,de                        ; *10  8 + 5 more DE(=slot)
        add hl,de                        ; *11  additions gets there)
        add hl,de                        ; *12
        add hl,de                        ; *13
        ld de,EXT2_TABLE
        add hl,de                        ; HL -> record
        inc hl                            ; -> name_len
        ld a,(hl)
        ld (DECOMP_TMP_LEN),a
        inc hl                              ; -> name
        ld (DECOMP_TMP_A),hl
        ld a,(DECOMP_TMP_LEN)
        ld c,a
        ld hl,(DECOMP_TMP_A)
        call DECOMP_EMIT_TEXT
        ld a,' '
        call DECOMP_EMIT_CHAR
        ld a,(DECOMP_EXT_ARGCOUNT)
        or a
        jp z,.cext_no_args
; BUG FOUND (real hardware, post-R8.5 SPRITE-module reconciliation):
; the ORIGINAL version of this handler popped fragments in reverse call
; order and emitted them AS POPPED, with a comment explicitly flagging
; this as "a real, documented limitation for more than 1 argument" --
; but that's not just a cosmetic ordering quirk: since a popped value's
; own POSITION determines which EXT_CALL_ARGn slot it lands in at
; runtime (OP_CALL_EXT's own pop_loop), a decompiled-then-recompiled
; multi-argument extension call with the args left in pop order
; compiles to a DIFFERENT bytecode than the original -- e.g. "GRAB
; 0,2,3,2,2" decompiled as "GRAB 2,2,3,2,0" and, if recompiled, would
; assign slot=2 instead of slot=0. Never caught before because no
; existing test decompiled a >1-argument extension call (rom/test_v2_
; ext_demo.asm's own TRIADD demo only checks the VM's own computed
; result, never calls DECOMPILE_PROGRAM) -- caught by rom/test_v2_
; sprite_module.asm's own real decompile-round-trip check. Fixed by
; popping all N fragments into slots first (DECOMP_ARG_PTR0-3/LEN0-3
; for the first 4, DECOMP_TMP_A/DECOMP_ARR_INDEX_TMP for a 5th --
; EXT2_REGISTER's own cap is 5 now, GRAB's own real argcount), THEN
; emitting slot 0..N-1 forward -- restoring original write order.
        ld b,a                    ; B = N -- DECOMP_FRAG_POP does NOT
                                    ; destroy B (checked its own header),
                                    ; safe as a loop counter across it
.cext_pop_loop:
        call DECOMP_FRAG_POP        ; pops argN first, then argN-1, ...
        push hl
        push bc
        ld a,b
        dec a                        ; this pop's own slot index (N-1
                                       ; on the first iteration, down to 0)
        cp 0
        jr z,.cps0
        cp 1
        jr z,.cps1
        cp 2
        jr z,.cps2
        cp 3
        jr z,.cps3
        jr .cps4
.cps0:
        pop bc
        pop hl
        ld (DECOMP_ARG_PTR0),hl
        ld a,c
        ld (DECOMP_ARG_LEN0),a
        jr .cext_pop_next
.cps1:
        pop bc
        pop hl
        ld (DECOMP_ARG_PTR1),hl
        ld a,c
        ld (DECOMP_ARG_LEN1),a
        jr .cext_pop_next
.cps2:
        pop bc
        pop hl
        ld (DECOMP_ARG_PTR2),hl
        ld a,c
        ld (DECOMP_ARG_LEN2),a
        jr .cext_pop_next
.cps3:
        pop bc
        pop hl
        ld (DECOMP_ARG_PTR3),hl
        ld a,c
        ld (DECOMP_ARG_LEN3),a
        jr .cext_pop_next
.cps4:
        pop bc
        pop hl
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_ARR_INDEX_TMP),a
.cext_pop_next:
        djnz .cext_pop_loop
        ; DECOMP_EXT_SLOT's own original purpose (registry slot id) is
        ; already consumed (the name was emitted above) -- reused here
        ; as the emit loop's own current-slot-index scratch, memory-
        ; based throughout (never a register across DECOMP_EMIT_TEXT/
        ; CHAR, both of which destroy BC per their own header).
        xor a
        ld (DECOMP_EXT_SLOT),a
.cext_emit_loop:
        ld a,(DECOMP_EXT_SLOT)
        cp 0
        jr z,.ce0
        cp 1
        jr z,.ce1
        cp 2
        jr z,.ce2
        cp 3
        jr z,.ce3
        jr .ce4
.ce0:
        ld hl,(DECOMP_ARG_PTR0)
        ld a,(DECOMP_ARG_LEN0)
        jr .cext_emit_common
.ce1:
        ld hl,(DECOMP_ARG_PTR1)
        ld a,(DECOMP_ARG_LEN1)
        jr .cext_emit_common
.ce2:
        ld hl,(DECOMP_ARG_PTR2)
        ld a,(DECOMP_ARG_LEN2)
        jr .cext_emit_common
.ce3:
        ld hl,(DECOMP_ARG_PTR3)
        ld a,(DECOMP_ARG_LEN3)
        jr .cext_emit_common
.ce4:
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_ARR_INDEX_TMP)
.cext_emit_common:
        ld c,a
        call DECOMP_EMIT_TEXT
        ld a,(DECOMP_EXT_ARGCOUNT)
        dec a
        ld (DECOMP_EXT_ARGCOUNT),a
        jr z,.cext_args_done
        ld a,','
        call DECOMP_EMIT_CHAR
        ld a,(DECOMP_EXT_SLOT)
        inc a
        ld (DECOMP_EXT_SLOT),a
        jr .cext_emit_loop
.cext_args_done:
.cext_no_args:
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

; PRINT/LPRINT -- each pops exactly one fragment (R8.5's own real
; scope, matching basic/basic.asm's real BASIC_EVAL_PRINT_ARG grammar:
; no comma/semicolon item list). DECOMP_EMIT_1ARG_STMT's own
; convention (keyword text at DECOMP_TMP_A/DECOMP_TMP_LEN) matches
; BORDER/INK/PAPER/PAUSE/RANDOMISE's own reuse of it exactly.
.op_print_num:
        ld hl,STR_PRINT
        ld (DECOMP_TMP_A),hl
        ld a,STR_PRINT_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_1ARG_STMT
        jp DECOMPILE_PROGRAM.loop
.op_print_str:
        ; NOT DECOMP_EMIT_1ARG_STMT -- the popped fragment here is a
        ; string-typed value, which (per DECOMP_STR_OPERAND's own header)
        ; needs the "PUSH_I16-as-strsym-index" reinterpretation before
        ; being emitted, or "PRINT A$" wrongly decompiles as "PRINT 0"
        ; (a real bug found via an actual run comparing decompiled text
        ; against the real program).
        call DECOMP_FRAG_POP          ; HL = arg text, C = length
        call DECOMP_STR_OPERAND
        ld (DECOMP_TMP_B),hl
        ld a,c
        ld (DECOMP_BLEN),a
        ld hl,STR_PRINT
        ld a,STR_PRINT_LEN
        ld c,a
        call DECOMP_EMIT_TEXT
        ld hl,(DECOMP_TMP_B)
        ld a,(DECOMP_BLEN)
        ld c,a
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop
.op_lprint_num:
        ld hl,STR_LPRINT
        ld (DECOMP_TMP_A),hl
        ld a,STR_LPRINT_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_1ARG_STMT
        jp DECOMPILE_PROGRAM.loop
.op_lprint_str:
        call DECOMP_FRAG_POP
        call DECOMP_STR_OPERAND
        ld (DECOMP_TMP_B),hl
        ld a,c
        ld (DECOMP_BLEN),a
        ld hl,STR_LPRINT
        ld a,STR_LPRINT_LEN
        ld c,a
        call DECOMP_EMIT_TEXT
        ld hl,(DECOMP_TMP_B)
        ld a,(DECOMP_BLEN)
        ld c,a
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

; R8.5 Group 1 -- CALL_FN is an EXPRESSION fragment producer (like ADD/
; SUB/etc. above), not a statement: it pops its one argument's own
; already-decompiled fragment, wraps it as "NAME(<arg>)", and pushes
; the result back as a new fragment for whatever consumes it next
; (PRINT, an assignment, another expression) -- never emits a newline
; itself.
; Multi-argument shape: fragments come off DECOMP_FRAG_POP in REVERSE
; (rightmost-argument-first) order, same as .op_call_ext's own operand
; stack -- popping and emitting in that same order would silently
; reverse a 2+-arg call's rendered argument order (a real, semantic-
; changing bug this milestone already found and fixed once for
; .op_call_ext's own identical shape). Fixed here the same way: pop all
; N fragments into fixed slots first, then emit forward in original
; write order.
.op_call_fn:
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld (DECOMP_IP),hl
        call DECOMP_BUILTIN_FN_NAME   ; A = fn_index in; HL = name text,
                                        ; C = name length, DECOMP_FN_
                                        ; ARGCOUNT out
        ld (DECOMP_OP_PTR),hl
        ld a,c
        ld (DECOMP_OP_LEN),a

        ld a,(DECOMP_FN_ARGCOUNT)
        ld b,a
.cfn_pop_loop:
        call DECOMP_FRAG_POP      ; HL = ptr, C = len; B = outer loop
                                    ; counter (DECOMP_FRAG_POP itself
                                    ; doesn't destroy B)
        ld a,(DECOMP_FN_ARGTYPE)
        or a
        jr z,.cfn_pop_numeric
        push bc                    ; DECOMP_STR_OPERAND's own contract
                                     ; destroys BC entirely -- park B
                                     ; (the outer loop counter) across
                                     ; it, same "value that must survive
                                     ; a destructive call lives off the
                                     ; register it's about to be
                                     ; destroyed in" discipline this
                                     ; whole rewrite keeps needing
        call DECOMP_STR_OPERAND   ; LEN/CODE/VAL (Group 6): a bare
                                    ; string-variable-reference fragment
                                    ; would otherwise render as plain
                                    ; digits (PUSH_I16's own generic
                                    ; rendering, which has no idea it's
                                    ; really a string index) -- same
                                    ; reinterpretation COMPILE_STR_ASSIGN/
                                    ; PRINT_STR's own decompile paths
                                    ; already need for the identical
                                    ; reason (see DECOMP_STR_OPERAND's
                                    ; own header)
        ld a,c                     ; A = the (possibly new) fragment length
        pop bc                     ; B restored; C about to be overwritten
        ld c,a
.cfn_pop_numeric:
        push hl
        push bc
        ld a,b
        dec a
        cp 0
        jr z,.cfnp0
        cp 1
        jr z,.cfnp1
        cp 2
        jr z,.cfnp2
        jr .cfnp3
.cfnp0:
        pop bc
        pop hl
        ld (DECOMP_ARG_PTR0),hl
        ld a,c
        ld (DECOMP_ARG_LEN0),a
        jr .cfn_pop_next
.cfnp1:
        pop bc
        pop hl
        ld (DECOMP_ARG_PTR1),hl
        ld a,c
        ld (DECOMP_ARG_LEN1),a
        jr .cfn_pop_next
.cfnp2:
        pop bc
        pop hl
        ld (DECOMP_ARG_PTR2),hl
        ld a,c
        ld (DECOMP_ARG_LEN2),a
        jr .cfn_pop_next
.cfnp3:
        pop bc
        pop hl
        ld (DECOMP_ARG_PTR3),hl
        ld a,c
        ld (DECOMP_ARG_LEN3),a
.cfn_pop_next:
        djnz .cfn_pop_loop

        call DECOMP_COMBINE_RESET
        ld hl,(DECOMP_OP_PTR)
        ld a,(DECOMP_OP_LEN)
        call DECOMP_COMBINE_TEXT
        ld a,'('
        call DECOMP_COMBINE_CHAR

        xor a
        ld (DECOMP_EXT_SLOT),a         ; reused as this loop's own
                                          ; index -- .op_call_ext's own
                                          ; use of this cell is long
                                          ; finished by the time this
                                          ; opcode's handler ever runs
.cfn_emit_loop:
        ld a,(DECOMP_EXT_SLOT)
        cp 0
        jr z,.cfne0
        cp 1
        jr z,.cfne1
        cp 2
        jr z,.cfne2
        jr .cfne3
.cfne0:
        ld hl,(DECOMP_ARG_PTR0)
        ld a,(DECOMP_ARG_LEN0)
        jr .cfn_emit_common
.cfne1:
        ld hl,(DECOMP_ARG_PTR1)
        ld a,(DECOMP_ARG_LEN1)
        jr .cfn_emit_common
.cfne2:
        ld hl,(DECOMP_ARG_PTR2)
        ld a,(DECOMP_ARG_LEN2)
        jr .cfn_emit_common
.cfne3:
        ld hl,(DECOMP_ARG_PTR3)
        ld a,(DECOMP_ARG_LEN3)
.cfn_emit_common:
        call DECOMP_COMBINE_TEXT
        ld a,(DECOMP_FN_ARGCOUNT)
        dec a
        ld (DECOMP_FN_ARGCOUNT),a
        jr z,.cfn_args_done
        ld a,','
        call DECOMP_COMBINE_CHAR
        ld a,(DECOMP_EXT_SLOT)
        inc a
        ld (DECOMP_EXT_SLOT),a
        jr .cfn_emit_loop
.cfn_args_done:
        ld a,')'
        call DECOMP_COMBINE_CHAR
        ld a,(DECOMP_COMBINE_LEN)
        cp DECOMP_FRAG_TEXT_MAX+1
        jp nc,DECOMP_ERR_EXPR_TOO_LONG
        ld c,a
        ld hl,DECOMP_COMBINE_BUF
        call DECOMP_FRAG_PUSH
        jp DECOMPILE_PROGRAM.loop

; R8.5 Group 4 -- array element access. Synthesized names again (no
; array-name preservation through compile, same "V<idx>"/"S<idx>$"
; convention this whole file already uses for scalars/strings): "A<idx>".
; ARRAY_MAX_COUNT is 4, so the index is always a single digit -- no need
; for DECOMP_EMIT_INT16/DECOMP_VARNAME_FRAG's full multi-digit algorithm.
.op_arr_load:
        ; expression fragment producer (like CALL_FN above): pops the
        ; already-decompiled index expression, wraps it as "A<idx>(<expr>)",
        ; pushes the result back as a new fragment. The operand's own
        ; second byte (declared size) is skipped -- needed only for the
        ; runtime bounds check, not for reconstructing source text.
        ld hl,(DECOMP_IP)
        ld a,(hl)
        ld (DECOMP_ARR_INDEX_TMP),a
        inc hl
        inc hl
        ld (DECOMP_IP),hl
        call DECOMP_FRAG_POP        ; HL = index-expr text, C = length
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_TMP_LEN),a
        call DECOMP_COMBINE_RESET
        ld a,'A'
        call DECOMP_COMBINE_CHAR
        ld a,(DECOMP_ARR_INDEX_TMP)
        add a,'0'
        call DECOMP_COMBINE_CHAR
        ld a,'('
        call DECOMP_COMBINE_CHAR
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_TMP_LEN)
        call DECOMP_COMBINE_TEXT
        ld a,')'
        call DECOMP_COMBINE_CHAR
        ld a,(DECOMP_COMBINE_LEN)
        cp DECOMP_FRAG_TEXT_MAX+1
        jp nc,DECOMP_ERR_EXPR_TOO_LONG
        ld c,a
        ld hl,DECOMP_COMBINE_BUF
        call DECOMP_FRAG_PUSH
        jp DECOMPILE_PROGRAM.loop

.op_arr_store:
        ; statement handler (like STORE_VAR above): pops the value
        ; fragment (top of stack) then the index-expression fragment,
        ; emits "A<idx>(<index-expr>) = <value>" straight to the output
        ; buffer.
        ;
        ; BUG FOUND (real hardware): DECOMP_EMIT_CHAR reuses DECOMP_TMP_LEN
        ; as ITS OWN internal 1-byte scratch buffer (see its own header:
        ; "reuse as a 1-byte source buffer") -- this handler originally
        ; parked the VALUE fragment's own length there too, then emitted
        ; SEVERAL individual characters ('(' ')' ' ' '=' ' ') via
        ; DECOMP_EMIT_CHAR before reading it back, each one silently
        ; overwriting DECOMP_TMP_LEN with that character's own code.
        ; Caught via a real ZEsarUX run + single-stepping: DECOMP_TMP_LEN
        ; read back as $20 (the last emitted space) instead of 2 (the real
        ; length of "10"), pulling in 32 garbage bytes as the "value" text
        ; and desyncing every line after it. Fixed by holding the value's
        ; length in DECOMP_BLEN instead -- a cell DECOMP_EMIT_CHAR never
        ; touches (confirmed by reading its own body, not assumed). Same
        ; underlying lesson as this file's other real bugs this session,
        ; one layer deeper: a MEMORY cell can alias a callee's own
        ; internal scratch just as easily as a register can.
        ld hl,(DECOMP_IP)
        ld a,(hl)
        ld (DECOMP_ARR_INDEX_TMP),a
        inc hl
        inc hl
        ld (DECOMP_IP),hl
        call DECOMP_FRAG_POP        ; HL = value text, C = length (top)
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_BLEN),a
        call DECOMP_FRAG_POP        ; HL = index-expr text, C = length
        ld (DECOMP_OP_PTR),hl
        ld a,c
        ld (DECOMP_OP_LEN),a
        ld a,'A'
        call DECOMP_EMIT_CHAR
        ld a,(DECOMP_ARR_INDEX_TMP)
        add a,'0'
        call DECOMP_EMIT_CHAR
        ld a,'('
        call DECOMP_EMIT_CHAR
        ld hl,(DECOMP_OP_PTR)
        ld a,(DECOMP_OP_LEN)
        ld c,a
        call DECOMP_EMIT_TEXT
        ld a,')'
        call DECOMP_EMIT_CHAR
        ld a,' '
        call DECOMP_EMIT_CHAR
        ld a,'='
        call DECOMP_EMIT_CHAR
        ld a,' '
        call DECOMP_EMIT_CHAR
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_BLEN)
        ld c,a
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

; R8.5 Group 2 (closed out late) -- INPUT. Statement handlers (not
; expression fragment producers): emit "INPUT V<idx>"/"INPUT S<idx>$"
; straight to the output buffer -- INPUT never pops a fragment (unlike
; STORE_VAR/STORE_STR_VAR, it has no source expression, only a target).
.op_input_num:
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld (DECOMP_IP),hl
        ld (DECOMP_ARR_INDEX_TMP),a   ; reuse -- a plain 1-byte scratch,
                                        ; not touched by DECOMP_EMIT_TEXT/
                                        ; DECOMP_EMIT_INT16 (confirmed by
                                        ; reading their own bodies, not
                                        ; assumed -- see this file's own
                                        ; DECOMP_TMP_LEN bug just above for
                                        ; why that check matters)
        ld hl,STR_INPUT
        ld c,STR_INPUT_LEN
        call DECOMP_EMIT_TEXT
        ld a,(DECOMP_ARR_INDEX_TMP)
        call DECOMP_EMIT_VARNAME
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

.op_input_str:
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld (DECOMP_IP),hl
        ld (DECOMP_ARR_INDEX_TMP),a
        ld hl,STR_INPUT
        ld c,STR_INPUT_LEN
        call DECOMP_EMIT_TEXT
        ld a,'S'
        call DECOMP_EMIT_CHAR
        ld a,(DECOMP_ARR_INDEX_TMP)
        ld l,a
        ld h,0
        call DECOMP_EMIT_INT16
        ld a,'$'
        call DECOMP_EMIT_CHAR
        call DECOMP_EMIT_NEWLINE
        jp DECOMPILE_PROGRAM.loop

; R8.5 Group 5 -- MODE/ULAPLUS/PALETTE. Same generic-1/2-arg-statement
; shape as .op_border/.op_plot above.
.op_mode:
        ld hl,STR_MODE
        ld (DECOMP_TMP_A),hl
        ld a,STR_MODE_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_1ARG_STMT
        jp DECOMPILE_PROGRAM.loop
.op_ulaplus:
        ld hl,STR_ULAPLUS
        ld (DECOMP_TMP_A),hl
        ld a,STR_ULAPLUS_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_1ARG_STMT
        jp DECOMPILE_PROGRAM.loop
.op_palette:
        ld hl,STR_PALETTE
        ld (DECOMP_TMP_A),hl
        ld a,STR_PALETTE_LEN
        ld (DECOMP_TMP_LEN),a
        call DECOMP_EMIT_2ARG_STMT
        jp DECOMPILE_PROGRAM.loop

; R8.5 Group 3 -- the remaining relops, plus AND/OR/NOT. Same shape as
; .op_cmplt/.op_cmpeq above.
.op_cmple:
        call DECOMP_OP_CMPLE
        jp DECOMPILE_PROGRAM.loop
.op_cmpgt:
        call DECOMP_OP_CMPGT
        jp DECOMPILE_PROGRAM.loop
.op_cmpge:
        call DECOMP_OP_CMPGE
        jp DECOMPILE_PROGRAM.loop
.op_cmpne:
        call DECOMP_OP_CMPNE
        jp DECOMPILE_PROGRAM.loop
.op_and:
        call DECOMP_OP_AND
        jp DECOMPILE_PROGRAM.loop
.op_or:
        call DECOMP_OP_OR
        jp DECOMPILE_PROGRAM.loop
.op_not:
        call DECOMP_OP_NOT
        jp DECOMPILE_PROGRAM.loop

; DECOMP_BUILTIN_FN_NAME -- input: A = fn_index. Output: HL = name text
; pointer, C = name length, DECOMP_FN_ARGCOUNT/DECOMP_FN_ARGTYPE = the
; function's own declared argcount/argtype. Destroys: AF, BC, DE, HL.
; Real indexed lookup into DECOMP_BUILTIN_FN_TABLE (5 bytes/row:
; [text_ptr:2][len:1][argcount:1][argtype:1]), same order as rom/
; exrom_v2_compiler.asm's own BUILTIN_FN_TABLE and rom/exrom_v2_vm_
; core.asm's own BUILTIN_FN_JUMP_TABLE. Group 6 appends further rows
; here as functions are added -- no other change needed.
DECOMP_BUILTIN_FN_NAME:
        ld l,a
        ld h,0
        ld d,h
        ld e,l                  ; DE = fn_index
        add hl,hl
        add hl,hl               ; HL = fn_index*4
        add hl,de               ; HL = fn_index*5
        ld de,DECOMP_BUILTIN_FN_TABLE
        add hl,de               ; HL -> this fn_index's own row
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,(hl)
        ld c,a
        inc hl
        ld a,(hl)
        ld (DECOMP_FN_ARGCOUNT),a
        inc hl
        ld a,(hl)
        ld (DECOMP_FN_ARGTYPE),a
        ex de,hl                ; HL = name text pointer
        ret

; DECOMP_STR_OPERAND -- input: HL = a fragment's own text pointer, C =
; its length (as popped from the fragment stack by a string-typed
; consumer below). A string-typed sub-expression's only two possible
; fragment producers are PUSH_STR_LIT (already rendered as a real quoted
; "..." literal above) and PUSH_I16-as-strsym-index (rom/exrom_v2_
; compiler.asm's own COMPILE_STR_FACTOR: a string VARIABLE reference
; compiles to the exact same generic PUSH_I16 opcode a plain numeric
; literal does -- the bytecode itself carries no tag distinguishing
; "this 16-bit value is a strsym index" from "this is just a number";
; OP_STORE_STR_VAR's own header explains why: string values are STRTAB
; indices, pushed as ordinary TAG_INT values, on purpose, not a design
; gap). .op_push_i16 above has therefore already rendered that fragment
; as plain decimal digits (e.g. "2"), which is wrong in THIS context --
; it needs to read as "S2$". Since BASIC expressions are always either
; all-numeric or all-string, never mixed (the same invariant rom/
; exrom_v2_compiler.asm's own COMPILE_IF header relies on), a fragment
; reaching a string-typed consumer that does NOT already start with '"'
; can ONLY be that mis-rendered PUSH_I16 case -- reinterpreted here by
; wrapping the SAME already-rendered digit text as "S<digits>$" rather
; than re-parsing it back into a number, cheaper and just as correct.
; Output: HL = text pointer, C = length (a NEW fragment already pushed
; if reinterpretation was needed; the ORIGINAL fragment, untouched, if
; it was already a real string literal). Destroys: AF, BC, DE, HL.
DECOMP_STR_OPERAND:
        ld a,(hl)
        cp '"'
        ret z                         ; already a real string literal
        cp '('
        ret z                         ; already a combined "(A+B)"-shaped
                                        ; string expression (STR_CONCAT's
                                        ; own real output) -- a real bug
                                        ; found via an actual run: without
                                        ; this check, a concatenation
                                        ; result later popped by STORE_
                                        ; STR_VAR/another STR_CONCAT got
                                        ; wrongly re-wrapped as "S(...)$)"
                                        ; instead of passed through as-is
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_TMP_LEN),a
        call DECOMP_COMBINE_RESET
        ld a,'S'
        call DECOMP_COMBINE_CHAR
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_TMP_LEN)
        call DECOMP_COMBINE_TEXT
        ld a,'$'
        call DECOMP_COMBINE_CHAR
        ld a,(DECOMP_COMBINE_LEN)
        cp DECOMP_FRAG_TEXT_MAX+1
        jp nc,DECOMP_ERR_EXPR_TOO_LONG
        ld c,a
        ld hl,DECOMP_COMBINE_BUF
        call DECOMP_FRAG_PUSH
        call DECOMP_FRAG_POP          ; HL = the new fragment's own text,
                                        ; C = its length -- returned to
                                        ; the caller the same shape a
                                        ; plain FRAG_POP would have
        ret

; STR_CONCAT/STR_CMP_LT/STR_CMP_EQ -- binary string ops, same pop-two-
; combine-one shape as DECOMP_BINARY_OP, but with DECOMP_STR_OPERAND
; applied to EACH popped operand first (both operands of a string-typed
; binary op are themselves string-typed, same "never mixed" invariant).
; "+", "<", "=" match rom/exrom_v2_compiler.asm's own real source
; syntax (COMPILE_STR_EXPR's "+" for concatenation; COMPILE_IF's own
; str_lt/str_eq branches reuse the SAME relational tokens the numeric
; path does).
DECOMP_STR_BINARY_OP:                ; input: HL = operator text, B = length
        ld (DECOMP_OP_PTR),hl
        ld a,b
        ld (DECOMP_OP_LEN),a
        call DECOMP_FRAG_POP         ; HL = B's text, C = B's length
        call DECOMP_STR_OPERAND
        ld (DECOMP_TMP_B),hl
        ld a,c
        ld (DECOMP_BLEN),a
        call DECOMP_FRAG_POP         ; HL = A's text, C = A's length
        call DECOMP_STR_OPERAND
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_TMP_LEN),a
        call DECOMP_COMBINE_RESET
        ld a,'('
        call DECOMP_COMBINE_CHAR
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_TMP_LEN)
        call DECOMP_COMBINE_TEXT
        ld hl,(DECOMP_OP_PTR)
        ld a,(DECOMP_OP_LEN)
        call DECOMP_COMBINE_TEXT
        ld hl,(DECOMP_TMP_B)
        ld a,(DECOMP_BLEN)
        call DECOMP_COMBINE_TEXT
        ld a,')'
        call DECOMP_COMBINE_CHAR
        ld a,(DECOMP_COMBINE_LEN)
        cp DECOMP_FRAG_TEXT_MAX+1
        jp nc,DECOMP_ERR_EXPR_TOO_LONG
        ld c,a
        ld hl,DECOMP_COMBINE_BUF
        call DECOMP_FRAG_PUSH
        ret

; shared 1-argument emit: input HL=keyword text, C=keyword length (via
; DECOMP_TMP_A/DECOMP_TMP_LEN, parked by each caller below -- HL/C
; themselves don't survive the DECOMP_FRAG_POP that happens first).
DECOMP_EMIT_1ARG_STMT:
        call DECOMP_FRAG_POP          ; HL = arg text, C = length
        ld (DECOMP_TMP_B),hl
        ld a,c
        ld (DECOMP_BLEN),a
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_TMP_LEN)
        ld c,a
        call DECOMP_EMIT_TEXT
        ld hl,(DECOMP_TMP_B)
        ld a,(DECOMP_BLEN)
        ld c,a
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE
        ret

; shared 2-argument emit: pops 2 fragments (rightmost-pushed popped
; FIRST, matching VM_POP's own LIFO order), parks each, then emits
; "KEYWORD <second-popped=leftmost>,<first-popped=rightmost>". Input:
; HL=keyword text (parked at DECOMP_TMP_A), C=keyword length (parked at
; DECOMP_TMP_LEN) by each caller below, same convention as the 1-arg
; helper above.
DECOMP_EMIT_2ARG_STMT:
        call DECOMP_FRAG_POP          ; rightmost arg
        ld (DECOMP_ARG_PTR0),hl
        ld a,c
        ld (DECOMP_ARG_LEN0),a
        call DECOMP_FRAG_POP          ; leftmost arg
        ld (DECOMP_ARG_PTR1),hl
        ld a,c
        ld (DECOMP_ARG_LEN1),a
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_TMP_LEN)
        ld c,a
        call DECOMP_EMIT_TEXT
        ld hl,(DECOMP_ARG_PTR1)
        ld a,(DECOMP_ARG_LEN1)
        ld c,a
        call DECOMP_EMIT_TEXT
        ld a,','
        call DECOMP_EMIT_CHAR
        ld hl,(DECOMP_ARG_PTR0)
        ld a,(DECOMP_ARG_LEN0)
        ld c,a
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_NEWLINE
        ret

STR_PROC:      db "PROC "
STR_PROC_LEN:  equ $-STR_PROC
STR_CALL:      db "CALL "
STR_CALL_LEN:  equ $-STR_CALL
STR_ENDP:      db "ENDP"
STR_ENDP_LEN:  equ $-STR_ENDP
STR_CLS:       db "CLS"
STR_CLS_LEN:   equ $-STR_CLS
STR_BORDER:    db "BORDER "
STR_BORDER_LEN: equ $-STR_BORDER
STR_INK:       db "INK "
STR_INK_LEN:   equ $-STR_INK
STR_PAPER:     db "PAPER "
STR_PAPER_LEN: equ $-STR_PAPER
STR_PLOT:      db "PLOT "
STR_PLOT_LEN:  equ $-STR_PLOT
STR_LINE:      db "LINE "
STR_LINE_LEN:  equ $-STR_LINE
STR_LINE_TO:   db " TO "
STR_LINE_TO_LEN: equ $-STR_LINE_TO
STR_BEEP:      db "BEEP "
STR_BEEP_LEN:  equ $-STR_BEEP
STR_SOUND:     db "SOUND "
STR_SOUND_LEN: equ $-STR_SOUND
STR_POKE:      db "POKE "
STR_POKE_LEN:  equ $-STR_POKE
STR_PAUSE:     db "PAUSE "
STR_PAUSE_LEN: equ $-STR_PAUSE
STR_RANDOMISE: db "RANDOMISE "
STR_RANDOMISE_LEN: equ $-STR_RANDOMISE
STR_PRINT:     db "PRINT "
STR_PRINT_LEN: equ $-STR_PRINT
STR_LPRINT:    db "LPRINT "
STR_LPRINT_LEN: equ $-STR_LPRINT
STR_INPUT:     db "INPUT "
STR_INPUT_LEN: equ $-STR_INPUT
STR_MODE:      db "MODE "
STR_MODE_LEN:  equ $-STR_MODE
STR_ULAPLUS:   db "ULAPLUS "
STR_ULAPLUS_LEN: equ $-STR_ULAPLUS
STR_PALETTE:   db "PALETTE "
STR_PALETTE_LEN: equ $-STR_PALETTE
STR_END:       db "END"
STR_END_LEN:   equ $-STR_END
STR_ABS:       db "ABS"
STR_ABS_LEN:   equ $-STR_ABS
STR_SGN:       db "SGN"
STR_SGN_LEN:   equ $-STR_SGN
STR_MOD:       db "MOD"
STR_MOD_LEN:   equ $-STR_MOD
STR_DIV:       db "DIV"
STR_DIV_LEN:   equ $-STR_DIV
STR_RND:       db "RND"
STR_RND_LEN:   equ $-STR_RND
STR_POINT:     db "POINT"
STR_POINT_LEN: equ $-STR_POINT
STR_ATTR:      db "ATTR"
STR_ATTR_LEN:  equ $-STR_ATTR
STR_INT:       db "INT"
STR_INT_LEN:   equ $-STR_INT
STR_PEEK:      db "PEEK"
STR_PEEK_LEN:  equ $-STR_PEEK
STR_USR:       db "USR"
STR_USR_LEN:   equ $-STR_USR
STR_LEN_FN:    db "LEN"
STR_LEN_FN_LEN: equ $-STR_LEN_FN
STR_CODE_FN:   db "CODE"
STR_CODE_FN_LEN: equ $-STR_CODE_FN
STR_VAL_FN:    db "VAL"
STR_VAL_FN_LEN: equ $-STR_VAL_FN

; DECOMP_BUILTIN_FN_TABLE -- [text_ptr:2][len:1][argcount:1] per
; fn_index, same order as rom/exrom_v2_compiler.asm's own
; BUILTIN_FN_TABLE and rom/exrom_v2_vm_core.asm's own
; BUILTIN_FN_JUMP_TABLE (kept in sync by construction, not derived from
; either at build time). argcount is needed here (not just the name)
; because .op_call_fn must know how many fragments to pop and
; re-render in the right order -- see that routine's own header.
; 5 bytes/row: [text_ptr:2][len:1][argcount:1][argtype:1]. argtype: 0 =
; numeric argument(s) (rendered straight from DECOMP_FRAG_POP), 1 =
; string argument (needs DECOMP_STR_OPERAND's own reinterpretation --
; see .op_call_fn's own header for why a bare variable-reference
; fragment needs this).
DECOMP_BUILTIN_FN_TABLE:
        dw STR_ABS
        db STR_ABS_LEN, 1, 0
        dw STR_SGN
        db STR_SGN_LEN, 1, 0
        dw STR_MOD
        db STR_MOD_LEN, 2, 0
        dw STR_DIV
        db STR_DIV_LEN, 2, 0
        dw STR_RND
        db STR_RND_LEN, 1, 0
        dw STR_POINT
        db STR_POINT_LEN, 2, 0
        dw STR_ATTR
        db STR_ATTR_LEN, 2, 0
        dw STR_INT
        db STR_INT_LEN, 1, 0
        dw STR_PEEK
        db STR_PEEK_LEN, 1, 0
        dw STR_USR
        db STR_USR_LEN, 1, 0
        dw STR_LEN_FN
        db STR_LEN_FN_LEN, 1, 1
        dw STR_CODE_FN
        db STR_CODE_FN_LEN, 1, 1
        dw STR_VAL_FN
        db STR_VAL_FN_LEN, 1, 1

STR_GOTO:      db "GOTO "
STR_GOTO_LEN:  equ $-STR_GOTO
STR_IF:        db "IF "
STR_IF_LEN:    equ $-STR_IF
STR_THEN_GOTO: db " THEN GOTO "
STR_THEN_GOTO_LEN: equ $-STR_THEN_GOTO
STR_THEN:      db " THEN"           ; R8.5 Group 3 -- block IF's own
STR_THEN_LEN:  equ $-STR_THEN         ; "IF <cond> THEN" line (no GOTO)
STR_ELSE:      db "ELSE"
STR_ELSE_LEN:  equ $-STR_ELSE
STR_ENDIF:     db "ENDIF"
STR_ENDIF_LEN: equ $-STR_ENDIF
STR_FOR:       db "FOR "
STR_FOR_LEN:   equ $-STR_FOR
STR_TO:        db " TO "
STR_TO_LEN:    equ $-STR_TO
STR_STEP:      db " STEP "
STR_STEP_LEN:  equ $-STR_STEP
STR_NEXT:      db "NEXT "
STR_NEXT_LEN:  equ $-STR_NEXT

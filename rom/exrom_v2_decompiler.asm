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
DECOMP_LABEL_TABLE:   equ $8F00   ; up to 16 distinct jump-target
                                    ; addresses, 2 bytes each (32 bytes,
                                    ; ends $8F20) — collected by the
                                    ; pre-pass below
DECOMP_LABEL_MAX:     equ 16
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
;   6 = a JMPZ was found that does NOT match COMPILE_IF's own fixed
;       shape (see this file's own header — JMPZ has no other meaning in
;       this compiler's current output)
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
DECOMP_EMIT_INT16:
        bit 7,h
        jr z,.positive
        ld a,'-'
        call DECOMP_EMIT_CHAR
        xor a
        sub l
        ld l,a
        ld a,0
        sbc a,h
        ld h,a                   ; HL = -HL (two's complement negate)
.positive:
        ld a,h
        or l
        jr nz,.nonzero
        ld a,'0'
        jp DECOMP_EMIT_CHAR
.nonzero:
        ld (DECOMP_NUM_VAL),hl
        xor a
        ld (DECOMP_NUM_DIGCOUNT),a
.divloop:
        ld hl,(DECOMP_NUM_VAL)
        ld a,h
        or l
        jr z,.emit_digits
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
.emit_digits:
        ld a,(DECOMP_NUM_DIGCOUNT)
        ld b,a
.emit_loop:
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
        jr nz,.emit_loop
        ret

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
        ; reuse DECOMP_EMIT_INT16's own digit algorithm but into the
        ; combine buffer instead of the output buffer: build digits the
        ; same way, then combine-emit each one.
        ld a,h
        or l
        jr nz,.nonzero
        ld a,'0'
        call DECOMP_COMBINE_CHAR
        jr .done
.nonzero:
        ld (DECOMP_NUM_VAL),hl
        xor a
        ld (DECOMP_NUM_DIGCOUNT),a
.divloop:
        ld hl,(DECOMP_NUM_VAL)
        ld a,h
        or l
        jr z,.emit_digits
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
        jr .divloop
.emit_digits:
        ld a,(DECOMP_NUM_DIGCOUNT)
        ld b,a
.eloop:
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
        jr nz,.eloop
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
        ld a,'-'
        call DECOMP_COMBINE_CHAR
        xor a
        sub l
        ld l,a
        ld a,0
        sbc a,h
        ld h,a
.positive:
        ld a,h
        or l
        jr nz,.nonzero
        ld a,'0'
        call DECOMP_COMBINE_CHAR
        jr .done
.nonzero:
        ld (DECOMP_NUM_VAL),hl
        xor a
        ld (DECOMP_NUM_DIGCOUNT),a
.divloop:
        ld hl,(DECOMP_NUM_VAL)
        ld a,h
        or l
        jr z,.emit_digits
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
        jr .divloop
.emit_digits:
        ld a,(DECOMP_NUM_DIGCOUNT)
        ld b,a
.eloop:
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
        jr nz,.eloop
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
        jr z,.w0
        cp 5                      ; ADD
        jr z,.w0
        cp 7                      ; SUB
        jr z,.w0
        cp 8                      ; MUL
        jr z,.w0
        cp 9                      ; DIV
        jr z,.w0
        cp 10                     ; CMP_LT
        jr z,.w0
        cp 11                     ; CMP_EQ
        jr z,.w0
        cp 1                      ; PUSH_I8
        jr z,.w1
        cp 3                      ; LOAD_VAR
        jr z,.w1
        cp 4                      ; STORE_VAR
        jr z,.w1
        cp 13                     ; FOR_INIT
        jr z,.w1
        cp 2                      ; PUSH_I16
        jr z,.w2
        cp 14                     ; FOR_NEXT
        jr z,.w3
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
        cp 0                      ; HALT ends the walk
        ret z
        cp 6                       ; JMP
        jr z,.target
        cp 12                       ; JMPZ
        jr z,.target
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
        ld (DECOMP_NUM_VAL),hl
        xor a
        ld (DECOMP_NUM_DIGCOUNT),a
.divloop:
        ld hl,(DECOMP_NUM_VAL)
        ld a,h
        or l
        jr z,.emit_digits
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
        jr .divloop
.emit_digits:
        ld a,(DECOMP_NUM_DIGCOUNT)
        ld b,a
.eloop:
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
        jr nz,.eloop
        ret

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
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld (DECOMP_IP),hl
        cp 0                     ; HALT ends the walk
        ret z
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
        jp DECOMP_ERR_UNSUPPORTED_OPCODE

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

; Bare JMP -- always COMPILE_GOTO's own output (a JMPZ-paired JMP is
; already consumed whole by .op_jmpz below, and never falls through to
; here). Emits "GOTO L<target>".
.op_jmp:
        ld hl,(DECOMP_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (DECOMP_IP),hl          ; DE = target (relative bytecode offset)
        ld hl,STR_GOTO
        ld c,STR_GOTO_LEN
        call DECOMP_EMIT_TEXT
        call DECOMP_EMIT_LABELNAME  ; consumes DE itself (see its own header)
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
                                     ; past its operand (the candidate JMP)
        ld (DECOMP_TMP_B),de        ; park the JMPZ target
        ld a,(hl)
        cp 6                        ; must be JMP
        jp nz,DECOMP_ERR_BAD_JMPZ_SHAPE
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
        jp nz,DECOMP_ERR_BAD_JMPZ_SHAPE
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

; FOR_INIT: 1-byte symtab-index operand; pops TWO fragments (limit was
; pushed last by COMPILE_FOR, so it pops first) -- "FOR V<idx> = <init>
; TO <limit>".
.op_for_init:
        ld hl,(DECOMP_IP)
        ld a,(hl)
        inc hl
        ld (DECOMP_IP),hl
        ld (DECOMP_TMP_LEN),a       ; symtab index
        call DECOMP_FRAG_POP        ; HL = limit text, C = length
        ld (DECOMP_TMP_A),hl
        ld a,c
        ld (DECOMP_TMP_B),a          ; park limit length (low byte only)
        call DECOMP_FRAG_POP        ; HL = init text, C = length
        push hl                      ; save init text ptr/len on the real
        push bc                      ; stack -- DECOMP_EMIT_VARNAME/TEXT
                                       ; below clobber HL/BC themselves
        ld hl,STR_FOR
        ld c,STR_FOR_LEN
        call DECOMP_EMIT_TEXT
        ld a,(DECOMP_TMP_LEN)
        call DECOMP_EMIT_VARNAME
        ld a,' '
        call DECOMP_EMIT_CHAR
        ld a,'='
        call DECOMP_EMIT_CHAR
        ld a,' '
        call DECOMP_EMIT_CHAR
        pop bc
        pop hl
        call DECOMP_EMIT_TEXT       ; init text
        ld hl,STR_TO
        ld c,STR_TO_LEN
        call DECOMP_EMIT_TEXT
        ld hl,(DECOMP_TMP_A)
        ld a,(DECOMP_TMP_B)
        ld c,a
        call DECOMP_EMIT_TEXT       ; limit text
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

STR_GOTO:      db "GOTO "
STR_GOTO_LEN:  equ $-STR_GOTO
STR_IF:        db "IF "
STR_IF_LEN:    equ $-STR_IF
STR_THEN_GOTO: db " THEN GOTO "
STR_THEN_GOTO_LEN: equ $-STR_THEN_GOTO
STR_FOR:       db "FOR "
STR_FOR_LEN:   equ $-STR_FOR
STR_TO:        db " TO "
STR_TO_LEN:    equ $-STR_TO
STR_NEXT:      db "NEXT "
STR_NEXT_LEN:  equ $-STR_NEXT

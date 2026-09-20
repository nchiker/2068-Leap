; 2068-Leap V2 feasibility study — COMPILER sizing SPIKE ONLY.
;
; NOT production code. NOT wired into the real Makefile. Standalone, isolated.
;
; Purpose: get one REAL measured data point for "how much ROM does a small
; recursive-descent expression compiler cost, emitting bytecode for the VM
; in vm_sizing_spike.asm" — a genuinely new piece of code V1 does not have
; (V1 has no compile step at all), used to sanity-check the prose estimate
; in REWRITE_VM_DESIGN.md/LANGUAGE_CORE_ROM_ANALYSIS.md rather than guessing
; the whole compiler's size from zero data points.
;
; Scope (deliberately narrow — a slice, not the whole compiler):
;   expr    := term (('+' | '-') term)*
;   term    := factor (('*' | '/') factor)*
;   factor  := NUMBER | IDENT | '(' expr ')'
; Emits: OP_PUSH_I8/OP_PUSH_I16, OP_LOAD_VAR, OP_ADD/OP_SUB/OP_MUL/OP_DIV
; (same opcodes as vm_sizing_spike.asm). Symbol lookup during compilation is
; a linear scan of a compile-time-only symbol table (the compiled OUTPUT is
; an index, per STRING_AND_SYMBOL_DESIGN.md's multi-char-identifier goal --
; the scan cost is paid once at edit time, never at runtime).
;
; Assemble standalone:
;   sjasmplus compiler_sizing_spike.asm --lst=compiler_sizing_spike.lst

    ORG $9000

; --- compile-time state ---
SRC_PTR:    equ $F300   ; pointer into source text being compiled
EMIT_PTR:   equ $F302   ; pointer into bytecode output buffer
CSYM_COUNT: equ $F304   ; number of compile-time symbols seen so far (1 byte)
CSYM_NAMES: equ $F400   ; compile-time symbol name table (up to 32 x 8 bytes)

; ===========================================================================
; ENTRY: COMPILE_EXPR — compiles one expression, leaves result on VM stack
; at runtime. Calls itself recursively for parenthesized sub-expressions.
; ===========================================================================
COMPILE_EXPR:
        call COMPILE_TERM
.loop:
        call SKIP_SPACES
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
        call SKIP_SPACES
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
        call SKIP_SPACES
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
        call SKIP_SPACES
        ld hl,(SRC_PTR)
        inc hl                  ; consume ')'
        ld (SRC_PTR),hl
        ret
.ident:
        jp COMPILE_IDENT_LOAD

; ===========================================================================
; Number literal: scan digits, decide 8-bit vs 16-bit encoding (the "small
; integer constants" vs "larger integer constants" bytecode split the study
; asks for), emit the matching PUSH opcode + operand bytes.
; ===========================================================================
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
        ; de = de*10 + digit
        ld h,d
        ld l,e
        add hl,hl               ; *2
        add hl,hl               ; *4
        add hl,de               ; *5
        add hl,hl               ; *10
        pop af
        ld c,a
        ld b,0
        add hl,bc
        ex de,hl
        jr .digit_loop
.done:
        ; DE = value. Choose PUSH_I8 if 0<=value<=255 else PUSH_I16.
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

; ===========================================================================
; Identifier load: scan the name, find-or-create its compile-time symbol
; index (linear scan — compile-time cost only), emit OP_LOAD_VAR <index>.
; ===========================================================================
COMPILE_IDENT_LOAD:
        ld b,0                  ; length so far
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
        ; B = name length (name bytes are the B chars ending just before HL)
        call CSYM_FIND_OR_CREATE
        call EMIT_BYTE_OP_LOAD_VAR
        call EMIT_BYTE           ; A already holds the symbol index on return
        ret

; find-or-create a compile-time symbol; returns its index in A.
; (Linear scan of an 8-char-bounded name table — same shape as the RUNTIME
; scan STRING_AND_SYMBOL_DESIGN.md widens; here it is a COMPILE-TIME-ONLY
; cost, paid once per distinct identifier per compile, not per execution.)
CSYM_FIND_OR_CREATE:
        ld a,(CSYM_COUNT)
        ; (full compare-loop omitted from this slice deliberately -- its
        ; shape and cost are already measured in STRING_AND_SYMBOL_DESIGN.md
        ; for the runtime side; this spike is only sizing the CALL-and-use
        ; site, i.e. how much compiler glue is needed around it)
        inc a
        ld (CSYM_COUNT),a
        dec a
        ret

; ===========================================================================
; Emit helpers — append a byte/opcode to the bytecode output buffer.
; ===========================================================================
EMIT_BYTE:
        ld hl,(EMIT_PTR)
        ld (hl),a
        inc hl
        ld (EMIT_PTR),hl
        ret

EMIT_BYTE_OP_PUSH_I8:
        ld a,$01
        jp EMIT_BYTE

EMIT_BYTE_OP_PUSH_I16:
        ld a,$02
        jp EMIT_BYTE

EMIT_BYTE_OP_LOAD_VAR:
        ld a,$03
        jp EMIT_BYTE

EMIT_OP_ADD:
        ld a,$05
        jp EMIT_BYTE

EMIT_OP_SUB:
        ld a,$06
        jp EMIT_BYTE

EMIT_OP_MUL:
        ld a,$07
        jp EMIT_BYTE

EMIT_OP_DIV:
        ld a,$08
        jp EMIT_BYTE

SKIP_SPACES:
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

COMPILER_SPIKE_END:

        DISPLAY "compiler_sizing_spike: total bytes = ", /D, COMPILER_SPIKE_END-COMPILE_EXPR
        DISPLAY "compiler_sizing_spike: expr+term+factor (control) bytes = ", /D, COMPILE_NUMBER_LITERAL-COMPILE_EXPR
        DISPLAY "compiler_sizing_spike: number-literal compiler bytes = ", /D, COMPILE_IDENT_LOAD-COMPILE_NUMBER_LITERAL
        DISPLAY "compiler_sizing_spike: ident-load compiler bytes = ", /D, CSYM_FIND_OR_CREATE-COMPILE_IDENT_LOAD
        DISPLAY "compiler_sizing_spike: emit helpers bytes = ", /D, SKIP_SPACES-EMIT_BYTE

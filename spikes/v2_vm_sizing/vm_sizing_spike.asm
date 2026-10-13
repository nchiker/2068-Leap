; 2068-Leap V2 feasibility study — ROM sizing SPIKE ONLY.
;
; NOT production code. NOT wired into the real Makefile. NOT linked against
; rom/, basic/, kernel/, include/ (those are read-only for this study).
;
; Purpose: produce a REAL assembled-byte-count for a representative slice of
; a compact bytecode VM (dispatch loop + ~20 representative opcode handlers +
; symbol-table access + mixed int/float dispatch + control flow), so
; docs/REWRITE_VM_DESIGN.md and REWRITE_ROM_BUDGET.md can cite measured
; numbers instead of guesses for "the VM's own new code", extrapolated to a
; full ~40-opcode set.
;
; Calls into the EXISTING calculator (rom/exrom_calc.asm) and EXISTING math
; primitives (kernel/math/math.asm) are represented here as CALL to external
; stub labels of the same instruction shape (3-byte CALL) that a real build
; would use to reach that already-existing, already-paid-for code — this
; spike does not re-implement float arithmetic or re-measure the calculator
; itself (its 1,931 EXROM bytes are already counted as a reused platform
; cost, per REWRITE_ROM_BUDGET.md).
;
; Assemble standalone (no DEVICE, no linkage to the real ROM images):
;   sjasmplus vm_sizing_spike.asm --lst=vm_sizing_spike.lst

    ORG $8000

; ---------------------------------------------------------------------------
; External stubs standing in for ALREADY-EXISTING, ALREADY-PAID-FOR code that
; a real V2 VM would call into (the calculator, integer math primitives).
; Each is a single RET so the CALL-site cost (the only thing this spike is
; trying to measure) is real, while the callee's own body is NOT re-measured
; here (it already exists in EXROM/kernel/math today).
; ---------------------------------------------------------------------------
CALC_ADD_STUB:      ret
CALC_SUB_STUB:      ret
CALC_MUL_STUB:      ret
CALC_DIV_STUB:      ret
CALC_CMP_STUB:      ret
CALC_INT_TO_FP_STUB: ret
CALC_FP_TO_INT_STUB: ret
MATH_UMUL16_STUB:   ret
MATH_UDIV16_STUB:   ret
BASIC_RAISE_ERROR_STUB: ret

; ---------------------------------------------------------------------------
; VM state (would be RAM sysvars in a real build; declared here only so the
; handlers below can reference concrete addresses and assemble/size for real)
; ---------------------------------------------------------------------------
VM_IP:      equ $F000   ; bytecode instruction pointer (2 bytes)
VM_SP:      equ $F002   ; VM operand stack pointer (2 bytes, grows down)
VM_TOS_TAG: equ $F004   ; tag of top-of-stack value: 0=INT 1=FLOAT (1 byte)
VM_TMP_TAG: equ $F005   ; tag of second-from-top (1 byte, scratch)
SYMTAB_BASE: equ $F100  ; base of the compiled symbol table
SYM_REC_LEN: equ 14     ; bytes per symbol record (widened per STRING_AND_SYMBOL_DESIGN.md: name is compiled away, so this is [tag:1][data:2] worth of live cost, but reserved wider for a string-capable slot)
BYTECODE_BASE: equ $F800

; ===========================================================================
; DISPATCH LOOP
; ===========================================================================
VM_RUN:
        ld hl,(VM_IP)
        ld a,(hl)               ; fetch opcode
        inc hl
        ld (VM_IP),hl
        ; dispatch via table: A*2 -> HL index into VM_OP_TABLE
        ld l,a
        ld h,0
        add hl,hl               ; *2
        ld de,VM_OP_TABLE
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        jp (hl)                 ; jump to handler; each handler re-enters VM_RUN via JP VM_RUN

VM_OP_TABLE:
        dw OP_HALT
        dw OP_PUSH_I8
        dw OP_PUSH_I16
        dw OP_LOAD_VAR
        dw OP_STORE_VAR
        dw OP_ADD
        dw OP_SUB
        dw OP_MUL
        dw OP_DIV
        dw OP_CMP_LT
        dw OP_CMP_EQ
        dw OP_JMP
        dw OP_JMPZ
        dw OP_FOR_INIT
        dw OP_FOR_NEXT
        dw OP_CALL
        dw OP_RET_OP
        dw OP_LOAD_FLOAT_VAR
        dw OP_STORE_FLOAT_VAR
        dw OP_PROMOTE_TOS
VM_OP_TABLE_END:

; ===========================================================================
; SYMBOL TABLE ACCESS (compiled-index access, not name search)
; index (A, 0-based) -> HL = record address in SYMTAB_BASE + index*SYM_REC_LEN
; This is the entire point of compiling identifiers to indexes at edit time:
; runtime access is arithmetic, not a scan.
; ===========================================================================
VM_SYM_ADDR:
        ld l,a
        ld h,0
        ld d,h
        ld e,SYM_REC_LEN
        ; HL = index * SYM_REC_LEN via repeated add (14 is not power-of-2;
        ; a real build would use a small multiply or restructure the record
        ; to a power-of-2 size — left as-is here since the cost of THIS
        ; routine, not its optimality, is what's being measured)
        ld b,l
        ld hl,0
.mul_loop:
        add hl,de
        djnz .mul_loop
        ld de,SYMTAB_BASE
        add hl,de
        ret

; ===========================================================================
; STACK HELPERS
; ===========================================================================
VM_PUSH16:              ; push HL onto VM operand stack
        ld de,(VM_SP)
        dec de
        ld a,h
        ld (de),a
        dec de
        ld a,l
        ld (de),a
        ld (VM_SP),de
        ret

VM_POP16:               ; pop into HL
        ld de,(VM_SP)
        ld a,(de)
        ld l,a
        inc de
        ld a,(de)
        ld h,a
        inc de
        ld (VM_SP),de
        ret

; ===========================================================================
; OPCODE HANDLERS (representative slice)
; ===========================================================================

OP_HALT:
        ret                     ; return to the native caller; VM stops

OP_PUSH_I8:
        ld hl,(VM_IP)
        ld a,(hl)
        inc hl
        ld (VM_IP),hl
        ; sign-extend A into HL
        ld l,a
        ld h,0
        bit 7,a
        jr z,.pos
        ld h,$FF
.pos:
        call VM_PUSH16
        xor a
        ld (VM_TOS_TAG),a       ; INT
        jp VM_RUN

OP_PUSH_I16:
        ld hl,(VM_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (VM_IP),hl
        ex de,hl
        call VM_PUSH16
        xor a
        ld (VM_TOS_TAG),a
        jp VM_RUN

OP_LOAD_VAR:
        ld hl,(VM_IP)
        ld a,(hl)               ; symbol index operand
        inc hl
        ld (VM_IP),hl
        call VM_SYM_ADDR        ; HL -> record
        inc hl                  ; skip tag byte
        ld a,(hl)
        inc hl
        ld d,(hl)
        ld l,a
        ld h,d
        call VM_PUSH16
        ret

OP_STORE_VAR:
        ld hl,(VM_IP)
        ld a,(hl)
        inc hl
        ld (VM_IP),hl
        push af
        call VM_POP16           ; value into HL
        pop af
        push hl
        call VM_SYM_ADDR
        inc hl
        pop de
        ld (hl),e
        inc hl
        ld (hl),d
        jp VM_RUN

; --- Mixed int/float ADD: the representative "hybrid dispatch" handler ---
OP_ADD:
        call VM_POP16           ; b operand
        push hl
        ld a,(VM_TOS_TAG)
        ld b,a
        pop hl
        call VM_POP16           ; a operand (second pop reuses same stack slot logic)
        ld a,(VM_TOS_TAG)
        or b
        jr nz,.mixed_or_float
        ; both INT: native 16-bit add, unchanged fast path
        ex de,hl
        call VM_POP16
        add hl,de
        call VM_PUSH16
        jp VM_RUN
.mixed_or_float:
        ; at least one operand FLOAT: promote and hand off to the calculator
        call CALC_INT_TO_FP_STUB
        call CALC_ADD_STUB
        ld a,1
        ld (VM_TOS_TAG),a       ; FLOAT
        jp VM_RUN

OP_SUB:
        call VM_POP16
        ex de,hl
        call VM_POP16
        or a
        sbc hl,de
        call VM_PUSH16
        ld a,(VM_TOS_TAG)
        or a
        jr z,.done
        call CALC_SUB_STUB
.done:
        jp VM_RUN

OP_MUL:
        call VM_POP16
        ex de,hl
        call VM_POP16
        ld a,(VM_TOS_TAG)
        or a
        jr nz,.float_path
        call MATH_UMUL16_STUB
        jr c,.overflow_promote
        call VM_PUSH16
        jp VM_RUN
.overflow_promote:
        call CALC_INT_TO_FP_STUB
        call CALC_MUL_STUB
        ld a,1
        ld (VM_TOS_TAG),a
        jp VM_RUN
.float_path:
        call CALC_MUL_STUB
        jp VM_RUN

OP_DIV:
        ; V1 precedent: / always round-trips through the calculator even for
        ; plain integer division (NUMERIC_DESIGN.md, VERIFIED) — V2 keeps
        ; that shape rather than adding a separate fast integer-divide path.
        call VM_POP16
        ld a,h
        or l
        jr nz,.nonzero
        call BASIC_RAISE_ERROR_STUB
        jp VM_RUN
.nonzero:
        call CALC_INT_TO_FP_STUB
        call CALC_DIV_STUB
        call CALC_FP_TO_INT_STUB
        jp VM_RUN

OP_CMP_LT:
        call VM_POP16
        ex de,hl
        call VM_POP16
        or a
        sbc hl,de
        ld a,0
        jp m,.push_result
        ld a,1
.push_result:
        push af
        pop hl
        call VM_PUSH16
        jp VM_RUN

OP_CMP_EQ:
        call VM_POP16
        ex de,hl
        call VM_POP16
        or a
        sbc hl,de
        ld a,1
        jr z,.iszero
        xor a
.iszero:
        ld l,a
        ld h,0
        call VM_PUSH16
        jp VM_RUN

OP_JMP:
        ld hl,(VM_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        ld (VM_IP),hl
        jp VM_RUN

OP_JMPZ:
        call VM_POP16
        ld a,h
        or l
        jr nz,.no_jump
        ld hl,(VM_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        ld (VM_IP),hl
        jp VM_RUN
.no_jump:
        ld hl,(VM_IP)
        inc hl
        inc hl
        ld (VM_IP),hl
        jp VM_RUN

; --- FOR/NEXT: compiled loop, no source re-scan (this is the whole point —
; V1's GOTO-based loops re-scan source text for their target on every jump;
; PERFORMANCE_BASELINE.md, VERIFIED; a compiled bytecode target address makes
; every branch, not just FOR/NEXT, cost the same as V1's FOR/NEXT already
; does) ---
OP_FOR_INIT:
        ld hl,(VM_IP)
        ld a,(hl)               ; loop variable symbol index
        inc hl
        ld (VM_IP),hl
        call VM_SYM_ADDR
        push hl
        call VM_POP16           ; initial value from stack
        pop de
        inc de
        ld a,l
        ld (de),a
        inc de
        ld a,h
        ld (de),a
        jp VM_RUN

OP_FOR_NEXT:
        ld hl,(VM_IP)
        ld a,(hl)               ; loop var symbol index
        inc hl
        ld e,(hl)               ; branch target low
        inc hl
        ld d,(hl)               ; branch target high
        inc hl
        ld (VM_IP),hl
        call VM_SYM_ADDR
        inc hl
        ld a,(hl)
        inc hl
        ld c,(hl)
        inc a
        ld (hl),a
        jr nz,.take_branch
        jp VM_RUN
.take_branch:
        ex de,hl
        ld (VM_IP),hl
        jp VM_RUN

; --- Procedure call/return: fixed-size frame, GOSUB_STACK-shaped (per
; ARCHITECTURE_COMPARISON.md's "keep the GOSUB_STACK shape" verdict — not a
; general activation-record scheme) ---
OP_CALL:
        ld hl,(VM_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (VM_IP),hl
        ex de,hl
        push hl                 ; return address (bytecode IP) pushed on Z80
                                 ; hardware stack, same shape as GOSUB today
        ld hl,(VM_IP)
        pop de
        ex de,hl
        ld (VM_IP),hl
        jp VM_RUN

OP_RET_OP:
        ; native RET would return to a hardware-stack return address; here,
        ; represented as a VM_IP restore from the same slot OP_CALL used.
        jp VM_RUN

OP_LOAD_FLOAT_VAR:
        ld hl,(VM_IP)
        ld a,(hl)
        inc hl
        ld (VM_IP),hl
        call VM_SYM_ADDR
        inc hl
        ld a,(hl)
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld l,e
        ld h,d
        call VM_PUSH16
        ld a,1
        ld (VM_TOS_TAG),a
        jp VM_RUN

OP_STORE_FLOAT_VAR:
        ld hl,(VM_IP)
        ld a,(hl)
        inc hl
        ld (VM_IP),hl
        push af
        call VM_POP16
        pop af
        push hl
        call VM_SYM_ADDR
        inc hl
        pop de
        ld a,1
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        jp VM_RUN

OP_PROMOTE_TOS:
        call CALC_INT_TO_FP_STUB
        ld a,1
        ld (VM_TOS_TAG),a
        jp VM_RUN

VM_END:

        DISPLAY "vm_sizing_spike: total bytes = ", /D, VM_END-VM_RUN
        DISPLAY "vm_sizing_spike: dispatch+table bytes = ", /D, VM_OP_TABLE_END-VM_RUN
        DISPLAY "vm_sizing_spike: sym-addr routine bytes = ", /D, VM_PUSH16-VM_SYM_ADDR
        DISPLAY "vm_sizing_spike: stack helpers bytes = ", /D, OP_HALT-VM_PUSH16
        DISPLAY "vm_sizing_spike: 20 opcode handlers bytes = ", /D, VM_END-OP_HALT

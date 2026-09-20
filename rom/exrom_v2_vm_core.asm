; ============================================================================
; rom/exrom_v2_vm_core.asm — Architecture B, R1: production VM core
; (integer execution — Milestone 01's original 7 opcodes, extended to the
; full integer-domain opcode set per docs/v2/ARCHITECTURE_B_IMPLEMENTATION_
; PLAN.md's R1 scope: HALT, PUSH_I8, PUSH_I16, LOAD_VAR, STORE_VAR, ADD, SUB,
; MUL, DIV, CMP_LT, CMP_EQ, JMP, JMPZ, FOR_INIT, FOR_NEXT, CALL, RET.)
;
; 2068-Leap V2 rewrite. Milestone 01 (the original 7-opcode slice) is real-
; hardware-validated — see docs/v2/ARCHITECTURE_B_MILESTONE_01.md's RESULTS
; section. This revision extends that validated foundation with the rest of
; R1's integer-domain opcodes, per the plan's own explicit staging: floating
; point (R6), strings (R5), and platform-call trampolines (R7) are
; deliberately NOT added here — R1 is "VM foundation... integer execution,"
; not the full language. Architecture-discipline rule followed: SUB/MUL/DIV
; reuse the existing, already-verified `kernel/math/math.asm` primitives
; (MATH_ADD16 pattern already used inline for ADD; MATH_MULTIPLY16/
; MATH_DIVIDE16/MATH_COMPARE16 now called directly) rather than
; reimplementing integer arithmetic — the same "reuse mature platform
; components" principle Milestone 01 already applied to the operand stack's
; bounds checking.
;
; STATUS: NOT wired into the shipping EXROM build (rom/exrom_build.asm does
; not INCLUDE this file). Exercised only by the standalone smoke ROM
; rom/test_v2_vm_milestone01.asm. Zero effect on the production V1
; interpreter or shipping ROM size.
;
; Design reference: docs/v2/REWRITE_VM_DESIGN.md, docs/v2/
; STATEMENT_COMPILER_SPIKE.md, docs/v2/ARCHITECTURE_B_MILESTONE_01.md,
; docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md (R1).
;
; Opcode numbering (0-16, 17 opcodes total):
;   0  = HALT
;   1  = PUSH_I8    (operand: 1 signed byte, sign-extended)
;   2  = PUSH_I16   (operand: 2 bytes, little-endian)
;   3  = LOAD_VAR   (operand: 1 byte symbol index)
;   4  = STORE_VAR  (operand: 1 byte symbol index)
;   5  = ADD        (pops b, pops a, pushes a+b — native Z80 add)
;   6  = JMP        (operand: 2 bytes, absolute bytecode offset)
;   7  = SUB        (pops b, pops a, pushes a-b — MATH_SUB16 pattern)
;   8  = MUL        (pops b, pops a, pushes a*b — calls MATH_MULTIPLY16)
;   9  = DIV        (pops b, pops a, pushes a/b truncated — calls
;                     MATH_DIVIDE16; divide-by-zero raises a real VM error,
;                     unlike V1's silent 0 — V2_LANGUAGE_SPEC.md's already-
;                     planned fix, and unlike V1's `/`, does NOT round-trip
;                     through the float calculator for the plain-integer
;                     case — a deliberate, documented compatibility break:
;                     V1 pays the calculator's cost unconditionally for every
;                     integer division (NUMERIC_DESIGN.md, VERIFIED); V2's
;                     integer DIV opcode uses the existing fast native
;                     MATH_DIVIDE16 primitive instead, reserving the
;                     calculator for when a value is genuinely FLOAT-tagged,
;                     which this integer-only R1 milestone does not yet
;                     produce)
;   10 = CMP_LT      (pops b, pops a, pushes 1 if a<b else 0 — calls
;                      MATH_COMPARE16)
;   11 = CMP_EQ      (pops b, pops a, pushes 1 if a=b else 0)
;   12 = JMPZ        (operand: 2 bytes; pops cond, branches if zero)
;   13 = FOR_INIT    (operand: 1 byte symbol index; pops limit, pops
;                      initial value; stores initial into the symbol,
;                      remembers the limit — single active loop only in
;                      this R1 slice; general nested-loop frames are R3's
;                      "program execution" scope, not re-litigated here)
;   14 = FOR_NEXT    (operand: 1 byte symbol index + 2 bytes branch target;
;                      increments the symbol by 1 (fixed STEP=1 — general
;                      STEP is also deferred to R3), compares to the
;                      remembered limit via MATH_COMPARE16, branches back if
;                      not yet past it)
;   15 = CALL        (operand: 2 bytes bytecode target; pushes the return
;                      address onto the VM's own bytecode-address call
;                      stack — a small, fixed-depth, bounds-checked stack
;                      distinct from the Z80 hardware stack and from the
;                      operand stack, matching the "GOSUB_STACK-shaped
;                      frame" principle ARCHITECTURE_COMPARISON.md already
;                      recommended keeping)
;   16 = RET         (pops the VM call stack into VM_IP; underflow is a
;                      real, caught error, not undefined behavior)
;
; VM error codes (VM_ERROR_CODE, set on any abnormal halt):
;   0 = no error (normal HALT)
;   1 = illegal opcode
;   2 = operand stack overflow
;   3 = operand stack underflow
;   4 = floating-point path not yet implemented (ADD/SUB/etc. saw a non-INT
;       tag — deferred to R6, per the header note above)
;   5 = divide by zero
;   6 = call stack overflow
;   7 = call stack underflow (RET with no matching CALL)
;
; Operand-stack record layout (3 bytes, at address SP, SP+1, SP+2):
;   [value_lo][value_hi][tag]   -- SP points at the lowest (most recent) record
; ============================================================================

; ---------------------------------------------------------------------------
; VM state. Placed by the including driver (rom/test_v2_vm_milestone01.asm
; for now); a later milestone integrating this into the real EXROM build
; will relocate these into include/sysvars.inc.
; ---------------------------------------------------------------------------
VM_CODE_BASE:       equ $9000   ; base address bytecode JMP offsets are relative to
VM_IP:              equ $8700   ; instruction pointer (2 bytes, absolute address)
VM_SP:              equ $8702   ; operand-stack pointer (2 bytes, grows down)
VM_STACK_TOP:       equ $8780   ; operand stack lives $8704-$877F (initial SP)
VM_STACK_FLOOR:     equ $8704   ; lowest legal SP value (overflow if SP-3 < this)
VM_TOS_TAG:         equ $8782   ; tag of the value last pushed: 0=INT, 1=FLOAT
VM_ERROR_CODE:      equ $8783   ; 0 = no error; see header for nonzero codes
VM_HALTED:          equ $8784   ; nonzero once HALT (or an error-halt) executes
VM_PUSH_VAL_TMP:    equ $8785   ; VM_PUSH scratch (2 bytes)
VM_PUSH_TAG_TMP:    equ $8787   ; VM_PUSH scratch (1 byte)
VM_FOR_LIMIT:       equ $8788   ; FOR_INIT/FOR_NEXT: remembered loop limit (2
                                ; bytes) — single active loop, R1 scope only
VM_FOR_NEXT_BRANCH: equ $878A  ; OP_FOR_NEXT scratch: branch target operand (2B)
VM_FOR_NEXT_VALADDR: equ $878C ; OP_FOR_NEXT scratch: loop var's value_lo addr (2B)
VM_FOR_NEXT_NEWVAL: equ $878E  ; OP_FOR_NEXT scratch: incremented value (2B)
VM_CALL_PUSH_TMP:   equ $8790  ; VM_CALL_PUSH scratch (2 bytes)
VM_CALL_SP:         equ $8792  ; VM call-stack pointer (2 bytes, grows down)
VM_CALL_STACK_TOP:  equ $87A0  ; call stack lives $8794-$879F (6 return
                                ; addresses deep — R1's own fixed, bounds-
                                ; checked depth, not the Z80 hardware stack)
VM_CALL_STACK_FLOOR: equ $8794

SYMTAB_BASE:        equ $8800   ; symbol records: [tag:1][value_lo:1][value_hi:1]
SYM_REC_LEN:        equ 3       ; 3 bytes/record (tag + 2-byte value; no name
                                ; field at runtime at all — REWRITE_RAM_BUDGET.md's
                                ; compiled-index design)

TAG_INT:            equ 0
TAG_FLOAT:          equ 1

; ---------------------------------------------------------------------------
; VM_INIT — call once before VM_RUN. Resets both stacks, error/halt flags.
; ---------------------------------------------------------------------------
VM_INIT:
        ld hl,VM_STACK_TOP
        ld (VM_SP),hl
        ld hl,VM_CALL_STACK_TOP
        ld (VM_CALL_SP),hl
        xor a
        ld (VM_ERROR_CODE),a
        ld (VM_HALTED),a
        ld (VM_TOS_TAG),a
        ret

; ---------------------------------------------------------------------------
; VM_RUN — dispatch loop. Entry: VM_IP already set by the caller. Returns
; when VM_HALTED becomes nonzero (normal HALT or any error-halt).
; ---------------------------------------------------------------------------
VM_RUN:
.loop:
        ld a,(VM_HALTED)
        or a
        ret nz
        ld hl,(VM_IP)
        ld a,(hl)               ; fetch opcode
        inc hl
        ld (VM_IP),hl
        cp 17                   ; 17 opcodes defined (0-16)
        jp nc,VM_ERR_ILLEGAL_OPCODE
        ld l,a
        ld h,0
        add hl,hl               ; *2 (word-sized table entries)
        ld de,VM_OP_TABLE
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        jp (hl)                 ; jump to handler; every handler falls through
                                 ; to VM_RUN.loop or to a VM_ERR_* exit

VM_OP_TABLE:
        dw OP_HALT
        dw OP_PUSH_I8
        dw OP_PUSH_I16
        dw OP_LOAD_VAR
        dw OP_STORE_VAR
        dw OP_ADD
        dw OP_JMP
        dw OP_SUB
        dw OP_MUL
        dw OP_DIV
        dw OP_CMP_LT
        dw OP_CMP_EQ
        dw OP_JMPZ
        dw OP_FOR_INIT
        dw OP_FOR_NEXT
        dw OP_CALL
        dw OP_RET

; ---------------------------------------------------------------------------
; Symbol access: index (A) -> HL = record address (SYMTAB_BASE + index*3).
; ---------------------------------------------------------------------------
VM_SYM_ADDR:
        ld l,a
        ld h,0                  ; HL = index
        ld d,h
        ld e,l                  ; DE = index (copy)
        add hl,hl                ; HL = index*2
        add hl,de                ; HL = index*3
        ld de,SYMTAB_BASE
        add hl,de
        ret

; ---------------------------------------------------------------------------
; Operand stack, WITH real bounds checking.
; ---------------------------------------------------------------------------
VM_PUSH:                       ; input: HL = value, A = tag
        ld (VM_PUSH_VAL_TMP),hl
        ld (VM_PUSH_TAG_TMP),a
        ld hl,(VM_SP)
        ld de,-3
        add hl,de               ; HL = would-be new SP
        ld de,VM_STACK_FLOOR
        or a
        sbc hl,de
        jp c,VM_ERR_STACK_OVERFLOW   ; new SP < floor
        ld hl,(VM_SP)
        ld de,-3
        add hl,de
        ld (VM_SP),hl           ; commit the new SP
        ld de,(VM_PUSH_VAL_TMP)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld a,(VM_PUSH_TAG_TMP)
        ld (hl),a
        ld (VM_TOS_TAG),a
        ret

VM_POP:                        ; output: HL = value, A = tag
        ld hl,(VM_SP)
        ld de,VM_STACK_TOP
        or a
        sbc hl,de               ; HL = SP - TOP; zero means the stack is empty
        jp z,VM_ERR_STACK_UNDERFLOW
        ld hl,(VM_SP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld a,(hl)
        inc hl
        ld (VM_SP),hl
        ex de,hl                ; HL = value; A still holds the tag
        ret

; ---------------------------------------------------------------------------
; VM call stack (bytecode return addresses only — separate from both the
; operand stack above and the Z80 hardware stack).
; ---------------------------------------------------------------------------
VM_CALL_PUSH:                  ; input: HL = bytecode return address
        ld (VM_CALL_PUSH_TMP),hl
        ld hl,(VM_CALL_SP)
        ld de,-2
        add hl,de               ; HL = would-be new call SP
        ld de,VM_CALL_STACK_FLOOR
        or a
        sbc hl,de
        jp c,VM_ERR_CALL_STACK_OVERFLOW
        ld hl,(VM_CALL_SP)
        ld de,-2
        add hl,de
        ld (VM_CALL_SP),hl      ; commit the new call SP
        ld de,(VM_CALL_PUSH_TMP)
        ld (hl),e
        inc hl
        ld (hl),d
        ret

VM_CALL_POP:                   ; output: HL = bytecode return address
        ld hl,(VM_CALL_SP)
        ld de,VM_CALL_STACK_TOP
        or a
        sbc hl,de
        jp z,VM_ERR_CALL_STACK_UNDERFLOW
        ld hl,(VM_CALL_SP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (VM_CALL_SP),hl
        ex de,hl
        ret

; ---------------------------------------------------------------------------
; Opcode handlers
; ---------------------------------------------------------------------------
OP_HALT:
        ld a,1
        ld (VM_HALTED),a
        ret                     ; VM_RUN.loop will see VM_HALTED set and return

OP_PUSH_I8:
        ld hl,(VM_IP)
        ld a,(hl)
        inc hl
        ld (VM_IP),hl
        ld l,a
        ld h,0
        bit 7,a
        jr z,.positive
        ld h,$FF                ; sign-extend
.positive:
        ld a,TAG_INT
        call VM_PUSH
        jp VM_RUN.loop

OP_PUSH_I16:
        ld hl,(VM_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (VM_IP),hl
        ex de,hl
        ld a,TAG_INT
        call VM_PUSH
        jp VM_RUN.loop

OP_LOAD_VAR:
        ld hl,(VM_IP)
        ld a,(hl)
        inc hl
        ld (VM_IP),hl
        call VM_SYM_ADDR        ; HL -> record [tag][value_lo][value_hi]
        ld a,(hl)               ; tag
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl                ; HL = value; A still holds the tag
        call VM_PUSH
        jp VM_RUN.loop

OP_STORE_VAR:
        ld hl,(VM_IP)
        ld a,(hl)               ; symbol index operand
        inc hl
        ld (VM_IP),hl
        ld c,a                  ; save index
        call VM_POP             ; HL = value, A = tag (this opcode set is
                                 ; still integer-only end to end, so the tag
                                 ; is not separately re-validated here — R6
                                 ; must revisit this when FLOAT-producing
                                 ; opcodes exist)
        push hl                 ; save value
        ld a,c
        call VM_SYM_ADDR        ; HL -> record
        pop de                  ; DE = value
        ld a,TAG_INT
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        jp VM_RUN.loop

OP_ADD:
        call VM_POP             ; HL = b, A = tag_b
        ld c,a
        push hl
        call VM_POP             ; HL = a, A = tag_a
        or c
        jp nz,VM_ERR_FLOAT_NOT_IMPLEMENTED   ; either operand non-INT
        pop de                  ; DE = b
        add hl,de               ; HL = a+b — native 16-bit Z80 add, the
                                 ; integer fast path this whole architecture
                                 ; exists to preserve.
        ld a,TAG_INT
        call VM_PUSH
        jp VM_RUN.loop

OP_JMP:
        ld hl,(VM_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,VM_CODE_BASE
        add hl,de
        ld (VM_IP),hl           ; O(1) compiled branch — see Milestone 01's
                                 ; real hardware measurement for the direct
                                 ; confirmation of this claim.
        jp VM_RUN.loop

OP_SUB:
        call VM_POP             ; HL = b, A = tag_b
        ld c,a
        push hl
        call VM_POP             ; HL = a, A = tag_a
        or c
        jp nz,VM_ERR_FLOAT_NOT_IMPLEMENTED
        pop de                  ; DE = b (HL is still a, from the second
                                 ; VM_POP above — no register shuffle needed)
        or a
        sbc hl,de               ; HL = a - b
        ld a,TAG_INT
        call VM_PUSH
        jp VM_RUN.loop

OP_MUL:
        call VM_POP             ; HL = b, A = tag_b
        ld c,a
        push hl
        call VM_POP             ; HL = a, A = tag_a
        or c
        jp nz,VM_ERR_FLOAT_NOT_IMPLEMENTED
        pop de                  ; DE = b
        call MATH_MULTIPLY16    ; existing, already-verified platform
                                 ; primitive (kernel/math/math.asm) — reused,
                                 ; not reimplemented. Overflow silently
                                 ; truncates here, same as the primitive's
                                 ; own documented behavior; auto-promotion
                                 ; on overflow is R6 scope (NUMERIC_DESIGN.md)
        ld a,TAG_INT
        call VM_PUSH
        jp VM_RUN.loop

OP_DIV:
        call VM_POP             ; HL = b, A = tag_b
        ld c,a
        push hl
        call VM_POP             ; HL = a, A = tag_a
        or c
        jp nz,VM_ERR_FLOAT_NOT_IMPLEMENTED
        pop de                  ; DE = b (the divisor)
        ld a,d
        or e
        jp z,VM_ERR_DIVIDE_BY_ZERO   ; real, caught error — a deliberate
                                      ; improvement over V1's silent 0
                                      ; (V2_LANGUAGE_SPEC.md's already-
                                      ; planned fix), reached here via a
                                      ; genuinely faster path than V1's own
                                      ; `/` (see this file's header note)
        call MATH_DIVIDE16      ; existing, already-verified platform
                                 ; primitive — truncates toward zero
        ld a,TAG_INT
        call VM_PUSH
        jp VM_RUN.loop

OP_CMP_LT:
        call VM_POP             ; HL = b, A = tag_b
        ld c,a
        push hl
        call VM_POP             ; HL = a, A = tag_a
        or c
        jp nz,VM_ERR_FLOAT_NOT_IMPLEMENTED
        pop de                  ; DE = b
        call MATH_COMPARE16     ; A = 0 if a=b, 1 if a>b, $FF if a<b
        ld hl,0
        cp $FF
        jr nz,.not_less
        inc l                   ; HL = 1 (true)
.not_less:
        ld a,TAG_INT
        call VM_PUSH
        jp VM_RUN.loop

OP_CMP_EQ:
        call VM_POP             ; HL = b, A = tag_b
        ld c,a
        push hl
        call VM_POP             ; HL = a, A = tag_a
        or c
        jp nz,VM_ERR_FLOAT_NOT_IMPLEMENTED
        pop de                  ; DE = b
        call MATH_COMPARE16     ; A = 0 if a=b
        ld hl,0
        or a
        jr nz,.not_equal
        inc l                   ; HL = 1 (true)
.not_equal:
        ld a,TAG_INT
        call VM_PUSH
        jp VM_RUN.loop

OP_JMPZ:
        call VM_POP             ; HL = condition value, A = tag (not
                                 ; re-checked here; a boolean from CMP_*
                                 ; or any int value is a legal condition,
                                 ; same "any nonzero is true" rule V1 uses)
        ld a,h
        or l
        jr nz,.no_branch
        ld hl,(VM_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld hl,VM_CODE_BASE
        add hl,de
        ld (VM_IP),hl
        jp VM_RUN.loop
.no_branch:
        ld hl,(VM_IP)
        inc hl
        inc hl                  ; skip the 2-byte operand we didn't use
        ld (VM_IP),hl
        jp VM_RUN.loop

OP_FOR_INIT:
        ld hl,(VM_IP)
        ld a,(hl)               ; loop variable symbol index
        inc hl
        ld (VM_IP),hl
        ld c,a
        call VM_POP             ; HL = limit
        ld (VM_FOR_LIMIT),hl
        call VM_POP             ; HL = initial value
        push hl
        ld a,c
        call VM_SYM_ADDR
        pop de
        ld a,TAG_INT
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        jp VM_RUN.loop

OP_FOR_NEXT:
        ld hl,(VM_IP)
        ld a,(hl)               ; loop variable symbol index
        inc hl
        ld e,(hl)               ; branch target low
        inc hl
        ld d,(hl)               ; branch target high
        inc hl
        ld (VM_IP),hl
        ld (VM_FOR_NEXT_BRANCH),de
        call VM_SYM_ADDR        ; HL -> record (A = symbol index, consumed)
        inc hl                  ; -> value_lo (record+1)
        ld (VM_FOR_NEXT_VALADDR),hl
        ld e,(hl)
        inc hl
        ld d,(hl)               ; DE = current value
        inc de                  ; DE = new current value (fixed STEP=1)
        ld (VM_FOR_NEXT_NEWVAL),de
        ex de,hl                ; HL = new current value
        ld de,(VM_FOR_LIMIT)
        call MATH_COMPARE16     ; A = 0 if equal, 1 if HL(new)>DE(limit),
                                 ; $FF if HL(new)<DE(limit); destroys HL
        ld hl,(VM_FOR_NEXT_VALADDR)
        ld de,(VM_FOR_NEXT_NEWVAL)
        ld (hl),e
        inc hl
        ld (hl),d               ; write the incremented value back
        cp 1
        jp z,.past_limit        ; new value > limit: loop ends
        ld de,(VM_FOR_NEXT_BRANCH)
        ld hl,VM_CODE_BASE
        add hl,de
        ld (VM_IP),hl
        jp VM_RUN.loop
.past_limit:
        jp VM_RUN.loop

OP_CALL:
        ld hl,(VM_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (VM_IP),hl           ; temporarily: VM_IP = return address
                                 ; (just past the CALL's operand)
        push hl                 ; save the return address across the
                                 ; upcoming VM_CALL_PUSH call, which uses
                                 ; DE as scratch and would otherwise clobber
                                 ; a target held there (a real bug this
                                 ; milestone's first version had — caught by
                                 ; a real ZEsarUX run: VM_IP silently stayed
                                 ; at the return address instead of jumping
                                 ; into the callee, so ARG never got
                                 ; doubled; fixed by setting VM_IP directly
                                 ; from a register never passed through the
                                 ; VM_CALL_PUSH call at all)
        ld hl,VM_CODE_BASE
        add hl,de               ; HL = call target (absolute)
        ld (VM_IP),hl           ; VM_IP = target — set directly, before
                                 ; VM_CALL_PUSH runs, so nothing it clobbers
                                 ; can undo this
        pop hl                  ; HL = return address
        call VM_CALL_PUSH
        jp VM_RUN.loop

OP_RET:
        call VM_CALL_POP        ; HL = return address
        ld (VM_IP),hl
        jp VM_RUN.loop

; ---------------------------------------------------------------------------
; Error exits — each sets VM_ERROR_CODE and VM_HALTED, then returns to the
; caller (the driver), which inspects both.
; ---------------------------------------------------------------------------
VM_ERR_ILLEGAL_OPCODE:
        ld a,1
        jp VM_ERR_COMMON

VM_ERR_STACK_OVERFLOW:
        ld a,2
        jp VM_ERR_COMMON

VM_ERR_STACK_UNDERFLOW:
        ld a,3
        jp VM_ERR_COMMON

VM_ERR_FLOAT_NOT_IMPLEMENTED:
        ld a,4
        jp VM_ERR_COMMON

VM_ERR_DIVIDE_BY_ZERO:
        ld a,5
        jp VM_ERR_COMMON

VM_ERR_CALL_STACK_OVERFLOW:
        ld a,6
        jp VM_ERR_COMMON

VM_ERR_CALL_STACK_UNDERFLOW:
        ld a,7
        jp VM_ERR_COMMON

VM_ERR_COMMON:
        ld (VM_ERROR_CODE),a
        ld a,1
        ld (VM_HALTED),a
        ret

VM_CORE_END:

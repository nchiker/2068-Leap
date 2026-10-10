; ============================================================================
; tools/spikes/control_stack_spike.asm -- R10.7 P4 SPIKE (non-production).
;
; The unified, typed, memory-limited BASIC control stack that replaces the three
; fixed stacks (FOR 4 B x 15, CALL 2 B x 12, PARAM-save 8 B x 12):
;
;   one stack growing DOWN from CS_TOP; the array arena grows UP from CS_FLOOR
;   (ARRAYS_END in the VM); every push checks the two against each other, so
;   depth is limited only by free memory. Frames carry a one-byte type at the
;   lowest address:
;
;     FOR   [T_FOR  ][limit:2][step:2]               5 B  (the ENCLOSING loop's)
;     CALL  [T_CALL ][return address:2]              3 B
;     PARAM [T_PARAM][tag:1][value:2][float:5]       9 B  (the parameter's old value)
;
; Pops are type-checked. RET and PARAM_UNBIND first DISCARD any FOR frames above
; their own frame: a FOR loop left by GOTO never gets its FOR_POP, and on three
; separate stacks that leak was harmless; on one stack it would be mistaken for a
; CALL/PARAM frame, so the unwind heals it (and frees the leak at procedure exit).
; FOR_POP requires a FOR frame on top (a mismatch is an error, never silent).
;
; This spike exercises: nested FOR, EXIT FOR (lands on FOR_POP), recursion, early
; exits (leaked FOR frames), DEF FN / PROC parameter restoration, exhaustion in
; both directions, and mismatched pops.
;
; Build: tools/sjasmplus_strict.sh tools/spikes/control_stack_spike.asm
; Run  : tools/spikes/run_spike.sh build/spikes/control_stack_spike.bin 0x8020
; ============================================================================
    DEVICE NOSLOT64K

CSP         EQU $8000   ; 2  stack pointer (lowest used byte)
CS_TOP      EQU $8002   ; 2  empty-stack value
CS_FLOOR    EQU $8004   ; 2  arena top (the stack may not go below it)
FOR_LIMIT   EQU $8006   ; 2  current loop
FOR_STEP    EQU $8008   ; 2
SYMREC      EQU $8010   ; 3  a "parameter symbol" record
FLOATREC    EQU $8013   ; 5  its float slot
RESULT      EQU $8020   ; last test number started
DEPTH       EQU $8022   ; 2

T_FOR   EQU 1
T_CALL  EQU 2
T_PARAM EQU 3

    ORG 0
    di
    ld   sp,$FF00
    jp   TESTS

; ============================ SPIKE CORE (measured) ==========================
CORE_BEGIN:
; CS_ALLOC -- A = frame size. Out: carry clear, HL = new frame (CSP updated);
; carry set = no room (nothing changed).
CS_ALLOC:
    ld   e,a
    ld   d,0
    ld   hl,(CSP)
    or   a
    sbc  hl,de
    ret  c
    ex   de,hl              ; DE = new CSP
    ld   hl,(CS_FLOOR)
    or   a
    sbc  hl,de              ; floor - new
    jr   z,.ok
    jr   nc,.fail           ; floor > new: the stack would run into the arena
.ok:
    ld   (CSP),de
    ex   de,hl              ; HL = new frame
    or   a
    ret
.fail:
    scf
    ret

; CS_PUSH_FOR -- saves the enclosing loop's limit/step (OP_FOR_INIT)
CS_PUSH_FOR:
    ld   a,5
    call CS_ALLOC
    ret  c
    ld   (hl),T_FOR
    inc  hl
    ld   de,(FOR_LIMIT)
    ld   (hl),e
    inc  hl
    ld   (hl),d
    inc  hl
    ld   de,(FOR_STEP)
    ld   (hl),e
    inc  hl
    ld   (hl),d
    or   a
    ret

; CS_POP_FOR -- restores the enclosing loop (OP_FOR_POP). Carry = top is not FOR.
CS_POP_FOR:
    ld   hl,(CSP)
    ld   a,(hl)
    cp   T_FOR
    jr   nz,CS_BAD
    inc  hl
    ld   e,(hl)
    inc  hl
    ld   d,(hl)
    ld   (FOR_LIMIT),de
    inc  hl
    ld   e,(hl)
    inc  hl
    ld   d,(hl)
    ld   (FOR_STEP),de
    inc  hl
    ld   (CSP),hl
    or   a
    ret
CS_BAD:
    scf
    ret

; CS_PUSH_CALL -- HL = return address (OP_CALL / CALL_UDF)
CS_PUSH_CALL:
    push hl
    ld   a,3
    call CS_ALLOC
    jr   c,.fail
    ld   (hl),T_CALL
    inc  hl
    pop  de
    ld   (hl),e
    inc  hl
    ld   (hl),d
    or   a
    ret
.fail:
    pop  hl
    ret

; CS_UNWIND -- skip over FOR frames; out: HL = first non-FOR frame, A = its type,
; carry set if the stack is empty. Read-only: the caller's pop discards what was
; skipped.
CS_UNWIND:
    ld   hl,(CSP)
.next:
    ld   de,(CS_TOP)
    or   a
    sbc  hl,de
    jr   z,.empty
    add  hl,de
    ld   a,(hl)
    cp   T_FOR
    ret  nz                 ; carry clear
    ld   de,5
    add  hl,de              ; (CSP is NOT written here: the owner frame's pop sets
    jr   .next              ; CSP past it, which discards the leaked FOR frames too,
                            ; and an error leaves the stack untouched)
.empty:
    scf
    ret

; CS_RET -- OP_RET: pops a CALL frame, healing leaked FOR frames. HL = return
; address. Carry = no CALL frame on top (error).
CS_RET:
    call CS_UNWIND
    ret  c
    cp   T_CALL
    jr   nz,CS_BAD
    inc  hl
    ld   e,(hl)
    inc  hl
    ld   d,(hl)
    inc  hl
    ld   (CSP),hl
    ex   de,hl
    or   a
    ret

; CS_PUSH_PARAM -- OP_PARAM_BIND: HL = symbol record (3 B), DE = float slot (5 B)
CS_PUSH_PARAM:
    push hl
    push de
    ld   a,9
    call CS_ALLOC
    jr   c,.fail
    ld   (hl),T_PARAM
    inc  hl
    ex   de,hl              ; DE = frame+1
    pop  hl                 ; float slot
    ex   (sp),hl            ; HL = symbol, (SP) = float slot
    ld   bc,3
    ldir
    pop  hl                 ; float slot
    ld   bc,5
    ldir
    or   a
    ret
.fail:
    pop  de
    pop  hl
    ret

; CS_POP_PARAM -- OP_PARAM_UNBIND: HL = symbol record, DE = float slot to restore
CS_POP_PARAM:
    push hl
    push de
    call CS_UNWIND
    jr   c,.bad
    cp   T_PARAM
    jr   nz,.bad
    inc  hl                 ; -> saved record
    pop  de                 ; float slot (destination for the last 5)
    ex   (sp),hl            ; HL = symbol (dest), (SP) = saved record
    ex   de,hl              ; DE = symbol, HL = float slot
    ex   (sp),hl            ; HL = saved record, (SP) = float slot
    ld   bc,3
    ldir                    ; restore the symbol record
    pop  de                 ; float slot
    ld   bc,5
    ldir                    ; restore the float slot
    ld   (CSP),hl           ; HL is just past the frame
    or   a
    ret
.bad:
    pop  de
    pop  hl
    scf
    ret
CORE_END:

; =============================== TEST SUPPORT ================================
STACK_TOP   EQU $A000
ARENA_BASE  EQU $9000   ; the "arena" (arrays) grows up from here toward the stack

T   MACRO n
    ld   a,n
    ld   (RESULT),a
    ENDM

INIT:
    ld   hl,STACK_TOP
    ld   (CSP),hl
    ld   (CS_TOP),hl
    ld   hl,ARENA_BASE
    ld   (CS_FLOOR),hl
    ld   hl,0
    ld   (FOR_LIMIT),hl
    ld   (FOR_STEP),hl
    ret

; EMPTY? -- Z if CSP == CS_TOP
EMPTY:
    ld   hl,(CSP)
    ld   de,(CS_TOP)
    or   a
    sbc  hl,de
    ret

TESTS:
    ; ---- 1: 12 nested FOR loops, each saves the enclosing limit/step; popped LIFO
    T 1
    call INIT
    ld   b,12
    ld   c,1
.f1:
    push bc
    ld   a,c
    ld   l,a
    ld   h,0
    ld   (FOR_LIMIT),hl      ; loop c: limit=c, step=100+c
    ld   a,100
    add  a,c
    ld   l,a
    ld   (FOR_STEP),hl
    ; (OP_FOR_INIT pushes the ENCLOSING loop's values first; emulate: push, then
    ;  overwrite with the new loop's)
    pop  bc
    push bc
    call CS_PUSH_FOR
    jp   c,FAIL
    pop  bc
    ld   a,c
    inc  a
    ld   l,a
    ld   h,0
    ld   (FOR_LIMIT),hl
    ld   a,201
    add  a,c
    ld   l,a
    ld   (FOR_STEP),hl
    inc  c
    djnz .f1
    ld   b,12
.p1:
    push bc
    call CS_POP_FOR
    jp   c,FAIL
    pop  bc
    djnz .p1
    call EMPTY
    jp   nz,FAIL
    ; after popping all 12 the loop state is the one pushed FIRST: limit=1, step=101
    ld   hl,(FOR_LIMIT)
    ld   de,1
    or   a
    sbc  hl,de
    jp   nz,FAIL
    ld   hl,(FOR_STEP)
    ld   de,101
    or   a
    sbc  hl,de
    jp   nz,FAIL

    ; ---- 2: recursion with a parameter: CALL + PARAM frames until memory runs out
    T 2
    call INIT
    ld   hl,0
    ld   (DEPTH),hl
.r2:
    ld   hl,(DEPTH)
    ld   (SYMREC+1),hl       ; the parameter's current value = the depth
    ld   hl,$1234
    call CS_PUSH_CALL
    jr   c,.r2done
    ld   hl,SYMREC
    ld   de,FLOATREC
    call CS_PUSH_PARAM
    jr   c,.r2done_after_call
    ld   hl,(DEPTH)
    inc  hl
    ld   (DEPTH),hl
    jr   .r2
.r2done_after_call:
    ; the CALL frame was pushed but its PARAM did not fit: pop the CALL frame
    call CS_RET
    jp   c,FAIL
.r2done:
    ; (STACK_TOP-ARENA_BASE)/12 frames pairs fit exactly: 0x1000/12 = 341
    ld   hl,(DEPTH)
    ld   de,341
    or   a
    sbc  hl,de
    jp   nz,FAIL
    ; a failed push changed nothing: CSP is still a whole number of frames
    ld   hl,STACK_TOP
    ld   de,(CSP)
    or   a
    sbc  hl,de
    ld   de,341*12
    or   a
    sbc  hl,de
    jp   nz,FAIL
    ; unwind everything: values come back in reverse order
    ld   hl,341
    ld   (DEPTH),hl
.u2:
    ld   hl,(DEPTH)
    ld   a,h
    or   l
    jr   z,.u2done
    dec  hl
    ld   (DEPTH),hl
    ld   hl,SYMREC
    ld   de,FLOATREC
    call CS_POP_PARAM
    jp   c,FAIL
    ld   hl,(SYMREC+1)       ; the symbol must have its depth value back
    ld   de,(DEPTH)
    or   a
    sbc  hl,de
    jp   nz,FAIL
    call CS_RET
    jp   c,FAIL
    ld   de,$1234
    or   a
    sbc  hl,de
    jp   nz,FAIL
    jr   .u2
.u2done:
    call EMPTY
    jp   nz,FAIL

    ; ---- 3: leaked FOR frames (loops left by GOTO) are discarded by UNBIND and RET
    T 3
    call INIT
    ld   hl,$4321
    call CS_PUSH_CALL
    jp   c,FAIL
    ld   hl,77
    ld   (SYMREC+1),hl
    ld   hl,SYMREC
    ld   de,FLOATREC
    call CS_PUSH_PARAM
    jp   c,FAIL
    call CS_PUSH_FOR         ; two loops inside the procedure, both left by GOTO
    jp   c,FAIL
    call CS_PUSH_FOR
    jp   c,FAIL
    ld   hl,99
    ld   (SYMREC+1),hl       ; the body changed the parameter
    ld   hl,SYMREC
    ld   de,FLOATREC
    call CS_POP_PARAM
    jp   c,FAIL
    ld   hl,(SYMREC+1)
    ld   de,77
    or   a
    sbc  hl,de
    jp   nz,FAIL
    call CS_PUSH_FOR         ; another leaked loop between UNBIND and RET
    jp   c,FAIL
    call CS_RET
    jp   c,FAIL
    ld   de,$4321
    or   a
    sbc  hl,de
    jp   nz,FAIL
    call EMPTY
    jp   nz,FAIL

    ; ---- 4: mismatched pops are errors, never silent
    T 4
    call INIT
    ld   hl,$1111
    call CS_PUSH_CALL
    call CS_POP_FOR          ; top is CALL -> error
    jp   nc,FAIL
    ld   hl,SYMREC
    ld   de,FLOATREC
    call CS_POP_PARAM        ; top is CALL, not PARAM -> error
    jp   nc,FAIL
    call CS_RET              ; but RET itself is fine
    jp   c,FAIL
    call CS_RET              ; empty -> error
    jp   nc,FAIL
    call CS_POP_FOR          ; empty: the "top" is past CS_TOP: must not succeed
    ; (CS_POP_FOR on an empty stack reads memory above the stack: the VM never
    ;  executes FOR_POP without a matching FOR_INIT, the compiler guarantees it.)

    ; ---- 5: exhaustion from the other side: arrays eat the room, pushes fail
    T 5
    call INIT
    ld   hl,STACK_TOP-20     ; arena top almost touches the stack top
    ld   (CS_FLOOR),hl
    call CS_PUSH_FOR         ; 5 B: fits
    jp   c,FAIL
    call CS_PUSH_FOR         ; 10
    jp   c,FAIL
    call CS_PUSH_FOR         ; 15
    jp   c,FAIL
    call CS_PUSH_FOR         ; 20 == exactly full
    jp   c,FAIL
    call CS_PUSH_FOR         ; 25 > 20: refused
    jp   nc,FAIL
    ld   hl,STACK_TOP-20
    ld   de,(CSP)
    or   a
    sbc  hl,de
    jp   nz,FAIL             ; unchanged by the failed push
    ld   hl,STACK_TOP        ; the arena can't grow past the stack either: the
    ld   de,(CSP)            ; VM checks ARRAYS_END against CSP (modelled by the
    or   a                   ; same compare)
    sbc  hl,de
    ld   de,20
    or   a
    sbc  hl,de
    jp   nz,FAIL

    ; ---- 6: EXIT FOR: control leaves the loop body but lands on FOR_POP, so the
    ;      frame is released normally (no leak)
    T 6
    call INIT
    call CS_PUSH_FOR
    call CS_PUSH_FOR
    call CS_POP_FOR          ; inner loop exited early -> its FOR_POP
    jp   c,FAIL
    call CS_POP_FOR
    jp   c,FAIL
    call EMPTY
    jp   nz,FAIL
    jp   PASS

FAIL:
    ld   a,2
    out  ($FE),a
.f: halt
    jr   .f
PASS:
    ld   a,4
    out  ($FE),a
.p: halt
    jr   .p

    DISPLAY "control stack core bytes: ", CORE_END-CORE_BEGIN
    DISPLAY "  CS_ALLOC=", CS_PUSH_FOR-CS_ALLOC, " CS_PUSH_FOR=", CS_POP_FOR-CS_PUSH_FOR, " CS_POP_FOR+BAD=", CS_PUSH_CALL-CS_POP_FOR
    DISPLAY "  CS_PUSH_CALL=", CS_UNWIND-CS_PUSH_CALL, " CS_UNWIND=", CS_RET-CS_UNWIND, " CS_RET=", CS_PUSH_PARAM-CS_RET
    DISPLAY "  CS_PUSH_PARAM=", CS_POP_PARAM-CS_PUSH_PARAM, " CS_POP_PARAM=", CORE_END-CS_POP_PARAM
    DS $6000-$,0
    SAVEBIN "build/spikes/control_stack_spike.bin",0,$6000

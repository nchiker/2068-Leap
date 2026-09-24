; ============================================================================
; kernel/extensions/ext_registry.asm — V2-native loadable-extension
; registry (Architecture B, R7.5)
;
; A fresh, V2-native answer to "how does a compiled-bytecode program call
; into a RAM-loaded package" — deliberately NOT a port of V1's own
; BASIC_EXTENSION_REGISTER/EXT_SERVICE_* mechanism (register-passed
; arguments, per-run text rematching, basic.asm-resident registration
; logic). See docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R7.5
; section for the full quantitative comparison this design was chosen
; from (compile-time-resolved slot id + runtime generation check, versus
; a V1-shaped runtime name-rescan) and why.
;
; Never `basic.asm`-resident by construction (unlike V1's own gateway,
; which R9 would otherwise have had to relocate out of basic.asm before
; deleting it) — this module lives in kernel/ from day one, so it needs
; no relocation at all when R9 removes V1's language core.
;
; DESIGN: a compile-time-resolved slot id, not a runtime name search.
; EXT2_REGISTER assigns a slot AND a rolling, never-0 GENERATION value
; (a global counter, bumped on every registration — not slot-indexed —
; so two different registrations, even into the SAME slot after a
; clear, get different generation values). The V2 compiler resolves a
; keyword to a slot id once, at compile time, and bakes BOTH the slot id
; and the generation value it saw into the bytecode operand. At runtime,
; OP_CALL_EXT (rom/exrom_v2_vm_core.asm) re-checks the slot's CURRENT
; generation against the one baked into the bytecode before calling
; through it — a mismatch (module unloaded, or a different module now
; occupying that slot) is a real, caught error, not a silent wrong call.
;
; Arguments are NOT register-passed (V1's own ABI, explicitly not
; preserved per the user's own direction — Z80's 4 general registers
; don't scale to an arbitrary argument count anyway): up to 4 full
; 16-bit values are written to the fixed EXT_CALL_ARG0..3 memory block
; in call order, before the extension's own exec routine is invoked. A
; result may be written to EXT_CALL_RESULT (currently unused by
; statement extensions; reserved for a later function-extension design,
; explicitly out of THIS milestone's scope per docs/v2/
; ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's own R7.5 write-up).
;
; STANDING CONVENTION (see rom/exrom_v2_vm_core.asm's own header for the
; full account): never keep a value live in a register across a `call`;
; save to memory first; check the callee's own "Destroys:" line.
; ============================================================================

; ---------------------------------------------------------------------------
; Workspace — placed at $8F70-$8FF0, immediately after rom/exrom_v2_
; decompiler.asm's own relocated workspace and still comfortably below
; VM_CODE_BASE ($9000). NOT the old $8380 this file used before: that
; address was believed empty from the same "grep rom/exrom_v2_*.asm's
; own equs" check exrom_v2_decompiler.asm's own workspace used, but a
; real build's own .sym file shows $8380-$83FF is NOT empty at all --
; it overlaps real, live V1 sysvars still resident during the R7.5-R9
; coexistence window: SIN_X2 ($8383), SIN_POWER ($8388), GOSUB_STACK
; ($838F, 16 bytes), STR_EXPR_SCRATCH ($83A8), STR_CMP_RIGHT ($83C8),
; and others -- a real, confirmed bug (a program using GOSUB, a trig
; function, or a string comparison at the same time as a loaded V2
; extension would corrupt either the extension registry or that
; sysvar, depending on write order), found while investigating the
; SAME class of placement mistake in exrom_v2_decompiler.asm's own
; workspace (see that file's own header for the full account: include/
; sysvars.inc's real DEFS-allocated sysvars run continuously from $8000
; through $8454 with zero gaps; docs/v2/REWRITE_RAM_BUDGET.md's own
; "$8455-$BFFF usable pool" figure is the real boundary, not any single
; rom/exrom_v2_*.asm file's own local `equ`s). Unlike the decompiler's
; own workspace, this table must NOT reuse compile-time/decompile-time
; scratch -- a registered extension has to survive across compile/RUN/
; LIST cycles -- so it needs genuinely unclaimed, permanent space.
;
; CAPACITY INCREASE (printer-package ROM reconciliation): raising
; EXT2_MAX 8->12 and EXT2_REC_LEN 13->14 (to carry each record's own
; argtypes bitmask -- see EXT2_REGISTER's own header) would grow this
; table from 104 to 168 bytes -- no longer fitting the 144-byte gap
; between $8F70 and VM_CODE_BASE ($9000) alongside EXT_CALL_ARG0-4/
; EXT_CALL_RESULT/EXT2_GEN_COUNTER/EXT2_REG_* (which all stay exactly
; where they were -- only the table itself needs to move). Relocated to
; $9820, comfortably past VM_CODE_BASE's own real bytecode growth
; ($9000-$97FF, 2048 bytes -- already the same real margin rom/
; ext_sprite_module.asm's own workspace at $9800 already trusts) and
; past that module's own 12-byte SPR_* block ($9800-$980B), confirmed
; via the same "grep every rom/*.asm and kernel/*/*.asm equ in this
; address range" audit this project always runs before a new placement
; decision (checked: nothing else claims $980C-$9820 today).
; ---------------------------------------------------------------------------
EXT2_MAX:            equ 12       ; up to 12 registered extensions --
                                    ; SPRITE(4)+MODE/ULAPLUS/PALETTE(3)
                                    ; already used 7 of the old 8-slot
                                    ; cap; 12 leaves room for the new
                                    ; printer package (2 slots -- see
                                    ; that module's own header) plus
                                    ; genuine future headroom, at pure-
                                    ; RAM cost only (verified: EXT2_
                                    ; REGISTER/LOOKUP/CLEAR_ALL's own
                                    ; `cp EXT2_MAX`/`ld bc,EXT2_MAX*
                                    ; EXT2_REC_LEN` are immediate-operand
                                    ; instructions, unchanged size
                                    ; regardless of the constant's value
                                    ; -- raising it costs zero ROM)
EXT2_REC_LEN:        equ 14       ; [gen:1][name_len:1][name:8][exec:2]
                                    ; [argcount:1][argtypes:1] -- the new
                                    ; last byte is a per-argument-position
                                    ; bitmask (bit N set = argument N is
                                    ; a STRING expression), generalizing
                                    ; rom/exrom_v2_compiler.asm's own
                                    ; BUILTIN_FN_TABLE argtype column
                                    ; (R8.5 Group 6, LEN/CODE/VAL) to
                                    ; extensions with several arguments
                                    ; of different types
EXT2_TABLE:          equ $9820    ; 12*14 = 168 bytes, ends $98C8 --
                                    ; relocated, see this block's own
                                    ; header above
EXT_CALL_ARG0:        equ $8FD8   ; 2 bytes each — full 16-bit, not V1's
EXT_CALL_ARG1:        equ $8FDA   ; 1-byte EXTENSION_ARG0..3
EXT_CALL_ARG2:        equ $8FDC
EXT_CALL_ARG3:        equ $8FDE
EXT_CALL_RESULT:      equ $8FE0   ; 2 bytes; reserved, unused by
                                    ; statement extensions for now
EXT_CALL_ARG4:        equ $8FEC   ; 2 bytes -- the 5th arg slot (GRAB's
                                    ; own w/h/etc.), placed in the real
                                    ; free gap between EXT2_REG_NAMELEN's
                                    ; own end ($8FEC) and VM_CODE_BASE
                                    ; ($9000), not contiguous with ARG0-3
                                    ; (which would require shifting
                                    ; EXT_CALL_RESULT/EXT2_GEN_COUNTER/
                                    ; every EXT2_REG_* scratch cell after
                                    ; it) -- OP_CALL_EXT's own arg-index
                                    ; math (EXT_CALL_ARG0 + index*2) only
                                    ; needs to special-case index 4
EXT2_GEN_COUNTER:     equ $8FE2   ; 1 byte; rolling, never 0
EXT2_REG_NAME:        equ $8FE3   ; EXT2_REGISTER scratch (2 bytes)
EXT2_REG_EXEC:        equ $8FE5   ; (2 bytes)
EXT2_REG_ARGCOUNT:    equ $8FE7   ; (1 byte)
EXT2_REG_SLOT:        equ $8FE8   ; (1 byte): the slot index being filled
EXT2_REG_SLOTPTR:     equ $8FE9   ; (2 bytes): a moving write cursor
                                    ; into the slot being filled
EXT2_REG_NAMELEN:     equ $8FEB   ; (1 byte)
EXT2_REG_ARGTYPES:    equ $9810   ; (1 byte) -- EXT2_REGISTER's own copy
                                    ; of its new C=argtypes input,
                                    ; stashed at entry before C is reused
                                    ; as the slot-scan index. Placed
                                    ; alongside the relocated table
                                    ; (genuinely free space -- the
                                    ; original $8F70 block has no spare
                                    ; byte left; see that block's own
                                    ; header) rather than shifting
                                    ; anything in it.

; ===========================================================================
; EXT2_CLEAR_ALL — zeroes the whole registry (every slot's generation
; byte becomes 0 = "empty"), and resets the rolling generation counter.
; Call once at cold boot/NEW, mirroring V1's own EXTENSION_MAGIC reset —
; without this, a stale registration from a previous session/program
; would look valid to a later compile that never re-registered anything
; (the exact bug class MEM_INIT's own EXTENSION_MAGIC reset comment
; already documents for V1's mechanism, re-learned proactively here
; rather than re-discovering it the hard way a second time).
; Destroys: AF, BC, DE, HL.
; ===========================================================================
EXT2_CLEAR_ALL:
        xor a
        ld (EXT2_GEN_COUNTER),a
        ld hl,EXT2_TABLE
        ld bc,EXT2_MAX*EXT2_REC_LEN
        call MEM_FILL_ZERO      ; existing, already-verified platform
                                  ; primitive (kernel/memory) — reused,
                                  ; not reimplemented
        ret

; ===========================================================================
; EXT2_NAME_LEN — input: HL = null-terminated name pointer. Output: A =
; length, capped at 8 (this registry's own name-field width). Destroys:
; AF, BC, HL.
; ===========================================================================
EXT2_NAME_LEN:
        ld b,0
.loop:
        ld a,(hl)
        or a
        jr z,.done               ; BUG FOUND (real hardware): the first
                                    ; version did `ret z` right here,
                                    ; returning with A = the just-read
                                    ; NULL byte (0) instead of the
                                    ; accumulated count in B — every
                                    ; registered name came out with
                                    ; name_len=0 regardless of its real
                                    ; length. Caught by reading the
                                    ; registry table's own real memory
                                    ; after a real run (name_len byte
                                    ; was 0 for "SUM3", a real 4-char
                                    ; name), not by inspection.
        ld a,b
        cp 8
        jr z,.done
        inc hl
        inc b
        jr .loop
.done:
        ld a,b
        ret

; ===========================================================================
; EXT2_REGISTER — In: HL = null-terminated name (<=8 significant chars),
; DE = exec entry point, B = argcount (0-5), C = argtypes bitmask (bit N
; set = argument N is a STRING expression; 0 = every argument numeric,
; the only value every pre-printer-package extension uses). Out: carry
; set + A=0xFF on failure (table full, or argcount>5); carry clear +
; A=slot id on success. Destroys: AF, BC, DE, HL.
;
; Cap raised 4->5 (2068-Leap's own post-R8.5 sprite-module reconciliation
; -- see docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's own SPRITE
; section): GRAB needs 5 args (slot,row,col,w,h). Same-size instruction
; change (`cp 5`->`cp 6`), zero net resident cost. COMPILE_EXT_CALL/
; OP_CALL_EXT's own arg-loops were already argcount-generic (no
; hardcoded max), so this is the ONLY code change the whole mechanism
; needed to support a 5-argument extension.
;
; C=argtypes ADDED (printer-package ROM reconciliation, generalizing
; typed arguments -- see COMPILE_EXT_CALL's own header): C is stashed
; into EXT2_REG_ARGTYPES immediately, before it's reused below as the
; slot-scan index, same "value that must survive a destructive
; register reuse lives in memory first" discipline this whole rewrite
; already follows everywhere else.
EXT2_REGISTER:
        ld (EXT2_REG_NAME),hl
        ld (EXT2_REG_EXEC),de
        ld a,c
        ld (EXT2_REG_ARGTYPES),a
        ld a,b
        cp 6
        jr nc,.fail
        ld (EXT2_REG_ARGCOUNT),a
        ld c,0                  ; slot index
        ld hl,EXT2_TABLE
.scan:
        ld a,(hl)
        or a
        jr z,.found
        inc c
        ld a,c
        cp EXT2_MAX
        jr nc,.fail
        ld de,EXT2_REC_LEN
        add hl,de
        jr .scan
.found:
        ld a,c
        ld (EXT2_REG_SLOT),a
        ; HL -> this slot's own generation byte. Compute the new
        ; (rolling, never-0) generation value now, before any further
        ; use of HL, and write it immediately -- no call intervenes
        ; between reading EXT2_GEN_COUNTER and using HL here, so this is
        ; safe without an extra scratch cell.
        ld a,(EXT2_GEN_COUNTER)
        inc a
        jr nz,.gen_ok
        inc a                    ; skip 0 -- 0 always means "empty"
.gen_ok:
        ld (EXT2_GEN_COUNTER),a
        ld (hl),a                ; write this slot's own generation
        inc hl
        ld (EXT2_REG_SLOTPTR),hl  ; park the dest-record pointer (past
                                    ; the generation byte) — the next
                                    ; call, EXT2_NAME_LEN, uses HL as
                                    ; both its input AND its own scratch,
                                    ; so it cannot survive in a register
                                    ; across that call
        ld hl,(EXT2_REG_NAME)
        call EXT2_NAME_LEN         ; A = length
        ld (EXT2_REG_NAMELEN),a
        ld hl,(EXT2_REG_SLOTPTR)
        ld (hl),a                  ; write name_len
        inc hl
        ld (EXT2_REG_SLOTPTR),hl   ; -> dest name field
        ld de,(EXT2_REG_NAME)       ; DE = source name text (kept in DE,
                                     ; not HL, so DECOMP-style clobber
                                     ; doesn't apply — no call happens
                                     ; between here and the copy loop)
        ex de,hl                     ; HL = source, DE = dest
        ld de,(EXT2_REG_SLOTPTR)
        ld a,(EXT2_REG_NAMELEN)
        ld b,a
        or a
        jr z,.no_name_bytes
.copy_loop:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .copy_loop
.no_name_bytes:
        ; DE already points just past the copied name bytes; zero-pad
        ; the rest of the 8-byte field directly from there.
        ld a,(EXT2_REG_NAMELEN)
        ld b,8
        sub b
        neg
        ld b,a                      ; B = 8-length = padding count (0-8)
        ex de,hl                      ; HL = current write position
        or a
        jr z,.pad_done
.pad_loop:
        xor a
        ld (hl),a
        inc hl
        djnz .pad_loop
.pad_done:
        ; HL now -> byte right after the 8-byte name field == where
        ; exec_ptr/argcount/argtypes go (record layout: gen,name_len,
        ; name[8],exec_ptr[2],argcount[1],argtypes[1] -- exactly where
        ; we are now)
        ld de,(EXT2_REG_EXEC)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld a,(EXT2_REG_ARGCOUNT)
        ld (hl),a
        inc hl
        ld a,(EXT2_REG_ARGTYPES)
        ld (hl),a
        ld a,(EXT2_REG_SLOT)
        or a
        ret
.fail:
        ld a,$FF
        scf
        ret

; ===========================================================================
; EXT2_SLOT_ADDR — input: A = slot id (0-11). Output: HL = record
; address (EXT2_TABLE + id*14, EXT2_REC_LEN having grown 13->14 for the
; printer-package's own argtypes byte -- see EXT2_REC_LEN's own header).
; *14 computed as *8+*4+*1+*1 (8+4+1+1=14) — *13 computed as *8+*4+*1 (a
; first draft's *2,*4,+*5,*10,+*5 chain (=*15, wrong) was caught by
; hand-tracing the arithmetic before ever assembling it, not by a
; failed test) plus one more `add hl,de` for the new 14th byte.
; Destroys: AF, BC, DE, HL.
; ===========================================================================
EXT2_SLOT_ADDR:
        ld l,a
        ld h,0
        ld d,h
        ld e,l                   ; DE = *1
        add hl,hl                 ; *2
        add hl,hl                  ; *4
        push hl                     ; save *4 (BC below needs a real
                                     ; register, and DE is already busy
                                     ; holding *1)
        add hl,hl                    ; *8
        pop bc                        ; BC = *4
        add hl,bc                      ; *8+*4 = *12
        add hl,de                       ; *12+*1 = *13
        add hl,de                        ; *13+*1 = *14
        ld de,EXT2_TABLE
        add hl,de
        ret

; ===========================================================================
; EXT2_LOOKUP_TMP_NAME/LEN/SLOT — EXT2_LOOKUP's own scratch.
EXT2_LOOKUP_NAME:     equ $8FEC   ; (2 bytes)
EXT2_LOOKUP_LEN:      equ $8FEE   ; (1 byte)
EXT2_LOOKUP_SLOT:     equ $8FEF   ; (1 byte)

; ===========================================================================
; EXT2_LOOKUP — In: HL = name pointer, B = length (a compiler token's
; own (TOK_NAME,TOK_LEN) — NOT necessarily null-terminated, unlike
; EXT2_REGISTER's own input convention). Out: carry set if no match;
; carry clear + A = slot id, and the matched slot's own generation/
; argcount readable via EXT2_SLOT_ADDR(A) by the caller (kept simple —
; this routine does not also return those fields itself, since its only
; two real callers, the V2 compiler and this file's own tests, both
; immediately re-derive the slot address anyway to read the rest of the
; record). Destroys: AF, BC, DE, HL.
; ===========================================================================
EXT2_LOOKUP:
        ld (EXT2_LOOKUP_NAME),hl
        ld a,b
        ld (EXT2_LOOKUP_LEN),a
        xor a
        ld (EXT2_LOOKUP_SLOT),a
.loop:
        ld a,(EXT2_LOOKUP_SLOT)
        cp EXT2_MAX
        jr nc,.not_found
        call EXT2_SLOT_ADDR       ; HL -> candidate record
        ld a,(hl)                  ; generation -- 0 means empty, never
                                    ; a real match
        or a
        jr z,.next
        inc hl
        ld a,(hl)                   ; stored name_len
        ld c,a
        ld a,(EXT2_LOOKUP_LEN)
        cp c
        jr nz,.next                 ; length mismatch -- can't be this one
        inc hl                        ; HL -> stored name text
        ld de,(EXT2_LOOKUP_NAME)      ; DE = candidate's OWN input text
        ld a,c
        or a
        jr z,.match                   ; a zero-length name always
                                      ; "matches" a zero-length candidate
                                      ; (never actually reachable via
                                      ; EXT2_REGISTER's own >=1-char
                                      ; keyword convention, but keeps
                                      ; this loop correct regardless)
        ld b,a
.cmp_loop:
        ld a,(de)
        cp (hl)
        jr nz,.next
        inc hl
        inc de
        dec b
        jr nz,.cmp_loop
.match:
        ld a,(EXT2_LOOKUP_SLOT)
        or a
        ret
.next:
        ld a,(EXT2_LOOKUP_SLOT)
        inc a
        ld (EXT2_LOOKUP_SLOT),a
        jr .loop
.not_found:
        scf
        ret

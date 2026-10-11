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
; ============================================================================
; *** STANDING CONVENTION — READ THIS BEFORE ADDING OR EDITING ANY CODE ***
;
;   NEVER KEEP A VALUE LIVE IN A REGISTER ACROSS A `call`.
;   Save it to a dedicated memory scratch cell FIRST, reload it AFTER.
;
; This is not a style preference — it is the single most-repeated real bug
; class in this entire rewrite, found via actual ZEsarUX execution FIVE
; separate times across R2/R3/R5/R6 (register-clobber bug count: R2's
; assignment-target-in-C, R2's load-opcode-clobbering-the-index, R3's
; RESOLVE_ALL_FIXUPS counter, R3's COMPILE_NEXT offset, R5's FOUR string-op
; instances, R6's THREE float instances — see docs/v2/
; ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R2/R3/R5/R6 sections for the full
; account of each). Every single instance had the same shape: a routine
; that "looks safe" to call — no hint from its name or its call site alone
; — turns out to use HL/DE/BC/AF as its OWN internal scratch, silently
; destroying whatever the caller was holding there.
;
; Concrete repeat offenders already found in THIS file: `VM_FLOAT_ADDR`
; clobbers DE; `CALC_SP_TO_NEXT_FREE_PTR` (rom/exrom_calc.asm) documents
; "Destroys: AF, BC, DE, HL" in its own header and still caught a live
; value in HL/DE across it, twice, in this file's own R6 code and again
; independently in the R6 test driver.
;
; Before writing `call SOMETHING` with a value you need afterward still
; sitting in a register: (1) check that callee's own header comment for a
; "Destroys:" line — if it doesn't have one, read its body before trusting
; it; (2) if in ANY doubt, save the value to memory first regardless. A
; wasted `ld (SCRATCH),hl` costs a few bytes and a few cycles. A missed one
; costs a silent, hard-to-find correctness bug that a test program may or
; may not happen to exercise — several of the five bugs above were caught
; only because a specific test program happened to hit that exact path;
; see the R6 retrospective audit (docs/v2/ARCHITECTURE_B_IMPLEMENTATION_
; PLAN.md, R6 section) for what an UNexercised instance of this looks like
; before it's found.
; ============================================================================
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
;   17 = PUSH_STR_LIT (R5 addition; operand: 1 length byte + that many
;                      content bytes, VARIABLE length — the first such
;                      operand in this VM; copies into the next round-
;                      robin STRTAB temp slot, pushes that slot's index)
;   18 = STORE_STR_VAR (R5; operand: 1 byte target STRTAB index; pops a
;                      source index, copies its record onto the target)
;   19 = STR_CONCAT   (R5; pops b-index, pops a-index; concatenates their
;                      content, truncated to 31 bytes, into a fresh temp
;                      slot; pushes that slot's index)
;   20 = STR_CMP_LT   (R5; pops b-index, pops a-index; pushes 1 if a<b
;                      else 0 — lexicographic content comparison)
;   21 = STR_CMP_EQ   (R5; same, equality)
;   22 = PUSH_FLOAT_LIT (R6 addition; operand: 2-byte int value + 2-byte
;                      divisor, computed by the compiler from a decimal
;                      literal's digits; pushes value/divisor as a real
;                      float, via the actual calculator, into a fresh
;                      FLOATTAB temp slot)
;
; R6 also changes ADD/SUB/MUL/DIV's own behavior: each now checks BOTH
; operand tags and, if either is FLOAT, promotes/converts via the real
; calculator instead of raising "float not yet implemented." DIV
; specifically also detects an INEXACT plain-integer division (e.g.
; 5/2) and promotes to FLOAT for that case too, matching NUMERIC_
; DESIGN.md's design — see OP_DIV's own header note for how this stays
; cheap for the (presumably common) exact-division case. STORE_VAR now
; preserves whatever tag VM_POP returns instead of hardcoding TAG_INT.
;
;   23 = CLS     (R7 addition; no operand; clears the bitmap and repaints
;                 the attribute area with the current INK/PAPER/etc.
;                 attribute, via the real kernel/graphics GFX_CLS/
;                 GFX_PAINT_ATTR primitives)
;   24 = BORDER  (R7; pops a value; sets the border via the real
;                 GFX_SET_BORDER primitive, which masks to 0-7 itself)
;   25 = INK     (R7; pops a value; masks to 0-7, stores CURRENT_INK)
;   26 = PAPER   (R7; pops a value; masks to 0-7, stores CURRENT_PAPER)
;   27 = PLOT    (R7; pops y then x — compiler pushes x then y, matching
;                 "PLOT x,y"'s reading order; y is clamped to 0-191, the
;                 attribute byte is computed from current INK/PAPER/
;                 INVERSE/BRIGHT/FLASH state, then the real kernel/
;                 graphics GFX_WRITE_PIXEL primitive is called — see
;                 VM_COMPUTE_PRINT_ATTR/VM_CLAMP_Y191's own header for why
;                 these are a small REWRITE of basic.asm's language-level
;                 logic rather than a call into basic.asm itself)
;
;   28 = LINE    (R7 Phase 2; pops y1,x1,y0,x0 — compiler pushes
;                 x0,y0,x1,y1, matching "LINE x0,y0 TO x1,y1"'s reading
;                 order; writes the real GFX_LINE_X0/Y0/X1/Y1/ATTR/OVER
;                 sysvars, same ones V1 itself writes, then calls the
;                 real, unmodified GFX_LINE)
;   29 = BEEP    (R7 Phase 2; pops pitch,duration — compiler pushes
;                 duration,pitch, matching "BEEP duration,pitch"'s real
;                 V1 order; calls the real, unmodified SOUND_BEEP)
;   30 = SOUND   (R7 Phase 2; pops data,register — compiler pushes
;                 register,data, matching "SOUND register,data"'s real
;                 V1 order; calls the real SOUND_EXROM directly, not
;                 basic.asm's own paging wrapper — see OP_SOUND's own
;                 header for why that's the right call, not a shortcut)
;   31 = POKE    (R7 Phase 2; pops value,address — writes value's low
;                 byte to address, matching V1's own BASIC_STMT_POKE)
;   32 = PAUSE   (R7 Phase 2; pops n; 0 waits for a keypress, >0 waits
;                 exactly n display-frame ticks — the same algorithm
;                 BASIC_STMT_PAUSE already uses, transcribed for the
;                 same "this is language-level control flow, not a
;                 platform primitive" reason as VM_COMPUTE_PRINT_ATTR)
;   33 = RANDOMISE (R7 Phase 2; pops n, calls the real, unmodified
;                 MATH_RND_SEED)
;   34 = CALL_EXT (R7.5; operand [slot_id:1][generation:1][argcount:1];
;                 pops argcount values into EXT_CALL_ARG0..3 (kernel/
;                 extensions/ext_registry.asm), re-checks the matched
;                 slot's current generation against the compiled-in
;                 value, and calls through its exec_ptr — a real,
;                 V2-native loadable-extension dispatch mechanism, NOT a
;                 port of V1's own register-passed/name-rescanned
;                 mechanism; see ext_registry.asm's own header and docs/
;                 v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R7.5 section
;                 for the full design and the quantitative comparison it
;                 was chosen from)
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
;   8 = invalid SOUND register (R7 Phase 2; SOUND_EXROM's own real 1-16
;       range check failed — a real, caught error, matching V1's own
;       MSG_INVALID_SOUND_REGISTER, not silently ignored)
;   9 = extension not found (R7.5; OP_CALL_EXT's own registry generation
;       check failed — the module was never loaded, was unloaded, or a
;       different module now occupies that slot; see kernel/extensions/
;       ext_registry.asm's own header for the full design)
;  10 = array index out of bounds (R8.5 Group 4; OP_ARR_LOAD/STORE's own
;       runtime bounds check against the operand-baked declared size)
;  11 = array index must be an integer (a FLOAT-tagged value popped where
;       OP_ARR_LOAD/STORE expected a TAG_INT array index)
;  12-14 = (formerly invalid MODE/ULAPLUS/PALETTE value) -- retired;
;       MODE/ULAPLUS/PALETTE moved to a loadable extension package
;       (rom/ext_mode_module.asm), which owns its own error codes
;

; Operand-stack record layout (3 bytes, at address SP, SP+1, SP+2):
;   [value_lo][value_hi][tag]   -- SP points at the lowest (most recent) record
; ============================================================================

    INCLUDE "include/v2_layout.inc"

; R8.5 Group 2 (closed out late) -- OP_INPUT_NUM/STR's own KEY_ENTER
; check needs this. Include-guarded (IFNDEF KEYS_INC), so safe even for
; a test file that also includes it separately.
    INCLUDE "include/keys.inc"

; ---------------------------------------------------------------------------
; VM state. Placed by the including driver (rom/test_v2_vm_milestone01.asm
; for now); a later milestone integrating this into the real EXROM build
; will relocate these into include/sysvars.inc.
; ---------------------------------------------------------------------------
VM_CODE_BASE:       equ V2_CODE_BASE ; base address bytecode JMP offsets are relative to
VM_IP:              equ $B600   ; instruction pointer (2 bytes, absolute address)
VM_SP:              equ $B602   ; operand-stack pointer (2 bytes, grows down)
VM_STACK_TOP:       equ $B680   ; operand stack lives $B604-$B67F (initial SP)
VM_STACK_FLOOR:     equ $B604   ; lowest legal SP value (overflow if SP-3 < this)
VM_TOS_TAG:         equ $B682   ; tag of the value last pushed: 0=INT, 1=FLOAT
VM_ERROR_CODE:      equ $B683   ; 0 = no error; see header for nonzero codes
VM_HALTED:          equ $B684   ; nonzero once HALT (or an error-halt) executes
VM_PUSH_VAL_TMP:    equ $B685   ; VM_PUSH scratch (2 bytes)
VM_PUSH_TAG_TMP:    equ $B687   ; VM_PUSH scratch (1 byte)
; R10.7 item 7 (re-attempted: see SYMTAB_BASE/CSYMTAB_MAX_ENTRIES's own
; header comments for the original revert and the now-fixed, unrelated
; VM_ARR_VALUE_TMP/VM_INPUT_COUNT collision that caused it): VM_CALL_STACK
; grows from 6 to 12 entries. Its TOP stays fixed at $B6A0 (so nothing
; above it — VM_STR_TEMP_NEXT and every string/float/ext/array/input
; scratch cell through $B79D — needs to move); its FLOOR extends downward
; from $B694 to $B688 instead, which is exactly the 12 bytes the 6 cells
; below (VM_FOR_LIMIT/VM_FOR_NEXT_BRANCH/VM_FOR_NEXT_VALADDR/VM_FOR_NEXT_
; NEWVAL/VM_CALL_PUSH_TMP/VM_CALL_SP) used to occupy. Those 6 cells are
; relocated to $B79E-$B7A9 below (the confirmed-free 98-byte runtime gap
; between VM_ARR_VALUE_TMP's own real end, $B79E, and CSYMTAB_BASE,
; $B800) instead — no other runtime or compile-time cell moves.
VM_FOR_LIMIT:       equ $B79E   ; FOR_INIT/FOR_NEXT: remembered loop limit (2
                                ; bytes) — single active loop, R1 scope only
VM_FOR_NEXT_BRANCH: equ $B7A0  ; OP_FOR_NEXT scratch: branch target operand (2B)
VM_FOR_NEXT_VALADDR: equ $B7A2 ; OP_FOR_NEXT scratch: loop var's value_lo addr (2B)
VM_FOR_NEXT_NEWVAL: equ $B7A4  ; OP_FOR_NEXT scratch: incremented value (2B)
VM_CALL_PUSH_TMP:   equ $B7A6  ; VM_CALL_PUSH scratch (2 bytes)
; R10.7 P4: the fixed call / param-save / FOR stacks are gone; all three are
; frames on the unified typed control stack (VM_CSP, include/v2_layout.inc).

SYM_REC_LEN:        equ 3       ; 3 bytes/record (tag + 2-byte value; no name
                                ; field at runtime at all — REWRITE_RAM_BUDGET.md's
; R10.7 item 7 (re-attempted — see docs/v2/R10_7_CAPABILITY_RESTORATION.md
; and docs/v2/R10_7_CAPACITY_ARCHITECTURE_AUDIT.md): numeric scalars widen
; 16->32. The extra 16 slots (48B) are NOT placed by growing this table in
; place (that cascaded into every table above it last time, which is how
; the real-but-unrelated VM_ARR_VALUE_TMP/VM_INPUT_COUNT collision got
; exposed) and NOT in general-purpose "free RAM" — they live in the V2
; source-staging buffer ($9455-V2_CODE_BASE), reusing the audit's own
; verified lifetime invariant: that buffer is written fresh by
; V2_BUILD_SOURCE and read by the lexer only DURING COMPILE_PROGRAM, and
; is provably idle for the entire execution phase (VM_INIT/VM_RUN never
; read or write it). SYMTAB_OVERFLOW_BASE/STRTAB_OVERFLOW_BASE below are
; valid ONLY from VM_INIT (after a successful compile) until the next
; V2_BUILD_SOURCE call — do not read or write them during compilation,
; and do not assume their contents survive past the next RUN.

; ---------------------------------------------------------------------------
; Post-R9 PROC/DEF-FN recursion-safety correction (docs/v2/
; V2_SEMANTIC_CAPABILITY_AUDIT.md S11): PROC's parameter was bound through
; a plain STORE_VAR into the SAME shared SYMTAB slot every other use of
; that name resolves to -- only the return address was saved/restored
; across a call (VM_CALL_PUSH/POP above), not the parameter's own value,
; so a recursive call silently clobbered an outer invocation's own
; parameter. OP_PARAM_BIND/OP_PARAM_UNBIND (opcodes 56/57) below replace
; the plain STORE_VAR/RET pair at a PROC's own entry/exit with one that
; also saves/restores the parameter symbol's ENTIRE value across the
; call -- both its SYMTAB record (3 bytes: works for a plain INT
; parameter) AND its own dedicated FLOATTAB slot's real 5 bytes (a FLOAT
; parameter's SYMTAB record only ever holds that fixed per-variable
; FLOATTAB index -- see OP_STORE_VAR's own .float_store note below -- so
; restoring the index alone would not undo an inner call's own
; overwrite of the actual float data at that same fixed slot). This is
; the smallest shared reentrant mechanism the milestone asked for: DEF
; FN's own reintegration reuses these same two opcodes at its own
; JMP_DEFFN entry/RET_DEFFN exit, unchanged.
; Placed in the 208-byte gap between SYMTAB_BASE+16*3=$B730 and
; CSYMTAB_BASE=$B800 (checked directly against every other v2 file's own
; equ's before placing this).
; ---------------------------------------------------------------------------
; R10.7 item 7 (re-attempted — see VM_CALL_STACK_FLOOR's own header
; comment above for the original revert/now-fixed collision this re-
; attempt builds on): nesting depth 6->12, matching VM_CALL_STACK's own
; R10.7 widening above. VM_PARAM_SAVE_STACK_FLOOR/SP stay exactly where
; they were ($B730/$B732 — SYMTAB_BASE itself did NOT grow in place, see
; its own header comment, so there is no pressure on this address from
; below); only the TOP moves, growing upward by the formula below. The 3
; small scratch cells that used to sit right after the old $B762 top
; (VM_PARAM_SYM_ADDR_TMP/FLOAT_ADDR_TMP/BIND_INDEX_TMP) are relocated to
; sit right after the NEW top instead, the same relative position they
; always had — confirmed free up to VM_ARR_ADDR_TMP ($B798, unchanged).
VM_PARAM_SYM_ADDR_TMP:  equ $B792  ; OP_PARAM_BIND/UNBIND
                                     ; scratch (2 bytes): the parameter's
                                     ; own SYMTAB record address, parked
                                     ; before a call
VM_PARAM_FLOAT_ADDR_TMP: equ VM_PARAM_SYM_ADDR_TMP+2 ; (2 bytes): the
                                     ; parameter's own dedicated FLOATTAB
                                     ; record address
VM_PARAM_BIND_INDEX_TMP: equ VM_PARAM_FLOAT_ADDR_TMP+2 ; (1 byte): the
                                     ; symbol index this instruction's own
                                     ; operand names (compiled-index design)

TAG_INT:            equ 0
TAG_FLOAT:          equ 1
TAG_STR:            equ 2   ; QUAL (Q-02): a string TEMP index on the operand stack (variable refs stay 0)

; --- R5 addition: string table (separate from the numeric SYMTAB above —
; a 31-byte-cap string cannot fit in a 2-byte operand-stack slot, so string
; "values" on the operand stack are always a 2-byte STRTAB INDEX, pushed
; via the ordinary PUSH_I16 opcode reused for this purpose — see
; docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R5 section for why no
; new "push a string index" opcode was needed) ---
; R8.5 Group 4 -- fixed-stride runtime array pool. Integer-only (TAG_INT),
; statically sized (compile-time-constant DIM), flat 2-bytes/element
; storage -- no allocator, no per-element tag byte (a real, deliberate
; RAM saving over the scalar SYMTAB's own [tag][lo][hi] shape: an array
; R10.7 dynamic-array redesign: the old fixed 4x16 ARRTAB pool (128
; bytes, always fully reserved regardless of real DIM'd size) is
; removed. Arrays now live in a sequential arena growing from ARRAYS_
; END up to VARS_START (include/sysvars.inc) -- real, already-existing,
; already-correctly-reset-by-NEW/CLEAR/cold-boot sysvars that nothing
; previously advanced past PROG_END. See docs/v2/R10_7_ARRAY_
; ARCHITECTURE_AUDIT.md Part 2 for the full design.
;
; ARR_PTR_TABLE: one 2-byte runtime arena-address slot per possible
; compile-time array index (0 = not yet DIM'd this run). This is now
; the ONLY fixed-size runtime cost -- the array's own data is arena-
; allocated, not pre-reserved here. Placed a little past the old freed
; ARRTAB_BASE ($B460) rather than reusing it exactly, leaving a clean
; margin before STRTAB_BASE ($B500).
; STRARR_PTR_TABLE -- same idea, for string arrays (item 3), placed
; right after ARR_PTR_TABLE (16*2=32 bytes, $B4B0-$B4CF).

; Arena descriptor shapes (in ARRAYS_END..VARS_START):
;   numeric: [dim_count:1][count:2][data: count*2 bytes]
;   string:  [dim_count:1][count:2][width:1][data: count*width bytes],
;            each element [len:1][content:width-1]
; dim_count is always 1 today -- reserved so a future 2-D DIM needs no
; format migration for existing 1-D arrays (R10_7_ARRAY_ARCHITECTURE_
; AUDIT.md Part 2 item 3).
ARR_DESC_COUNT_OFF:  equ 1        ; offset of the 2-byte element count
ARR_DESC_DATA_OFF:   equ 3        ; offset of the data (numeric)
STRARR_DESC_WIDTH_OFF: equ 3      ; offset of the 1-byte element width
STRARR_DESC_DATA_OFF:  equ 4      ; offset of the data (string)

; R10.7 Dynamic Data Phase 2 -- string arrays (DIM A$(n[,w])). Runtime
; scratch, placed in the real free 32-byte gap between STRARR_PTR_TABLE's
; own end ($B4D0+8*2=$B4E0) and STRTAB_BASE ($B500) -- confirmed free by
; direct address-collision grep before picking this span (same discipline
; as every other hand-placed cell in this file).
VM_STRARR_INDEX_TMP: equ $B4E0  ; OP_STRARR_LOAD/STORE/DIM_STR: the
                                   ; operand-baked array slot (1 byte)
VM_STRARR_COUNT_TMP: equ $B4E1  ; OP_STRARR_LOAD/STORE: the operand-baked
                                   ; declared element count (2 bytes)
                                   ; ($B4E3-$B4E4 deliberately left
                                   ; unused here -- the element-index
                                   ; scratch is VM_ARR_ELEM_TMP, shared
                                   ; with the numeric array opcodes, see
                                   ; VM_ARR_VALIDATE_INDEX's own header)
VM_STRARR_WIDTH_TMP: equ $B4E5  ; VM_STRARR_ADDR's own resolved per-
                                   ; element width, read from the arena
                                   ; descriptor (1 byte) -- saved to memory
                                   ; because the immediately-following
                                   ; MATH_MULTIPLY16 call destroys A
VM_STRARR_ADDR_TMP:  equ $B4E6  ; VM_STRARR_ADDR's own data-base address,
                                   ; parked across MATH_MULTIPLY16 (which
                                   ; destroys AF/BC/DE); OP_STRARR_STORE
                                   ; also reuses this cell (its own use of
                                   ; VM_STRARR_ADDR has already finished by
                                   ; then) to park the resolved destination
                                   ; address across the following
                                   ; VM_STR_ADDR call (2 bytes)
VM_STRARR_VALUE_IDX_TMP: equ $B4E8 ; OP_STRARR_STORE only: the popped
                                   ; source string's own STRTAB index,
                                   ; saved across the second VM_POP (the
                                   ; array index) that follows it (1 byte)

STR_REC_LEN:        equ 32
STRTAB_TEMP_COUNT:  equ 4       ; concatenation-result temp slots (indices
                                 ; 8-9 now, were 4-5), round-robin — no
                                 ; allocator, matching this
                                 ; project's own "avoid inventing a general
                                 ; allocator" discipline; a temp is only
                                 ; ever live long enough to be immediately
                                 ; STORE_STR_VAR'd or compared, per this
                                 ; milestone's own scoped grammar (string
                                 ; expressions are a flat '+' chain, never
                                 ; nested independently-live sub-results)
VM_STR_TEMP_NEXT:   equ $B6A0   ; round-robin index into the temp slots (1B)
VM_STR_LIT_LEN_TMP: equ $B6A1   ; OP_PUSH_STR_LIT scratch (1 byte)
VM_STR_LIT_TEMPIDX_TMP: equ $B6A2  ; shared scratch (1 byte): the temp-slot
                                     ; index chosen for this operation,
                                     ; before it's turned into an absolute
                                     ; STRTAB index
VM_STR_TARGET_TMP:  equ $B6A3   ; OP_STORE_STR_VAR scratch (1 byte)
VM_STR_SRC_ADDR_TMP: equ $B6A4  ; shared scratch (2 bytes): a source
                                  ; record's address, saved across a second
                                  ; VM_STR_ADDR call that would otherwise
                                  ; overwrite it
VM_STR_DST_ADDR_TMP: equ $B6A6  ; OP_STR_CONCAT scratch (2 bytes)
VM_STR_RUNNING_DST_TMP: equ $B6AC ; OP_STR_CONCAT scratch (2 bytes): the
                                    ; running dest-content WRITE pointer,
                                    ; saved to memory across the second
                                    ; VM_STR_ADDR call (for b's record) —
                                    ; that call uses DE as its own scratch
                                    ; internally, clobbering it; an earlier
                                    ; version kept the running dest pointer
                                    ; in DE across that call, so the
                                    ; "append b's content" phase silently
                                    ; started writing at STRTAB_BASE
                                    ; instead of continuing the temp slot,
                                    ; corrupting whatever record happened to
                                    ; sit at index 0. Caught by a real
                                    ; ZEsarUX run and confirmed by single-
                                    ; stepping VM_STR_ADDR's own body live
                                    ; (the seventh real register-clobber
                                    ; bug found this way across R2-R5).
VM_STR_CONCAT_B_TMP: equ $B6A8  ; OP_STR_CONCAT scratch (1 byte): the
                                  ; second operand's STRTAB index
VM_STRCMP_LENA_TMP: equ $B6A9   ; VM_STR_COMPARE scratch (1 byte)
VM_STRCMP_LENB_TMP: equ $B6AA   ; VM_STR_COMPARE scratch (1 byte)
VM_STRCMP_MINLEN_TMP: equ $B6AB ; VM_STR_COMPARE scratch (1 byte)
BFN_STR_TMP:        equ $B6AE   ; R8.5 Group 6 (string-result functions)
                                  ; scratch, 1 byte: a value that must
                                  ; survive VM_STR_ALLOC_TEMP/VM_STR_ADDR
                                  ; (both destroy AF/HL) -- same "park it
                                  ; in memory, not a register, across a
                                  ; destructive call" discipline this
                                  ; whole rewrite keeps needing

; --- R6 addition: floating point, via the REAL, existing calculator
; (rom/exrom_calc.asm) — reused, not reimplemented, per this whole
; rewrite's standing architecture decision (NUMERIC_DESIGN.md,
; ARCHITECTURE_COMPARISON.md). A real 5-byte calculator float cannot fit
; in a 2-byte operand-stack slot, so — exactly mirroring the string
; design above — a FLOAT "value" on the VM's own operand stack is always
; a 2-byte FLOATTAB index, pushed via the ordinary TAG_FLOAT-tagged
; VM_PUSH; the actual 5 float bytes live in FLOATTAB, in the calculator's
; own native format (opaque to the VM — copied to/from CALC_STACK
; verbatim, never decoded here). ---
FLOAT_REC_LEN:      equ 5
FLOATTAB_TEMP_COUNT: equ 4      ; arithmetic-result temp slots, indices
                                  ; FLOATTAB_MAX_VARS.. — round-robin, same
                                  ; "no allocator needed" reasoning as
                                  ; STRTAB's own temps: a temp is only
                                  ; ever live long enough to be
                                  ; immediately stored or compared
VM_FLOAT_TEMP_NEXT: equ $B6AE   ; round-robin index into the temp slots (1B)
VM_FLOAT_TEMPIDX_TMP: equ $B6AF ; VM_FLOAT_STORE_RESULT scratch (1 byte)
VM_FLOAT_A_TAG:     equ $B6B0   ; OP_ADD/SUB/MUL/DIV scratch (1 byte each):
VM_FLOAT_A_VAL:     equ $B6B1   ; operand A's tag/value, saved to memory
VM_FLOAT_B_TAG:     equ $B6B3   ; the moment VM_POP returns them, since
VM_FLOAT_B_VAL:     equ $B6B4   ; every one of these handlers pops TWICE
                                  ; and needs both operands' tag+value
                                  ; simultaneously afterward
VM_FLOAT_OPERAND_TAG: equ $B6B6 ; VM_FLOAT_PUSH_OPERAND's own input (1 byte)
VM_FLOAT_OPERAND_VAL: equ $B6B7 ; (2 bytes)
VM_DIV_QUOTIENT_TMP: equ $B6B9  ; OP_DIV scratch (2 bytes): the fast-path
                                  ; int quotient, saved across the
                                  ; exactness-check multiply-back before
                                  ; either using it (exact) or discarding
                                  ; it in favour of a real float divide
                                  ; (inexact)
VM_FLOAT_SRC_ADDR_TMP: equ $B6BB ; VM_FLOAT_PUSH_OPERAND's own dedicated
                                  ; scratch (2 bytes): parks the source
                                  ; FLOATTAB address across the
                                  ; CALC_SP_TO_NEXT_FREE_PTR call inside
                                  ; VM_FLOAT_PUSH_OPERAND's .is_float branch
                                  ; (that routine documents "Destroys: AF,
                                  ; BC, DE, HL" — holding the source in HL
                                  ; across it was a real bug found on real
                                  ; hardware, see that branch's own
                                  ; comment). Deliberately a NEW cell, not
                                  ; VM_FLOAT_B_VAL: this routine is called
                                  ; TWICE per opcode (once for operand A,
                                  ; once for operand B), and the first
                                  ; call's caller (OP_ADD/SUB/MUL/DIV) still
                                  ; needs VM_FLOAT_B_TAG/VAL intact when
                                  ; operand A happens to be the FLOAT one —
                                  ; reusing B's own cell as scratch here
                                  ; would have reintroduced the exact same
                                  ; clobber bug one level up.
VM_PLOT_X_TMP:      equ $B6BD    ; R7 (OP_PLOT) scratch, 1 byte each: x/y/
VM_PLOT_Y_TMP:      equ $B6BE    ; attribute/OVER-flag, all parked in
VM_PLOT_ATTR_TMP:   equ $B6BF    ; memory across VM_COMPUTE_PRINT_ATTR/
VM_PLOT_OVER_TMP:   equ $B6C0    ; VM_CLAMP_Y191 rather than kept live in
                                  ; a register across those calls — same
                                  ; standing discipline as every other
                                  ; scratch cell above, applied up front
                                  ; this time instead of found via a bug
VM_EXT_SLOT:        equ $B6C1    ; R7.5 (OP_CALL_EXT) scratch, 1 byte
VM_EXT_GEN:         equ $B6C2    ; each unless noted: the operand's own
VM_EXT_ARGCOUNT:    equ $B6C3    ; [slot_id][generation][argcount], and
VM_EXT_REMAINING:   equ $B6C4    ; a countdown used while popping args
VM_EXT_POPVAL:      equ $B6C5    ; (2 bytes): this iteration's popped value
VM_EXT_RECPTR:      equ $B6C7    ; (2 bytes): the matched registry record
VM_EXT_EXEC_PTR:    equ $BA5C    ; (2 bytes): preserve package target while
                                  ; paging chunk 6 back to Home for execution

; --- R8.5 addition: text I/O (PRINT/LPRINT/INPUT). BASIC_OUTPUT_ROW/COL
; (basic.asm) are NOT reused here -- basic.asm is V1's own language
; core, deleted whole at R9 (same reasoning R7's own VM_COMPUTE_PRINT_
; ATTR/VM_CLAMP_Y191 header already gives for not calling BASIC_STMT_
; CLS/PLOT/COMPUTE_PRINT_ATTR directly: depending on it here would just
; create a dependency R9 has to unwind later). A small, self-contained
; VM-owned equivalent instead. ---
VM_ARR_INDEX_TMP:   equ $B6D0  ; R8.5 Group 4 -- OP_ARR_LOAD/STORE scratch:
                                  ; the operand-baked array slot, saved to
                                  ; memory before VM_POP (which uses HL/DE
                                  ; internally, same "never keep a value in
                                  ; a register across a call" discipline
                                  ; this whole file already follows)
VM_ARR_SIZE_TMP:    equ $B6D1   ; R10.7 -- widened to 2 bytes (was 1): the
                                  ; operand-baked declared element count,
                                  ; now up to 65535 (arena-bounded, not a
                                  ; fixed 16-element pool)
VM_ARR_ELEM_TMP:    equ $B6D3   ; the popped, bounds-checked element index
                                  ; (2 bytes, though only the low byte is
                                  ; ever nonzero for a valid access)
; VM_ARR_VALUE_TMP relocated to $B79C (below, with VM_ARR_ADDR_TMP/
; VM_DIM_COUNT_TMP) -- widening it to 2 bytes at its original $B6D5
; would have overlapped VM_INPUT_COUNT at $B6D6 by one byte (a real bug
; caught here: documented in an earlier version of this comment but
; never actually fixed until now -- OP_ARR_STORE was never exercised by
; the test that first caught this, so the collision went unnoticed).
; VM_ARR_ADDR_TMP/VM_DIM_COUNT_TMP: placed at $B798, NOT contiguous with
; the cells above -- this whole $B6D0-$B6E1 span is fully packed
; (VM_INPUT_* overlaps immediately after the old VM_ARR_VALUE_TMP),
; confirmed by direct address-collision check before picking this spot. $B798 is
; real free space: past VM_PARAM_BIND_INDEX_TMP's own widened end
; ($B792 + 2 + 2 + 1 = $B797, once VM_PARAM_NEST_MAX is 12 -- see that
; equ's own R10.7 update below) and before rom/exrom_v2_compiler.asm's
; own CSYMTAB_BASE ($B800).
VM_ARR_ADDR_TMP:    equ $B798   ; R10.7 -- VM_ARR_ADDR's own resolved
                                  ; arena element address (2 bytes),
                                  ; parked across VM_ERR_* calls
VM_DIM_COUNT_TMP:   equ $B79A   ; R10.7 OP_DIM scratch (2 bytes): the
                                  ; requested element count, saved across
                                  ; the arena-bump arithmetic
VM_ARR_VALUE_TMP:   equ $B79C   ; OP_ARR_STORE only: the popped value,
                                  ; saved across the second VM_POP (the
                                  ; index) that follows it (2 bytes)

; R8.5 Group 2 (closed out late, see this milestone's own status note) --
; INPUT. A genuine V2-native rewrite on top of kernel/io/io.asm's real
; IO_READ_KEY (kernel-resident, confirmed reusable post-R9) and the same
; GFX_PRINT_STRING_ATTR echo path PRINT already validated -- NOT a port
; of rom/exrom_input.asm's own V1 mechanism (confirmed basic.asm-
; dependent, not reusable).
VM_INPUT_COUNT:      equ $B6D6  ; digits/chars accepted so far (1 byte)
VM_INPUT_TARGET_TMP: equ $B6D7  ; the operand-baked SYMTAB/STRTAB index,
                                   ; saved to memory before IO_READ_KEY
                                   ; (1 byte)
VM_INPUT_NEG_TMP:    equ $B6D8  ; numeric INPUT only: 1 = a leading '-'
                                   ; was seen (1 byte)
VM_INPUT_CHARBUF:    equ $B6D9  ; a 2-byte [char][0] scratch buffer,
                                   ; reprinted via GFX_PRINT_STRING_ATTR
                                   ; once per accepted character -- the
                                   ; SAME null-terminated-text contract
                                   ; VM_PRINT_COMMON already uses, not a
                                   ; new echo primitive
VM_INPUT_STR_PTR:    equ $B6DB  ; string INPUT only: running write
                                   ; pointer into the target STRTAB
                                   ; record's own content area (2 bytes)
VM_INPUT_DIGITS:     equ $B6DD  ; numeric INPUT only: up to 6 accepted
                                   ; digit characters (max int magnitude
                                   ; is 5 digits + sign), parsed to a
                                   ; 16-bit value once ENTER closes input
VM_INPUT_DIGITS_MAX: equ 5
VM_INPUT_TEXT_MAX:   equ 20     ; RC: numeric INPUT text in PRINT_BUF      ; -32768..32767 -- 5 digits, sign tracked
                                   ; separately in VM_INPUT_NEG_TMP

VM_FOR_STEP:         equ $B6E2  ; R8.5 Group 5 -- FOR...STEP. Remembered
                                   ; loop step (2 bytes) for the INNERMOST
                                   ; currently-running loop -- a cached
                                   ; top-of-VM_FOR_STACK copy, kept as a
                                   ; plain cell because OP_FOR_NEXT already
                                   ; reads it this way; OP_FOR_INIT/
                                   ; OP_FOR_POP keep it synchronized with
                                   ; VM_FOR_STACK on every push/pop (see
                                   ; VM_FOR_STACK_BASE below). A STEP-less
                                   ; FOR compiles a literal PUSH_I8 1 here
                                   ; (rom/exrom_v2_compiler.asm's own
                                   ; COMPILE_FOR), so OP_FOR_INIT/
                                   ; OP_FOR_NEXT never need to special-case
                                   ; "no step" at runtime. Post-R9: real
                                   ; nesting up to VM_FOR_NEST_MAX deep is now
                                   ; supported (was a KNOWN, DOCUMENTED
                                   ; single-active-loop limitation before
                                   ; this milestone; docs/v2/
                                   ; V2_SEMANTIC_CAPABILITY_AUDIT.md S9).

; ---------------------------------------------------------------------------
; Post-R9 nested FOR/NEXT correction: VM_FOR_LIMIT/VM_FOR_STEP above are a
; single active loop's cached values; nesting needs the ENCLOSING loop's
; own values preserved somewhere while an inner loop runs. VM_FOR_STACK
; holds exactly that: OP_FOR_INIT pushes the current (about-to-be-
; enclosing) VM_FOR_LIMIT/STEP onto it before overwriting them with the
; new inner loop's values; OP_FOR_POP (opcode 55, emitted once by the
; compiler right after every compiled NEXT -- both a loop's normal fall-
; through-past-limit exit and EXIT FOR's own patched JMP land there, see
; rom/exrom_v2_compiler.asm's COMPILE_NEXT) pops them back. VM_FOR_NEST_MAX=4
; matches the compiler's own identical, explicit nesting-depth limit
; (rom/exrom_v2_compiler.asm) -- bytecode from this compiler can never
; exceed it, so no runtime bound check is needed here. Placed in the free
; gap between STRTAB_BASE+6*32=$B5C0 and VM_IP=$B600 (64 bytes; checked
; directly against every other v2 file's own equ's before placing this).
; ---------------------------------------------------------------------------
; R10.7 P4: the FOR frames live on the unified control stack (see
; VM_CS_ALLOC); VM_FOR_LIMIT/STEP above remain the live innermost values.
VM_OUTPUT_ROW:       equ $B6C9    ; current PRINT row, 0-23 (1 byte)
VM_OUTPUT_COL:        equ $B6CA    ; unused after a PRINT (V1's own real
                                     ; PRINT always ends its own line --
                                     ; no ";"-suppressed-newline form
                                     ; exists in this dialect -- kept for
                                     ; symmetry/future AT support, always
                                     ; 0 today) (1 byte)
VM_PRINT_TEXT_TMP:    equ $B6CB    ; (2 bytes): text pointer parked
                                     ; across VM_COMPUTE_PRINT_ATTR
VM_PRINT_SIGN_TMP:    equ $B6CD    ; (1 byte): nonzero if a float being
                                     ; printed was negative
BFN_ABS_IDX_TMP:      equ $B6CE    ; (2 bytes): R8.5 Group 1 -- BUILTIN_
                                     ; FN_ABS's own float-index scratch,
                                     ; parked across the VM_FLOAT_ADDR/
                                     ; sign-check calls that would
                                     ; otherwise clobber it

; every one of these is real RAM, not a register held across a call or a
; loop that itself calls something else — the standing discipline
; established after four real register-clobber bugs found via ZEsarUX
; execution in R2/R3 (see docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md).

; ---------------------------------------------------------------------------
; VM_INIT — call once before VM_RUN. Resets both stacks, error/halt flags.
; ---------------------------------------------------------------------------
VM_RUN_SP:          equ $BED0   ; QUAL (Q-03/Q-18): SP of the VM's caller, restored by VM_ERR_COMMON
VM_INIT:
        ld (VM_RUN_SP),sp       ; QUAL: errors raised while carving the tables / binding the store
        ld hl,(SYM_END_V)          ; R10.7 -- reset the array arena so a second RUN of the same
        ld de,SESS_GAP+1           ; program doesn't allocate on top of the old arrays. RC (session):
        add hl,de                  ; the arena starts SESS_GAP above the symbol table
        ld (ARRAYS_END),hl
        ld (SESS_ARENA_BASE),hl
        ld hl,ARR2_BASE          ; R10.7 P5.4: segment 2 starts empty
        ld (ARR2_END),hl
        call VM_INIT_REGS
        jp VM_CARVE_TABLES       ; R10.7 P3: size the run-time tables
VM_INIT_REGS:
        ld hl,VM_STACK_TOP
        ld (VM_SP),hl
        xor a
        ld (VM_ERROR_CODE),a
        ld (VM_HALTED),a
        ld (VM_OUTPUT_ROW),a    ; R8.5 -- PRINT/LPRINT's own output cursor;
        ld (VM_OUTPUT_COL),a
        ld (ARR2_SWAPPED),a
        ret

; RC (session variables): VM_INIT_SESSION -- an immediate statement in a session. The arena, segment 2
; and the values stay; the run-time tables are re-carved for the symbol counts the statement may have
; grown, each table's existing slots moved to its new base (lowest table first: every base only moves
; down, so each move is an ascending LDIR onto free or already-moved space) and only the new slots and
; the temporaries zeroed. Old counts and bases come from SESS_SAVE (taken before the compile).
VM_INIT_SESSION:
        ld (VM_RUN_SP),sp
        call VM_INIT_REGS
        call VM_CARVE_PTRS              ; the new bases
        ld hl,VM_CARVE_DESC+24          ; the SYMTAB descriptor (the lowest table) first
        ld b,5
.move:
        push bc
        push hl
        ld a,(hl)                       ; the count cell's low byte (SYM_COUNTS + kind)
        add a,SESS_SAVE_OFS
        ld e,a
        ld d,SESS_SAVE >> 8
        ld a,(de)                       ; A = the old count
        inc hl
        inc hl
        inc hl
        ld c,(hl)                       ; C = bytes per slot
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)                       ; DE = this table's pointer cell
        ld b,a
        ld hl,0
        or a
        jr z,.k0
        push de
        ld e,c
        ld d,h
.mul:
        add hl,de
        djnz .mul                       ; HL = the bytes to keep
        pop de
.k0:
        push hl                         ; keep
        ex de,hl                        ; HL = pointer cell
        ld e,(hl)
        inc hl
        ld d,(hl)                       ; DE = new base
        ld a,l
        add a,SESS_SAVE_OFS-1
        ld l,a
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a                          ; HL = old base
        pop bc                          ; BC = keep
        ld a,b
        or c
        jr z,.k1
        ldir                            ; DE -> the first slot to zero
.k1:
        pop hl                          ; this descriptor
        push hl
        push de                         ; the first byte to zero
        ld a,l
        cp VM_CARVE_DESC & $FF
        ld de,V2_SOURCE_END             ; the highest table ends at the pool top
        jr z,.top
        dec hl
        ld d,(hl)
        dec hl
        ld e,(hl)                       ; DE = the pointer cell of the table above (descriptor 6 lower)
        ex de,hl
        ld e,(hl)
        inc hl
        ld d,(hl)                       ; DE = its new base
.top:
        ex de,hl
        pop de
        or a
        sbc hl,de                       ; HL = the bytes to zero (0 when the table did not grow)
        ld b,h
        ld c,l
        ex de,hl
        call nz,MEM_FILL_ZERO           ; the new slots and the temporaries
        pop hl
        ld de,-6
        add hl,de                       ; the next table up
        pop bc
        djnz .move
        ret

; V2_SESSION_UNDO -- RC: back to the symbol table and run-time tables saved in SESS_SAVE (an immediate
; statement that failed to compile, or whose new slots did not fit). Flags are preserved.
V2_SESSION_UNDO:
        ld hl,SESS_SAVE
        ld de,SYM_COUNTS
        ld bc,23
        ldir
        ld hl,(SYM_END_V)
        ld (hl),b                       ; the table's terminator
        ld hl,(RT_SYMTAB_PTR)
        ld (VARS_START),hl              ; the lowest table's base
        ret

; ---------------------------------------------------------------------------
; VM_CARVE_TABLES -- R10.7 P3. The run-time tables are no longer fixed
; reservations: they are carved, exactly sized, from the TOP of the pool (just
; below the compile/run zone) from the counts the compiler produced:
;
;   table               bytes                              pointer
;   SYMTAB              3 * N                              RT_SYMTAB_PTR
;   FLOATTAB            5 * (N + FLOATTAB_TEMP_COUNT)      RT_FLOATTAB_PTR
;   STRTAB              32 * (M + STRTAB_TEMP_COUNT)       RT_STRTAB_PTR
;   array pointers      2 * A                              RT_ARRPTR_PTR
;   string-arr pointers 2 * SA                             RT_STRARRPTR_PTR
;   (N numeric, M string, A array, SA string-array symbols)
;
; Variable access stays direct and indexed (base pointer in RAM; the old tier
; compare is gone, so it is no slower). The round-robin string and float temp
; slots sit just above the program's own variables, so their indices start at
; M / N; RT_STR_COUNT / RT_NUM_COUNT hold M / N for that. VARS_START becomes
; the bottom of the carved block, which is exactly the ceiling the array arena
; already checks, so FREE() stays VARS_START - ARRAYS_END. If the block does
; not fit above ARRAYS_END (which starts just past the compile symbol table)
; the run is refused with VM_ERR_ARRAY_SPACE (error 64, "OUT OF MEMORY").
; The whole block is zeroed.
; ---------------------------------------------------------------------------
VM_CARVE_TABLES:
        call VM_CARVE_PTRS
        ld hl,V2_SOURCE_END
        ld de,(VARS_START)
        or a
        sbc hl,de               ; HL = block length (never 0: the temp slots)
        ld b,h
        ld c,l
        ex de,hl                ; HL = block start
        jp MEM_FILL_ZERO
; VM_CARVE_PTRS -- size and place the run-time tables for the current symbol counts (bases, VARS_START,
; VM_CSP); the contents are not touched.
VM_CARVE_PTRS:
        ld a,(CSYM_COUNT)
        ld (RT_NUM_COUNT),a
        ld a,(STRSYM_COUNT)
        ld (RT_STR_COUNT),a
        ld hl,V2_SOURCE_END
        ld (VARS_START),hl
        ld hl,VM_CARVE_DESC
        ld b,5
.table:
        push bc
        ld e,(hl)
        inc hl
        ld d,(hl)               ; DE = address of this table's count cell
        inc hl
        ld a,(de)
        add a,(hl)              ; + the number of temp slots
        inc hl
        ld c,(hl)               ; C = bytes per slot
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)               ; DE = this table's pointer cell
        inc hl
        push hl                 ; next descriptor
        push de
        ld b,a                  ; B = slots
        ld hl,0
        ld d,0
        ld e,c
        or a
        jr z,.mulend            ; (a table can be empty: 0 symbols)
.mul:
        add hl,de               ; HL = slots * bytes-per-slot
        djnz .mul
.mulend:
        ex de,hl                ; DE = size
        ld hl,(VARS_START)
        or a
        sbc hl,de               ; HL = new base
        ld (VARS_START),hl
        pop de                  ; DE = pointer cell
        ex de,hl
        ld (hl),e
        inc hl
        ld (hl),d               ; pointer cell = new base
        pop hl                  ; next descriptor
        pop bc
        djnz .table
        ld hl,(VARS_START)
        ld de,(ARRAYS_END)
        or a
        sbc hl,de
        jp c,VM_ERR_ARRAY_SPACE ; the block does not fit
        ld hl,(VARS_START)
        ld (VM_CSP),hl          ; R10.7 P4: control stack starts empty at the
        ret
VM_CARVE_DESC:
        dw STRARRSYM_COUNT
        db 0, 2
        dw RT_STRARRPTR_PTR
        dw ARRSYM_COUNT
        db 0, 2
        dw RT_ARRPTR_PTR
        dw STRSYM_COUNT
        db STRTAB_TEMP_COUNT, 32
        dw RT_STRTAB_PTR
        dw CSYM_COUNT
        db FLOATTAB_TEMP_COUNT, 5
        dw RT_FLOATTAB_PTR
        dw CSYM_COUNT
        db 0, 3
        dw RT_SYMTAB_PTR


; ---------------------------------------------------------------------------
; VM_RUN — dispatch loop. Entry: VM_IP already set by the caller. Returns
; when VM_HALTED becomes nonzero (normal HALT or any error-halt).
; ---------------------------------------------------------------------------
VM_RUN:
        ld (VM_RUN_SP),sp       ; QUAL: any VM error returns straight to VM_RUN's caller
.loop:
        ld a,(VM_HALTED)
        or a
        ret nz
        ld hl,(VM_IP)
        ld a,(hl)               ; fetch opcode
        inc hl
        ld (VM_IP),hl
        cp 74                   ; 74 opcodes (OUT 67, NL 68, PRINT_COMMA 69, PUSH_FLOAT5 70, STR_CMP_GT 71, AND_SC 72, OR_SC 73)
                                 ; (was: 67 opcodes defined (0-66, R8.5 adds
                                 ; 35-38: PRINT_NUM/STR, LPRINT_NUM/STR;
                                 ; 39: CALL_FN (Group 1); 40-43: CMP_LE/
                                 ; GT/GE/NE; 44-46: AND/OR/NOT; 47:
                                 ; JMP_ELSE (Group 3); 48-49: ARR_LOAD/
                                 ; ARR_STORE (Group 4); 50-51: INPUT_NUM/
                                 ; INPUT_STR (Group 2's own late close-out).
                                 ; 52-54 (formerly MODE/ULAPLUS/PALETTE,
                                 ; removed to a loadable extension package)
                                 ; are now JMP_DEFFN/CALL_UDF/RET_DEFFN
                                 ; (post-R9 DEF FN reintegration, docs/v2/
                                 ; deffn_design/README.md) -- runtime-
                                 ; IDENTICAL aliases of JMP/CALL/RET, a
                                 ; compile-time/decompile-time
                                 ; disambiguation only. 55: OP_FOR_POP (post-R9
                                 ; nested FOR/NEXT correction) -- pops the
                                 ; innermost FOR_STACK frame; both a loop's
                                 ; normal fall-through-past-limit exit and
                                 ; EXIT FOR's own patched JMP land on this
                                 ; opcode, so both paths pop exactly once.
                                 ; 56-57: OP_PARAM_BIND/OP_PARAM_UNBIND
                                 ; (post-R9 PROC/DEF-FN recursion-safety
                                 ; correction).
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
        dw OP_PUSH_STR_LIT
        dw OP_STORE_STR_VAR
        dw OP_STR_CONCAT
        dw OP_STR_CMP_LT
        dw OP_STR_CMP_EQ
        dw OP_PUSH_FLOAT_LIT
        dw OP_CLS               ; 23 (R7)
        dw OP_BORDER             ; 24
        dw OP_INK                ; 25
        dw OP_PAPER               ; 26
        dw OP_PLOT                ; 27
        dw OP_LINE                 ; 28 (R7 Phase 2)
        dw OP_BEEP                  ; 29
        dw OP_SOUND                  ; 30
        dw OP_POKE                    ; 31
        dw OP_PAUSE                    ; 32
        dw OP_RANDOMISE                 ; 33
        dw OP_CALL_EXT                   ; 34 (R7.5)
        dw OP_PRINT_NUM                   ; 35 (R8.5)
        dw OP_PRINT_STR                    ; 36
        dw OP_FLASH                           ; 37 (was OP_LPRINT_NUM;
                                                ; R10.7 attribute setter)
        dw OP_BRIGHT                           ; 38 (was OP_LPRINT_STR;
                                                ; R10.7 attribute setter)
        dw OP_CALL_FN                         ; 39 (R8.5 Group 1)
        dw OP_CMP_LE                           ; 40 (R8.5 Group 3)
        dw OP_CMP_GT                            ; 41
        dw OP_CMP_GE                             ; 42
        dw OP_CMP_NE                              ; 43
        dw OP_AND                                  ; 44
        dw OP_OR                                    ; 45
        dw OP_NOT                                    ; 46
        dw OP_JMP                                     ; 47 (R8.5 Group 3
                                                        ; -- OP_JMP_ELSE:
                                                        ; runtime-identical
                                                        ; to plain JMP,
                                                        ; deliberately
                                                        ; aliased to the
                                                        ; SAME handler --
                                                        ; only the opcode
                                                        ; NUMBER differs,
                                                        ; for the
                                                        ; decompiler's own
                                                        ; benefit)
        dw OP_ARR_LOAD                                  ; 48 (R8.5 Group 4)
        dw OP_ARR_STORE                                  ; 49
        dw OP_INPUT_NUM                                   ; 50 (R8.5 Group 2)
        dw OP_INPUT_STR                                    ; 51
        dw OP_JMP                                           ; 52 JMP_DEFFN --
                                                              ; post-R9 DEF FN
        dw OP_CALL                                          ; 53 CALL_UDF --
                                                              ; runtime-
        dw OP_RET                                           ; 54 RET_DEFFN --
                                                              ; IDENTICAL to
                                                              ; JMP/CALL/RET
                                                              ; (compile-time/
                                                              ; decompile-time
                                                              ; disambiguation
                                                              ; only, same as
                                                              ; OP_JMP_ELSE)
        dw OP_FOR_POP                                       ; 55 (nested FOR/NEXT)
        dw OP_PARAM_BIND                                    ; 56 (PROC/DEF FN
        dw OP_PARAM_UNBIND                                  ; 57  recursion safety)
        ; 52-54 (OP_MODE/OP_ULAPLUS/OP_PALETTE) removed -- now a
        ; loadable extension package, rom/ext_mode_module.asm
        dw OP_OVER                                          ; 58 (R10.7 --
        dw OP_INVERSE                                       ; 59  attribute
                                                             ; setters, OP_
                                                             ; FLASH/BRIGHT
                                                             ; above reused
                                                             ; 37-38)
        dw OP_AT                                            ; 60 (R10.7 --
        dw OP_TAB                                           ; 61  standalone
                                                             ; cursor stmts)
        dw OP_CLEAR                                         ; 62 (R10.7)
        dw V2_EXROM_ARR_DIM_ADDR                            ; 63 (R10.9: EXROM-owned DIM
                                                             ; dynamic arrays)
        dw V2_EXROM_ARR_DIM_STR_ADDR                        ; 64 (R10.9: EXROM-owned DIM$
        dw OP_STRARR_LOAD                                   ; 65  Phase 2 --
        dw OP_STRARR_STORE                                  ; 66  string arrays)
        dw OP_OUT                                           ; 67  STUDY
        dw OP_NL                                            ; 68  STUDY
        dw OP_PRINT_COMMA                                   ; 69  STUDY
        dw OP_PUSH_FLOAT5                                   ; 70  RC: 5-byte literal
        dw OP_STR_CMP_GT                                    ; 71  RC: string >
        dw OP_AND_SC                                        ; 72  RC: short-circuit AND
        dw OP_OR_SC                                         ; 73  RC: short-circuit OR

; ---------------------------------------------------------------------------
; String-table access: index (A) -> HL = record address. Same shape as
; VM_SYM_ADDR, separate table. R10.7 item 7: two-tier (BASE indices 0-3 /
; OVERFLOW indices 4-9, which now includes both the 4 new named slots AND
; the 2 round-robin temps — see STRTAB_MAX_VARS's own header comment for
; why the temps relocated too). One extra compare+branch versus the old
; flat formula; still a direct indexed access, never a name search, so
; the project's standing "identifiers resolve to compact slot references
; at compile time, runtime access stays O(1)" property is unchanged.
; ---------------------------------------------------------------------------
VM_STR_ADDR:
        ld l,a
        ld h,0                  ; HL = index
        add hl,hl               ; *2
        add hl,hl               ; *4
        add hl,hl               ; *8
        add hl,hl               ; *16
        add hl,hl               ; *32
        ld de,(RT_STRTAB_PTR)   ; R10.7 P3: flat table sized by the compiler's
        add hl,de               ; counts (no tier); A is preserved
        ret

VM_STR_COPY:
        ld b,32
.loop:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .loop
        ret

; ---------------------------------------------------------------------------
; Symbol access: index (A) -> HL = record address. R10.7 item 7: two-tier
; (BASE indices 0-15 / OVERFLOW indices 16-31 — see SYMTAB_OVERFLOW_BASE's
; own header comment for the lifetime invariant the overflow tier depends
; on). Same "one extra compare, still O(1), never a name search"
; discipline as VM_STR_ADDR above.
; ---------------------------------------------------------------------------
VM_SYM_ADDR:
        ld l,a
        ld h,0                  ; HL = index
        ld d,h
        ld e,l                  ; DE = index (copy)
        add hl,hl                ; HL = index*2
        add hl,de                ; HL = index*3
        ld de,(RT_SYMTAB_PTR)    ; R10.7 P3: flat table, base in RAM
        add hl,de
        ret

VM_PUSH_STR_RESULT:
        pop af
        ld l,a
        ld h,0
        ld a,TAG_STR             ; QUAL (Q-02) -- was xor a
        jr VM_PUSH

; ---------------------------------------------------------------------------
; Operand stack, WITH real bounds checking.
; ---------------------------------------------------------------------------
VM_PUSH_INT:                   ; RC shrink: push HL as an INT
        xor a                   ; TAG_INT
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
        ret

; PUSH_INT_CONTINUE -- shared opcode-handler tail: push HL as a plain
; TAG_INT value and continue the VM dispatch loop. Identical 3-
; instruction, 7-byte sequence previously duplicated 21 times across
; this file's own opcode handlers (R10.7 dormant-ROM audit, docs/v2/
; R10_7_DORMANT_ROM_CONSOLIDATION_AUDIT.md). A pure tail-jump (never a
; `call`) into VM_RUN.loop, which itself never returns here -- no stack
; surgery of any kind, so every call site just becomes `jp
; PUSH_INT_CONTINUE` with no change to the hardware stack at the jump.
; In: HL = the plain integer result to push. Destroys: AF (and whatever
; VM_RUN.loop's own dispatch destroys next).
PUSH_STR_CONTINUE:
        ld a,TAG_STR            ; QUAL (Q-02): string temp results carry their own tag
        jr PUSH_INT_CONTINUE.push
PUSH_INT_CONTINUE:
        xor a                    ; TAG_INT=0 (xor a, 1 byte, not ld a,TAG_INT's 2)
.push:
        call VM_PUSH
        jp VM_RUN.loop

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

; VM_POP_CHECK_INT -- shared "pop, then require a plain TAG_INT value"
; tail used by OP_ARR_LOAD/STORE and OP_STRARR_LOAD/STORE's own array-
; index/value operand fetches (identical `call VM_POP / cp TAG_INT / jp
; nz,VM_ERR_ARRAY_TYPE` sequence previously duplicated 6 times; R10.7
; dormant-ROM audit, docs/v2/R10_7_DORMANT_ROM_CONSOLIDATION_AUDIT.md).
; Out: HL = value, A = TAG_INT (on success); jumps to VM_ERR_ARRAY_TYPE
; directly otherwise, same as the inlined version did. Destroys: AF.
VM_POP_CHECK_INT:
        rst $10
        cp TAG_INT
        jp nz,VM_ERR_ARRAY_TYPE
        ret

; ---------------------------------------------------------------------------
; VM call stack (bytecode return addresses only — separate from both the
; operand stack above and the Z80 hardware stack).
; ---------------------------------------------------------------------------
; ---------------------------------------------------------------------------
; R10.7 P4 -- unified typed control stack. One memory-limited stack, growing
; DOWN from VARS_START (the carved-table block's bottom) toward ARRAYS_END,
; replaces the fixed 12-deep call, 12-deep param-save and 15-deep FOR stacks.
; Frames (tag first, lowest address = top):
;   T_FOR   [1][var][limit:5][step:5]  (QUAL: calculator form)  12 B
;   T_CALL  [2][return address:2]                               3 B
;   T_PARAM [3][SYMTAB record:3][FLOATTAB record:5]             9 B
; RET / PARAM_UNBIND skip FOR frames above their owner (a GOTO out of a loop
; leaks its FOR frame); the owner's pop then discards them. Exhaustion is the
; same clean VM_ERR_CALL_STACK_OVERFLOW; the Z80 hardware stack is separate.
; ---------------------------------------------------------------------------
T_FOR:                  equ 1
T_CALL:                 equ 2
T_PARAM:                equ 3

; VM_CS_ALLOC -- A = frame size. Out: HL = new frame, CSP lowered; carry set
; (nothing changed) if it would run into ARRAYS_END. Destroys: AF, DE, HL.
VM_CS_ALLOC:
        ld e,a
        ld d,0
        ld hl,(VM_CSP)
        or a
        sbc hl,de
        ret c
        ex de,hl                ; DE = new CSP
        ld hl,(ARRAYS_END)
        or a
        sbc hl,de               ; arrays end - new
        jr z,.ok
        jr nc,.fail             ; the stack would run into the arrays
.ok:
        ld (VM_CSP),de
        ex de,hl                ; HL = new frame
        or a
        ret
.fail:
        scf
        ret

; VM_CS_UNWIND -- Out: HL = topmost non-FOR frame, A = its tag; carry set if
; the stack is empty. CSP is not changed.
VM_CS_UNWIND:
        ld hl,(VM_CSP)
.next:
        ld de,(VARS_START)
        or a
        sbc hl,de
        jr z,.empty
        add hl,de
        ld a,(hl)
        cp T_FOR
        ret nz                  ; carry clear
        ld de,VM_FOR_FRAME_LEN  ; QUAL: FOR frames are [T_FOR][var][limit:2][step:2]
        add hl,de
        jr .next
.empty:
        scf
        ret

VM_CALL_PUSH:                  ; input: HL = bytecode return address
        push hl
        ld a,3
        call VM_CS_ALLOC
        pop de
        jp c,VM_ERR_CALL_STACK_OVERFLOW
        ld (hl),T_CALL
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        ret

VM_CALL_POP:                   ; output: HL = bytecode return address
        call VM_CS_UNWIND
        jp c,VM_ERR_CALL_STACK_UNDERFLOW
        cp T_CALL
        jp nz,VM_ERR_CALL_STACK_UNDERFLOW
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (VM_CSP),hl
        ex de,hl
        ret

; VM_PARAM_SAVE_PUSH -- input: HL = source SYMTAB record address (3
; bytes), DE = source dedicated FLOATTAB record address (5 bytes).
; Destroys: AF, BC, DE, HL.
VM_PARAM_SAVE_PUSH:
        push de
        push hl
        ld a,9
        call VM_CS_ALLOC
        jr c,.fail
        ld (hl),T_PARAM
        inc hl
        ex de,hl                ; DE = frame+1
        pop hl                  ; HL = symbol record
        ld bc,3
        ldir
        pop hl                  ; HL = float record
        ld bc,5
        ldir
        ret
.fail:
        pop hl
        pop de
        jp VM_ERR_CALL_STACK_OVERFLOW

; VM_PARAM_SAVE_POP -- input: HL = destination SYMTAB record address (3
; bytes), DE = destination dedicated FLOATTAB record address (5 bytes).
; Destroys: AF, BC, DE, HL.
VM_PARAM_SAVE_POP:
        push de
        push hl
        call VM_CS_UNWIND
        jr c,.bad
        cp T_PARAM
        jr nz,.bad
        inc hl                  ; -> saved record
        pop de                  ; DE = symbol record
        ld bc,3
        ldir
        pop de                  ; DE = float record
        ld bc,5
        ldir
        ld (VM_CSP),hl          ; HL is just past the frame
        ret
.bad:
        pop hl
        pop de
        jp VM_ERR_CALL_STACK_UNDERFLOW

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
        jp PUSH_INT_CONTINUE

OP_PUSH_I16:
        ld hl,(VM_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        ld (VM_IP),hl
        ex de,hl
        jp PUSH_INT_CONTINUE

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

; OP_STORE_VAR — R6 changes this beyond just preserving the tag (see
; below): storing a FLOAT-tagged value must copy the actual 5 float
; bytes into a slot DEDICATED to this variable's own SYMTAB index
; (FLOATTAB_MAX_VARS's own header comment explains why), not merely
; copy whatever transient index VM_POP handed back — a value produced by
; arithmetic lives in a ROUND-ROBIN TEMP slot that a later float
; operation will legitimately reuse; a variable that only remembered
; that index, instead of a real copy, would silently see its own value
; change later when the temp slot gets overwritten by something
; unrelated. Found and fixed before ever running on real hardware, by
; reasoning through what a real test program with more than
; FLOATTAB_TEMP_COUNT live float results would actually do.
OP_STORE_VAR:
        ld hl,(VM_IP)
        ld a,(hl)               ; symbol index operand
        inc hl
        ld (VM_IP),hl
VM_STORE_VAR_LOOP:              ; QUAL (float FOR): the store is a subroutine now; FOR_INIT/NEXT reuse it
        call VM_STORE_VAR_BY_INDEX
        jp VM_RUN.loop

; VM_STORE_VAR_BY_INDEX -- input: A = symbol index. Pops one operand-
; stack value and stores it into that symbol, tag-aware (float values
; get a real copy into their own dedicated FLOATTAB slot, see below).
; Factored out of OP_STORE_VAR (post-R9 PROC/DEF-FN recursion-safety
; correction) so OP_PARAM_BIND below can reuse the identical store logic
; after first saving the parameter's OLD value -- the two opcodes differ
; only in what happens BEFORE the store, never in the store itself.
; Falls through to VM_RUN.loop exactly like the original inline body did.
VM_STORE_VAR_BY_INDEX:
        ld c,a                  ; save index
        rst $10                 ; HL = value, A = tag
        ld (VM_FLOAT_A_TAG),a
        ld (VM_FLOAT_A_VAL),hl
        cp TAG_FLOAT
        jr z,.float_store
        push hl                 ; save value
        ld a,c
        call VM_SYM_ADDR        ; HL -> record
        pop de                  ; DE = value
        ld a,(VM_FLOAT_A_TAG)
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        ret
.float_store:
        ; BUG FOUND (real hardware, R6): the first version of this branch
        ; held the source address in DE across a SECOND call to
        ; VM_FLOAT_ADDR (to compute the dest address) — but VM_FLOAT_ADDR
        ; itself uses DE as scratch (`ld d,h / ld e,l ... ld de,FLOATTAB_
        ; BASE`), silently destroying the source address before the ldir
        ; ever ran. Every variable's dedicated FLOATTAB slot came back
        ; all-zero as a result (confirmed via real `mem` reads: FLOATTAB
        ; index 0/2/3 all-zero while the round-robin temp slots 16/17 held
        ; the real computed bytes) — exactly the "register clobbered
        ; across a call" bug class this whole project keeps re-finding.
        ; Fixed by parking the source address in memory (reusing
        ; VM_FLOAT_B_VAL, unused by this single-operand opcode) instead of
        ; in a register VM_FLOAT_ADDR might touch.
        ld a,l                  ; the popped (transient) FLOATTAB index
        call VM_FLOAT_ADDR       ; HL -> source floattab record
        ld (VM_FLOAT_B_VAL),hl   ; park source address in memory, not DE
        ld a,c                   ; this variable's own SYMTAB index —
                                  ; also its own DEDICATED FLOATTAB index,
                                  ; by this design's 1:1 mapping
        call VM_FLOAT_ADDR       ; HL -> dest floattab record
        ex de,hl                 ; DE = dest
        ld hl,(VM_FLOAT_B_VAL)   ; HL = source (recovered from memory,
                                  ; untouched by the call above)
        push bc                  ; save C (target index) — ldir clobbers
                                  ; BC as its own byte counter
        ld bc,FLOAT_REC_LEN
        ldir
        pop bc
        ld a,c
        call VM_SYM_ADDR         ; HL -> this variable's SYMTAB record
        ld a,TAG_FLOAT
        ld (hl),a
        inc hl
        ld (hl),c                ; value = this variable's own (now
                                   ; freshly-populated) dedicated
                                   ; FLOATTAB index — stable, not a
                                   ; borrowed temp reference
        inc hl
        ld (hl),0
        ret

; ---------------------------------------------------------------------------
; OP_PARAM_BIND / OP_PARAM_UNBIND (opcodes 56/57) -- post-R9 PROC/DEF-FN
; recursion-safety correction (docs/v2/V2_SEMANTIC_CAPABILITY_AUDIT.md
; S11). COMPILE_PROC emits OP_PARAM_BIND where it used to emit a plain
; OP_STORE_VAR at a procedure's own entry (right after its skip-JMP), and
; OP_PARAM_UNBIND right before OP_RET at its own exit. Both share the
; identical 1-byte [symbol_index] operand OP_STORE_VAR already used here.
; ---------------------------------------------------------------------------

; OP_PARAM_BIND -- saves the parameter symbol's CURRENT value (its
; SYMTAB record and its own dedicated FLOATTAB slot's real bytes) onto
; VM_PARAM_SAVE_SP, THEN stores the caller's just-pushed argument into it
; via the exact same VM_STORE_VAR_BY_INDEX logic OP_STORE_VAR uses.
OP_PARAM_BIND:
        ld hl,(VM_IP)
        ld a,(hl)
        inc hl
        ld (VM_IP),hl
        ld (VM_PARAM_BIND_INDEX_TMP),a
        call VM_SYM_ADDR              ; HL -> this symbol's own record
        ld (VM_PARAM_SYM_ADDR_TMP),hl
        ld a,(VM_PARAM_BIND_INDEX_TMP)
        call VM_FLOAT_ADDR             ; HL -> this symbol's own dedicated
                                         ; FLOATTAB record (1:1 mapping,
                                         ; same as OP_STORE_VAR's own
                                         ; .float_store above)
        ex de,hl                        ; DE = floattab addr
        ld hl,(VM_PARAM_SYM_ADDR_TMP)   ; HL = sym addr
        call VM_PARAM_SAVE_PUSH
        ld a,(VM_PARAM_BIND_INDEX_TMP)
        jr VM_STORE_VAR_LOOP            ; pops the argument, stores it,
                                          ; falls through to VM_RUN.loop

; OP_PARAM_UNBIND -- restores the parameter symbol's OLD value (both
; its SYMTAB record and its own dedicated FLOATTAB slot's real bytes),
; undoing exactly what the matching OP_PARAM_BIND changed -- symmetric
; with VM_CALL_PUSH/POP's own return-address save/restore, one layer
; deeper (the parameter's VALUE, not just where to resume).
OP_PARAM_UNBIND:
        ld hl,(VM_IP)
        ld a,(hl)
        inc hl
        ld (VM_IP),hl
        ld (VM_PARAM_BIND_INDEX_TMP),a
        call VM_SYM_ADDR
        ld (VM_PARAM_SYM_ADDR_TMP),hl
        ld a,(VM_PARAM_BIND_INDEX_TMP)
        call VM_FLOAT_ADDR
        ex de,hl                        ; DE = floattab addr
        ld hl,(VM_PARAM_SYM_ADDR_TMP)   ; HL = sym addr
        call VM_PARAM_SAVE_POP
        jp VM_RUN.loop

; ---------------------------------------------------------------------------
; R10.7 dynamic-array redesign (R8.5 Group 4's own opcodes, rewired) --
; array element access. Both opcodes carry a 3-byte operand baked in at
; compile time: [array_index:1][declared_size:2] -- the declared size
; still travels WITH every access for the bounds check (now 16-bit, no
; longer capped at 255), but the array's own DATA now lives in the
; arena (ARRAYS_END..VARS_START), reached via one extra indirection
; through ARR_PTR_TABLE[array_index] -- see docs/v2/R10_7_
; ARRAY_ARCHITECTURE_AUDIT.md Part 2 for the full design.
; ---------------------------------------------------------------------------

; VM_ARR_ADDR — input: VM_ARR_INDEX_TMP (array slot 0..ARRAY_MAX_COUNT-1),
; VM_ARR_ELEM_TMP (element index, already bounds-checked by the caller).
; Output: HL = (this array's own arena descriptor address) + ARR_DESC_
; DATA_OFF + elem_index*2; carry set if the array was never DIM'd this
; run (ARR_PTR_TABLE slot still 0) -- a real, distinct error, not a
; silent wrap into address 0.
; Destroys: AF, DE, HL.
VM_ARR_ADDR:
        ld a,(VM_ARR_INDEX_TMP)
        ld l,a
        ld h,0
        add hl,hl                ; *2 -- ARR_PTR_TABLE index -> byte offset
        ld de,(RT_ARRPTR_PTR)
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)                ; DE = this array's arena descriptor addr
        ld a,d
        or e
        scf
        ret z                     ; never DIM'd this run
        ex de,hl                  ; HL = descriptor addr
        ld de,ARR_DESC_DATA_OFF
        add hl,de                 ; HL -> data[0]
        ld de,(VM_ARR_ELEM_TMP)
        add hl,de
        add hl,de                 ; + elem_index*2
        or a                      ; carry clear -- success
        ret

; VM_ARR_VALIDATE_INDEX — shared numeric/string array-index bounds check,
; used by OP_ARR_LOAD/STORE and OP_STRARR_LOAD/STORE alike (identical
; logic previously duplicated across all four -- factored out during the
; Dynamic Data Phase 2 HOME-budget shrink pass; no behavior change, same
; two error exits). Input: HL = popped index value (already TAG_INT-
; checked by the caller), DE = this access's own declared element count.
; Output: HL = the same index value, confirmed 0 <= HL < DE; jumps
; directly to VM_ERR_ARRAY_BOUNDS on failure (never returns on failure).
; Destroys: AF, DE.
VM_ARR_VALIDATE_INDEX:
        ld a,h
        bit 7,a
        jp nz,VM_ERR_ARRAY_BOUNDS   ; negative index
        or a
        sbc hl,de
        jp nc,VM_ERR_ARRAY_BOUNDS    ; index >= declared count
        add hl,de                    ; HL = index again
        ret

OP_ARR_LOAD:
        ld hl,(VM_IP)
        ld a,(hl)
        ld (VM_ARR_INDEX_TMP),a
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (VM_ARR_SIZE_TMP),de
        inc hl
        ld (VM_IP),hl
        call VM_POP_CHECK_INT
        ld de,(VM_ARR_SIZE_TMP)
        call VM_ARR_VALIDATE_INDEX
        ld (VM_ARR_ELEM_TMP),hl
        call VM_ARR_ADDR
        jp c,VM_ERR_ARRAY_BOUNDS  ; never DIM'd
        ld e,(hl)
        inc hl
        ld d,(hl)
        ex de,hl
        jp PUSH_INT_CONTINUE

OP_ARR_STORE:
        ld hl,(VM_IP)
        ld a,(hl)
        ld (VM_ARR_INDEX_TMP),a
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (VM_ARR_SIZE_TMP),de
        inc hl
        ld (VM_IP),hl
        call VM_POP_CHECK_INT
        ld (VM_ARR_VALUE_TMP),hl
        call VM_POP_CHECK_INT
        ld de,(VM_ARR_SIZE_TMP)
        call VM_ARR_VALIDATE_INDEX
        ld (VM_ARR_ELEM_TMP),hl
        call VM_ARR_ADDR
        jp c,VM_ERR_ARRAY_BOUNDS
        ld de,(VM_ARR_VALUE_TMP)
        ld (hl),e
        inc hl
        ld (hl),d
        jp VM_RUN.loop

; OP_DIM — R10.7, real runtime allocation (DIM used to do zero runtime
; work; the size was purely a compile-time bound). Operand: [array_
; index:1][count:2]. Writes a [dim_count:1][count:2][data...] descriptor
; at the current ARRAYS_END, bumps ARRAYS_END past it, and records the
; new descriptor's address in ARR_PTR_TABLE[array_index]. Sequential/
; arena-only: no free(), matching this milestone's own "no fragmentation-
; prone heap" requirement.
; ARENA_ALLOC_NUMERIC -- shared numeric-array arena allocation core,
; factored out of OP_DIM below so Dynamic Data Phase 2's array LOAD
; (rom/exrom_v2_shell.asm, reached via the build/v2_crossbank.inc
; cross-bank binding, the same mechanism MEM_CLEAR_V2 already uses) can
; reuse the EXACT allocation logic OP_DIM itself uses, instead of a
; second, parallel copy of it. Input: A = array index, DE = requested
; element count. Output: on success, returns normally (ARR_PTR_TABLE
; [array_index] already updated, ARRAYS_END already bumped) -- the
; caller re-derives the new descriptor's data address via VM_ARR_ADDR
; (element index 0) rather than this routine returning it directly, the
; same lookup LOAD needs again anyway for every subsequent element. On
; exhaustion, tail-jumps to VM_ERR_ARRAY_SPACE -- which itself ends in a
; plain RET (VM_ERR_COMMON), so this ALSO returns normally to the
; caller either way; an EXROM caller (LOAD) distinguishes the two by
; checking VM_ERROR_CODE/VM_HALTED afterward instead of a carry flag
; (cheaper here than threading a carry-based contract through, and
; VM_INIT already clears both on the next real RUN regardless).
; Destroys: AF, BC, DE, HL.
ARENA_ALLOC_NUMERIC:
        ld (VM_ARR_INDEX_TMP),a
        ld (VM_DIM_COUNT_TMP),de  ; DE = requested element count
        ; needed = 3 (header) + count*2
        ld h,d
        ld l,e
        add hl,hl                 ; count*2
        ld de,ARR_DESC_DATA_OFF
        add hl,de                 ; + header -- HL = needed byte total
        call VM_ARENA_FIT         ; main pool, else segment 2 (swapped in)
        jp nc,VM_ERR_ARRAY_SPACE  ; fits neither
        ; write the descriptor at the OLD ARRAYS_END
        ld hl,(ARRAYS_END)
        ld (hl),1                 ; dim_count=1 (R10.7 item 3: reserved
                                     ; for a future 2-D DIM; every 1-D
                                     ; array's own byte layout is
                                     ; unaffected if that ever lands)
        inc hl
        ld de,(VM_DIM_COUNT_TMP)
        ld (hl),e
        inc hl
        ld (hl),d
        ; record this array's own descriptor address (the OLD ARRAYS_
        ; END) in ARR_PTR_TABLE[array_index]
        ld de,(ARRAYS_END)
        ld a,(VM_ARR_INDEX_TMP)
        ld l,a
        ld h,0
        add hl,hl
        ld bc,(RT_ARRPTR_PTR)
        add hl,bc
        ld (hl),e
        inc hl
        ld (hl),d
        ; bump ARRAYS_END past the whole descriptor
        ld hl,(ARRAYS_END)
        ld de,ARR_DESC_DATA_OFF
        add hl,de
        ld de,(VM_DIM_COUNT_TMP)
        add hl,de
        add hl,de                  ; + count*2
        ld (ARRAYS_END),hl
        jp VM_ARENA_DONE

; ---------------------------------------------------------------------------
; R10.7 Dynamic Data Phase 2 -- string arrays, DIM A$(n[,w]). Same arena/
; pointer-table/OP_DIM machinery as the numeric arrays above (docs/v2/
; R10_7_ARRAY_ARCHITECTURE_AUDIT.md Part 2 item 2), reusing STRARR_PTR_
; TABLE/STRARRAY_MAX_COUNT already reserved there. A string array element
; is a fixed-width, length-prefixed [len:1][content:width-1] record --
; the same shape STRTAB already uses, just at a caller-chosen width
; instead of STRTAB's fixed 32 bytes. A string VALUE on the VM's own
; operand stack is always a STRTAB index (see the R5 header note above),
; so array LOAD copies the element's own content into a fresh STRTAB
; temp slot and pushes that temp's index (the same "produce an ordinary
; string value" contract every BUILTIN_FN_* string function already
; follows, e.g. UPPER$/LOWER$'s own copy-skeleton below); array STORE
; does the reverse, copying an already-resolved STRTAB record's content
; into the arena, truncated to the array's own declared width.
; ---------------------------------------------------------------------------

; VM_STRARR_ADDR — input: VM_STRARR_INDEX_TMP (array slot), VM_STRARR_
; ELEM_TMP (element index, already bounds-checked by the caller). Output:
; HL = this element's own [len][content] record address; VM_STRARR_
; WIDTH_TMP = this array's own per-element width (saved to memory, not
; A, since the multiply below destroys A); carry set if the array was
; never DIM'd this run. Destroys: AF, BC, DE, HL.
VM_STRARR_ADDR:
        ld a,(VM_STRARR_INDEX_TMP)
        ld l,a
        ld h,0
        add hl,hl                ; *2 -- STRARR_PTR_TABLE index -> byte offset
        ld de,(RT_STRARRPTR_PTR)
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)                ; DE = this array's arena descriptor addr
        ld a,d
        or e
        scf
        ret z                     ; never DIM'd this run
        ex de,hl                  ; HL = descriptor addr
        ld de,STRARR_DESC_WIDTH_OFF
        add hl,de                 ; HL -> width byte
        ld a,(hl)                 ; A = this array's own per-element width
        ld (VM_STRARR_WIDTH_TMP),a
        inc hl                    ; HL -> data[0] (WIDTH_OFF+1 == DATA_OFF)
        ld (VM_STRARR_ADDR_TMP),hl ; park data-base across MATH_MULTIPLY16
        ld h,0
        ld l,a                    ; HL = width (zero-extended)
        ld de,(VM_ARR_ELEM_TMP)
        call MATH_MULTIPLY16       ; HL = elem_index * width
        ld de,(VM_STRARR_ADDR_TMP)
        add hl,de                  ; HL = data-base + elem_index*width
        or a                       ; carry clear -- success
        ret

OP_STRARR_LOAD:
        ld hl,(VM_IP)
        ld a,(hl)
        ld (VM_STRARR_INDEX_TMP),a
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (VM_STRARR_COUNT_TMP),de
        inc hl
        ld (VM_IP),hl
        call VM_POP_CHECK_INT
        ld de,(VM_STRARR_COUNT_TMP)
        call VM_ARR_VALIDATE_INDEX
        ld (VM_ARR_ELEM_TMP),hl
        call VM_STRARR_ADDR
        jp c,VM_ERR_ARRAY_BOUNDS  ; never DIM'd
        ; copy the element's own [len][content] record into a fresh
        ; STRTAB temp, same copy-skeleton as BUILTIN_FN_UPPER/LOWER below
        ld (VM_STR_SRC_ADDR_TMP),hl
        call VM_STR_ALLOC_TEMP      ; HL -> dest record, A = new temp index
        ld (VM_STR_DST_ADDR_TMP),hl
        push af
        ld hl,(VM_STR_SRC_ADDR_TMP)
        ld a,(hl)                   ; source (element) length byte
        inc hl
        ld de,(VM_STR_DST_ADDR_TMP)
        ld (de),a
        inc de
        ld b,a
        or a
        jr z,.load_done
.load_copy:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .load_copy
.load_done:
        pop af                   ; NOTE: must stay a plain pop+VM_PUSH here,
                                  ; NOT "call VM_PUSH_STR_RESULT" -- this site
                                  ; falls through to "jp VM_RUN.loop" rather
                                  ; than returning, so a `call` would push a
                                  ; return address on top of this af first and
                                  ; VM_PUSH_STR_RESULT's own `pop af` would
                                  ; grab that return address instead (found by
                                  ; regression: string_arrays FAIL, HOME-
                                  ; budget shrink pass).
        ld l,a
        ld h,0
        jp PUSH_STR_CONTINUE   ; QUAL (Q-02)

OP_STRARR_STORE:
        ld hl,(VM_IP)
        ld a,(hl)
        ld (VM_STRARR_INDEX_TMP),a
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (VM_STRARR_COUNT_TMP),de
        inc hl
        ld (VM_IP),hl
        rst $10                 ; QUAL (Q-02): the value is a string index (TAG_STR for a temp)
        ld a,l
        ld (VM_STRARR_VALUE_IDX_TMP),a  ; STRTAB indices are always small
        call VM_POP_CHECK_INT
        ld de,(VM_STRARR_COUNT_TMP)
        call VM_ARR_VALIDATE_INDEX
        ld (VM_ARR_ELEM_TMP),hl
        call VM_STRARR_ADDR
        jp c,VM_ERR_ARRAY_BOUNDS
        ld (VM_STRARR_ADDR_TMP),hl      ; dest element address, parked
                                           ; across the VM_STR_ADDR call
                                           ; below (VM_STRARR_ADDR's own
                                           ; use of this cell has already
                                           ; finished by this point)
        ld a,(VM_STRARR_VALUE_IDX_TMP)
        call VM_STR_ADDR          ; HL -> source STRTAB record
        ld a,(hl)                 ; source length
        inc hl                    ; HL -> source content
        ld c,a                    ; C = source length, clamped next
        ld a,(VM_STRARR_WIDTH_TMP)
        dec a                     ; A = max content bytes (width-1)
        cp c
        jr nc,.store_len_ok
        ld c,a                    ; clamp to this array's own element width
.store_len_ok:
        ld de,(VM_STRARR_ADDR_TMP)
        ld a,c
        ld (de),a                 ; dest length byte = clamped length
        inc de
        ld b,c
        ld a,b
        or a
        jr z,.store_done
.store_copy:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .store_copy
.store_done:
        jp VM_RUN.loop

; OP_DIM_STR -- DIM A$(n,w)'s own runtime allocation, mirroring OP_DIM
; exactly (same arena/exhaustion-check/pointer-table shape) with one
; extra operand byte (the per-element width) and a 1-byte-wider header
; ([dim_count:1][count:2][width:1][data...], STRARR_DESC_DATA_OFF=4
; instead of ARR_DESC_DATA_OFF=3). Operand: [array_index:1][count:2]
; [width:1].
; ARENA_ALLOC_STRING -- shared string-array arena allocation core,
; factored out of OP_DIM_STR below for the same reason ARENA_ALLOC_
; NUMERIC was (Dynamic Data Phase 2 array SAVE/LOAD reuses it via
; cross-bank binding). Input: A = array index, DE = requested element
; count, C = per-element width. Output/error-handling: same "tail-jumps
; to VM_ERR_ARRAY_SPACE, which itself returns normally either way"
; contract ARENA_ALLOC_NUMERIC's own header explains in full. Destroys:
; AF, BC, DE, HL.
ARENA_ALLOC_STRING:
        ld (VM_STRARR_INDEX_TMP),a
        ld (VM_STRARR_COUNT_TMP),de  ; DE = requested element count
        ld a,c
        ld (VM_STRARR_WIDTH_TMP),a    ; A = requested per-element width
                                        ; (kept in memory, not on the Z80
                                        ; stack, across the space-check
                                        ; exit below -- a stack push left
                                        ; unbalanced on the exhaustion
                                        ; exit path would be a real bug,
                                        ; same "balance every exit path"
                                        ; discipline this codebase
                                        ; already applies elsewhere)
        ; needed = 4 (header) + count*width -- count*width computed ONCE
        ; here and cached in VM_STRARR_ADDR_TMP (free at this point; its
        ; own use by VM_STRARR_ADDR/OP_STRARR_STORE happens on a later,
        ; separate opcode dispatch), reused below for the arena bump
        ; instead of calling MATH_MULTIPLY16 a second time.
        ld h,0
        ld l,a                        ; HL = width
        ld de,(VM_STRARR_COUNT_TMP)
        call VM_MUL_CHECKED            ; QUAL (Q-04): count*width overflow -> OUT OF MEMORY
        jp c,VM_ERR_ARRAY_SPACE         ; (MATH_MULTIPLY16 truncated: a small block for a big array)            ; HL = count*width
        ld (VM_STRARR_ADDR_TMP),hl
        ld de,STRARR_DESC_DATA_OFF
        add hl,de                       ; + header -- HL = needed byte total
        call VM_ARENA_FIT                ; main pool, else segment 2 (swapped in)
        jp nc,VM_ERR_ARRAY_SPACE           ; fits neither
        ; write the descriptor at the OLD ARRAYS_END
        ld hl,(ARRAYS_END)
        ld (hl),1                         ; dim_count=1 (reserved, same as
                                             ; numeric OP_DIM)
        inc hl
        ld de,(VM_STRARR_COUNT_TMP)
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld a,(VM_STRARR_WIDTH_TMP)
        ld (hl),a
        ; record this array's own descriptor address (the OLD ARRAYS_
        ; END) in STRARR_PTR_TABLE[array_index]
        ld de,(ARRAYS_END)
        ld a,(VM_STRARR_INDEX_TMP)
        ld l,a
        ld h,0
        add hl,hl
        ld bc,(RT_STRARRPTR_PTR)
        add hl,bc
        ld (hl),e
        inc hl
        ld (hl),d
        ; bump ARRAYS_END past the whole descriptor
        ld hl,(ARRAYS_END)
        ld de,STRARR_DESC_DATA_OFF
        add hl,de
        ld de,(VM_STRARR_ADDR_TMP)        ; count*width, cached above
        add hl,de
        ld (ARRAYS_END),hl
        jp VM_ARENA_DONE

; VM_ARENA_FIT -- R10.7 P5.4. HL = bytes needed. Carry SET if they fit: first in
; the main pool (ARRAYS_END + needed < VM_CSP), else in segment 2, in which case
; ARRAYS_END and ARR2_END are exchanged so the allocator's unchanged code
; allocates there; VM_ARENA_DONE exchanges them back. Carry clear: fits neither.
VM_ARENA_FIT:
        push hl
        ld de,(ARRAYS_END)
        add hl,de
        ccf                     ; QUAL (Q-04): a 16-bit overflow means "does not fit"
        jr nc,.main_done        ; (it used to wrap and look like room)
        ld de,(VM_CSP)
        or a
        sbc hl,de
.main_done:
        pop hl
        ret c
        ld de,(ARR2_END)
        add hl,de
        ccf                     ; QUAL (Q-04): segment 2 sits at $E000, so any request over
        ret nc                  ; ~8 KB wrapped past $FFFF and was zero-filled over the stack
        ld de,ARR2_LIMIT
        or a
        sbc hl,de               ; (end of segment is exclusive: equal is full)
        ret nc
        ld a,1
        ld (ARR2_SWAPPED),a
        call VM_ARENA_SWAP
        scf
        ret

VM_ARENA_DONE:
        ld a,(ARR2_SWAPPED)
        or a
        ret z
        xor a
        ld (ARR2_SWAPPED),a
VM_ARENA_SWAP:
        ld hl,(ARRAYS_END)
        ld de,(ARR2_END)
        ld (ARRAYS_END),de
        ld (ARR2_END),hl
        ret

; ---------------------------------------------------------------------------
; R8.5 Group 2 (closed out late) -- INPUT. Both opcodes carry a 1-byte
; operand (the target SYMTAB/STRTAB index, resolved at compile time the
; same way as a bare assignment's own target). Echo reuses
; GFX_PRINT_STRING_ATTR (the exact same primitive VM_PRINT_COMMON
; already validated) one character at a time -- not a new echo
; primitive, not V1's own KTAB_BASIC_INPUT_SERVICE.
; ---------------------------------------------------------------------------

OP_INPUT_NUM:                   ; RC (Q-15/Q-16): the typed text ('-' first, digits, '.') is
        ld hl,(VM_IP)           ; collected in PRINT_BUF and read by the shared number parser:
        ld a,(hl)               ; 1.5 is 1.5 (was 15), 99999 is 99999 (was -31073)
        ld (VM_INPUT_TARGET_TMP),a
        inc hl
        ld (VM_IP),hl
        xor a
        ld (VM_INPUT_COUNT),a
.loop:
        call IO_READ_KEY        ; A = translated key code
        cp KEY_ENTER
        jr z,.done
        ld c,a
        ld a,(VM_INPUT_COUNT)
        cp VM_INPUT_TEXT_MAX
        jr nc,.loop
        ld b,a
        ld a,c
        cp '-'
        jr nz,.not_minus
        ld a,b
        or a
        jr nz,.loop             ; '-' only as the first character
        ld a,c
        jr .accept
.not_minus:
        cp '.'
        jr z,.accept
        cp '0'
        jr c,.loop
        cp '9'+1
        jr nc,.loop
.accept:
        ld hl,PRINT_BUF
        ld e,b
        ld d,0
        add hl,de
        ld (hl),a
        inc b
        ld e,a
        ld a,b
        ld (VM_INPUT_COUNT),a
        ld a,e
.echo:
        ld (VM_INPUT_CHARBUF),a
        xor a
        ld (VM_INPUT_CHARBUF+1),a
        call VM_COMPUTE_PRINT_ATTR   ; A = attr byte
        ld e,a
        ld a,(VM_OUTPUT_ROW)
        ld b,a
        ld a,(VM_OUTPUT_COL)
        ld c,a
        ld a,(CURRENT_OVER)
        ld d,a
        ld a,e
        ld hl,VM_INPUT_CHARBUF
        call GFX_PRINT_STRING_ATTR
        ld a,b
        ld (VM_OUTPUT_ROW),a
        ld a,c
        ld (VM_OUTPUT_COL),a
        jr .loop
.done:
        ld a,(VM_INPUT_COUNT)
        ld b,a
        ld hl,PRINT_BUF
        call NUM_PARSE_CALC
        call NUM_PUSH_CALC
        ld a,(VM_INPUT_TARGET_TMP)
        call VM_STORE_VAR_BY_INDEX   ; INT or FLOAT
        call VM_ADVANCE_OUTPUT_ROW
        jp VM_RUN.loop

OP_INPUT_STR:
        ld hl,(VM_IP)
        ld a,(hl)
        ld (VM_INPUT_TARGET_TMP),a
        inc hl
        ld (VM_IP),hl
        call VM_STR_ADDR           ; HL -> record [len][content..]
        inc hl                      ; HL -> content start
        ld (VM_INPUT_STR_PTR),hl
        xor a
        ld (VM_INPUT_COUNT),a
.loop:
        call IO_READ_KEY
        cp KEY_ENTER
        jr z,.done
        cp $20                       ; accept printable ASCII only --
        jr c,.loop                    ; same real range check rom/
        cp $7F                         ; exrom_input.asm's own string
        jr nc,.loop                     ; path already used
        ld c,a                          ; save char -- across the bounds
                                          ; check below, not across a call
        ld a,(VM_INPUT_COUNT)
        cp 31
        jr nc,.loop                      ; full -- silently drop (matches
                                           ; rom/exrom_input.asm's own
                                           ; real ".string_full" behavior)
        ld hl,(VM_INPUT_STR_PTR)
        ld (hl),c
        inc hl
        ld (VM_INPUT_STR_PTR),hl
        ld a,(VM_INPUT_COUNT)
        inc a
        ld (VM_INPUT_COUNT),a
        ld a,c
        ld (VM_INPUT_CHARBUF),a
        xor a
        ld (VM_INPUT_CHARBUF+1),a
        call VM_COMPUTE_PRINT_ATTR
        ld e,a
        ld a,(VM_OUTPUT_ROW)
        ld b,a
        ld a,(VM_OUTPUT_COL)
        ld c,a
        ld a,(CURRENT_OVER)
        ld d,a
        ld a,e
        ld hl,VM_INPUT_CHARBUF
        call GFX_PRINT_STRING_ATTR
        ld a,b
        ld (VM_OUTPUT_ROW),a
        ld a,c
        ld (VM_OUTPUT_COL),a
        jr .loop
.done:
        ld a,(VM_INPUT_TARGET_TMP)
        call VM_STR_ADDR
        ld a,(VM_INPUT_COUNT)
        ld (hl),a
        call VM_ADVANCE_OUTPUT_ROW
        jp VM_RUN.loop

; R10.5 shrink: OP_ADD/SUB/MUL/DIV shared a near-identical pop/tag-check
; prologue and (for ADD/SUB/MUL, and DIV's own float_path) a near-identical
; FLOAT-path calculator-stub invocation. Factored into
; VM_PREPARE_BINARY_OPERANDS and VM_FLOAT_BINARY_COMMON below; the latter
; reaches its op-specific CALC_*_STUB indirectly through HL via the
; existing VM_CALL_USR_TRAMPOLINE `jp (hl)` idiom. Behavior unchanged
; (same flags/ops/order); see docs/v2/R10_5_SHRINK.md.
VM_PREPARE_BINARY_OPERANDS:
        rst $10                 ; HL = b, A = tag_b
        ld (VM_FLOAT_B_TAG),a
        ld (VM_FLOAT_B_VAL),hl
        rst $10                 ; HL = a, A = tag_a
        ld (VM_FLOAT_A_TAG),a
        ld (VM_FLOAT_A_VAL),hl
        ld c,a
        ld a,(VM_FLOAT_B_TAG)
        or c                    ; Z iff both operands are INT (tag 0)
        ret

VM_FLOAT_BINARY_COMMON:
        ; entry: HL = address of the CALC_*_STUB to invoke for this op
        push hl
        call VM_CALC_PUSH_AB
        pop hl
        call VM_CALL_USR_TRAMPOLINE   ; indirect call to the stub in HL
        call VM_FLOAT_STORE_RESULT
        jp VM_RUN.loop

; QUAL: VM_CALC_PUSH_AB -- a fresh calculator stack holding [a, b] from VM_FLOAT_A/B_TAG/VAL
; (shared by the float arithmetic, the float compare, DIV and MOD). Destroys AF, BC, DE, HL.
VM_CALC_PUSH_AB:
        xor a
        ld (CALC_SP),a          ; a clean calculator stack: every float op is self-contained
        ld a,(VM_FLOAT_A_TAG)
        ld hl,(VM_FLOAT_A_VAL)
        call VM_FLOAT_PUSH_TAGGED
        ld a,(VM_FLOAT_B_TAG)
        ld hl,(VM_FLOAT_B_VAL)
VM_FLOAT_PUSH_TAGGED:           ; A = tag, HL = value: push it (INT converted)
        ld (VM_FLOAT_OPERAND_TAG),a
        ld (VM_FLOAT_OPERAND_VAL),hl
        jp VM_FLOAT_PUSH_OPERAND

OP_ADD:
        call VM_PREPARE_BINARY_OPERANDS
        jr nz,.float_path        ; either operand is FLOAT (R6)
        ld hl,(VM_FLOAT_A_VAL)
        ld de,(VM_FLOAT_B_VAL)
        or a
        adc hl,de               ; STUDY (D11): ADC sets P/V = signed overflow
        jp pe,.float_path       ; promote: the operands are still in VM_FLOAT_A/B_VAL
        ;                         HL = a+b — native 16-bit Z80 add, the
                                 ; integer fast path this whole architecture
                                 ; exists to preserve. Untouched by R6:
                                 ; reached only when BOTH operands are INT.
        jp PUSH_INT_CONTINUE
.float_path:
        ld hl,VM_CALC_ADD_STUB
        jr VM_FLOAT_BINARY_COMMON

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
        call VM_PREPARE_BINARY_OPERANDS
        jr nz,.float_path
        ld hl,(VM_FLOAT_A_VAL)
        ld de,(VM_FLOAT_B_VAL)
        or a
        sbc hl,de               ; HL = a - b
        jp pe,.float_path       ; STUDY (D11): promote on signed overflow
        jp PUSH_INT_CONTINUE
.float_path:
        ld hl,VM_CALC_SUB_STUB
        jr VM_FLOAT_BINARY_COMMON

OP_MUL:
        call VM_PREPARE_BINARY_OPERANDS
        jr nz,.float_path
        ld hl,(VM_FLOAT_A_VAL)
        ld de,(VM_FLOAT_B_VAL)
        call VM_MUL_CHECKED     ; STUDY (D11): MATH_MULTIPLY16 with overflow detection
        jp c,.float_path        ; promote
        jp PUSH_INT_CONTINUE
        ; (old text) existing, already-verified platform
                                 ; primitive (kernel/math/math.asm) — reused,
                                 ; not reimplemented. Overflow silently
                                 ; truncates here, same as the primitive's
                                 ; own documented behavior; auto-promotion
                                 ; on overflow remains deferred (a separate,
                                 ; not-yet-built refinement — this
                                 ; milestone's own scope is composable
                                 ; float arithmetic when a value is
                                 ; ALREADY float-tagged, not auto-promoting
                                 ; on integer overflow)
        jp PUSH_INT_CONTINUE
.float_path:
        ld hl,VM_CALC_MUL_STUB
        jp VM_FLOAT_BINARY_COMMON

; OP_DIV — R6 addition changes this opcode's shape: even with two plain
; INT operands, the result must STAY FLOAT when the division is inexact
; (matching NUMERIC_DESIGN.md's design, e.g. "5/2" -> 2.5, not 2). Rather
; than routing every integer division through the calculator (V1's own
; precedent, per that document — a real but avoidable cost), this tries
; the existing fast MATH_DIVIDE16 path first, then CHEAPLY verifies
; exactness by multiplying the quotient back (MATH_UMUL16-based,
; native Z80) — only falling back to a real float divide via the
; calculator on the (presumably less common) inexact case. Exact
; divisions, which is most of them in ordinary integer-heavy programs,
; never touch the calculator at all.
OP_DIV:
        call VM_PREPARE_BINARY_OPERANDS
        jr nz,.float_path        ; either operand already FLOAT-tagged
        ld hl,(VM_FLOAT_B_VAL)
        ld a,h
        or l
        jp z,VM_ERR_DIVIDE_BY_ZERO   ; real, caught error — a deliberate
                                      ; improvement over V1's silent 0
                                      ; (V2_LANGUAGE_SPEC.md's already-
                                      ; planned fix)
        ld hl,(VM_FLOAT_A_VAL)
        ld de,(VM_FLOAT_B_VAL)
        call VM_DIV16_CHECKED   ; QUAL (D11-EXT): -32768 / -1 -> carry
        jr c,.inexact
                                 ; primitive — truncates toward zero
        ld (VM_DIV_QUOTIENT_TMP),hl
        ld de,(VM_FLOAT_B_VAL)
        call MATH_MULTIPLY16    ; HL = quotient*divisor (exactness check)
        ld de,(VM_FLOAT_A_VAL)
        or a
        sbc hl,de
        jr nz,.inexact           ; quotient*divisor != dividend -> inexact
        ld hl,(VM_DIV_QUOTIENT_TMP)
        jp PUSH_INT_CONTINUE
.inexact:
        jp VM_DIV_VIA_FLOAT
.float_path:
        ; R10 correction (V2_SEMANTIC_CAPABILITY_AUDIT.md matrix row 7):
        ; a FLOAT-tagged zero divisor is now caught here too, via the
        ; shared VM_FLOAT_TEST_ZERO helper (same packed-float sign/zero
        ; encoding VM_NUM_TO_TEXT's own float-sign code already reads),
        ; closing the previously documented, deliberately deferred gap.
        ld a,(VM_FLOAT_B_TAG)
        ld hl,(VM_FLOAT_B_VAL)
        call VM_FLOAT_TEST_ZERO
        jp z,VM_ERR_DIVIDE_BY_ZERO
        ld hl,VM_CALC_DIV_STUB
        jp VM_FLOAT_BINARY_COMMON

OP_CMP_LT:
        call VM_CMP_DISPATCH     ; A = 0 if a=b, 1 if a>b, $FF if a<b
        ld hl,0
        cp $FF
        jr nz,.not_less
        inc l                   ; HL = 1 (true)
.not_less:
        jp PUSH_INT_CONTINUE

OP_CMP_EQ:
        call VM_CMP_DISPATCH     ; A = 0 if a=b
        ld hl,0
        or a
        jr nz,.not_equal
        inc l                   ; HL = 1 (true)
.not_equal:
        jp PUSH_INT_CONTINUE

; ===========================================================================
; R8.5 Group 3 -- the remaining relops (<=, >, >=, <>) OP_CMP_LT/EQ never
; needed, plus AND/OR/NOT. R10 correction: all six relops now route
; through VM_CMP_DISPATCH, which adds real FLOAT-operand support (see
; that routine's own header) -- AND/OR/NOT keep their original int-only
; restriction unchanged (boolean-operand FLOAT semantics were not part
; of the audit's finding and are a separate, unscoped question).
; ===========================================================================
OP_CMP_LE:
        call VM_CMP_DISPATCH     ; A = 0 if a=b, 1 if a>b, $FF if a<b
        ld hl,0
        cp 1
        jr z,.not_le            ; true unless a>b
        inc l
.not_le:
        jp PUSH_INT_CONTINUE

OP_CMP_GT:
        call VM_CMP_DISPATCH
        ld hl,0
        cp 1
        jr nz,.not_gt
        inc l
.not_gt:
        jp PUSH_INT_CONTINUE

OP_CMP_GE:
        call VM_CMP_DISPATCH
        ld hl,0
        cp $FF
        jr z,.not_ge             ; true unless a<b
        inc l
.not_ge:
        jp PUSH_INT_CONTINUE

OP_CMP_NE:
        call VM_CMP_DISPATCH
        ld hl,0
        or a
        jr z,.not_ne
        inc l
.not_ne:
        jp PUSH_INT_CONTINUE

OP_AND:
        rst $10                 ; HL = b, A = tag_b
        ld c,a
        push hl
        rst $10                  ; HL = a, A = tag_a
        or c
        jp nz,VM_ERR_FLOAT_NOT_IMPLEMENTED
        pop de                   ; DE = b
        ld a,h
        or l
        jr z,.false               ; a == 0 -> false regardless of b
        ld a,d
        or e
        jr z,.false                ; b == 0 -> false
        ld hl,1
        jr .push
.false:
        ld hl,0
.push:
        jp PUSH_INT_CONTINUE

OP_OR:
        rst $10
        ld c,a
        push hl
        rst $10
        or c
        jp nz,VM_ERR_FLOAT_NOT_IMPLEMENTED
        pop de
        ld a,h
        or l
        jr nz,.true
        ld a,d
        or e
        jr nz,.true
        ld hl,0
        jr .push
.true:
        ld hl,1
.push:
        jp PUSH_INT_CONTINUE

OP_NOT:
        rst $10                  ; HL = value, A = tag
        call VM_FLOAT_TEST_ZERO  ; RC: a FLOAT is true when nonzero (was error 4)
        ld hl,0
        jr nz,.push
        inc l
.push:
        jp PUSH_INT_CONTINUE

; RC (L-SC): OP_AND_SC / OP_OR_SC (opcodes 72/73), operand: a 2-byte target. The left operand of
; AND (OR) is popped; when it already decides the result -- false for AND, true for OR -- that
; result (0 or 1) is pushed and execution jumps past the right operand, which is then never
; evaluated; otherwise execution continues into the right operand (compiled as `b NOT NOT`).
OP_AND_SC:
        xor a
        jr VM_LOGIC_SC
OP_OR_SC:
        ld a,1
VM_LOGIC_SC:
        push af
        rst $10                  ; HL = a, A = tag
        call VM_FLOAT_TEST_ZERO
        ld hl,0
        jr z,.t
        inc l                    ; HL = the truth of a (0/1)
.t:
        pop af
        cp l
        jp nz,OP_JMPZ.no_branch  ; not decided: on to the right operand
        xor a                    ; TAG_INT
        call VM_PUSH
        jp OP_JMP

OP_JMPZ:
        rst $10                 ; HL = condition value, A = tag (not
                                 ; re-checked here; a boolean from CMP_*
                                 ; or any int value is a legal condition,
                                 ; same "any nonzero is true" rule V1 uses)
        call VM_FLOAT_TEST_ZERO ; QUAL (Q-06): a FLOAT condition is tested by value (was: its slot index)
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

; QUAL (Q-07/Q-19/Q-20; owner decision 1: floating-point FOR): a FOR frame holds the loop's OWN
; state, [T_FOR][var][limit:5][step:5]. The limit and the step are kept in the calculator's 5-byte
; form -- an INT in its small-integer form [0][sign][lo][hi][0] -- so a FLOAT bound needs no second
; frame type and every frame walker keeps one length. NEXT v finds its own frame (dropping loops
; abandoned by GOTO above it); FOR v replaces a stale frame of the same variable; FOR skips the body
; when the start is already past the limit (the 2-byte operand is linked into the loop's EXIT chain
; by the compiler, so it lands on the loop's FOR_POP).
; Semantics (the VM's own rules, nothing FOR-specific): FOR stores the start like an assignment;
; NEXT computes v = v + step like ADD (INT + INT stays INT and promotes to FLOAT on overflow; any
; FLOAT operand gives FLOAT) and compares v with the limit like the relational operators. The loop
; is over when v is past the limit in the direction of the step's sign; a zero step counts as
; ascending (the documented endless loop while v <= limit; BREAK stops it). A float loop variable
; accumulates the step by repeated addition, as in Sinclair BASIC.
VM_FOR_FRAME_LEN:   equ 12
VM_FOR_FRM:         equ VM_FOR_LIMIT        ; scratch: the current loop's frame (2 B)
VM_FOR_DST:         equ VM_FOR_STEP         ; scratch: VM_FOR_POP5_AT's destination (2 B)

; VM_FIND_FOR -- C = loop variable. Walks the run of FOR frames on top of the control stack.
; Out: Z and HL = that loop's frame; NZ = not found (another kind of frame, or the bottom).
; Destroys AF, DE, HL.
VM_FIND_FOR:
        ld hl,(VM_CSP)
.l:
        ld de,(VARS_START)
        or a
        sbc hl,de
        jr z,.none
        add hl,de
        ld a,(hl)
        cp T_FOR
        ret nz
        inc hl
        ld a,(hl)
        dec hl
        cp c
        ret z
        ld de,VM_FOR_FRAME_LEN
        add hl,de
        jr .l
.none:
        or $FF                  ; NZ
        ret

OP_FOR_INIT:
        ld hl,(VM_IP)
        ld c,(hl)               ; C = loop variable
        inc hl
        ld (VM_IP),hl           ; VM_IP -> the 2-byte skip operand
        call VM_FIND_FOR
        jr nz,.fresh
        ld de,VM_FOR_FRAME_LEN  ; re-entered: drop the old frame of this variable and
        add hl,de               ; any loop abandoned above it
        ld (VM_CSP),hl
.fresh:
        ld a,VM_FOR_FRAME_LEN
        call VM_CS_ALLOC        ; HL = new frame (C survives)
        jp c,VM_ERR_CALL_STACK_OVERFLOW
        ld (VM_FOR_FRM),hl
        ld (hl),T_FOR
        inc hl
        ld (hl),c
        ld de,6
        add hl,de               ; -> frame+7
        call VM_FOR_POP5_AT     ; step
        ld hl,(VM_FOR_FRM)
        inc hl
        inc hl                  ; -> frame+2
        call VM_FOR_POP5_AT     ; limit
        call VM_FOR_VAR
        call VM_STORE_VAR_BY_INDEX   ; v = start (INT or FLOAT, as an assignment)
        call VM_FOR_PAST
        dec a
        jp z,OP_JMP             ; already past the limit: skip the body (to FOR_POP)
        jp OP_JMPZ.no_branch    ; run the body: step over the operand

OP_FOR_NEXT:
        ld hl,(VM_IP)
        ld c,(hl)               ; loop variable symbol index
        inc hl
        ld e,(hl)               ; branch target low
        inc hl
        ld d,(hl)               ; branch target high
        inc hl
        ld (VM_IP),hl
        ld (VM_FOR_NEXT_BRANCH),de
        call VM_FIND_FOR        ; QUAL: this loop's own frame
        jp nz,VM_ERR_CALL_STACK_UNDERFLOW  ; NEXT without its FOR (GOTO into a body, a FOR skipped by IF)
        ld (VM_CSP),hl          ; drop loops abandoned above it by GOTO
        ld (VM_FOR_FRM),hl
        ld a,c
        call VM_FOR_LOAD_VA     ; A = v's tag, DE = its value, HL -> value+1
        dec hl
        ld (VM_FOR_NEXT_VALADDR),hl
        ld hl,(VM_FOR_FRM)
        ld bc,7
        add hl,bc               ; -> step
        or (hl)                 ; zero iff v is INT and the step a 16-bit integer
        jr nz,.calc_add
        inc hl
        inc hl
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a                  ; HL = step
        ld b,h                  ; B = the step's high byte (its sign, kept for the compare)
        or a
        adc hl,de               ; HL = v + step
        jp pe,.calc_add         ; signed overflow: the FLOAT sum (D11 promotion)
        ex de,hl                ; DE = v + step
        ld hl,(VM_FOR_NEXT_VALADDR)
        ld (hl),e
        inc hl
        ld (hl),d               ; v = v + step, still INT
        ld hl,(VM_FOR_FRM)
        inc hl
        inc hl                  ; -> limit
        ld a,(hl)
        or a
        jr nz,.test             ; a FLOAT limit: the general compare
        inc hl
        inc hl
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a                  ; HL = limit
        ex de,hl                ; HL = v, DE = limit
        call MATH_COMPARE16     ; the all-INT fast path: a 16-bit compare (B survives)
        bit 7,b
        jr z,.decide
        neg                     ; counting down: "past" means v < limit
        jr .decide
.calc_add:
        xor a
        ld (CALC_SP),a
        call VM_FLOAT_PUSH_OPERAND   ; v (VM_FOR_LOAD_V left it in VM_FLOAT_OPERAND_*)
        ld hl,(VM_FOR_FRM)
        ld de,7
        add hl,de
        call VM_FLOAT_PUSH_RAW       ; step
        call VM_CALC_ADD_STUB
        call VM_FLOAT_STORE_RESULT   ; the sum, as a FLOAT temp on the operand stack
        call VM_FOR_VAR
        call VM_STORE_VAR_BY_INDEX   ; v = the sum
.test:
        call VM_FOR_PAST
.decide:
        dec a
        jp z,VM_RUN.loop        ; past the limit: fall through to FOR_POP
        ld de,(VM_FOR_NEXT_BRANCH)
        ld hl,VM_CODE_BASE
        add hl,de
        ld (VM_IP),hl
        jp VM_RUN.loop

; VM_FOR_VAR -- A = the current loop's variable (from VM_FOR_FRM). Destroys HL.
VM_FOR_VAR:
        ld hl,(VM_FOR_FRM)
        inc hl
        ld a,(hl)
        ret

; VM_FOR_LOAD_V -- the loop variable's tag and value into VM_FLOAT_OPERAND_TAG/VAL.
; Out: A = tag, DE = value, HL -> the record's value high byte. Destroys AF, DE, HL.
VM_FOR_LOAD_V:
        call VM_FOR_VAR
VM_FOR_LOAD_VA:                 ; entry with A = the variable
        call VM_SYM_ADDR
        ld a,(hl)
        ld (VM_FLOAT_OPERAND_TAG),a
        inc hl
        ld e,(hl)
        inc hl
        ld d,(hl)
        ld (VM_FLOAT_OPERAND_VAL),de
        ret

; VM_FOR_PAST -- is the loop variable past the limit, in the direction of the step's sign?
; Out: A = 1 past, else 0 or $FF. Destroys AF, BC, DE, HL.
VM_FOR_PAST:
        call VM_FOR_LOAD_V
        ld hl,(VM_FOR_FRM)
        inc hl
        inc hl                  ; -> limit
        or (hl)                 ; zero iff v is INT and the limit a 16-bit integer
        jr nz,.calc
        inc hl
        inc hl
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a                  ; HL = limit
        ex de,hl                ; HL = v, DE = limit
        call MATH_COMPARE16     ; A = $FF v<limit, 0 equal, 1 v>limit
        jr .dir
.calc:
        push hl
        xor a
        ld (CALC_SP),a
        call VM_FLOAT_PUSH_OPERAND   ; v
        pop hl
        call VM_FLOAT_PUSH_RAW       ; limit
        call VM_CALC_SUB_STUB        ; v - limit
        call VM_CALC_CLASSIFY
.dir:
        ld hl,(VM_FOR_FRM)
        ld de,8
        add hl,de               ; -> step byte 1: bit 7 is the sign in both forms
        bit 7,(hl)
        ret z
        neg                     ; counting down: "past" means v < limit
        ret

; VM_FOR_POP5_AT -- pops a numeric operand and writes it at HL in the calculator's 5-byte form.
; Destroys AF, BC, DE, HL.
VM_FOR_POP5_AT:
        ld (VM_FOR_DST),hl
        rst $10                 ; HL = value, A = tag
        cp TAG_FLOAT
        jr z,.float
        ex de,hl                ; DE = INT value
        ld hl,(VM_FOR_DST)
        ld (hl),0               ; small-integer form [0][sign][lo][hi][0]
        inc hl
        ld a,d
        rla
        sbc a,a
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),d
        inc hl
        ld (hl),0
        ret
.float:
        ld a,l
        call VM_FLOAT_ADDR      ; HL -> its 5 bytes
        ld de,(VM_FOR_DST)
        ld bc,FLOAT_REC_LEN
        ldir
        ret

; OP_FOR_POP (opcode 55) -- post-R9 nested FOR/NEXT correction. Pops this
; loop's own VM_FOR_STACK frame, restoring the enclosing loop's VM_FOR_
; LIMIT/STEP (or harmless stale values if this was the outermost loop --
; no consumer reads them again before a fresh OP_FOR_INIT overwrites them).
; The compiler emits this opcode exactly once, right after every compiled
; NEXT; both the loop's own normal fall-through-past-limit exit and any
; EXIT FOR inside it land on this same bytecode address (rom/exrom_v2_
; compiler.asm's COMPILE_NEXT), so the frame is popped exactly once
; regardless of which path exits the loop.
OP_FOR_POP:
        ld hl,(VM_CSP)
        ld a,(hl)
        cp T_FOR
        jp nz,VM_ERR_CALL_STACK_UNDERFLOW
        ld de,VM_FOR_FRAME_LEN  ; QUAL: no enclosing state to restore any more
        add hl,de
        ld (VM_CSP),hl
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

; ===========================================================================
; STRING OPCODE HANDLERS (R5 addition)
;
; Bytecode operand shapes: OP_PUSH_STR_LIT's operand is VARIABLE length
; (1 length byte + that many content bytes) — the first variable-length
; operand in this VM; every handler below still follows the "advance
; VM_IP by exactly what this opcode consumed" contract other opcodes use,
; it just has to compute how much that is at runtime instead of it being
; fixed.
;
; String "values" live entirely in STRTAB, addressed by a compile-time or
; runtime-computed index; a string reference on the operand stack is that
; index, pushed as a perfectly ordinary TAG_INT 2-byte value via the
; EXISTING VM_PUSH/OP_PUSH_I16 mechanism — no new operand-stack tag was
; needed, since the compiler alone (not the VM) tracks which values are
; "really" string indices, per this milestone's own scoped design (see
; docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R5 section).
; ===========================================================================

OP_PUSH_STR_LIT:
        ld hl,(VM_IP)
        ld a,(hl)               ; length byte (<=31, compiler-guaranteed)
        inc hl
        ld (VM_IP),hl           ; VM_IP -> content start (for now)
        ld (VM_STR_LIT_LEN_TMP),a
        call VM_STR_ALLOC_TEMP  ; QUAL (Q-02): HL -> a temp no stacked value uses, A = its index
        ld (VM_STR_LIT_TEMPIDX_TMP),a
        ld a,(VM_STR_LIT_LEN_TMP)
        ld (hl),a               ; write length byte
        inc hl                  ; HL -> dest content
        ld de,(VM_IP)           ; DE = source content pointer (in bytecode)
        ld a,(VM_STR_LIT_LEN_TMP)
        or a
        jr z,.no_copy
        ld b,a
.copy_loop:
        ld a,(de)
        ld (hl),a
        inc hl
        inc de
        djnz .copy_loop
.no_copy:
                                ; QUAL (Q-28): no NUL any more. A 31-character literal filled the
                                ; 32-byte record and the NUL landed on the NEXT record's length byte
                                ; -- after the last temp slot that is ARR_PTR_TABLE[0]'s low byte
                                ; (array 0 then read/wrote the wrong memory). OP_PRINT_STR now
                                ; prints by the length byte (Q-27).
                                ; (was: xor a / ld (hl),a -- null-terminate the content; HL is
                                  ; still the destination record's write
                                  ; cursor here (real bug found via a real
                                  ; ZEsarUX run: this terminator was never
                                  ; actually written despite this routine's
                                  ; own header comment and OP_PRINT_STR's
                                  ; claiming it was, so GFX_PRINT_STRING_ATTR
                                  ; ran off the end of "WORLD" into
                                  ; whatever stale bytes followed it in the
                                  ; 32-byte record)
        ld hl,(VM_IP)
        ld a,(VM_STR_LIT_LEN_TMP)
        ld e,a
        ld d,0
        add hl,de               ; VM_IP advances past the content bytes
        ld (VM_IP),hl
        ld a,(VM_STR_LIT_TEMPIDX_TMP)
        ld l,a
        ld h,0
        jp PUSH_STR_CONTINUE

OP_STORE_STR_VAR:
        ld hl,(VM_IP)
        ld a,(hl)               ; target string-var index
        inc hl
        ld (VM_IP),hl
        ld (VM_STR_TARGET_TMP),a
        rst $10                 ; HL = source index, A = tag (ignored --
                                 ; this opcode set is string-only end to
                                 ; end for R5's scope)
        ld a,l
        call VM_STR_ADDR        ; HL -> source record
        ld (VM_STR_SRC_ADDR_TMP),hl
        ld a,(VM_STR_TARGET_TMP)
        call VM_STR_ADDR        ; HL -> target record
        ex de,hl                ; DE = target record address
        ld hl,(VM_STR_SRC_ADDR_TMP)
        call VM_STR_COPY        ; copies HL(src) -> DE(dst), 32 bytes
        jp VM_RUN.loop

OP_STR_CONCAT:
        call VM_STR_ALLOC_TEMP  ; QUAL (Q-02): destination picked while both operands are still on
        ld (VM_STR_DST_ADDR_TMP),hl ; the stack, so it is neither of them (b must survive the copy of a)
        ld (VM_STR_LIT_TEMPIDX_TMP),a
        rst $10                 ; HL = b's index
        ld a,l
        ld (VM_STR_CONCAT_B_TMP),a
        rst $10                 ; HL = a's index
        ld a,l
        call VM_STR_ADDR        ; HL -> a's record
        ld (VM_STR_SRC_ADDR_TMP),hl
        ld hl,(VM_STR_SRC_ADDR_TMP)
        ld a,(hl)               ; a's length
        ld c,a                  ; C = running combined length so far
        inc hl                  ; HL -> a's content
        ld de,(VM_STR_DST_ADDR_TMP)
        inc de                  ; DE -> dest content (length byte written last)
        ld b,a
        or a
        jr z,.a_copy_done
.a_copy_loop:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .a_copy_loop
.a_copy_done:
        ld (VM_STR_RUNNING_DST_TMP),de  ; DE must not survive the next
                                           ; call across a register —
                                           ; VM_STR_ADDR uses DE as its own
                                           ; scratch internally (see this
                                           ; cell's own equ comment)
        ld a,(VM_STR_CONCAT_B_TMP)
        call VM_STR_ADDR        ; HL -> b's record
        ld a,(hl)               ; b's length
        inc hl                  ; HL -> b's content
        ld de,(VM_STR_RUNNING_DST_TMP)  ; restore the real dest pointer
        ld b,a
        or a
        jr z,.b_copy_done
.b_copy_loop:
        ld a,c
        cp 31
        jr nc,.b_copy_done      ; already at the 31-byte cap: stop, truncate
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        inc c
        djnz .b_copy_loop
.b_copy_done:
                                ; QUAL (Q-28): no NUL (a 31-character result put it past the record)
                                ; (was: xor a / ld (de),a -- null-terminate the combined content --
                                  ; same real bug class as OP_PUSH_STR_LIT's
                                  ; own fix: DE is still the write cursor
                                  ; right after the last copied byte here
        ld hl,(VM_STR_DST_ADDR_TMP)
        ld (hl),c               ; write the final combined length byte
        ld a,(VM_STR_LIT_TEMPIDX_TMP)
        ld l,a
        ld h,0
        jp PUSH_STR_CONTINUE

; RC (L-STR): the six string relations compile to these three opcodes (with NOT for <>, >=, <=).
OP_STR_CMP_GT:                  ; opcode 71
        call VM_STR_POP_COMPARE
        dec a                   ; Z iff a > b
        jr VM_STR_BOOL
OP_STR_CMP_LT:
        call VM_STR_POP_COMPARE
        inc a                   ; Z iff a < b
        jr VM_STR_BOOL
OP_STR_CMP_EQ:
        call VM_STR_POP_COMPARE
        or a                    ; Z iff a = b
VM_STR_BOOL:
        ld hl,0
        jr nz,.f
        inc l
.f:
        jp PUSH_INT_CONTINUE
; VM_STR_POP_COMPARE -- pops b then a (string indexes): A = 0 / 1 / $FF for a = / > / < b.
VM_STR_POP_COMPARE:
        rst $10                 ; HL = b's index
        ld a,l
        call VM_STR_ADDR        ; HL -> b's record
        ld (VM_STR_RUNNING_DST_TMP),hl
        rst $10                 ; HL = a's index
        ld a,l
        call VM_STR_ADDR        ; HL -> a's record
        ld de,(VM_STR_RUNNING_DST_TMP)
        jp VM_STR_COMPARE

; VM_STR_COMPARE — input: HL = a's record address, DE = b's record address.
; Output: A = 0 if equal, 1 if a>b, $FF if a<b (matches MATH_COMPARE16's
; own convention, for consistency). Lexicographic content comparison over
; min(lenA,lenB) bytes; ties broken by length (the shorter string is
; "less" when one is a prefix of the other, standard lexicographic order).
VM_STR_COMPARE:
        ld a,(hl)
        ld (VM_STRCMP_LENA_TMP),a
        ex de,hl                ; QUAL (Q-01): was push hl / ex de,hl / ... / pop hl, which left
        ld a,(hl)               ; DE = HL = A, so the content loop compared A with itself and
        ld (VM_STRCMP_LENB_TMP),a ; only the length tiebreak decided ("abc" = "xyz").
        ex de,hl                ; HL = A, DE = B again (same size: ex/ex instead of push/pop)
        ld a,(VM_STRCMP_LENA_TMP)
        ld b,a
        ld a,(VM_STRCMP_LENB_TMP)
        cp b
        jr c,.b_smaller
        ld a,b                  ; lenA <= lenB: minlen = lenA
        jr .have_min
.b_smaller:
        ld a,(VM_STRCMP_LENB_TMP)  ; minlen = lenB
.have_min:
        ld (VM_STRCMP_MINLEN_TMP),a
        inc hl                    ; HL -> a's content
        inc de                    ; DE -> b's content
        ld a,(VM_STRCMP_MINLEN_TMP)
        or a
        jr z,.tiebreak
        ld b,a
.cmp_loop:
        ld a,(de)                 ; A = b's byte
        cp (hl)                   ; compare against a's byte
        jr z,.equal_byte
        jr c,.a_greater           ; b_byte < a_byte -> a_byte > b_byte
        ld a,$FF                  ; b_byte > a_byte -> a_byte < b_byte
        ret
.a_greater:
        ld a,1
        ret
.equal_byte:
        inc hl
        inc de
        djnz .cmp_loop
.tiebreak:
        ld a,(VM_STRCMP_LENA_TMP)
        ld b,a
        ld a,(VM_STRCMP_LENB_TMP)
        cp b
        jr z,.tie_equal
        jr c,.tie_a_greater        ; lenB < lenA -> a has a longer, equal
                                     ; prefix -> a is greater
        ld a,$FF                   ; lenB > lenA -> a is a proper prefix of
                                     ; b -> a is less
        ret
.tie_a_greater:
        ld a,1
        ret
.tie_equal:
        xor a
        ret

; ===========================================================================
; FLOATING-POINT SUPPORT (R6 addition) — reuses the REAL, existing
; calculator (rom/exrom_calc.asm) via its documented CALC_INT_TO_FP
; converter and its RST $28 literal-stream mechanism, the exact same
; entry points basic/basic.asm's own "/" operator already uses in
; production (NUMERIC_DESIGN.md, VERIFIED). This module does NOT
; reimplement float arithmetic — it calls the real engine, copies its
; results into FLOATTAB, and never inspects a float's actual bytes.
;
; A note on how RST $28 reaches the calculator from a standalone test
; image with no real HOME/EXROM paging: see rom/test_v2_compiler_r6.asm's
; own header for the one small, explicitly-labeled stand-in this requires
; (a trivial `KTAB_CALC_EXIT_TRAMPOLINE: ret`, replacing the real
; production build's page-back-in-then-return jump-table indirection,
; which has nothing to page in a flat single-bank test image). Nothing
; about the calculator's own arithmetic is stubbed — only the one HOME-
; side return hook a real paged build would provide differently.
; ===========================================================================

; VM_FLOAT_ADDR — index (A) -> HL = record address (FLOATTAB_BASE + index*5).
VM_FLOAT_ADDR:
        ld l,a
        ld h,0
        ld d,h
        ld e,l
        add hl,hl               ; *2
        add hl,hl               ; *4
        add hl,de               ; *5
        ld de,(RT_FLOATTAB_PTR)
        add hl,de
        ret

; VM_FLOAT_PUSH_OPERAND — input: VM_FLOAT_OPERAND_TAG/VAL. Pushes the
; operand onto the REAL calculator's own CALC_STACK: converts a plain INT
; via CALC_INT_TO_FP, or copies an existing FLOATTAB entry's raw 5 bytes
; directly (a FLOAT operand's "value" is always a FLOATTAB index).
VM_FLOAT_PUSH_OPERAND:
        ld a,(VM_FLOAT_OPERAND_TAG)
        cp TAG_FLOAT
        jr z,.is_float
        ld hl,(VM_FLOAT_OPERAND_VAL)
        jp CALC_INT_TO_FP
.is_float:
        ; BUG FOUND (real hardware, R6): holding the source address in HL
        ; across the CALC_SP_TO_NEXT_FREE_PTR call below silently corrupted
        ; every mixed int/float ADD (e.g. Y=A+0.5 came out 6.0, not 3.5) —
        ; CALC_SP_TO_NEXT_FREE_PTR's own header documents "Destroys: AF,
        ; BC, DE, HL", and its real body ends with `ex de,hl`, which hands
        ; back whatever HL/DE happened to hold on ENTRY (here: DE was left
        ; = CALC_STACK by the ldir this same routine ran on the FIRST
        ; operand a moment earlier), not the source address computed just
        ; above. The ldir then silently copied the FIRST operand's own
        ; just-pushed bytes over itself instead of the second operand's
        ; real float data. Exact same register-clobber-across-a-call bug
        ; class as OP_STORE_VAR's and the R6 test driver's own fix — this
        ; is the third real instance of it found this milestone. Fixed the
        ; same way: park the source address in memory, not a register
        ; VM_FLOAT_ADDR's own callee touches.
        ld a,(VM_FLOAT_OPERAND_VAL)   ; low byte only — indices are small
        call VM_FLOAT_ADDR             ; HL -> source float record
VM_FLOAT_PUSH_RAW:                      ; QUAL (float FOR): entry with HL -> any 5-byte value
        ld (VM_FLOAT_SRC_ADDR_TMP),hl   ; park it in this routine's OWN
                                          ; dedicated scratch (see that
                                          ; cell's own header for why not
                                          ; VM_FLOAT_A_VAL/B_VAL)
        call CALC_SP_TO_NEXT_FREE_PTR  ; DE -> dest (next free CALC_STACK slot)
        ld hl,(VM_FLOAT_SRC_ADDR_TMP)    ; recover the real source address
        ld bc,FLOAT_REC_LEN
        ldir
        ld a,(CALC_SP)
        inc a
        ld (CALC_SP),a
        ret

; VM_FLOAT_STORE_RESULT — copies the calculator's own result (always at
; CALC_STACK index 0, since every arithmetic handler below resets
; CALC_SP to 0 before pushing its two operands) into a fresh FLOATTAB
; temp slot, then pushes that slot's index onto the VM's own operand
; stack, TAG_FLOAT.
VM_FLOAT_STORE_RESULT:
        ld a,(RT_NUM_COUNT)
        ld b,FLOATTAB_TEMP_COUNT
        ld e,TAG_FLOAT
        call VM_TEMP_PICK        ; QUAL (Q-02): a float temp no stacked value refers to
        ld (VM_FLOAT_TEMPIDX_TMP),a
        call VM_FLOAT_ADDR       ; HL -> dest temp slot
        ex de,hl                  ; DE = dest
        ld hl,CALC_STACK
        ld bc,FLOAT_REC_LEN
        ldir
        ld a,(VM_FLOAT_TEMPIDX_TMP)
        ld l,a
        ld h,0
        ld a,TAG_FLOAT
        jp VM_PUSH

; VM_CALC_ADD_STUB/SUB/MUL/DIV — invoke the real calculator's own
; already-wired ADD/SUB/MUL/DIV literals (NUMERIC_DESIGN.md, VERIFIED:
; "the calculator's literal opcode set already includes add/sub/mul/
; div") via RST $28, exactly matching basic.asm's own "/" operator
; wiring (`rst $28` / `DB <literal>,$38`). The RST $28 vector at $0028
; and CALC_LITERAL_PTR's own resume mechanism return control to the
; instruction right after the DB bytes — i.e., this stub's own `ret` —
; without ever touching the Z80 hardware stack in between, so the
; caller's own return address (pushed by `call VM_CALC_ADD_STUB` etc.)
; survives untouched.
VM_CALC_ADD_STUB:
        ld b,0
        rst $28
        db $0F,$38              ; add, end-calc
        jr VM_CALC_CHECK
VM_CALC_SUB_STUB:
        ld b,0
        rst $28
        db $03,$38              ; subtract, end-calc
        jr VM_CALC_CHECK
VM_CALC_MUL_STUB:
        ld b,0
        rst $28
        db $04,$38              ; multiply, end-calc
        jr VM_CALC_CHECK
VM_CALC_DIV_STUB:
        ld b,0
        rst $28
        db $05,$38              ; divide, end-calc
; RC: the calculator aborts an operation whose result is beyond the 5-byte range (about 1.7E38) and
; leaves an operand behind; that used to become the result silently (4294967296^4 printed 2^96).
; Now it is runtime error 67, the code the non-promoting builds already use for overflow. A literal
; or VAL/INPUT text that overflows reaches the same check through NUM_PARSE_CALC.
VM_CALC_CHECK:
        ld a,(CALC_ERROR_CODE)
        or a
        ret z
        ld a,67
        jp VM_ERR_COMMON

; VM_DIV_VIA_FLOAT — R10.5 shrink: three call sites (OP_DIV's own inexact-
; quotient fallback, plus two other integer-pair-to-FLOAT-division paths)
; shared this identical "convert both VM_FLOAT_A_VAL/VM_FLOAT_B_VAL to
; FLOAT, divide via the calculator, store result" tail. Entry: caller has
; already set VM_FLOAT_A_VAL/VM_FLOAT_B_VAL (as plain INT16s). Terminal —
; falls straight through to VM_RUN.loop like its call sites always did.
; Behavior unchanged; see docs/v2/R10_5_SHRINK.md.
VM_DIV_VIA_FLOAT:
        xor a
        ld (CALC_SP),a
        ld hl,(VM_FLOAT_A_VAL)
        call CALC_INT_TO_FP
        ld hl,(VM_FLOAT_B_VAL)
        call CALC_INT_TO_FP
        call VM_CALC_DIV_STUB
        call VM_FLOAT_STORE_RESULT
        jp VM_RUN.loop

; VM_FLOAT_TEST_ZERO -- input: A = tag, HL = value (as VM_POP delivers).
; TAG_INT tests HL directly. TAG_FLOAT treats HL as a FLOATTAB index and
; reads the real 5-byte packed record: byte0=0 is the small-int fast
; form (byte1 = sign $00/$FF, bytes2-3 = the 16-bit magnitude -- zero
; only when byte1/2/3 are all zero, confirmed from CALC_INT_TO_FP's own
; body); byte0!=0 is the general form, which this calculator never uses
; to represent exactly zero (CALC_INT_TO_FP/VM_CALC_SUB_STUB's own
; results always normalize 0 to the small-int form), so it is always
; nonzero. Same packed-format reading VM_NUM_TO_TEXT's own float-sign
; code already uses (see that routine's header).
; Out: Z set if the value is exactly zero. Destroys: AF, HL.
VM_FLOAT_TEST_ZERO:
        cp TAG_FLOAT
        jr z,.float
        ld a,h
        or l
        ret
.float:
        ld a,l
        call VM_FLOAT_ADDR       ; HL -> the real 5 packed bytes
        ld a,(hl)                ; byte0
        or a
        ret nz                   ; general form -> never exactly zero
        inc hl
        ld a,(hl)                ; byte1 (sign, small-int form)
        or a
        ret nz
        inc hl
        ld a,(hl)                ; byte2
        inc hl
        or (hl)                  ; A = byte2 | byte3
        ret

; VM_CMP_DISPATCH -- shared int/float relational-compare backend for
; OP_CMP_LT/LE/GT/GE/EQ/NE. Pops its own two operands via the same
; VM_FLOAT_A/B_TAG/VAL convention OP_DIV already established (never
; concurrently live with an arithmetic opcode's own use of those cells,
; since opcodes execute one at a time). Two INT-tagged operands take the
; unchanged MATH_COMPARE16 fast path; either FLOAT-tagged operand takes
; a real calculator subtract (a-b) and classifies the packed result's
; own sign/zero encoding (same layout VM_FLOAT_TEST_ZERO above already
; reads) -- closing the "any FLOAT operand -> VM_ERR_FLOAT_NOT_
; IMPLEMENTED" gap (R10 correction, V2_SEMANTIC_CAPABILITY_AUDIT.md
; matrix row 8).
; Out: A = 0 if a=b, 1 if a>b, $FF if a<b -- the exact MATH_COMPARE16
; contract, so every caller's existing post-compare branch (cp $FF /
; cp 1 / or a) needs no change. Destroys: AF, BC, DE, HL.
VM_CMP_DISPATCH:
        rst $10                  ; HL = b, A = tag_b
        ld (VM_FLOAT_B_TAG),a
        ld (VM_FLOAT_B_VAL),hl
        rst $10                  ; HL = a, A = tag_a
        ld (VM_FLOAT_A_TAG),a
        ld (VM_FLOAT_A_VAL),hl
        ld c,a
        ld a,(VM_FLOAT_B_TAG)
        or c
        jr nz,.float_path
        ld hl,(VM_FLOAT_A_VAL)
        ld de,(VM_FLOAT_B_VAL)
        jp MATH_COMPARE16
.float_path:
        call VM_CALC_PUSH_AB
        call VM_CALC_SUB_STUB     ; CALC_STACK[0] = a-b
VM_CALC_CLASSIFY:                 ; QUAL (float FOR): A = $FF / 0 / 1 for CALC_STACK[0] <0 / =0 / >0
        ld hl,CALC_STACK
        ld a,(hl)
        or a
        jr nz,.general
        inc hl                    ; -> byte1 (sign, small-int form)
        ld a,(hl)
        or a
        jr nz,.neg
        inc hl                    ; -> byte2
        ld a,(hl)
        inc hl                    ; -> byte3
        or (hl)
        jr z,.zero
        jr .pos
.general:
        inc hl                    ; -> byte1 (sign bit, general form)
        ld a,(hl)
        and $80
        jr nz,.neg
.pos:
        ld a,1
        ret
.neg:
        ld a,$FF
        ret
.zero:
        xor a
        ret

; ---------------------------------------------------------------------------
; VM_POP_COERCE_INT -- shared FLOAT/INT type-boundary mechanism (post-R9
; semantic-completion milestone, docs/v2/V2_SEMANTIC_CAPABILITY_AUDIT.md
; S4/S13). Pops one operand exactly like VM_POP, but if it is FLOAT-
; tagged (a FLOATTAB index, NOT the number, if used raw), truncates it
; to a plain 16-bit int via the real calculator -- the SAME technique
; BUILTIN_FN_SIN's own FLOAT fix below already uses and hardware-
; validates (VM_FLOAT_OPERAND_TAG/VAL + VM_FLOAT_PUSH_OPERAND +
; CALC_FP_TO_INT). An INT-tagged operand returns unchanged. Every site
; that wants "a plain integer, converting a FLOAT argument the same way
; INT() does" calls this instead of raw VM_POP, closing the FLOAT-
; operand-misinterpretation bug class with one shared routine instead of
; per-site patches.
; Output: HL = plain 16-bit int (truncated toward zero if the input was
; FLOAT). Destroys: AF, BC, DE (same as VM_FLOAT_PUSH_OPERAND/
; CALC_FP_TO_INT already do) -- callers that need a register to survive
; already park it on the hardware stack, matching every other call in
; this file.
VM_POP_COERCE_INT:
        rst $10                 ; HL = value, A = tag
        cp TAG_FLOAT
        ret nz
VM_COERCE_POPPED:               ; QUAL (Q-32): entry with A = TAG_FLOAT, HL = the popped FLOAT
        call VM_FLOAT_PUSH_FIRST
        jp CALC_FP_TO_INT        ; HL = truncated int

; QUAL (Q-10): VM_FLOAT_PUSH_FIRST -- A = tag, HL = value: a fresh calculator stack holding it.
VM_FLOAT_PUSH_FIRST:
        ld (VM_FLOAT_OPERAND_TAG),a
        ld (VM_FLOAT_OPERAND_VAL),hl
        xor a
        ld (CALC_SP),a
        jp VM_FLOAT_PUSH_OPERAND

; QUAL (Q-32; owner decision 3): VM_POP_ADDR -- an address or a port (POKE, PEEK, USR, IN, OUT).
; An INT is its 16-bit pattern, as before. A FLOAT is truncated and accepted from -32768 to 65535
; (a negative value gives its two's-complement pattern, like an INT); anything else is error 15.
; VM_POP_COERCE_INT saturated every FLOAT above 32767 to 32767, so once D11 promotion made
; `a + 3370` a FLOAT, `POKE a + 3370, v` wrote to address 32767.
; Out: HL = the address. Destroys AF, BC, DE.
VM_POP_ADDR:
        rst $10                 ; HL = value, A = tag
        cp TAG_FLOAT
        ret nz
        push hl
        ld a,l
        call VM_FLOAT_ADDR      ; HL -> its 5 bytes
        ld a,(hl)               ; exponent byte (0 = the small-integer form)
        sub $90
        jr c,.signed            ; |x| < 32768, or the small form: the ordinary conversion
        jr nz,.range            ; |x| >= 65536 (the error unwinds SP, Q-03 fix)
        inc hl
        bit 7,(hl)
        jr nz,.signed           ; -65535..-32768: CALC_FP_TO_INT keeps -32768 and rejects the rest
        pop de
        ld a,(hl)
        or $80                  ; restore the mantissa's implicit top bit
        inc hl
        ld l,(hl)
        ld h,a                  ; HL = 32768..65535, fraction dropped
        ret
.signed:
        pop hl
        ld a,TAG_FLOAT
        call VM_COERCE_POPPED
        ret nc
.range:
        jp BUILTIN_FN_CHR.chr_range_err

; ---------------------------------------------------------------------------
; RC: the shared number parser (literals beyond the 16-bit/value-divisor forms, VAL, INPUT).
; NUM_PARSE_CALC -- HL -> text, B = its length (or 255). Reads [spaces][-|+]digits[.digits] and stops
; at the first other character; no digits = 0. Digits accumulate exactly in the calculator (x*10+d,
; exact up to 2^32); up to 9 fraction digits are kept and divided out once by 10^k (exact, so one
; rounding). Out: CALC_STACK[0] = the value (CALC_SP = 1), HL -> the first character not used,
; NP_FRAC = the number of fraction digits. Destroys AF, BC, DE.
NP_FRAC:        equ VM_INPUT_COUNT
NP_FLAGS:       equ VM_INPUT_NEG_TMP     ; bit 0 '-', bit 1 '.' seen
NUM_PARSE_CALC:
        xor a
        ld (NP_FLAGS),a
        ld (NP_FRAC),a
        ld (CALC_SP),a
        push hl
        push bc
        ld l,a
        ld h,a
        call CALC_INT_TO_FP      ; [0]
        pop bc
        pop hl
        inc b
.skip:
        dec b
        jr z,.end
        ld a,(hl)
        cp ' '
        jr nz,.sign
        inc hl
        jr .skip
.sign:
        cp '+'
        jr z,.adv
        cp '-'
        jr nz,.loop1
        ld a,1
        ld (NP_FLAGS),a
.adv:
        inc hl
        dec b
.loop1:
        inc b
.loop:
        dec b
        jr z,.end
        ld a,(hl)
        cp '.'
        jr nz,.digit
        ld a,(NP_FLAGS)
        bit 1,a
        jr nz,.end               ; a second '.' ends the number
        set 1,a
        ld (NP_FLAGS),a
        jr .next
.digit:
        sub '0'
        cp 10
        jr nc,.end
        ld c,a
        ld a,(NP_FLAGS)
        bit 1,a
        jr z,.acc
        ld a,(NP_FRAC)
        cp 9
        jr nc,.next              ; fraction digits beyond the 9th are ignored
        inc a
        ld (NP_FRAC),a
.acc:
        push hl
        push bc
        ld hl,10
        call CALC_INT_TO_FP
        call VM_CALC_MUL_STUB
        pop bc
        push bc
        ld l,c
        ld h,0
        call CALC_INT_TO_FP
        call VM_CALC_ADD_STUB    ; [x*10 + d]
        pop bc
        pop hl
.next:
        inc hl
        jr .loop
.end:
        push hl
        ld a,(NP_FRAC)
        or a
        jr z,.signed
        push af
        ld hl,1
        call CALC_INT_TO_FP      ; [x, 1] (destroys BC)
        pop bc                   ; B = the fraction digit count
.p10:
        push bc
        ld hl,10
        call CALC_INT_TO_FP
        call VM_CALC_MUL_STUB
        pop bc
        djnz .p10                ; [x, 10^k]
        call VM_CALC_DIV_STUB
.signed:
        ld a,(NP_FLAGS)
        rra
        jr nc,.done
        ld hl,0
        call CALC_INT_TO_FP
        ld b,0
        rst $28
        db $01,$03,$38           ; exchange, subtract: [0 - x]
.done:
        pop hl
        ret

; NUM_PUSH_CALC -- push CALC_STACK[0] (CALC_SP = 1): an INT when NP_FRAC = 0 and it fits, else a FLOAT.
NUM_PUSH_CALC:
        ld a,(NP_FRAC)
        or a
        jp nz,VM_FLOAT_STORE_RESULT
        ld b,0
        rst $28
        db $31,$38               ; duplicate
        call CALC_FP_TO_INT      ; HL; carry = not an INT
        jp c,VM_FLOAT_STORE_RESULT
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH

; OP_PUSH_FLOAT5 (opcode 70) -- RC: a literal as its 5-byte calculator value (operand: 5 bytes).
OP_PUSH_FLOAT5:
        ld hl,(VM_IP)
        ld de,CALC_STACK
        ld bc,5
        ldir
        ld (VM_IP),hl
        call VM_FLOAT_STORE_RESULT
        jp VM_RUN.loop

; OP_PUSH_FLOAT_LIT — operand: 2-byte int value (the literal's digits,
; decimal point removed) + 2-byte divisor (10^number-of-fractional-
; digits, computed by the compiler). Computes value/divisor as a real
; float via the calculator, stores it in a fresh FLOATTAB temp slot,
; pushes that slot's index, TAG_FLOAT.
OP_PUSH_FLOAT_LIT:
        ld hl,(VM_IP)
        ld e,(hl)
        inc hl
        ld d,(hl)               ; DE = value
        inc hl
        ld (VM_FLOAT_A_VAL),de
        ld e,(hl)
        inc hl
        ld d,(hl)               ; DE = divisor
        inc hl
        ld (VM_IP),hl
        ld (VM_FLOAT_B_VAL),de
        jp VM_DIV_VIA_FLOAT

; QUAL (L-C): VM_PUSH_U16 -- HL = 32768..65535, pushed as that FLOAT. Its calculator form is
; exactly [$90][H AND $7F][L][0][0] (exponent 16, the mantissa's top bit is the sign).
VM_PUSH_U16:
        ex de,hl
        ld hl,CALC_STACK
        ld (hl),$90
        inc hl
        ld a,d
        and $7F
        ld (hl),a
        inc hl
        ld (hl),e
        inc hl
        ld (hl),0
        inc hl
        ld (hl),0
        jp VM_FLOAT_STORE_RESULT

; ===========================================================================
; PLATFORM INTEGRATION (R7 addition) — native-call opcodes reaching real,
; UNMODIFIED kernel/graphics primitives (GFX_CLS/GFX_PAINT_ATTR/
; GFX_SET_BORDER/GFX_WRITE_PIXEL), per docs/v2/
; ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R7 scope ("calling convention
; into existing platform modules, no changes to those modules
; themselves"). Deliberately NOT calling into basic/basic.asm's own
; BASIC_STMT_CLS/BASIC_STMT_PLOT/BASIC_COMPUTE_PRINT_ATTR, even though
; those already exist and do the same job for V1: basic.asm is V1's
; language core, which R9 removes outright once V2 covers everything —
; depending on it here would just create a dependency R9 has to unwind
; later. VM_COMPUTE_PRINT_ATTR/VM_CLAMP_Y191 below are instead a small,
; self-contained REWRITE of that language-level logic (ink/paper/inverse/
; bright/flash bit-packing, y-clamping) — genuinely part of the language
; core this whole project is rewriting, not the platform being reused —
; verified to produce bit-identical attribute bytes to V1's own
; BASIC_COMPUTE_PRINT_ATTR (same algorithm, transcribed) so PLOT/CLS's
; VISIBLE result matches V1 exactly, which is this milestone's own
; success gate.
; ===========================================================================

; VM_COMPUTE_PRINT_ATTR — real BASIC_COMPUTE_PRINT_ATTR algorithm
; (basic.asm), transcribed rather than called (see block header above).
; No `call` inside, so no register-clobber risk to audit here.
; Out: A = Spectrum attribute byte (FLASH/BRIGHT/PAPER/INK bit-packed)
; Destroys: AF, BC
VM_COMPUTE_PRINT_ATTR:
        ld a,(CURRENT_INK)
        ld b,a
        ld a,(CURRENT_PAPER)
        ld c,a
        ld a,(CURRENT_INVERSE)
        or a
        jr z,.no_swap
        ld a,b
        ld b,c
        ld c,a
.no_swap:
        ld a,c
        add a,a
        add a,a
        add a,a
        or b
        ld c,a
        ld a,(CURRENT_BRIGHT)
        or a
        jr z,.no_bright
        ld a,c
        or $40
        ld c,a
.no_bright:
        ld a,(CURRENT_FLASH)
        or a
        jr z,.no_flash
        ld a,c
        or $80
        ret
.no_flash:
        ld a,c
        ret

; VM_CLAMP_Y191 — real BASIC_CLAMP_Y191 algorithm (basic.asm),
; transcribed for the same reason as VM_COMPUTE_PRINT_ATTR above.
; In: A = candidate y. Out: A clamped to 0-191. Destroys: AF only.
; RC (DEC-PLOT): out-of-range coordinates clamp to the screen edge (y > 191 already did; x and any
; value above 255 or below 0 wrapped modulo 256 to a wrong position).
VM_CLAMP_YCOORD:                ; HL -> A = 0..191
        call VM_CLAMP_COORD
VM_CLAMP_Y191:
        cp 192
        ret c
        ld a,191
        ret
VM_CLAMP_COORD:                 ; HL -> A = 0..255 (negative -> 0)
        ld a,h
        or a
        ld a,l
        ret z
        ld a,h
        rla
        ld a,0
        ret c
        dec a
        ret

OP_CLS:
        call GFX_CLS
        call VM_COMPUTE_PRINT_ATTR   ; A = attr — used immediately below,
                                      ; no intervening call, so no memory
                                      ; scratch needed for it here
        call GFX_PAINT_ATTR
        ld hl,0                  ; QUAL (Q-14): CLS homes the PRINT position (it kept the old row/column)
        ld (VM_OUTPUT_ROW),hl    ; (VM_OUTPUT_ROW, VM_OUTPUT_COL are adjacent)
        jp VM_RUN.loop

OP_BORDER:
        rst $18                 ; HL = value (QUAL Q-30) (any numeric value
                                  ; is accepted, same as V1's BORDER)
        ld a,l
        call GFX_SET_BORDER      ; masks to the low 3 bits itself
        jp VM_RUN.loop

; R8.5 Group 5's own resident OP_MODE/OP_ULAPLUS/OP_PALETTE removed
; (product decision, same principle as the earlier SPRITE-to-loadable-
; module move): now a loadable extension package, rom/ext_mode_
; module.asm, using the same EXT2_REGISTER/OP_CALL_EXT mechanism the
; sprite module already established. Opcodes 52-54 are now unused
; (they were the highest-numbered opcodes in this table, so no
; renumbering of anything else was needed).

OP_INK:
        rst $18
        ld a,l
        and $07
        ld (CURRENT_INK),a
        jp VM_RUN.loop

OP_PAPER:
        rst $18
        ld a,l
        and $07
        ld (CURRENT_PAPER),a
        jp VM_RUN.loop

; OP_FLASH/OP_BRIGHT/OP_OVER/OP_INVERSE (R10.7, opcodes 37/38/58/59) --
; same shape as OP_INK/OP_PAPER above, cloned per R10.25's own finding;
; each is boolean (real Sinclair BASIC's own "any nonzero odd value
; means on" convention, basic/basic.asm's own BASIC_STMT_FLASH/BRIGHT/
; INVERSE/OVER — AND $01, not $07).
OP_FLASH:
        rst $18
        ld a,l
        and $01
        ld (CURRENT_FLASH),a
        jp VM_RUN.loop

OP_BRIGHT:
        rst $18
        ld a,l
        and $01
        ld (CURRENT_BRIGHT),a
        jp VM_RUN.loop

OP_OVER:
        rst $18
        ld a,l
        and $01
        ld (CURRENT_OVER),a
        jp VM_RUN.loop

OP_INVERSE:
        rst $18
        ld a,l
        and $01
        ld (CURRENT_INVERSE),a
        jp VM_RUN.loop

; OP_AT (opcode 60) -- standalone "AT row,col" statement (R10.7).
; Compiler pushes row then col (COMPILE_EXPECT_COMMA_EXPR's own
; established order, same as PLOT/LINE); VM_POP is LIFO so col comes
; off first. Row clamped into 0-23 (GFX_ROWS, not a power of 2 --
; basic/basic.asm's own BASIC_STMT_AT precedent); col masked with $1F
; (GFX_COLS=32, a clean power of 2). Only PRINT AT <item-list> embedding
; remains out of reach (needs item-list grammar) -- this is the
; standalone-statement form only, matching R10.25's own B-class scope.
OP_AT:
        rst $18                  ; HL = col
        ld a,l
        and $1F
        ld (VM_OUTPUT_COL),a
        rst $18                  ; HL = row
        ld a,l
        cp 24
        jr c,.row_ok
        ld a,23
.row_ok:
        ld (VM_OUTPUT_ROW),a
        jp VM_RUN.loop

; OP_TAB (opcode 61) -- standalone "TAB col" statement (R10.7). Sets
; VM_OUTPUT_COL only, row untouched -- same masked-1-arg shape as
; OP_BORDER/OP_INK/OP_PAPER.
OP_TAB:
        rst $18
        ld a,l
        and $1F
        ld (VM_OUTPUT_COL),a
        jp VM_RUN.loop

; OP_CLEAR (opcode 62) -- CLEAR statement (R10.7, class B). Thin call
; into EXROM's own MEM_CLEAR_V2 (rom/exrom_v2_shell.asm) -- EXROM is
; already mapped in during ordinary VM execution, same established
; pattern PRINT's own exrom_format.asm calls already use (no BANK_PAGE_
; EXROM_OUT/IN needed, unlike OP_CALL_EXT's package-window case).
OP_CLEAR:
        call MEM_CLEAR_V2
        call VM_CS_UNWIND        ; RC (Q-21): drop the FOR frames above the innermost CALL/PARAM frame
        jr nc,.keep              ; (a FOR loop around CLEAR then ends at its NEXT: error 7, as a
        ld hl,(VARS_START)       ; cleared loop variable does on the Spectrum; it looped forever)
.keep:
        ld (VM_CSP),hl
        jp VM_RUN.loop

; OP_PLOT — pops y then x (compiler pushes x, then y, matching "PLOT
; x,y"'s reading order; VM_POP is LIFO, so y comes off first). Every
; value that must survive past the NEXT call is parked in its own
; VM_PLOT_*_TMP cell first — VM_CLAMP_Y191/VM_COMPUTE_PRINT_ATTR/
; GFX_WRITE_PIXEL are all real calls, and this project's own standing
; convention (see this file's header) is never to trust a register
; across one.
OP_PLOT:
        rst $18                  ; HL = y (FLOAT truncated)
        call VM_CLAMP_YCOORD     ; RC (DEC-PLOT): A = y clamped to 0..191
        ld (VM_PLOT_Y_TMP),a
        rst $18                  ; HL = x (FLOAT truncated)
        call VM_CLAMP_COORD      ; RC (DEC-PLOT): x clamped to 0..255 (was taken mod 256)
        ld (VM_PLOT_X_TMP),a
        call VM_COMPUTE_PRINT_ATTR
        ld (VM_PLOT_ATTR_TMP),a
        ld a,(CURRENT_OVER)
        ld (VM_PLOT_OVER_TMP),a
        ld a,(VM_PLOT_OVER_TMP)
        ld d,a                   ; D = over flag (GFX_WRITE_PIXEL's own
                                   ; parameter register)
        ld a,(VM_PLOT_X_TMP)
        ld b,a                    ; B = x
        ld a,(VM_PLOT_Y_TMP)
        ld c,a                    ; C = y
        ld a,(VM_PLOT_ATTR_TMP)   ; A = attr — loaded LAST, matching
                                    ; GFX_WRITE_PIXEL's real calling
                                    ; convention (A/B/C/D all set, no
                                    ; call in between here to clobber any
                                    ; of them)
        call GFX_WRITE_PIXEL
        jp VM_RUN.loop

; ===========================================================================
; R7 PHASE 2 — the real remainder of this ROM's own graphics/system
; statement set (LINE/BEEP/SOUND/POKE/PAUSE/RANDOMISE), each a native-call
; opcode into the existing, UNMODIFIED kernel primitive that already does
; this job for V1 — see rom/exrom_v2_compiler.asm's own R7 Phase 2 header
; for why CIRCLE/FILL/DRAW/OUT are NOT here (not real keywords in this
; ROM's own current dialect, confirmed against include/checker_
; keywords.inc, not assumed from the plan's own original text).
; ===========================================================================

; OP_LINE — pops y1,x1,y0,x0 (compiler pushes x0,y0,x1,y1, matching
; "LINE x0,y0 TO x1,y1"'s reading order; VM_POP is LIFO). Writes straight
; into the real GFX_LINE_X0/Y0/X1/Y1/ATTR/OVER sysvars — the SAME
; sysvars V1's own BASIC_PARSE_LINE_ARGS writes, not a private copy —
; then calls the real, unmodified GFX_LINE. Each popped value is stored
; immediately, before the NEXT VM_POP/call, so nothing is ever held in a
; register across a call here.
OP_LINE:
        rst $18                 ; HL = y1 (FLOAT truncated)
        ld a,l
        call VM_CLAMP_Y191
        ld (GFX_LINE_Y1),a
        rst $18                 ; HL = x1
        ld a,l
        ld (GFX_LINE_X1),a
        rst $18                 ; HL = y0
        ld a,l
        call VM_CLAMP_Y191
        ld (GFX_LINE_Y0),a
        rst $18                 ; HL = x0
        ld a,l
        ld (GFX_LINE_X0),a
        ld a,(CURRENT_OVER)
        ld (GFX_LINE_OVER),a
        call VM_COMPUTE_PRINT_ATTR
        ld (GFX_LINE_ATTR),a
        call GFX_LINE
        jp VM_RUN.loop

; OP_BEEP — pops pitch then duration (compiler pushes duration,pitch,
; matching "BEEP duration,pitch"'s real V1 argument order). Uses the Z80
; hardware stack (push/pop) to hold pitch across the second VM_POP —
; the same safe, already-established technique OP_FOR_INIT's own `push
; hl / call ... / pop de` uses, not a bare register held across a call.
OP_BEEP:
        rst $18                 ; HL = pitch (FLOAT truncated)
        push hl
        rst $18                 ; HL = duration
        pop bc                   ; BC = pitch (SOUND_BEEP's own register)
        ex de,hl                  ; DE = duration (SOUND_BEEP's own
                                    ; register); HL now holds whatever
                                    ; DE held before (unused garbage)
        call SOUND_BEEP
        jp VM_RUN.loop

; OP_SOUND — pops data then register (compiler pushes register,data,
; matching "SOUND register,data"'s real V1 argument order). Calls the
; real SOUND_EXROM primitive directly (rom/exrom_sound.asm) — bypassing
; basic.asm's own BASIC_SOUND_EXROM Home/EXROM paging wrapper, exactly
; the same reasoning rom/test_v2_compiler_r6.asm's own header documents
; for CALC_EXROM_ENTRY: a flat, single-bank test image has no banks to
; page, so the real EXROM module's real entry point can be called
; directly. An out-of-range register (SOUND_EXROM's own real 1-16 check)
; is a real, caught VM error, not silently ignored.
OP_SOUND:
        rst $18                 ; HL = data (FLOAT truncated)
        push hl
        rst $18                 ; HL = register
        ld a,l
        ld b,a                    ; B = register
        pop hl                    ; HL = data (restored)
        ld a,l
        ld c,a                    ; C = data
        call SOUND_EXROM
        jp c,VM_ERR_INVALID_SOUND_REGISTER
        jp VM_RUN.loop

; OP_POKE — pops value then address (compiler pushes address,value,
; matching "POKE address,value"'s real V1 argument order).
OP_POKE:
        rst $18                 ; HL = value (FLOAT truncated)
        push hl
        call VM_POP_ADDR        ; HL = address (QUAL Q-32)
        pop de                    ; DE = value (restored)
        ld a,e                    ; low byte of value — matches V1's own
                                    ; BASIC_STMT_POKE (`ld a,e / ld (hl),a`)
        ld (hl),a
        jp VM_RUN.loop

; OP_PAUSE — pops n. n=0 waits for a keypress (IO_READ_KEY); n>0 waits
; exactly n display-frame ticks (INT_GET_FRAMES) — the identical
; algorithm BASIC_STMT_PAUSE already uses, transcribed rather than
; called (basic.asm is V1's language core, same reasoning as VM_COMPUTE_
; PRINT_ATTR's own header above — this IS language-level control flow,
; not a platform primitive being reused). INT_GET_FRAMES's own header
; documents "Destroys: HL" only, so DE (the target) safely survives
; across the repeated call in .wait_loop without any extra scratch cell.
OP_PAUSE:
        rst $18                 ; HL = n (QUAL Q-30: a FLOAT was its slot index)
        ld a,h
        or l
        jr z,.wait_key
        push hl                  ; save n across the next call
        call INT_GET_FRAMES       ; HL = current frame count
        pop de                    ; DE = n (restored)
        add hl,de                 ; HL = target = current + n
        ex de,hl                  ; DE = target
.wait_loop:
        ld a,(VM_HALTED)          ; STUDY (D5): BREAK (set by the ISR) ends a long PAUSE
        or a
        jp nz,VM_RUN.loop
        call INT_GET_FRAMES       ; HL = current (DE survives, per
                                    ; INT_GET_FRAMES's own "Destroys: HL"
                                    ; only contract)
        or a
        sbc hl,de                 ; carry set while current < target
        jr c,.wait_loop
        jp VM_RUN.loop
.wait_key:
        call IO_READ_KEY
        jp VM_RUN.loop

; OP_RANDOMISE — pops n, reseeds the RNG via the real, unmodified
; MATH_RND_SEED (kernel/math). No register survives past this one call
; (HL is MATH_RND_SEED's own input register, consumed immediately).
OP_RANDOMISE:
        rst $18                 ; HL = n (FLOAT truncated)
        call MATH_RND_SEED
        jp VM_RUN.loop

; ===========================================================================
; R7.5 — V2-native loadable-extension dispatch. See kernel/extensions/
; ext_registry.asm's own header for the full design (compile-time-
; resolved slot id + a runtime generation check, chosen over a V1-shaped
; runtime name-rescan — the quantitative comparison lives in docs/v2/
; ARCHITECTURE_B_IMPLEMENTATION_PLAN.md's R7.5 section) and docs/v2/
; REWRITE_VM_DESIGN.md's own cross-link.
; ===========================================================================

; VM_CALL_INDIRECT — input: DE = target address. `call VM_CALL_INDIRECT`
; is a real call (pushes a return address); this routine's own `jp (hl)`
; then tail-jumps into the target WITHOUT pushing anything further, so
; the target's own eventual `ret` pops the SAME return address straight
; back to whoever called VM_CALL_INDIRECT — the identical tail-call
; shape basic.asm's own BASIC_CALL_USR (`jp (hl)`) already uses for V1's
; extension callbacks. Destroys: whatever the target itself destroys.
VM_CALL_INDIRECT:
        ex de,hl
        jp (hl)

; OP_CALL_EXT — operand: [slot_id:1][generation:1][argcount:1]. Pops
; `argcount` values (tag ignored — this milestone's extension ABI is
; plain-int-only, matching V1's own extension ABI, which was also always
; 16-bit ints) into EXT_CALL_ARG0..(argcount-1) in call order (the LAST
; value popped — since VM_POP is LIFO — is the FIRST argument, so this
; fills from the highest index down), verifies the matched slot's
; CURRENT generation against the one baked into the bytecode, and calls
; through its exec_ptr. A mismatch (module unloaded, or a different
; module now occupying that slot) is a real, caught VM error.
OP_CALL_EXT:
        ld hl,(VM_IP)
        ld a,(hl)
        ld (VM_EXT_SLOT),a
        inc hl
        ld a,(hl)
        ld (VM_EXT_GEN),a
        inc hl
        ld a,(hl)
        ld (VM_EXT_ARGCOUNT),a
        inc hl
        ld (VM_IP),hl
        ld a,(VM_EXT_ARGCOUNT)
        ld (VM_EXT_REMAINING),a
.pop_loop:
        ld a,(VM_EXT_REMAINING)
        or a
        jr z,.args_done
        dec a
        ld (VM_EXT_REMAINING),a   ; A = the arg index this value fills
                                    ; (argcount-1 on the first iteration,
                                    ; counting down to 0)
        call VM_POP_ADDR           ; QUAL (Q-33): HL = the value as a 16-bit int (a FLOAT is
                                     ; truncated; it used to arrive as its slot index)
        ld (VM_EXT_POPVAL),hl
        ld a,(VM_EXT_REMAINING)
        cp 4                        ; the 5th slot (index 4, GRAB's own
        jr z,.arg4                   ; w/h/etc.) is NOT contiguous with
                                       ; ARG0-3 (kernel/extensions/
                                       ; ext_registry.asm's own header
                                       ; explains why) -- needs its own
                                       ; base address, not index*2 math
        add a,a                    ; *2 (each arg slot is 2 bytes)
        ld hl,EXT_CALL_ARG0
        ld e,a
        ld d,0
        add hl,de
        jr .store
.arg4:
        ld hl,EXT_CALL_ARG4
.store:
        ld de,(VM_EXT_POPVAL)
        ld (hl),e
        inc hl
        ld (hl),d
        jr .pop_loop
.args_done:
        ld a,(VM_EXT_SLOT)
        call EXT2_SLOT_ADDR        ; HL -> registry record
        ld (VM_EXT_RECPTR),hl
        ld a,(hl)                   ; the slot's CURRENT generation
        ld b,a
        ld a,(VM_EXT_GEN)
        cp b
        jp nz,VM_ERR_EXTENSION_NOT_FOUND
        ld hl,(VM_EXT_RECPTR)
        ld de,10                     ; record layout: [gen:1][name_len:1]
                                     ; [name:8][exec_ptr:2][argcount:1] —
                                     ; exec_ptr always starts at +10,
                                     ; regardless of the real name's own
                                     ; length (the 8-byte name FIELD is
                                     ; fixed-width, zero-padded)
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)                    ; DE = exec_ptr
        ; V2 extensions execute from the package window at $F400. Return
        ; chunk 6 to Home while they run so RAM scratch at $C000-$DFFF
        ; (notably the 6KB flood-fill visited bitmap) is visible. Package
        ; RAM at $F400 and fixed V2 tables remain mapped in either state.
        ld (VM_EXT_EXEC_PTR),de
        IFDEF V2_PRODUCTION
        call BANK_PAGE_EXROM_OUT
        ENDIF
        ld hl,(VM_EXT_EXEC_PTR)
        ex de,hl
        call VM_CALL_INDIRECT
        IFDEF V2_PRODUCTION
        call BANK_PAGE_EXROM_IN
        ENDIF
        jp VM_RUN.loop

; ===========================================================================
; R8.5 — text I/O (PRINT/LPRINT). V1's own real scope, matched (not
; exceeded): ONE argument, numeric or string, auto-detected at compile
; time (rom/exrom_v2_compiler.asm's COMPILE_PRINT peeks the same way
; COMPILE_IF already does); no comma/semicolon-separated item list, no
; ";"-suppressed trailing newline -- basic/basic.asm's own real
; BASIC_STMT_PRINT doesn't have either. Reaches real, unmodified,
; EXROM-resident platform primitives throughout (rom/exrom_format.asm's
; BASIC_NUM_TO_STRING_EXROM/BASIC_FLOAT_TO_STRING_EXROM, kernel/
; graphics's GFX_PRINT_STRING_ATTR/GFX_SCROLL_OUTPUT_UP, rom/
; exrom_printer.asm's BASIC_STMT_LPRINT_EXROM) -- never basic.asm
; itself, which R9 deletes whole (same reasoning R7's own VM_COMPUTE_
; PRINT_ATTR/VM_CLAMP_Y191 header already gives).
; ===========================================================================

; VM_NUM_TO_TEXT — input: HL = value, A = tag (TAG_INT/TAG_FLOAT).
; Out: HL = null-terminated decimal text (PRINT_BUF). Destroys: AF, BC,
; DE, HL.
;
; REAL BUG FOUND AND FIXED (R8.5 Group 6, SQR): the float path below
; re-reads its own operand from VM_PRINT_TEXT_TMP rather than the HL it
; was actually called with -- originally safe only because OP_PRINT_NUM,
; its one real caller at the time, happened to always set that cell
; itself first. BUILTIN_FN_STR (Group 6) calls this directly with a
; FLOAT tag and never set it, so STR$() of a float variable silently
; rendered whatever value some earlier PRINT had last parked there,
; not the real argument -- never caught because STR$'s own test only
; used an integer argument. Fixed at the root: this entry now sets
; VM_PRINT_TEXT_TMP from its own real HL parameter unconditionally, so
; every caller's HL is what the float path actually uses, matching
; this header's own documented contract instead of requiring each new
; caller to independently discover the undocumented extra step.
;
; Float sign: BASIC_FLOAT_TO_STRING_EXROM's own real contract is
; magnitude-only (non-negative) -- confirmed from its one real V1
; caller, which tracks sign separately (basic/basic.asm's own
; BASIC_EVAL_PRINT_ARG, for its own narrower SQR/SIN-only float
; display). V2's own float values can be negative from ordinary
; arithmetic, not just two magnitude-guaranteed functions, so this
; needs a real sign step V1 never did. The 5-byte packed float's own
; sign bit location is confirmed directly from rom/exrom_calc.asm's
; own CALC_FP_TO_INT body (not guessed): byte0==0 is the compact
; "small integer" form (sign is byte1, $00/$FF); otherwise byte1's own
; bit7 is the sign, in the general form. Negation itself reuses the
; ALREADY-VERIFIED "subtract" calculator literal (VM_CALC_SUB_STUB's
; own `$03,$38` -- see that routine's own header) as `0 - value`,
; rather than guessing at a separate "negate" literal's own byte value.
VM_NUM_TO_TEXT:
        ld (VM_PRINT_TEXT_TMP),hl   ; see this routine's own header --
                                       ; the float path below needs this
        cp TAG_FLOAT
        jr z,.float
        ex de,hl
        jp BASIC_NUM_TO_STRING_EXROM
.float:
        ld a,l
        call VM_FLOAT_ADDR          ; HL -> the real 5 packed bytes
        ld a,(hl)                    ; byte0 (exponent, or 0 = small-int
                                       ; form)
        or a
        jr z,.small_int_form
        inc hl
        ld a,(hl)                     ; byte1 (general form's own sign
                                        ; bit is its bit7)
        and $80
        jr .have_sign
.small_int_form:
        inc hl
        ld a,(hl)                      ; byte1 ($00/$FF in this form)
.have_sign:
        or a
        ld a,0
        jr z,.positive
        ld a,1
.positive:
        ld (VM_PRINT_SIGN_TMP),a
        or a
        jr z,.push_positive
        xor a
        ld (CALC_SP),a
        ld hl,0
        call CALC_INT_TO_FP           ; push 0.0 (the 'a' operand)
        ld a,TAG_FLOAT
        ld (VM_FLOAT_OPERAND_TAG),a
        ld hl,(VM_PRINT_TEXT_TMP)      ; the original FLOATTAB index,
                                         ; parked by OP_PRINT_NUM below
                                         ; before calling here
        ld (VM_FLOAT_OPERAND_VAL),hl
        call VM_FLOAT_PUSH_OPERAND     ; push the real value (the 'b'
                                         ; operand)
        call VM_CALC_SUB_STUB          ; CALC_STACK top = 0-value = the
                                         ; positive magnitude
        jr .to_string
.push_positive:
        xor a
        ld (CALC_SP),a
        ld a,TAG_FLOAT
        ld (VM_FLOAT_OPERAND_TAG),a
        ld hl,(VM_PRINT_TEXT_TMP)
        ld (VM_FLOAT_OPERAND_VAL),hl
        call VM_FLOAT_PUSH_OPERAND
.to_string:
        call BASIC_FLOAT_TO_STRING_EXROM  ; HL = text (PRINT_BUF, no sign)
        ld a,(VM_PRINT_SIGN_TMP)
        or a
        ret z
        dec hl                              ; PRINT_BUF reserves the
        ld (hl),'-'                          ; byte before the returned
        ret                                   ; pointer for exactly this

OP_PRINT_NUM:
        rst $10                     ; HL = value, A = tag
        call VM_NUM_TO_TEXT          ; VM_NUM_TO_TEXT's own entry now
                                       ; parks HL into VM_PRINT_TEXT_TMP
                                       ; itself (its float path's real
                                       ; need) -- this call site no
                                       ; longer needs to do it separately
        jr VM_PRINT_COMMON

OP_PRINT_STR:
        rst $10                     ; HL = STRTAB index, A = tag
        ld a,l
        call VM_STR_ADDR             ; HL -> record
        ld c,(hl)                    ; QUAL (Q-27/Q-28): print exactly `length` characters.
        ld b,0                       ; LEFT$/RIGHT$/MID$/CHR$/STR$/string-array reads never wrote a
        inc hl                       ; NUL, so PRINT showed the stale tail of an earlier string in the
        ld de,PRINT_BUF              ; temp slot (a$="abcdefgh": PRINT LEFT$("q",1) -> "qbcdefgh");
        push de                      ; the writers that did write one could put it past the record.
        ld a,c
        or a
        jr z,.empty                  ; (LDIR with BC = 0 would copy 64K)
        ldir
.empty:
        xor a
        ld (de),a                    ; PRINT_BUF is 64 B; a string is at most 31
        pop hl
        jr VM_PRINT_COMMON

; VM_PRINT_COMMON — input: HL = null-terminated text to print. Shared
; tail for OP_PRINT_NUM/OP_PRINT_STR: compute the current attribute,
; print at (VM_OUTPUT_ROW, VM_OUTPUT_COL), advance to a fresh line.
VM_PRINT_COMMON:
        ld (VM_PRINT_TEXT_TMP),hl
        call VM_COMPUTE_PRINT_ATTR   ; A = attr byte
        ld e,a
        ld a,(VM_OUTPUT_ROW)
        ld b,a
        ld a,(VM_OUTPUT_COL)
        ld c,a
        ld a,(CURRENT_OVER)
        ld d,a
        ld a,e
        ld hl,(VM_PRINT_TEXT_TMP)
        call GFX_PRINT_STRING_ATTR    ; B/C = row/col right after the
                                        ; text (may have wrapped/
                                        ; scrolled for a long string)
        ld a,b
        ld (VM_OUTPUT_ROW),a
        ld a,c                         ; STUDY: the column survives -- OP_NL ends the line,
        ld (VM_OUTPUT_COL),a           ; a trailing ';' leaves the cursor here
        jp VM_RUN.loop

; STUDY: end of a PRINT line (the implicit newline every PRINT statement ends with, unless it
; ended in ';' or ',').
OP_NL:
        call VM_ADVANCE_OUTPUT_ROW
        jp VM_RUN.loop

; STUDY: ',' in a PRINT list -- the next 16-column zone; from the right-hand zone, the next line.
OP_PRINT_COMMA:
        ld a,(VM_OUTPUT_COL)
        or 15
        inc a
        cp 32
        jr nc,.next_line
        ld (VM_OUTPUT_COL),a
        jp VM_RUN.loop
.next_line:
        call VM_ADVANCE_OUTPUT_ROW
        jp VM_RUN.loop

; VM_ADVANCE_OUTPUT_ROW — a small, self-contained VM-owned equivalent of
; basic/basic.asm's own BASIC_ADVANCE_OUTPUT_ROW (same algorithm: reset
; column, advance row, scroll all 24 rows at the bottom) -- NOT a call
; into basic.asm itself, which R9 deletes whole.
VM_ADVANCE_OUTPUT_ROW:
        xor a
        ld (VM_OUTPUT_COL),a
        ld a,(VM_OUTPUT_ROW)
        inc a
        cp 24
        jr c,.no_wrap
        call GFX_SCROLL_OUTPUT_UP
        ld a,23
        ld (VM_OUTPUT_ROW),a
        ret
.no_wrap:
        ld (VM_OUTPUT_ROW),a
        ret

; OP_LPRINT_NUM/OP_LPRINT_STR (opcodes 37-38) removed -- printer-
; package ROM reconciliation: LPRINT is no longer a resident opcode
; (rom/exrom_v2_compiler.asm's own COMPILE_LPRINT now compiles it as a
; plain OP_CALL_EXT to the loadable rom/ext_printer_module.asm, same
; mechanism SPRITE/MODE already use). Opcodes 37-38 are NOT the highest-
; numbered pair in this table (CALL_FN=39 and everything after it still
; needs to keep its own number), so rather than renumber every opcode
; from 39 up (real, unnecessary churn/risk for two now-permanently-dead
; slots), the jump-table entries below simply point at VM_ERR_ILLEGAL_
; OPCODE instead -- a real caught error if bytecode somehow still
; contained one (it never will: nothing emits opcode 37/38 anymore),
; not silent garbage.

; ===========================================================================
; R8.5 Group 1 -- built-in (resident) function calls. Operand: [fn_index:1].
; Argcount is NOT re-checked at runtime -- rom/exrom_v2_compiler.asm's own
; BUILTIN_FN_FIND already verified it at compile time against the same
; table's own argcount field, so each function routine below simply pops
; exactly as many values as it knows it needs. Same tail-jump-through-
; call trampoline OP_CALL_EXT already established (VM_CALL_INDIRECT does
; `jp (hl)`, not `call (hl)` -- the callee's own `ret` returns to
; wherever OP_CALL_FN's own `call VM_CALL_INDIRECT` was invoked from).
; ===========================================================================
OP_CALL_FN:
        ld hl,(VM_IP)
        ld a,(hl)
        inc hl
        ld (VM_IP),hl
        ld l,a
        ld h,0
        add hl,hl              ; *2 (word-sized table entries)
        ld de,BUILTIN_FN_JUMP_TABLE
        add hl,de
        ld e,(hl)
        inc hl
        ld d,(hl)
        call VM_CALL_INDIRECT
        jp VM_RUN.loop

BUILTIN_FN_JUMP_TABLE:
        dw BUILTIN_FN_ABS       ; fn_index 0
        dw BUILTIN_FN_SGN       ; fn_index 1
        dw BUILTIN_FN_MOD       ; fn_index 2
        dw BUILTIN_FN_DIV       ; fn_index 3
        dw BUILTIN_FN_RND       ; fn_index 4
        dw BUILTIN_FN_POINT     ; fn_index 5
        dw BUILTIN_FN_ATTR      ; fn_index 6
        dw BUILTIN_FN_INT       ; fn_index 7
        dw BUILTIN_FN_PEEK      ; fn_index 8
        dw BUILTIN_FN_USR       ; fn_index 9
        dw BUILTIN_FN_LEN       ; fn_index 10
        dw BUILTIN_FN_CODE      ; fn_index 11
        dw BUILTIN_FN_VAL       ; fn_index 12
        dw BUILTIN_FN_CHR       ; fn_index 13
        dw BUILTIN_FN_STR       ; fn_index 14
        dw BUILTIN_FN_UPPER     ; fn_index 15
        dw BUILTIN_FN_LOWER     ; fn_index 16
        dw BUILTIN_FN_LEFT      ; fn_index 17
        dw BUILTIN_FN_RIGHT     ; fn_index 18
        dw BUILTIN_FN_INKEY     ; fn_index 19
        dw BUILTIN_FN_SQR       ; fn_index 20
        dw BUILTIN_FN_PI        ; fn_index 21
        dw BUILTIN_FN_RAD       ; fn_index 22
        dw BUILTIN_FN_DEG       ; fn_index 23
        dw BUILTIN_FN_SIN       ; fn_index 24
        dw BUILTIN_FN_FREE      ; fn_index 25
        dw BUILTIN_FN_COS       ; fn_index 26
        dw BUILTIN_FN_TAN       ; fn_index 27
        dw BUILTIN_FN_MID       ; fn_index 28
        dw BUILTIN_FN_FREE_N    ; fn_index 29
        dw BUILTIN_FN_IN        ; fn_index 30 (STUDY)
        dw BUILTIN_FN_STICK     ; fn_index 31 (STUDY)

; BUILTIN_FN_ABS — ABS(x). Pops one value (either tag), pushes its
; magnitude. Int path: plain two's-complement negate (always safe, the
; value is a raw operand-stack word, never a table index). Float path:
; checks the FLOATTAB record's own sign byte directly (same technique
; VM_NUM_TO_TEXT's own float path already uses) and, only if negative,
; computes "0 - x" via the calculator (VM_FLOAT_STORE_RESULT's own
; fresh-temp-slot allocation, same as OP_SUB's float path) -- never
; mutates the popped record in place, which would risk aliasing a live
; variable's own FLOATTAB slot if OP_LOAD_VAR ever pushes a variable's
; real index rather than a copy.
BUILTIN_FN_ABS:
        rst $10                 ; HL = value, A = tag
        cp TAG_FLOAT
        jr z,.float
        bit 7,h
        jr z,.int_push
        xor a
        sub l
        ld l,a
        ld a,0
        sbc a,h
        ld h,a
        jp m,VM_PUSH_U16         ; QUAL (D11-EXT): ABS(-32768) = 32768, a FLOAT
.int_push:
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH
.float:
        ld (BFN_ABS_IDX_TMP),hl
        ld a,l
        call VM_FLOAT_ADDR       ; HL -> record
        ld a,(hl)                 ; byte0 (exponent, or 0 = small-int form)
        or a
        jr z,.small_int_form
        inc hl
        ld a,(hl)                  ; general form: sign is byte1's bit7
        and $80
        jr .have_sign
.small_int_form:
        inc hl
        ld a,(hl)                   ; small-int form: byte1 itself is
                                      ; $00/$FF
.have_sign:
        or a
        jr z,.float_positive
        xor a
        ld (CALC_SP),a
        ld hl,0
        call CALC_INT_TO_FP          ; push 0.0
        ld a,TAG_FLOAT
        ld (VM_FLOAT_OPERAND_TAG),a
        ld hl,(BFN_ABS_IDX_TMP)
        ld (VM_FLOAT_OPERAND_VAL),hl
        call VM_FLOAT_PUSH_OPERAND    ; push the real value
        call VM_CALC_SUB_STUB
        jp VM_FLOAT_STORE_RESULT        ; fresh temp slot + VM_PUSH, no
                                           ; aliasing risk
.float_positive:
        ld hl,(BFN_ABS_IDX_TMP)
        ld a,TAG_FLOAT
        jp VM_PUSH

; ---------------------------------------------------------------------------
; R8.5 Group 6 -- SGN/MOD/DIV/RND. Confirmed via this milestone's own
; reuse audit AND a direct check of basic.asm's own real dispatch: each
; is a thin wrapper over a real, already-reusable kernel/math/math.asm
; primitive operating on plain 16-bit integers (this whole function
; family is deliberately integer-only in V1 too -- "this is a pure-
; integer BASIC", basic.asm's own .call_int comment). No float path:
; matching V1's real behavior exactly, not a new V2 scope cut.
; ---------------------------------------------------------------------------

; SGN(x) -- pops one int, pushes -1/0/1. MATH_SGN16: HL in, HL out.
BUILTIN_FN_SGN:
        rst $10                 ; HL = value, A = tag
        cp TAG_FLOAT
        jr nz,.int              ; QUAL (Q-10): a FLOAT's sign, not the sign of its truncation
        ld a,l
        call VM_FLOAT_ADDR      ; HL -> its 5 bytes
        ld a,(hl)
        inc hl
        or a
        jr nz,.general
        inc hl                  ; the small-integer form: bytes 2-3 are the value
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a
.int:
        call MATH_SGN16
        jr BFN_PUSH_INT_RESULT
.general:                       ; the general form is never zero: its sign bit decides
        bit 7,(hl)
        ld hl,1
        jr z,BFN_PUSH_INT_RESULT
        dec hl
        dec hl                  ; -1
        jr BFN_PUSH_INT_RESULT

; QUAL (Q-10): MOD and DIV take FLOAT operands: DIV(a,b) = a/b truncated toward zero (an INT when it
; fits, else a FLOAT), MOD(a,b) = a - DIV(a,b)*b (sign of the dividend, as for INTs).
BUILTIN_FN_MOD:
        call BFN_POP_DIVISION   ; NC: HL = dividend, DE = divisor (never 0); C: CALC_STACK[0] = a/b
        jr c,.float
        call MATH_MOD16
        jr BFN_PUSH_INT_RESULT
.float:
        ld hl,CALC_STACK
        call FP_TRUNC           ; [q]
        ld a,(VM_FLOAT_B_TAG)
        ld hl,(VM_FLOAT_B_VAL)
        call VM_FLOAT_PUSH_TAGGED
        call VM_CALC_MUL_STUB   ; [q*b]
        ld a,(VM_FLOAT_A_TAG)
        ld hl,(VM_FLOAT_A_VAL)
        call VM_FLOAT_PUSH_TAGGED
        ld b,0
        rst $28
        db $01,$03,$38          ; exchange, subtract: [a - q*b]
        jp VM_FLOAT_STORE_RESULT

BUILTIN_FN_INT:
        rst $10                 ; HL = value, A = tag
        cp TAG_FLOAT
        jr nz,BFN_PUSH_INT_RESULT
        call VM_FLOAT_PUSH_FIRST  ; CALC_STACK[0] = x
; QUAL (D11-EXT): CALC_STACK[0] truncated toward zero, pushed as an INT when it fits, else as a FLOAT
; (INT(90000.5) = 90000, which saturated to 32767).
BFN_TRUNC_PUSH:
        ld hl,CALC_STACK
        call FP_TRUNC
        call CALC_FP_TO_INT     ; HL = the value; carry = not an INT
        jp c,VM_FLOAT_STORE_RESULT   ; (the record is still at CALC_STACK[0])
        jr BFN_PUSH_INT_RESULT

BUILTIN_FN_DIV:
        call BFN_POP_DIVISION
        jr c,BFN_TRUNC_PUSH
        call VM_DIV16_CHECKED
        jp c,VM_PUSH_U16        ; QUAL (D11-EXT): DIV(-32768,-1) = 32768 (HL is still -32768 = $8000)
BFN_PUSH_INT_RESULT:
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH

; QUAL (Q-10): NC = both INT: HL = dividend, DE = divisor (error if 0). C = a FLOAT is involved: the
; operands are in VM_FLOAT_A/B_* and CALC_STACK[0] = a/b (error if b = 0).
BFN_POP_DIVISION:
        call VM_PREPARE_BINARY_OPERANDS
        jr nz,.float
        ld hl,(VM_FLOAT_A_VAL)
        ld de,(VM_FLOAT_B_VAL)
        ld a,d
        or e                    ; NC
        ret nz
        jp VM_ERR_DIVIDE_BY_ZERO
.float:
        ld a,(VM_FLOAT_B_TAG)
        ld hl,(VM_FLOAT_B_VAL)
        call VM_FLOAT_TEST_ZERO
        jp z,VM_ERR_DIVIDE_BY_ZERO
        call VM_CALC_PUSH_AB
        call VM_CALC_DIV_STUB   ; [a/b]
        scf
        ret

; QUAL (D11-EXT): HL / DE as MATH_DIVIDE16, but carry set (nothing computed, HL unchanged) for
; -32768 / -1, whose quotient 32768 is not an INT.
VM_DIV16_CHECKED:
        ld a,d
        and e
        inc a                   ; Z iff DE = -1
        jr nz,.go
        ld a,h
        xor $80
        or l                    ; Z iff HL = -32768
        scf
        ret z
.go:
        call MATH_DIVIDE16
        or a
        ret

; QUAL (D11-EXT, Q-10): FP_TRUNC -- truncate the 5-byte value at HL toward zero, in place.
; Destroys AF, B, HL.
FP_TRUNC:
        ld a,(hl)
        or a
        ret z                   ; the small-integer form is already an integer
        sub $81                 ; A = e - 1  (value = 0.1mmm... x 2^e)
        jr c,.zero              ; e <= 0: |x| < 1
        cp 31
        ret nc                  ; e >= 32: no fraction bits
        cpl
        add a,32                ; A = 32 - e fraction bits to clear (1..31)
        ld b,a
        inc hl
        inc hl
        inc hl
        inc hl                  ; -> the least significant mantissa byte
.byte:
        ld a,b
        cp 8
        jr c,.part
        ld (hl),0
        dec hl
        sub 8
        ld b,a
        jr nz,.byte
        ret
.part:
        ld a,$FF
.mask:
        add a,a
        djnz .mask              ; A = $FF << B
        and (hl)
        ld (hl),a
        ret
.zero:
        ld b,5
.z:
        ld (hl),0
        inc hl
        djnz .z
        ret

; RND(x) -- pops one int (the upper bound), pushes a random value.
; MATH_RND16: HL in, HL out.
BUILTIN_FN_RND:
        rst $18                 ; HL = value (FLOAT truncated)
        call MATH_RND16
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH

; POINT(x,y) -- confirmed via basic.asm's own .call_point: a thin
; adapter onto GFX_READ_PIXEL's own B=x/C=y -> A=0/1 contract (not the
; HL/DE-in MATH_* convention SGN/MOD/DIV/RND above share -- POINT isn't
; itself a MATH_* routine). Y is clamped to 191 (192 pixels tall, not a
; power of 2), same as V1's own real behavior; X's full 0-255 range is
; already the whole valid screen width, no clamp needed.
BUILTIN_FN_POINT:
        rst $18                 ; HL = y (FLOAT truncated)
        push hl                 ; same fix as BUILTIN_FN_MOD/DIV above
        rst $18                 ; HL = x
        call VM_CLAMP_COORD     ; RC (DEC-PLOT): x clamped like PLOT's
        ld b,a                  ; B = x
        pop hl                  ; HL = y
        call VM_CLAMP_YCOORD
        ld c,a                  ; C = y (clamped)
        call GFX_READ_PIXEL     ; A = 0 or 1
        ld l,a
        ld h,0
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH

; ATTR(row,col) -- confirmed via basic.asm's own .call_attr: reads the
; normal 32x24 attribute grid via GFX_CELL_ATTR_ADDR. Invalid
; coordinates (either value's own high byte nonzero, i.e. >255, or
; GFX_CELL_ATTR_ADDR's own row<24/col<32 range check failing) return 0,
; matching POINT's deliberately forgiving screen-query behavior --
; not an error condition.
BUILTIN_FN_ATTR:
        rst $18                 ; HL = col (FLOAT truncated)
        push hl
        rst $18                 ; HL = row
        pop de                  ; DE = col
        ld a,h
        or d
        jr nz,.attr_zero
        ld b,l                  ; B = row
        ld c,e                  ; C = col
        call GFX_CELL_ATTR_ADDR
        jr c,.attr_zero
        ld a,(hl)
        ld l,a
        ld h,0
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH
.attr_zero:
        ld hl,0
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH

; INT(x) -- under V2's hybrid INT/FLOAT numeric model this is no longer
; V1's true no-op (V1 was pure-integer, so every value already was its
; own INT()): a FLOAT argument must genuinely truncate toward zero and
; come back INT-tagged. VM_POP_COERCE_INT is exactly the INT() operation
; already, so this is now literally that shared routine plus a fresh
; INT tag -- closing the "INT(3.7) still yields 3.7" bug (docs/v2/
; V2_SEMANTIC_CAPABILITY_AUDIT.md S4).

; PEEK(addr) -- confirmed via basic.asm's own .call_peek: reads raw
; memory directly, deliberately NOT routed through a kernel/ API (the
; address is arbitrary caller-supplied data, not kernel-owned hardware/
; sysvar state). V1's own real .call_peek carries a BASIC_CHECK_ONLY
; guard against a real bug (GitHub issue #4) where V1's interpreter
; evaluates expressions live during whole-program static checking,
; auto-vivifying an unassigned variable to 0 and peeking address 0 as a
; side effect of merely checking syntax. That hazard does not exist
; here: V2 compiles ahead of time and never evaluates an expression
; during compilation, so no equivalent guard is needed.
BUILTIN_FN_PEEK:
        call VM_POP_ADDR        ; HL = address (QUAL Q-32)
        ld a,(hl)
        ld l,a
        ld h,0
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH

; USR(addr) -- confirmed via basic.asm's own .call_usr/BASIC_CALL_USR:
; tail-jumps into the caller-supplied machine code address via `jp
; (hl)`, reached through a `call` so the user routine's own closing RET
; returns control right back here (real Sinclair BASIC CALL/USR
; convention: result left in HL). V1's own real .call_usr carries a
; BASIC_CHECK_ONLY guard against a real hang (a live-typing/whole-
; program checker evaluating "X=USR(0)" without truly running it would
; otherwise jump to this ROM's own RST_00 reset vector). That hazard
; does not exist here for the same reason PEEK's header above gives.
BUILTIN_FN_USR:
        call VM_POP_ADDR        ; HL = address (QUAL Q-32)
        call VM_CALL_USR_TRAMPOLINE
        bit 7,h
        jp nz,VM_PUSH_U16        ; QUAL (L-C): BC is unsigned, 0..65535
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH

; STUDY: IN(port) -- the FULL 16-bit port address goes to BC (`in a,(c)` drives A15-A8 from B), so
; IN(65278) reads keyboard half-row 0 ($FEFE) and IN(63486) half-row 1 ($F7FE), unlike a low-byte-only IN.
BUILTIN_FN_IN:
        call VM_POP_ADDR        ; HL = port (QUAL Q-32)
        ld b,h
        ld c,l
        in a,(c)
        ld l,a
        ld h,0
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH

; STUDY: STICK(n) -- Timex joystick through AY register 14 (I/O port A), the removed V1 STICK_READ
; algorithm: stick 1 = low nibble (direction bits, active high), stick 2 = one bit (hardware asymmetry).
BUILTIN_FN_STICK:
        rst $18                 ; HL = 1 or 2
        ld a,h
        or a
        jr nz,.bad
        ld a,l
        dec a
        cp 2
.bad:
        jp nc,BUILTIN_FN_CHR.chr_range_err   ; RC (Q-23): STICK(n), n other than 1/2: error 15
        ld a,$0E
        out (PORT_AY_REG),a      ; select AY register 14
        ld c,PORT_AY_DATA
        in a,(c)
        cpl                      ; active low -> active high
        dec l
        jr nz,.stick2
        and $0F
        cp $0F
        jr c,.done
        xor a                    ; all four set: no real input
        jr .done
.stick2:
        rlca
        and $01
.done:
        ld l,a
        ld h,0
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH

; STUDY: OUT port,value -- pops value then port (compiler pushed port,value, like POKE).
OP_OUT:
        rst $18                 ; HL = value
        push hl
        call VM_POP_ADDR        ; HL = port (QUAL Q-32)
        ld b,h
        ld c,l
        pop hl
        ld a,l
        out (c),a
        jp VM_RUN.loop

VM_CALL_USR_TRAMPOLINE:
        jp (hl)

; LEN(a$)/CODE(a$)/VAL(a$) -- confirmed via basic.asm's own real
; dispatch (.str_arg_len/.str_arg_code/.str_arg_val): the first built-
; ins whose argument is a STRING (compiled via COMPILE_STR_EXPR, per
; rom/exrom_v2_compiler.asm's own BUILTIN_FN_TABLE argtype column --
; see that table's own header). A string "value" on the operand stack
; is a plain STRTAB index (TAG_INT), same as everywhere else in this
; VM -- VM_STR_ADDR turns it into a real record address ([len:1]
; [content:31]).

; LEN(a$) -- the record's own length byte, directly.
BUILTIN_FN_LEN:
        rst $10                 ; HL = string index (L; H=0 always --
                                 ; STRSYM_FIND_OR_CREATE's own indices
                                 ; are always small)
        ld a,l
        call VM_STR_ADDR        ; HL = record address
        ld a,(hl)
        ld l,a
        ld h,0
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH

; CODE(a$) -- the ASCII code of the first character, or 0 for an empty
; string (V1's own real .str_arg_code behavior, matched exactly).
BUILTIN_FN_CODE:
        rst $10
        ld a,l
        call VM_STR_ADDR        ; HL = record address
        ld a,(hl)               ; length byte
        or a
        jr z,.code_empty
        inc hl
        ld a,(hl)               ; first content byte
        ld l,a
        ld h,0
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH
.code_empty:
        ld hl,0
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH

; VAL(a$) -- parses the string's own content as a signed decimal
; integer, reusing the REAL digit-accumulation math OP_INPUT_NUM's own
; VM_PARSE_INPUT_INT already provides (see that routine's own header)
; rather than porting basic.asm's own separate BASIC_STRFUNC_EXROM
; parser. VM_PARSE_INPUT_INT itself only ever consumes VM_INPUT_DIGITS/
; VM_INPUT_COUNT/VM_INPUT_NEG_TMP -- it has no idea whether they were
; filled by OP_INPUT_NUM's own live-keyboard scan or, as here, a plain
; in-memory buffer scan; this is a thin adapter feeding it the same
; shape of data from a different source, not a reimplementation of the
; actual parsing arithmetic. Same char-filtering rules as OP_INPUT_NUM's
; own scanner: non-digit characters are silently skipped, '-' is only
; accepted as the very first character, and digits beyond
; VM_INPUT_DIGITS_MAX are discarded (matching, not inventing, that
; scanner's own existing overflow behavior).
; R10 correction (V2_SEMANTIC_CAPABILITY_AUDIT.md matrix row 6): VAL()
; now recognizes an optional '.' the same way the compiler's own
; LEX_SCAN_NUMBER does (digits before and after the dot accumulate into
; one running value; a separate counter tracks how many fractional
; digits were seen). VM_VAL_SEEN_DOT/VM_VAL_FRAC_COUNT reuse
; VM_INPUT_TARGET_TMP/VM_INPUT_CHARBUF -- BUILTIN_FN_VAL and OP_INPUT_*
; are different opcodes, never concurrently executing, so this costs no
; new RAM (same reuse convention VM_PARSE_INPUT_INT's own
; VM_ARR_VALUE_TMP borrow already established).
VM_VAL_SEEN_DOT:   equ VM_INPUT_TARGET_TMP
VM_VAL_FRAC_COUNT: equ VM_INPUT_CHARBUF
BUILTIN_FN_VAL:                 ; RC (Q-17): the shared number parser (stops at the first other
        rst $10                 ; character; values beyond 32767 and decimals are FLOATs)
        ld a,l
        call VM_STR_ADDR        ; HL -> [len][content]
        ld b,(hl)
        inc hl
        call NUM_PARSE_CALC
        jp NUM_PUSH_CALC

; VM_STR_ALLOC_TEMP -- allocates the next round-robin STRTAB temp slot,
; same allocation OP_STR_CONCAT's own body already performs inline (see
; its own header for the round-robin design). Out: HL = the new record's
; own address (content starts at HL+1 -- caller still writes byte 0,
; the length byte, itself), A = the new record's own STRTAB index (0-5,
; ready to push once the caller has written the record's content).
; Destroys: AF, DE, HL (HL is an OUTPUT, not preserved as an input).
VM_STR_ALLOC_TEMP:
        ld a,(RT_STR_COUNT)
        ld b,STRTAB_TEMP_COUNT
        ld e,TAG_STR
        call VM_TEMP_PICK        ; QUAL (Q-02): A = a string temp no stacked value refers to
        push af
        call VM_STR_ADDR          ; HL -> its record
        pop af
        ret

; QUAL (Q-02): temp-slot allocator. Two round-robin slots per kind used to be reused while
; still referenced from the operand stack (1.5+2.5*3.5 = 12.25, UPPER$("a")+LOWER$("B") = "bb").
; In: A = first temp index, B = slot count, E = tag (TAG_FLOAT / TAG_STR).
; Out: A = an index in [A, A+B) that no operand-stack entry (index, tag E) refers to.
; Every slot live -> STACK OVERFLOW (error 2), never a silent reuse. Destroys BC, D, HL, F.
VM_TEMP_PICK:
.try:
        ld d,a                   ; D = candidate
        ld hl,(VM_SP)
.scan:
        ld a,l
        cp LOW VM_STACK_TOP      ; the operand stack lies in one page ($B604-$B680)
        jr nc,.free
        ld a,(hl)                ; value low
        inc hl
        cp d
        jr nz,.skip2
        ld a,(hl)                ; value high (temp indices are < 256)
        or a
        jr nz,.skip2
        inc hl
        ld a,(hl)                ; tag
        cp e
        jr z,.used
        jr .next
.skip2:
        inc hl
.next:
        inc hl
        jr .scan
.used:
        ld a,d
        inc a
        djnz .try
        jp VM_ERR_STACK_OVERFLOW
.free:
        ld a,d
        ret

; CHR$(n) -- the 1-character string with ASCII code n. Int-only
; argument (VM_POP's own tag is ignored), matching V1's real CHR$
; behavior and the SGN/MOD/DIV/RND family's already-established "this
; is a pure-integer BASIC" precedent for this class of function.
BUILTIN_FN_CHR:
        rst $18                   ; HL = value (QUAL Q-30: a FLOAT was its slot index)
        ld a,h
        or a
        jr nz,.chr_range_err      ; h<>0 -- outside 0-255 in either
                                     ; direction (a negative two's-
                                     ; complement value has h<>0 too,
                                     ; e.g. -1 = $FFFF)
        ld a,l
        ld (BFN_STR_TMP),a         ; stash the character code across
                                      ; VM_STR_ALLOC_TEMP (destroys AF)
        call VM_STR_ALLOC_TEMP      ; HL -> dest record, A = new index
        push af
        ld (hl),1                  ; length byte = 1
        inc hl
        ld a,(BFN_STR_TMP)
        ld (hl),a
        jp VM_PUSH_STR_RESULT
.chr_range_err:
        ld a,15
        jp VM_ERR_COMMON

; STR$(n) -- n formatted as a decimal string, reusing the real VM_NUM_
; TO_TEXT conversion PRINT/LPRINT already use (see its own header).
BUILTIN_FN_STR:
        rst $10                    ; HL = value, A = tag
        call VM_NUM_TO_TEXT         ; HL = null-terminated decimal text
                                       ; (PRINT_BUF)
        ld (VM_STR_SRC_ADDR_TMP),hl
        call VM_STR_ALLOC_TEMP       ; HL -> dest record, A = new index
        ld (VM_STR_DST_ADDR_TMP),hl
        push af
        ld hl,(VM_STR_SRC_ADDR_TMP)
        ld de,(VM_STR_DST_ADDR_TMP)
        inc de                        ; DE -> dest content -- the real
                                         ; length byte is written once
                                         ; known, below
        ld b,0
.str_loop:
        ld a,(hl)
        or a
        jr z,.str_done
        ld a,b
        cp 31
        jr nc,.str_done               ; clamp to the record's own 31-
                                          ; byte cap (never actually
                                          ; reached by any real decimal/
                                          ; float rendering)
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        inc b
        jr .str_loop
.str_done:
        ld hl,(VM_STR_DST_ADDR_TMP)
        ld (hl),b
        jp VM_PUSH_STR_RESULT

; UPPER$(s) -- case-convert, byte for byte. Result length always equals
; the source length.
BUILTIN_FN_UPPER:
        rst $10                     ; HL = string index
        ld a,l
        call VM_STR_ADDR            ; HL -> src record
        ld (VM_STR_SRC_ADDR_TMP),hl
        call VM_STR_ALLOC_TEMP       ; HL -> dest record, A = new index
        ld (VM_STR_DST_ADDR_TMP),hl
        push af
        ld hl,(VM_STR_SRC_ADDR_TMP)
        ld a,(hl)                    ; source length
        inc hl                        ; HL -> source content
        ld de,(VM_STR_DST_ADDR_TMP)
        ld (de),a                     ; dest length byte
        inc de
        ld b,a
        or a
        jr z,.upper_done
.upper_loop:
        ld a,(hl)
        cp 'a'
        jr c,.upper_copy
        cp 'z'+1
        jr nc,.upper_copy
        sub 32
.upper_copy:
        ld (de),a
        inc hl
        inc de
        djnz .upper_loop
.upper_done:
        jp VM_PUSH_STR_RESULT

; LOWER$(s) -- case-convert, byte for byte. Mirrors UPPER$ exactly with
; the fold direction reversed.
BUILTIN_FN_LOWER:
        rst $10
        ld a,l
        call VM_STR_ADDR
        ld (VM_STR_SRC_ADDR_TMP),hl
        call VM_STR_ALLOC_TEMP
        ld (VM_STR_DST_ADDR_TMP),hl
        push af
        ld hl,(VM_STR_SRC_ADDR_TMP)
        ld a,(hl)
        inc hl
        ld de,(VM_STR_DST_ADDR_TMP)
        ld (de),a
        inc de
        ld b,a
        or a
        jr z,.lower_done
.lower_loop:
        ld a,(hl)
        cp 'A'
        jr c,.lower_copy
        cp 'Z'+1
        jr nc,.lower_copy
        add a,32
.lower_copy:
        ld (de),a
        inc hl
        inc de
        djnz .lower_loop
.lower_done:
        jp VM_PUSH_STR_RESULT

; LEFT$(s,n) -- the first n characters of s (clamped to the real source
; length; n<0 -> 0 characters). Compiled left-to-right (s then n), so
; the operand stack has n on top (popped first).
BUILTIN_FN_LEFT:
        rst $18                     ; HL = the count (QUAL Q-30)
        call VM_CLAMP_COORD         ; RC shrink: A = count clamped to 0..255 (negative 0)
        ld (BFN_STR_TMP),a
        rst $10                      ; HL = string index (s)
        ld a,l
        call VM_STR_ADDR             ; HL -> src record
        ld (VM_STR_SRC_ADDR_TMP),hl
        ld a,(hl)                    ; source length
        ld b,a
        ld a,(BFN_STR_TMP)
        cp b
        jr c,.left_clamped
        ld a,b
.left_clamped:
        ld (BFN_STR_TMP),a           ; final copy_len
        call VM_STR_ALLOC_TEMP        ; HL -> dest record, A = new index
        ld (VM_STR_DST_ADDR_TMP),hl
        push af
        ld hl,(VM_STR_SRC_ADDR_TMP)
        inc hl                        ; HL -> src content (LEFT$ always
                                         ; starts at the beginning)
        ld de,(VM_STR_DST_ADDR_TMP)
        ld a,(BFN_STR_TMP)
        ld (de),a                     ; dest length byte
        inc de
        ld b,a
        or a
        jr z,.left_done
.left_loop:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .left_loop
.left_done:
        jp VM_PUSH_STR_RESULT

; RIGHT$(s,n) -- the last n characters of s. Same n-resolution as
; LEFT$'s own; differs only in the source content's own start offset.
BUILTIN_FN_RIGHT:
        rst $18                     ; HL = the count (QUAL Q-30)
        call VM_CLAMP_COORD         ; RC shrink: A = count clamped to 0..255 (negative 0)
        ld (BFN_STR_TMP),a
        rst $10                       ; HL = string index (s)
        ld a,l
        call VM_STR_ADDR              ; HL -> src record
        ld (VM_STR_SRC_ADDR_TMP),hl
        ld a,(hl)                     ; source length
        ld b,a
        ld a,(BFN_STR_TMP)
        cp b
        jr c,.right_clamped
        ld a,b
.right_clamped:
        ld (BFN_STR_TMP),a            ; final copy_len
        call VM_STR_ALLOC_TEMP         ; HL -> dest record, A = new index
        ld (VM_STR_DST_ADDR_TMP),hl
        push af
        ld hl,(VM_STR_SRC_ADDR_TMP)
        ld a,(hl)                     ; source length again (HL not yet
                                          ; advanced past the length byte)
        ld b,a
        ld a,(BFN_STR_TMP)
        ld c,a                         ; C = copy_len
        ld a,b
        sub c                          ; A = start offset within content
        inc hl                         ; HL -> src content start
        ld e,a
        ld d,0
        add hl,de                      ; HL -> src content + start offset
        ld de,(VM_STR_DST_ADDR_TMP)
        ld a,c
        ld (de),a                      ; dest length byte
        inc de
        ld b,c
        or a
        jr z,.right_done
.right_loop:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .right_loop
.right_done:
        jp VM_PUSH_STR_RESULT

; MID$(s$, start, len) -- R10.7, R10.25 class C. Same LEFT$/RIGHT$
; skeleton (VM_STR_ADDR -> clamp -> VM_STR_ALLOC_TEMP -> copy loop);
; only the start offset differs (LEFT$ fixed at 0, RIGHT$ derived as
; srclen-n, MID$ an arbitrary caller-supplied 1-based start, clamped
; the same forgiving way real Sinclair BASIC's own MID$ does: start<1
; clamps to 1, start past the end yields an empty string, and a
; requested length longer than what remains is clamped to what
; remains -- no error raised for any of these, matching LEFT$/RIGHT$'s
; own precedent of forgiving-clamp over hard error).
BUILTIN_FN_MID:
        rst $18                     ; HL = the count (QUAL Q-30)
        call VM_CLAMP_COORD         ; RC shrink: A = count clamped to 0..255 (negative 0)
        ld (BFN_STR_TMP),a
        rst $18                      ; HL = start (1-based) (QUAL Q-30)
        call VM_CLAMP_COORD          ; RC shrink (Q-31 kept): the whole 16-bit start: negative -> 0,
        or a                         ; above 255 -> 255 (offset 254: past the end of any string)
        jr nz,.mid_start_ok
        inc a                        ; start<=0 clamps to 1
.mid_start_ok:
        dec a                        ; convert to a 0-based offset
        ld (BFN_MID_START_TMP),a
        rst $10                      ; HL = string index (s)
        ld a,l
        call VM_STR_ADDR             ; HL -> src record
        ld (VM_STR_SRC_ADDR_TMP),hl
        ld a,(hl)                    ; source length
        ld b,a                       ; B = srclen
        ld a,(BFN_MID_START_TMP)
        cp b
        jr c,.mid_start_in_range
        ld a,b                       ; start past the end -> offset=
                                        ; srclen (0 chars remain)
.mid_start_in_range:
        ld (BFN_MID_START_TMP),a     ; final 0-based start offset (<=srclen)
        ld c,a
        ld a,b
        sub c                        ; A = srclen - start = chars available
        ld d,a
        ld a,(BFN_STR_TMP)
        cp d
        jr c,.mid_len_clamped
        ld a,d
.mid_len_clamped:
        ld (BFN_STR_TMP),a           ; final copy_len
        call VM_STR_ALLOC_TEMP        ; HL -> dest record, A = new index
        ld (VM_STR_DST_ADDR_TMP),hl
        push af
        ld hl,(VM_STR_SRC_ADDR_TMP)
        inc hl                        ; HL -> src content start
        ld a,(BFN_MID_START_TMP)
        ld e,a
        ld d,0
        add hl,de                    ; HL -> src content + start offset
        ld de,(VM_STR_DST_ADDR_TMP)
        ld a,(BFN_STR_TMP)
        ld (de),a                    ; dest length byte
        inc de
        ld b,a
        or a
        jr z,.mid_done
.mid_loop:
        ld a,(hl)
        ld (de),a
        inc hl
        inc de
        djnz .mid_loop
.mid_done:
        jp VM_PUSH_STR_RESULT

; INKEY$() -- one keypress, as a 0- or 1-character string. Never
; blocks: kernel/io/io.asm's own IO_READ_KEY_NONBLOCK returns 0
; immediately if nothing is currently latched (same real ISR-latched-
; state contract IO_READ_KEY's own blocking wait already relies on --
; see that routine's header).
BUILTIN_FN_INKEY:
        call IO_READ_KEY_NONBLOCK
        or a
        jr z,.inkey_empty
        ld (BFN_STR_TMP),a
        call VM_STR_ALLOC_TEMP        ; HL -> dest record, A = new index
        push af
        ld (hl),1
        inc hl
        ld a,(BFN_STR_TMP)
        ld (hl),a
        jp VM_PUSH_STR_RESULT
.inkey_empty:
        call VM_STR_ALLOC_TEMP        ; HL -> dest record, A = new index
                                          ; (an empty string is still a
                                          ; real STRTAB record, same
                                          ; convention every other empty-
                                          ; string result already uses)
        ld (hl),0
        ld l,a
        ld h,0
        ld a,TAG_STR             ; QUAL (Q-02) -- was xor a
        jp VM_PUSH

; SQR(n) -- int-only argument (VM_POP's own tag is ignored), matching
; V1's own real SQR(n) contract (basic.asm's own BASIC_SQR_FLOAT
; header: "HL = n (signed 16-bit int)"). RESULT is always a real
; float, even SQR(0)=0.0 -- V1's own header documents a real bug from
; skipping that. kernel/math's own MATH_SQRT16 gives floor(sqrt(n)) as
; the initial guess (usually wrong -- SQR(2) genuinely is 1.4142...,
; not 1), refined by 4 Newton-Raphson iterations in float space
; (x_{k+1} = (x_k + n/x_k)/2) on the real calculator, reusing the
; already-proven VM_CALC_*_STUB/VM_FLOAT_PUSH_OPERAND/VM_FLOAT_STORE_
; RESULT infrastructure R6's own OP_ADD/SUB/MUL/DIV already established
; -- same iteration count/error-bound reasoning as basic.asm's own
; BASIC_SQR_FLOAT (its own header has the full exhaustive-check math).
; Reuses the real SQR_ARG_N sysvar (include/sysvars.inc) V1's own
; BASIC_SQR_FLOAT already owns for the identical purpose -- real,
; permanent RAM already budgeted, not a second scratch cell.
; QUAL (Q-10, Q-22): SQR of any non-negative number (was: the argument truncated to an integer
; first; a negative argument returned 0). Newton x' = (x + n/x)/2 from a guess within a factor of
; sqrt(2): isqrt(n) for the small-integer form, else 2^(e/2) built from n's exponent byte -- 5 steps
; give full calculator precision for every magnitude. A negative argument is error 15.
SQR_ARG_FP:     equ SIN_X_RAD     ; 5 bytes (SIN's scratch; never live together)
BUILTIN_FN_SQR:
        rst $10
        call VM_FLOAT_PUSH_FIRST     ; [n]
        call VM_CALC_CLASSIFY        ; A = sign of n
        or a
        jp z,VM_FLOAT_STORE_RESULT   ; SQR(0) = 0
        jp m,BUILTIN_FN_CHR.chr_range_err
        ld hl,CALC_STACK
        ld de,SQR_ARG_FP
        ld bc,5
        ldir                         ; SQR_ARG_FP = n
        ld hl,CALC_STACK
        ld a,(hl)
        or a
        jr nz,.sqr_exp_guess
        inc hl
        inc hl
        ld a,(hl)
        inc hl
        ld h,(hl)
        ld l,a                       ; HL = n (small-integer form: 1..65535)
        call MATH_SQRT16             ; HL = isqrt(n) >= 1
        xor a
        ld (CALC_SP),a
        call CALC_INT_TO_FP          ; [x0]
        jr .sqr_iter
.sqr_exp_guess:                      ; x0 = 2^floor((e+2)/2), e = exponent byte - 128
        sub 126
        sra a
        add a,128
        ld (hl),a
        inc hl
        ld b,4
.sqr_g:
        ld (hl),0                    ; mantissa 0.5 (implicit bit), positive
        inc hl
        djnz .sqr_g
.sqr_iter:
        ld b,5
.sqr_loop:
        push bc
        rst $28
        db $31,$38                   ; [x,x]
        ld hl,SQR_ARG_FP
        call CALC_PUSH_FP_RAW        ; [x,x,n]
        rst $28
        db $01,$05,$0F,$38           ; exchange, divide, add: [x + n/x]
        ld hl,2
        call CALC_INT_TO_FP
        rst $28
        db $05,$38                   ; [(x + n/x) / 2]
        pop bc
        djnz .sqr_loop
        jp VM_FLOAT_STORE_RESULT

; PI() -- the constant pi, via the real calculator's own already-wired
; CALC_PUSH_PI literal (rom/exrom_calc.asm; that file's own header
; documents the packed constant's provenance/accuracy). No argument.
BUILTIN_FN_PI:
        xor a
        ld (CALC_SP),a
        call CALC_PUSH_PI
        jp VM_FLOAT_STORE_RESULT

; RAD(x) -- degrees to radians (x*pi/180). DEG(x) -- radians to degrees
; (x*180/pi). Int-only argument (matching V1's own real RAD/DEG
; contract exactly); unlike V1's own BASIC_RAD_FLOAT/DEG_FLOAT (which
; manually extract the sign first and never reapply it to a negative
; result, a documented V1 simplification -- basic.asm's own header),
; CALC_INT_TO_FP already encodes a negative 16-bit int with the
; correct sign (confirmed from its own body: byte1 = $FF for h<0), so
; the real calculator's own multiply/divide propagate sign correctly
; on their own -- pushing the raw signed argument directly is simpler
; AND more correct than replicating V1's own sign-stripping, not a
; scope increase.
BUILTIN_FN_RAD:
        rst $10                  ; QUAL (Q-10): x as it is (was truncated)
        call VM_FLOAT_PUSH_FIRST
        call CALC_PUSH_PI          ; push pi
        call VM_CALC_MUL_STUB        ; x*pi
        ld hl,180
        call CALC_INT_TO_FP            ; push 180
        call VM_CALC_DIV_STUB            ; (x*pi)/180
        jp VM_FLOAT_STORE_RESULT

; SIN_PEEK_POP -- copies the calculator's current top-of-stack (5
; bytes) to (DE), then pops it (CALC_SP -= 1). Same real "CALC_STACK/
; CALC_SP are plain RAM, readable/writable regardless of EXROM paging"
; reasoning basic.asm's own CALC_PEEK_TOP_AND_POP header gives -- V2's
; own vm_core.asm is ALREADY EXROM-resident, so it needs no "avoid an
; EXROM round trip" wrapper at all, just this same direct manipulation.
; In: DE = destination. Out: (DE) = popped value. Destroys: AF, BC, HL.
SIN_PEEK_POP:
        push de
        ld a,(CALC_SP)
        dec a
        ld (CALC_SP),a          ; pop -- CALC_SP now IS the popped
                                   ; slot's own index
        ld l,a
        ld h,0
        ld b,h
        ld c,l
        add hl,hl                ; *2
        add hl,hl                ; *4
        add hl,bc                 ; *5
        ld bc,CALC_STACK
        add hl,bc                  ; HL -> the popped slot's address
        pop de
        ld bc,5
        ldir
        ret

; SIN(degrees) -- int-only argument (matching V1's own real SIN
; contract), a genuine 5-term (through x^9/9!) Taylor series in
; radians, real range reduction to a [0,90]-degree reference angle
; first -- same technique AND divisor table as basic.asm's own
; BASIC_SIN_FLOAT (that routine's own header has the full derivation
; of SIN_DIVISOR_TABLE's 6/20/42/72 values from the Taylor series'
; real per-term ratios). Reuses R6's own already-proven VM_CALC_*_STUB/
; CALC_INT_TO_FP/CALC_PUSH_PI/CALC_PUSH_FP_RAW/VM_FLOAT_STORE_RESULT
; infrastructure throughout, plus the REAL SIN_X_RAD/SIN_X2/SIN_POWER/
; FUNC_RESULT_FLOAT_NEGATIVE sysvars V1's own BASIC_SIN_FLOAT already
; owns for the identical purpose (include/sysvars.inc) -- real,
; permanent RAM already budgeted, not new scratch cells.
;
; Sign handling deliberately does NOT match V1's own documented
; simplification (extract the sign before reduction, and never
; reapply it to the final result -- basic.asm's own RAD/DEG header
; explains why V1 accepted that gap). V2 already has real signed-float
; negation (the same "push 0, push value, subtract" technique BUILTIN_
; FN_ABS's own float path already uses) at essentially no extra cost,
; so SIN(-x) correctly equals -SIN(x) here -- a real, deliberate
; improvement over V1, not scope creep (it costs a few extra bytes at
; the very end, not a new architecture), and required for this
; milestone's own SIN(-x)~=-SIN(x) symmetry test to pass at all.
; QUAL (Q-10): SIN/COS/TAN of a FLOAT number of degrees. The integer part k = trunc(x) is reduced
; exactly as before (16-bit, mod 360, folded to [0,90]); the fraction f = x - k (SIN_POWER, a 5-byte
; value; 0 for an INT argument) follows the same folds -- negated whenever the fold negates the
; angle (SIN_FRAC_NEG) -- and is added back before the series: angle = reference +/- f.
SIN_FRAC_NEG:   equ BFN_ABS_IDX_TMP   ; 1 byte (ABS's scratch; never live together)
BUILTIN_FN_SIN:
        rst $10                      ; HL = value, A = tag
        cp TAG_FLOAT
        jr nz,.sin_int_arg
        call VM_FLOAT_PUSH_FIRST     ; [x]
.sin_calc_arg:                       ; CALC_STACK[0] = x (CALC_SP = 1)
        ld hl,CALC_STACK
        ld de,SIN_POWER
        ld bc,5
        ldir                         ; SIN_POWER = x
        ld hl,CALC_STACK
        call FP_TRUNC                ; [k]
        ld b,0
        rst $28
        db $31,$38                   ; [k,k]
        call CALC_FP_TO_INT          ; HL = k, [k]
        jp c,BUILTIN_FN_CHR.chr_range_err   ; |x| >= 32768 degrees: error 15
        push hl
        ld hl,SIN_POWER
        call CALC_PUSH_FP_RAW        ; [k,x]
        ld b,0
        rst $28
        db $01,$03,$38               ; exchange, subtract: [x - k] = [f]
        ld de,SIN_POWER
        call SIN_PEEK_POP            ; SIN_POWER = f
        pop hl
        jr .sin_frac_set
.sin_int_arg:
        push hl
        ld hl,SIN_POWER
        call FP_TRUNC.zero           ; f = 0
        pop hl
.sin_frac_set:
        xor a
        ld (SIN_FRAC_NEG),a
.sin_have_int:
        ; ---- reduce to a reference angle in [0,90], track sign ----
        ld de,360
        call MATH_MOD16                ; HL = degrees mod 360 (signed,
                                          ; sign of the dividend)
        xor a
        ld (FUNC_RESULT_FLOAT_NEGATIVE),a
        ld a,h
        or a
        jp p,.sin_nonneg
        ld a,1
        ld (FUNC_RESULT_FLOAT_NEGATIVE),a
        ld (SIN_FRAC_NEG),a          ; QUAL (Q-10): the fraction is negated with the angle
        ld a,h
        cpl
        ld h,a
        ld a,l
        cpl
        ld l,a
        inc hl
.sin_nonneg:
        ; HL = |degrees mod 360| in [0,359]; fold [180,359] down via
        ; sin(x+180) = -sin(x)
        ld a,h
        or a
        jr nz,.sin_ge180
        ld a,l
        cp 180
        jr c,.sin_lt180
.sin_ge180:
        ld de,180
        or a
        sbc hl,de
        ld a,(FUNC_RESULT_FLOAT_NEGATIVE)
        xor 1
        ld (FUNC_RESULT_FLOAT_NEGATIVE),a
.sin_lt180:
        ; HL in [0,179]; fold (90,179] down: reference = x if x<=90
        ; else 180-x
        ld a,l
        cp 91
        jr c,.sin_ref_done
        ld de,180
        ex de,hl
        or a
        sbc hl,de                       ; HL = 180-x (operands swapped
                                            ; by the ex above)
        ld a,(SIN_FRAC_NEG)
        xor 1
        ld (SIN_FRAC_NEG),a             ; QUAL (Q-10): 180 - (k + f) = (180 - k) - f
.sin_ref_done:
        ; a reference angle of exactly 0 has no sign either way (both
        ; 0 and 180 fold to a 0 reference) -- force the flag off so a
        ; fold that flipped it doesn't produce a cosmetic "-0.0000"
        ld a,h
        or l
        jr nz,.sin_ref_nonzero
        ld a,(SIN_POWER)
        or a
        jr nz,.sin_ref_nonzero        ; QUAL (Q-10): a nonzero fraction keeps its sign
        ld (FUNC_RESULT_FLOAT_NEGATIVE),a
.sin_ref_nonzero:
        ; ---- degrees -> radians: x_rad = degrees * pi / 180 ----
        xor a
        ld (CALC_SP),a
        call CALC_INT_TO_FP           ; push degrees: [d]
        ld hl,SIN_POWER
        call CALC_PUSH_FP_RAW         ; [d,f]
        ld a,(SIN_FRAC_NEG)
        or a
        jr nz,.sin_fsub
        call VM_CALC_ADD_STUB         ; [d + f]
        jr .sin_fdone
.sin_fsub:
        call VM_CALC_SUB_STUB         ; [d - f]
.sin_fdone:
        call CALC_PUSH_PI               ; push pi: [d,pi]
        call VM_CALC_MUL_STUB             ; [d*pi]
        ld hl,180
        call CALC_INT_TO_FP               ; push 180: [d*pi,180]
        call VM_CALC_DIV_STUB               ; [x_rad]
        ld de,SIN_X_RAD
        call SIN_PEEK_POP                     ; SIN_X_RAD = x_rad;
                                                 ; stack empty
        ; ---- x2 = x_rad^2 ----
        ld hl,SIN_X_RAD
        call CALC_PUSH_FP_RAW            ; [x_rad]
        ld hl,SIN_X_RAD
        call CALC_PUSH_FP_RAW             ; [x_rad,x_rad]
        call VM_CALC_MUL_STUB               ; [x2]
        ld de,SIN_X2
        call SIN_PEEK_POP                     ; SIN_X2 = x2; stack empty

        ; ---- acc = x_rad (term_0); power = x_rad ----
        ld hl,SIN_X_RAD
        ld de,SIN_POWER
        ld bc,5
        ldir
        ld hl,SIN_X_RAD
        call CALC_PUSH_FP_RAW             ; [acc]

        ld hl,SIN_DIVISOR_TABLE
        ld b,4
.sin_term_loop:
        push bc
        push hl                             ; save divisor-table ptr
        ld hl,SIN_POWER
        call CALC_PUSH_FP_RAW                 ; [acc,power]
        ld hl,SIN_X2
        call CALC_PUSH_FP_RAW                  ; [acc,power,x2]
        call VM_CALC_MUL_STUB                    ; [acc,power*x2]
        pop hl                                  ; HL = divisor-table ptr
        ld e,(hl)
        inc hl
        ld d,(hl)
        inc hl
        push hl                                  ; save advanced ptr
        ex de,hl                                  ; HL = this term's D_k
        call CALC_INT_TO_FP                        ; push D_k:
                                                       ; [acc,power*x2,D_k]
        call VM_CALC_DIV_STUB                         ; [acc,power]
        ld de,SIN_POWER
        call SIN_PEEK_POP                                ; SIN_POWER =
                                                             ; new power;
                                                             ; [acc]
        ld hl,SIN_POWER
        call CALC_PUSH_FP_RAW                              ; [acc,power]
        pop hl                                              ; advanced
                                                               ; table ptr
        pop bc                                                ; loop
                                                                 ; counter
        push hl
        push bc
        ld a,b
        and 1
        ; B is the DJNZ countdown (4,3,2,1 across passes k=1,2,3,4 --
        ; djnz decrements at the BOTTOM, so pass k sees B's PRE-
        ; decrement value), not k itself: B even (4,2) means k odd
        ; (1,3) -> SUBTRACT; B odd (3,1) means k even (2,4) -> ADD.
        jr z,.sin_term_sub
        call VM_CALC_ADD_STUB
        jr .sin_term_combined
.sin_term_sub:
        call VM_CALC_SUB_STUB
.sin_term_combined:
        pop bc
        pop hl
        djnz .sin_term_loop

        ; stack: [acc] -- the reference angle's own non-negative sine
        ld a,(FUNC_RESULT_FLOAT_NEGATIVE)
        or a
        jr z,.sin_done
        ld de,SIN_POWER                    ; reuse -- no longer needed
        call SIN_PEEK_POP                     ; SIN_POWER = acc; stack
                                                 ; empty (CALC_SP=0)
        ld hl,0
        call CALC_INT_TO_FP                       ; push 0: [0]
        ld hl,SIN_POWER
        call CALC_PUSH_FP_RAW                       ; push acc: [0,acc]
        call VM_CALC_SUB_STUB                         ; [0-acc] = [-acc]
.sin_done:
        jp VM_FLOAT_STORE_RESULT

SIN_DIVISOR_TABLE: dw 6, 20, 42, 72

; COS(x) -- R10.7, R10.25 class C. COS(x) = SIN(x+90); reuses SIN's own
; degree-reduction/Taylor-series body entirely (BUILTIN_FN_SIN.sin_have_
; int, same cross-scope local-label reference this file's own decompiler
; sibling already establishes as a precedent) -- only the +90 shift
; before entry is new. Int-only argument (matching RAD/DEG's own
; contract), but a FLOAT argument is still accepted and truncated first
; (same tolerance SIN itself already extends), matching R10.25's own
; audit note.
BUILTIN_FN_COS:
        rst $10                      ; HL = value, A = tag
        cp TAG_FLOAT
        jr nz,.cos_int
        call VM_FLOAT_PUSH_FIRST     ; QUAL (Q-10): COS(x) = SIN(x + 90) in FLOAT
        ld hl,90
        call CALC_INT_TO_FP
        call VM_CALC_ADD_STUB
        jp BUILTIN_FN_SIN.sin_calc_arg
.cos_int:
        ld de,90
        add hl,de
        jp BUILTIN_FN_SIN.sin_int_arg

; TAN(x) -- R10.7, R10.25 class C. TAN(x) = SIN(x)/COS(x) via the
; existing calculator division primitive, with a divide-by-zero guard
; (COS(x)=0 at x=90+180n) -- the calculator itself already raises
; overflow on divide-by-zero (VM_CALC_DIV_STUB's own callers elsewhere
; in this file rely on the same behavior), so no new error path is
; invented here.
; QUAL (Q-10): TAN(x) = SIN(x)/COS(x). x is first copied into a fresh FLOAT temp T that stays
; referenced at the bottom of the operand stack while COS and SIN run, so neither result can be
; stored into its slot (the old version re-pushed the caller's slot after SIN had freed it, and COS
; then read SIN's result: TAN(45.5) gave 0.7133).
BUILTIN_FN_TAN:
        rst $10
        call VM_FLOAT_PUSH_FIRST
        call VM_FLOAT_STORE_RESULT   ; [T]
        rst $10                      ; A/HL = T
        push af
        push hl
        call VM_PUSH
        pop hl
        pop af
        push af
        push hl
        call VM_PUSH                 ; [T, T]
        call BUILTIN_FN_COS          ; [T, c]
        pop hl
        pop af
        call VM_PUSH                 ; [T, c, T]
        call BUILTIN_FN_SIN          ; [T, c, s]
        call VM_PREPARE_BINARY_OPERANDS   ; A = c, B = s; [T]
        rst $10                      ; drop T
        ld a,(VM_FLOAT_A_TAG)
        ld hl,(VM_FLOAT_A_VAL)
        call VM_FLOAT_TEST_ZERO      ; COS(x) = 0 at x = 90 + 180n
        jp z,VM_ERR_DIVIDE_BY_ZERO
        call VM_CALC_PUSH_AB         ; [c, s]
        ld b,0
        rst $28
        db $01,$05,$38               ; exchange, divide: [s / c]
        jp VM_FLOAT_STORE_RESULT

; FREE() -- 0 args, always a real int. R10.25 class B item: a thin
; wrapper over kernel/memory/memory.asm's own MEM_FREE_BYTES, which
; already computes and is already labeled "Backs BASIC's FREE()".
BUILTIN_FN_FREE:
        ld hl,(VM_CSP)           ; R10.7 P4: the gap between the arrays and
        ld de,(ARRAYS_END)       ; the control stack is what is really free
        or a
        sbc hl,de
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH

; FREE(n) -- R10.7 P5.5. FREE(1) = bytes free in array segment 2 ($E000-$E7FF);
; any other argument behaves as FREE() (the main pool, up to the control stack).
BUILTIN_FN_FREE_N:
        rst $18                  ; HL = n
        dec hl
        ld a,h
        or l
        jr nz,BUILTIN_FN_FREE
        ld hl,ARR2_LIMIT
        ld de,(ARR2_END)
        or a
        sbc hl,de
        jp VM_PUSH_INT          ; RC shrink: TAG_INT + VM_PUSH

BUILTIN_FN_DEG:
        rst $10                  ; QUAL (Q-10): x as it is (was truncated)
        call VM_FLOAT_PUSH_FIRST
        ld hl,180
        call CALC_INT_TO_FP        ; push 180
        call VM_CALC_MUL_STUB        ; x*180
        call CALC_PUSH_PI              ; push pi
        call VM_CALC_DIV_STUB            ; (x*180)/pi
        jp VM_FLOAT_STORE_RESULT

; ---------------------------------------------------------------------------
; Error exits — each sets VM_ERROR_CODE and VM_HALTED, then returns to the
; caller (the driver), which inspects both.
; ---------------------------------------------------------------------------
VM_ERR_ILLEGAL_OPCODE:
        ld a,1
        jr VM_ERR_COMMON

VM_ERR_STACK_OVERFLOW:
        ld a,2
        jr VM_ERR_COMMON

VM_ERR_STACK_UNDERFLOW:
        ld a,3
        jr VM_ERR_COMMON

VM_ERR_FLOAT_NOT_IMPLEMENTED:
        ld a,4
        jr VM_ERR_COMMON

VM_ERR_DIVIDE_BY_ZERO:
        ld a,5
        jr VM_ERR_COMMON

VM_ERR_CALL_STACK_OVERFLOW:
        ld a,6
        jr VM_ERR_COMMON

VM_ERR_CALL_STACK_UNDERFLOW:
        ld a,7
        jr VM_ERR_COMMON

VM_ERR_INVALID_SOUND_REGISTER:
        ld a,8
        jr VM_ERR_COMMON

VM_ERR_EXTENSION_NOT_FOUND:
        ld a,9
        jr VM_ERR_COMMON

VM_ERR_ARRAY_BOUNDS:
        ld a,10
        jr VM_ERR_COMMON

VM_ERR_ARRAY_TYPE:
        ld a,11
        jr VM_ERR_COMMON

; VM_ERR_ARRAY_SPACE -- R10.7 dynamic-array redesign: OP_DIM's own
; arena-exhaustion guard (ARRAYS_END+needed would reach/exceed VARS_
; START). The clean, caught error the fixed-pool design never needed
; ("memory exhaustion produces a clean error" requirement).
VM_ERR_ARRAY_SPACE:
        ld a,64                 ; R10.7 P0: was 16, which collided with the
        jr VM_ERR_COMMON        ; SPRITE package's own range error (16)

; VM_ERR_CHR_RANGE -- R8.5 Group 6: CHR$'s argument was outside 0-255.
; Reached inline via BUILTIN_FN_CHR's own "jp VM_ERR_COMMON" (no
; separate named routine needed -- kept here as documentation of the
; code, matching this table's own existing style).
; Error code 15 (12-14 retired, see the note above).

; VM_ERR_INVALID_MODE/ULAPLUS/PALETTE (error codes 12-14) removed --
; dead code now that OP_MODE/OP_ULAPLUS/OP_PALETTE no longer exist here.
; The loadable ext_mode_module.asm owns its own error codes/reporting,
; same as ext_sprite_module.asm already does.

; STUDY (D11): signed 16x16 multiply with overflow detection, built on MATH_SIGN_PREP / MATH_APPLY_SIGN.
; In: HL = a, DE = b.  Out: HL = product, carry clear; carry SET = |a*b| does not fit INT16.
VM_MUL_CHECKED:
        call MATH_SIGN_PREP     ; HL = |a|, DE = |b|, (MATH_SIGN) = $80 when the result is negative
        ld b,d
        ld c,e                  ; BC = |b| (multiplier)
        ex de,hl                ; DE = |a| (multiplicand)
        ld hl,0
.loop:
        ld a,b
        or c
        jr z,.done              ; multiplier exhausted
        srl b
        rr c
        jr nc,.shift
        add hl,de
        jr c,.ovf               ; partial sum >= 65536
.shift:
        sla e
        rl d
        jr nc,.loop
        ld a,b
        or c
        jr z,.loop              ; the lost bit would only be multiplied by 0
        jr .ovf                 ; a set multiplier bit remains: product >= 65536
.done:
        bit 7,h
        jr z,.fits              ; 0..32767
        ld a,(MATH_SIGN)
        or a
        jr z,.ovf               ; positive result >= 32768
        ld a,h
        xor $80
        or l
        jr nz,.ovf              ; negative result: only exactly -32768 fits
.fits:
        call MATH_APPLY_SIGN    ; (the negate path leaves carry set)
        or a
        ret
.ovf:
        scf
        ret

VM_ERR_COMMON:
        ld (VM_ERROR_CODE),a
        ld a,1
        ld (VM_HALTED),a
        ld sp,(VM_RUN_SP)       ; QUAL (Q-03/Q-18): unwind. An error used to return into whatever
        ret                     ; called the raising routine, which then carried on (array stores wrote
                                ; out of bounds after VM_ARR_VALIDATE_INDEX failed; OP_AND/OP_OR
                                ; returned through a pushed operand -> jp $0001 = cold start)

; VM_TEST_ARGTYPE_BIT -- bounded ROM consolidation pass: rom/exrom_v2_
; compiler.asm's own COMPILE_TEST_ARGTYPE_BIT and rom/exrom_v2_
; decompiler.asm's own DECOMP_TEST_ARGTYPE_BIT were byte-IDENTICAL
; routines (confirmed by direct comparison, not assumed from the
; similar names) -- both compile-time and decompile-time argtype-bit
; tests need the exact same "rotate the mask right by the argument
; index, then test bit 0" logic. Kept here (vm_core.asm is included by
; every build that includes either of the other two, so this is always
; reachable) as the ONE real copy; both call sites now just `call
; VM_TEST_ARGTYPE_BIT` across the file boundary, the same cross-file
; call pattern this codebase already uses throughout (e.g. compiler.asm
; calling kernel/extensions/ext_registry.asm's own EXT2_LOOKUP).
;
; Input: A = argtypes bitmask, B = argument index (0-7). Output: Z flag
; set if that bit is clear (numeric), NZ if set (string). Destroys: AF,
; B, D.
VM_TEST_ARGTYPE_BIT:
        ld d,b                  ; D = index (rotation count)
        ld b,a                  ; B = mask (rotated in place)
.rot_loop:
        ld a,d
        or a
        jr z,.done
        ld a,b
        srl a
        ld b,a
        dec d
        jr .rot_loop
.done:
        ld a,b
        bit 0,a
        ret

VM_CORE_END:
VM_RUN_LOOP EQU VM_RUN.loop   ; R10.9: exported for the EXROM array service

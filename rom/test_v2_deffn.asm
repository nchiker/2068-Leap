; ============================================================================
; rom/test_v2_deffn.asm — post-R9 semantic-completion milestone: DEF FN
; reintegration (docs/v2/deffn_design/README.md, docs/v2/
; V2_SEMANTIC_CAPABILITY_AUDIT.md S11/S21).
;
; Standalone ROM image exercising rom/exrom_v2_compiler.asm's new
; COMPILE_DEF_FN/.udf_call (COMPILE_FACTOR) and rom/exrom_v2_vm_core.asm's
; JMP_DEFFN/CALL_UDF/RET_DEFFN opcode aliases, reusing the SAME OP_PARAM_
; BIND/OP_PARAM_UNBIND reentrant mechanism rom/test_v2_proc_recursion.asm
; already proves for PROC. NOT wired into the production BASIC dispatch
; or the shipping EXROM build.
;
; Source program compiled and executed:
;
;   DEF FN SQ(X)=X*X:DEF FN INC(X)=X+1:
;   DEF FN SQINC(X)=FN SQ(FN INC(X)):DEF FN TRUNC2(X)=INT(X):
;   DEF FN R(N)=FN R(N-1)+N:
;   A=FN SQ(5):B=FN SQINC(3):C=FN TRUNC2(3.7):D=FN R(1)
;
; Exercises:
; - simple single-argument definition and call (SQ): A = 5*5 = 25
; - a function call used as the ARGUMENT to another function call
;   (SQINC calls INC(X) then SQ() of that result), proving the nested-
;   call scratch-clobber protection: B = SQ(INC(3)) = SQ(4) = 16
; - a FLOAT argument flowing through PARAM_BIND correctly (the same
;   copy-into-the-parameter's-own-dedicated-FLOATTAB-slot path OP_
;   STORE_VAR's own .float_store already uses) and INT() genuinely
;   truncating it (this milestone's own FLOAT/type-boundary fix,
;   BUILTIN_FN_INT/VM_POP_COERCE_INT): C = INT(3.7) = 3
; - genuine self-recursion (FN R calls itself, unconditionally -- DEF
;   FN's body is a bare expression with no conditional construct, so
;   real recursion here can only ever be bounded by the shared VM_CALL_
;   STACK/VM_PARAM_SAVE_SP depth limit, not by a language-level base
;   case): D = FN R(1) recurses until VM_CALL_PUSH's own bounds check
;   fires VM_ERR_CALL_STACK_OVERFLOW (error 6) -- a clean, deterministic
;   VM error, not a hang or memory corruption, proving the reentrant
;   parameter mechanism holds up under real recursive stress and
;   generalizes correctly from PROC to DEF FN.
;
; Build:
;   tools/sjasmplus_strict.sh --sym=build/test_v2_deffn.sym \
;       rom/test_v2_deffn.asm
; Run (PASS=green/FAIL=red border):
;   ts2068-debug start --rom build/smoke/test_v2_deffn_zesarux.bin
;   ts2068-debug run --max-instructions 3000000
;   ts2068-debug timex   (border field)
; ============================================================================

    INCLUDE "include/hardware.inc"
    INCLUDE "include/sysvars.inc"


    DEVICE NOSLOT64K

    ORG $0000
RST_00:
    di
    jp   COLD_START
    DS   $0028 - $, $FF
    ; RST $28 -- the real calculator's real entry vector, per rom/
    ; exrom_calc.asm's own documented "ENTRY CONTRACT" header: a plain
    ; `jp CALC_EXROM_ENTRY` is exactly right here, no paging trampoline
    ; needed, because this whole test image is a single flat bank (no
    ; real HOME/EXROM split) -- same wiring as rom/test_v2_compiler_r6.asm
    ; and rom/test_v2_vm_milestone01.asm (both also include the real
    ; calculator).
    jp   CALC_EXROM_ENTRY
    DS   $0100 - $, $FF

COLD_START:
    ld   sp, $FF00

    call COMPILER_INIT
    ld   hl, SOURCE_TEXT
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM

    ld   a, (COMPILE_ERROR_CODE)
    or   a
    jp   nz, FAIL

    ld   hl, (EMIT_PTR)
    ld   (DECOMP_END_ADDR), hl

    call VM_INIT
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    call VM_RUN

    ; D=FN R(1) deliberately recurses until the call stack overflows --
    ; VM_ERROR_CODE must be exactly 6 (VM_ERR_CALL_STACK_OVERFLOW), not 0
    ; and not some other error, and VM_HALTED must be set.
    ld   a, (VM_ERROR_CODE)
    cp   6
    jp   nz, FAIL
    ld   a, (VM_HALTED)
    or   a
    jp   z, FAIL

    ; A/B/C were all computed and stored correctly BEFORE the fatal
    ; recursion, so their SYMTAB values must already be right.
    call CHECK_RESULT
    jp   c, FAIL

PASS:
    ld   a, 4                ; green
    out  (PORT_ULA), a
    jr   $

FAIL:
    ld   a, 2                ; red
    out  (PORT_ULA), a
    jr   $

SOURCE_TEXT:
    db "DEF FN SQ(X)=X*X:DEF FN INC(X)=X+1:"
    db "DEF FN SQINC(X)=FN SQ(FN INC(X)):DEF FN TRUNC2(X)=INT(X):"
    db "DEF FN R(N)=FN R(N-1)+N:"
    db "A=FN SQ(5):B=FN SQINC(3):C=FN TRUNC2(3.7):D=FN R(1)", 0

; ============================================================================
; CHECK_RESULT — direct SYMTAB memory reads. Compiler assigns indices in
; first-use order: X (all four SQ/INC/SQINC/TRUNC2 parameters share the
; SAME name, hence the SAME index -- ordinary CSYMTAB scoping, no
; separate per-function namespace, same as PROC) -> 0; N (FN R's own
; parameter, a distinct name) -> 1; A -> 2; B -> 3; C -> 4.
; ============================================================================
CHECK_RESULT:
    ld   a, (SYMTAB_BASE + 2*3)     ; A's own tag
    cp   0
    jr   nz, .fail
    ld   hl, (SYMTAB_BASE + 2*3 + 1)
    ld   de, 25
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   a, (SYMTAB_BASE + 3*3)     ; B's own tag
    cp   0
    jr   nz, .fail
    ld   hl, (SYMTAB_BASE + 3*3 + 1)
    ld   de, 16
    or   a
    sbc  hl, de
    jr   nz, .fail
    ld   a, (SYMTAB_BASE + 4*3)     ; C's own tag
    cp   0
    jr   nz, .fail
    ld   hl, (SYMTAB_BASE + 4*3 + 1)
    ld   de, 3
    or   a
    sbc  hl, de
    jr   nz, .fail
    ret
.fail:
    scf
    ret

; Test-only stubs: this file's own test program never exercises PRINT's
; own real screen output, LPRINT/BEEP/SOUND/PAUSE/INPUT, and never
; registers or calls a loadable extension -- same stubbing discipline as
; every other v2 test.
BASIC_STMT_LPRINT_EXROM:
    ret
SOUND_BEEP:
    ret
SOUND_EXROM:
    or a
    ret
IO_READ_KEY:
    xor a
    ret
INT_GET_FRAMES:
    ld hl,0
    ret
EXT2_LOOKUP:
    scf
    ret
EXT2_SLOT_ADDR:
    ret
EXT_CALL_ARG0: equ $8B00
EXT_CALL_ARG4: equ $8B00
EXT2_TABLE:    equ $8B00

KTAB_CALC_EXIT_TRAMPOLINE:
    ret

; COMPILE_PROGRAM unconditionally writes DECOMP_END_ADDR (a decompiler-
; owned label) even when the decompiler itself isn't linked in -- same
; mechanical requirement every pre-decompiler-inclusion v2 test file
; already had (docs/v2/V2_SEMANTIC_CAPABILITY_AUDIT.md S2's own root-
; cause note on this exact "Label not found" failure). This test never
; calls DECOMPILE_PROGRAM, so the address just needs to resolve, not do
; anything real.
DECOMP_END_ADDR: equ $BD9F

; This test's own program DOES produce a real FLOAT value (the literal
; 3.7 passed to FN TRUNC2), so -- unlike test_v2_for_step.asm/test_v2_
; proc_recursion.asm's own pure-integer stubbing -- the real calculator
; is needed here, same as test_v2_group6_math.asm.
    INCLUDE "kernel/math/math.asm"
    INCLUDE "rom/exrom_calc.asm"
; kernel/graphics/graphics.asm (2235 real lines) is NOT included here:
; this test never checks real screen bitmap content or calls PRINT's own
; real rendering path.
GFX_CLS:
    ret
GFX_PAINT_ATTR:
    ret
GFX_SET_BORDER:
    ret
GFX_WRITE_PIXEL:
    ret
GFX_LINE:
    ret
GFX_PRINT_STRING_ATTR:
    ret
GFX_SCROLL_OUTPUT_UP:
    ret
GFX_SET_MODE:
    ret
GFX_SPRITE_CAPTURE:
    or a
    ret
GFX_SPRITE_DRAW:
    or a
    ret
GFX_READ_PIXEL:
    xor a
    ret
GFX_CELL_ATTR_ADDR:
    scf
    ret
; kernel/memory/memory.asm is NOT included here -- checked directly:
; neither rom/exrom_v2_vm_core.asm/compiler.asm/decompiler.asm reference
; any MEM_*/PROG_END/PROG_AREA_START/ARRAYS_END/VARS_START symbol, and
; this test never touches the real editor engine.
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/exrom_v2_vm_core.asm"
    INCLUDE "rom/exrom_v2_compiler.asm"
; rom/exrom_v2_decompiler.asm (3500+ real lines) is NOT included here:
; combined with the real calculator this test's own float literal (3.7)
; genuinely needs, all three together overflow this flat 16K image by
; over 2KB. DEF FN's own decompiler support (opcodes 52-54's dispatch,
; .op_jmp_deffn/.op_call_udf/.op_ret_deffn, DECOMP_COMBINE_UINT16) is
; instead verified by rom/test_v2_deffn_decompile.asm, a separate,
; pure-integer (no calculator needed) companion test.

    DS   $4000 - $, $FF

    SAVEBIN "test_v2_deffn.bin", $0000, $4000

; ============================================================================
; rom/test_v2_run_tables.asm -- R10.7 P3 regression test.
;
; The run-time tables (SYMTAB, FLOATTAB, STRTAB, array pointer tables) are no
; longer fixed reservations: VM_INIT carves them, exactly sized, from the top
; of the pool from the compiler's counts (VM_CARVE_TABLES). This test drives
; counts far past the old caps (32 numeric, 8 string, 16 numeric arrays, 8
; string arrays):
;
;   * 100 numeric variables, 40 string variables, 24 numeric arrays, 12 string
;     arrays, a float expression and string concatenations (their temp slots
;     follow the program's own variables), all in ONE program
;   * T = V1+V50+V100 = 151, U = A24(1)+A1(1) = 75, LEN(S1$+S40$) = 5 ('x1x40'),
;     G = INT(2.5*4)+1 = 11, LEN(B12$(1)+B1$(1)) = 5 ('b12b1') -- every one read
;     through the real VM_SYM_ADDR, so a wrong base or an overlap between the
;     carved tables would show up as a wrong value
;   * RT_NUM_COUNT / RT_STR_COUNT / VARS_START describe the carve, and the carved
;     block lies entirely above ARRAYS_END and below the zone
;
; Finally the compile symbol table is made to look as if it filled the pool; the
; carve cannot fit and the run must be REFUSED cleanly with VM error 64 (out of
; memory) and the VM halted -- never a silent overlap.
; ============================================================================
    DEFINE TEST_V2_CUSTOM_CHECKS
    INCLUDE "rom/test_v2_harness_home_head.inc"
    INCLUDE "rom/test_v2_symmacros.inc"

DECOMP_END_ADDR: equ $9900

TEST_CUSTOM_MAIN:
    ld   hl, SRC_BIG
    call COMPILE_SRC
    jp   nz, TEST_FAIL
    call RUN_PROGRAM
    ld   a, (VM_ERROR_CODE)
    or   a
    jp   nz, TEST_FAIL

    ; the carve: counts, ordering and bounds
    ld   a, (RT_NUM_COUNT)
    cp   106                                      ; V1..V100, T, U, N, F, G, M
    jp   nz, TEST_FAIL
    ld   a, (RT_STR_COUNT)
    cp   42                                  ; S1$..S40$, C$, D$
    jp   nz, TEST_FAIL
    ld   hl, (VARS_START)
    ld   de, (ARRAYS_END)
    or   a
    sbc  hl, de
    jp   c, TEST_FAIL                        ; block must not reach the arena
    ld   hl, (RT_SYMTAB_PTR)
    ld   de, (VARS_START)
    or   a
    sbc  hl, de
    jp   nz, TEST_FAIL                       ; SYMTAB is the lowest table = VARS_START
    ld   hl, (RT_FLOATTAB_PTR)
    ld   de, (RT_SYMTAB_PTR)
    or   a
    sbc  hl, de
    jp   c, TEST_FAIL                        ; FLOATTAB above SYMTAB
    ld   hl, (RT_STRTAB_PTR)
    ld   de, (RT_FLOATTAB_PTR)
    or   a
    sbc  hl, de
    jp   c, TEST_FAIL                        ; STRTAB above FLOATTAB
    ld   hl, V2_SOURCE_END
    ld   de, (RT_STRTAB_PTR)
    or   a
    sbc  hl, de
    jp   c, TEST_FAIL                        ; everything below the zone

    ld   hl, NM_T
    ld   b, 1
    ld   de, 151
    call CHECK_VAR
    jp   c, TEST_FAIL
    ld   hl, NM_U
    ld   b, 1
    ld   de, 75
    call CHECK_VAR
    jp   c, TEST_FAIL
    ld   hl, NM_N
    ld   b, 1
    ld   de, 5
    call CHECK_VAR
    jp   c, TEST_FAIL
    ld   hl, NM_G
    ld   b, 1
    ld   de, 11
    call CHECK_VAR
    jp   c, TEST_FAIL
    ld   hl, NM_M
    ld   b, 1
    ld   de, 5
    call CHECK_VAR
    jp   c, TEST_FAIL
    ld   hl, NM_V77
    ld   b, 3
    ld   de, 77
    call CHECK_VAR
    jp   c, TEST_FAIL

    ; refusal: pretend the compile symbol table already fills almost all the pool
    ; (SYM_END_V near the top); the carve for even a tiny program cannot fit
    ld   hl, SRC_SMALL
    call COMPILE_SRC
    jp   nz, TEST_FAIL
    ld   hl, V2_SOURCE_END - 100
    ld   (SYM_END_V), hl
    call RUN_PROGRAM
    ld   a, (VM_ERROR_CODE)
    cp   64
    jp   nz, TEST_FAIL
    ld   a, (VM_HALTED)
    or   a
    jp   z, TEST_FAIL
    jp   TEST_PASS

; CHECK_VAR -- HL = name, B = length, DE = expected value. Carry set on mismatch.
CHECK_VAR:
    push de
    ld   c, SYM_K_NUM
    call SYM_FIND
    jr   c, .bad
    call VM_SYM_ADDR
    inc  hl
    ld   a, (hl)
    inc  hl
    ld   h, (hl)
    ld   l, a
    pop  de
    or   a
    sbc  hl, de
    ret  z
    scf
    ret
.bad:
    pop  de
    scf
    ret

NM_T: db "T"
NM_U: db "U"
NM_N: db "N"
NM_G: db "G"
NM_M: db "M"
NM_V77: db "V77"

COMPILE_SRC:
    push hl
    ld   hl, PROG_AREA_START
    ld   (PROG_END), hl
    ld   (ARRAYS_END), hl
    ld   hl, V2_SOURCE_END
    ld   (VARS_START), hl
    call COMPILER_INIT
    pop  hl
    ld   (SRC_PTR), hl
    ld   hl, VM_CODE_BASE
    ld   (EMIT_PTR), hl
    call COMPILE_PROGRAM
    ld   a, (COMPILE_ERROR_CODE)
    or   a
    ret

RUN_PROGRAM:
    call VM_INIT
    ld   a, (VM_ERROR_CODE)
    or   a
    ret  nz                      ; refused by the carve
    ld   hl, VM_CODE_BASE
    ld   (VM_IP), hl
    jp   VM_RUN

SRC_BIG:
    db 'V1=1:V2=2:V3=3:V4=4:V5=5:V6=6:V7=7:V8=8:V9=9:V10=10:V11=11:V12=12:V13=13:V14=14:V15=15:V16=16:V17=17'
    db ':V18=18:V19=19:V20=20:V21=21:V22=22:V23=23:V24=24:V25=25:V26=26:V27=27:V28=28:V29=29:V30=30:V31=31:V'
    db '32=32:V33=33:V34=34:V35=35:V36=36:V37=37:V38=38:V39=39:V40=40:V41=41:V42=42:V43=43:V44=44:V45=45:V46'
    db '=46:V47=47:V48=48:V49=49:V50=50:V51=51:V52=52:V53=53:V54=54:V55=55:V56=56:V57=57:V58=58:V59=59:V60=6'
    db '0:V61=61:V62=62:V63=63:V64=64:V65=65:V66=66:V67=67:V68=68:V69=69:V70=70:V71=71:V72=72:V73=73:V74=74:'
    db 'V75=75:V76=76:V77=77:V78=78:V79=79:V80=80:V81=81:V82=82:V83=83:V84=84:V85=85:V86=86:V87=87:V88=88:V8'
    db '9=89:V90=90:V91=91:V92=92:V93=93:V94=94:V95=95:V96=96:V97=97:V98=98:V99=99:V100=100:S1$="x1":S2$="x2'
    db '":S3$="x3":S4$="x4":S5$="x5":S6$="x6":S7$="x7":S8$="x8":S9$="x9":S10$="x10":S11$="x11":S12$="x12":S1'
    db '3$="x13":S14$="x14":S15$="x15":S16$="x16":S17$="x17":S18$="x18":S19$="x19":S20$="x20":S21$="x21":S22'
    db '$="x22":S23$="x23":S24$="x24":S25$="x25":S26$="x26":S27$="x27":S28$="x28":S29$="x29":S30$="x30":S31$'
    db '="x31":S32$="x32":S33$="x33":S34$="x34":S35$="x35":S36$="x36":S37$="x37":S38$="x38":S39$="x39":S40$='
    db '"x40":DIM A1(3):A1(1)=3:DIM A2(4):A2(1)=6:DIM A3(5):A3(1)=9:DIM A4(6):A4(1)=12:DIM A5(7):A5(1)=15:DI'
    db 'M A6(8):A6(1)=18:DIM A7(2):A7(1)=21:DIM A8(3):A8(1)=24:DIM A9(4):A9(1)=27:DIM A10(5):A10(1)=30:DIM A'
    db '11(6):A11(1)=33:DIM A12(7):A12(1)=36:DIM A13(8):A13(1)=39:DIM A14(2):A14(1)=42:DIM A15(3):A15(1)=45:'
    db 'DIM A16(4):A16(1)=48:DIM A17(5):A17(1)=51:DIM A18(6):A18(1)=54:DIM A19(7):A19(1)=57:DIM A20(8):A20(1'
    db ')=60:DIM A21(2):A21(1)=63:DIM A22(3):A22(1)=66:DIM A23(4):A23(1)=69:DIM A24(5):A24(1)=72:DIM B1$(2,8'
    db '):B1$(1)="b1":DIM B2$(2,8):B2$(1)="b2":DIM B3$(2,8):B3$(1)="b3":DIM B4$(2,8):B4$(1)="b4":DIM B5$(2,8'
    db '):B5$(1)="b5":DIM B6$(2,8):B6$(1)="b6":DIM B7$(2,8):B7$(1)="b7":DIM B8$(2,8):B8$(1)="b8":DIM B9$(2,8'
    db '):B9$(1)="b9":DIM B10$(2,8):B10$(1)="b10":DIM B11$(2,8):B11$(1)="b11":DIM B12$(2,8):B12$(1)="b12":T='
    db 'V1+V50+V100:U=A24(1)+A1(1):C$=S1$+S40$:N=LEN(C$):F=2.5*4:G=INT(F)+1:D$=B12$(1)+B1$(1):M=LEN(D$)'
    db 0
SRC_SMALL:
    db 'S1$="a":X=1', 0

; Test-only stubs (same discipline as rom/test_v2_scalar_capacity32.asm).
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
GFX_READ_PIXEL:
    xor a
    ret
GFX_CELL_ATTR_ADDR:
    scf
    ret
    INCLUDE "kernel/extensions/ext_registry.asm"
    INCLUDE "rom/exrom_format.asm"
IO_READ_KEY_NONBLOCK:
        xor a
        ret

    INCLUDE "rom/test_v2_harness_home_tail.inc"

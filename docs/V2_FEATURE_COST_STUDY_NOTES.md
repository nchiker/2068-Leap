# Study notes (running log; source for docs/V2_FEATURE_COST_STUDY.md)
Baseline 7ae0599: HOME 565 free, EXROM 802 free. Known defects baseline: 14 XFAIL 3 PASS (verified in study/baseline).

## BREAK (D5/D5b) -- branch study/break, worktree ~/2068-Leap-study/break, commit 8ee4f1a
- ISR (kernel/interrupt/interrupt.asm, accept path, IFDEF V2_PRODUCTION) on decoded KEY_BREAK sets VM_ERROR_CODE=66, VM_HALTED=1;
  VM_RUN.loop already tests VM_HALTED each opcode => zero per-opcode cost, no VM opcode poll. VM_INIT clears both at RUN => stale request inert.
- EXROM: V2_RUNTIME_MSG 66 -> "BREAK"; EditorLoop ignores any code <$20 (D5b). PAUSE n wait loop polls VM_HALTED.
- Cost: HOME -21 (565->544), EXROM -13 (802->789). Variant w/o PAUSE poll: HOME -14 (551). 
- Tests: tools/study_break_matrix.py 6/6 x2 runs (REAL matrix: CAPS+SPACE via send-keys-event -> ISR). Existing D5 case pokes latch => would stay XFAIL; D5b flips XPASS.
- Limits: INPUT key-wait & package loops (FILL) not interruptible until they return; BREAK keycap physical matrix pos unverified.

## D9a/D9b edit preservation -- branch study/edit-preserve, worktree ~/2068-Leap-study/edit-preserve
- D9b alone (re-enter editor without EDITOR_INIT/V2_LOAD_EDIT after PROGRAM FULL; label .reenter): MEASURED HOME 0, EXROM 0 (802 free).
- D9a (V2_NAV_COMMIT: compare buffer vs record, store via shared V2_STORE_EDIT on UP/DOWN/insert-line, keep buffer+cursor on PROGRAM FULL): HOME 0, EXROM -83 (719 free).
  Variant "no compare, always store when buffer non-empty": EXROM -55 (747 free) but clears arrays + rewrites store on every navigation: rejected.
- Tests: known-defects D9-edit-survives-navigation & D9-program-full-keeps-text -> XPASS; D9-nav-plain PASS; tools/study_edit_preserve.py 9/9 (append-line UP commit, DOWN no-op on append line, unchanged nav writes nothing, arrays kept, insert-line, PROGRAM FULL on nav keeps buffer+cursor).
- commit 'STUDY edit-preserve' on branch study/edit-preserve

## U6 display reset -- branch study/u6-display, worktree ~/2068-Leap-study/u6-display
- V2_RESET_DISPLAY (CURRENT_* defaults, border 7, mode 0) shared by boot head + every `.loop` (return to editor). No CLS at .loop (editor redraw already clears; avoids extra flicker).
- MEASURED: HOME 0, EXROM -4 (802->798). Known-defect U6-mode1-return -> XPASS; tools/study_u6.py 4/4 (colour state, MODE 1 return incl. status-bar attr $07, border, second-run clean).
- Not verified: ULAplus palette/enable state on real hardware (emulator has no ULAplus here); hi-res on hardware.

## D11 integer overflow -- branches study/d11-error (commit 'STUDY d11-error'), study/d11-promote (stacked on d11-error)
Tools: tools/study_vm_oracle.py (REAL Z80 driver in ZEsarUX: boundary grid + random pairs vs exact Python reference), tools/study_d11_print.py, tools/d11_ablate.py.
Key discoveries (baseline, MEASURED): (1) float literals digit mantissa is 16-bit: 9999.5 prints -3107.6999, 12345.678 prints 24.9099; (2) floats |x|>=32768 print as "32767.////" (BASIC_FLOAT_TO_STRING uses 16-bit CALC_FP_TO_INT);
  (3) FOR counter wraps at 32767 (infinite loop); (4) POKE 65000 / USR(61440) literals > 32767 are used as 16-bit address patterns by the test corpus (tests/math5, usr1, hit) => rejecting literals > 32767 breaks address literals.
Error variant (overflow -> runtime error 67 "NUMERIC OVERFLOW"; literal > 32767 -> error 64): HOME -101 (565->464), EXROM -23 (802->779).
  Breakdown HOME: ADD 5, SUB 3, checked MUL 63 (VM_MUL_CHECKED shift-add w/ carry/lost-bit detection), FOR_NEXT 5, lexer LEX_ACCUM_DIGIT range check 21 (shared digit routine), VM_ERR_OVERFLOW 4; EXROM: message+mapping 23.
  Oracle: mul 105,476 pairs, 0 mismatches; mulop (via real VM_RUN bytecode) / add / sub ~100k each: 0 mismatches (see logs). Known-defects D11-* all XPASS, D11-ok-in-range PASS.
Promotion variant (overflow -> float via existing float path): arithmetic (ADD/SUB/MUL/FOR) HOME -76 (565->489), EXROM 0; large-float display (FLOAT_BIG_TO_STRING: 32-bit mantissa>>shift, 10-digit decimal, ".0000") EXROM -106 (802->696). 
  Total promote (arith+display, no literal change): HOME -76, EXROM -106. Prints: 30000*3 -> 90000.0000; 32767*32767 -> 1073676289.0000; FOR i=32765 TO 32767 terminates; 181*181 stays int. Limit: fraction of floats >=32768 not shown; exponent >= 2^32 saturates.

## IN / OUT / STICK core-ROM variant -- branch study/lang-hw (2 commits), worktree ~/2068-Leap-study/lang-hw
- OUT port,value = new statement keyword (token 65, opcode 67, VM handler `out (c),a` with BC = full 16-bit port); IN(port) = builtin fn_index 30 (`in a,(c)`); STICK(n) = builtin fn_index 31 (removed V1 STICK_READ algorithm: AY reg 14 via PORT_AY_REG/PORT_AY_DATA).
- MEASURED HOME costs (isolated ablation): OUT +56, IN +22, STICK +45 = -123 (565->442), EXROM 0. 
- Shrink found while doing it: BEEP/SOUND/POKE/PLOT/OUT share one COMPILE_2ARG_STMT helper (same shape as the existing COMPILE_1ARG_STMT): saves 43 B => OUT+IN+STICK net HOME -80 (565->485). Behaviour of BEEP/SOUND/POKE/PLOT unchanged (same error codes/order).
- Tests tools/study_lang_hw.py 6/6: AY register round trip via OUT/IN ports $F5/$F6; IN full 16-bit: with key '1' held, IN(63486)=$BE (row 1-5 bit0 low), IN(65278)=$BF, IN(65022)=$BF while low-byte-only IN(254)=$BE; STICK idle = 0 for 1 and 2; errors for OUT 1 arg (22) / IN() (3).
- NOT verified: STICK directions (ZEsarUX has no Timex-joystick event path in ts2068-debug); non-$FE-mirrored port on real hardware (AY ports are the natural test: needs hardware); name collision: variables named IN / STICK become functions (compat break, documented).
- Decompiler (test-only) knows IN/STICK table rows (check_builtin_tables passes) but not OP_OUT (not implemented in prototype).

## CALL p(FN f(x)) -- branch study/bugfix-callfn
- ROOT CAUSE (found by reading, confirmed by test): COMPILE_CALL_STMT stashes the PROC name in the shared STMT_IDENT_NAME_BUF; the argument's nested `.udf_call` re-stashes "f" there, so the CALL was emitted for label f (the FN body) instead of p ("passes 0" was a symptom). .udf_call parked its own copy; CALL_STMT did not.
- FIX: factor .udf_call's inline park/restore into COMPILE_EXPR_KEEPNAME, used by both. MEASURED HOME +4 (565->561), EXROM 0. tools/study_callfn.py: 7/7 on the fix; 5/7 FAIL on baseline (baseline has 2 passing controls).
- Classification: correctness defect (compiler); release-critical-ish (silent wrong call), tiny.

## End-of-source errors name the opening line -- branch study/eof-for-line (FOR only)
- FOR frame +2 bytes (CSTK_FRAME_LEN 5->7: +2 B RAM per open FOR, compile stack), store LEX_LINE at COMPILE_FOR, set LEX_LINE from the innermost open frame before error 65. MEASURED HOME -23 (565->542), EXROM 0. 5/5 cases (simple, later, nested inner closed, outer closed, continuation lines). The existing gate case D4-eof-for (expects the append line) would be changed to the FOR line.
- PROC (16), block IF (9) and forward-label (7) NOT prototyped: ESTIMATED ONLY +30..60 B each (PROC/IF state is in globals / hardware stack, not on the compile stack).

## MOD(N,15) in demos/showcase.txt -- diagnosis (no prototype of a fix kept)
- Phase 2D report's "MOD(N,15) is not a V2 function" is WRONG: MOD(a,b) IS a built-in (fn_index 2) and works (MOD(20,15)=5, in DEF FN too).  Real cause: showcase has `DIM N(...)` and `DEF FN T(N)=MOD(N,15)`: a DIM'd array name used as a value is parsed as an array read and requires '(' (error 40) -- array and scalar namespaces collide. Infix `a MOD b` is an unsupported operator (error 64 now).
- Classification: demo/name-resolution issue. Cheapest fix = rename the parameter in the demo; a compiler fix (fall back to the scalar when no '(' follows the array name) is ESTIMATED ONLY ~+20 B HOME.

## Extension FUNCTIONS (ABI 2.1) + HW package -- branch study/extfn
- FINDING: the existing registry is STATEMENT-ONLY (EXT_CALL_RESULT is reserved/unused, docs say "no extension functions"); STICK/IN cannot be exposed as functions without a compiler+VM change. The new mechanism is an ABI MINOR addition: registration C bit 7 = function; compiler parses NAME(args) (COMPILE_FACTOR hook + '('/')' in COMPILE_EXT_CALL), OP_CALL_EXT operand bit 7 = push EXT_CALL_RESULT as INT; EXT_CALL_RESULT pinned ($BEE0); PKG_ABI_MINOR 0->1 (old package tapes still load; new function packages refused by old ROMs). check_package_abi: "ABI 2.1 -- 16 service slots, 35 pinned cells ... all checks passed".
- MEASURED: mechanism HOME -95 (565->470), EXROM 0. Package rom/ext_v2_hw_module.asm = 110 B for OUT + IN() + STICK() (of 1024 B window). RAM 0.
- Tests tools/study_extfn.py 8/9 (the one 'FAIL' is only the expected error CODE differing: 28 not 22); AY round trip, 16-bit port keyboard half-rows, STICK idle, IN() inside expressions, unloaded package -> compile error, function without '(' -> error 51.
- Trade-off: package route = ZERO HOME for each added function after the 95 B mechanism, but: needs the tape load every session; ONE package resident at a time (HW would evict SPRITE/SHAPES/MODE/GRAPHICS/PRINTER); name can't be used as a variable once loaded.
- Core route (lang-hw): OUT 56 + IN 22 + STICK 45 = 123 B, or 80 B after the COMPILE_2ARG_STMT shrink.  Break-even: package route wins only if >= ~3 further function candidates are added.
- d11-promote final (branch study/d11-promote-lit = promote + literal policy L-A, unused error-67 code/message removed): MEASURED HOME -99 (565->466), EXROM -106 (802->696). Literal policy L-A: 0..65535 accepted (32768..65535 are 16-bit ADDRESS patterns: POKE 65000 / USR(61440) tests pass; PRINT 65535 still shows -1), >= 65536 error 64; decimal mantissa > 32767 error 64 (was garbage: 12345.678 -> 24.9099). tools/study_d11_literals.py 11/13 (2 expectations were mine: 12345.5 is now correctly rejected; 3276.7 shows 3276.6999 = pre-existing D10 truncation).
- Literal policies measured: L-B (all >32767 = error): lexer share 21 B but BREAKS address literals (tests/math5, usr1, hit use POKE 65000/61440/33508); L-A above; L-C (promote 32768..65535 to float + address coercion for POKE/PEEK/USR/IN/OUT) ESTIMATED ONLY +40..60 B HOME.

## PRINT multi-item + INPUT prompt -- branch study/lang-print
- Grammar: PRINT item {(';'|',') item} [';'|','] ; bare PRINT = newline; trailing separator suppresses the newline; ',' tabs to the next 16-column zone (next line from the right half). INPUT "prompt"; v / INPUT "prompt", v. Lexer gains ';' (TOK_SEMI 65).
- Bytecode change: OP_PRINT_NUM/STR no longer end the line; new OP_NL (67) and OP_PRINT_COMMA (68); PRINT_STR keeps VM_OUTPUT_COL (INPUT echo continues after the prompt). Bytecode is not persisted (source is) => no tape-format impact.
- MEASURED HOME -150 (565->415), EXROM 0 (unoptimised first cut). Tests tools/study_lang_print.py 13/13 read the SCREEN back through the ROM font (single/semicolon/comma zones/trailing ;/bare PRINT/blocks/INPUT prompt+echo+value; errors 64 and 22).
- Standalone component tests (bytecode-asserting) NOT run for this prototype; the decompiler (test-only) does not know OP_NL/OP_PRINT_COMMA.

## Shrink (shrink-z80 pattern scan, hand-validated) -- branch study/shrink-pos
- z80_pattern_scan.py on the shell/compiler/VM: the only high-value repeated sequence was `ld hl,(CUR_EDIT_POS) / ld a,h / cp $FF` x8 in rom/exrom_v2_shell.asm -> V2_POS_IS_APPEND helper (flags/HL identical at every site): MEASURED EXROM +17 free (802->819), HOME 0. (more in the combined builds: D9 adds 3 sites => ~+26.)
- COMPILE_2ARG_STMT (lang-hw): HOME +43.  COMPILE_EXPR_KEEPNAME (bugfix-callfn): the shared helper makes the CALL fix cost only +4 B instead of ~+40.  TOK_ENDS_STMT (lang-print ablation): -6 B on PRINT (not applied).  V2_STORE_EDIT / V2_RD_CLEAR_ROWS: shared subroutines (cost-neutral).

## NEW FINDING: bare identifier line accepted silently -- branch study/bare-ident
- A line holding only an identifier (`PRNT`, `CLEARR`, `CONT`, `COPY`, `RESTORE`, `x`) compiles with error 0 and does NOTHING: CR is lexed as TOK_COLON, so `.ident_stmt` took "ident <CR>" for a label definition `ident:`. Unsupported/mistyped command words are silently ignored (D3 family, not closed by Phase 2D). MEASURED on baseline.
- FIX (reuses Phase 2D's LEX_NEWLINE_PENDING flag: the ':' that follows must not be a line end): MEASURED HOME -8 (565->557), EXROM 0. tools/study_bare_ident.py 13/13 (7 bare-word cases now error 64; real labels, GOTO, PROC, `x = 1:` unchanged).
- Classification: correctness defect, release-critical class (silent ignore of a command), tiny.

## LIST abortable (R10.8 ED5) -- measured only: `cp KEY_BREAK / ret z` after the page-end key wait: EXROM -3 (802->799). (baseline copy, not a branch)

## D7 FILL completeness -- branch study/fill-d7
- SHAPES package: PUSH records a dropped seed (SHAPES_OVF); when the stack is dry and something was dropped, a RESUMABLE row-major sweep of the visited bitmap seeds every fillable 4-neighbour of every visited pixel (cursor SHAPES_RX/RY; stops at the pixel when the stack fills, drains, resumes); a drop during a drain marks the sweep dirty -> one more sweep. 
- MEASURED: package 795 -> 1007 B (+212 incl. BREAK polling per seed and per sweep row, study_fill_break.py: a FILL running on the staggered pattern returns within 2M instructions of VM_HALTED=1; first cut was 997 B (+202); 27 B left of the 1024 B window). RAM 8 B inside the package image. HOME 0, EXROM 0.
- v2_fill_check.py 10/10 unchanged (no overflow => identical code path & timing).  Adversarial scenarios, exact pixel comparison with an independent flood fill: noise-10pct, noise-25pct, noise-40pct, ladder-2px XPASS/PASS; staggered-dots and ladder-1px-teeth exact (0 differing pixels) but EMULATED TIME 787 s and 453 s (3.528 MHz); noise-10pct 120 s, noise-25pct 102 s.  The first (non-resumable) rescan timed out on the harness cap of 400M instructions; the resumable sweep fixed the pass count but each sweep is ~49k visited-bit tests + 4 neighbour tests per visited pixel.
- Honest assessment: correctness restored (no silent partial fill); pathological images are minutes-slow on real clock. A faster exact algorithm (span stack with run-length seeds, or growing the seed stack via the 6 KB visited-bitmap bank when free) is NOT studied.

## Interaction finding (oracle sensitivity) -- D9 x I2
- Merge a4f0710 (D9 commit-on-navigate + I2 two-line redraw, before any fix): `study_flicker.py --diff append-up` => diff_mismatches=1 (an append-line commit followed by UP leaves the status "LINE n/m" stale because the same-index fast path does not redraw the status). Fix (commit 3b6b183): clear V2_REDRAW_SCOPE in V2_SHOW_MESSAGE and after a V2_NAV_COMMIT store. Cost +8 B EXROM. The differential oracle is therefore known to be able to fail.
- Another integration fact: core OUT keyword broke tests/test_v2_control_stack (a label named OUT); `make check` legacy EXROM fixture only has 96 B below $DFC0 (big-float display excluded there with IFNDEF EDITOR_TEST_EXROM); component-test EXROMs have no exrom_calc (display routine must use only sysvars + the carry from CALC_FP_TO_INT).

## I1b -- cell-level typing redraw (branch study/flicker-i1b, based on flicker-i1)
- Old row table parked on the hardware stack (0 fixed RAM beyond 9 scratch bytes $BEC2-$BECC); new table compared; first row whose start/length changed or that holds the first changed character is redone from that column; cells are OVERWRITTEN with GFX_PUTCHAR (never cleared first), trailing cells of a shrunk row blanked; attrs of the active rows reset; cursor.
- MEASURED: EXROM -341 total (I1 was -123: +218 B for the finer step), HOME 0, RAM 11 B scratch. type-10lines (typing at the START of a 37-char line, the worst case for an incremental redraw): 69,562 -> 39,918 T/key (baseline 591,281); type-wrapchg 203,312 -> 108,829; differential oracle 0 mismatches in 3 scenarios (type-10lines, type-wrapchg, mixed-session). No GFX_CLEAR_ROW_TEXT, no V2_DRAW_TEXT call on the typing path => no blank interval at all.
- Real unit costs measured on the baseline: GFX_CLS 194,038 T; GFX_CLEAR_ROW_TEXT 24,834 T per row; GFX_PUTCHAR 696-833 T. (My earlier prose figures of 1.5-1.9k T per PUTCHAR and 48k per row clear were wrong; corrected in the report.)

## IN()/STICK() handlers in EXROM -- branch study/lang-hw-exrom (on lang-hw)
- Fixed 3-byte jp slots V2_EXROM_IN_ADDR/V2_EXROM_STICK_ADDR ($C0E6/$C0E9; array service moved to $C0EC), handlers in new rom/exrom_v2_hwio.asm, crossbank names VM_POP_COERCE_INT/VM_PUSH added. MEASURED BUT NOT FULLY VERIFIED (production build + study_lang_hw 6/6; standalone component tests not run, they would need V2_EXROM_IN_ADDR stubs).
- OUT+IN+STICK: HOME 565->533 (-32; core variant -80), EXROM 802->748 (-54; core 0). Total 86 B vs 80 B in core: the EXROM placement trades 48 HOME bytes for 54 EXROM bytes — useful only to protect the HOME 350 B reserve.

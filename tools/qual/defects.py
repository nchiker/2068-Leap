"""Defect register of the qualification study (data used by qcoverage.py and the reports).

Severity: CRITICAL (silent data/memory corruption, or loss of the program), HIGH (silently wrong
results in ordinary programs), MEDIUM (wrong results in less common cases, or a documented feature
behaving differently), LOW (robustness/usability), DOC (documentation only), TEST (test
infrastructure), DECISION (owner decision, not a defect).  Byte costs are signed like the cost
study: "HOME -8" = 8 bytes of HOME consumed.  [M] = measured on study/qualification-costs
(Essential base), [E] = estimate.
"""
SEV_ORDER = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "DOC", "TEST", "DECISION", ""]

D = {
 # id: (severity, configs, title, root cause, fix / cost)
 "Q-01": ("CRITICAL", "all", "String comparison compares only the lengths",
          "VM_STR_COMPARE: push hl / ex de,hl / ... / pop hl leaves DE = HL = string A; the content loop compares A with itself",
          "ex de,hl twice instead of push/pop [M] HOME 0"),
 "Q-02": ("CRITICAL", "all", "Two round-robin temporaries per kind are reused while still live (float and string)",
          "OP_PUSH_STR_LIT/OP_STR_CONCAT/VM_STR_ALLOC_TEMP/VM_FLOAT_STORE_RESULT take the next of 2 slots unconditionally",
          "VM_TEMP_PICK (first slot not referenced on the operand stack), TAG_STR=2, 4 slots per kind [M] HOME +40 (saves), RAM +74, var caps 253->251"),
 "Q-03": ("CRITICAL", "all", "AND/OR with a float operand jumps to the operand value (cold start, program lost)",
          "OP_AND/OP_OR raise VM_ERR_FLOAT_NOT_IMPLEMENTED with an operand pushed; VM_ERR_COMMON's ret pops it as the return address",
          "VM_ERR_COMMON restores VM_RUN_SP (shared with Q-18) [M] HOME -11 for both"),
 "Q-04": ("CRITICAL", "all", "DIM of more than ~8 KB wraps the 16-bit size arithmetic and zero-fills over the stack",
          "VM_ARENA_FIT adds the request to ARRAYS_END / ARR2_END ($E000) without a carry check; count*width uses truncating MATH_MULTIPLY16",
          "carry = no fit; VM_MUL_CHECKED; >16383 elements -> OUT OF MEMORY [M] HOME -8, EXROM -6"),
 "Q-05": ("MEDIUM", "essential enhanced", "-32768 prints +32768.0000 (literal rule L-A + D11 promotion)",
          "unary minus compiles 0 - $8000; the overflow check promotes the exact result 32768",
          "fold -<integer literal> in COMPILE_FACTOR [M] HOME -18 (or literal rule L-C)"),
 "Q-06": ("HIGH", "all", "IF on a float value tests its float-table slot index, not the value",
          "OP_JMPZ tests HL of the popped entry regardless of its tag",
          "call VM_FLOAT_TEST_ZERO [M] HOME -1"),
 "Q-07": ("HIGH", "all", "FOR runs its body once when the start is already past the limit (manual: never)",
          "OP_FOR_INIT has no entry test", "FOR frame redesign (with Q-08/Q-19/Q-20) [M] HOME -102 for all four"),
 "Q-08": ("HIGH", "all", "FOR start/limit/step given a float use its slot index; a float loop variable hangs NEXT",
          "OP_FOR_INIT pops without a tag check; OP_FOR_NEXT reads the raw value",
          "MITIGATED on study/qualification-costs (error 11); owner decision 1 (2026-10-11): implement floating-point FOR -- prototype study/proto-float-for variant D [M] HOME -97, all 30 float-FOR cases PASS. Open until integrated"),
 "Q-09": ("MEDIUM", "all", "A decimal literal with 5+ fractional digits overflows the 16-bit divisor silently",
          "LEX_SCAN_NUMBER multiplies CNUM_DIVISOR_TMP by 10 without a range check (0.00001 = 1/34464)",
          "5th fractional digit -> error 64, like L-A [M] HOME -5"),
 "Q-10": ("HIGH", "all", "SGN/SQR/RAD/DEG/SIN/COS/TAN/MOD/DIV truncate a float argument to an integer",
          "the built-ins call VM_POP_COERCE_INT (CALC_FP_TO_INT, truncation) before computing",
          "SGN/SQR/RAD/DEG on the float operand [E] HOME -40..-60; SIN/COS/TAN float degrees [E] HOME -40..-70"),
 "Q-11": ("MEDIUM", "all", "A PROC or DEF FN defined inside a PROC body corrupts the enclosing PROC",
          "PROC_SKIP_PATCH_TMP / PROC_PARAM_INDEX_TMP are single globals reused by the inner definition",
          "park both across the body [M] HOME -16 (or reject nested definitions [E] -8..-12)"),
 "Q-12": ("LOW", "all", "A duplicate label is accepted silently (the first definition wins)",
          "LABEL_DEFINE returns quietly when the label exists", "compile error 57 [M] HOME -4"),
 "Q-13": ("MEDIUM", "all", "MOD(x,0) and DIV(x,0) return 0 silently (manual: DIVISION BY ZERO)",
          "MATH_UDIV16 returns 0 for a zero divisor; the built-ins do not check", "shared operand pop + zero check [M] HOME -2"),
 "Q-14": ("LOW", "all", "CLS does not move the PRINT position to the top", "OP_CLS leaves VM_OUTPUT_ROW/COL", "[M] HOME -6"),
 "Q-15": ("MEDIUM", "all", "INPUT of a number ignores '.' (1.5 is read as 15)", "OP_INPUT_NUM accepts digits and a leading '-' only",
          "parse through the VAL path (fraction) [E] HOME -15..-25"),
 "Q-16": ("MEDIUM", "all", "INPUT of a number wraps above 32767 (99999 -> -31073); 5 digits; no editing keys",
          "VM_PARSE_INPUT_INT uses truncating MATH_MULTIPLY16", "overflow -> promote or reject [E] HOME -10..-30; DELETE key [E] -10..-15"),
 "Q-17": ("LOW", "all", "VAL skips non-digits (VAL(\"12abc34\") = 1234) and wraps above 32767",
          "BUILTIN_FN_VAL's tolerant scan", "PARTLY FIXED: stop at the first non-digit [M] HOME 0; wrap above 32767 still open [E] -10..-30"),
 "Q-18": ("CRITICAL", "all", "An out-of-range or wrongly-typed array store reports the error but still writes",
          "VM_ARR_VALIDATE_INDEX / VM_POP_CHECK_INT jp to VM_ERR_*; VM_ERR_COMMON returns into OP_ARR_STORE/OP_STRARR_STORE, which completes the store (a(-1)= rewrites the descriptor count)",
          "VM_ERR_COMMON restores VM_RUN_SP (shared with Q-03) [M] HOME -11 for both"),
 "Q-19": ("MEDIUM", "all", "NEXT reached without its FOR (GOTO into a loop, FOR skipped by IF) loops forever",
          "OP_FOR_NEXT uses the VM_FOR_LIMIT/STEP globals of whatever loop ran last", "FOR frame redesign (error 7)"),
 "Q-20": ("HIGH", "all", "After GOTO out of an inner FOR, the outer NEXT uses the inner loop's limit and step",
          "only the innermost loop's limit/step live in globals; the abandoned inner loop's values stay there", "FOR frame redesign"),
 "Q-21": ("LOW", "all", "CLEAR inside a FOR loop zeroes the loop variable: the loop never ends",
          "MEM_CLEAR_V2 zeroes the scalars, not the loop frames", "decision: CLEAR ends active loops / error [E] HOME -6..-12"),
 "Q-22": ("LOW", "all", "SQR of a negative number returns 0 silently", "MATH_SQRT16 returns 0 for a negative argument", "error [E] HOME -5"),
 "Q-23": ("LOW", "essential enhanced", "STICK(n) for n other than 1 or 2 returns a value (manual: INVALID ARGUMENT)",
          "BUILTIN_FN_STICK: dec l / jr nz treats every n<>1 as stick 2", "range check [E] HOME -6..-8"),
 "Q-24": ("LOW", "all", "CALL of a plain label (no PROC) is accepted; GOTO into a PROC fails only at run time",
          "labels and procedures share one namespace", "mark PROC labels [E] HOME -10..-20"),
 "Q-25": ("LOW", "all", "A string comparison cannot be combined with AND/OR or used as a value (compile error)",
          "COMPILE_IF handles one string comparison as the whole condition", "part of L-STR"),
 "Q-26": ("LOW", "all", "[ \\ ] ^ ` { | } ~ print as blanks", "the font holds a punctuation subset (PUNCT_CHAR_TABLE)", "document, or 9 glyphs [E] HOME -72..-90"),
 "Q-27": ("HIGH", "all", "PRINT of a string-function result shows the tail of an earlier string",
          "LEFT$/RIGHT$/MID$/CHR$/STR$/string-array reads write no NUL; PRINT prints up to a NUL", "print by the length byte [M] HOME -12 (with Q-28)"),
 "Q-28": ("CRITICAL", "all", "A 31-character string literal/concatenation can corrupt array 0's descriptor pointer",
          "the NUL after a 31-character content lands on the next record; after the last temp that is ARR_PTR_TABLE[0]",
          "no NUL writes (PRINT by length) [M] with Q-27"),
 "Q-29": ("HIGH", "all", "SPRITE MOVE restores the saved background at a garbage position and leaves the old image (SPRITE package)",
          "D is not reloaded after SPR_COMPUTE_ADDRS before the restore of the old position",
          "ld d,0 after SPR_COMPUTE_ADDRS [M] package +2 (832 -> 834)"),
 "Q-30": ("HIGH", "all", "A FLOAT argument of CHR$, LEFT$, RIGHT$, MID$, PAUSE, BORDER is its slot index (LEFT$(a$,2.5) = \"\", CHR$(65.6) = CHR$(0), PAUSE 0.5 waits for a key)",
          "these handlers call VM_POP instead of VM_POP_COERCE_INT",
          "call VM_POP_COERCE_INT at 7 sites [M] HOME 0"),
 "Q-31": ("LOW", "all", "MID$ start uses its low byte only (MID$(s$,257,1) = MID$(s$,1,1); -256 means 1)",
          "BUILTIN_FN_MID tests L only", "test H: negative -> 1, >= 256 -> past the end [M] HOME -12"),
 "Q-32": ("CRITICAL", "essential enhanced", "POKE/PEEK/USR/IN/OUT to an address computed above 32767 use address 32767 (POKE writes the wrong byte)",
          "D11 promotion makes the sum a FLOAT; VM_POP_COERCE_INT saturates it to 32767 (the baseline's wrap gave the right address) -- introduced by the overnight D11 prototype",
          "VM_POP_ADDR (FLOAT -32768..65535 accepted, else error 15) [M] HOME -49 (study/proto-lc 6449bee)"),
 "Q-33": ("HIGH", "all", "A FLOAT argument of a package statement arrives as its slot index (r = 33/2: CIRCLE 128,96,r draws radius ~1)",
          "OP_CALL_EXT pops the arguments with VM_POP and ignores the tag",
          "arguments through VM_POP_ADDR [M] HOME -2 (study/proto-lc 7372441)"),
 "Q-34": ("HIGH", "all", "The calculator never rounds: INT(3.1*10) = 30, INT(0.7*10) = 6, 1/10*10 <> 1 (divide 41% correctly rounded, up to 1.95 ulp low)",
          "CALC_OP_DIV keeps 32 quotient bits and drops the dividend's low bit on its pre-shift; CALC_OP_MUL truncates the product; CALC_ADDSUB_ENGINE aligns without guard bits; CALC_PACK does not round",
          "FIXED (R1, backport/leapc 3164936): Leap-C's 40-bit float core behind V2's literal interface, rounded to nearest, bit-exact with Leap-C's model [M] EXROM +719 (saves) (tools/qual/qcalcround.py measures)"),
 "Q-35": ("MEDIUM", "all", "COS(n) for n = 32678..32767 is wrong (COS(32687) = 0.0175, not 0.2924); COS and TAN of a FLOAT above 32677 are error 15 (SIN takes up to 32767)",
          "BUILTIN_FN_COS adds 90 to the argument (in 16 bits for an INT, a float add for a FLOAT) before SIN reduces it mod 360",
          "FIXED (5.10, proto/5.9-5.10-float-fn-exrom): the 90 added after the reduction mod 360, then reduced again; part of 5.10's rewrite, which saves EXROM"),
 "DD-1": ("DOC", "all", "Manual: a string array element holds 31 characters; the default width is 16 (15 characters)",
          "docs/v1/user_manual.md section 6", "correct the manual or the default"),
 "DEC-PLOT": ("DECISION", "all", "PLOT/POINT coordinates above 255 wrap modulo 256 (y > 191 is clamped)", "OP_PLOT uses L only", "decide: wrap / clamp / error"),
 "T-1": ("TEST", "all", "The CALC variant of the component-test EXROM was 1653-1670 B over 8 KB and silently truncated",
         "plain sjasmplus only warns on a negative DS", "fixed on study/qualification-b: strict build, no decompiler in the CALC image"),
 "T-2": ("TEST", "enhanced", "chunk_refill_boundary did not fit its flat 16 KB image (41 B over)", "legacy flat image", "migrated to the two-bank harness (study/qualification-b)"),
 "T-3": ("TEST", "all", "15 component-test sources are never run (print, compiler_r2..r7, call_fn, sprite_module, ...)",
         "not listed in tools/run_v2_standalone_tests.sh", "run or retire them [E] test effort only"),
 "T-4": ("TEST", "enhanced", "The test-only decompiler skips OP_NL/OP_PRINT_COMMA (PRINT a;b decompiles as two PRINTs) and rejects OP_OUT",
         "decompiler tables", "teach the decompiler [E] test effort only"),
 # documented defects reproduced (cost study / R10.8)
 "D10": ("MEDIUM", "all", "Float display truncates the fourth decimal (0.1+0.2 -> 0.2999)", "BASIC_FLOAT_TO_STRING_EXROM truncates", "round [E] EXROM -10..-20"),
 "D11": ("HIGH", "baseline", "16-bit integer overflow wraps silently", "Phase 2D VM", "fixed in Essential/Enhanced (promotion)"),
 "D11-EXT": ("MEDIUM", "essential enhanced", "ABS(-32768), -32768/-1, DIV(-32768,-1), INT(x>32767) still wrap/saturate", "outside the promotion paths", "[E] HOME -10..-25"),
 "D11-DISP": ("LOW", "essential enhanced", "Floats >= 32768 print without their fraction; >= 2^32 saturate", "FLOAT_BIG_TO_STRING", "[E] EXROM -40..-80"),
 "L-A": ("DECISION", "essential enhanced", "Literal rule L-A: 32768..65535 are 16-bit address patterns; larger or over-precise literals are error 64", "cost study G.1", "owner decision (L-C [E] HOME -40..-60)"),
 "L3": ("LOW", "all", "A string literal longer than 31 characters is cut silently", "COMPILE_STR_FACTOR clamps", "error instead [E] HOME -4"),
 "L-STR": ("MEDIUM", "all", "String ordering comparisons <> > <= >= are missing (spec MUST HAVE)", "COMPILE_IF", "[E] HOME -30..-40"),
 "L-SC": ("LOW", "all", "AND/OR do not short-circuit (spec MUST HAVE)", "OP_AND/OP_OR", "[E] HOME -20"),
 "L-INSTR": ("LOW", "all", "INSTR documented, absent", "-", "package or core [E]"),
 "L-ELIF": ("LOW", "all", "ELSEIF documented (V1), absent (ELSE IF works)", "-", "[E] HOME -10..-20"),
 "L-NEXT": ("LOW", "all", "Bare NEXT documented as optional, error 10", "-", "[E] HOME -10"),
 "N-1": ("HIGH", "baseline", "CALL p(FN f(x)) calls the wrong label", "shared STMT_IDENT_NAME_BUF", "fixed in Essential/Enhanced"),
 "N-2": ("HIGH", "baseline", "A bare word on a line is silently ignored", "label lookahead", "fixed in Essential/Enhanced"),
 "N-4": ("LOW", "all", "An array name used as a scalar requires '(' (showcase.txt)", "COMPILE_FACTOR", "rename / [E] HOME -20"),
}

SEVERITY = {k: v[0] for k, v in D.items()}
FIX = {k: v[4] for k, v in D.items()}

# RC (integration/v2-final-rom): the defect markers the release candidate has fixed or decided, so a run
# with `--fixed rc` drops them (a marked case must then PASS; one that still fails is a FAIL, one that
# passes while marked would be an XPASS). Still open: Q-24, Q-26 (LOW, deferred -- docs/
# V2_DEFECT_REGISTER.md). L-INSTR and L-ELIF are decisions, not fixes: their corpus cases now expect
# the V2 behaviour (a compile error) directly. DD-1 was the manual's error (corrected).
RC_FIXED = ("Q-01 Q-02 Q-03 Q-04 Q-05 Q-06 Q-07 Q-08 Q-09 Q-10 Q-11 Q-12 Q-13 Q-14 Q-15 Q-16 Q-17 Q-18 Q-19 Q-20 "
            "Q-21 Q-22 Q-23 Q-25 Q-27 Q-28 Q-29 Q-30 Q-31 Q-32 Q-33 D10 D11-EXT D11-DISP L-STR L-SC L-A L3 L-NEXT "
            "N-4 DEC-PLOT DD-1 Q-34 Q-35").split()

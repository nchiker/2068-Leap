# 2068-Leap V2 — Independent Z80 audit and shrink review (qualification study, Phase B)

> **Later note (2026-10-27):** defect **Q-26** (the nine characters: brackets, braces, backslash, caret, backquote, bar and tilde print blank), listed as open below, is **fixed in `v2.1.0-emu.1`** (nine new glyphs, HOME 64 bytes; `V2_DEFECT_REGISTER.md`, `V2_1_RELEASE_STATUS.md`). The report as delivered is unchanged.

> **Addendum (2026-10-11, owner-decision review — `docs/V2_OWNER_DECISIONS_REVIEW.md`).** Two more defects were found after this report.
> **Q-32** (CRITICAL, Essential/Enhanced): an address computed above 32767 is saturated to 32767 by `POKE/PEEK/USR/IN/OUT`. It was **introduced by
> the overnight D11 promotion prototype**, so this report's statement that no defect came from the prototypes no longer holds.
> **Q-33** (HIGH, all configurations): a FLOAT package-statement argument arrives as its slot index. Both are fixed on `study/proto-lc`.
> The report as delivered is unchanged on `study/qualification-a`.

**Status:** complete for the scope in §1; nothing here is integrated. Branches: `study/qualification-a` (this report, tools),
`study/qualification-costs` (measured correctness fixes), `study/qualification-shrink` (measured shrink prototype),
`study/qualification-final` (fixes + shrink together), `study/qualification-b` (test infrastructure). `~/2068-Leap` / `v2-development` (`7ae0599`) untouched; nothing pushed.

**Evidence classes.** **[M]** measured on an assembled production image and/or observed on the real ROM in ZEsarUX through the
qualification harness (`tools/qual/`), with the case or command named; **[S]** read from current source (file:line given against
`study/combined-enhanced` = `8379ab5` unless stated); **[E]** estimate, never presented as measured. Byte costs are signed like the cost
study: “HOME −8” = 8 bytes consumed, “HOME +40” = 40 bytes freed. Everything is emulator evidence; nothing is hardware-qualified.

---------------------------------------------------------------------------------------------------------------------------

## 0. Summary

* **Six critical defects and one closely related high one (Q-27), all pre-existing in the Phase 2D baseline and present unchanged in V2 Essential and V2 Enhanced**
  (none was introduced by the overnight prototypes). Four corrupt memory or destroy the program, three silently give wrong answers in ordinary programs:

  | ID | Defect | Minimal reproduction (real ROM) | Fix measured on `study/qualification-costs` |
  |---|---|---|---|
  | **Q-01** | String comparison compares only the lengths | `k$="n": IF k$="y" THEN …` takes the THEN branch | 0 B |
  | **Q-02** | Float/string temporaries reused while live | `PRINT 1.5+2.5*3.5` → `12.2500`; `PRINT UPPER$("a")+LOWER$("B")` → `bb` | HOME **+40 (saves)**, RAM +74 |
  | **Q-03** | `AND`/`OR` with a float operand jump to the operand value | `x=0.5: IF x AND 1 THEN …` → cold restart, **program erased** | HOME −11 (with Q-18) |
  | **Q-04** | DIM size arithmetic wraps | `DIM a(4200)` → cold restart, **program erased** (`DIM a(4000)` works) | HOME −8, EXROM −6 |
  | **Q-18** | A rejected array store still writes | `DIM a(5): a(5)=99` → error 10 *and* `a(0)=99`; `a(-1)=v` rewrites the array's size | (with Q-03) |
  | **Q-27** | `PRINT` of a string-function result shows an older string's tail | `a$="abcdefgh": PRINT LEFT$("q",1)` → `qbcdefgh` | HOME −12 (with Q-28) |
  | **Q-28** | A 31-character string corrupts array 0's pointer | `DIM a(3): a(0)=7: s$="x": t$=<31 chars>: PRINT a(0)` → `0` | (with Q-27) |

  Two of them share one root pattern — **errors are raised with `jp VM_ERR_*` from inside called subroutines and `VM_ERR_COMMON` returns into the caller,
  which carries on** (§3.1). One 11-byte change (save SP at `VM_RUN`, restore it in `VM_ERR_COMMON`) closes the whole class.
* **Further high-severity semantic defects:** Q-06 float `IF` condition, Q-07 `FOR` zero-trip, Q-08 float `FOR` bounds, Q-10 float arguments truncated by
  `SGN/SQR/RAD/DEG/SIN…`, Q-20 `GOTO` out of an inner `FOR`, Q-29 SPRITE `MOVE` (package), Q-30 float arguments of `CHR$ LEFT$ RIGHT$ MID$ PAUSE BORDER` used as
  their slot index — plus D11/N-1/N-2 already known — and a list of medium/low ones (§2).
* **Every critical and high defect except Q-10 has a measured fix** on `study/qualification-costs` (`b1463c7`, Essential base); Q-08 is *mitigated* (a float `FOR`
  bound is a clean error 11 instead of a wrong loop). 22 defect ids in all: HOME 353 → **196** free (−157), EXROM 488 → 482 (−6), SPRITE package +2, RAM +74.
  The fixed build passes `make check`, the 115-case gate, the 98-case Array Store gate, the 15-case known-defect suite and FILL 10/10; 17/19 production checks
  (the two failures are capacity constants that the Q-02 fix changes by design, §3.2); corpus 551 PASS / 61 XFAIL / 5 FAIL (the 5 are Q-08 mitigated-only and
  Q-17 partly fixed — conformance report §6.2).
* **Fixes and shrink together are measured too:** `study/qualification-final` (`b716d4e`) = the fix branch + the RST change re-applied by its mechanical rule:
  **HOME 741 / EXROM 482 free [M]**, `make check` rc 0, the same gate results and the same corpus results as the fix branch, case for case.
  The same procedure on Enhanced (`study/qualification-enh-final`, `162dd59`): fixes alone **HOME 23 / EXROM 233**, fixes + RST **HOME 578 / EXROM 233 [M]**,
  `make check` rc 0, standalone 38/38, gate 113 (Enhanced's case count) / 98 / 15, FILL 10/10, corpus with the same 5 known FAILs and no other change.
* **A large, safe shrink exists that the earlier shrink passes did not find** (§4.1): the HOME ROM bytes `$0004–$0027` and `$002B–$0037` are `$FF` fill, i.e. five free
  RST vectors. Routing the five hottest call targets through them (`LEX_NEXT_TOKEN`, `VM_POP`, `VM_POP_COERCE_INT`, `EMIT_BYTE`, tail jumps to `COMPILE_RAISE_ERROR`)
  frees **HOME +559 B** on V2 Essential (353 → 912 free) **[M]**, at **+0.1 … +0.3 %** emulated run time **[M]**; the full project battery passes and the corpus as it stood then (555 cases) gives
  results identical to Essential, case for case **[M]**. It is mechanical, behaviour-preserving and reversible. This alone is larger than everything the overnight prototypes consumed in HOME.
* The overnight prototypes themselves are sound in the parts reviewed (§5): no new correctness defect was found in their code; the risks are in the ISR-side `BREAK`
  write ordering (benign), the `STICK` port read (hardware question), and one contract change (`FLOAT_BIG_TO_STRING` destroys `IX`, harmless for current callers).

---------------------------------------------------------------------------------------------------------------------------

## 1. Scope and coverage

### 1.1 Builds reviewed

| Configuration | Commit | HOME free | EXROM free | ROM sha256 (first 16) | How |
|---|---|---:|---:|---|---|
| Phase 2D baseline | `7ae0599` | 565 | 802 | `ce66832c9aebffca` | `tools/qual/build_configs.sh` (git archive → `make build v2-packages`, `make budget`) **[M]** |
| V2 Essential | `0dedab3` `study/combined-essential` | 353 | 488 | `b0fbbf6b0537f34b` | same **[M]**; byte-identical to the overnight worktree build |
| V2 Enhanced | `8379ab5` `study/combined-enhanced` | 180 | 239 | `f70d20fbb62143af` | same **[M]** |
| Fixes (this study) | `b1463c7` `study/qualification-costs` | 196 | 482 | `38e8b2309a76eb1a` | Essential + the fixes of §2 **[M]** |
| Shrink (this study) | `ff7f0be` `study/qualification-shrink` | 912 | 488 | `26605e6699b86f64` | Essential + RST vectors **[M]** |
| Fixes + shrink (this study) | `b716d4e` `study/qualification-final` | **741** | 482 | `f29b2309f04b4b9f` | fix branch + RST vectors **[M]** |
| Enhanced + fixes (this study) | `c461d7c` `study/qualification-enh-final~1` | 23 | 233 | `9b2f424ec90e5948` | Enhanced + the same fix commits **[M]** |
| Enhanced + fixes + shrink | `162dd59` `study/qualification-enh-final` | **578** | 233 | `b448576c701da746` | + RST vectors (`tools/qual/apply_rst_rule.py`) **[M]** |

### 1.2 What was reviewed, and how deeply

| Area | Files | Depth |
|---|---|---|
| Compiler, lexer, symbol table | `rom/exrom_v2_compiler.asm` (4 855 lines), `rom/exrom_v2_symtab.asm` | **every line** of the comment-stripped source (2 807 code lines) |
| VM, built-ins, numeric glue | `rom/exrom_v2_vm_core.asm` (5 213 lines) | **every line** (3 216 code lines) |
| Numeric kernel, formatting, calculator entry | `kernel/math/math.asm`, `rom/exrom_format.asm`, `rom/exrom_calc.asm` (`CALC_INT_TO_FP`, `CALC_FP_TO_INT`) | full for math/format; calculator interior not reviewed |
| Shell, Array Store | `rom/exrom_v2_shell.asm`, `rom/exrom_v2_arrstore.asm` | run path, dispatch, DIM/bind/adopt, every prototype hunk; LIST/LOAD/SAVE skimmed |
| Editor, display, keyboard, ISR | `rom/exrom_editor.asm`, `kernel/graphics/graphics.asm`, `kernel/interrupt/interrupt.asm` | prototype hunks (D5b, I1/I2, BREAK), `GFX_PRINT_STRING_ATTR`, font lookup |
| Packages / ABI | `include/v2_package_abi.inc`, `rom/ext_*_module.asm` | registrations, PRINTER string path, SHAPES D7 hunk, pinned cells |
| Storage / tape | `kernel/storage/storage.asm` | **not reviewed** beyond the scanner output (the Phase 2A gate cases cover its semantics) |
| Prototype diffs | `git diff 7ae0599 study/combined-enhanced` (912+/145− lines in 10 production files) | every hunk (§5) |

### 1.3 Tools run

| Tool | Result use |
|---|---|
| `z80-skills:audit-z80` `preflight_scan.py` (whole tree) and `z80_pattern_scan.py` (production-only file set, `scratchpad/audit/prod_enhanced`) | candidate queue: 24 stack-delta-at-exit, 2 exit-with-interrupts-disabled, 39 stale-flag-branch, 3 call-followed-by-ret, 775 layout hints … each high-value category hand-checked (§3.6) |
| `z80-skills:shrink-z80` `deadcode_scan.py` | noisy (tables and data reported as unreferenced); no dead routine confirmed |
| **error-raise site scanner** (this study, inline Python over `exrom_v2_vm_core.asm`) | classifies every `jp/jr … VM_ERR_*` by calling context and pushes outstanding → found Q-03 and Q-18 by construction (§3.1) |
| **call-frequency counter** over the HOME listing | found the RST opportunity (§4.1) |
| qualification harness `tools/qual/` (619-case corpus, `qprobe.py`, `qbench.py`) | reproductions and fix verification on the real ROM |

The audit skill's contract was followed: primary checkout read-only; all builds in exported trees or study worktrees; scanner output was used as candidates only.
No agents were spawned; every promoted finding was re-read at its site and, where marked [M], reproduced on the real ROM.

---------------------------------------------------------------------------------------------------------------------------

## 2. Findings register (severity first)

Full reproduction programs are the corpus cases named in `docs/V2_LANGUAGE_COVERAGE.csv` / `V2_LANGUAGE_CASES.csv`; every row below was
observed on all three configurations unless the *Configs* column narrows it. “Fix [M]” = assembled and verified on `study/qualification-costs`.

| ID | Sev. | Configs | Defect | Root cause [S] | Evidence [M] | Fix / cost |
|---|---|---|---|---|---|---|
| Q-01 | CRITICAL | all | string `=` / `<` compare lengths only | `VM_STR_COMPARE` (vm_core:2716) `push hl / ex de,hl / … / pop hl` leaves DE = HL = A | `strcmp.eq.0` (`"abc"="xyz"` true), `strcmp.inkey_idiom` | ex/ex, **0 B** [M] |
| Q-02 | CRITICAL | all | live temporaries overwritten (2 round-robin slots per kind) | `OP_PUSH_STR_LIT`, `OP_STR_CONCAT`, `VM_STR_ALLOC_TEMP`, `VM_FLOAT_STORE_RESULT` | `arith.f.prec` (`1.5+2.5*3.5` = 12.25), `str.temps.*` | allocator that skips referenced slots, **HOME +40**, RAM +74 [M] |
| Q-03 | CRITICAL | all | `AND`/`OR` float operand → jump to operand value | `OP_AND` (2266) / `OP_OR` (2287) `push hl` … `jp nz,VM_ERR_FLOAT_NOT_IMPLEMENTED` | `crash.*`: program store emptied | SP restore, **HOME −11** with Q-18 [M] |
| Q-04 | CRITICAL | all | DIM > ~8 KB wraps, zero-fills over the stack | `VM_ARENA_FIT` (1810) no carry check; segment 2 at `$E000`; `ARENA_ALLOC_STRING` truncating multiply | `dim.big.*` (8 000 elements), probe `DIM a(4200)` | **HOME −8, EXROM −6** [M] |
| Q-18 | CRITICAL | all | rejected array store still writes | `VM_ARR_VALIDATE_INDEX` (1447) / `VM_POP_CHECK_INT` (1066) `jp` to `VM_ERR_*`, `ret` back into `OP_ARR_STORE` / `OP_STRARR_STORE` | `mem.*` (RAM inspected after the run) | with Q-03 [M] |
| Q-27 | HIGH | all | stale tail after a string function result | `LEFT$/RIGHT$/MID$/CHR$/STR$/STRARR_LOAD` write no NUL; `OP_PRINT_STR` prints to NUL | `strrec.stale_tail` | print by length, **HOME −12** with Q-28 [M] |
| Q-28 | CRITICAL | all | 31-character string corrupts `ARR_PTR_TABLE[0]` | NUL written at record+32 = next table's first byte | `strrec.31_vs_array` | with Q-27 [M] |
| Q-06 | HIGH | all | `IF x` on a float tests its slot index | `OP_JMPZ` (2322) ignores the tag | `if.float_cond` | **HOME −1** [M] |
| Q-07 | HIGH | all | `FOR i=5 TO 1` runs the body once | no entry test in `OP_FOR_INIT` (2345) | `for.zero_trip` | FOR redesign, **HOME −102** for Q-07/08/19/20 [M] |
| Q-08 | HIGH | all | float `FOR` bounds/step read as slot index; float loop variable hangs | `OP_FOR_INIT` pops without tag check | `for.float_*` | error 11 (in the redesign) [M]; float loops [E] −80…−150 |
| Q-20 | HIGH | all | after `GOTO` out of an inner loop the outer `NEXT` uses the inner limit/step | `VM_FOR_LIMIT/STEP` globals hold only the innermost loop | `for.goto_out_inner` (3 iterations → 10) | FOR redesign [M] |
| Q-10 | HIGH | all | `SGN SQR RAD DEG SIN COS TAN` (and `MOD DIV`) truncate float arguments | `VM_POP_COERCE_INT` before computing | `fn.sgn.f_small` (`SGN(0.5)`=0), `fn.sqr.f` (`SQR(2.25)`=1.4142), `fn.deg.pi` (171.89) | [E] −40…−60 (SGN/SQR/RAD/DEG), −40…−70 (trig) |
| Q-05 | MEDIUM | Ess/Enh | `PRINT -32768` → `32768.0000` | L-A literal `$8000`, `0 − x` promoted | `lit.int.neg32768` | fold `-literal`, **HOME −18** [M] |
| Q-09 | MEDIUM | all | 5+ fractional digits wrap the divisor (`0.00001` wrong) | `LEX_SCAN_NUMBER` (894) | `lit.dec.0p00001` | error 64, **HOME −5** [M] |
| Q-11 | MEDIUM | all | PROC/DEF FN inside a PROC body corrupts the outer PROC | single `PROC_SKIP_PATCH_TMP`/`PROC_PARAM_INDEX_TMP` | `proc.nested_def` | park across body, **HOME −16** [M] |
| Q-13 | MEDIUM | all | `MOD(x,0)`, `DIV(x,0)` = 0 silently | `MATH_UDIV16` guard, no check in the built-ins | `fn.mod.zero` | **HOME −2** [M] (shared pop) |
| Q-15/16 | MEDIUM | all | `INPUT` 1.5 → 15; 99999 → −31073 | `OP_INPUT_NUM` / `VM_PARSE_INPUT_INT` | `input.decimal`, `input.big` | [E] −25…−55 |
| Q-19 | MEDIUM | all | `NEXT` without its `FOR` loops forever | stale globals | `for.goto_into`, `for.next_in_if` (HUNG) | FOR redesign → error 7 [M] |
| Q-12 | LOW | all | duplicate label silently accepted | `LABEL_DEFINE` (symtab:381) | `label.dup` | error 57, **HOME −4** [M] |
| Q-14 | LOW | all | `CLS` keeps the print position | `OP_CLS` | `print.cls` | **HOME −6** [M] |
| Q-17 | LOW | all | `VAL` skips non-digits; wraps > 32767 | `BUILTIN_FN_VAL` tolerant scan | `str.val_stop`, `str.val_big` | stop: **0 B** [M]; wrap [E] |
| Q-21 | LOW | all | `CLEAR` inside `FOR` → endless loop | `MEM_CLEAR_V2` zeroes scalars only | `clear.loop` (HUNG) | decision [E] −6…−12 |
| Q-22 | LOW | all | `SQR(-4)` = 0 silently | `MATH_SQRT16` | `fn.sqr.neg` | [E] −5 |
| Q-23 | LOW | Ess/Enh | `STICK(5)` returns a value | `dec l / jr nz` | `hw.stick_bad` | [E] −6…−8 |
| Q-24 | LOW | all | `CALL` of a plain label accepted | shared label namespace | `proc.goto_label` | [E] −10…−20 |
| Q-25 | LOW | all | string comparison cannot be combined (`AND`) or used as a value | `COMPILE_IF` | `str.cmp_and` | part of L-STR |
| Q-26 | LOW | all | `[ \ ] ^ ` `{ | } ~` print blank | font punctuation subset | `print.font_brackets` | document [E] or −72…−90 |
| Q-29 | HIGH | all | SPRITE `MOVE` restores the background at a garbage position and leaves the old image | `SPR_MOVE_EXEC` indexes `SPRITE_SLOT_ROW/COL` with `DE` after `SPR_COMPUTE_ADDRS` left `D = HIGH(SPRITE_SLOT_BG_BUF)` (the other three callers reload `D`) | `pkg.sprite.move_restore`, `pkg.sprite.cycle` | `ld d,0`, **package +2** [M] |
| Q-30 | HIGH | all | a FLOAT argument of `CHR$ LEFT$ RIGHT$ MID$ PAUSE BORDER` is its slot index (`LEFT$(a$,5/2)` = `""`, `CHR$(65.6)` = `CHR$(0)`, `PAUSE 20.5` ≈ no pause) | these handlers `call VM_POP` instead of `VM_POP_COERCE_INT` | `tag.left_float`, `tag.chr_float`, `tag.pause_frames` | 7 call targets changed, **0 B** [M] |
| Q-31 | LOW | all | `MID$` start uses its low byte (`MID$(s$,257,1)` = first character; −256 means 1) | `BUILTIN_FN_MID` tests `L` only | `tag.mid_bigstart*` | test `H`, **HOME −12** [M] |

Not defects but recorded: **DD-1** (manual: string array elements hold 31 characters; default width 16 holds 15); **DEC-PLOT** (PLOT/POINT x/y wrap modulo 256).

---------------------------------------------------------------------------------------------------------------------------

## 3. Audit detail (B4)

### 3.1 The systemic defect: errors raised from inside called routines

`VM_ERR_COMMON` (vm_core:5173) stores the code, sets `VM_HALTED` and executes `ret`. The VM's convention is that an opcode handler is *jumped* to from
`VM_RUN.loop`, so a `jp VM_ERR_*` directly in a handler returns to `VM_RUN`'s caller — correct. But 11 raise sites sit in routines that are **called**
(`VM_POP`, `VM_PUSH`, `VM_POP_CHECK_INT`, `VM_ARR_VALIDATE_INDEX`, `VM_CALL_PUSH/POP`, `VM_PARAM_SAVE_PUSH/POP`), and two handlers raise with a value
pushed on the Z80 stack (`OP_AND`, `OP_OR`). The error-site scanner lists all of them; consequences, checked one by one:

| Raise site | Caller continues with | Consequence |
|---|---|---|
| `VM_ARR_VALIDATE_INDEX` | `OP_ARR_STORE`, `OP_STRARR_STORE` compute the element address from the *rejected* index and store | **memory write out of bounds** (Q-18): `a(n)` → `a(0)`, `a(-1)` → descriptor count, string arrays → descriptor/next array |
| `VM_POP_CHECK_INT` (value or index is a float) | the store completes with the float-table slot index | element overwritten (Q-18) |
| `OP_AND` / `OP_OR` with a pushed operand | `ret` pops the operand (e.g. 1) as the return address | `jp $0001` → `V2_COLD_START` → `MEM_INIT`: **program erased** (Q-03) |
| `VM_POP` (underflow), `VM_PUSH` (overflow), call-stack helpers | harmless follow-on work, then `VM_RUN.loop` sees `VM_HALTED` | none found |
| `ARENA_ALLOC_*` (called from `ARR_DIM`) | `ARR_DIM` tests `VM_HALTED` itself | none (deliberate) |

**Fix [M]:** `VM_RUN` and `VM_INIT` save SP in `VM_RUN_SP` (`$BED0`, a free cell in the V2 sysvar gap — `check_ram_aliases.py` passes) and
`VM_ERR_COMMON` restores it before `ret`; every error now leaves the VM at once. `V2_COMPILE_RUN` calls `VM_INIT`, `ARR_RUN_INIT` and `VM_RUN` at the same stack
level, so the Array Store bind error (`ARR_RUN_INIT` → error 65) unwinds correctly as well. **HOME −11.** Verified: all `mem.*` and `crash.*` cases, the 98-case Array Store gate.
Packages never call `VM_ERR_COMMON` (they set the pinned `VM_ERROR_CODE/VM_HALTED` cells), so an unwind can never return into EXROM code with EXROM paged out.
The fix also makes `VM_POP_CHECK_INT` safe to use for new type checks (the FOR redesign uses it).

### 3.2 Temporaries (Q-02)

Two string and two float temp slots were taken round-robin. Any expression with three live temporaries breaks: `1.5+2.5*3.5` (the
first literal is still on the stack when the third is pushed), `(1.5+2.5)*(3.5+4.5)`, `"a"+UPPER$("b")`, `LEFT$(…)+MID$(…)+RIGHT$(…)`,
`"<"+MID$(s$,2,3)+">"`. **Fix [M]:** `VM_TEMP_PICK` returns the first slot whose index (with the matching tag) is not on the operand stack (the stack lies in
one page, `$B604–$B680`, so the scan compares the low byte of the pointer); all slots live → `STACK OVERFLOW` instead of corruption. String temps get their
own tag (`TAG_STR = 2`; string *variables* keep tag 0), so stacked integers never block a slot; `OP_STR_CONCAT` picks its destination before popping.
**HOME +40** (a shared allocator replaces three inline round-robin blocks), **RAM +74** (4 slots per kind), scalar caps 253 → 251 (derived in `exrom_v2_symtab.asm`).
Consequences for tests: `v2_production_checks.py` `253-vars` and `free-1` (FREE window 900–1100, now 893) assert the old capacities and fail by design.
A 3-slot variant would cost RAM +37 and cap 252 **[E]**.

### 3.3 String records (Q-27, Q-28)

A string record is 32 bytes `[len][31 content]`. Literal and concatenation results append a NUL after the content (needed by `GFX_PRINT_STRING_ATTR`),
but the other producers (`LEFT$ RIGHT$ MID$ CHR$ STR$ UPPER$ LOWER$`, string-array reads, `INPUT`) do not — so `PRINT` showed the tail of whatever the
temp slot held before (Q-27). And a 31-character content leaves no room: the NUL lands on the next record's length byte, which after the last temp slot is
`ARR_PTR_TABLE[0]`'s low byte (carving order in `VM_CARVE_DESC`: STRARRPTR, ARRPTR, STRTAB …) — array 0 is then read and written at the wrong address
(Q-28, observed: `PRINT a(0)` = 0 instead of 7). **Fix [M]:** `OP_PRINT_STR` copies `len` bytes to `PRINT_BUF` (64 B) and terminates there; no producer writes a
terminator. The only string consumer outside the VM (PRINTER package) already uses the length byte; `PACKAGE_ABI.md` slot 15 describes the record as
`[len][content…, NUL]` and must drop “NUL”. **HOME −12.**

### 3.4 Arrays and the arena (Q-04)

`VM_ARENA_FIT` adds the request to `ARRAYS_END` and, failing that, to `ARR2_END` (segment 2 is `$E000–$E7FF`) without checking the 16-bit carry; any request
above ~8 KB that does not fit the main pool wraps, “fits” segment 2, and `ARR_DIM` zero-fills it across the machine stack (`$FF00`) — observed as a cold restart
with the program erased for `DIM a(4200)` and `DIM s$(300,32)`. `ARENA_ALLOC_STRING` uses the truncating `MATH_MULTIPLY16` for `count*width` and the compiler
accepts DIM sizes up to 65 535 (an L-A address pattern), so `count*2` can also wrap to a small block with a large bounds count. **Fix [M]:** carry = no fit (HOME −5),
`VM_MUL_CHECKED` (HOME −3), `ARR_DIM` rejects more than 16 383 elements before any arithmetic (EXROM −6; `VM_ERR_ARRAY_SPACE` added to the crossbank export list).

### 3.5 Control flow

* **FOR (Q-07, Q-08, Q-19, Q-20).** The innermost loop's limit and step live in two globals; frames hold the *enclosing* loop's values. `GOTO` out of an inner loop
  therefore leaves the inner values in force for the outer `NEXT` (observed 10 iterations instead of 3), a `NEXT` reached without its `FOR` runs with stale
  values (endless loop), and there is no entry test. Floats are read without a tag check. **Redesign [M]:** frames carry `[T_FOR][var][limit][step]`; `NEXT v` finds its
  own frame (dropping abandoned frames above it, error 7 if none); `FOR v` replaces a stale frame of `v`; `FOR_INIT` gets a 2-byte skip target that the compiler links
  into the loop's `EXIT FOR` chain (patched to `FOR_POP` by `NEXT`); float bounds → error 11. **HOME −102**; bytecode change only (not persisted); four
  component-test expectations follow (decompiled text, hand-assembled bytecode). A tighter implementation is likely possible (the measured cost is ~40 B above the [E]).
* **IF on a float (Q-06):** `OP_JMPZ` → `VM_FLOAT_TEST_ZERO`, HOME −1.
* **Nested definitions (Q-11):** `COMPILE_PROC` parks its two scratch cells across the body, HOME −16.

### 3.6 Scanner candidates reviewed by hand

| Category | Verdict |
|---|---|
| stack-delta-at-exit (24) | all intended: `VM_PUSH_STR_RESULT` pops the caller's `push af`; symtab/compiler routines pop parked values before `ret`; storage `.exit` paths. No imbalance found |
| exit-with-interrupts-disabled (2) | `STORAGE_RECEIVE_BLOCK` / `STORAGE_LOAD`: documented contract, the callers `ei` |
| call-followed-by-ret (3) | `COMPILER_INIT` `call SYM_RESET / ret`, `ext_mode_module`, `ext_registry`: tail-call shrink, 1 B each **[S]** |
| stale-flag-branch (39), long-di-span (5), smc/layout hints (800+) | sampled; no defect found (the layout hints are mostly `DS`/`ORG` padding and `EQU` tables) |
| `ld (VM_TOS_TAG),a` | **write-only cell**: stored by `VM_PUSH` and `VM_INIT`, never read anywhere (production, packages) → 6 B and 13 T per push **[S]** |

### 3.7 Interrupts, banking, RAM, ABI

* **BREAK (prototype D5):** the ISR writes `VM_ERROR_CODE = 66` and `VM_HALTED = 1` at any time. A BREAK that lands between an opcode's own `ld (VM_ERROR_CODE),a`
  and its `ret` overwrites the real error with BREAK — benign (the program stops either way). A BREAK during the compiler is discarded by `VM_INIT`. A BREAK during
  `INPUT` is not seen until ENTER (documented). No race can corrupt memory.
* **Banking:** every EXROM-to-HOME call goes through KTAB or is to HOME code that is always mapped; the error unwind (§3.1) never crosses a package call because
  packages do not raise VM errors. `PKG_NUM_TO_TEXT_SAFE` remains the only package path into EXROM and still pages around it.
* **RAM:** new cell `VM_RUN_SP` at `$BED0` (free in both combined builds; the flicker prototypes use `$BEC0–$BEC5`, I1b `$BEC2–$BECC`); `check_ram_aliases.py` passes.
* **`FLOAT_BIG_TO_STRING` (prototype D11) destroys IX.** No current caller keeps IX across number formatting (IX is used only by the editor and the tape code), but
  the ABI slot 14 contract says AF BC DE HL; if float formatting is ever exposed to packages the contract must add IX.
* **`STICK` (prototype)** reads AY port `$F6` with `in a,(c)` and an undefined `B`; on a TS2068 the AY decode ignores A8–A15, but a Dock/peripheral that decodes the
  upper lines could see a random high byte. Hardware question; setting `B` costs 2 B.

---------------------------------------------------------------------------------------------------------------------------

## 4. Shrink (B3)

### 4.1 Measured: RST vectors for the hottest calls — `study/qualification-shrink` (`ff7f0be`)

| Vector | Replaces | Sites | HOME free after |
|---|---|---:|---:|
| (Essential) | — | — | 353 |
| RST `$08` | `call LEX_NEXT_TOKEN` | 104 | 555 (+202) |
| RST `$10` | `call VM_POP` | 47 | 647 (+92) |
| RST `$18` | `call VM_POP_COERCE_INT` | 43 | 733 (+86) |
| RST `$20` | `call EMIT_BYTE` | 28 | 787 (+54) |
| RST `$30` | `jp`/`jr COMPILE_RAISE_ERROR` (tail) | 58 | **912 (+125)** |

`$0008–$0027` and `$0030–$0037` were `$FF` fill between the reset vector, the `RST $28` calculator entry and the `RST $38` ISR (the KTAB starts at `$0040`,
the package service table at `$0092` — neither moves). `RST $08–$20` are plain `jp target` vectors, so `rst n` has exactly the contract of `call target`.
`RST $30` replaces a *tail jump*: its vector drops the RST return address (`inc sp` ×2, no flag or register effect) and jumps, so `COMPILE_RAISE_ERROR`'s own
`ret` returns to the original caller exactly as after `jp`. Test images get the same vectors (`rom/v2_rst_vectors.inc`, `rom/v2_rst30.inc`).
**Evidence [M]:** `make check` rc 0 (package-ABI checker included); standalone 38/38; 115-case gate, 98-case Array Store gate, known-defect suite, 19/19 production checks,
FILL 10/10; the 555 completed corpus cases give the same status *and* the same observed text as Essential (0 differences).
**Speed [M]** (`tools/qual/qbench.py`, emulated T-states, compile + run): integer loop +0.14 %, float loop −0.01 %, strings +0.19 %, built-ins +0.27 %, compile-only +0.09 %.
**Risk:** low and mechanical; the only global assumption is that nothing else uses RST `$08–$30` (stock-ROM USR code that does `RST $10` to print would now call
`VM_POP` — but V2 does not provide the stock ROM entry points anyway). **EXROM: 0.** The same transformation applies unchanged to Enhanced (est. same +559 **[E]**).

### 4.2 Further candidates (not assembled unless marked)

| Candidate | Bank | Est. | Notes |
|---|---|---:|---|
| `EMIT_OP_*` stubs (`ld a,N : jp EMIT_BYTE`, ~60) → inline `ld a,N / rst $20` at each call | HOME | +150…+250 | requires §4.1; tail-jump sites cost +1 each |
| `ld a,(COMPILE_ERROR_CODE) / or a / ret nz` (15 sites) → `call CHK_ERR` (pops its return and returns from the caller on error) | HOME | +23 | no RST left after §4.1 |
| `xor a / jp VM_PUSH` (20 sites) → `jp VM_PUSH_INT` (1-byte entry before `VM_PUSH`) | HOME | +18 | flags/registers identical |
| `VM_TOS_TAG` write-only | HOME | +6 | also −13 T per push |
| `call X / ret` → `jp X` (3 sites) | HOME | +3 | |
| `MOD`/`DIV` shared operand pop | HOME | +8 (net −2 including the Q-13 check) | **[M]** inside the Q-13 fix |
| shared `BUILTIN_FN_LEFT/RIGHT` clamp prologue (identical 15-byte prologues) | HOME | +12…+15 | |

None of these interacts with the overnight prototypes' semantics.

### 4.3 Bank placement

No measured candidate needed EXROM. HOME is the pressure point today, and §4.1 changes that picture: Essential + every measured fix + RST is **741 HOME free [M]**;
V2 Enhanced + the same is **578 HOME / 233 EXROM free [M]** (`study/qualification-enh-final`); without RST the fixes leave Enhanced 23 B of HOME. Once the remaining
required items and storage goal 2 are counted,
**Enhanced's EXROM (239 free) becomes the binding constraint** — see `V2_REMAINING_COMPLETION_BUDGET.md` §6. The EXROM-placed hardware
functions (`study/lang-hw-exrom`) — a HOME-for-EXROM trade of 48 for 54 bytes — are not worth taking once §4.1 is in.

---------------------------------------------------------------------------------------------------------------------------

## 5. The overnight prototypes (B2)

| Prototype | Correctness risk found | Duplication / placement | Registers, stack, timing | Verdict |
|---|---|---|---|---|
| D5/D5b BREAK (ISR) | ISR may overwrite a real error code with 66 (benign); INPUT not interruptible (documented) | HOME (ISR) is the only correct place | ISR +~30 T per decoded key only | keep |
| D9a/D9b edit preservation | compare loop correct incl. prefix/suffix cases; stores only when changed; `V2_STORE_EDIT` shared | EXROM | — | keep |
| U6 display reset | ULAplus state not reset (manual claims it is) — hardware | EXROM, shared with boot | — | keep, verify ULAplus on hardware |
| D11 promotion + L-A literals | Q-05 (`-32768`), Q-09 (divisor) are edges of the same work; extremes still wrap (D11-EXT) | HOME (hot path) | `VM_MUL_CHECKED` verified by 105 476-pair oracle (cost study) | keep with Q-05/Q-09 fixes |
| Big-float display | IX destroyed (contract note §3.7); fraction dropped ≥ 32 768; saturates ≥ 2³² (D11-DISP) | EXROM | — | keep |
| N-1 `COMPILE_EXPR_KEEPNAME` | 33 B of stack per nested CALL/FN argument; guarded by `COMPILE_STACK_CHECK` | HOME | — | keep |
| N-2 bare word | correct for CR/LF/real `:` combinations | HOME | — | keep |
| N-3 FOR line | frame +2 B; superseded in layout by the FOR redesign (which also stores per-loop data) | HOME | — | merge into the redesign |
| OUT/IN/STICK core | Q-23; STICK's undefined B (§3.7); names reserved | HOME | — | keep (core cheaper than EXROM/ABI 2.1, cost study) |
| `COMPILE_2ARG_STMT` | none | HOME, saves 43 | — | keep |
| Multi-item PRINT / prompted INPUT | none in the compiler; decompiler (test-only) does not reconstruct it (T-4) | HOME | — | keep (Enhanced) |
| I1/I2 redraw | `V2_RD_CLEAR_ROWS` would clear to row 22 if ever given a zero height (not reachable: wrap count ≥ 1) | EXROM | writes attributes as `$38` (valid because U6 forces mode 0) | keep |
| D7 FILL | reads `VM_HALTED` (ABI-pinned `$B684`): safe | package | — | keep |
| LIST abort, `V2_POS_IS_APPEND` | none | EXROM | — | keep |

Combined builds: the merges are faithful (costs exactly additive per the cost study); the integration fixes (D9 × I2 scope reset, opcode/token renumbering) are correct.
**No defect in §2 was introduced by a prototype**; Q-05 and Q-09 are edges of the D11 literal work that the prototypes did not cover.

---------------------------------------------------------------------------------------------------------------------------

## 6. Architecture observations (B5)

1. **Error handling is the weakest contract** (§3.1): an error is a *flag plus a return*, with every caller expected to cope. The SP-restore fix turns it into a
   proper non-local exit for the VM; the compiler has the same shape (errors set `COMPILE_ERROR_CODE` and every routine checks and returns) but it is consistent there.
2. **No single representation contract for strings** (§3.3): some producers terminate, some do not, `PRINT` relied on termination. Length-only is the cheaper and safer rule.
3. **Float values flow into integer-only consumers unchecked**: `JMPZ`, `FOR_INIT`, `BORDER`, `PAUSE`, `CHR$`, `LEFT$`, `RIGHT$`, `MID$` pop with `VM_POP` and use the
   slot index (Q-06, Q-08, Q-30 — all three fixed or mitigated on the fix branch); others coerce by truncation (`VM_POP_COERCE_INT`) where mathematics needs the float (Q-10). A rule — “every consumer either coerces or rejects a float, explicitly” — would have prevented Q-06/Q-08/Q-10.
4. **Fixed 2-slot temporaries** were never adequate (§3.2).
5. The build is otherwise lean (the R10.7 consolidation audits hold up): no dead routines were found; the large saving available is structural (RST vectors), not de-duplication.

---------------------------------------------------------------------------------------------------------------------------

## 7. Recommended priority

1. **Q-03 + Q-18** (SP restore, 11 B), **Q-01** (0 B), **Q-04** (8+6 B), **Q-27 + Q-28** (12 B), **Q-02** (frees 40 B, RAM +74): the critical set, 0 net HOME cost together (−11 −8 −12 +40 = +9 B freed).
2. **RST vectors** (§4.1): +559 HOME, takes the budget question off the table for the rest of V2.
3. **Q-06** (1 B), **Q-30** (0 B), **Q-29** (package +2), **Q-07/Q-08/Q-19/Q-20** (FOR redesign, 102 B — worth tightening; Q-08 needs the integer-only-`FOR`
   decision), **Q-10** (SGN/SQR/RAD/DEG float arguments).
4. Medium items: Q-05, Q-09, Q-11, Q-13, Q-15/16, D10.
5. Low items and decisions: §2.

All Q fixes apply to the Phase 2D code and are independent of which prototype set is adopted.

## 8. Reproduction

```
cd ~/2068-Leap-study/qualification-a
tools/qual/build_configs.sh ~/2068-Leap-study/qual-builds                       # baseline / essential / enhanced
tools/qual/build_configs.sh ~/2068-Leap-study/qual-builds costs=study/qualification-costs shrink=study/qualification-shrink final=study/qualification-final
python3 tools/qual/qprobe.py essential -- 'k$ = "n"' 'IF k$ = "y" THEN' 'PRINT "yes"' 'ELSE' 'PRINT "no"' 'ENDIF'   # Q-01
python3 tools/qual/qrun.py --out /tmp/q --cfg essential --filter crash.,mem.,dim.big,strrec.               # critical set
python3 tools/qual/qbench.py essential shrink                                                              # RST speed
tools/qual/run_gate_suites.sh ~/2068-Leap-study/qual-builds/shrink 10610 /tmp/gate-shrink                  # project battery
```

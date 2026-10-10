# R10.8 — Final Feature Matrix (V2 production vs. goals, docs, tests, V1, stock TS2068)

Audit of commit `6151b64`. Companion: [`R10_8_GAP_ANALYSIS.md`](R10_8_GAP_ANALYSIS.md) (finding IDs `D*`,
`R*`, `L*` below), [`R10_8_EDITOR_USABILITY_AUDIT.md`](R10_8_EDITOR_USABILITY_AUDIT.md),
[`R10_8_PRE_R11_PLAN.md`](R10_8_PRE_R11_PLAN.md).

**This matrix describes what the compiler and VM actually accept, established by running
programs on the production ROM (`build/ts2068rom_zesarux.bin`) headless, not by reading
documentation.** It supersedes `docs/v2/R10_STOCK_TS2068_CAPABILITY_MATRIX.md`, which predates R10.7
(§8 lists its stale rows).

## 0. Legend

**Status classes (as requested)**

| Code | Class | Rule used here |
|---|---|---|
| **PT** | Implemented and production-tested | exercised by an automated test that runs on the **production ROM** (`tools/v2_production_checks.py` 19 cases, `tools/v2_fill_check.py` 10 cases) |
| **IT** | Implemented but insufficiently tested | works in this audit's probes and/or has *component* tests (the 38 standalone tests do not boot the production EXROM) but no production-ROM test |
| **PI** | Partially implemented | accepted, but with a documented or proven functional gap, or defective (`D*`) |
| **MR** | Missing or regressed | absent, or present in V1 / required by the V2 spec and not in V2 |
| **IU** | Intentionally unsupported | absent by a recorded design/product decision |

**Evidence tags:** **[M]** measured in this audit (production ROM, headless; recipes in the gap analysis
Appendix A); **[S]** source-level; **[D]** from project docs (not re-verified); **[T:name]** automated test
that covers it (`p:` = production check, `s:` = standalone component test, `k:` = kernel smoke,
`f:` = FILL check). "Stock" = original TS2068 BASIC, used only as a usability baseline.

**Important caveat on every "accepted" claim below.** Until D3 is fixed, *acceptance by the compiler
(`COMPILE_ERROR_CODE == 0`) does not prove a line was understood*: unrecognised trailing tokens and
statement starts silently end compilation. Every row marked **[M]** was confirmed by a sentinel
statement that was executed afterwards, or by displayed output.

## 1. Baseline

HOME ROM 15,838/16,384 B used (**546 B free**); EXROM 6,807/8,192 B used (**1,385 B free**);
source/array pool 8,397 B; bytecode 4,011 B; segment 2 2,048 B; package window 1,024 B. All **[M]**
(`make budget`). Suites: `make check` rc 0; headless `make test` rc 0 — smoke 9/9, V2 standalone 38/38,
production 19/19, FILL 10/10 **[M]**. Legacy Fuse tests were not run.

## 2. Statements

| Feature | V2 production reality | Docs / tests | V1 / Stock | Status |
|---|---|---|---|---|
| `name = expr` (numeric) | accepted; auto-creates variable; no `LET` (`LET x=1` → compile error 2) | spec; [T:p:plain,…] | V1 same / stock `LET` optional | **PT** |
| `name$ = strexpr` | accepted; concatenation `+`, 31-char cap (longer literal silently truncated to 31 **[M]**) | [T:p:seg2-string] | V1 26 slots / stock unlimited | **PT** (limit L3) |
| `PRINT <num | str>` | **one argument**; newline always; scrolling; floats shown with 4 truncated decimals (D10). `PRINT a; b`, `PRINT a, b`, `PRINT "x"; …` compile with error 0 and **drop the rest of the program** (D3) **[M]** | spec "single-argument grammar"; [T:s:print] | V1 same / stock multi-item with `;` `,` `'` `AT` `TAB` | **PI** (L2 + D3) |
| `PRINT` scrolling speed | ≈ 235 k T per printed line when scrolling (≈ 15 lines/s) **[M]** | — | stock similar order | **IT** |
| `AT x,y` / `TAB n` (standalone cursor statements, R10.7) | compile and run **[M]**; the PRINT-item forms `PRINT AT …` are not accepted | no test found for `TOK_KW_AT/TAB` | stock `PRINT AT/TAB` | **IT** |
| `LPRINT`, `LLIST` | via PRINTER package (one package at a time; source-based `LLIST`) | [T:s:printer_module] | V1 resident | **IT** (package, L7) |
| `IF c THEN GOTO label` | accepted | [T:s:block_if, relational] | stock `IF c THEN GOTO n` | **IT** |
| Block `IF … ELSE … ENDIF` (nestable) | accepted; **always** a block IF: `IF x=1 THEN y=2` with no `ENDIF` → compile error 9; `ELSEIF` → error 2; `ELSE IF … ENDIF ENDIF` works **[M]** | [T:p:recursion-150] | V1 had `ELSEIF` / stock single-line IF only | **PT** (block); single-line IF **IU** (L1); `ELSEIF` **MR** vs V1 |
| `AND`, `OR`, `NOT` | accepted; **no short-circuit** (`IF y<>0 AND 10/y>1` → runtime error 5 when y=0) **[M]** | spec "AND/OR short-circuit: MUST HAVE" (`V2_LANGUAGE_SPEC.md`) | stock same (no short-circuit) | **PI** vs spec |
| `FOR v = a TO b [STEP s]` / `NEXT [v]` / `EXIT FOR` | nested to memory limit; STEP incl. negative **[M]** (`FOR i=10 TO 1 STEP -3` → sum 22); float STEP accepted **[M]**; `FOR` without `NEXT` accepted silently (D3 family); loop variable not recursion-local (L5) | [T:p:nested-for, goto-out-of-for; s:for_step, for_nested, for_recursion_guard] | stock same | **PT** |
| `GOTO label`, labels (`name:`) | labels only (no line numbers); `GOTO 10` → error 12; names with digits OK, underscore not (error 2) **[M]** | [T:p:labels-procs-fns] | V1 same | **PT** |
| `PROC name(p): … ENDP` / `CALL name(arg)` | exactly one parameter, no return value, recursion (150 deep ✓), memory-limited depth | [T:p:recursion-150; s:proc_recursion, recursion_depth12, control_stack] | V1 `CALL label` w/o params / stock `GOSUB` | **PT** (L2) |
| `DEF FN name(p) = expr` / `FN name(arg)` | one numeric parameter; recursion-safe | [T:p:labels-procs-fns; s:deffn] | V1 minimal / stock same | **PT** |
| `GOSUB` / `RETURN` | not accepted (error 2) | decision (replaced by PROC/CALL) | V1 yes / stock yes | **IU** (regression for stock/V1 code) |
| `DIM a(n)` (numeric, constant `n`) | constant size ≥ 1; element read/write; bounds-checked (error 10); redeclare = error 38; `DIM a(n)` with variable `n` → error 34; `DIM a(3,3)` → error 37 | [T:p:seg2-*, dim-*; s:arrays, dynamic_arrays] | stock multi-dim, run-time size | **PT** (1-D) ; N-D/runtime size **IU** (L9) |
| `DIM a$(n[,w])` (string arrays) | accepted; width default/override | [T:p:seg2-string; s:string_arrays] | stock `DIM a$(n,w)` | **PT** |
| `DIMN(a)` | size of a DIM'd array (function form) | [T:s:dynamic_arrays, arrays] | V1 yes | **IT** |
| `INPUT v` / `INPUT v$` | one target, **no prompt string** (`INPUT "N"; n` → error 43); runtime blocking behaviour not verified here | [T:s:input] | stock prompts + lists | **PI** / **IT** |
| `REM`, `:` separators | accepted; `'` comment is **not** (silent truncation, D3) **[M]** | [T:p] | stock `REM` only | **PT** |
| `END`, `STOP` | both compile to HALT; no `CONT` | — | stock STOP resumable | **IT** (L8) |
| `CLS` `BORDER` `INK` `PAPER` | accepted | [T:s:compiler_r7, graphics_pixel] | | **IT** |
| `FLASH` `BRIGHT` `OVER` `INVERSE` | accepted as statements (R10.7 restoration); state persists across RUN **[M]** | [T:s:compiler_r7, graphics_pixel] | stock yes | **IT** (state leak §4.8 gap) |
| `PLOT x,y` / `LINE x0,y0 TO x1,y1` | accepted; `PLOT` ~977/s **[M]** | [T:s:graphics_pixel, decompiler_phase2] | stock `PLOT`/`DRAW` | **IT** |
| `CIRCLE x,y,r` / `FILL x,y` (SHAPES package) | production flow measured: filled disc **[M]**; FILL incomplete on dense regions (D7) | [T:f (10 fixtures); s:shapes_circle] | V1 resident (removed 2026-09-19 for ROM) | **PI** (D7), package (L7) |
| `DRAW` | absent | — | stock yes | **MR** (no V2 decision recorded beyond the stock matrix) |
| `BEEP d,p` / `SOUND r,v` | compile + run without error **[M]**; audible output not verified | [T:s:compiler_*] | stock `BEEP`; `SOUND` is AY-specific | **IT** (raw AY registers 1–16; no `PLAY`) |
| `PAUSE n` | accepted (`PAUSE 1` ran **[M]**); `PAUSE 0` waits for a key per the `kernel/io` comments **[S]** | [T:s:block_if…] | stock same | **IT** |
| `RANDOMISE n` | spelled `RANDOMISE`; `RANDOMIZE` → error 2 | [T:s:compiler_r7] | stock both | **IT** |
| `POKE a,v` | accepted; `PEEK` round trip ✓ **[M]** | [T:s:ext_demo, decompiler_phase2] | | **IT** |
| `CLEAR` | statement exists; resets array arena + package registry but not scalars/array pointers; breaks following package calls (D8) | no test | stock clears variables | **PI** (D8) |
| `OUT`, `IN` (statement/function) | absent | `R10_25_CAPABILITY_EXPOSURE_AUDIT.md` class C | stock yes; V1 `OUT` package | **MR** |
| `DATA` / `READ` / `RESTORE` | absent (`DATA 1,2,3` → error 2) | spec: rejected | stock yes | **IU** |
| `MERGE`, `CONT`, `COPY`, `LET`, `SCREEN$`, `VAL$`, `VERIFY`(see §7) | absent (except VERIFY) | spec: MERGE rejected | stock yes | **IU/MR** |
| Extension statements (`GRAB`, `SHOW`, `HIDE`, `MOVE`, `MODE`, `ULAPLUS`, `PALETTE`, `CIRCLE`, `FILL`, `CPLOT`, `BLOCK`, `FRAME`, `INVERT`) | recognised **only while the owning package is registered** at compile time; otherwise compile error 2 (generic) **[M]** | §6 | V1 resident SPRITE etc. (syntax `SPRITE GRAB` → `GRAB`) | **IT** |

## 3. Operators and expressions

| Feature | V2 reality | Status |
|---|---|---|
| `+ - * /`, unary `-`, parentheses | accepted; `/` yields float when inexact (`7/2` → `3.5000`) **[M]**; **unclosed `(` is accepted silently** (D3 family) **[M]** | **PT** / defect |
| Comparison `= < > <= >= <>` (numeric) | accepted [T:s:relational] | **IT** |
| String comparison | **only `=` and `<`**; `<>`, `>`, `<=`, `>=` → compile error 3 **[M]** — the language spec lists ordering comparisons on strings as MUST HAVE | **PI / MR vs spec** |
| `a MOD b`, `a DIV b` | **not operators**; functions `MOD(a,b)`, `DIV(a,b)`. The infix form silently ends compilation (D3) **[M]** | **PI** (documented as functions) |
| Exponentiation `^`, bit ops | absent | **IU** |
| Hex/binary/exponent literals (`$FF`, `&HFF`, `1E3`) | not accepted (error 3) **[M]** | **IU** |
| Integer literal range | `100000` prints `-31072` (wraps, no error) **[M]** | **PI** (D11) |
| Operator precedence | standard; not separately tested | **IT** |

## 4. Numerics

| Feature | V2 reality | Status |
|---|---|---|
| 16-bit signed integer fast path | `+ - *` wrap silently (`30000*3`→`24464`, `32767+1`→`-32768`) **[M]**; V1 raised `NUMERIC OVERFLOW` on `*` | **PI / MR vs V1** (D11) |
| Float (5-byte, calculator) | produced by `/`, decimal literals (`10.5`), `SQR PI RAD DEG SIN COS TAN`; float+int mixed arithmetic composes (`SQR(2)+1` → `2.4142`) **[M]**; ≈ 110 float loop iterations/s (≈ 32 k T per `x = x + 0.5`) **[M]** | **IT** (component tests `r10_numeric`, `group6_math`, `sqr`; production probes only) |
| Float display | fixed 4 decimals, **truncated**: `SIN(30)`=`0.4999`, `0.1+0.2`=`0.2999`, `PI()`=`3.1415` **[M]** | **PI** (D10) |
| `INT(x)` | truncates toward zero (`INT(-3.5)` → `-3`; stock floors) | **IT** (L6) |
| `MOD(-7,3)`, `DIV(-7,2)` | `-1`, `-3` (truncating) | **IT** |
| Division by zero | runtime error 5 (improvement over V1's silent 0); not in the production checks, measured here **[M]** | **IT** |
| `RND(n)` | integer-valued (observed `RND(6)` → `1`); range semantics not verified; V1-style integer RNG (stock returns a float 0..1) | **IT** |
| `ABS SGN` | float-aware `ABS`; `SGN` ok **[M]** | **IT** |
| Trig: `SIN COS TAN` (degrees), `ASN ACS ATN EXP LN` | first three present; the rest absent | **PI** (L9) |

## 5. Strings, arrays, variables, identifiers, memory

| Feature | V2 reality | Status |
|---|---|---|
| String length | 31 characters per scalar/element (fixed 32-byte slot) | **IU** (L3) |
| String functions | `LEN CODE VAL CHR$ STR$ UPPER$ LOWER$ LEFT$ RIGHT$ MID$ INKEY$()` present [T:s:strfuncs, builtin_roundtrip]; probes: `LEN("foobar")`=6, `MID$("hello",2,3)`→"ell", `VAL("123")+1`=124 **[M]**; `INSTR` absent (V1 had); slicing `a$(2 TO 3)` silently truncates the program (D3) **[M]** | **IT** / `INSTR` **MR** vs V1 |
| Identifiers | case-insensitive, 31 significant chars, letters + digits (`my_var` → error 2); 32 chars → error 61 `NAME TOO LONG` **[M/T:p:ident-31,32]**; keyword prefixes (`tomato`, `to1`) are ordinary names **[M]** | **PT** |
| Scalar symbols | **253 numeric, 253 string** (255 − 2 temp slots), **255 numeric arrays, 255 string arrays** — one-byte operand; 254th numeric → `TOO MANY VARIABLES` **[T:p:253-vars,254-vars]** (reconciliation: gap §4.4) | **PT** |
| Arrays | 1-D, 0-based, 16-bit elements, whole array in main pool else segment 2; lifetime = until next RUN/edit/NEW/CLEAR; `FREE()`, `FREE(1)` | **PT** (D6 for LOAD, D8 for CLEAR) |
| Memory model | pool 8,397 B (source + arrays + carved run tables), bytecode 4,011 B, segment 2 2,048 B; messages `OUT OF MEMORY` (4 resources, R8), `STACK OVERFLOW`, `PROGRAM FULL`, `TOO MANY VARIABLES`, `NESTING TOO DEEP`, `NAME TOO LONG` | **PT** |
| Variable inspection after RUN | none: variables are re-zeroed per RUN and per `:` statement (L8) | **IU/MR** |

## 6. Built-in functions (30 table rows; `BUILTIN_FN_TABLE`, statically checked against VM and decompiler tables)

| Function | Status | Notes |
|---|---|---|
| `ABS SGN MOD DIV RND INT` | IT | numeric; `MOD/DIV` are functions |
| `POINT(x,y) ATTR(r,c)` | IT | thin adapters on kernel graphics |
| `PEEK USR` | IT | `USR(0)` resets the machine (expected) |
| `LEN CODE VAL` | IT | string argument |
| `CHR$ STR$ UPPER$ LOWER$ LEFT$ RIGHT$ MID$` | IT | string results; `$` written in source |
| `INKEY$()` | IT | non-blocking key; **0-argument functions require `()`**: `PI`, `FREE`, `INKEY$` without parentheses → compile error 29 **[M]** |
| `SQR PI RAD DEG SIN COS TAN` | IT | float results; D10 display |
| `FREE()`, `FREE(0)`, `FREE(1)` | PT | main-pool / segment-2 bytes free [T:p:free-1, free-expr-arg] |
| `DIMN(a)` | IT | |
| absent vs V1/stock | MR/IU | `STICK` (V1; removed R10.7 as dead code — prior audits already list it), `INSTR`, `ASN ACS ATN EXP LN`, `SCREEN$`, `VAL$`, `IN`, `TAB/AT` as functions |

## 7. Cassette, persistence, packages

| Feature | V2 reality | Status |
|---|---|---|
| `SAVE "name"` | up to 10 chars; stock header (type 0) + one data block; prints `SAVED` unconditionally; no progress display | **IT** (transport proven in **Fuse** per R9 ledger **[D]**; D1/D2/R3 for the receive/format side) |
| `LOAD "name"` / `LOAD ""` | header search, name/type/length checks, program replaced; **partial/aborted transfers reported as LOADED** (D1) | **PI** (D1) |
| `VERIFY "name"` | present (R10.25); failure erases the program, mismatch never detected (D2) | **PI** (D2) |
| `SAVE/LOAD "n" EXT` | save/load the resident package; ABI byte check only (R1) | **IT** (R1) |
| `SAVE/LOAD "n" ARRAY a` | SAVE works (incl. segment 2 **[M]**); LOAD allocates but the array cannot reach a RUN (D6) | **PI** (D6) |
| Program format | plain text records, position-independent; unversioned (R3) | **IT** |
| Tape validation on production | no automated production-ROM tape test; headless ZEsarUX cannot sample tape reliably (R9 ledger) | **IT** (physical/Fuse validation required; user asked not to run Fuse now) |

### 7.1 Runtime extensions / loadable packages (one resident at a time, L7)

| Package (`build/v2_package_*.bin`) | Statements | Size | Notes | Status |
|---|---|---|---|---|
| MODE | `MODE m`, `ULAPLUS u`, `PALETTE i,v` | 165 B | `MODE 1` runs; editor display garbled on return (U6) **[M]** | **IT** [T:s:mode_module] |
| SPRITE | `GRAB s,r,c,w,h` `SHOW s,r,c` `MOVE s,r,c` `HIDE s` | 832 B | production flow ran clean; errors 15/17 reported as generic `RUNTIME ERROR` **[M]**; **no V2 standalone test** (`rom/test_v2_sprite_module.asm` not in the runner) | **IT** |
| PRINTER | `LPRINT`, `LLIST` | 345 B | [T:s:printer_module] | **IT** |
| SHAPES | `CIRCLE`, `FILL` | 795 B | production flow ✓ **[M]**; D7 | **PI** |
| GRAPHICS | `CPLOT`, `BLOCK`, `FRAME`, `INVERT` | 467 B | built by `make v2-packages`, **not copied into the release assets** (4 TZX), and `docs/user_manual.md` says these are "not linked into the V2 system" | **IT** [T:s:graphics_module]; doc discrepancy |
| AYREG, OUT (V1 packages) | — | — | not ported | **MR** (decision recorded in the manual) |

Package ABI: R1/A1–A7 in the gap analysis (absolute HOME addresses; `autostart` byte = 1 is the only
check).

## 8. Graphics, colour, sprites, sound

| Area | V2 production | Status |
|---|---|---|
| Colour: `BORDER INK PAPER BRIGHT FLASH OVER INVERSE` | present; **not reset between runs** (gap §4.8) | **IT** |
| `PLOT LINE` + `POINT ATTR` | present | **IT** |
| `CIRCLE FILL` | package; D7 | **PI** |
| Video modes | `MODE 0/1` (normal, hi-res) via package; 64-column removed (2026-08-20); ULAplus/PALETTE via package; editor does not recover from `MODE 1` | **IT** (U6) |
| Sprites | 8 slots, GRAB from screen, SHOW/MOVE/HIDE; package; buffers `$E800–$F0FF` | **IT** |
| Sound | `BEEP`, `SOUND reg,val` (raw AY 1–16); startup chime (boot only) | **IT** (not audited audibly) |
| Printer | package | **IT** |

## 9. Keyboard, joystick, input, system

| Feature | V2 production | Status |
|---|---|---|
| Keyboard decode | CAPS/SYMBOL combos, lowercase default, auto-repeat 35/5 ticks, single-slot latch | **IT** (no production test; U1) |
| `INKEY$()` | non-blocking | **IT** |
| `INPUT` | blocking, one variable | **IT** |
| `PAUSE n`, `FREE()` | present | **IT/PT** |
| **BREAK** | **not implemented for running programs**; key code `$10` is inserted into the edit line (D5/D5b) | **MR** |
| Joystick (`STICK`) | absent (removed from the production kernel R10.7 as dead code) | **MR** |
| `PEEK/POKE/USR` | present | **IT** |
| `IN`/`OUT` ports | absent | **MR** |

## 10. Procedures, control flow, recursion, error handling

| Feature | Status | Notes |
|---|---|---|
| Recursion | **PT** | 150-deep parameter recursion ✓; unbounded recursion → clean `STACK OVERFLOW` with arrays intact [T:p:stack-into-arrays] |
| Exit/unwind (`EXIT FOR`, GOTO out of FOR in a PROC) | **PT** | |
| Runtime error handling | **PI** | five-ish classes of message, no code, no line (U5); no `ON ERROR`; `STOP` = `END` |
| Compile error handling | **PI** | 60 distinct internal codes collapse to `SYNTAX ERROR`; cursor jump wrong (D4); silent truncation (D3) |
| Memory exhaustion recovery | **PT** | `OUT OF MEMORY`, source intact [T:p:dim-under-recursion, seg2-exhausted] |

## 11. Editor, listing, decompilation

| Feature | V2 production | Status |
|---|---|---|
| Full-screen editor, word-wrap, insert/delete char/line, status bar, keyword emphasis | present (detail: editor audit) | **IT** (no production test) |
| Navigation | UP/DOWN/LEFT/RIGHT only (U2) | **PI** |
| `LIST` | paged, abortless (ED5) | **IT** |
| `LLIST` | PRINTER package, source-based | **IT** |
| Decompiler | **test-only**; 30/30 built-ins round-trip (bytecode equivalence; float functions not behaviourally compared); 31-char fragment limit (L10) | **IT** (not a user feature) |

## 12. Discrepancies between documented and accepted language

| # | Document | Says | Actual |
|---|---|---|---|
| DD-1 | `docs/user_manual.md`, `docs/basic_language_reference.md` | V1 language: `GOSUB/RETURN`, `DATA/READ/RESTORE`, `ELSEIF`, `SPRITE GRAB …`, `INSTR`, `STICK`, resident `CIRCLE/FILL` | none of these exist in V2 (manual header admits "historical … being reconciled") |
| DD-2 | `docs/v2/V2_LANGUAGE_SPEC.md` (Phase 2) | MUST HAVE: string ordering `< <= > >=`, `AND/OR` short-circuit, multi-dim arrays, checker `IF/FOR` balance; hybrid promotion "on `+ - *`" | string compare only `= <`; no short-circuit; no multi-dim; unmatched `FOR` and unclosed `(` silently accepted; `+ - *` do **not** promote on integer overflow (D11) |
| DD-3 | `docs/v2/R10_STOCK_TS2068_CAPABILITY_MATRIX.md` | FOR nests 4 deep; 4×16 arrays; 16 numeric slots; 4 string vars; 24 built-ins; **no** `FLASH BRIGHT OVER INVERSE FREE CLEAR MID$ COS TAN`, no string arrays; `VERIFY`/`CLEAR` absent | all now present (R10.7/R10.25): memory-limited nesting, 253/253/255/255 symbols, 30 built-ins, `CLEAR`, `VERIFY`, string arrays, `MID$ COS TAN FREE` |
| DD-4 | `docs/v2/CURRENT_LIMITATIONS.md` | "V1 has 5 bytes free … nothing can be just added" | V1-era text; V2 has 546/1,385 B free |
| DD-5 | README, `make release-assets` | "Four loadable V2 packages" | five package images build; release ships four; manual says CPLOT/BLOCK/FRAME/INVERT are "not linked" though `v2_package_graphics.bin` exists |
| DD-6 | README "make test … 14 V2 ZEsarUX fixtures" | | 38 standalone + 19 production + 10 FILL + 9 smoke; headless |
| DD-7 | `R9_HANDOFF/R9 commit 9fc3890` "physical cassette round-trip proven" | | proven in **Fuse** (emulator); no physical-hardware evidence in the repo |
| DD-8 | `R10_7_LIMITS_REMOVAL_PROGRESS.md` P5.2 "FILL … exact" | exact | exact only for the 10 fixtures; D7 |
| DD-9 | `R10_7_CAPABILITY_RESTORATION.md` §11.2 array LOAD | allocates "fresh from the tape … the loading session acts on" | cleared by the next RUN (D6) |
| DD-10 | compiler header comments (error table 1–48; "block IF out of R3's scope") | | codes 55–64 live in the shell; block IF exists; no single authoritative error-code list |
| DD-11 | PRINT comments mention "trailing `;`" style variants in older matrix | | `PRINT x; x` ends the program silently (D3) |

## 13. V1 → V2 regression summary

**Regressions (V1 had it, V2 does not, no recorded product decision):** `ELSEIF`; `NUMERIC OVERFLOW`
on `*`; `STICK()`; `INSTR()`; `HELP`/`EDIT`/`DELETE` commands; multi-error browse (SYMBOL SHIFT+A/S);
live-typing checker. **Decided changes:** `GOSUB/RETURN` → `PROC/CALL(arg)`; `SPRITE GRAB` → `GRAB`; resident
`CIRCLE/FILL/LPRINT/SPRITE/MODE` → loadable packages. **Improvements:** 31-char identifiers (was 1–8),
253 string variables (was 26), string arrays, hybrid float, division by zero is an error, memory-limited
recursion/labels/FOR nesting, block IF/ELSE/ENDIF, `MID$ COS TAN FREE VERIFY CLEAR`, compile-whole-then-run (no
half-running program, **modulo D3**).

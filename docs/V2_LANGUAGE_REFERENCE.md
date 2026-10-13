# 2068-Leap V2 -- language reference (V2 Enhanced release)

The compact, precise description of the language the V2 Enhanced release implements (tag `v2.0.0-emu.1`; the language is unchanged in the maintenance release `v2.0.1-emu.1` apart from the sound changes it lists, and on the `v2-development` branch apart from the memory figures, which this copy gives for the development ROM). It is derived from the ROM source, the package modules and the qualification evidence, and every statement in it was checked on the release image. The teaching version, with a worked example for every keyword, is the **user manual**: [`manual/01_introduction.md`](manual/01_introduction.md); its keyword part ([`manual/03_keywords.md`](manual/03_keywords.md)) is this reference with examples, and its examples are tests (`make doc-examples`). The language conformance corpus (`tools/qual/corpus.py`, 667 cases, `make qual`) is the historical release record and is unchanged. Where an older document (`docs/v1/user_manual.md`, `docs/v1/basic_language_reference.md`, the V1 manuals) disagrees with this one, this one wins. Corrections made to the previous version of this file are listed in [`V2_DOCUMENTATION_FINDINGS.md`](V2_DOCUMENTATION_FINDINGS.md). Features that are deliberately not in V2 are in section 12 and in `V2_FEATURE_MATRIX.md`.

## 1. Programs, lines and labels

* A program is a list of lines, edited in the full-screen editor; there are **no line numbers**.
* A line holds one or more statements separated by `:`. A line is at most 127 characters.
* A **label** is a line `name:` -- it names the next statement. Labels are the only jump targets (`GOTO name`, `IF ... THEN GOTO name`). A duplicate label is compile error 57.
* `REM` comments run to the end of the line (a `:` in a comment does not end it). `'` is not a comment character.
* The whole program is compiled before it runs (`RUN`): a compile error shows its message on the status line and, at the next key, moves the cursor to the failing line; nothing runs.
* Keywords, names and statements are not case-sensitive.

## 2. Names, types and values

* Identifiers: a letter, then letters and digits, up to 31 characters (longer: error 61), case-insensitive. **No underscore.** A keyword or the name of a built-in function (`print`, `abs`, `code`, `len` ...) cannot be used as a variable, array, label, procedure or function name; a name that merely *begins* with one can (`tomato`, `format`).
* `name$` is a string variable; `name(i)` / `name$(i)` an array element. `x`, `x$` and `x(1)` are three different things.
* **Numbers** are 16-bit integers (-32768 .. 32767) or 5-byte floats (the Sinclair format: 32-bit mantissa, about 9 significant digits, magnitude up to about 1.7E38). Integer arithmetic that overflows promotes to a float; a float result beyond the range is run-time error **67**; a result below the range becomes 0.
* **Strings** hold 0..31 characters. A string literal longer than 31 characters is compile error **70**; a concatenation longer than 31 characters keeps the first 31.
* Variables need no declaration; a variable never assigned is 0 / "" (section 9 says when variables are fresh).

## 3. Literals

| Form | Value |
|---|---|
| `0` .. `32767` | integer |
| `32768` .. `65535` | a positive float (literal rule L-C); still usable wherever an address is expected (`POKE 65000,1`, `PEEK`, `USR`) |
| larger integers, decimals (`3.14159`, `0.000001`, `12345.5`) | exact 5-byte float (decimal-to-binary rounding of the 32-bit mantissa) |
| beyond about 1.7E38 | compile error 64 (message `UNEXPECTED TOKEN`) |
| `"text"` | a string, at most 31 characters; no escape for a quote |

There is no exponent notation and no hexadecimal literal. A minus sign is an operator.

## 4. Expressions

Precedence, highest first: function calls and brackets; unary `-`; `*` `/`; `+` `-`; relations `=` `<>` `<` `>` `<=` `>=`; `NOT`; `AND`; `OR`. Equal ranks work left to right. There is no power operator, and `DIV`/`MOD` are functions.

* `/` is exact division (an inexact integer quotient becomes a float); `DIV(a,b)` and `MOD(a,b)` are integer division and remainder (floats are truncated first); division by zero is run-time error 5.
* Relations give 1 (true) or 0 (false), on numbers and on strings (all six, character by character by code; a prefix sorts first). An integer and a float with the same value compare equal.
* `AND` / `OR` short-circuit and give 0/1 (they are logical, not bitwise: `3 AND 5` is 1); `NOT` gives 0/1. Any nonzero number is true.
* `+` concatenates strings; a string and a number cannot be mixed (compile error).
* `PRINT` shows an integer as is and a float with four decimals, the stored value rounded (`0.1 + 0.2` prints `0.3000`, `PRINT 65535` prints `65535.0000`).

## 5. Statements

| Statement | Notes |
|---|---|
| `var = expr`, `var$ = expr$`, `a(i) = expr`, `a$(i) = expr$` | assignment (no `LET`) |
| `PRINT [item {; or , item} [; or ,]]` | `;` joins with nothing, `,` goes to the next 16-column zone; a trailing separator keeps the cursor on the line; bare `PRINT` is an empty line; text wraps at column 32 and the screen scrolls after row 22 (row 23 is the status line) |
| `AT row,col`, `TAB col` | move the `PRINT` position: row above 23 is 23, **column modulo 32** |
| `INPUT var`, `INPUT "prompt"; var`, `INPUT "prompt", var` | numeric input accepts integers and decimals (up to 20 characters; non-numbers give 0, trailing text is ignored); string input up to 31; the answer is echoed; **only a plain variable** (an array element is compile error 64) |
| `IF cond THEN` ... [`ELSE` ...] `ENDIF` | always a block; the only one-line form is `IF cond THEN GOTO label`; no `ELSEIF` |
| `FOR v = a TO b [STEP s]` ... `NEXT [v]` | integer or float loop (any of a, b, s a float makes it a float loop; the step is added each time, so a fractional count is as exact as the arithmetic); limit and step evaluated once; a start already past the limit runs zero times; after a normal exit `v` is the first value past the limit; `STEP 0` never advances (stop with `BREAK` or `EXIT FOR`); `EXIT FOR` leaves the innermost loop; a `NEXT` without its `FOR`, or for another variable, is a compile error |
| `GOTO label` | out of loops allowed; into one: run-time error 7 at its `NEXT` |
| `PROC name(p):` ... `ENDP`, `CALL name(expr)` | one by-value parameter (restored on return); recursion works (about 670 levels); other variables are shared; a `PROC` in the flow of control is skipped; `CALL` of a plain label is accepted and does not return (Q-24, accepted) |
| `DEF FN f(x) = expr` / `FN f(expr)` | numeric, one parameter; may be used before its definition; duplicate names are compile error 57 |
| `DIM a(n)`, `DIM a$(n)`, `DIM a$(n,w)` | arrays of `n` elements, indices 0 .. n-1; `n` a literal (1 .. 16383; what fits is memory-limited); numeric elements are 16-bit integers (a float or a value outside -32768..32767 is run-time error 11); string elements are `w` bytes (`w`-1 characters; default `w` = 16); a name is DIM'd once per run (error 38); out-of-range index run-time error 10; one dimension |
| `CLEAR` | variables and ordinary arrays back to 0 / empty; ends enclosing loops (a later `NEXT` is run-time error 7); program, packages and the Array Store stay |
| `END`, `STOP` | stop (variables stay, section 9) |
| `CLS` | clear the text area to the current colours, home the `PRINT` position |
| `BORDER n`, `INK n`, `PAPER n` | low 3 bits of n |
| `FLASH n`, `BRIGHT n`, `OVER n`, `INVERSE n` | only the **low bit** of n |
| `PLOT x,y`, `LINE x0,y0 TO x1,y1` | 256 x 192 pixels, x from the left, **y from the top**; coordinates outside the screen are moved to the edge; fractions cut off |
| `BEEP seconds,semitones` | Sinclair's `BEEP`, on the AY chip's channel A (maintenance release): `seconds` 0..273, rounded to whole display frames (under half a frame: silent); `semitones` -60..69 from middle C, a fraction cut off toward zero, below -39 plays -39 (27.5 Hz); otherwise run-time error 15. Channel A is left silent, channels B and C untouched; interrupts stay on, BREAK stops a note |
| `SOUND register,value` | writes `value` to AY register `register`, **0 to 16** as in the stock TS2068 BASIC (low 8 bits of `register`, sent to the chip unchanged); 17 or more: run-time error 8. (The first V2 release refused register 0.) |
| `POKE address,value`, `OUT port,value` | low byte of `value`; address / port 0 .. 65535 (65536 and above: error 15) |
| `PAUSE n` | wait `n` display frames, counted with `HALT` (0: wait for a key); BREAK interrupts; needs the frame interrupt (with it off, `PAUSE` never ends). The first V2 release's `PAUSE` could end at once when the frame counter wrapped past 65535; fixed in the maintenance release |
| `RANDOMISE n` | seed `RND`; the number is required |
| `REM text` | comment |

## 6. Built-in functions

| Function | Result |
|---|---|
| `ABS(n)`, `SGN(n)`, `INT(n)` | absolute value, sign (-1/0/1), the integer part **truncated toward zero** (`INT(-3.5)` = -3; Sinclair BASIC floors) |
| `MOD(a,b)`, `DIV(a,b)` | truncated remainder / quotient (`MOD(-7,3)` = -1, `DIV(-7,2)` = -3; error 5 for b = 0) |
| `SQR(n)` | square root (a float; error 15 for n < 0) |
| `SIN(d)`, `COS(d)`, `TAN(d)` | degrees (fractions allowed); `TAN(90)` is error 5 |
| `PI()`, `RAD(d)`, `DEG(r)` | pi; degrees to radians; radians to degrees |
| `RND(n)` | a random whole number 0 .. n-1 (0 when n < 1) |
| `LEN(s$)`, `CODE(s$)`, `VAL(s$)` | length; code of the first character (0 if empty); the leading number of the text (spaces and a sign skipped; 0 if none) |
| `CHR$(n)` | one character (error 15 outside 0..255); codes 32..127 the ROM font, 128..143 block graphics, **144..164 the 21 user-defined characters**, other codes blank |
| `STR$(n)` | the number as `PRINT` shows it |
| `UPPER$(s$)`, `LOWER$(s$)` | case conversion |
| `LEFT$(s$,n)`, `RIGHT$(s$,n)`, `MID$(s$,start,n)` | substrings (1-based start, below 1 counts as 1; counts clamped) |
| `INKEY$()` | the key now held, or "" |
| `PEEK(a)` | byte at an address (0..65535) |
| `USR(a)` | calls machine code at `a` with `CALL`; **the result is HL on return**, 0..65535 (a result of 32768 or more is a float); the ROM saves and restores `IY`; everything else may be destroyed; interrupts must stay enabled; the routine must `RET` |
| `IN(port)`, `STICK(n)` | port read (full 16-bit address); joystick 1 (0..15) or 2 (0..1); other n: error 15 |
| `POINT(x,y)`, `ATTR(row,col)` | pixel (0/1); attribute (ink + 8 paper + 64 bright + 128 flash; 0 off-screen) |
| `FREE()`, `FREE(1)` | free bytes of the main pool / of segment 2 |
| `DIMN(a)` | the declared size of a **numeric** array (a string array: compile error 47) |

Functions are always written with brackets, even without an argument.

**User-defined characters.** Codes 144..164 print the 8 x 8 bitmap held in the 168-byte table `UDG_TABLE` at **61824 (`$F180`)**: character *c* at `61824 + (c - 144) * 8`, eight bytes, top row first, bit 7 the leftmost pixel. They are defined with `POKE` (there is no statement and no `USR "a"`), print in the current colours and follow `OVER`/`INVERSE`, survive `RUN`, `CLEAR`, `CLS`, `NEW`, `MODE` and `LOAD` of a program, are not saved on tape and are **not initialised at start-up** (the emulator's RAM is zero; a real machine's may not be). The ROM font (codes 32..127) and the block graphics cannot be redefined. See manual concept *User-defined characters*.

## 7. Commands (typed on the editor's empty last line, not in programs)

| Command | Effect |
|---|---|
| `RUN` | compile and run the program with fresh variables |
| `: statements` | run immediately, in the current variable session (section 9) |
| `LIST` | list the program, 23 lines a page; BREAK at a full page stops it |
| `NEW` | clear the program, variables, package and the Array Store |
| `SAVE "name"` / `LOAD "name"` / `VERIFY "name"` | program tapes (a name of up to 10 characters; `LOAD ""` takes the next program) |
| `SAVE "name" ALL` | program + variable session + Array Store in one tape block (`V2_SAVE_ALL_FORMAT.md`); about 2.4 s identity check before the tones, also on `LOAD` and `VERIFY` of an ALL tape |
| `SAVE "name" ARRAY a` / `LOAD "name" ARRAY a` | one array to / from tape; `LOAD ... ARRAY` puts it in the Array Store, where it survives `RUN`, `CLEAR` and edits, and a matching `DIM` adopts it |
| `SAVE "name" EXT` / `LOAD "name" EXT` | a loadable package (`PACKAGE_ABI.md`); `NO PACKAGE` if `SAVE` has none |

## 8. Errors

The screen shows a **message**, never a number. Compile errors stop before anything runs; run-time errors stop the program (its variables are kept). The messages: `SYNTAX ERROR`, `UNEXPECTED TOKEN`, `NAME TOO LONG`, `NESTING TOO DEEP`, `TOO MANY VARIABLES`, `OUT OF MEMORY`, `STACK OVERFLOW`, `RUNTIME ERROR`, `ARRAY SIZE MISMATCH`, `BREAK`, `PROGRAM FULL`, and the tape messages `SAVED`, `LOADED`, `VERIFIED`, `VERIFY FAILED`, `LOAD FAILED`, `NO VARIABLES`, `BAD TAPE VERSION`, `ABORTED`, `NO PACKAGE`, `ARRAY NOT DIMD`, `ARRAY STORE FULL`, `BAD ARRAY TAPE`. Appendix A of the manual explains each.

Internal codes (as used by the tests and the source). **Compile errors**, each with a program that causes it in Appendix B of the manual (`app.cerr.*`, run by `make doc-examples`):

| Code | Cause | Message |
|---|---|---|
| 1, 39 | more than 251 number / 251 string names (1), more than 255 array names (39) | `TOO MANY VARIABLES` |
| 2 | identifier not followed by `=`, unknown word, package statement without its package | `SYNTAX ERROR` |
| 3 | an expression could not start | `SYNTAX ERROR` |
| 5, 6, 55, 62 | out of compile memory: label table, forward references, code area, workspace | `OUT OF MEMORY` |
| 7 | `GOTO` an undefined label | `SYNTAX ERROR` |
| 8, 9 | `IF` without `THEN` (8); block `IF` without `ELSE`/`ENDIF` (9) | `SYNTAX ERROR` |
| 10, 11, 12 | `FOR`/`NEXT` without a variable (10); `FOR` without `TO` (11); no label after `GOTO` (12) | `SYNTAX ERROR` |
| 13 .. 15 | `CALL`: no name, no `(`, no `)` | `SYNTAX ERROR` |
| 16 .. 20 | `PROC`: no `ENDP` (16); no name, `(`, parameter, `)` (17..20) | `SYNTAX ERROR` |
| 22 .. 25 | missing comma / `TO` in `PLOT`, `BEEP`, `POKE`, `SOUND`, `OUT`, `AT`, `LINE` | `SYNTAX ERROR` |
| 28 | wrong number of arguments of a package statement | `SYNTAX ERROR` |
| 29 .. 31 | built-in function call: no `(`, comma, `)` | `SYNTAX ERROR` |
| 32 .. 38 | `DIM`: no name (32; also `LPRINT` without its package), no `(` (33), size not a literal (34), size 0 (35), no `)` (37), declared twice (38) | `SYNTAX ERROR` |
| 41, 42 | array index without `)` (41); assignment to an array never DIM'd (42) | `SYNTAX ERROR` |
| 43, 44 | `INPUT` without a plain variable; `EXIT` without `FOR` | `SYNTAX ERROR` |
| 46 .. 48 | `DIMN`: no `(`, not a numeric array, no `)` | `SYNTAX ERROR` |
| 49 .. 54 | `DEF FN`: no `FN`, name, `(`, parameter, `)`, `=` | `SYNTAX ERROR` |
| 56, 57, 63 | `NEXT` for another variable; duplicate label / `PROC` / `DEF FN`; `EXIT FOR` outside a loop | `SYNTAX ERROR` |
| 60, 61 | nesting too deep; name too long | `NESTING TOO DEEP`, `NAME TOO LONG` |
| 64 | unexpected token (also a literal beyond the number range) | `UNEXPECTED TOKEN` |
| 65, 66 | `FOR` without `NEXT`; bracket not closed | `SYNTAX ERROR` |
| 70 | string literal longer than 31 characters | `SYNTAX ERROR` |
| 71 | an immediate statement defined a label, `PROC` or `DEF FN` | `SYNTAX ERROR` |

**Run-time errors** (`ve`):

| Code | Cause | Message |
|---|---|---|
| 2, 6 | expression stack (2) / control stack, i.e. recursion or nested loops (6) overflow | `STACK OVERFLOW` |
| 5 | division by zero (also `TAN(90)`) | `RUNTIME ERROR` |
| 7 | `NEXT` / return without a frame (jump into a loop; after `CLEAR` inside a loop) | `RUNTIME ERROR` |
| 10, 11 | array index out of range (10); non-integer or out-of-range value stored in, or used as an index of, a numeric array (11) | `RUNTIME ERROR` |
| 8 | `SOUND` register 17 or more | `RUNTIME ERROR` |
| 15 | argument out of range (`CHR$`, `STICK`, `SQR` of a negative number, an address of 65536 or more, `BEEP` out of range) | `RUNTIME ERROR` |
| 64, 65 | out of array memory (64); `DIM` differs from the stored array (65) | `OUT OF MEMORY`, `ARRAY SIZE MISMATCH` |
| 66 | BREAK | `BREAK` |
| 67 | a float result beyond about 1.7E38 | `RUNTIME ERROR` |
| 12, 13, 14 | mode package: bad `MODE`, `ULAPLUS`, `PALETTE` | `RUNTIME ERROR` |
| 15 .. 20 | sprite package: slot; row / column / size; never grabbed; already shown; not shown; does not fit | `RUNTIME ERROR` |
| 15 | cbeep package: `CBEEP` out of range | `RUNTIME ERROR` |

## 9. Variable sessions

`RUN` starts with fresh variables. When the program stops -- at its end, `END`, `STOP`, `BREAK` or an error -- its variables stay: immediate statements (`: PRINT x`, `: x = 7`, `: GOTO label`) use them and may add new ones; `CLEAR` resets them; any edit, `NEW` or `LOAD` ends the session. An immediate statement may not define a label, `PROC` or `DEF FN` (error 71). Full rules: `V2_SESSION_VARIABLES.md`; with examples: manual concept *Sessions*.

## 10. Memory and capacity

* **Storage model.** The program is kept as source text: each line is stored as a 2-byte length, the text and an end mark (length + 3 bytes) in the main pool, and stays as typed (`LIST`, `SAVE`, `LLIST` use it; no decompiler is in the release). `RUN` and immediate statements compile it to bytecode in a separate 4011-byte code area (`$A655-$B5FF`) that is rebuilt every time, is not part of the pool, not counted by `FREE()` and never saved.
* **The pool** is 9211 bytes (`$825A-$A654`): program text, the table of names (a 4-byte header + the name + any extra for every name), an 81-byte gap kept for immediate statements, the arrays (growing up), the control stack (growing down from the top of the free space) and, at the top, the run-time tables carved exactly for the compiler's counts (3 + 5 bytes per number name, 32 per string name, 2 per array, plus 4 spare number and 4 spare string slots = 148 bytes on an empty program).
* `FREE()` = the gap between the top of the arrays and the control stack (8967 on an empty machine with a one-line program); it excludes the code area, segment 2 and the run-time tables, and falls by 12 for every active procedure call or `FOR` loop. `FREE(1)` = free bytes of segment 2 (2 KB at `$E000`: arrays that do not fit in the pool, and the Array Store). Packages load into their own 1 KB window (`$F400`) and do not change `FREE()`.
* Costs: text length + 3 per line; first use of a number name 12 + length; string name 36 + length; label / `PROC` / `DEF FN` name 7 + length; numeric array 2 per element + about 11 + length; string array width (default 16) per element + about 13 + length. Numbers and string constants are in the code, not the pool.
* Limits: 251 number and 251 string names (strings are limited by memory long before: about 170 one-character strings); 255 array names; code area 4011 bytes (1000 lines of `x = 1`); recursion about 740 levels (12 bytes a level); nesting: brackets 105, `IF` 211, `FOR` 141. See manual Appendix D and the concept *Memory*.

## 11. Packages

A package tape adds statements: `LOAD "NAME" EXT`. One package at a time (a second replaces the first); `NEW` unloads it; a statement of a package that is not loaded is a compile error. Package arguments are whole numbers and statements that take positions use only the low 8 bits. Package authors: `PACKAGE_ABI.md`; users: manual Part 5.

| Package (tape name, size) | Statements |
|---|---|
| **mode** (`MODE`, 165 bytes) | `MODE m` (0 normal, 1 the TS2068's extended-colour mode: 8 x 1 colour attributes at `$6000`; the 512 x 192 mode is not offered), `ULAPLUS u` (0/1), `PALETTE i,v` (i 0..63) |
| **sprite** (`SPRITE`, 834) | `GRAB slot,row,col,w,h` (slot 0..7, w and h 1..4 cells), `SHOW slot,row,col`, `MOVE slot,row,col`, `HIDE slot` (positions in character cells) |
| **printer** (`PRINTER`, 345) | `LPRINT x` (one number or string; a number as a whole number), `LLIST` |
| **shapes** (`SHAPES`, 1007) | `CIRCLE x,y,r`, `FILL x,y` (pixel coordinates) |
| **graphics** (`GRAPHICS`, 467) | `CPLOT x,y` (64 x 48 grid), `BLOCK x0,y0,x1,y1`, `FRAME x0,y0,x1,y1`, `INVERT x0,y0,x1,y1` (pixel corners) |
| **cbeep** (`CBEEP`, 260) | `CBEEP ms,semitones,border`: the loudspeaker (port `$FE`), ms 0..32767, semitones -60..69, border colour 0..7 kept (a different number changes the border); interrupts off while it sounds, so BREAK waits for the note; error 15 out of range (maintenance release) |

## 12. Not in V2 (deliberately)

Line numbers, `GOSUB`/`RETURN` (use `PROC`/`CALL`), `LET`, single-line `IF ... THEN stmt` (other than `THEN GOTO`), `ELSEIF`, `INSTR`, string slicing `a$(i TO j)` (use `MID$`), `READ`/`DATA`, multi-dimensional arrays, `DIM` with a variable size, float array elements, `PRINT AT`/colour items inside `PRINT` (use the statements), exponent and hex literals, a power operator, `CONTINUE` (an immediate `: GOTO label` restarts at a label instead), `DIMN` of a string array. The characters `[`, `\`, `]`, `^`, `` ` ``, `{`, `|`, `}` and `~` print as blanks (the font has no glyphs for them -- accepted defect Q-26).

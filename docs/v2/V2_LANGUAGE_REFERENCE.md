# 2068-Leap V2 -- language reference (release candidate)

This is the authoritative description of the language the V2 release candidate implements
(`integration/v2-final-rom`). Where an older document (`docs/user_manual.md`,
`docs/basic_language_reference.md`, the V1 manuals) disagrees, this one wins; the executable form of
it is the conformance corpus `tools/qual/corpus.py` (667 cases, run by `make qual`). Features that
are deliberately not in V2 are listed in section 12 and in `V2_FEATURE_MATRIX.md`.
`V2_LANGUAGE_SPEC.md` is the planning-phase *target* (MUST HAVE / DESIRABLE, with cost estimates);
this document is what the release candidate implements.

## 1. Programs, lines and labels

* A program is a list of lines, edited in the full-screen editor; there are **no line numbers**.
* A line holds one or more statements separated by `:`. A line is at most 127 characters.
* A **label** is a line `name:` -- it names the next statement. Labels are the only jump targets
  (`GOTO name`, `IF ... THEN GOTO name`). A duplicate label is compile error 57.
* `REM` comments run to the end of the line.
* The whole program is compiled before it runs (`RUN`); a compile error shows the message and
  moves the cursor to the failing line, and nothing runs.

## 2. Names, types and values

* Identifiers: a letter, then letters/digits, up to 31 significant characters (longer: error 61),
  case-insensitive. `name$` is a string variable; `name(i)` / `name$(i)` an array element.
* **Numbers** are 16-bit integers (-32768 .. 32767) or 5-byte floats (the Sinclair format: 32-bit
  mantissa, about 9 significant digits, magnitude up to about 1.7E38). Integer arithmetic that
  overflows promotes to a float; a float result beyond the range is runtime error **67** (number
  too big); a result below the range becomes 0.
* **Strings** hold 0..31 characters. A string literal longer than 31 characters is compile error
  **70**; a concatenation longer than 31 characters keeps the first 31.
* Variables need no declaration; a variable never assigned is 0 / "" (see section 9 for when
  variables are fresh).

## 3. Literals

| Form | Value |
|---|---|
| `0` .. `32767` | integer |
| `32768` .. `65535` | a positive float (literal rule L-C); still usable wherever an address is expected (`POKE 65000,1`, `PEEK`, `USR`) |
| larger integers, decimals (`3.14159`, `0.000001`, `12345.5`) | exact 5-byte float (decimal-to-binary rounding of the 32-bit mantissa) |
| beyond about 1.7E38 | compile error 64 |
| `"text"` | a string, at most 31 characters |

There is no exponent notation and no hexadecimal literal. A minus sign is an operator.

## 4. Expressions

Precedence, highest first: function calls and parentheses; unary `-`; `*` `/`; `+` `-`; relations
`=` `<>` `<` `>` `<=` `>=`; `NOT`; `AND`; `OR`.

* `/` is exact division (an inexact integer quotient becomes a float); `DIV(a,b)` and `MOD(a,b)`
  are integer division and remainder (floats are truncated first); division by zero is runtime
  error 5.
* Relations give 1 (true) or 0 (false). Strings compare with all six relations, character by
  character (a prefix sorts first).
* `AND` / `OR` short-circuit (the right operand is not evaluated when the left decides) and give
  0/1; `NOT` gives 0/1. Any nonzero number (integer or float) is true.
* `+` concatenates strings.
* `PRINT` shows an integer as is and a float with four decimals, rounded (`0.1 + 0.2` prints
  `0.3000`, `PRINT 65535` prints `65535.0000`).

## 5. Statements

| Statement | Notes |
|---|---|
| `var = expr`, `var$ = expr$`, `a(i) = expr`, `a$(i) = expr$` | assignment (no `LET`) |
| `PRINT items`, `LPRINT items` | items separated by `;` (no space) or `,` (next 16-column zone); a trailing `;` keeps the cursor. Position and colour are separate statements (below), not `PRINT` items |
| `AT row,col`, `TAB col` | move the `PRINT` position (out-of-range values are clamped) |
| `INPUT var` / `INPUT var$` | numeric input accepts integers and decimals (up to 20 characters); string input up to 31 |
| `IF cond THEN` ... [`ELSE` ...] `ENDIF` | always a block (each part on its own lines); single-line form: `IF cond THEN GOTO label` only. There is no `ELSEIF`: use `ELSE` + a nested `IF ... ENDIF` |
| `FOR v = a TO b [STEP s]` ... `NEXT [v]` | integer or float loop (any of a, b, s a float makes it a float loop); the limit and step are evaluated once; a loop whose start is already past the limit runs zero times; after a normal exit `v` is the first value past the limit; `STEP 0` never advances (counts as ascending: `BREAK` or `EXIT FOR` ends it); `NEXT` may omit the variable; `EXIT FOR` leaves the innermost loop; a `NEXT` without its `FOR` is a compile error |
| `GOTO label` | jumping out of loops is allowed; jumping into one is an error |
| `PROC name(p):` ... `ENDP` | a procedure with one by-value parameter `p` (restored on return); recursion works |
| `CALL name(expr)` | call a procedure |
| `DEF FN f(x) = expr` / `FN f(expr)` | one-parameter user function |
| `DIM a(n)`, `DIM a$(n)`, `DIM a$(n,w)` | arrays of `n` elements, indices 0 .. n-1; `n` a literal (1 .. 16383); numeric elements are 16-bit integers (storing a float or a value outside -32768..32767 is runtime error 11); string elements are `w` bytes (`w`-1 characters; default `w` = 16, i.e. 15 characters; `DIM a$(n,32)` holds 31); a name is DIM'd once per run; out-of-range index: runtime error 10 |
| `CLEAR` | ordinary variables and arrays back to zero / empty; ends enclosing loops (a later `NEXT` is runtime error 7); the program, packages and the Array Store stay |
| `END`, `STOP` | stop the program (variables stay, section 9) |
| `CLS` | clear the screen |
| `BORDER n`, `INK n`, `PAPER n`, `FLASH n`, `BRIGHT n`, `OVER n`, `INVERSE n` | screen attributes for what is printed next |
| `PLOT x,y`, `LINE x0,y0 TO x1,y1` | 256x192 pixels; coordinates outside the screen are clamped to the edge |
| `BEEP duration,pitch`, `SOUND register,value` | sound (AY registers 0..15) |
| `POKE address,value`, `OUT port,value` | memory and port writes (addresses 0 .. 65535) |
| `PAUSE n` | wait `n` frames (`BREAK` interrupts) |
| `RANDOMISE [n]` | seed `RND` |
| `REM text` | comment |

## 6. Built-in functions

| Function | Result |
|---|---|
| `ABS(n)`, `SGN(n)`, `INT(n)` | absolute value, sign (-1/0/1), the integer part -- **truncated toward zero** (`INT(-3.5)` = -3; stock Sinclair BASIC floors to -4: a documented V2 difference, R10.8 L6) |
| `MOD(a,b)`, `DIV(a,b)` | truncated integer remainder / quotient (`MOD(-7,3)` = -1, `DIV(-7,2)` = -3; error 5 for b = 0) |
| `SQR(n)` | square root (error 15 for n < 0) |
| `SIN(d)`, `COS(d)`, `TAN(d)` | trigonometry in **degrees** (fractional degrees allowed); `TAN(90)` is error 5 |
| `PI()`, `RAD(d)`, `DEG(r)` | pi; degrees to radians; radians to degrees |
| `RND(n)` | a random integer 0 .. n-1 (0 when n < 1) |
| `LEN(s$)`, `CODE(s$)`, `VAL(s$)` | length; code of the first character; the leading number in the text (spaces and a sign skipped; stops at the first character that cannot continue the number) |
| `CHR$(n)` | a 1-character string (error 15 outside 0..255) |
| `STR$(n)` | the number as `PRINT` shows it |
| `UPPER$(s$)`, `LOWER$(s$)` | case conversion |
| `LEFT$(s$,n)`, `RIGHT$(s$,n)`, `MID$(s$,start,n)` | substrings (1-based start, a start below 1 counts as 1; out-of-range counts are clamped) |
| `INKEY$()` | the key being pressed, or "" |
| `PEEK(a)`, `USR(a)` | byte at an address; call machine code at an address (result: BC as 0..65535) |
| `IN(port)`, `STICK(n)` | port read; joystick 1 or 2 (other n: error 15) |
| `POINT(x,y)`, `ATTR(row,col)` | pixel (0/1, clamped coordinates); attribute byte |
| `FREE()`, `FREE(1)` | free bytes of the main pool / of segment 2 |
| `DIMN(a)`, `DIMN(a$)` | an array's declared size |

## 7. Commands (typed in the editor, not in programs)

| Command | Effect |
|---|---|
| `RUN` | compile and run the program with fresh variables |
| `: statements` | run immediately, in the current variable session (section 9) |
| `LIST` | list the program |
| `NEW` | clear the program, variables, packages and the Array Store |
| `SAVE "name"` / `LOAD "name"` / `VERIFY "name"` | program tapes (a name of up to 10 characters; `LOAD ""` takes the next program) |
| `SAVE "name" ALL` | program + variable session + Array Store in one tape block (`V2_SAVE_ALL_FORMAT.md`) |
| `SAVE "name" ARRAY a` / `LOAD "name" ARRAY a` | one array to / from tape; `LOAD ... ARRAY` puts it in the Array Store, where it survives `RUN`, `CLEAR` and edits, and a matching `DIM` adopts it |
| `SAVE "name" EXT` / `LOAD "name" EXT` | a loadable package (`PACKAGE_ABI.md`); its keywords become part of the language until `NEW` |

## 8. Errors

Compile errors stop before anything runs; runtime errors stop the program (`ERROR`-class message
on the status line). Codes the user meets most often:

| Code | Kind | Meaning |
|---|---|---|
| 1, 39 | compile | more than 251 numeric / 251 string / 255 array names ("TOO MANY VARIABLES") |
| 2, 3, 9..48 | compile | syntax: expected token missing (full list in `rom/exrom_v2_compiler.asm`, header) |
| 5, 6, 45, 55, 62 | compile | out of compile memory ("OUT OF MEMORY") |
| 7 | compile | `GOTO` an undefined label |
| 56, 63, 65 | compile | `NEXT` for another variable; `EXIT FOR` outside a loop; `FOR` without `NEXT` |
| 57 | compile | duplicate label |
| 60 / 61 | compile | nesting too deep / name too long |
| 64 | compile | unexpected token (also: a literal beyond the float range) |
| 70 | compile | string literal longer than 31 characters |
| 71 | compile | an immediate statement defined a label, `PROC` or `DEF FN` |
| 2, 6 | runtime | expression or call stack overflow ("STACK OVERFLOW") |
| 5 | runtime | division by zero (also `TAN(90)`) |
| 7 | runtime | `NEXT` / `RET` without a frame (e.g. after `CLEAR` inside a loop) |
| 10 | runtime | array index out of range |
| 15 | runtime | argument out of range (`CHR$`, `STICK`, `SQR` of a negative number) |
| 64 | runtime | out of array memory ("OUT OF MEMORY") |
| 65 | runtime | `DIM` size or width differs from the stored array of that name ("ARRAY SIZE MISMATCH") |
| 66 | runtime | `BREAK` (CAPS SHIFT + SPACE) |
| 67 | runtime | number too big (a float result beyond about 1.7E38) |

## 9. Variable sessions

`RUN` starts with fresh variables. When the program stops -- at its end, `END`, `STOP`, `BREAK`
or an error -- its variables stay: immediate statements (`: PRINT x`, `: x = 7`, `: GOTO label`)
use them and may add new ones; `CLEAR` resets them; any edit, `NEW` or `LOAD` ends the session.
Full rules: `V2_SESSION_VARIABLES.md`.

## 10. Memory and capacity

* The main pool (program text, symbol table, arrays, variables) is about 8.4 KB; arrays that do
  not fit go to segment 2 (2 KB at `$E000`), which also holds the Array Store. `FREE()`/`FREE(1)`
  report what is left.
* 251 numeric and 251 string variables; 255 numeric and 255 string arrays; up to ~4 KB of compiled
  bytecode; recursion depth is limited by the call stack (150 levels with one parameter pass the
  production checks).
* A string array element costs its width; a numeric element 2 bytes.

## 11. Packages

A package tape adds keywords (graphics shapes, sprites, printer, screen modes, ...): `LOAD "name"
EXT`. One package at a time; `NEW` removes it. Package authors: `PACKAGE_ABI.md`.

## 12. Not in V2 (deliberately)

Line numbers, `GOSUB`/`RETURN` (use `PROC`/`CALL`), `LET`, single-line `IF ... THEN stmt` (other
than `THEN GOTO`), `ELSEIF`, `INSTR`, string slicing `a$(i TO j)` (use `MID$`), `READ`/`DATA`,
multi-dimensional arrays, `DIM` with a variable size, float array elements, `PRINT AT`/colour
items inside `PRINT` (use the statements), exponent and hex literals, `CONTINUE` (an immediate
`: GOTO label` restarts at a label instead). The characters `[ \ ] ^ \` { | } ~` print as
blanks (the font has no glyphs for them -- open defect Q-26).

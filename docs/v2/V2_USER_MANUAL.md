# 2068-Leap V2 -- User's Manual (release candidate)

For the Timex Sinclair 2068 with the 2068-Leap V2 HOME ROM and EXROM. This manual describes the
release candidate (`integration/v2-final-rom`). The complete, precise rules are in
`V2_LANGUAGE_REFERENCE.md`; this manual shows how to use them. (`docs/user_manual.md` is the
manual of the earlier V1 "Release 1 Beta" ROM: much of it does not apply to V2.)

## 1. Getting started

Switch on: the screen shows the editor -- an empty program and a status bar on the bottom row
(`LINE n/m` and the colour swatch). Type a line and press ENTER:

```
PRINT "HELLO"
```

The line is stored as part of the program. On the empty line after the last one, type `RUN` and
press ENTER: the program is compiled and runs. Press any key to return to the editor.

Commands (`RUN`, `LIST`, `NEW`, `SAVE`, `LOAD`, `VERIFY`, and `:` statements) are typed on the
**empty line at the end of the program**; typed on any other line they would replace that line.

## 2. The editor

| Key | Action |
|---|---|
| letters, digits, symbols | insert at the cursor |
| ENTER | store the line (or run the command typed on the last line) |
| CAPS SHIFT + 5 / 8 | cursor left / right |
| CAPS SHIFT + 7 / 6 | previous / next line |
| CAPS SHIFT + 0 (DELETE) | delete the character before the cursor; on an empty line, delete the line |
| CAPS SHIFT + 1 | delete the whole line |
| CAPS SHIFT + ENTER | insert a blank line |
| CAPS SHIFT + SPACE (BREAK) | stop a running program (ignored while editing) |

A line holds up to 127 characters and wraps over several screen rows. Keywords are shown in bold
on stored lines. When a program fails to compile, the error appears on the status line and the
cursor goes to the line where it was found.

Any change to the program (storing or deleting a line) ends the current variable session
(section 9).

## 3. Programs

There are no line numbers. A program is a list of lines; a line holds statements separated by
`:`. Jumps go to **labels** -- a line consisting of a name and a colon:

```
n = 0
again:
n = n + 1
PRINT n
IF n < 3 THEN GOTO again
```

`REM` starts a comment. `END` (or the last line) ends the program; `STOP` stops it too.

`RUN` compiles the whole program before running any of it, so a mistake anywhere is reported
before anything happens.

## 4. Numbers, strings and variables

* Names are letters and digits, starting with a letter, up to 31 characters, upper or lower case
  alike: `score`, `x2`, `TotalSum`. A string variable ends in `$`: `name$`.
* Variables need no declaration; an unset variable is 0 or "".
* Whole numbers from -32768 to 32767 are exact integers. Anything else -- fractions, larger
  numbers, results that overflow -- is a floating-point value with about 9 significant digits, up
  to about 1.7E38. `PRINT` shows integers plainly and other numbers with four decimals:

| You type | It prints |
|---|---|
| `PRINT 7 / 2` | `3.5000` |
| `PRINT 30000 * 3` | `90000.0000` |
| `PRINT 0.1 + 0.2` | `0.3000` |
| `PRINT 65535` | `65535.0000` |
| `PRINT 6 / 2` | `3` |

  A result beyond 1.7E38 stops the program with error 67 (number too big).
* Strings hold up to 31 characters. A string constant longer than that is a compile error; joining
  strings beyond 31 keeps the first 31.
* `INT` drops the fraction toward zero: `INT(-3.5)` is -3 (Sinclair BASIC gives -4). `DIV` and `MOD`
  likewise truncate.

## 5. Making decisions and loops

```
IF score > 100 THEN
  PRINT "WELL DONE"
ELSE
  IF score > 50 THEN
    PRINT "GOOD"
  ENDIF
ENDIF
```

`IF` is always a block ending in `ENDIF`; the only one-line form is `IF condition THEN GOTO label`.
Conditions use `= <> < > <= >=` (numbers or strings), `AND`, `OR`, `NOT`. `AND` and `OR` stop as
soon as the answer is known, so `IF y <> 0 AND x / y > 1 THEN` is safe when `y` is 0.

```
FOR i = 1 TO 10 STEP 2
  PRINT i
NEXT i
```

The loop variable, limit and step may be fractions (`FOR x = 0 TO 1 STEP 0.1`). A loop whose
start is already past its limit does not run at all. `NEXT` may omit the name. `EXIT FOR` leaves
the innermost loop. `STEP 0` never advances (stop it with `EXIT FOR` or BREAK).

## 6. Procedures and functions

```
CALL greet(3)
END
PROC greet(n):
  PRINT "HELLO "; n
ENDP
```

A procedure takes one value; it can call itself. One-line functions:

```
DEF FN sq(x) = x * x
PRINT FN sq(7)
```

## 7. Arrays

```
DIM scores(10)
DIM names$(5)
DIM longer$(5, 32)
scores(3) = 42
names$(0) = "ADA"
PRINT DIMN(scores)
```

`scores` has elements `scores(0)` to `scores(9)`, whole numbers; `names$` five strings of up to 15
characters; `longer$` five strings of up to 31. `DIMN(scores)` prints 10.

Sizes are constants. Numeric arrays hold whole numbers from -32768 to 32767 (a fraction is error
11). An index outside the array is error 10.

**Persistent arrays.** `LOAD "file" ARRAY name` loads an array from tape into the **Array Store**,
where it survives `RUN`, `CLEAR` and editing; a `DIM` of the same name and size in the program uses
it. `SAVE "file" ARRAY name` writes one array to tape. `NEW` empties the store.

## 8. Screen, graphics, sound and the machine

```
CLS
INK 2 : PAPER 6 : BORDER 1
AT 10, 5 : PRINT "HERE"
TAB 20 : PRINT "THERE"
PLOT 128, 96 : LINE 0, 0 TO 255, 191
PRINT POINT(128, 96), ATTR(10, 5)
BEEP 1, 12
SOUND 7, 62
```

`AT`, `TAB` and the colours (`INK PAPER FLASH BRIGHT OVER INVERSE`) are statements of their own,
used before `PRINT`. In `PRINT`, `;` joins items and `,` moves to the next 16-column zone; a
trailing `;` keeps the cursor on the line. `LPRINT` prints to the printer. Coordinates off the
screen are clamped to its edge.

`INPUT x` / `INPUT a$` read the keyboard (numbers may have fractions); `INKEY$()` returns the key
held now, or ""; `STICK(1)` / `STICK(2)` read the joysticks. `PEEK`, `POKE`, `IN`, `OUT` and
`USR(address)` reach memory, ports and machine code; addresses go up to 65535. `PAUSE n` waits `n`
frames; `RANDOMISE` and `RND(n)` give random numbers from 0 to n-1.

`FREE()` tells how much memory is left for the program and its data, `FREE(1)` how much is left in
the overflow area.

## 9. Variables after a program stops -- immediate statements

When a program stops -- at its end, at `STOP`, by BREAK or by an error -- its variables are kept.
On the empty last line, a statement typed after a colon runs at once, with those variables:

```
: PRINT score
: score = 0
: PRINT names$(0) + "!"
: GOTO again
```

An immediate statement may create new variables (they start at 0 or "") and call the program's
procedures; it cannot define labels, procedures or functions. `: GOTO label` starts the program at
that label with the current values (it does not resume a stopped `FOR` or procedure).

* `RUN` always starts again with fresh variables.
* `: CLEAR` (or `CLEAR` in the program) resets the variables; the program stays.
* Changing the program, `NEW` or `LOAD` ends the session; the next immediate statement starts
  with fresh variables.

## 10. Tapes

| Command | What it saves or loads |
|---|---|
| `SAVE "name"` | the program |
| `SAVE "name" ALL` | the program, its current variables and the Array Store |
| `LOAD "name"` / `LOAD ""` | a program (with its variables, if it was saved with `ALL`) |
| `VERIFY "name"` | checks a tape against what is in memory |
| `SAVE "name" ARRAY a` / `LOAD "name" ARRAY a` | one array |
| `SAVE "name" EXT` / `LOAD "name" EXT` | a package (section 11) |

Names have up to 10 characters. `SAVE ... ALL` lets you stop work and carry on later: after the
`LOAD`, `: PRINT`, `: GOTO` and the rest work with the saved values. The variables come back only
on the same ROM version (on another, the program loads and the message says `NO VARIABLES`); a
damaged tape gives `LOAD FAILED`. If a very large program plus its overflow arrays cannot be laid
out for saving, `SAVE ... ALL` says `OUT OF MEMORY` -- `SAVE "name"` still works. A tape written by
this version cannot be loaded by earlier V2 ROMs.

## 11. Packages

Extra statements come on package tapes: `LOAD "shapes" EXT` adds `CIRCLE`, `FILL` and more;
others add sprites, a printer, screen modes. One package is loaded at a time; `NEW` removes it.

## 12. Messages

| Message | Meaning |
|---|---|
| `SYNTAX ERROR`, `UNEXPECTED TOKEN` | the line is not valid (also: a number constant too big) |
| `NAME TOO LONG`, `NESTING TOO DEEP`, `TOO MANY VARIABLES`, `OUT OF MEMORY` | a limit was reached |
| `RUNTIME ERROR` | e.g. division by zero (5), index out of range (10), number too big (67) |
| `STACK OVERFLOW` | expressions or calls nested too deeply |
| `ARRAY SIZE MISMATCH` | a `DIM` differs from the stored array of that name |
| `BREAK` | the program was stopped with CAPS SHIFT + SPACE |
| `SAVED`, `LOADED`, `VERIFIED`, `NO VARIABLES`, `LOAD FAILED`, `VERIFY FAILED`, `ABORTED`, `BAD TAPE VERSION` | tape results |

The error codes are listed in `V2_LANGUAGE_REFERENCE.md` section 8.

## 13. Limits and differences from Sinclair BASIC

* Memory for program and data: about 8.4 KB, plus 2 KB for overflow arrays and the Array Store.
* 251 numeric and 251 string variables; arrays up to 16383 elements.
* No line numbers, `GOSUB`, `LET`, `ELSEIF`, `INSTR`, `READ`/`DATA`, string slicing (`MID$` does
  it), multi-dimensional arrays, exponent notation; `INT` truncates.
* The characters `[ \ ] ^ \` { | } ~` print as blanks.

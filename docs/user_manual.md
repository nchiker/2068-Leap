# 2068-Leap — User's Manual

**Release 1 Beta**

2068-Leap is a redesigned Timex Sinclair 2068 ROM: a structured BASIC
(no line numbers — labels and `GOTO` instead),
a full-screen editor, AY-3-8912 sound, and TS2068-specific graphics, built
from scratch as documented Z80 modules rather than a copy of the original
ROM.

This manual is both a tutorial and a reference for the implemented Release 1
Beta. Examples are written for the ROM you can download and run today.

### Project goals

2068-Leap explores an alternate path for the TS2068: keep the immediacy and
approachability of an 8-bit machine, but give it an editor and BASIC designed
as a coherent system. The project aims to:

- remain instant-on and fit a stock 48K TS2068 with its original 16K Home ROM
  and 8K EXROM architecture;
- make writing and revising programs comfortable without line numbers;
- expose the TS2068's graphics, AY sound, memory, and expansion capabilities
  directly from BASIC;
- favor clear, structured programs while preserving useful classic BASIC
  idioms; and
- keep optional features expandable through a documented loadable-module
  system instead of permanently filling the ROM with every possible command.

### What this ROM improves

This is a new operating environment for the TS2068, not a stock ROM with a
handful of added keywords. The redesign connects the editor, language,
hardware services, storage, and extension system:

- A persistent full-screen, word-wrapping editor replaces line-number entry.
- Labels, block `IF`, `FOR`/`NEXT`, `GOSUB`/`RETURN`, and colon-separated
  statements provide structured control flow.
- Errors are checked after each committed edit and again before `RUN`; bad
  lines are highlighted in place and have next/previous-error navigation.
- Numeric and string arrays, scalar strings, string functions, user-defined
  functions, pixel graphics, sprites, collision detection, AY sound, High
  Resolution Graphics color, and
  ULAplus palettes are accessible directly from BASIC.
- `SAVE` and `LOAD` retain standard TS2068 two-block tape framing while
  carrying this ROM's native program, with progress shown in the status bar.
- Loadable BASIC extensions let a program add an optional keyword without
  consuming more permanent ROM space.

ULAplus is program-scoped: every exit path restores the normal palette before
the editor reappears.

## New in Release 1 Beta since Public Preview 1

Release 1 Beta is substantially larger in capability than Public Preview 1.
The most visible changes are:

- **15,322 bytes of dynamic BASIC memory**, increased from 1,857 bytes in the
  preview through ROM/RAM audits and relocation of fixed work areas.
- **Loadable BASIC extensions** with tape `SAVE "name" EXT` and
  `LOAD "name" EXT`; six modules ship with the beta: CPLOT, BLOCK, FRAME,
  INVERT, AYREG, and OUT.
- **Classic `DEF FN`**, allowing a program to define and call a compact numeric
  function.
- **Program autorun**, using `SAVE "name" LINE n` to begin at a selected
  statement after loading.
- **Prompted input**, including `INPUT "Name: ";A$` and numeric prompts.
- **Expanded string and array support**, including string arrays, `INSTR`,
  nested string functions, and dynamic allocation.
- **A larger graphics and hardware toolkit**, including FRAME, INVERT, native
  AY-register access, and full-address Z80 port output as loadable commands.
- **Editor and runtime hardening**, including load-position fixes, stable
  word-wrap rendering, clean RUN state, stronger calculator checks, and a much
  larger automated regression suite.

See the separate **What's New in Release 1 Beta** document for a detailed
preview-to-beta feature tour.

## Contents

- [New in Release 1 Beta since Public Preview 1](#new-in-release-1-beta-since-public-preview-1)
1. [Getting started](#1-getting-started)
2. [The editor](#2-the-editor)
3. [Loading and saving with Fuse](#3-loading-and-saving-with-fuse)
4. [Program structure — labels instead of line numbers](#4-program-structure--labels-instead-of-line-numbers)
5. [Control flow](#5-control-flow)
6. [Variables and data](#6-variables-and-data)
7. [Expressions and operators](#7-expressions-and-operators)
8. [Screen output](#8-screen-output)
9. [Graphics](#9-graphics)
10. [Sprites](#10-sprites)
11. [Sound](#11-sound)
12. [Input](#12-input)
13. [Memory and machine code](#13-memory-and-machine-code)
14. [Loadable BASIC extensions](#14-loadable-basic-extensions)
15. [Immediate commands](#15-immediate-commands)
16. [Function reference](#16-function-reference)
17. [Statement reference](#17-statement-reference)
18. [Error messages](#18-error-messages)
19. [Keyboard reference](#19-keyboard-reference)
20. [Known limitations](#20-known-limitations)

---

## 1. Getting started

Boot the ROM (Home ROM + EXROM) in a supported emulator and
you're dropped straight into the full-screen editor with an empty
program — there's no separate "BASIC prompt" to get to first. Whatever
you type becomes the next line of your program the moment you press
ENTER.

The same cold-start path is designed for a stock 48K TS2068, but this beta's
public validation baseline is emulator-based; real-hardware boot and cassette
reports are especially welcome.

Type a line and press ENTER:

```
PRINT "HELLO"
```

Then type `RUN` alone on its own line and press ENTER to execute the
whole stored program. `RUN` is not a program statement — like `NEW`,
`LIST`, `EDIT`, `SAVE`, and `LOAD`, it's an **immediate command**:
typed alone and committed, it executes right away instead of being added
to the program (see [Immediate commands](#15-immediate-commands)).

A blank ENTER (nothing typed) does nothing — it's not an error, it's a
no-op.

Here is a small first program using several improvements together:

```basic
INK 6
DIM S(5)
FOR I = 0 TO DIMN(S)-1
S(I) = I*I
NEXT I
PRINT "LAST SQUARE=" + STR$(S(4))
IF S(4) = 16 THEN BORDER 4
```

Type `RUN` on the next blank editor line. It prints `LAST SQUARE=16` and
turns the border green.

## 2. The editor

There's one full-screen editor, always — no separate "listing" view or
"direct mode" prompt. The screen shows up to 23 rows of your program at
once (row 23 at the bottom is reserved for a status line), with the line
you're currently editing shown in plain text and every other, already
committed line shown with recognized keywords in **bold**.

### Typing

- Letters type as **lowercase by default**. Hold **CAPS SHIFT** for
  uppercase — this is a deliberate design choice for this ROM, not a
  fact about the hardware.
- Recognized keywords (`PRINT`, `INPUT`, `RUN`, `END`, `STOP`, `GOTO`,
  and every other statement/command keyword) auto-uppercase and render
  bold once a line is **committed** (ENTER), not while you're still
  typing it — a line still being typed always shows plain. A word that
  merely starts with a keyword but isn't one — `PRINTER` — is not
  mistaken for `PRINT`; a real word boundary (space, `=`, or end of
  line) is required after the match.
- ENTER commits the current line: if you're on the blank line at the
  end, it's appended as a new statement and a fresh blank line opens
  below it; if you've navigated up into an **existing** line, ENTER
  replaces that statement in place and moves down to the next line —
  exactly like a normal text editor.
- A blank ENTER (nothing typed on the line) is a no-op, whether you're
  on the new line or an existing one — it doesn't append an empty
  statement, and it doesn't replace an existing line with nothing.

### Navigation

| Key | Action |
|---|---|
| CAPS SHIFT + 7 | Move up a line |
| CAPS SHIFT + 6 | Move down a line |
| CAPS SHIFT + 5 | Move cursor left |
| CAPS SHIFT + 8 | Move cursor right |
| CAPS SHIFT + 0 | Delete character (forward delete) |

Fuse conveniently maps your PC's actual arrow keys and Backspace key
directly to these combos, so in practice you don't need to hold Shift
and press a number — the arrow keys and Backspace just work.

Moving to an existing line loads its committed text back into the edit
buffer so you can change it. **Any uncommitted change is discarded if
you navigate away without pressing ENTER first** — there's no undo, so
type carefully; this is deliberate, not a bug.

The view scrolls automatically once your program exceeds the 23 visible
rows, keeping wherever you're editing on screen. A line long enough to
need more than one screen row word-wraps rather than running off the
edge.

### Deleting lines

- **DELETE on an already-empty existing line** removes that line outright
  and shifts everything after it up to fill the gap. (On a line that
  still has text, CAPS SHIFT+0 just deletes forward character by
  character, same as any text editor — DELETE only removes the whole
  *line* once it's already empty.)
- **CAPS SHIFT + 1** deletes the current line outright in one keystroke,
  no need to empty it first — same underlying "delete and shift up"
  behavior, just reachable directly regardless of what's currently in
  the line.
- **CAPS SHIFT + ENTER** inserts a blank line *before* the one currently
  being edited, then moves you onto that new blank line to start typing.
  No effect on the not-yet-committed new line at the end of the program
  — there's nothing meaningful to insert before there.
- **`DELETE <start>,<end>`**, typed and committed like `RUN`, removes a
  whole range of lines by their position in the current listing (1-based
  — the first line shown is line 1, matching how you'd read a listing
  top to bottom; there are still no line numbers stored anywhere, this
  is purely how you type the range). Any problem — malformed numbers, a
  missing comma, a typed `0`, `start` greater than `end`, either number
  out of range — leaves the program unchanged; a bad `DELETE` shows
  `INVALID RANGE` in the status bar for one redraw, then the offending
  text auto-removes itself the next time you navigate away.

### Errors while typing and running

Before `RUN` actually executes anything, a whole-program check pass looks
at every statement. If it finds problems, execution never starts — you're
dropped back into the editor with the status bar reading `N ERRORS FOUND`
(or `1 ERROR FOUND`) instead of the usual `LINE n/m`, and every flagged
line renders in **red** ink (keywords inside them stay bold, just
bold-red instead of bold-black). This message is deliberately not a
full-screen takeover — the whole program stays visible while you fix it.

| Key | Action |
|---|---|
| SYMBOL SHIFT + A | Jump to the next flagged (error) line |
| SYMBOL SHIFT + S | Jump to the previous flagged line |

Both wrap around at either end, and work from anywhere in the program.
While your cursor is on a specific flagged line, the status bar shows
*that* line's own error message instead of the overall count; moving to
an unflagged line reverts to the general count.

A **runtime** error (one the static check pass can't catch — e.g.
`DIVISION BY ZERO`, which depends on a variable's actual value) stops the
program the moment it happens and shows the error message plus the
failing statement's own text, rather than silently doing nothing.

### Editor key reference

Keep this quick reference near the machine while editing:

```
LEFT       CAPS SHIFT+5
RIGHT      CAPS SHIFT+8
UP         CAPS SHIFT+7
DOWN       CAPS SHIFT+6
DELETE CHR CAPS SHIFT+0
INSERT LN  CAPS SHIFT+ENTER
DELETE LN  CAPS SHIFT+1

NEXT ERROR SYM SHIFT+A
PREV ERROR SYM SHIFT+S

```

## 3. Loading and saving with Fuse

`SAVE "<name>"` and `LOAD "<name>"` transfer the current program to and
from tape, using the same EAR/MIC cassette ports every Spectrum-family
machine uses for tape I/O — so in Fuse, this means the same **tape
deck** you'd use for any Spectrum program (Fuse's own Media/Tape menu:
open or record a tape file, then `SAVE`/`LOAD` from BASIC drives it, the
same relationship as a real cassette recorder).

The tape uses the stock TS2068/Sinclair 17-byte program header and
two-block transport framing. The saved program data is still this ROM's
own plain-text representation, not stock tokenized Sinclair BASIC. Stock
tools can recognize the container and header, but a stock ROM cannot run
the payload. See `docs/tape_compatibility.md` for the exact contract.

- **`SAVE "name"`** — saves the whole current program under that name
  (up to 10 characters).
- **`SAVE "name" LINE n`** — saves the program with a one-based autorun
  statement index. Loading it starts at statement `n`; an out-of-range value
  leaves the program loaded without running it.
- **`LOAD "name"`** — loads a program by name; the name on tape must
  match exactly, or `LOAD` fails.
- **`LOAD ""`** (empty name) — a wildcard: loads whatever program is
  found next on the tape, regardless of its name. Useful when you know
  there's only one program on the tape and don't want to retype its
  exact name.

While a `SAVE`/`LOAD` is in progress, the status line reports timing-safe
milestones: 0%, 10% after the header, and 100% after the program block.
On success it shows `SAVED 100%` or `LOADED 100%`. An unreadable or empty
tape reports `LOAD FAILED`.

The wildcard applies only to programs; extension modules require an explicit
name, so `LOAD "" EXT` is rejected. Both named `LOAD "name"` and wildcard `LOAD ""` have been confirmed in
real Fuse round-trips.
Fuse does not automatically start this custom ROM's loader, so open the
tape and press Play manually after entering `LOAD`.

There's no `MERGE` — `LOAD` always replaces the current program outright,
it never combines with what's already there. Save first if you want to
keep the current program before loading another.

## 4. Program structure — labels instead of line numbers

There are **no line numbers** in this BASIC. What classic line-numbered
BASIC did with `GOTO 100` this dialect does with named **labels**:

```
main_loop:
    PRINT "hello"
    x = x + 1
    IF x < 5 THEN GOTO main_loop
PRINT "done"
```

A label is an identifier alone on its own line, ending with a colon. It
can't share a line with anything else — `loop: PRINT 1` is a syntax
error, not a label followed by a statement.

**Label names: letters only** — no digits, no underscores. `sub1:` and
`main_loop:` both fail (the parser stops at the first non-letter, and
what's left over doesn't make sense as either a label or a `GOTO`
target). Stick to plain letter sequences (`mainloop:`, `done:`,
`checkscore:`) until this is loosened.

`GOTO <label>` jumps to that label. `GOSUB <label>` / bare `RETurn` push
a return address and come back; `CALL <label>` is a second spelling of
`GOSUB` — identical behavior, just a name some people find more natural
for a "stored procedure" you're not planning to jump back *past*. Either
way, `RETurn` (with no value — this dialect has no user-defined
functions to return a value *from*) comes back to whichever one called
it.

`LIST` jumps the editor view to the top of the program. `EDIT <label>`
jumps straight to that label's own line — handy for navigating a long
program without scrolling by hand.

## 5. Control flow

### IF

Block form:

```
IF x > 10 THEN
    PRINT "big"
ELSEIF x > 0 THEN
    PRINT "small"
ELSE
    PRINT "not positive"
END IF
```

(`ENDIF`, one word, also works — not a second spelling worth relying on
deliberately, just not rejected either.)

Single-line short form, no `END IF` needed:

```
IF x = 0 THEN PRINT "zero"
```

Multiple statements after `THEN`, colon-separated, all run:

```
IF x = 0 THEN PRINT "zero": y = 1
```

There's no `ELSE` in the single-line form — use the block form if you
need one.

Conditions: `=`, `<>`, `<`, `>`, `<=`, `>=`, plus `AND`/`OR`/`NOT`
(`NOT` binds tightest, then `AND`, then `OR`). A bare expression with no
relational operator is truthy/falsy the classic-BASIC way (nonzero is
true). **`AND`/`OR` do not short-circuit** — both sides always evaluate,
so `IF y <> 0 AND x/y > 1 THEN ...` still raises `DIVISION BY ZERO` when
`y` is 0, even though the guard looks like it should prevent that. This
is a known, permanent limitation, not a bug to report.

A genuinely mismatched `IF`/`END IF` (missing one or the other) isn't
caught until `RUN` — reported as `IF WITHOUT END IF`.

### FOR / NEXT

```
FOR i = 1 TO 10
    PRINT i
NEXT i
```

`STEP` defaults to 1:

```
FOR i = 10 TO 1 STEP -1
    PRINT i
NEXT
```

`NEXT`'s variable name is optional — bare `NEXT` acts on the innermost
open loop. If you do name it, it must match that loop's own variable, or
you get `NEXT VARIABLE MISMATCH`.

Classic entry semantics: if the very first check already fails (`FOR i =
5 TO 1` with the default `STEP 1`), the body never runs at all, not even
once. `STEP 0` is accepted and just never advances — an intentional
infinite loop if nothing else breaks out of it.

Loops nest up to 8 deep; a 9th concurrently open `FOR` reports `FOR
NESTED TOO DEEPLY`. `NEXT` with no open loop at all reports `NEXT
WITHOUT FOR`.

**`EXIT FOR`** breaks out of the innermost open loop early:

```
FOR i = 1 TO 100
    IF i > 5 THEN EXIT FOR
    PRINT i
NEXT i
```

Using it with no `FOR` loop open reports `EXIT WITHOUT FOR`. A genuinely
mismatched `FOR`/`NEXT` is only caught at `RUN` time, as `FOR WITHOUT
NEXT`.

### GOSUB / RETurn / CALL

```
GOSUB greet
GOTO after
greet:
    PRINT "hi"
    RETurn
after:
    PRINT "done"
```

Every `GOSUB` (or `CALL`) needs a matching `RETurn` to come back to.
Too many nested, un-returned `GOSUB`s reports `GOSUB TOO DEEP`; a stray
`RETurn` with nothing to return to reports `RETURN WITHOUT GOSUB`.

### STOP, END, PAUSE

- **`STOP`** halts the program and drops back to the editor, but
  *keeps* variable values and where you stopped, for inspection — a
  breakpoint, not a normal exit.
- **`END`** is the deliberate final stop — terminates the program
  cleanly.
- **`PAUSE <n>`** waits `n` display frames (roughly `n/50` seconds), or
  waits indefinitely for a keypress if `n` is `0`.

## 6. Variables and data

### Numeric variables

26 single-letter variables, `A` through `Z`, always available — no
declaration needed. Every number in this BASIC is a 16-bit signed
integer (-32768 to 32767); there's no float variable type (a small
number of *functions* — see [SQR/SIN/PI/RAD/DEG](#16-function-reference)
— can *display* a genuine fractional result when printed directly, but
that's a display feature of those specific functions, not a numeric
type change).

```
x = 5
y = x * 2 + 1
```

### User-defined functions with DEF FN

`DEF FN` is a major Release 1 Beta feature: it lets a program give a meaningful
name to a calculation and reuse it without duplicating the expression. One
classic single-argument numeric function can be active at a time:

```basic
DEF FN S(X)=X*X
PRINT FN S(12)
```

This prints `144`. The letter after `FN` is the function name; the letter in
parentheses is its local parameter. Both are single letters, but they do not
have to match:

```basic
DEF FN A(T)=T*T+2*T+1
FOR X=0 TO 4
PRINT FN A(X)
NEXT X
```

The parameter temporarily receives the call's argument while the expression is
evaluated. A function may use arithmetic, parentheses, numeric variables, and
built-in numeric functions:

```basic
M=10
DEF FN C(R)=2*R+M
PRINT FN C(5)
```

A definition takes effect when execution reaches its `DEF FN` statement. This
makes it possible to replace the active definition later in a program:

```basic
DEF FN F(X)=X*X
PRINT FN F(4)
DEF FN F(X)=X*3
PRINT FN F(4)
```

The two results are `16` and `12`. Calls made before a definition has executed
are rejected, and recursive `FN` calls are rejected. `DEF FN` returns a numeric
value; it does not define string functions or multi-argument functions.

### String variables

26 more, `A$` through `Z$` — a completely separate set of storage slots
from the numeric `A`-`Z`, sharing only the letter. Each holds up to
**31 characters**; anything longer is silently truncated, not rejected.

```
A$ = "hello"
B$ = A$ + " world"
PRINT B$
```

Assignment, `PRINT`, and `=`/`<>` comparison (`IF A$ = "Q" THEN ...`) are
supported. `<`, `<=`, `>`, `>=` are **not** supported for strings.

### Arrays

```
DIM scores(10)
scores(0) = 100
PRINT scores(0) + 1
```

`DIM name(n)` declares a **numeric** array of `n` zero-initialized
elements. `DIM name$(n)` declares up to 31 string elements, each able
to hold 31 characters. Both are indexed **0 to n-1** (0-based, not
classic BASIC's 1-based). `name(i)` or `name$(i)` reads or writes one
element, and numeric references can nest (`A(B(0)) = 99`).

```basic
DIM color$(3)
color$(0) = "RED"
color$(1) = UPPER$("blue")
PRINT color$(1)
```

A name can only be `DIM`'d once per `RUN` — re-`DIM`ing it without a
fresh `RUN` raises `ARRAY ALREADY DIMENSIONED`. Using an array before
`DIM`ing it raises `ARRAY NOT DIMENSIONED`; an out-of-range index raises
`SUBSCRIPT OUT OF RANGE`. A bad `DIM` size raises `INVALID ARRAY SIZE`,
and running out of room while allocating it raises `OUT OF MEMORY`.

`DIMN(name)` returns a numeric array's declared size; use `DIMN(name$)`
for a string array.

Arrays live in a genuinely dynamic memory region (not a fixed slot
table like the scalars above), so their capacity is limited only by
free RAM, reflected in `FREE()`.

There is no multi-dimensional (`DIM name(rows,cols)`) support.

## 7. Expressions and operators

Expressions calculate values for assignment, `PRINT`, `IF`, loop bounds,
graphics coordinates, sound parameters, and function calls. Ordinary numeric
expressions use signed 16-bit integers.

### Arithmetic and precedence

Operators are evaluated from highest to lowest precedence:

| Precedence | Operators | Meaning |
|---:|---|---|
| 1 | parentheses, function calls | Explicit grouping and returned values |
| 2 | unary `-`, `NOT` | Numeric negation and logical inversion |
| 3 | `*`, `/`, `MOD`, `DIV` | Multiplication, division, remainder, integer quotient |
| 4 | `+`, `-` | Addition, subtraction, or string concatenation for `+` |
| 5 | `=`, `<>`, `<`, `>`, `<=`, `>=` | Comparisons |
| 6 | `AND` | Logical conjunction |
| 7 | `OR` | Logical alternative |

Parentheses are the clearest way to document intent:

```basic
X = 3 + 4 * 2
Y = (X + 1) * 2
```

The results are `11` and `24`. `X=X+1` reads the old value before storing the
new one.

`/` and `DIV` produce an integer result and truncate toward zero. `MOD` returns
the remainder with the dividend's sign:

```basic
PRINT 17 DIV 5
PRINT 17 MOD 5
PRINT -17 MOD 5
```

The results are `3`, `2`, and `-2`. A zero divisor raises `DIVISION BY ZERO`.

### Comparisons and logic

Comparisons return a numeric true/false value and may be assigned, printed, or
combined—not only used in `IF`:

```basic
A=7>3
B=A AND NOT (2=3)
PRINT B
```

Zero is false and any nonzero numeric value is true. `NOT` binds most tightly,
then `AND`, then `OR`. `AND` and `OR` evaluate both sides; they do not
short-circuit. If the right side can fail, use a nested `IF` rather than relying
on the left side as a guard.

Numeric comparisons support all six relational operators. Strings support
equality and inequality:

```basic
IF UPPER$(A$)="YES" THEN BORDER 4
IF A$<>B$ THEN PRINT "DIFFERENT"
```

### String expressions

String concatenation uses `+`: `"a"+"b"`, including longer chains such as
`A$+" "+B$+"!"`. Each term is still parsed after the 31-character result cap
is reached; excess output is simply truncated.

String functions can be nested and combined:

```basic
A$="timex"
B$=UPPER$(LEFT$(A$,3))+"-2068"
PRINT B$
```

This prints `TIM-2068`. Numeric and string values are distinct; use `STR$` to
format a number and `VAL` to parse an integer from text.

### Functions inside expressions

Built-in and user-defined functions can appear wherever a value of their type
is expected:

```basic
X=ABS(-12)+RND(10)
IF POINT(20,20)=1 THEN PRINT "PIXEL SET"
DEF FN D(N)=N*2
Y=FN D(X)+1
```

Unusually deep nesting reports `EXPRESSION TOO COMPLEX`; arithmetic outside a
calculator-backed operation's supported range reports `NUMERIC OVERFLOW`.

## 8. Screen output

Text wraps automatically at column 31. When output passes the bottom of the
24-row screen, the display scrolls upward by one text row and printing
continues on the cleared bottom row. This applies to strings that cross the
right edge as well as to successive `PRINT` statements.

| Statement | Effect |
|---|---|
| `PRINT <expr>` | Print one string or numeric expression at the current row/column, then advance to the next row |
| `CLS` | Clear the screen using the *current* `PAPER` color, and reset print position back to row 0, column 0 |
| `AT <row>,<col>` | Position the *next* `PRINT` only — row 0-23, column 0-31 (out-of-range values clamp rather than error). Wears off after that one `PRINT`; the line after resets to column 0 |
| `TAB <col>` | Same one-`PRINT`-only lifetime as `AT`, but sets column only, leaves row untouched |
| `INK <n>` | Foreground (text) color, 0-7 |
| `PAPER <n>` | Background color, 0-7 |
| `BORDER <n>` | Screen border color, 0-7 |
| `FLASH <n>` | Flashing text, `0`/`1` |
| `BRIGHT <n>` | Bright variant of the current colors, `0`/`1` |
| `INVERSE <n>` | Swap ink/paper for the next `PRINT`(s), `0`/`1` — doesn't change the underlying `INK`/`PAPER` values |
| `OVER <n>` | `0` draws normally; `1` XOR-plots subsequent text and graphics, allowing the same glyph or shape to erase itself when drawn twice at one position |

**`PRINT` takes exactly one expression** — there is currently no
`;`/`,` multi-item list the way classic BASIC's `PRINT A; B; C` works.
To show several things on one line, concatenate a string expression
yourself instead:

```
PRINT "X=" + STR$(x) + " Y=" + STR$(y)
```

Or, to put separate values at specific screen positions, use `AT` before
each one, as separate colon-chained statements:

```
AT 0,0 : PRINT "X=" + STR$(x) : AT 0,10 : PRINT "Y=" + STR$(y)
```

Colors: 0=black, 1=blue, 2=red, 3=magenta, 4=green, 5=cyan, 6=yellow,
7=white.

## 9. Graphics

Screen is 256×191 pixels; the `AT`/`TAB` text grid above is a separate,
coarser 32×24 character view of the same physical screen.

| Statement/function | Effect |
|---|---|
| `PLOT x,y` | Set one pixel. `x` is 0-255, `y` is 0-191 (out-of-range `y` clamps to the last valid row) |
| `LINE x0,y0 TO x1,y1` | Draw a straight line between two **absolute** points (not classic BASIC's relative-from-last-`PLOT` `DRAW`) |
| `BLOCK x0,y0 TO x1,y1` | Available only when the BLOCK extension is loaded; save/load modules with `SAVE "name" EXT` and `LOAD "name" EXT` |
| `FRAME x0,y0 TO x1,y1` | Draw a rectangle outline when the FRAME extension is loaded; reversed corners and current print/OVER attributes are supported |
| `INVERT x0,y0 TO x1,y1` | Invert every pixel in a rectangle when the INVERT extension is loaded; applying it twice restores the original bitmap |
| `CIRCLE x,y,r` | Draw a circle outline centered at `x,y` with radius `r`; a circle that would extend past the edge is simply clipped there |
| `FILL x,y` | Flood-fill the connected region starting at that pixel |
| `POINT(x,y)` | Function — `1` if that pixel is currently set, `0` if not |
| `ATTR(row,col)` | Function — normal-screen attribute byte at character row 0-23, column 0-31; returns `0` outside that grid |
| `CPLOT cx,cy` | Optional loadable extension: coarse 2×2-per-cell block graphics; unavailable until its RAM module is installed |
| `MODE n` | `0` = Normal, `1` = High Resolution Graphics (same 256×191 bitmap, finer per-scanline color). Anything else raises `INVALID MODE` |
| `ULAPLUS n` | Enable (`1`) or disable (`0`) the ULAplus extended palette. Other values raise `INVALID ARGUMENT` |
| `PALETTE index,value` | Program ULAplus register `index` (0-63) with an 8-bit `GGGRRRBB` color value (0-255). Out-of-range arguments raise `INVALID ARGUMENT` |

`PLOT`/`LINE`/`CIRCLE` and the loadable `BLOCK`/`CPLOT` extensions color using the *current*
`INK`/`PAPER`/`FLASH`/`INVERSE` state, same as `PRINT` — and, unlike
`PRINT`, they genuinely respect `OVER`: with `OVER 0` (the default) a
pixel is set outright; with `OVER 1` it's **XOR-toggled** instead
(plotting the same point twice with `OVER 1` clears it again) — useful
for drawing something temporarily without needing to remember and redraw
whatever was underneath it.

### ULAplus palettes

ULAplus replaces the fixed Spectrum-style palette with 64 programmable color
registers while retaining the familiar bitmap and attribute model. Your BASIC
program still uses `INK`, `PAPER`, `BRIGHT`, and `FLASH`; ULAplus changes the
actual colors those attribute combinations display. This makes it possible to
give a game, chart, or demo its own consistent visual identity without drawing
in a different screen format.

Select a palette register from 0 through 63 and give it an 8-bit color value in
`GGGRRRBB` format:

- bits 7-5: green, 0-7;
- bits 4-2: red, 0-7;
- bits 1-0: blue, 0-3.

Green and red have three bits each; blue has two. Useful reference values
include `0` (black), `3` (blue), `28` (red), `224` (green), `252` (yellow), and
`255` (white). Mixing the bit fields creates intermediate shades—for example,
adding more green changes bits 7-5 without disturbing the red and blue fields.

For example, this programs the first eight registers and enables ULAplus:

```basic
PALETTE 0,0
PALETTE 1,3
PALETTE 2,28
PALETTE 3,31
PALETTE 4,224
PALETTE 5,227
PALETTE 6,252
PALETTE 7,255
ULAPLUS 1
```

After enabling the palette, ordinary drawing statements use it:

```basic
CLS
ULAPLUS 1
INK 2
PAPER 0
AT 3,5
PRINT "2068-LEAP COLOR"
OVER 1
LINE 20,40 TO 220,140
OVER 0
```

Palette programming and palette activation are separate on purpose. A program
can define all needed registers while the normal palette is still visible,
then switch the prepared palette on in one step. This avoids displaying a
partially programmed palette during setup.

`PALETTE` stores register values whether ULAplus is currently enabled or not,
so a program can prepare its colors first and then issue `ULAPLUS 1`. Issuing
`ULAPLUS 0` returns to the normal palette without erasing the programmed
values; a later `ULAPLUS 1` reuses them.

ULAplus is deliberately program-scoped. Every route back to the editor—normal
completion, `END`, `STOP`, a runtime error, or `BREAK`—automatically disables
ULAplus so the editor is always readable in the normal display mode. The
programmed palette values remain available to the next `ULAPLUS 1` during that
session.

`ULAPLUS 0` is also useful inside a program when returning temporarily to
standard colors. It does not erase the programmed values, so `ULAPLUS 1`
restores the same custom palette later.

ULAplus works with the normal screen and with `MODE 1`; it is independent of
the removed 64-column mode and its former TS2068 palette selector. Emulator
support varies: ZEsarUX can enable ULAplus for the TS2068, while an unpatched
upstream Fuse may not expose it for this machine.

## 10. Sprites

A fixed-slot sprite system — 8 slots (0-7), each up to 4×4 character
cells (32×32 pixels).

The sprite system uses a capture-and-save-under model suited to a 48K
machine. First draw an image anywhere on the screen and `GRAB` its rectangular
cell area into a slot. `SHOW` draws that image elsewhere while saving the
pixels underneath it. `HIDE` restores those pixels, and `MOVE` performs the
restore-and-redraw sequence. BASIC screen output is therefore the sprite
authoring tool; no separate bitmap file format is required.

| Statement/function | Effect |
|---|---|
| `SPRITE GRAB slot,row,col,w,h` | Capture whatever's currently on screen at that cell rectangle into `slot`'s own image buffer. Doesn't draw anything yet. A shown slot must be `HIDE`d before it can be re-`GRAB`bed |
| `SPRITE SHOW slot,row,col` | Draw a previously-`GRAB`bed sprite at a screen position, saving what was there first so it can be restored later. Refuses with `SPRITE ALREADY SHOWN` if that slot is already shown — `HIDE` it first |
| `SPRITE HIDE slot` | Restore the background a `SHOW`/`MOVE` saved, and stop drawing that sprite. Refuses with `SPRITE NOT SHOWN` if it isn't currently shown |
| `SPRITE MOVE slot,row,col` | Reposition an already-shown sprite in one step: restores the old background, then shows it at the new position — same net effect as `HIDE` then `SHOW`, just one statement. Also refuses with `SPRITE NOT SHOWN` if it isn't shown yet |
| `HIT(slot1,slot2)` | Function — `1` if both slots are currently shown *and* their rectangles overlap, `0` otherwise (including if either slot number is invalid or not shown — a collision check deliberately never errors, since a game loop calls it every frame) |

### Creating and moving a sprite

This example prints a two-character image, captures it as slot 0, clears the
work area, and moves the sprite across the screen:

```basic
CLS
AT 0,0
PRINT "<>"
SPRITE GRAB 0,0,0,2,1
CLS
SPRITE SHOW 0,10,0
FOR C=1 TO 20
PAUSE 2
SPRITE MOVE 0,10,C
NEXT C
SPRITE HIDE 0
```

Coordinates are character cells rather than pixels, so a 2-by-1 sprite is 16
pixels wide and 8 pixels high. The captured image includes its bitmap and
display attributes.

### Collision detection

If slot 0 is a player and slot 1 is an obstacle, test them in the game loop:

```basic
IF HIT(0,1) THEN BORDER 2
```

`HIT` compares the shown rectangles. It returns `0` when either slot is hidden
or invalid, keeping repeated game-loop tests simple.

### Display order and saved backgrounds

`row`/`col` are the same 0-23/0-31 character-cell coordinates `AT` uses;
`w`/`h` are 1-4 (cells, not pixels). An invalid slot number, or a
`GRAB`/`SHOW` rectangle that doesn't fit the screen, raises `BAD SPRITE
SLOT`, `SPRITE TOO LARGE`, or `SPRITE OUT OF RANGE` as appropriate;
using a slot that was never `GRAB`bed raises `SPRITE NOT DEFINED`.

Sprites use independent save-under backgrounds and maintain a display stack.
Overlapping sprites can be detected with `HIT()`. `HIDE` and `MOVE` must
operate in reverse `SHOW` order; attempting either operation on a lower sprite
reports `SPRITE ORDER ERROR` before changing the screen. Once the upper sprite
is hidden, the next sprite can be moved or hidden safely.

Think of shown sprites as a stack of transparent cards. Each card remembers
the screen that existed when it was placed. Removing a lower card first would
restore an obsolete background over the cards above it, so operations unwind
from the top down. This rule avoids the RAM and processing cost of a full
compositor while still supporting overlap.

`CLS`, `MODE`, editor entry, and screen scrolling invalidate all currently
displayed slots because their saved backgrounds no longer describe the screen.
Captured images remain defined and can be shown again; `HIT()` returns `0` and
`HIDE`/`MOVE` report `SPRITE NOT SHOWN` until that happens.

## 11. Sound

The TS2068 has two distinct ways to make sound. `BEEP` toggles the simple
one-bit speaker and is convenient for clicks, alerts, and short effects.
`SOUND` controls the AY-3-8912 sound generator, whose independent tone
channels can continue playing while BASIC does other work. The loadable AYREG
extension exposes the AY's native 0-15 register numbering for programmers who
already have register-level music data.

| Statement | Effect |
|---|---|
| `BEEP duration,pitch` | A square-wave tone through the speaker. **Not** the real Sinclair `BEEP`'s musical-note/seconds grammar — both arguments here are raw integers: `duration` is a count of full waveform cycles, `pitch` is the busy-wait length per half-cycle (bigger = slower toggling = lower pitch) |
| `SOUND register,data` | Writes directly to the AY-3-8912 sound chip's registers — `register` is 1-16 (anything else raises `INVALID SOUND REGISTER`), `data` is the byte written to it. This one *is* the real Sinclair `SOUND` command's actual register-level behavior |
| `AYREG register,data` | Optional loadable low-level AY command. Uses native register numbers 0-15 and data 0-255; invalid values are rejected before the chip is touched. Load it with `LOAD "name" EXT` first |

### Beeper effects

The first value controls how many waveform cycles are produced; the second is
the delay between speaker transitions. A larger pitch value therefore makes a
lower sound:

```basic
BEEP 80,40
PAUSE 5
BEEP 80,120
```

`BEEP` occupies the processor while it plays. Use short durations when a
program must remain responsive.

### AY tones

`SOUND` is a compact register interface rather than a note-language. A program
sets tone periods, enables channels, and assigns volumes with a sequence of
writes. This two-channel example follows the same pattern as the supplied
showcase:

```basic
SOUND 7,60
SOUND 16,100
SOUND 1,1
SOUND 8,10
SOUND 2,200
SOUND 3,2
SOUND 9,6
PAUSE 100
SOUND 8,0
SOUND 9,0
```

The tone remains active during the `PAUSE` because the AY generates it in
hardware. Setting the channel volume values back to zero silences it. For a
melody, update the period registers inside a loop while leaving the mixer and
volume setup in place.

The real `SOUND` command accepts a semicolon-chained list of register
pairs on one line; that grammar isn't recognized here — chain multiple
writes with `:` instead: `SOUND 8,15 : SOUND 0,200`.

AYREG uses native zero-based AY register numbers, while `SOUND` preserves the
TS2068 BASIC convention. Choose one convention for a piece of music and keep
its data tables consistent.

## 12. Input

Input comes in three forms: `INPUT` pauses for a complete value, `INKEY$()`
polls the keyboard without waiting, and `STICK()` reads a joystick. Use
`INPUT` for forms and questions; use polling for games and other continuous
loops.

| Statement/function | Effect |
|---|---|
| `INPUT ["prompt";] <var>` | Reads a numeric or string scalar. The optional literal prompt is printed before input. `INPUT N` accepts digits and an optional `-`; `INPUT N$` accepts up to 31 printable characters. ENTER commits the value |
| `INKEY$()` | Function — the currently-pressed key as a one-character string, or `""` if nothing is pressed. Doesn't wait — call it every loop iteration to poll: `IF INKEY$() = "Q" THEN END` |
| `STICK(device)` | Function — reads a joystick through the AY-3-8912's I/O port. `device` is `1` or `2`; anything else raises `INVALID ARGUMENT`. Device 1 returns a 4-bit direction value; device 2 (a real hardware asymmetry, not a design choice here) only returns a single bit |

The prompt must currently be a quoted literal followed by `;`, for example
`INPUT "Name: ";A$`; it is not a general string expression. Prompts do not
wrap: characters and input echo beyond column 31 are clipped by the graphics
layer, so keep the literal short enough for the current cursor position.

### Prompted numeric and string input

```basic
INPUT "Your name: ";N$
INPUT "Your age: ";A
PRINT "HELLO "+UPPER$(N$)
PRINT "NEXT YEAR="+STR$(A+1)
```

Numeric input accepts decimal digits and an optional leading minus sign.
String input accepts printable text and stores up to 31 characters. The
variable type determines which editor is used; a trailing `$` selects string
input.

### Nonblocking keyboard input

`INKEY$()` returns immediately, so a program normally calls it repeatedly and
uses `PAUSE` to control loop speed:

```basic
again:
K$=INKEY$()
IF K$="Q" THEN END
IF K$=" " THEN BORDER 4
PAUSE 1
GOTO again
```

An empty string means no key is currently pressed. Because polling does not
wait, the rest of a game or animation can continue between checks.

### Joystick input

```basic
J=STICK(1)
PRINT J
```

Device 1 returns a four-bit direction value that can be tested as a whole or
decoded into direction bits. Device 2 exposes the hardware's single-bit
reading. Poll `STICK()` in the same kind of loop used for `INKEY$()`.

## 13. Memory and machine code

These features connect BASIC to the TS2068 address space and Z80 hardware.
They are useful for inspecting the display, exchanging data with assembly
routines, experimenting with peripherals, and measuring available program
space. They also bypass many of BASIC's safety checks, so use known addresses
and keep backups of important programs.

| Statement/function | Effect |
|---|---|
| `PEEK(addr)` | Function — reads one byte, 0-255 |
| `POKE addr,value` | Writes the low byte of `value` to `addr` |
| `USR(addr)` | Function — jumps to machine code at `addr`; that routine must end with its own `RET`, leaving its result in `HL` |
| `FREE()` | Function — bytes still free in the program area |
| `OUT port,data` | Optional loadable statement that writes byte data 0-255 to a complete 16-bit Z80 I/O port address |

These are the classic BASIC raw-memory escape hatch — a program can
touch any address it computes, exactly as on any other 8-bit BASIC's
`PEEK`/`POKE`/`USR`.

### Reading and writing memory

The normal display bitmap begins at address 16384. This example saves its first
byte, changes it, and restores it:

```basic
O=PEEK(16384)
POKE 16384,255
PAUSE 50
POKE 16384,O
```

`PEEK` always returns 0-255. `POKE` stores only the low eight bits of its value.
Writing to ROM has no effect on real hardware, while writing to ROM-owned RAM
can corrupt the editor, variables, sprites, or machine stack. Screen memory is
a convenient visible area for controlled experiments.

### Calling Z80 routines

`USR(address)` transfers control to an assembly routine already present in RAM.
The routine must preserve any machine state it changes, put its 16-bit result
in `HL`, and finish with `RET`:

```basic
R=USR(60000)
PRINT R
```

The example assumes you have installed a suitable routine at address 60000;
do not call an arbitrary address. Machine-code authors should consult the
memory map before selecting storage, because the extension window and stack
occupy upper RAM.

### Measuring free BASIC memory

`FREE()` reports bytes remaining in the dynamic program area. It changes as
program statements and arrays consume or release space:

```basic
PRINT FREE()
DIM A(100)
PRINT FREE()
```

Release 1 Beta begins with a 15,322-byte dynamic BASIC pool, a major increase
from Public Preview 1's 1,857 bytes.

### Z80 port output

OUT is shipped as a loadable extension because direct port access is powerful
but specialized. After loading `out.tzx`:

```basic
LOAD "OUT" EXT
OUT 254,4
```

Port 254 controls the ULA border/MIC/EAR lines; the low three data bits select
the border color. OUT is intentionally unrestricted. Writes whose low byte is
`$F4` can affect TS2068 memory paging, and add-ons may decode other addresses.
A BASIC error cannot undo a hardware write, so only run OUT examples whose port
use you understand.

## 14. Loadable BASIC extensions

Loadable BASIC extensions are one of 2068-Leap's defining features. A normal
ROM is frozen once programmed, and both Release 1 ROM banks are essentially
full. The extension system gives BASIC a controlled way to learn a new
statement at run time: a module supplies its keyword and implementation, while
the ROM supplies parsing, validation, graphics services, and tape storage.

Release 1 Beta supports one optional statement extension at a time. Each module
lives in a fixed 512-byte RAM window. Loading a new module replaces the
previous one, so optional tools consume RAM only when needed and consume no
additional Home ROM or EXROM space.

An installed keyword participates in the language rather than behaving like a
raw `USR` call. It is recognized by the editor, checked before `RUN`, receives
parsed arguments in a documented form, and reports errors through BASIC's
normal status system.

| Extension | Syntax | Purpose |
|---|---|---|
| CPLOT | `CPLOT cx,cy` | Draw a coarse 2×2-pixel block at cell coordinates 0-63,0-47 |
| BLOCK | `BLOCK x0,y0 TO x1,y1` | Draw a filled rectangle, accepting corners in either order |
| FRAME | `FRAME x0,y0 TO x1,y1` | Draw a rectangular outline, accepting corners in either order |
| INVERT | `INVERT x0,y0 TO x1,y1` | XOR-invert an inclusive rectangle; run twice to restore it |
| AYREG | `AYREG register,data` | Write native AY register 0-15 with byte data 0-255 |
| OUT | `OUT port,data` | Write byte data 0-255 to a complete 16-bit Z80 port address |

The graphics modules show how one interface can support several drawing ideas.
CPLOT uses coarse block coordinates, BLOCK fills a rectangle, FRAME draws only
its edges, and INVERT changes an existing region reversibly. AYREG and OUT
provide isolated hardware-oriented commands.

### Loading and saving an extension

Load a module from tape with an explicit name:

```basic
LOAD "FRAME" EXT
```

In an emulator, attach `frame.tzx` through its tape controls first. Enter the
command above, start tape playback if required, and wait for the load-complete
status. The new statement is then part of BASIC:

```basic
INK 6
OVER 1
FRAME 20,20 TO 180,120
OVER 0
```

The name is mandatory; `LOAD "" EXT` is deliberately rejected. After loading,
use the new statement normally in a program. Save the currently loaded module
to another tape with:

```basic
SAVE "MYFRAME" EXT
```

Extension recordings use normal TS2068 tape framing but have their own module
type, checksum, fixed-size, and ABI-version checks. A damaged, wrong-sized, or
incompatible module is rejected before it can register a keyword.

### Program and extension loading order

`NEW` unregisters the current extension. Loading an ordinary BASIC program also
unregisters it before searching the tape, so load the program first and its
required extension second. A program may contain an extension statement while
its module is absent, but the whole-program check reports a syntax error until
the matching module is loaded.

For a program that uses FRAME, the reliable sequence is:

1. `LOAD "PROGRAM"` to load the BASIC program.
2. Attach the FRAME extension tape.
3. `LOAD "FRAME" EXT` to install its keyword.
4. Enter `RUN`.

This prevents a module used by an earlier program from silently remaining
active for an unrelated one.

### Saving and sharing modules

`SAVE "name" EXT` records the currently installed module. This lets a module
loaded from one tape be copied to another without exposing a general-purpose
CODE loader. The header records the extension type and ABI version, so an
incompatible future module can be rejected instead of called with the wrong
service contract.

### Safety and compatibility

CPLOT, BLOCK, FRAME, and INVERT use published graphics services and respect the
current drawing attributes, including `OVER`. AYREG and OUT access hardware
directly. In particular, OUT can change display, sound, tape, or memory-paging
hardware depending on the selected port; only run OUT programs whose port use
you understand.

The supplied modules are position-independent and use the Release 1 extension
ABI. Extension tape operation has automated emulator coverage; physical
cassette reliability still depends on recorder, cable, medium, and signal
level.

The Release 1 ABI deliberately supports statement extensions rather than
arbitrary replacement of the interpreter. That boundary is what makes a tape
module safe to recognize while editing and practical to validate before it is
executed.

## 15. Immediate commands

Typed alone on a line and committed (ENTER), these execute right away
instead of being stored as a program statement — the only statements
that behave this way:

| Command | Effect |
|---|---|
| `RUN` | Runs the whole stored program from the start, after a whole-program error check (see [The editor](#2-the-editor)) |
| `NEW` | Clears the current program *and* every variable, back to the same fresh state as cold boot |
| `LIST` | Jumps the editor view to the top of the program |
| `EDIT <label>` | Rebuilds the label table (so this works even before the program has ever been `RUN`) and jumps straight to that label's line |
| `DELETE <start>,<end>` | Removes a 1-based inclusive range of lines — see [The editor](#2-the-editor) |
| `SAVE "name"` / `LOAD "name"` / `LOAD ""` | Tape transfer — see [Loading and saving with Fuse](#3-loading-and-saving-with-fuse) |

## 16. Function reference

### Math

| Function | Returns |
|---|---|
| `ABS(x)` | Absolute value |
| `SGN(x)` | -1, 0, or 1 |
| `SQR(x)` | Square root — prints with real fractional digits (e.g. `1.4142`) when `PRINT SQR(x)` is the *entire* printed expression; falls back to a truncated integer when composed into a larger expression (`SQR(x)+1`) |
| `SIN(x)` | Sine of `x` **degrees** (not radians — see below) — same fractional-display behavior as `SQR` when printed alone |
| `PI()` | 3.1415... — called with empty parens, like `FREE()` |
| `RAD(x)` | Degrees to radians (`x * pi / 180`) |
| `DEG(x)` | Radians to degrees (`x * 180 / pi`) |
| `MOD(x,y)` | Remainder, taking the dividend's sign (`-17 MOD 5` = `-2`) |
| `DIV(x,y)` | Integer division, truncating toward zero (`-17 DIV 5` = `-3`) |
| `INT(x)` | No-op — every number here is already an integer |
| `RND(x)` | Pseudo-random value in `[0, x-1]` for positive `x`; `0` for `x<=0` |

Common numeric examples:

```basic
PRINT ABS(-25)
PRINT 17 DIV 5
PRINT 17 MOD 5
PRINT SQR(2)
PRINT SIN(30)
PRINT RAD(180)
```

`SGN` is useful when only direction matters: it returns `-1`, `0`, or `1`.
`DIV` and `MOD` are useful for splitting values into digits or hardware bytes.
`RAD` and `DEG` convert between angular units, while `PI()` supplies a
calculator-backed constant.

`SIN` takes **degrees**, not radians — a deliberate choice, since with
no float literals in this language an integer number of radians would
almost never land near a recognizable angle.

### Random numbers

`RND(limit)` returns a value from zero through `limit-1`. `RANDOMISE` controls
the sequence used by RND:

```basic
RANDOMISE 123
FOR I=1 TO 5
PRINT RND(100)
NEXT I
```

Running this program again with the same nonzero seed produces the same
sequence, which is useful for repeatable tests. `RANDOMISE 0` selects the
hardware-entropy seed used after cold boot.

### String

| Function | Returns |
|---|---|
| `CHR$(n)` | The one-character string with ASCII code `n` (0-255) |
| `STR$(n)` | `n` formatted as a decimal string |
| `UPPER$(s$)` | `s$` with `a`-`z` converted to `A`-`Z` |
| `LOWER$(s$)` | The reverse of `UPPER$` |
| `LEFT$(s$,n)` | The first `n` characters (clamps at either end rather than erroring) |
| `RIGHT$(s$,n)` | The last `n` characters (same clamping) |
| `LEN(s$)` | Length, 0-31 |
| `CODE(s$)` | ASCII code of the first character, `0` for an empty string |
| `VAL(s$)` | Parses a decimal integer from the start of `s$` (tolerates a leading `-`, stops at the first non-digit); `0` if nothing parseable |
| `INSTR(haystack$,needle$)` | 1-based position of the first match, or `0`; an empty needle returns `1` |

String functions can be nested because each result is a normal string value:

```basic
A$=" 2068-leap "
B$=UPPER$(RIGHT$(A$,5))
PRINT B$
PRINT LEN(B$)
PRINT INSTR(A$,"leap")
```

`LEFT$` and `RIGHT$` clamp their requested length rather than failing. `CODE`
and `CHR$` convert between a character and its byte value. `STR$` and `VAL`
bridge numeric and string expressions. `INSTR` uses one-based positions so a
zero result unambiguously means “not found.”

### Other

| Function | Returns |
|---|---|
| `FREE()` | Bytes free in the program area |
| `DIMN(name)` | An array's declared size |
| `PEEK(addr)` | One byte at `addr` |
| `USR(addr)` | Runs machine code at `addr`, `HL` result |
| `POINT(x,y)` | `1`/`0` — is that pixel set |
| `ATTR(row,col)` | Attribute byte at a normal-screen character cell, or `0` out of range |
| `INKEY$()` | Currently-pressed key, or `""` |
| `STICK(device)` | Joystick reading |
| `HIT(slot1,slot2)` | `1`/`0` — do two shown sprites overlap |

These functions connect expressions to system state. `FREE()` and `DIMN()`
report memory/allocation information; `PEEK()` and `USR()` bridge to machine
code; `POINT()` and `ATTR()` inspect the display; `INKEY$()` and `STICK()` poll
input; and `HIT()` tests sprite geometry.

```basic
PRINT "FREE="+STR$(FREE())
IF POINT(100,80) THEN PRINT "SET"
IF INKEY$()<>"" THEN PRINT "KEY"
```

## 17. Statement reference

Quick alphabetical lookup — see the linked section for the full
description of each.

| Statement | Section |
|---|---|
| `AT` | [8](#8-screen-output) |
| `AYREG` | [11](#11-sound), [14](#14-loadable-basic-extensions) |
| `BEEP` | [11](#11-sound) |
| `BLOCK` | [9](#9-graphics), [14](#14-loadable-basic-extensions) |
| `BORDER` | [8](#8-screen-output) |
| `BRIGHT` | [8](#8-screen-output) |
| `CALL` | [4](#4-program-structure--labels-instead-of-line-numbers) |
| `CIRCLE` | [9](#9-graphics) |
| `CLS` | [8](#8-screen-output) |
| `CPLOT` | [9](#9-graphics), [14](#14-loadable-basic-extensions) |
| `DEF FN` / `FN` | [6](#6-variables-and-data) |
| `DELETE` | [2](#2-the-editor), [15](#15-immediate-commands) |
| `DIM` | [6](#6-variables-and-data) |
| `EDIT` | [15](#15-immediate-commands) |
| `END` | [5](#5-control-flow) |
| `EXIT FOR` | [5](#5-control-flow) |
| `FILL` | [9](#9-graphics) |
| `FLASH` | [8](#8-screen-output) |
| `FRAME` | [9](#9-graphics), [14](#14-loadable-basic-extensions) |
| `FOR` / `NEXT` | [5](#5-control-flow) |
| `GOSUB` / `RETurn` | [4](#4-program-structure--labels-instead-of-line-numbers), [5](#5-control-flow) |
| `GOTO` | [4](#4-program-structure--labels-instead-of-line-numbers) |
| `IF` / `THEN` / `ELSEIF` / `ELSE` / `END IF` | [5](#5-control-flow) |
| `INK` | [8](#8-screen-output) |
| `INPUT` | [12](#12-input) |
| `INVERT` | [9](#9-graphics), [14](#14-loadable-basic-extensions) |
| `INVERSE` | [8](#8-screen-output) |
| `LINE` | [9](#9-graphics) |
| `LIST` | [15](#15-immediate-commands) |
| `LOAD` | [3](#3-loading-and-saving-with-fuse) |
| `MODE` | [9](#9-graphics) |
| `NEW` | [15](#15-immediate-commands) |
| `OUT` | [13](#13-memory-and-machine-code), [14](#14-loadable-basic-extensions) |
| `OVER` | [8](#8-screen-output), [9](#9-graphics) |
| `PAPER` | [8](#8-screen-output) |
| `PALETTE` | [9](#9-graphics) |
| `PAUSE` | [5](#5-control-flow) |
| `PLOT` | [9](#9-graphics) |
| `POKE` | [13](#13-memory-and-machine-code) |
| `PRINT` | [8](#8-screen-output) |
| `RANDOMISE` | [Random numbers](#random-numbers) |
| `REM` | comment to end of line — `REM this is ignored` |
| `RUN` | [15](#15-immediate-commands) |
| `SAVE` | [3](#3-loading-and-saving-with-fuse) |
| `SOUND` | [11](#11-sound) |
| `SPRITE GRAB` / `SHOW` / `HIDE` / `MOVE` | [10](#10-sprites) |
| `STOP` | [5](#5-control-flow) |
| `TAB` | [8](#8-screen-output) |
| `ULAPLUS` | [9](#9-graphics) |
| `:` (statement separator) | chains multiple statements on one line: `x=1 : y=2 : PRINT x+y` — works inside single-line `IF ... THEN` too |

`REM` (bare word only, not `REMark` spelled out) starts a comment
running to the end of the line — `REM this is ignored`, or trailing:
`x = 1 : REM note`. A `:` inside `REM`'s own text is just more comment
text, not a new statement.

## 18. Error messages

**Found while typing** (whole-program check, before `RUN` starts):

| Message | Meaning |
|---|---|
| `SYNTAX ERROR` | Malformed statement |
| `LABEL NOT FOUND` | A `GOTO`/`GOSUB`/`CALL` target doesn't exist |
| `INVALID ARGUMENT` | An argument is outside its valid range (`STICK`, `CHR$`) |

**Found at `RUN` time**:

| Message | Meaning |
|---|---|
| `DIVISION BY ZERO` | `/`, `MOD`, or `DIV` with a zero divisor |
| `NUMERIC OVERFLOW` | A calculator-backed result is outside its supported numeric range |
| `CALCULATOR ERROR` | The calculator rejected an operation or produced an invalid result |
| `IF WITHOUT END IF` | Unbalanced block `IF` |
| `FOR WITHOUT NEXT` | Unbalanced `FOR` |
| `NEXT WITHOUT FOR` | `NEXT` with no open loop |
| `NEXT VARIABLE MISMATCH` | Named `NEXT` variable doesn't match the open loop |
| `FOR NESTED TOO DEEPLY` | More than 8 `FOR` loops open at once |
| `EXIT WITHOUT FOR` | `EXIT FOR` with no open loop |
| `GOSUB TOO DEEP` | Too many nested, un-returned `GOSUB`/`CALL` |
| `RETURN WITHOUT GOSUB` | Stray `RETurn` |
| `INVALID MODE` | `MODE` argument isn't `0` or `1` |
| `INVALID SOUND REGISTER` | `SOUND` register outside 1-16 |
| `INVALID ARRAY SIZE` | Bad `DIM` size |
| `ARRAY ALREADY DIMENSIONED` | Re-`DIM`ing an array without a fresh `RUN` |
| `ARRAY NOT DIMENSIONED` | Using an array before `DIM`ing it |
| `SUBSCRIPT OUT OF RANGE` | Array index outside its declared size |
| `OUT OF MEMORY` | Not enough free RAM (e.g. for a `DIM`) |
| `EXPRESSION TOO COMPLEX` | An expression nested too deeply for the evaluator |
| `BREAK` | Program interrupted |
| `BAD SPRITE SLOT` | Invalid sprite slot number |
| `SPRITE TOO LARGE` | `SPRITE GRAB` rectangle too big |
| `SPRITE OUT OF RANGE` | `SPRITE GRAB`/`SHOW` rectangle doesn't fit the screen |
| `SPRITE NOT DEFINED` | Using a slot that was never `GRAB`bed |
| `SPRITE ALREADY SHOWN` | `SHOW` on a slot that's already shown |
| `SPRITE NOT SHOWN` | `HIDE`/`MOVE` on a slot that isn't currently shown |
| `SPRITE ORDER ERROR` | `HIDE`/`MOVE` attempted on a slot below another displayed sprite |

**`SAVE`/`LOAD`**:

| Message | Meaning |
|---|---|
| `SAVED` / `LOADED` | Success |
| `LOAD FAILED` | Unreadable tape, or name mismatch |
| `SAVE FAILED` | An extension SAVE was requested with no module installed |
| `INVALID FILENAME` | Bad `SAVE`/`LOAD` filename |

**Editor**:

| Message | Meaning |
|---|---|
| `INVALID RANGE` | Bad `DELETE` arguments |

## 19. Keyboard reference

### Cursor and editing

| Combo | Action |
|---|---|
| CAPS SHIFT + 5 | Left |
| CAPS SHIFT + 6 | Down |
| CAPS SHIFT + 7 | Up |
| CAPS SHIFT + 8 | Right |
| CAPS SHIFT + 0 | Delete (forward) |
| CAPS SHIFT + 1 | Delete whole line |
| CAPS SHIFT + ENTER | Insert blank line before current |
| SYMBOL SHIFT + A | Next error |
| SYMBOL SHIFT + S | Previous error |

Fuse maps your PC's real arrow keys and Backspace directly to the
corresponding combos above.

### Punctuation (SYMBOL SHIFT)

| Combo | Char | Combo | Char |
|---|---|---|---|
| SYMBOL SHIFT + 1 | `!` | SYMBOL SHIFT + 6 | `&` |
| SYMBOL SHIFT + 2 | `@` | SYMBOL SHIFT + 7 | `'` |
| SYMBOL SHIFT + 3 | `#` | SYMBOL SHIFT + 8 | `(` |
| SYMBOL SHIFT + 4 | `$` | SYMBOL SHIFT + 9 | `)` |
| SYMBOL SHIFT + 5 | `%` | SYMBOL SHIFT + 0 | `_` |
| SYMBOL SHIFT + Z | `:` | SYMBOL SHIFT + L | `=` |
| SYMBOL SHIFT + M | `.` | SYMBOL SHIFT + K | `+` |
| SYMBOL SHIFT + N | `,` | SYMBOL SHIFT + J | `-` |
| SYMBOL SHIFT + P | `"` | SYMBOL SHIFT + O | `;` |
| SYMBOL SHIFT + V | `/` | SYMBOL SHIFT + B | `*` |
| SYMBOL SHIFT + R | `<` | SYMBOL SHIFT + T | `>` |
| SYMBOL SHIFT + C | `?` | | |

### Block-graphics characters

The TS2068 number keys carry block-graphics legends. 2068-Leap can render
the corresponding 16 two-by-two mosaic characters, but its current keyboard
decoder does **not** yet enter them directly from those key combinations.
In BASIC, print them with `CHR$(128+n)`, where `n` is the quadrant mask:

- bit 0 = top right
- bit 1 = top left
- bit 2 = bottom right
- bit 3 = bottom left

| Code | Filled quadrants | Code | Filled quadrants |
|---:|---|---:|---|
| 128 | none (blank) | 136 | bottom left |
| 129 | top right | 137 | top right, bottom left |
| 130 | top left | 138 | left half |
| 131 | top half | 139 | top half, bottom left |
| 132 | bottom right | 140 | bottom half |
| 133 | right half | 141 | top right, bottom half |
| 134 | top left, bottom right | 142 | top left, bottom half |
| 135 | top half, bottom right | 143 | all (solid) |

For example, `PRINT CHR$(133)` prints a solid right-half block. `CPLOT`
uses the same quadrant idea with coarse coordinates, without requiring
character codes.

A handful of SYMBOL SHIFT letter combos (`X`, `I`, `U`, `Y`, `H`) have no
mapping in this ROM yet. `Q`/`W`/`E` (which give the two-character
tokens `<=`/`<>`/`>=` on real hardware) are deliberately not mapped
either — just type the two characters in sequence instead (`<` then
`=`), which this BASIC's own parser already reads the same way.

## 20. Known limitations

This section separates deliberate product design from features that may grow
after the beta. A deliberate difference is not a defect or an unfinished
promise; it defines how 2068-Leap is intended to work.

### Deliberate design choices

- **Programs have no line numbers.** Labels and structured control flow replace
  numbered targets, so `RENUMBER` is neither needed nor meaningful.
- **`PRINT` accepts one expression.** Build a complete line through string
  concatenation, or position separate outputs with colon-chained `AT`/`PRINT`
  statements. This keeps the grammar consistent with other statements.
- **`OVER 1` means XOR for text and graphics.** Drawing the same item twice in
  the same place restores the previous bitmap.
- **Programs use a native plain-text representation inside standard TS2068
  tape framing.** A stock ROM can recognize the container but cannot execute
  the 2068-Leap payload.
- **`LOAD` replaces the current program.** There is no implicit merge, which
  keeps labels, arrays, and extension lifecycle deterministic.
- **One loadable extension is active at a time.** This provides a predictable
  fixed RAM cost and a simple, safe keyword-registration model.

### Current Release 1 Beta boundaries

- Numeric and string arrays are one-dimensional.
- The implemented structured-control set centers on block/single-line `IF`,
  `FOR`/`NEXT`, labels, `GOTO`, and `GOSUB`/`CALL`; additional SuperBASIC-style
  constructs remain future design options.
- Arrays are the current tool for stored data tables; a separate
  `DATA`/`READ` stream is not part of this beta.
- The calculator focuses on the documented numeric functions in section 16.
- Several block-graphics keyboard legends do not yet have direct key-entry
  combinations; `CHR$` can still produce every block character.

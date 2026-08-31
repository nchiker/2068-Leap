# 2068 Leap BASIC Language Reference

Status: DRAFT — starting with the one decision everything else depends on:
how the language is structured without line numbers. Grows alongside
`basic/` as it's written.

## Program structure

A program is a sequence of statements, one per line, with **no line
numbers**. What used to be done by numbering lines and `GOTO`ing them is
done instead by:

1. **Labels** — named points in the program, for the small number of cases
   that still need an explicit jump target.
2. **Structured control flow** — named blocks that cover the vast majority
   of what line-number `GOTO` used to be used for, borrowed directly from
   QL SuperBASIC's block constructs.

### Labels

A label is an identifier alone on its own line, followed by a colon:

```
main_loop:
    PRINT "hello"
    IF done THEN GOTO finished
    GOTO main_loop
finished:
    PRINT "done"
```

- **Scope**: a label is local to the procedure it's defined in — the
  top-level (unnamed) program body counts as its own scope, and each
  `DEFine PROCedure`/`DEFine FuNction` is its own separate scope. A label
  only has to be unique *within* its enclosing scope, not across the
  whole program, following Visual Basic's model rather than SuperBASIC's
  flat, whole-program label space. This keeps the label table small (one
  small table per procedure, not one big table for the whole program) and
  keeps `EDITOR_BLOCK_DELETE`'s dangling-reference check cheap — it only
  ever has to search the enclosing procedure, never the whole program.
- Label names follow the same rules as variable names, and share the same
  restriction as procedure/function names *within their scope* — you
  can't reuse a name for both a label and a procedure/function visible in
  that scope, so a typo'd `GOTO` fails to compile rather than silently
  jumping somewhere unrelated.
- **Implementation note (2026-08-22), current reality vs. the design
  above**: labels/`GOTO`/bare `GOSUB`/`RETurn`/`CALL` are implemented,
  but as a single flat, whole-program label table (`MEM_LABEL_LOOKUP`)
  — the per-scope table described above needs `DEFine PROCedure`'s own
  scoping machinery, which isn't built. More importantly: `BASIC_
  PARSE_IDENTIFIER` (`basic/basic.asm`) — the ONE routine every label
  name, `GOTO`/`GOSUB`/`CALL` target, and label DEFINITION all parse
  through — only accepts **letters** (`A`-`Z`, case-insensitive after
  uppercasing); it silently STOPS at the first non-letter, including a
  digit. `sub1:` is parsed as the 3-letter identifier `SUB`, leaving a
  stray `1` behind — this fails BOTH the label-definition check (the
  leftover `1` isn't the `:` it expects next) and `GOTO`/`GOSUB
  sub1`'s own grammar check (the leftover `1` isn't the end-of-
  statement it expects) — reported as a whole-program check failure,
  not something GOTO/GOSUB do differently. **No digits or underscores
  in label names for now** — `main_loop` in the example above would
  hit this too (the underscore, not just a hypothetical digit). This
  was found the hard way, mid-session, testing bare `GOSUB`/`RETurn`/
  `CALL` — see `docs/programmers_reference.md`'s own writeup for the
  full incident.
- `GOTO <label>`, `GOSUB <label>`, and `RESTORE <label>` are the only
  statements that take a label as an operand, and — like everything else
  about a label — can only reference a label in their own scope. There is
  no cross-procedure `GOTO`; calling another procedure is always done
  with a normal procedure call, never a jump.
- `GOTO`/`GOSUB` cannot branch into the middle of a `REPeat`/`FOR`/`IF`/
  `SELect ON` block from outside it — disallowed outright, not just
  discouraged, matching VB.NET's rule for `For`/`Try`/`SyncLock`/`With`/
  `Using`. Branching *within* a block, or *out* of one to an enclosing
  scope, is fine; branching *in* from outside is not, because it would
  let control flow skip whatever setup the block's own entry does.
- Labels are resolved to program positions once, when the program is
  edited (not re-scanned on every `GOTO` at run time) — see "Label table"
  below.

### DATA / RESTORE / READ

This is the case classic line-number BASIC handled well and SuperBASIC's
line-number-free add-on (SSB) never solved (see project notes). Solution:
`RESTORE` takes a label placed immediately before the `DATA` statement(s)
it should resume reading from:

```
prices:
    DATA 1.99, 2.49, 9.99
...
    RESTORE prices
    READ p
```

**Status: design only — deliberately not implemented.** A working,
integer-only build was scoped out in full (2026-08-22) — three new
keywords, a persistent read-position pointer, and a full EXROM
migration to fit Home ROM's budget, ~90 bytes of unavoidable Home-side
dispatch/wrapper cost — and then set aside after the user weighed it
against `docs/programmers_reference.md`'s own numeric-array support
(`DIM`, 0-based, dynamic region): with no float literal syntax
anywhere in this dialect (see the "function-result float" note
elsewhere in this doc), `DATA` could only ever hold the same plain
integers an array already holds directly, indexed and mutable, with
none of `READ`'s own one-shot, position-tracking constraints. The
judgment call was that `DATA`/`RESTORE`/`READ` doesn't clear the bar
over what arrays already do, integer-only — worth reopening only if
this dialect ever gains float literals (making `DATA` a real win for
tabular constant data arrays can't hold as cleanly) or string arrays.
Redirected into expanding array-related functions/support instead
(see `docs/programmers_reference.md`'s own status tables for what
exists today: `DIM`, indexed read/write, `+` arithmetic over elements,
array-indexed-by-array).

Bare `RESTORE` (no label) resets to the first `DATA` statement in the
program, same as classic BASIC's default behaviour.

### Structured control flow

Ported from QL SuperBASIC, which is why looping/branching rarely needs
`GOTO` in practice even though the label mechanism above is always there
as an escape hatch:

| Construct | Form |
|---|---|
| Conditional | `IF <cond> THEN ... [ELSEIF <cond> THEN ...]* [ELSE ...] END IF` (multi-line); single-line `IF <cond> THEN <stmt>` for short cases |
| Counted loop | `FOR <var> = <start> TO <end> [STEP <n>] ... NEXT [<var>]` |
| General loop | `REPeat <name> ... [EXIT <name>] ... END REPeat <name>` |
| Case dispatch | `SELect ON <expr> ... ON <value> ... REMAINDER ... END SELect` |
| Procedure | `DEFine PROCedure <name>([REF] <params>) ... [RETurn] ... END DEFine` |
| Function | `DEFine FuNction <name>([REF] <params>) ... RETurn <value> ... END DEFine` |
| Error handling | `WHEN ERRor ... END WHEN` |

Functions return their value with `RETurn <value>` — there is no
implicit "assign to the function's own name" convention. This keeps
`RETurn` doing one consistent job everywhere it appears (see below)
instead of function returns working differently from everything else.

`REPeat` blocks still take a **name**, matched on the closing `END
REPeat`/`EXIT`, exactly as in SuperBASIC — this is what lets nested
loops be exited from arbitrarily deep without ambiguity about which
loop `EXIT` refers to. **`FOR` is the one deliberate departure from
SuperBASIC here**: real QL SuperBASIC closes `FOR` with `END FOR
[var]`, but this project closes it with classic-BASIC-style `NEXT
[var]` instead — [stated]'s own call, since `NEXT` is what everyone
who grew up on Sinclair/Commodore/Atari BASIC will instinctively type,
and it's one token shorter. The variable name on `NEXT` is optional
(bare `NEXT` acts on the innermost open loop, matching classic BASIC),
but when given, it must match that loop's own variable or the program
errors with `NEXT VARIABLE MISMATCH` rather than silently acting on
the wrong loop. **`FOR` now supports early exit via `EXIT FOR`**
(built 2026-08-19) — deliberately NOT bare `EXIT` the way `NEXT`
accepts a bare form: `EXIT <name>` is the documented general form
`REPeat` will use once built, and consuming bare `EXIT` now for a
construct (`FOR`) that has no name at all would mean guessing how it
ought to interact with `REPeat`'s own later named-exit matching.
`EXIT FOR` sidesteps that guess — unambiguous today, doesn't claim
territory a not-yet-built feature might need.

**Implementation status: IF/ELSEIF/ELSE/END IF and FOR/NEXT are both
built and working.** REPeat, SELect, DEFine PROCedure/FuNction, and
WHEN ERRor are still just this design document — none of that exists
in basic/basic.asm yet.

What's actually implemented for IF:
- Block form: `IF <cond> THEN` / body / `[ELSEIF <cond> THEN ...]*` /
  `[ELSE ...]` / `END IF`, arbitrarily nested. `ENDIF` (one word) also
  works, as a harmless side effect of how the parser tolerates zero
  spaces between `END` and `IF` — not a second spelling worth relying
  on deliberately, just not rejected either.
- Single-line short form: `IF <cond> THEN <stmt>`, no `END IF` needed —
  possible without any multi-statement/colon support because this
  project already stores one typed line as one statement's full text,
  so the text after `THEN` is just more of THAT statement, dispatched
  through the same top-level statement recognizer. There's no `ELSE`
  in the single-line form. Colon-chaining multiple statements after
  `THEN` now works too, now that the statement separator (`:`) is
  implemented — see "Statement separator" below.
- Conditions: `=`, `<>`, `<`, `>`, `<=`, `>=`, plus `AND`/`OR`/`NOT`
  (standard precedence: `NOT` binds tightest, then `AND`, then `OR`).
  A bare expression with no relational operator is truthy/falsy the
  classic-BASIC way (nonzero = true). **`AND`/`OR` do NOT short-
  circuit** — both sides are always evaluated, so `IF Y<>0 AND
  X/Y>1 THEN` still raises `DIVISION BY ZERO` when `Y=0`, exactly as
  if the guard weren't there. This is a known, accepted limitation,
  not a bug.
- The static program checker (see "Error handling" below) validates
  each IF/ELSEIF/ELSE/END IF line's own syntax, but does NOT verify
  whole-program IF/END IF balance — a genuinely mismatched IF is only
  caught at RUN time, reported as "IF WITHOUT END IF".

What's actually implemented for FOR/NEXT:
- `FOR <var> = <start> TO <end> [STEP <n>]`, always block form (no
  single-line short form the way IF has one). `STEP` defaults to 1
  when omitted. Nested up to 8 loops deep (`FOR_STACK_MAX` in
  sysvars.inc) — a 9th concurrently-open FOR reports "FOR NESTED TOO
  DEEPLY".
- Classic BASIC entry semantics: if the very first check already fails
  (e.g. `FOR I = 5 TO 1` with the default `STEP 1`), the loop body
  never runs, not even once — the whole thing is skipped at RUN time
  without ever assigning the loop variable or pushing loop state.
- `STEP 0` is accepted without a special case — the loop variable never
  advances, so it runs forever if the entry condition otherwise allows
  it (an intentional infinite loop, same as real SuperBASIC allows).
- `NEXT [<var>]` — the variable is optional; when given, it's checked
  against the innermost open loop's own variable (see the table note
  above for why this departs from real QL SuperBASIC's `END FOR`).
  `NEXT` with no open FOR loop at all reports "NEXT WITHOUT FOR" rather
  than reading garbage off an empty stack.
- Like IF/END IF, the static checker validates each FOR/NEXT line's
  own syntax in isolation but does NOT verify whole-program FOR/NEXT
  balance — a genuinely mismatched FOR is only caught at RUN time,
  reported as "FOR WITHOUT NEXT".
- `EXIT FOR` (built 2026-08-19) breaks out of the innermost open FOR
  loop early — pops that loop's FOR_STACK entry and jumps past its
  matching NEXT, reusing the same forward-scan `FOR`'s own "condition
  already false, skip the whole body" path already established. Using
  it with no FOR loop open reports "EXIT WITHOUT FOR". Only "EXIT FOR"
  is valid syntax — see the table note above for why bare `EXIT` is
  deliberately not accepted here.

### RETurn vs. EXIT

These are not interchangeable, and both are needed:

- **`RETurn`** leaves a `GOSUB`, a `DEFine PROCedure`, or a `DEFine
  FuNction` entirely, returning control to whoever called it. Bare
  `RETurn` for `GOSUB`/procedures; `RETurn <value>` for functions. A
  program with `GOSUB` but no `RETurn` was an actual gap in an earlier
  draft of this doc — every `GOSUB` needs a matching `RETurn` to come
  back to, same as classic BASIC. **Bare `GOSUB <label>` / `RETurn` /
  `CALL <label>` implemented (2026-08-22)** — `RETurn <value>` for
  functions is not (no `DEFine FuNction` exists to return from). See
  `docs/programmers_reference.md`'s own writeup for the implementation
  (a new `GOSUB_STACK`, shaped like the existing `FOR_STACK`) and a
  real edge case it had to guard against (`RETurn` when `GOSUB` was
  the program's own last statement).
- **`EXIT <name>`** breaks out of an open `REPeat`/`FOR` loop early,
  without leaving the enclosing procedure/function. It only makes sense
  inside a loop; `RETurn` only makes sense inside a `GOSUB` target,
  procedure, or function. Don't conflate "stop looping" with "stop
  running this procedure" — SuperBASIC keeps them as two separate
  mechanisms and so do we. **`EXIT FOR` is built** (2026-08-19) — see
  "Implementation status" above for exactly what it does; `REPeat`'s
  own named `EXIT <name>` form is still just this design document.

### Program control: STOP, END, PAUSE

- **`STOP`** halts execution and drops back to the editor, preserving
  program state (variables, position) for inspection — a debugging
  breakpoint, not a normal exit. Matches classic BASIC's `STOP`, which
  terminates execution and returns to command level, keeping the
  program's state intact so it can be examined before continuing or
  editing.
- **`END`** is the deliberate, final program-termination statement.
  Unambiguous alongside `END IF`/`END REPeat`/`END SELect`/`END DEFine`/
  `END WHEN` since those are always followed by another keyword, while
  bare `END` on its own line always means "stop the program."
- **`PAUSE <n>`** waits `n` display frames, or indefinitely for a
  keypress if `n` is 0 — carried over unchanged from the original
  Sinclair BASIC this ROM replaces, rather than reinvented, in keeping
  with the project's "feel authentic while extending it" philosophy.
  **Implemented (2026-08-22)**, via `kernel/interrupt`'s `FRAMES` tick
  counter for `n>0` and a blocking `IO_READ_KEY` for `n=0`.

### CALL — redefined and implemented (2026-08-22)

**Supersedes an earlier design never actually built**: this section
used to reserve `CALL <name>[(<args>)]` for invoking only a named,
`kernel_api.inc`-vetted machine-code routine (never a raw address) —
doc-only, zero code, from before this dialect had `GOSUB`/`RETurn` or
`USR` at all. Once both landed (this same session — see "Bare GOSUB/
RETURN" and "PEEK/POKE/USR/FREE" below), that original need was
already covered from two different directions: `USR(addr)` is the raw-
address escape hatch classic BASIC always used for exactly this, and
`CALL` itself was repurposed as the user's own explicit choice for this
dialect's simplified "stored procedures" — a second spelling of
`GOSUB`, sharing its exact return-address stack and label lookup, so a
procedure is just a label you `CALL` instead of `GOSUB` (`RETurn`
comes back either way). Deliberately NOT the scoped, parameter-taking
`DEFine PROCedure` this doc still describes elsewhere — no `LOCal`
variables, no parameter binding, no per-procedure label scoping; those
remain just this design document's own aspiration, not built.

### DEF FN — minimal numeric form implemented

`DEF FN S(X)=X*X` defines one single-letter, one-parameter numeric function;
`FN S(6)` invokes it in any numeric expression. The definition becomes active
when execution reaches the `DEF` statement. This first bounded form has no
string result, multiple parameters, or recursion. Its parameter is an internal
temporary binding and does not overwrite a BASIC scalar of the same letter.

### PEEK / POKE / USR / FREE — implemented (2026-08-22)

`PEEK(addr)` / `POKE addr,value` / `USR(addr)` are the classic-BASIC raw
escape hatch — a program can touch *any* address, exactly like every
other 8-bit BASIC's own PEEK/POKE/USR always have (see "CALL" above
for how this superseded that keyword's own original, never-built
"only named kernel routines" design). This isn't a loophole in the
"BASIC never
touches hardware/arbitrary memory directly" rule from `kernel/`'s own
architecture doc — that rule is about `basic/` not duplicating or
bypassing *kernel-owned, named* state; an address a BASIC program
computed itself at runtime has no such owner to bypass, so there's
nothing for a `kernel/` API to abstract here.

- **`PEEK(addr)`** reads one byte, `0`-`255`.
- **`POKE addr,value`** writes the low byte of `value` to `addr`.
- **`USR(addr)`** jumps to machine code at `addr`; the routine must end
  with its own `RET`, result in `HL` — same convention real Sinclair
  BASIC's own CALL/USR uses.

**`FREE()`** returns the number of bytes still free in the program
area (`PROG_AREA_MAX - PROG_END`, `kernel/memory`'s own `MEM_FREE_
BYTES`) — the first zero-argument built-in function this dialect has.

### Deliberately not added

`ON <expr> GOSUB label1, label2, ...` / `ON <expr> GOTO label1, label2,
...` — fully redundant with `SELect ON`, and flagged even in VB's own
documentation as obscure legacy syntax. Adding it back would undercut
the reason `SELect ON` exists.

`REMark` (abbreviated `REM`) starts a comment that runs to the end of
the line:

```
REMark this line is ignored by the interpreter
x = 1 : REMark trailing comments are fine too
```

**Implemented so far: bare `REM` only** — matching every other keyword
currently in `basic/basic.asm`, none of which support SuperBASIC-style
optional-lowercase-suffix abbreviation yet (that's a `BASIC_MATCH_ENDIF`-
style compound-keyword mechanism that would need to be built specially,
same as it was for `END IF`). `REM <anything>` is recognized and the
rest of the line ignored outright, regardless of content — `REMark`,
`REM this line is ignored`, and bare `REM` alone all work; only the
*full word* `REMark` typed out does not yet match. A trailing comment
using bare `REM` (`x = 1 : REM ...`) now works too, now that the
statement separator (`:`) is implemented — see "Statement separator"
below. `x = 1 : REMark ...` does NOT work yet, for the same reason
`REMark` alone doesn't — only bare `REM` is currently recognized.

### Statement separator

A colon (`:`) separates multiple statements on one line — **implemented**:

```
x = 1 : y = 2 : PRINT x + y
```

Works inside single-line `IF`'s `THEN` branch too: `IF <cond> THEN
<stmt>:<stmt>...` runs every colon-separated statement, not just the
first. **`:` does NOT substitute for `THEN`** in this project's actual
implementation (unlike an earlier draft of this design note, which
described them as interchangeable, matching SuperBASIC) — single-line
`IF` still requires the `THEN` keyword exactly as it already did; only
what follows `THEN` can now be more than one statement.

A `:` inside a quoted string is just text, never a separator —
`PRINT "a:b"` prints `a:b`. A `:` after `REM` is also just text —
`REM this: still one comment` — `REM` consumes the rest of the line
regardless of what's in it, matching classic BASIC. Empty statements
(a double colon, or a trailing colon with nothing after) are silently
allowed, matching classic BASIC's own leniency: `PRINT 1::PRINT 2` and
`PRINT 1:` both work fine.

A label definition (`loop:`) still must be the *entire* line by
itself — labels do not currently share a line with other statements;
`loop: PRINT 1` is a syntax error, not a label followed by a
statement. See `docs/programmers_reference.md`'s own "Statement
separator" section for why this is a deliberate, low-risk scope
boundary rather than an oversight.

Live keyword bolding while typing only recognizes a keyword at the
very *start* of a line — in `PRINT 1: GOTO loop`, only `PRINT` renders
bold, not `GOTO` after the colon. Purely cosmetic (execution is
unaffected); not yet extended to check after every colon.

### LOCal variables and arrays

Inside a `DEFine PROCedure`/`DEFine FuNction`, `LOCal <name>[,<name>...]`
declares variables (or arrays, combined with `DIM`) that exist only for
that call, instead of the program-wide global they'd otherwise be:

```
DEFine FuNction double(n)
    LOCal result
    result = n * 2
    RETurn result
END DEFine
```

This matters more here than it did for SuperBASIC's flat label space:
we already scoped labels per-procedure (see "Scope" above), and it would
be inconsistent to scope labels but leave every variable global by
default. Without `LOCal`, recursion (a function calling itself) also
isn't safe, since every call would share the same variable storage.
Anything not declared `LOCal` is a program-wide global, same as classic
Sinclair BASIC's behaviour for all variables.

### DIM

`DIM <name>(<size>[,<size>...])` declares an array, global unless paired
with `LOCal` inside a procedure/function:

```
DIM scores(10)
LOCal scores(10)   ' inside a procedure/function: local instead of global
```

### Parameter passing

`DEFine PROCedure`/`DEFine FuNction` parameters are **by value by
default**; an explicit `REF` before a parameter name passes it by
reference instead:

```
DEFine PROCedure increment(REF n)
    n = n + 1
END DEFine
```

This follows where Visual Basic ended up rather than where it started:
VB6/VBA defaulted to by-reference and only later versions (VB.NET)
switched the default to by-value, specifically because by-reference-by-
default caused real bugs — a procedure changing a caller's variable
without anyone at the call site expecting it, and the risk compounding
as procedures call procedures. Starting from by-value-by-default avoids
inheriting that history.

**Arrays are the one exception, and always pass by reference** —
`REF` is implied and cannot be overridden. This isn't a semantic
preference like VB.NET's, it's a memory-budget one: on a 48K machine,
copying a whole array to pass it by value the way ordinary scalars
default to just isn't affordable. A procedure that takes an array
parameter always receives the caller's actual array, full stop.

### Error handling

`WHEN ERRor ... END WHEN` wraps a block of code with an error handler,
rather than jumping to a labelled handler the way classic BASIC's
`ON ERROR GOTO` or VB's `On Error GoTo` do:

```
WHEN ERRor
    OPEN "cassette"
    PRINT "couldn't open device"
END WHEN
```

This was chosen over a `GOTO`-to-label style error handler for
consistency — everything else added since the original "no line
numbers" decision (`IF`/`REPeat`/`FOR`/`SELect ON`, and now this) is a
named or scoped block rather than a jump target, so error handling
follows the same shape instead of being the one exception that still
needs a label. `ERR` and `ERL`-equivalent status (error code / location)
inside the block: TBD once `basic/`'s error model is designed.

## Label table (implementation note for kernel/memory)

Because there are no line numbers to serve as addresses, `kernel/memory`
must maintain a **label table per scope**: name → program position, one
small table for the top-level program body and one per `DEFine
PROCedure`/`DEFine FuNction`, rebuilt (or incrementally updated) whenever
that scope is edited. Per-scope rather than one whole-program table,
following the label-scoping rule above — this bounds the table size by
"labels in one procedure," not "labels in the whole program," and means
editing inside one procedure never has to touch another procedure's
table. This is the mechanism that replaces `EDITOR_RENUMBER` — instead of
rewriting numeric targets after an edit, the label table for the affected
scope is just re-resolved, and any `GOTO`/`GOSUB`/`RESTORE` that
references a label by name never needs to change at all, edit or no edit.

This also settles the open question left on `EDITOR_BLOCK_DELETE`: before
deleting a range, check the *enclosing scope's* label table for any label
*defined inside* the range that's referenced by a `GOTO`/`GOSUB`/
`RESTORE` *outside* the range but still within that same scope (a
cross-scope reference is already impossible — see "Scope" above). If any
exist, refuse the delete and report which references would break — the
same non-destructive guarantee originally designed for `EDITOR_RENUMBER`,
just implemented against the label table instead of line numbers.

## I/O, screen, and built-in functions

Mimicking SuperBASIC's own keyword set (per the SBASIC/SuperBASIC
Reference Manual's keyword index) wherever it fits the TS2068's hardware.
One deliberate deviation, flagged up front: SuperBASIC's screen model is
built on the QL's bitmapped, multi-window `WINDOW`/`CURSOR` system, which
the TS2068 doesn't have. For screen output this ROM follows the
*original* Sinclair BASIC model instead (`AT`/`TAB` addressing a single
32x24 text screen) — same reasoning as `PAUSE` earlier: mimic SuperBASIC
where the hardware matches, mimic the machine's own original BASIC where
it doesn't.

### Screen output

| Keyword | Purpose |
|---|---|
| `PRINT` | Output text/values; `;` and `,` separators control spacing, matching classic BASIC |
| `CLS` | Clear screen (implemented) — resets the print cursor to row 0 too, so output after a mid-program `CLS` starts from the top |
| `AT <row>,<col>` | Position the next `PRINT` (classic Sinclair model, not SuperBASIC's `CURSOR`) — implemented (row clamped to 0-23, column masked to 0-31; only affects the single `PRINT` that immediately follows — the next line resets back to the left margin) |
| `TAB <col>` | Move to a column on the current line — implemented (sets column only, leaves row untouched; same one-`PRINT`-only lifetime as `AT`) |
| `INK <n>` / `PAPER <n>` / `BORDER <n>` | Foreground/background/border colour (all 0-7, implemented) — `INK`/`PAPER` set the current print colours (via `BASIC_COMPUTE_PRINT_ATTR`, applied by `PRINT` through `kernel/graphics`'s new `GFX_PRINT_STRING_ATTR`); `BORDER` sets the screen edge (`GFX_SET_BORDER`) |
| `FLASH <n>` / `BRIGHT <n>` / `OVER <n>` / `INVERSE <n>` | Text attributes — all implemented as 0/1 state. `INVERSE 1` swaps the current ink/paper at print time without changing their stored values; `BRIGHT` sets attribute bit 6; `OVER 1` XOR-plots subsequent `PRINT` glyphs onto the existing bitmap so printing the same text twice at the same position restores the background. |
| `CSIZE <n>` | Character size/scale — kept from SuperBASIC; useful for the extended graphics modes this ROM targets |

### Graphics

Another deliberate deviation from the "mimic SuperBASIC where the hardware
matches" default above: `LINE` takes **absolute** coordinates for both
endpoints, QL SuperBASIC style, not classic Sinclair BASIC's relative-only
`DRAW` (which always plots from wherever `PLOT` last left off). This one
genuinely is a QL-inspired improvement rather than a hardware-forced
choice — absolute coordinates are strictly easier to reason about, and
nothing about the TS2068's screen hardware requires the relative-only
model; classic `DRAW` only works that way because that's how the real
Sinclair ROM happened to implement it.

Pixel coordinates: `x` is 0-255 (the screen is exactly 256 pixels wide —
the full byte range is already the whole valid range, no clamping is
needed or applied). `y` is 0-191, clamped the same way `AT`'s row is
(192 isn't a power of 2 either) — an out-of-range `y` pins to the last
valid row rather than being rejected or reading out of bounds.

Both `PLOT` and `LINE` color the covering 8x8 attribute cell(s) using the
*current* `INK`/`PAPER`/`FLASH`/`INVERSE` state (the exact same
`BASIC_COMPUTE_PRINT_ATTR` computation `PRINT` already uses — screen
hardware is one shared bitmap+attribute area, so text and graphics
genuinely share color state, not a coincidence) and respect `OVER` (the
first real consumer of that sysvar — sets the pixel outright when `OVER`
is 0, XOR-toggles it when `OVER` is 1, same semantics real Sinclair BASIC
gives `OVER` for `PLOT`/`DRAW`/`CIRCLE`, not just `PRINT`).

| Keyword | Purpose |
|---|---|
| `PLOT <x>,<y>` | Set one pixel — implemented, via `kernel/graphics`'s `GFX_WRITE_PIXEL` |
| `LINE <x0>,<y0> TO <x1>,<y1>` | Draw a line between two points — implemented, via `kernel/graphics`'s `GFX_LINE` (Bresenham's algorithm, integer-only) |
| `BLOCK <x0>,<y0> TO <x1>,<y1>` | Optional 168-byte loadable extension. Preserves the former resident syntax, including reversed-corner normalization |
| `CIRCLE <x>,<y>,<r>` | Draw a circle outline — implemented, via `kernel/graphics`'s `GFX_CIRCLE` (midpoint circle algorithm, integer-only). A radius that pushes the circle past the screen edge is simply clipped there, same as any other out-of-range point |
| `FILL <x>,<y>` | Flood fill the connected region from that seed point — implemented, via `kernel/graphics`'s `GFX_FILL`. 4-connected, using an explicit bounded stack (2048 entries) rather than recursion; a large enough enclosed region can exhaust it, at which point the fill simply stops expanding further rather than crashing — see the programmer's reference for the real numbers behind that size |
| `POINT(x,y)` | Function — `1` if that pixel is currently set, `0` if not; implemented, via `kernel/graphics`'s `GFX_READ_PIXEL`. QL-named deliberately (`GFX_READ_PIXEL` is the write-side's read-back counterpart, `PLOT` stays the imperative Sinclair-flavored write) |
| `ATTR(row,col)` | Function — reads the normal 32×24 screen's attribute byte through the shared bounded attribute-address primitive; returns `0` for an out-of-range row or column |
| `CPLOT <cx>,<cy>` | Optional 132-byte loadable extension. It registers the natural syntax and draws a coarse 2x2-per-cell block; `cx` is clamped to 0-63 and `cy` to 0-47. Without the module, CPLOT is a syntax error |
| `MODE <n>` | Switch video mode — implemented, via `kernel/graphics`'s `GFX_SET_MODE`. `n` is `0` (Normal) or `1` (High Resolution Graphics — same 256x192 bitmap, finer 8x1 attribute resolution); anything else is a runtime `INVALID MODE` error, not silently clamped |
| `ULAPLUS <n>` | Enable (`1`) or disable (`0`) the ULAplus palette extension. Other values produce `INVALID ARGUMENT`. |
| `PALETTE <index>,<value>` | Write ULAplus palette register 0-63 with a value from 0-255 in `GGGRRRBB` format. Out-of-range values produce `INVALID ARGUMENT`. |

ULAplus is deliberately program-scoped. The palette remains active while a
program runs, but every return from `RUN`—normal completion, `END`/`STOP`, a
runtime error, or `BREAK`—disables ULAplus before the editor is shown again.
Palette register values remain programmed, so a later `ULAPLUS 1` can reuse
them without issuing the `PALETTE` statements again.

`CIRCLE` (like `PLOT`/`LINE`) colors its pixels using the
current `INK`/`PAPER`/`FLASH`/`INVERSE`/`OVER` state — see the shared
paragraph above. `CPLOT` does too.

**Mode 2 (64-Column) and its original TS2068 palette selector were removed
2026-08-20** — real overhead versus value: a genuinely wider pixel
space (512x192 instead of 256x192, spanning two physical display
files) with no per-pixel color at all, but it added roughly 750-950
bytes of Home ROM across `kernel/graphics`/`basic.asm` (six dedicated
kernel routines plus a mode-dispatch branch in every statement that
touched it) for a feature most programs wouldn't use, at the direct
expense of ROM budget for core language features (procedures, string
variables, SOUND). `MODE`'s validation narrowed back to 0-1. The current
two-argument `PALETTE` statement is the later ULAplus register interface.

Not yet built: true Dual Screen mode. Everything else from the wider graphics design discussion — `COPY`
(rectangle blit), `SCREEN`/`SHOW` (dual-screen flip), `WAIT FRAME`
(vblank sync), sprite-style save/restore + `HIT()` collision, and
`SCALE` — is deliberately not built yet; this round covered `GFX_
PIXEL_ADDR_SETUP`/`GFX_WRITE_PIXEL`/`GFX_PLOT_CLIPPED` (the shared
pixel-level foundation) plus `PLOT`/`LINE`/`POINT`/`BLOCK`/`CIRCLE`/
`CPLOT`. `GFX_RECT_SAVE`/`RESTORE` (the planned shared
primitive behind `COPY` and sprite-style save/restore) is still just
a design note, not code.

### Sound

| Keyword | Purpose |
|---|---|
| `BEEP <duration>,<pitch>` | Square-wave tone via the speaker — implemented (2026-08-22), see below |
| `SOUND <register>,<data>` | Write directly to the AY-3-8912 PSG — implemented (2026-08-22), see below |

**`BEEP <duration>,<pitch>` — implemented, but deliberately NOT the
real command's grammar (2026-08-22)**. Real classic BASIC's `BEEP`
takes a musical note number and a duration in seconds, converted to a
precise frequency through the floating-point calculator's own note
table. That conversion is a bigger undertaking than the rest of this
feature combined, and this project's test environment has no audio
output to verify a note-to-Hz conversion against — so both parameters
here are raw integers instead: `duration` is a plain count of full
waveform cycles, `pitch` is the per-half-cycle busy-wait length (bigger
= slower toggling = a lower pitch). See `docs/programmers_reference.
md`'s `kernel/sound` section for the hardware mechanism and the full
scope-reduction reasoning.

**`SOUND <register>,<data>` — implemented, and this one IS the real
command (2026-08-22)**: confirmed from the ROM disassembly's own
`SOUND` routine — writes `register` to port `$F5` and `data` to port
`$F6` (the AY-3-8912's address/data register pair), register validated
1-16 at runtime (0 or 17+ raises `INVALID SOUND REGISTER`). One
scope reduction from the authentic grammar: the real ROM accepts a
semicolon-chained list of pairs on one line (`SOUND 8,15;0,200;...`);
this dialect doesn't recognize `;` as statement syntax anywhere yet, so
only a single pair per `SOUND` is accepted — chain multiple with this
dialect's own `:` statement separator instead (`SOUND 8,15:SOUND
0,200`), which already gives the identical effect. See `docs/
programmers_reference.md`'s `basic/` "BEEP / SOUND" section for the
full implementation writeup (including a cross-EXROM-boundary bug
caught and fixed before it ever shipped).

### Input

| Keyword | Purpose |
|---|---|
| `INPUT` | Read a line of input into a variable, classic BASIC style |
| `INKEY$()` | Read one keypress without waiting — implemented (2026-08-22), see below |

`INPUT` accepts numeric and string targets, with an optional literal prompt:
`INPUT "Age: ";A` or `INPUT "Name: ";A$`. The prompt is not yet a general
string expression.

**`INKEY$()` — implemented, returns a real string (2026-08-22)**:
called with empty parens, `INKEY$()`, matching this dialect's own
zero-argument-function convention (`FREE()`/`PI()`), not real classic
BASIC's bare `INKEY$`. Returns the pressed key as a one-character
string, or `""` if nothing is currently pressed, via the same non-
blocking `kernel/io` routine (`IO_READ_KEY_NONBLOCK`) `IO_READ_KEY`/
`PAUSE 0` already use, just without their blocking wait. See the
"String functions" section below for the current, string-returning
form — this originally shipped as a plain-integer function (comparing
against a numeric ASCII code, `IF INKEY$()=81 THEN ...`) before real
string literals/comparison existed to support the natural
`IF INKEY$()="Q" THEN ...` form; that upgrade is now done.

**`STICK(device)` — implemented (2026-08-22)**: reads a joystick
through the AY-3-8912's I/O port, confirmed from the real ROM
disassembly's own `STICK` command — `device` is 1 or 2 (two joystick
ports); anything else raises `INVALID ARGUMENT` (the real ROM's own
error text) **at runtime**, not at check-time — a variable argument's
value isn't reliably known during the static whole-program check pass
(see `docs/programmers_reference.md`'s own writeup for a real false-
positive bug this caused and fixed before shipping). Device 1 returns
a 4-bit direction value; device 2 only returns a single bit — a
confirmed real hardware asymmetry, not a design choice. Not verifiable
against actual joystick movement in this project's own test
environment (no way to inject joystick input into the emulator used
for testing) — only the mechanism itself (grammar, the port read
completing, the range check) is verified.

### Direct/program-management commands

| Keyword | Purpose |
|---|---|
| `LOAD` / `SAVE` | Tape/storage program transfer — **implemented** with stock TS2068/Sinclair 17-byte header and two-block framing around this ROM's native (non-Sinclair-tokenized) program payload; see `docs/tape_compatibility.md`. `MERGE` remains separate from plain `LOAD`. |
| `LIST` | List the program — implemented as an immediate command (typed alone, like `RUN`/`NEW`): jumps the edit view to the top of the program (index 0), same "always-visible full-screen editor" view this ROM already uses, not a separate listing engine or output mode |
| `NEW` | Clear the current program and all variables (implemented) — an immediate command like `RUN`, not a program statement; resets to the same fresh state as cold boot |
| `DELETE <start>,<end>` | Delete a range of the program — implemented as `DELETE <start-line>,<end-line>` (1-based, inclusive; the first line in the listing is `1`, matching how anyone reads a program top to bottom — there are still no line NUMBERS stored anywhere, this is just how the range is typed), routing to `EDITOR_BLOCK_DELETE`. Any problem (malformed numbers, missing comma, a typed `0`, start>end, either index out of range) leaves the program unchanged and falls through to being tokenized as ordinary text, same fallback every malformed immediate command already has |
| `EDIT <label>` | Enter the full-screen editor on a specific label — implemented as an immediate command; rebuilds the label table fresh (so it works even before the program has ever been `RUN`), then jumps the edit view straight to that label's line |
| `MERGE` | Merge a loaded program into the current one — **not implemented**: `LOAD` now exists (see above) but replaces the current program outright rather than merging into it; a genuinely separate command from plain `LOAD`, still not built |

### String variables (2026-08-22)

Classic Sinclair `$`-suffix naming (`A$`), not a real string TYPE in
the language sense — `A$` and the numeric `A` are two entirely separate
storage locations that happen to share a letter, exactly like real
Sinclair BASIC's own simple-variable/string-variable split. 26 slots
(`A$`-`Z$`), each a **fixed 31-character maximum** — no heap, no
allocator; a design choice made explicitly to keep this affordable
(see `docs/programmers_reference.md`'s `basic/` "String scalars"
section for the RAM-budget reasoning behind fixed slots over a
compacting heap).

**Implemented**: assignment (`A$ = "literal"`, `A$ = B$`, or a `+`-
chain of either — see concatenation below), `PRINT A$`, and `=`/`<>`
comparison in `IF` (`IF A$ = "Q" THEN ...`, `IF A$ <> B$ THEN ...`) —
this is what finally gives `INKEY$()` a real string-comparison path,
closing the gap that routine's own scope note flagged. `<`, `<=`, `>`,
`>=` are **not** supported for strings — deliberately narrow, matching
`INKEY$`'s own established scope discipline rather than picking an
arbitrary ordering nobody asked for.

A literal longer than 31 characters is silently truncated, not
rejected — matching the exact precedent `PRINT "..."` already set for
its own literal handling (see that routine's own long-standing `TODO`
comment), not a new inconsistency introduced here.

**Concatenation — implemented (2026-08-22)**: `A$ + B$`, and longer
chains (`A$ + " " + B$ + "!"`), anywhere a string expression is
expected (assignment, comparison). Same 31-byte cap as everything
else here — once the combined result reaches it, further terms are
still parsed (so a too-long expression is still valid grammar, not a
syntax error) but stop contributing bytes, the identical "truncate,
don't error" rule single literals already followed. Cost ~50 bytes of
Home ROM, confirming the ~40-60 byte estimate made once string
scalars' own real cost was known — see `docs/programmers_reference.
md`'s `basic/` "String concatenation" section for the implementation.

**Arrays — implemented**: `DIM name(n)` declares a numeric array of `n`
zero-initialized elements, and `DIM name$(n)` declares a string array
whose elements hold up to 31 characters. Both use indices **0 to n-1**
(0-based — a deliberate simplification, not real Sinclair BASIC's
1-based convention). `name(i)` reads or (as an assignment target)
writes one element — `A(3) = 5`, `B = A(3) + 1`, even nested (`A(B(0))
= 99`). A name can only be `DIM`'d once per `RUN` (re-`DIM`ing without
a fresh `RUN` raises `ARRAY ALREADY DIMENSIONED` — real Sinclair BASIC
has the same restriction, for the same reason: supporting a clean
re-`DIM` would need a real reallocator). Using an array before `DIM`ing
it raises `ARRAY NOT DIMENSIONED`; an out-of-range index raises
`SUBSCRIPT OUT OF RANGE` (both real classic-BASIC error messages).

Unlike scalars (`VAR_TABLE`/`STR_TABLE`, fixed tables sized for all 26
possible letters whether used or not), arrays live in a genuinely
dynamic region — appended after program text as they're `DIM`'d, reset
each `RUN` — so capacity is limited only by free RAM (`FREE()`
reflects it), not a fixed slot count or per-array size cap. See
`docs/programmers_reference.md`'s `basic/` "Numeric arrays" section
for the full design (including a real nested-scratch-clobbering bug
found and fixed before this ever reached the emulator).

**`DIMN(name)` — implemented (2026-08-22)**: returns an array's
declared size. Use `DIMN(A)` for numeric arrays and `DIMN(A$)` for
string arrays. String arrays are limited to 31 elements, each stored
as the same 32-byte length-prefixed value used by scalar strings.

**Not yet implemented**: Multi-dimensional arrays (`DIM
name(rows,cols)`) were built and verified in full the same day as
`DIMN`, then archived for Home ROM budget once actually measured — see
`docs/programmers_reference.md`'s "Multi-dimensional arrays (archived)"
section for the complete design if this is ever worth reviving.

### String functions (2026-08-22)

**Implemented** — 8 string-returning functions plus `LEN`/`CODE`/`VAL`/`INSTR`
(number-returning, string-argument), all usable anywhere a string or
number expression is expected: assignment, `PRINT`, `IF` comparison,
even nested inside each other (`UPPER$(LEFT$(A$,3))`,
`LEN(UPPER$(A$))`).

| Function | Purpose |
|---|---|
| `CHR$(n)` | The one-character string with ASCII code `n` (0-255) — `INVALID ARGUMENT` outside that range |
| `STR$(n)` | `n` formatted as a decimal string |
| `UPPER$(s$)` | `s$` with `a`-`z` case-converted to `A`-`Z`; other bytes untouched |
| `LOWER$(s$)` | The reverse of `UPPER$` |
| `LEFT$(s$,n)` | The first `n` characters of `s$` — `n<0` clamps to empty, `n` past the end clamps to the whole string |
| `RIGHT$(s$,n)` | The last `n` characters of `s$` — same clamping as `LEFT$` |
| `LEN(s$)` | The length of `s$`, 0-31 |
| `CODE(s$)` | The ASCII code of `s$`'s first character, 0 for an empty string |
| `VAL(s$)` | Parses `s$` as a decimal integer, tolerant of a leading `-`; stops at the first non-digit rather than erroring; `0` for anything unparseable |
| `INSTR(haystack$,needle$)` | 1-based position of the first match; `0` when absent; an empty needle returns `1` |

`INSTR` was restored on 2026-08-30 after DEF-FN parser consolidation made
room in Home ROM. `FILL$` remains unimplemented. See `docs/
programmers_reference.md`'s `basic/` "String functions" section for the
earlier implementation history and parser bugs found by live emulator tests.

**`INKEY$()` upgraded to a real string (2026-08-22)** — supersedes
the plain-integer version described below. Called with empty parens,
`INKEY$()`, same zero-argument convention as `FREE()`/`PI()`. Returns
the pressed key as a one-character string, or `""` if nothing is
currently pressed — via the same non-blocking `kernel/io` routine
(`IO_READ_KEY_NONBLOCK`) the original integer version used. Now that
real string literals and comparison exist, the natural form works
directly: `IF INKEY$() = "Q" THEN ...`.

### Math functions

`ABS`, `SGN`, `SQR`, `SIN`, `COS`, `TAN`, `EXP`, `LN`, `LOG10`, `PI`,
`INT`, `MOD`, `DIV`, `RND`, `RANDOMISE`, `RAD`, `DEG` — again the shared
core between SuperBASIC and classic Sinclair BASIC.

**Implemented so far**: `ABS(x)`, `SGN(x)`, `MOD(x,y)`, `SQR(x)`,
`DIV(x,y)`, `INT(x)`, `RND(x)`, and `SIN(x)`. `ABS`/`SGN` proved out the
single-argument function-call grammar (`BASIC_TRY_EVAL_FUNCTION` in
`basic/basic.asm`, see `docs/programmers_reference.md`'s `basic/`
section) via `kernel/math`'s `MATH_ABS16`/`MATH_SGN16`; `MOD(x,y)` was
this language's first two-argument function, via `MATH_MOD16`
(remainder takes the dividend's sign, truncating convention —
`-17 MOD 5 = -2`, matching `-17/5 = -3`); `DIV(x,y)` reuses the
two-argument path `MOD` proved out, but needed no new kernel routine
at all — it's a thin wrapper directly over the already-verified
`MATH_DIVIDE16` (quotient only, same truncating-toward-zero convention
`-17/5 = -3`); `INT(x)` is a true no-op — every value in this
pure-integer BASIC is already its own `INT()`, so it needed no kernel
routine either, just a table entry for SuperBASIC-syntax compatibility;
`RND(x)` returns a pseudo-random value in `[0, x-1]` for a positive
`x` (`x<=0` returns 0), via the new `MATH_RND16` — a 16-bit
maximal-length LFSR seeded on first use from the Z80 `R` register (see
`docs/programmers_reference.md`'s `kernel/math` section for the full
story, including a real dead-end or two while finding correct LFSR
taps). `RND`'s seeding step is hardware-timing-dependent and — unlike
every other function above — can't be fully verified by simulation;
only its deterministic LFSR/range-scaling logic could be.
**`RANDOMISE <n>` — implemented (2026-08-22)**, as a statement (via
`BASIC_EXEC_STATEMENT_CONTENT`, not the expression/function mechanism —
this dialect's first "explicit reseeding" statement, so it needed the
statement-side grammar rather than function-call parsing).
`RANDOMISE 0` resets `RND`'s LFSR (`kernel/math`'s `RND_STATE`) back to
its own "never seeded" sentinel, so the very next `RND()` reseeds from
real hardware entropy (the Z80 `R` register) exactly as a cold boot
would; `RANDOMISE <n>` for `n<>0` becomes the new deterministic seed
directly — useful for reproducible "random" sequences (confirmed via a
real emulator test: `RANDOMISE 5` followed by `RND(1000)`, then
`RANDOMISE 5` again followed by another `RND(1000)`, produced identical
values both times). Everything else in this list remains unimplemented.

**`SQR(x)` and `SIN(x)`: "function-result float" (2026-08-22)** — this
dialect is still integer-only everywhere else (no float literal
syntax, `VAR_TABLE` still 2 bytes/variable), but these two functions
now compute a true float result through `rom/exrom_calc.asm`'s
calculator engine and `PRINT` it with real fractional digits when the
whole printed expression is exactly one bare call — `PRINT SQR(2)`
shows `1.4142`, not the old `MATH_SQRT16`-only `1`. Composed into a
larger expression (`x = SQR(2)+1`, `PRINT SQR(2)+1`), both still fall
back to the same truncated int as before — this is a PRINT-time
display upgrade for these two specific functions, not a numeric-type
change to the language. `SIN(x)` takes **degrees**, not radians (no
float literals means an integer number of radians would almost never
land near a recognizable angle). See `docs/programmers_reference.md`'s
`basic/` section for the full design writeup (why only these two
functions, the sysvars involved, the two real bugs a visual smoke test
caught before this shipped). `COS`/`TAN`/`EXP`/`LN`/etc. remain
unimplemented but are natural follow-ups reusing the same calculator
infrastructure (`PI_CONST`, the float pack/unpack engine) — no longer
blocked on "would need a fixed-point or float representation this
project hasn't adopted," since that representation now exists,
scoped deliberately narrowly (function results only, not a general
numeric type) to fit Home ROM's own tight budget.

**`PI()`, `RAD(x)`, `DEG(x)` — implemented (2026-08-22)**, reusing
SIN's exact "function-result float" machinery: `PI()` is this
dialect's first zero-argument built-in besides `FREE()` (`PRINT PI()`
shows `3.1415`); `RAD(x)` converts degrees to radians (`x*pi/180`) and
`DEG(x)` converts radians to degrees (`x*180/pi`), the same multiply/
divide pair `SIN`'s own degrees->radians step already used, just
factored out as callable values instead of feeding straight into a
Taylor series. All three fall back to a truncated int in a composed
expression, same as `SQR`/`SIN`. Confirmed correct against hand-
computed expected values in a real emulator test: `PI()` → `3.1415`,
`RAD(90)` → `1.5707`, `DEG(1)` → `57.2957`.

Building these surfaced (and fixed) a real, previously-latent bug —
not in `PI`/`RAD`/`DEG` themselves, but in `kernel/bank`'s EXROM paging
primitives, which every "function-result float" built-in (including
the already-shipped `SIN`) depends on via the calculator engine. See
`docs/programmers_reference.md`'s basic/ section ("PI/RAD/DEG and a
real EXROM-paging reentrancy bug") for the full story; short version:
the whole-program/live-typing checker runs with EXROM already paged
in, and any built-in that touches the calculator engine (`CALC_PUSH_
PI_HOME` etc.) used to page EXROM back OUT again internally, unmapping
it out from under the checker's own still-in-flight call chain —
`kernel/bank/bank.asm`'s `BANK_PAGE_EXROM_IN`/`_OUT` are now nesting-
safe (`BANK_EXROM_DEPTH`), so this affects every current and future
caller, not just these three functions.

### Arrays

`DIM` (declared earlier) plus `DIMN` — both implemented (2026-08-22),
see the "Numeric arrays" note above. `DIMN(name)` returns an array's
declared size, useful for writing procedures that operate on an array
without hard-coding it. SuperBASIC's own `DIMN` takes a second "which
dimension" argument, relevant for multi-dimensional arrays — this
dialect's own multi-dimensional support was built, verified, and then
archived for Home ROM budget (see `docs/programmers_reference.md`'s
"Multi-dimensional arrays (archived)" section), so `DIMN` stayed
single-argument: with only one dimension possible, there's nothing
left to ask "which" about.

### Open questions
- Exact label-table storage format and size budget (ties into
  `docs/memory_map.md`'s "Open questions" section) — now scoped per-
  procedure rather than whole-program, which should make this easier to
  pin down.
- Error status inside `WHEN ERRor` blocks — an `ERR`/`ERL`-style pair
  (error code, location) or something else; needs `basic/`'s error model
  designed first.
- Numeric type suffix (`%` for integer, as SuperBASIC has, vs. the
  original Sinclair BASIC's floating-point-only numbers) — not decided;
  affects performance on Z80 enough to be worth a real decision rather
  than defaulting either way.
- Exact `PRINT`/`INPUT` separator semantics (`;`, `,`, trailing `;`
  suppressing the newline) — needs pinning down against original
  Sinclair BASIC's rules specifically, once `basic/`'s I/O layer design
  starts.
- **Immediate ("direct mode") execution of an ordinary statement,
  without adding it to the stored program** — e.g. typing `CLS` alone
  to clear the screen right now, the way `RUN`/`HELP`/`NEW` already
  work, but for statements in general, not a fixed hardcoded list.
  QL SuperBASIC solves this with its line numbers: a line typed WITH a
  leading number is stored into the program, a line typed WITHOUT one
  executes immediately — that's the actual mechanism behind SuperBASIC
  letting `CLS` (and everything else) work both ways. This project
  deliberately has no line numbers (see "Program structure" above), so
  that exact mechanism isn't available — a typed line has nothing left
  in the leading-number slot to signal "run this now" instead of
  "store this." Candidate idea, not yet designed or built: a leading
  marker character (e.g. `!CLS`) meaning "execute immediately, don't
  store" for any statement, rather than special-casing individual
  keywords the way `RUN`/`HELP`/`NEW` are today. For now, `CLS` (and
  every other statement except `RUN`/`HELP`/`NEW`) stays program-only —
  typed alone it's added to the stored program, not run immediately;
  it only executes when the program is `RUN`.

# Storage and ROM extension plan

## Current constraints

The pre-extension DEF-FN build had 3 Home-ROM bytes and 75 EXROM bytes free.
After the CPLOT gateway, DEF-FN parser consolidation, and `INSTR`, the build
leaves 21 Home-ROM bytes and 35 EXROM bytes. The dynamic BASIC pool is `$8432-$BFFF`
(15,310 bytes). Storage already writes the
stock 17-byte header shape: type, ten-character name, length, autostart, and
program-length fields. Extending that header is unnecessary for the first set
of features and would reduce compatibility.

## Recommended storage sequence

1. **Program autorun**
   - Syntax: `SAVE "name" LINE expression`.
   - Store the resolved target in the existing autostart field; retain `$8000`
     (`STORAGE_NO_AUTOSTART`) for ordinary program saves.
   - LOAD must finish validation and installation before dispatching the saved
     target. An invalid target leaves the program loaded and reports an error.

2. **Raw/data-only blocks**
   - Syntax: `SAVE "name" CODE start,length` and
     `LOAD "name" CODE [start]`.
   - Use the stock code-file header type. Reject wraparound, ROM destinations,
     and ranges crossing reserved OS memory.
   - If LOAD omits `start`, use the saved address. An explicit address relocates
     the block after validating its complete range.

3. **Typed BASIC array data**
   - Candidate syntax: `SAVE "name" DATA A()` / `LOAD "name" DATA A()` and the
     string-array equivalent.
   - Use the stock numeric-array and character-array header types, preserving
     dimensions and elements rather than the complete variable pool.
   - Implement after CODE; array lookup, allocation, shape checking, and
     replacement semantics make this materially larger.

4. **Convenience and inspection**
   - `SAVE/LOAD "name" SCREEN$` can be thin CODE shorthands for display RAM.
   - `VERIFY "name"` can reuse the receiver's existing verify mode.
   - Defer `CAT` until its tape-advance and UI behavior are clearly specified.

## Other ROM additions to assess

- **`INSTR(haystack$,needle$)`** is the highest-priority missing string
  function. It was previously implemented far enough to establish the required
  two-simultaneous-string argument path, then removed solely for ROM budget.
  The retained four-slot `STR_FUNC_POOL` is already sufficient. Reintroduce it
  only after DEF-FN parser consolidation, with a fresh assembler-measured cost
  and tests for empty strings, no match, boundary matches, and nested string
  expressions.
- **`FILL$(pattern$,length)`** remains the next string-function candidate. It
  should repeat `pattern$` to the requested result length, with explicit empty-
  pattern, zero-length, maximum-length, and overflow behavior. Implement it
  after `INSTR`; the two functions together previously consumed 113 Home-ROM
  bytes of dispatch and argument-parsing code before they were dropped.
- **Prompted `INPUT`** should extend the existing EXROM-resident numeric/string
  input statement, initially as `INPUT "prompt"; variable`. Reuse the normal
  string-expression evaluator if its banked callback cost remains small;
  otherwise accept a string literal in the first version. Preserve the current
  bounded numeric and 31-character string input behavior. Test literal and
  empty prompts, numeric and string targets, screen-row advancement, malformed
  separators, and maximum-length input.
- **Two-dimensional numeric arrays** are a viable restored feature rather than
  a new design exercise. The prior `DIM A(rows,cols)`, two-index read/write,
  bounds checking, subscript-count validation, and `DIMN(A,dimension)` version
  was fully emulator-verified before being archived for ROM budget. Restore it
  from the documented record format and shared-parser design after the smaller
  requested language/storage features, then remeasure against the post-CPLOT
  layout. Keep string arrays one-dimensional in the first restoration unless
  their additional cost is demonstrated to be negligible.
- **`DEF FN`** is the highest-priority missing general BASIC feature. Proposed
  minimum syntax: `DEF FN name(param)=expression`, invoked as
  `FN name(argument)`. Reuse the numeric expression evaluator and existing
  scalar representation, but do not describe this as reusing CALL's parameter
  machinery: today's `CALL` is only a `GOSUB <label>` alias and has no argument
  binding. A correct implementation still needs definition lookup, temporary
  parameter binding and restoration, invocation parsing, checker grammar,
  recursion/depth policy, and duplicate/missing-definition errors. Start with
  one numeric parameter and numeric return; multiple parameters and string
  functions are separate expansions.
- Error trapping/resume and a program-metadata command need separate exact ROM
  estimates before ranking them against storage work.
- Reconsider the archived multi-dimensional arrays only after remeasuring their
  cost against the current 241/177-byte ROM budgets.
- A storage-detail command could expose type, length, address, and autorun data
  already present in the header.
- Any editor addition must carry an exact insert/scroll regression following
  the Shift+Enter precedent.

## Loadable BASIC extensions

Removing a specialist command need not make it permanently unavailable. This
interpreter matches statement keywords directly from stored ASCII text, so a
small ROM-resident extension gateway could consult a registered RAM table before
the normal checker or executor reports `SYNTAX ERROR`. No tokenized-program
format change is required.

The minimum safe registry entry should contain a keyword name, a grammar-shape
descriptor or non-executing checker callback, and an execution callback. Prefer
standard grammar descriptors for common shapes (no arguments, one numeric
expression, two comma-separated numeric expressions, string plus numeric) so
live typing and whole-program checking never have to execute arbitrary module
code. A module needing custom grammar may supply separate check and execute
callbacks under an explicit ABI.

The proof uses the fixed `$F400-$F5FF` upper-RAM window rather than changing the
compile-time `$C000` BASIC-pool ceiling. Never place persistent extension code
in storage/FILL transient scratch or in a bank that disappears during EXROM
paging. The 121-byte CPLOT module leaves `$F479-$F5FF` unused; the whole window
still leaves over 2 KiB below the initial stack pointer. A generalized allocator
remains deferred pending a new stack measurement with the window reserved.

Expose a compact, versioned ROM service table rather than allowing modules to
depend on incidental internal addresses. Initial services should cover numeric
expression parsing, comma/end validation, error reporting, current graphics
attributes, and stable graphics primitives. Keyword highlighting may remain
optional; execution and static checking are the compatibility requirements.

Removed resident `CPLOT` is now the proof extension: its 121-byte RAM module
exercises two numeric arguments plus graphics output. The single-slot gateway
costs 116 Home and 24 EXROM bytes; removing resident CPLOT recovered 244 Home
and 10 EXROM bytes, a net gain of 128 Home at a cost of 14 EXROM.
Until `LOAD ... CODE` exists it can be installed by a small BASIC loader; CODE
loading later provides the natural tape distribution mechanism. Measure the ROM
gateway cost before committing to this architecture—the gateway must remain
materially smaller than the commands it lets the base ROM shed.

## Preliminary fit review

These are planning ranges from the current call paths, not byte-exact promises.
Each accepted feature still needs an assembler-built spike and a final
Home/EXROM delta. Available production padding is 241 Home bytes plus 177 EXROM
bytes; those budgets are separate and cannot be freely combined.

| Addition | Preliminary ROM cost | Current fit assessment |
|---|---:|---|
| Program autorun (`SAVE ... LINE`) | ~70-120 Home, ~20-50 EXROM | Likely fits alone; best first storage feature |
| Minimal numeric, one-argument `DEF FN` | **238 Home, 102 EXROM measured** | Implemented spike; fits but leaves only 3 Home/75 EXROM, so consolidation is required before another command |
| `INSTR(haystack$,needle$)` | Implemented; current build includes its two-string parser and search semantics | Complete and covered by `tests/instr.txt` |
| `FILL$(pattern$,length)` | Exact individual cost not yet isolated; shares the prior 113-Home-byte total | Size after `INSTR`; lower priority and cannot fit the current 3-byte Home remainder |
| Prompted `INPUT "text"; A` / `A$` | Not yet measured; expected to be a relatively small EXROM-heavy extension | Strong candidate after `INSTR`; builds on the existing EXROM input engine and adds no keyword |
| Two-dimensional numeric arrays | Prior complete build was ~26 bytes over Home when Home-resident, or ~69 bytes over EXROM when moved there, under the then-current layout | Reassess after CPLOT/gateway; the measured 128-byte net Home recovery makes the shared-parser design plausible but tighter than first estimated |
| Raw `CODE` SAVE/LOAD | ~180-300 Home, ~80-150 EXROM | Borderline alone; unlikely to coexist with `DEF FN` in current padding without relocation/savings |
| `SCREEN$` shorthand after CODE | ~25-60 total | Likely fits once CODE exists |
| `VERIFY` | ~50-100 total | Likely small because receiver verify mode already exists, but command/status paths remain |
| Typed numeric/string-array `DATA` | ~300-550 total | Does not safely fit with the higher priorities in current padding |
| Header/storage detail command | ~100-180 total | Possible, but lower value than autorun/DEF FN/CODE |
| `CAT` | Unknown, likely >200 | Defer until semantics and transport behavior are specified |
| RAM BASIC-extension gateway | **116 Home, 24 EXROM measured**; CPLOT module is 121 RAM bytes | Implemented single-slot proof; net CPLOT trade is +128 Home, -14 EXROM, +2 BASIC RAM bytes |

Recommended sizing order: build a non-committing `DEF FN` spike first because
it has the greatest uncertainty, then autorun, then CODE. Keep only features
whose measured image deltas and regression coverage fit both ROMs independently.

## Capacity recovery and optional feature tradeoffs

There is no confirmed dead production routine left to remove. The prior ROM
audit traced apparent zero-reference blocks through fallthrough, fixed entry
tables, and cross-bank numeric calls. The following are therefore deliberate
product tradeoffs, not dead-code cleanup.

First recover space without deleting behavior:

1. Consolidate the duplicated DEF-FN header parser/checker in EXROM and enter it
   through the retired six-byte `$C072-$C077` slot. The Home runtime handler is
   currently 78 bytes; replacing it with a small wrapper should recover roughly
   70 Home bytes while sharing most of the existing EXROM checker grammar.
2. Reconsider only assembler-proven legal, final-layout JP-to-JR sites from the
   previously deferred low-margin/editor groups. These are small supplementary
   savings, not enough to fund a feature alone, and require the same batched
   rebuild discipline as the first branch pass.

If a feature must be removed, likely candidates are:

| Candidate removal | Approximate recovery/usefulness tradeoff |
|---|---|
| `SOUND` register statement, retaining `BEEP` | About 50 Home bytes plus a small EXROM amount; relatively contained if direct AY-register access is little used |
| `CPLOT` | **244 Home and 10 EXROM bytes measured** by removing its parser, renderer, keyword, and dispatch entries from the current DEF-FN tree. Redundant for many programs that already have PLOT/BLOCK, but TS2068-specific |
| `DIMN()` | Roughly 14 Home and 75 EXROM bytes; small language loss, useful mainly for introspection loops |
| Built-in HELP screen | Roughly 25-35 Home and 191 EXROM bytes; large cold EXROM recovery, but a visible usability regression |
| ULAplus commands | Roughly 50+ Home and 100+ EXROM bytes including glue; substantial recovery but removes a showcased extension |
| Keyword highlighting | Large cross-bank recovery, but tightly coupled to the editor experience and high regression risk |
| Sprite subsystem | Over 1K EXROM but comparatively little Home; only sensible if sprites are no longer a product goal |

Preferred product set is to retain `SOUND`, remove `CPLOT`, consolidate DEF-FN,
then size and add `INSTR`, prompted `INPUT`, `VERIFY`, and program autorun in
that order. Reassess the already-verified two-dimensional numeric-array design
against the resulting bank totals. Consider `FILL$` from the measured
remainder. Removing a large EXROM-only feature does not solve a Home-ROM
shortage unless Home code is subsequently relocated into the freed EXROM
space.

## RAM audit boundary

The first upper-memory relocation moves only `STR_FUNC_POOL`
(`$F328-$F3A7`). It is fixed scratch, always visible during EXROM calls, and
disjoint from the edit buffer. Further relocations should be made one reviewed
block at a time. The 126-byte canary measurement is evidence of current valid
nested-expression use, not proof that no future path can go deeper.

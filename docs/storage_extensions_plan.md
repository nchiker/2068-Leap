# Storage and ROM extension plan

## Current constraints

The current V2 build leaves 19 Home-ROM bytes and
2 EXROM bytes free after adding the generalized grammar descriptor and
loadable BLOCK. The dynamic BASIC pool is `$8426-$BFFF`
(15,322 bytes). Storage already writes the
stock 17-byte header shape: type, ten-character name, length, autostart, and
program-length fields. Extending that header is unnecessary for the first set
of features and would reduce compatibility.

## Recommended storage sequence

1. **Program autorun — implemented**
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
paging. The 132-byte CPLOT and 168-byte BLOCK modules each fit independently;
the whole window
leaves 2,304 bytes of genuine stack headroom at `$F600-$FEFF`. A generalized allocator
remains deferred pending a new stack measurement with the window reserved.

The v1 ABI is a version byte followed by four callable three-byte `JP` veneers
at fixed RAM addresses `$F3B6-$F3C2`. CPLOT calls registration, current graphics
attribute calculation, pixel writing, and the OVER-state accessor through those
veneers, so its binary contains no movable ROM routine or sysvar addresses.
Future slots must be appended without reordering existing ones.

Removed resident `CPLOT` is the two-expression proof extension: its 132-byte RAM module
exercises two numeric arguments plus graphics output. The single-slot gateway
costs 116 Home and 24 EXROM bytes; removing resident CPLOT recovered 244 Home
and 10 EXROM bytes, a net gain of 128 Home at a cost of 14 EXROM.
The dedicated trailing `EXT` qualifier now provides the tape distribution
mechanism without exposing arbitrary-address CODE loading. The gateway remains
materially smaller than the commands it lets the base ROM shed.

Implemented tape syntax is `SAVE "name" EXT` and `LOAD "name" EXT`. Extension
files use header type 4, require exactly the fixed 512-byte `$F400-$F5FF`
window, and store ABI version 1 in the header autostart field. LOAD validates
type, size, checksum, and ABI version before calling the installer at `$F400`;
any failure leaves the registry unpublished. Unlike program `LOAD ""`, an
extension LOAD requires an explicit filename; `LOAD "" EXT` is rejected.
The complete module contract, service ABI, grammar descriptors, lifecycle,
test requirements, and feature-selection guidance are documented in
[`loadable_basic_extensions.md`](loadable_basic_extensions.md).

The registry carries a non-executable grammar descriptor. Grammar 0 is
`expr,expr`; grammar 1 reuses LINE's `expr,expr TO expr,expr` parser and exposes
the four byte-sized coordinates at fixed ABI addresses. The checker interprets
the same descriptor without calling RAM. BLOCK is the first grammar-1 module,
measures 168 bytes, and has executed after loading through Fuse's live pulse
decoder from a generated Direct Recording TZX.

### Extension follow-up status

- Completed: BLOCK is position-independent, uses the existing service veneers
  plus fixed grammar-argument ABI bytes, and fits in 168 bytes.
- Completed: installed use, reversed corners, unloaded rejection, `NEW`
  clearing, deterministic extension SAVE/LOAD round-trip infrastructure, and
  live pulse-level BLOCK LOAD are covered.
- Completed: FRAME is a 212-byte grammar-1 module with no production-ROM cost;
  reversed corners, four-edge output, OVER restoration, and lifecycle cases
  are covered.
- Completed: INVERT is a 157-byte grammar-1 module with no production-ROM cost;
  inclusive/reversed rectangles, double-application restoration, unloaded
  rejection, and `NEW` clearing are covered.
- Planned: future optional statement keywords are external-first. The remaining ranked
  queue (`ELLIPSE`, `OUT`, `UDG`, then `HELP`) and
  completion requirements are maintained in
  [`loadable_basic_extensions.md`](loadable_basic_extensions.md#maintained-external-keyword-roadmap).

## Preliminary fit review

These are planning ranges from the current call paths, not byte-exact promises.
Each accepted feature still needs an assembler-built spike and a final
Home/EXROM delta. Available production padding is 19 Home bytes plus 2 EXROM
bytes; those budgets are separate and cannot be freely combined.

| Addition | Preliminary ROM cost | Current fit assessment |
|---|---:|---|
| Program autorun (`SAVE ... LINE`) | Implemented and covered by success, malformed, zero, and out-of-range tests | Complete |
| Minimal numeric, one-argument `DEF FN` | **238 Home, 102 EXROM measured** | Implemented spike; fits but leaves only 3 Home/75 EXROM, so consolidation is required before another command |
| `INSTR(haystack$,needle$)` | Implemented; current build includes its two-string parser and search semantics | Complete and covered by `tests/instr.txt` |
| `FILL$(pattern$,length)` | Exact individual cost not yet isolated; shares the prior 113-Home-byte total | Size after `INSTR`; lower priority and cannot fit the current 3-byte Home remainder |
| Prompted `INPUT "text"; A` / `A$` | Implemented as a literal-prompt grammar in runtime and checker | Complete; retains bounded numeric/string input |
| Two-dimensional numeric arrays | Prior complete build was ~26 bytes over Home when Home-resident, or ~69 bytes over EXROM when moved there, under the then-current layout | Reassess after CPLOT/gateway; the measured 128-byte net Home recovery makes the shared-parser design plausible but tighter than first estimated |
| Raw `CODE` SAVE/LOAD | ~180-300 Home, ~80-150 EXROM | Borderline alone; unlikely to coexist with `DEF FN` in current padding without relocation/savings |
| `SCREEN$` shorthand after CODE | ~25-60 total | Likely fits once CODE exists |
| `VERIFY` | Measured prototype cost about 45 Home + 145 EXROM bytes | Rejected as poor value; stock Timex shares substantially more parser infrastructure |
| Typed numeric/string-array `DATA` | ~300-550 total | Does not safely fit with the higher priorities in current padding |
| Header/storage detail command | ~100-180 total | Possible, but lower value than autorun/DEF FN/CODE |
| `CAT` | Unknown, likely >200 | Defer until semantics and transport behavior are specified |
| Printer `COPY`/`LPRINT`/`LLIST` | Requires new printer transport and no-argument/text/listing ABI services | Defer; prove screen `COPY` first after hardware and stable-service contracts are specified |
| RAM BASIC-extension gateway | **116 Home, 24 EXROM measured**; CPLOT module is 132 RAM bytes | Implemented single-slot proof; net CPLOT trade is +128 Home, -14 EXROM, +2 BASIC RAM bytes |

The completed sequence now includes DEF FN, INSTR, external BLOCK/CPLOT/FRAME/INVERT,
external AYREG, program autorun, and prompted INPUT. VERIFY was measured and rejected. Raw
CODE storage and two-dimensional arrays remain candidates, but the current
19-byte Home and 2-byte EXROM margins require another recovery decision first.

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

# 2068-Leap V2 — Current Limitations Inventory

Evidence classes follow the develop-z80 convention: `VERIFIED` (fresh source/build
evidence), `LIKELY` (strong project-local evidence, one check remains), `ASSUMED`
(explicit working premise). All ROM/RAM figures below are `VERIFIED` from a fresh
`make budget` run against commit `942facb` (2026-09-19) unless marked otherwise.

Baseline fact that frames every category below: **2068-Leap V1 has 5 bytes free
in HOME ROM (16379/16384 used) and 27 bytes free in EXROM (8165/8192 used) — 32
bytes total free across the entire 24KB ROM.** Nothing in this document can be
"just added" to the current image. Every V2 feature must be paid for by removing,
shrinking, or restructuring existing code.

## 1. Fundamental architectural limitations

These require a design change, not a patch — the current data layout or execution
model makes the limitation structural.

- **No general floating point.** A real float engine exists (`RST $28`
  calculator, EXROM-resident, reworked from the 48K Spectrum ROM's calculator),
  but it is wired in as a narrow, per-builtin special case: `SQR(x)`/`SIN(x)`
  produce a true float only when the *entire* printed expression is exactly one
  bare call (`PRINT SQR(2)` → `1.4142`). Composed into any larger expression
  (`x = SQR(2)+1`) it silently falls back to the integer-truncating path
  (`1`, not `2.4142`). There is no float variable type, no float literal syntax,
  and no promotion rule. `COS`/`TAN`/`EXP`/`LN`/`LOG10` are unimplemented.
- **No string heap.** String scalars are fixed-size 36-byte pool records (31
  content bytes + a length byte + a 4-byte header), with no allocator for
  anything beyond that cap. *(Phase 2 correction — see
  `ARCHITECTURE_VALIDATION.md` Correction 1: this entry originally
  attributed the single-character restriction to a fixed 26-slot `A$`-`Z$`
  table. That table was retired in V1's own "Phase 4" development
  (2026-08-23), before this document's first draft. The restriction's
  actual, narrower cause is that the pool record's name field is exactly 1
  byte, compared with a single exact-match instruction — see the revised
  `STRING_AND_SYMBOL_DESIGN.md`.)* The 31-byte length cap remains real and
  is the correct target for a future string-heap redesign, deferred to
  V2.1+ per the revised `STRING_AND_SYMBOL_DESIGN.md`.
- **No procedures/functions.** Only `DEF FN` exists (single-letter name, one
  numeric parameter, no recursion, no string result) and `CALL <label>`, which
  is a plain alias for `GOSUB` with no parameters, no locals, and no scoping.
  Everything else described as "structured BASIC" in the language reference
  (`DEFine PROCedure/FuNction`, `LOCal`, `REF` params) is design-only text, not
  code.
- **Zero ROM headroom under the current architecture.** 32 bytes free total.
  This alone is architectural evidence that V2 needs a redesign somewhere
  (shrink/remove/restructure existing subsystems), not incremental addition on
  top of V1.
- **Direct-execute-from-source interpretation.** There is no tokenizer and no
  bytecode/IR. The program is stored as native, case-normalized source text and
  every statement is fully re-parsed from text on every execution
  (`BASIC_EXEC_STATEMENT` → `BASIC_EXEC_DISPATCH_TABLE`,
  `basic/basic.asm:10016-10308`). This is a real, structural performance
  ceiling — fixable by caching parsed statement boundaries (REFINE), not by a
  patch, and not worth replacing with a full bytecode VM (see
  `ARCHITECTURE_COMPARISON.md` for why structured-basic-poc's VM-safety layer
  costs ~22% execution time on its own benchmarks).
- **Identifier storage model — corrected in Phase 2.** Scalar variables are
  pool-allocated, auto-vivified records (`[kind][name:1][count:2][data]`,
  via `BASIC_VAR_FIND_OR_CREATE`/`BASIC_ARRAY_FIND`), not a fixed 26-entry
  table (that table was retired in V1's own "Phase 4," before this
  restriction was first documented — see `ARCHITECTURE_VALIDATION.md`
  Correction 1). The name field is exactly 1 byte and compared with a
  single exact-match instruction — *this* is why scalar names are
  single-letter, not the absence of a symbol table. Reclassified from
  "requires a new subsystem" to §2 below: this is a narrower, cheaper fix
  than originally stated.

## 2. Implementation limitations fixable without redesign

Real, live restrictions that can be fixed inside the current architecture,
without touching the storage model or execution strategy.

- **Single-character scalar names (Phase 2 reclassification).** Now that
  the actual cause is known (a 1-byte name field and single-byte compare in
  an already-generalized pool-record scan, not a fixed table), widening
  this is a bounded, contained change to `BASIC_VAR_FIND_OR_CREATE`/
  `BASIC_ARRAY_FIND` — see `STRING_AND_SYMBOL_DESIGN.md`'s revised design
  and cost estimate.
- **`AND`/`OR` do not short-circuit.** `IF Y<>0 AND X/Y>1 THEN` still raises
  `DIVISION BY ZERO` when `Y=0`. Documented as "known, accepted" today, but
  it's a straightforward evaluator fix (skip the RHS when the LHS already
  decides the result), not an architecture change.
- **Identifiers accept only A-Z — no digits, no underscore, even in multi-
  character labels/procedure names.** `BASIC_PARSE_IDENTIFIER` (the shared
  routine used for every identifier) silently truncates at the first
  non-letter. Found the hard way: `sub1:` parses as the 3-letter identifier
  `SUB` plus a stray `1`, producing a confusing grammar error instead of a
  clean one. This is a character-class table fix, not a redesign.
- **The static whole-program checker doesn't verify `IF`/`END IF` or
  `FOR`/`NEXT` balance** — only caught at `RUN` time (`IF WITHOUT END IF`,
  `FOR WITHOUT NEXT`). The marketing claim "a program with errors never
  half-runs" is only true for the checks the checker actually performs. Fixable
  by extending the existing checker's state machine.
- **Divide-by-zero returns 0 silently** instead of raising an error — a
  leftover from before the `BASIC_RAISE_*` error mechanism existed. Wiring it
  into the mechanism that already exists (used for `NUMERIC OVERFLOW` etc.) is
  a small, contained fix.
- **Multi-dimensional arrays were built, verified, and then archived on the
  same day (2026-08-22) purely for HOME ROM budget** (they overflowed the
  then-current budget by an estimated 26-69 bytes). This is a *finished
  feature disabled by budget*, not a design gap — reviving it is a budget
  problem, not an implementation problem.

## 3. Deliberate tradeoffs that should probably remain

- **0-based arrays** (a deliberate departure from 1-based classic Sinclair
  BASIC — "simpler, no reallocator needed"). No compelling reason to change.
- **One loadable BASIC extension resident at a time**, in a fixed 512-byte RAM
  window (`$F400-$F5FF`), loaded from tape on demand rather than costing
  permanent ROM space. This is a genuinely good, already-proven ROM-budget
  technique (six shipped extensions: `CPLOT`, `BLOCK`, `FRAME`, `INVERT`,
  `AYREG`, `OUT`) and should be kept and possibly extended, not replaced.
- **No line numbers; native, non-tokenized program text, addressed by
  position.** `LIST`/`DELETE` show 1-based display line numbers purely as a
  UI convenience — nothing is actually stored as numbered lines. This is a
  real strength (matches the "no line numbers" headline feature) and should be
  preserved.
- **Direct-execute-from-source with no tokenize-on-entry step** — deliberate,
  keeps the "instant-on" promise and avoids a compile step entirely. V2 should
  REFINE this (e.g. cache parsed statement boundaries) rather than replace it
  with a bytecode VM, given the measured cost of that approach elsewhere (see
  `ARCHITECTURE_COMPARISON.md`).
- **No full LOAD rollback on a failed tape load** — accepted tradeoff on a
  stock 48K machine with no way to snapshot the whole workspace cheaply.
  Documented, tested via a real Fuse `.TAP` round trip, not worth revisiting.

## 4. Missing features

- `DEFine PROCedure`/`FuNction` with `LOCal` variables and `REF` (by-reference)
  parameters.
- `REPeat...END REPeat` with named `EXIT <name>`.
- `SELect ON`.
- `WHEN ERRor` (structured exception handling) — today there is only one flat
  raise/report mechanism with no user-installable handler.
- `DATA`/`READ`/`RESTORE` — explicitly scoped out while the language was
  integer-only; worth reconsidering once floats exist.
- `COS`/`TAN`/`EXP`/`LN`/`LOG10` — the calculator has spare capability
  (only 8 of its literal opcodes are wired up; others raise
  `CALC_ERR_UNIMPLEMENTED`), just no dispatch wiring or ROM budget yet.
- Multi-dimensional arrays (see §2 — already built once, currently absent from
  the shipped ROM purely for budget reasons).
- `MERGE`.
- A `PLAY`/sequencer layer over the existing raw `SOUND`/`BEEP` primitives
  (documented as a plausible, low-cost future addition).
- String ordering comparisons (`<`, `<=`, `>`, `>=` — only `=`/`<>` exist
  today; no semantics were ever built for ordering).
- Substring/slicing beyond `CHR$`/`STR$`/`LEN`/`CODE`/`VAL`/`INSTR` (no
  general substring-extraction function).

## 5. Bugs rather than design limitations

All of the following are already fixed on `main` — listed here so V2 carries
their regression tests forward rather than losing coverage during a redesign:

- Issue #1: `PRINT` silently dropped trailing content after a string argument
  (`73acb31`).
- Issue #2: `STR_FUNC_POOL` leak (`9f67fee`, has dedicated regression coverage).
- Issue #4: the whole-program checker rejected `PEEK(...)` combined with `*`
  (`942facb`).
- `LEN`/`CODE`/`VAL` string-pool leak (`91b5e40`).
- `DIM`'s numeric-array path had a 16-bit overflow in its size calculation that
  could corrupt roughly 64K of RAM (`e48187d`).
- Two calculator-engine bugs, root-caused and fixed together (`ba579d5`,
  `4cec666`).
- Silent 16-bit overflow on BASIC `*` — now raises `NUMERIC OVERFLOW`
  (`52467de`).
- Ghost cursor / stale editor position after a program load
  (`24def85`, `a6281a3`).
- Named tape loading interacting badly with the status-bar redraw
  (`d823af4`).
- Randomized (uninitialized) RAM at startup (`ba9a404`).

None of these are architectural — they're listed purely so the V2 regression
suite doesn't silently lose coverage for them during the numeric/string
redesign.

## A note on category boundaries

Two items are genuinely borderline and are called out explicitly rather than
silently placed in one bucket:

- The identifier letters-only restriction (§2) reads more like a found-the-
  hard-way implementation gap than a defended design choice — it is *not*
  listed under §3 (deliberate tradeoffs) even though a superficial reading of
  the codebase might suggest it was intentional.
- The 26-fixed-slot, no-heap string design (§1) was a deliberate, reasoned
  RAM-budget choice *for V1* (§3-adjacent reasoning), but the resulting
  *limitation* is fundamental (§1) — V2's job is to find a materially cheaper
  heap design than the one that motivated the tradeoff in the first place, not
  to declare the tradeoff permanently correct. See `STRING_AND_SYMBOL_DESIGN.md`.

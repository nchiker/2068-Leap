# 2068-Leap V2 — Language Target (Phase 2 revision)

**Supersedes the Phase 1 version.** Costs are updated per the revised
`NUMERIC_DESIGN.md`/`STRING_AND_SYMBOL_DESIGN.md` (cheaper than Phase 1
estimated, due to infrastructure reuse) and the revised `ROM_BUDGET.md`
(no consolidation saving exists to pay for any of it, in either bank). This
revision adds the MUST HAVE / DESIRABLE / OPTIONAL-DEFERRED split the
Phase 2 brief requires, and explicitly narrows the string feature to what
actually fits.

## MUST HAVE (the V2 Core — smallest set that meaningfully answers Phase 2's brief)

These are the features whose absence is the single most user-visible gap
identified across both phases, and whose *revised* cost is now small enough
to be worth fighting for room for, once Phase 0 relocates enough HOME/EXROM
headroom (`FIRST_MILESTONE.md`).

### Multi-character identifiers (numeric and string scalars, labels)

- ROM: ~110 bytes (name-field widen + compare loop ~80 HOME, charset widen
  ~30 HOME — `STRING_AND_SYMBOL_DESIGN.md`).
- RAM: +8 bytes per declared scalar (a real cost, not a saving —
  `RAM_BUDGET.md`).
- Perf: `LOW-MEDIUM` (revised down from Phase 1's `MEDIUM` — V1's scalar
  access was already a linear scan, not O(1), so widening the compare
  changes the per-candidate cost, not the access pattern).
- Complexity: `LOW` — extends an already-generalized, already-tested
  routine.
- Compatibility: additive.
- Risk: `LOW`.
- Benefit: closes the single most user-visible naming restriction.

### Hybrid numeric promotion (`+`/`-`/`*` gain what `/` already has)

- ROM: ~90 HOME (hot-path tag-check/dispatch) + ~250 mostly-EXROM (cold-
  path promotion, decimal-literal encoding) — revised down substantially
  from Phase 1's ~330-430 total, because the promotion mechanism (tag,
  converters, calculator literals) already exists (`NUMERIC_DESIGN.md`).
- RAM: none new (the type tag is folded into the widened scalar record
  from the identifier change above, not a separate structure).
- Perf: `LOW` risk on the fast INT path (one tag check); `/`'s existing,
  already-paid calculator round-trip cost is a pre-existing condition, not
  new cost.
- Complexity: `MEDIUM` — touches the arithmetic combine sites, but as a
  policy change to an existing mechanism, not new plumbing.
- Compatibility: additive (`X = 10.5`, currently a syntax error, becomes
  valid).
- Risk: `MEDIUM` overall.
- Benefit: closes the biggest fundamental limitation — genuinely
  composable float arithmetic.

### Ordering comparisons on strings (`<`, `<=`, `>`, `>=`)

- ROM: ~40-60 EXROM. RAM: none. Perf: none (self-contained). Complexity:
  low. Compatibility: additive.
- Risk: `LOW`. Benefit: closes a real, if narrow, correctness gap; cheap
  regardless of the string representation (works on the existing
  fixed-31-byte record, doesn't need the deferred pool allocator).

### `AND`/`OR` short-circuit evaluation

Unchanged from Phase 1: ~20 HOME, `LOW` risk, strictly improves behavior.

### Divide-by-zero raises a real error

Unchanged from Phase 1: ~15 HOME, `LOW` risk, consistency fix.

### Checker `IF`/`FOR` balance validation

Unchanged from Phase 1 in substance (~20-30 EXROM); no longer bundled with
the retracted checker-consolidation saving — this is now a standalone
addition, not a byproduct of a bigger refactor that turned out not to
exist.

### Multi-dimensional array revival

Unchanged from Phase 1: ~70 EXROM, `LOW` risk, revives already-built,
already-verified code.

## DESIRABLE (worth doing once Phase 0 finds room, not part of the Core)

### Procedures/functions (`PROC`/`FN`, by-value parameters, one level of locals)

- ROM: ~150 HOME (call/return, must interact with `GOSUB_STACK`) + ~350
  EXROM (parameter binding, local-scope resolution). **This is now the
  single largest item in the entire language target, larger than the
  numeric+symbol work combined**, and — per `ARCHITECTURE_VALIDATION.md`
  — it was not independently re-validated in Phase 2 (no fork traced its
  mechanics). Given the ROM budget crisis in `ROM_BUDGET.md`, this is
  **downgraded from "committed" (Phase 1) to "desirable, deferred pending
  Phase 0's relocation results and a dedicated validation SPIKE"** — it is
  the natural first cut if Phase 0 doesn't find enough room for everything.
- Everything else about this feature (RAM: 80 bytes from stack headroom,
  compatibility: additive, complexity: `HIGH`) is unchanged from Phase 1.
- Risk: `HIGH`, now compounded by the ROM shortfall — this is the item
  most likely to slip to V2.1.

## OPTIONAL / DEFERRED (explicitly out of V2.0, cost estimates unchanged from Phase 1 unless noted)

- **Dynamic-length scalar strings beyond the 31-byte cap** (pool-allocated,
  descriptor-lite, ~250-350 EXROM) — explicitly deferred in the revised
  `STRING_AND_SYMBOL_DESIGN.md`. This is a *new* deferral versus Phase 1,
  which had committed a version of this to V2.0; Phase 2's ROM-budget
  crisis and the discovery that the identifier-length problem could be
  solved separately and far more cheaply together make this the right cut.
- `COS`/`TAN`/`EXP`/`LN`/`LOG10` dispatch wiring — unchanged, ~200-300
  EXROM, deferred pending the numeric hybrid landing and being measured.
- `REPeat...END REPeat` / named `EXIT` — unchanged, ~150 EXROM.
- `SELect ON` — unchanged, ~150-250 EXROM.
- `WHEN ERRor` — unchanged, ~150-250 EXROM.
- `DIM AS FLOAT` typed arrays — unchanged, ~150-250 EXROM.
- `PLAY`/sequencer over `SOUND`/`BEEP` — unchanged, low cost, no urgency.

## Explicitly rejected (unchanged from Phase 1, see `ARCHITECTURE_COMPARISON.md`)

Reference-counted/generational string heap, bytecode VM with checked-
return-record safety, relocatable multi-module registry, `DATA`/`READ`/
`RESTORE`, `MERGE`.

## Does the MUST HAVE set fit comfortably? (task section 18's explicit question)

**Not yet, honestly.** Even the narrowed MUST HAVE set above (excluding
procedures entirely) totals roughly: HOME ~275 bytes (110 identifier + 90
numeric-hot + 15 div0 + ~20 AND/OR, rounding), EXROM ~420-450 bytes
(numeric-cold ~250 + ordering ~50 + checker-balance ~25 + multi-dim ~70 +
misc). Against 5 bytes HOME and 280 bytes EXROM (after the LPRINT/LLIST
move, per `ROM_BUDGET.md`), HOME is still short by ~270 bytes even with
procedures cut entirely from consideration. **This confirms
`ROM_BUDGET.md`'s conclusion independently from the language-spec side**:
Phase 0's HOME-relocation work is required before *any* of the Core
language features can be committed, not just before procedures.

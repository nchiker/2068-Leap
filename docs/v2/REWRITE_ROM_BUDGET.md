# 2068-Leap V2 — Rewrite ROM Budget

Evidence classes: `VERIFIED`, `ESTIMATED` (calculation shown), `ASSUMED`
(explicit policy choice). Anchor commit `77fdc1f` (see
`LANGUAGE_CORE_ROM_ANALYSIS.md` for why, and for the full per-module table).

## Step 1: V2 PLATFORM COST (`VERIFIED`)

Sum of every module classified as "mature functionality that should survive
largely unchanged regardless of language-core design" in
`LANGUAGE_CORE_ROM_ANALYSIS.md`: startup/kernel, editor, display/graphics,
sprites, sound, input, storage, the existing float calculator, and
unavoidable tables/data.

**V2 PLATFORM COST = 10,565 bytes** (5,013 HOME + 5,552 EXROM).

## Step 2: REQUIRED ENGINEERING RESERVE (`ASSUMED`)

This project's own history is the evidence for why a reserve matters: V1 has
repeatedly operated at single-digit-byte margins (5/27 bytes free at the
`CURRENT_LIMITATIONS.md` snapshot, 2/116 at this study's `77fdc1f` anchor),
and every one of those margins has been consumed by the next real feature.
A "reserve" that is itself zero is not a reserve.

**ASSUMED: 500 bytes total reserve** (a policy choice, not a measurement —
roughly 2% of the 24,576-byte ROM, chosen to be large enough to absorb one
mid-sized feature's worth of estimation error without immediately
re-creating the single-digit-byte-margin problem, small enough not to
foreclose real feature work). A more conservative 1,000-byte reserve is
shown alongside for comparison.

## Step 3: MAXIMUM LANGUAGE CORE BUDGET (`ESTIMATED`, formula from Step 1/2)

```
MAXIMUM LANGUAGE CORE BUDGET = 24,576 - V2 PLATFORM COST - RESERVE
```

| Reserve assumption | Maximum language-core budget |
|---|---:|
| 500 bytes (recommended) | 24,576 - 10,565 - 500 = **13,511 bytes** |
| 1,000 bytes (conservative) | 24,576 - 10,565 - 1,000 = **13,011 bytes** |

This number is deliberately computed **before** designing the interpreter,
per the study brief's explicit instruction not to design first and hope it
fits.

## Step 4: how each architecture's language core compares to that budget

### Architecture A — Evolved V1

- Current, measured V1 language core: **13,893 bytes** (already over the
  13,511-byte budget by 382 bytes, using only the reserve policy above — and
  this is *before* adding a single V2 feature).
- `V2_LANGUAGE_SPEC.md`'s MUST HAVE feature set (multi-char identifiers,
  hybrid numeric promotion, string ordering, `AND`/`OR` short-circuit,
  divide-by-zero error, checker balance, multi-dim arrays — procedures
  excluded) costs an additional `LIKELY` ~275 HOME + ~420-450 EXROM ≈
  **695-725 bytes**, per that document's own arithmetic.
- **Estimated evolved-V1 language core with MUST HAVE features: 13,893 +
  695 to 725 ≈ 14,590-14,620 bytes** — roughly **1,080-1,110 bytes over**
  the 13,511-byte maximum budget, using only 118 bytes of currently free
  ROM. This independently reproduces `ROM_BUDGET.md`'s finding (~420-byte
  shortfall per bank, ~840-870 bytes total) via a different accounting
  method (whole-ROM budget vs. per-bank budget) — the two studies agree.
- Adding procedures/functions (DESIRABLE, ~500 more bytes) widens the gap
  further, to roughly ~1,580-1,610 bytes over budget.
- **This shortfall can only be closed by Phase 0 relocation** (moving cold
  platform code into EXROM/loadable extensions, shrinking the *platform*
  total, not the language-core total) or by cutting scope. Neither changes
  the fact that evolved-V1's language core itself does not shrink — it only
  grows as features are added.

### Architecture B — New language core, existing platform (recommended shape, see `REWRITE_VM_DESIGN.md`)

- **Estimated rewritten language core: 5,010-7,220 bytes** (midpoint ≈
  6,100), measured/extrapolated in `REWRITE_VM_DESIGN.md`.
- This is **6,290-8,500 bytes under** the 13,511-byte maximum budget —
  not "just fits," but fits with room to spare for every DESIRABLE/OPTIONAL
  feature in `V2_LANGUAGE_SPEC.md` (procedures, transcendental math,
  `SELect`, `WHEN ERRor`, `REPeat`, typed arrays) simultaneously, without
  further platform relocation being required at all.
- **Total rewritten V2 ROM: 10,565 (platform) + 5,010-7,220 (language core)
  = 15,575-17,785 bytes**, against a 24,576-byte ceiling.
- **Expected ROM reserve: 6,791-9,001 bytes** — an order of magnitude larger
  than any reserve V1 has ever actually had.

### Architecture C — Broader clean V2 architecture

- Same platform reuse, same recommended VM/compiler shape as B (this study
  found no evidence, and `ARCHITECTURE_COMPARISON.md` found no evidence
  either, that a more invasive program-representation redesign — e.g.
  structured-basic-poc's NUL-record model — produces additional savings;
  both plain source text and NUL-record text are, per `V2_ARCHITECTURE.md`,
  "also plain text").
- Additional cost: representation-migration/adapter code with no offsetting
  saving found — `ESTIMATED` **+300-600 bytes**, and higher implementation
  risk (touches more of the editor/storage boundary than B does).
- **Total: 15,875-18,385 bytes**, reserve **6,191-8,701 bytes** — strictly
  worse than B on every measured axis, confirming the study brief's own
  caution ("do NOT assume C is automatically superior because it is
  cleaner"). **Not recommended.**

## Break-even analysis

**Question:** how much ROM must a rewrite save to justify its engineering
cost and risk?

- Evolved-V1 (Architecture A) cannot fund even its MUST HAVE feature set
  today (short by ~1,080-1,110 bytes against this study's own reserve
  policy) without a Phase 0 relocation step of unknown, unmeasured yield.
- A rewrite (Architecture B) is estimated to free **6,700-8,900 bytes**
  versus V1's measured language core (13,893 minus 5,010-7,220) — two full
  orders of magnitude larger than "a few hundred bytes," which the study
  brief correctly identifies as not worth the risk on its own.
- **Break-even for this specific situation is not really in question**: the
  desired V2 feature budget (MUST HAVE + DESIRABLE, procedures included)
  needs on the order of 1,200-1,600 bytes beyond what evolved-V1 has once
  Phase 0 relocation is exhausted (per `ROM_BUDGET.md`'s own conclusion,
  independently reproduced above). A rewrite that plausibly frees
  6,700-8,900 bytes clears that bar by roughly 4-7×, even accounting for
  the compiler estimate's real uncertainty (see the confidence statement in
  `REWRITE_VM_DESIGN.md`). **If the rewrite's compiler component turned out
  to cost even double this study's high estimate (10,900 bytes instead of
  5,450), the rewrite would still fit inside the 13,511-byte budget with a
  positive reserve.** This is a comfortable, not a marginal, margin.

## Recalculation after the statement-compiler spike (`STATEMENT_COMPILER_SPIKE.md`)

**Status: Architecture B's acceptance gates have been checked against real
measurement and PASS.** See `STATEMENT_COMPILER_SPIKE.md` for the full
derivation. This section supersedes the "Estimated rewritten language core"
figures above with numbers anchored on a real, assembled statement-compiler
spike (964 measured bytes across 5 representative statement types + a
shared lexer/emitter/fixup infrastructure) instead of a flat multiplier on
the checker's size.

**Platform re-measured at `61bb8bb`** (P0.4, CIRCLE+FILL relocation landed
since this document's original anchor `77fdc1f`): **9,925 bytes** (down 640
from 10,565 — real evidence Phase 0 relocation is recovering ROM). V1
language core at the same commit: 13,988 bytes (up 95, new extension-
dispatch glue).

| Component | EXPECTED | CONSERVATIVE HIGH |
|---|---:|---:|
| VM runtime (~40 opcodes) | 950 | 1,100 |
| Expression compiler (extended: comparisons, unary, string-concat, calls) | 500 | 700 |
| Statement compiler (measured + family extrapolation + explicit contingency) | 2,500 | 3,300 |
| Decimal-literal recognition (lexer addition) | 30 | 50 |
| String/ordering runtime | 160 | 170 |
| Procedures/functions runtime (parameter binding, local scope — carried forward unchanged from evolved-V1's own estimate, not independently re-measured this pass) | 500 | 650 |
| Runtime error-raise call sites (VM-specific glue to the existing `BASIC_RAISE_*` mechanism) | 40 | 60 |
| Decompiler/pretty-printer (`LIST`/`EDIT` from bytecode) | 300 | 500 |
| **LANGUAGE CORE TOTAL** | **4,880** | **6,530** |

| | EXPECTED | CONSERVATIVE HIGH |
|---|---:|---:|
| Platform | 9,925 | 9,925 |
| Language core | 4,880 | 6,530 |
| **TOTAL ROM** | **14,805** | **16,455** |
| **RESERVE** (of 24,576) | **9,771** | **8,121** |

**Gate requirement: ≥4,096 bytes reserve at the conservative estimate.
Actual: 8,121 bytes — passes with roughly double the required margin.**
This is a *smaller* language-core estimate than the pre-spike figure
(5,010-7,220, midpoint 6,100) — real measurement showed shared
infrastructure (82% of the statement-compiler spike) carries more of the
weight than the original flat-multiplier heuristic assumed, and integrating
the expression compiler with a shared lexer measurably shrank it (291→223
bytes, a real 23% reduction from sharing `SKIP_SPACES`).

**Decision: Architecture B is ACCEPTED.** Per the gate-check process in
`STATEMENT_COMPILER_SPIKE.md`, this triggers the production plan in
`ARCHITECTURE_B_IMPLEMENTATION_PLAN.md` and its first milestone in
`ARCHITECTURE_B_MILESTONE_01.md`, and the decision is recorded in
`V2_ARCHITECTURE.md`.

## Caveat this document does not hide

The platform-cost and language-core-cost measurements are `VERIFIED` (real
assembled bytes, real module boundaries). The rewritten language-core
estimate is `ESTIMATED` from two real spikes (a 588-byte 20-opcode VM slice
and a 291-byte expression compiler) extrapolated with `ASSUMED` multipliers
for the largest single component (the statement compiler, ~55-75% of the
whole estimate). This is real measurement-anchored evidence, not a guess,
but it is not the same evidentiary weight as the platform numbers. See
`REWRITE_VM_DESIGN.md`'s closing confidence statement for the recommended
next validation step before any production commitment.

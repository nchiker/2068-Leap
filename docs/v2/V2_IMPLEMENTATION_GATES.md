# 2068-Leap V2 — Implementation Gates

Explicit regression and performance gates for every milestone in
`IMPLEMENTATION_PLAN.md`, from Phase 0 onward. These are stop conditions,
not suggestions — a milestone that fails one of them does not proceed to
the next milestone until reassessed.

## Required for every milestone, no exceptions

1. **BUILD**: `make build` (or the equivalent for the sibling repo touched)
   completes with no assembler errors or warnings introduced by the
   milestone's diff.
2. **BOOT**: the resulting ROM image boots to the editor in the emulator
   (via the `2068-debug` skill or equivalent) without a hang or crash.
3. **REGRESSION TESTS**: the full existing test suite for every subsystem
   the milestone touches, plus every new test the milestone's own
   completion criteria specify, all passing.
4. **ROM MEASUREMENT**: `make budget` run fresh, HOME and EXROM byte counts
   compared against the milestone's stated expected ROM impact. A delta
   beyond the milestone's stated margin (see each milestone's own
   completion criteria for its specific tolerance) is a stop condition, not
   something to silently absorb.
5. **RAM IMPACT CHECK**: any new or resized fixed structure, any change to
   a per-record size in the dynamic pool, or any change to a stack-headroom
   carve-out, compared against `RAM_BUDGET.md`'s current numbers. An
   unexpected fixed-RAM increase (one not already itemized in
   `RAM_BUDGET.md`) is a stop condition.
6. **RELEVANT BENCHMARKS**: the specific benchmark(s) named in the
   milestone's own entry in `IMPLEMENTATION_PLAN.md`, run and compared
   against the `PERFORMANCE_BASELINE.md` baseline (or, for Phase 0's P0.1,
   the milestone's own output *is* the baseline).

## Stop conditions (explicit, per the task brief)

**STOP and reassess, rather than automatically proceeding, if a milestone:**

- Exceeds its stated ROM allocation. Reassessment options: shrink the
  milestone's own scope, find additional relocation headroom (re-open
  P0.2), or defer the milestone's remaining scope to V2.1+ — but not
  silently absorb the overage by reducing another milestone's stated
  reserve without updating `ROM_BUDGET.md` explicitly.
- Unexpectedly increases fixed RAM usage beyond what `RAM_BUDGET.md`
  already itemizes for that milestone.
- Causes unacceptable benchmark regression — defined per-milestone in
  `PERFORMANCE_BASELINE.md`'s risk analysis (e.g. M4's non-negotiable
  "integer loops must not pay the full float cost" gate has zero tolerance
  for a large regression; M3's variable-access gate has a wider but still
  finite tolerance).
- Breaks unrelated functionality — any regression test outside the
  milestone's own declared subsystem failing is treated as a full stop,
  not a "note it and continue."
- Introduces excessive subsystem coupling — a new dependency edge not
  already described in `V2_DEPENDENCY_MAP.md`/`SUBSYSTEM_BOUNDARIES.md`
  (e.g. a new shared global between the editor and the interpreter beyond
  the four already documented) requires updating those documents and
  getting the coupling explicitly reviewed before the milestone is
  accepted, not silently shipped.

## Specific gate for Phase 0 (P0.2/P0.3)

Because Phase 0 is the load-bearing prerequisite for everything else, its
gate is stricter: **P0.3 does not complete, and no M1+ milestone is
authorized to start, until `ROM_BUDGET.md` is revised with real, measured
numbers showing a genuine non-zero reserve in both HOME and EXROM for the
committed `V2_LANGUAGE_SPEC.md` MUST HAVE set** (procedures excluded,
per that document's own revised scope). If P0.2's SPIKE cannot find enough
relocatable headroom, the correct outcome is a further, explicit scope cut
documented in `V2_LANGUAGE_SPEC.md` — not proceeding against a budget known
to be short.

## Specific gate for M4 (numeric promotion)

Zero tolerance beyond "low single digits of percent" regression on the new
isolated integer-arithmetic-loop benchmark (P0.1). This is the one gate
this entire plan treats as non-negotiable, per the task's own stated
principle, and is the one most worth a human sanity-check even if the
automated gate passes.

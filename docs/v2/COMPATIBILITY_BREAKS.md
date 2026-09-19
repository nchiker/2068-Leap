# 2068-Leap V2 — Compatibility Break Ledger

Every intentional V1→V2 incompatibility, tracked so deliberate redesign
never becomes accidental loss. Policy (per explicit user direction,
2026-09-19 session, see `V1_V2_COMPATIBILITY.md`): breaking compatibility is
acceptable whenever it produces real, *measured* cost savings — this ledger
exists to keep every such break visible and justified, not to minimize
their number.

## Break 1: LPRINT/LLIST moved from resident to a loadable extension

- **Old behavior/interface**: `LPRINT`/`LLIST` always available, no load
  step.
- **New behavior/interface**: requires `LOAD "PRINTER" EXT` (or equivalent)
  before use.
- **Reason**: printer use is rare/optional; this is the only concrete,
  evidence-backed EXROM-freeing move identified by
  `CONSOLIDATION_AUDIT.md` with no code-deduplication alternative.
- **ROM benefit**: ~253 bytes EXROM (measured size of the current resident
  implementation; net saving pending confirmation once the new extension's
  own size is measured against the ~10-byte JP-stub estimate in
  `ROM_BUDGET.md`).
- **RAM benefit**: none directly (uses the existing 512-byte extension
  window, already accounted for).
- **Performance benefit/cost**: negligible — printer statements are not a
  hot path.
- **User-visible consequence**: an explicit load step for a previously
  always-available feature.
- **Migration consequence**: any V1 program using `LPRINT`/`LLIST` needs a
  `LOAD "PRINTER" EXT` line added before its first use of either statement.
- **Status**: candidate, not yet implemented — awaiting Phase 0 execution.

## Break 2 (candidate, cost unverified): sprites moved from resident to an ABI-expanded loadable extension

- **Old behavior/interface**: `SHOW`/`MOVE`/`HIDE`/`HIT()` always
  available, no load step, coexists freely with any other loaded extension
  slot usage (moot today since nothing else needs the slot
  simultaneously in practice).
- **New behavior/interface**: requires a `LOAD "SPRITES" EXT`-style step;
  cannot coexist with a second loaded extension in the same program (the
  mechanism remains single-module-at-a-time even after being expanded to
  support multiple keywords + one function per module).
- **Reason**: potential saving (~750-900 net EXROM bytes) is large enough
  to plausibly resolve the entire EXROM shortfall identified in
  `ROM_BUDGET.md` on its own.
- **ROM benefit**: **unverified** — 1,077 bytes removed from residency,
  minus ~60-80 bytes (multi-keyword dispatch, measured-plausible) minus an
  **unmeasured** `ASSUMED` 80-150 HOME bytes (function-call dispatch inside
  `BASIC_EVAL_PRIMARY`). Net figure not to be trusted until the SPIKE in
  `IMPLEMENTATION_PLAN.md` P0.2 actually drafts and sizes that code.
- **RAM benefit**: none expected (sprite buffers are already in
  always-resident chunk 7 RAM, unaffected by where the *code* lives).
- **Performance benefit/cost**: none expected on the sprite hot path itself
  (calling a RAM-resident loaded module is at least as cheap as calling
  EXROM, since no bank switch is needed); the function-dispatch addition's
  cost to *every other* expression evaluation (not just sprite-related
  ones) is the one performance question that matters here and is unmeasured.
- **User-visible consequence**: a materially larger break than Break 1 —
  sprites are a mature, heavily-used, marquee feature, not a rare one.
- **Migration consequence**: any V1 program using sprites needs a load-step
  line added; a program also using a second extension concurrently would
  need to be restructured (e.g. drop `AYREG`, fall back to plain `SOUND`).
- **Status**: candidate only. Per its own completion criteria, this break
  is not accepted until its cost is measured, not estimated.

## What is explicitly not yet broken

Every other V1 behavior, format, or API (tape/storage framing, the four
untouched extensions, `KTAB_*` jump table conventions, program-text-based
storage) remains unchanged in the current plan — see
`V1_V2_COMPATIBILITY.md` for the full accounting. This ledger is updated
the moment any of those becomes a live candidate too.

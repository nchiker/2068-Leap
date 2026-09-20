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

## Break 2 (landed, P0.3, 2026-09-19): `HIT()` moved from resident to a loadable extension; `SPRITE` itself stays resident

- **Scope correction from the original candidate above**: the candidate
  assumed converting `SHOW`/`MOVE`/`HIDE`/`HIT()` together. Implementation
  found `SHOW`/`MOVE`/`HIDE` are sub-verbs of a single resident `SPRITE`
  statement (`SPRITE GRAB/SHOW/HIDE/MOVE`), not three separate top-level
  keywords — and that statement's own free-form sub-verb grammar doesn't
  fit either canned statement shape the loadable-extension ABI offers
  (grammar 0: `expr,expr`; grammar 1: LINE-shaped 4-expr). A third,
  free-form grammar shape would need its own checker-delegated validation
  callback per module, adding more fixed Home dispatch cost this ROM's
  near-zero Home margin (2 bytes free even after this break, see below)
  cannot currently absorb. **Only `HIT()` — a single 2-argument function
  with no sub-verb grammar — was converted.** `SPRITE GRAB/SHOW/HIDE/MOVE`
  is unchanged, still resident in EXROM (`rom/exrom_sprite.asm`), and
  still requires no load step. This also means the original ~750-900
  byte EXROM estimate (for converting all four) was never going to be
  the real, measured number for what actually shipped — the real number
  below is for `HIT()` alone.
- **Old behavior/interface**: `HIT()` always available, no load step.
- **New behavior/interface**: requires a `LOAD "SPRITE" EXT`-style step
  before any expression uses `HIT(...)`; a whole-program check pass
  rejects `HIT(...)` if the module isn't loaded (confirmed live: `tests/
  hit_unloaded.txt`, `tests/hit_new_clear.txt`).
- **Reason**: `HIT()`'s own body (rectangle-overlap arithmetic over plain
  RAM sysvars) had no EXROM dependency at all, making it a clean,
  self-contained migration candidate once the full-sprite conversion
  turned out not to fit.
- **ROM benefit — real, measured**: EXROM free space rose from 27 to
  **116 bytes** (net **+89 bytes recovered**, `make budget`,
  2026-09-19) — removing `BASIC_SPRITE_HIT` (~130 lines) and its fixed
  entry stub's real logic from EXROM more than paid for the new function-
  slot dispatch body also placed in EXROM (`BASIC_TRY_EXTENSION_
  FUNCTION_EXROM_BODY`, `rom/exrom_sprite.asm`). Home free space fell
  from 5 to **2 bytes** (net **3 bytes used**, not saved) — the function-
  slot ABI's Home-side pieces (the `EXTENSION_EXEC_PTR`/`FUNC_NAME_PTR`
  registration branch in `BASIC_EXTENSION_REGISTER`, and the 6-byte
  `BASIC_CALL_EXROM_INLINE` dispatch inlined into `BASIC_EVAL_PRIMARY`)
  are fixed, one-time Home costs paid regardless of which extension uses
  the function slot — everything genuinely large (the match/parse/call
  logic itself) was moved to EXROM specifically because Home had no
  room, see `MILESTONE_01_RESULTS.md`.
- **RAM benefit**: none (sprite buffers/arrays are unaffected either way;
  the RAM extension module itself is ~247 bytes, well under the existing
  512-byte window).
- **Performance benefit/cost**: not separately measured this milestone;
  the fixed per-expression-evaluation dispatch cost (`BASIC_EVAL_PRIMARY`
  now also tries the extension-function match before falling to the
  plain-variable path) applies to every expression, not just `HIT()`
  calls — small (one `call`+`ret nc`, i.e. one indirection into an
  EXROM-resident magic/active check) but real, unmeasured in frames.
- **User-visible consequence**: smaller than the original candidate
  assumed — only `HIT()` needs a load step; `SPRITE GRAB/SHOW/HIDE/MOVE`
  are unaffected.
- **Migration consequence**: any V1 program using `HIT()` needs a
  `LOAD "SPRITE" EXT` line added before its first use; `SPRITE` itself
  needs no change.
- **Status**: **landed** — `make check`/`make test` both clean (98/98),
  live-verified via `ts2068-debug` (`tests/hit.txt`,
  `tests/hit_unloaded.txt`, `tests/hit_new_clear.txt`).

## Break 2 follow-up (still a candidate, not landed): `SPRITE`'s own statement conversion

Converting `SPRITE GRAB/SHOW/HIDE/MOVE` itself remains a real, larger
potential EXROM saving (~850+ bytes, the bulk of `rom/exrom_sprite.asm`),
but needs a free-form ("callback owns its own parse, including its own
checker-side validation callback") grammar shape added to the extension
ABI first — out of scope for this milestone given Home's now-2-byte
margin. Any future attempt should budget for that shape's own fixed Home
cost before assuming the EXROM saving is free.

## What is explicitly not yet broken

Every other V1 behavior, format, or API (tape/storage framing, the four
untouched extensions, `KTAB_*` jump table conventions, program-text-based
storage) remains unchanged in the current plan — see
`V1_V2_COMPATIBILITY.md` for the full accounting. This ledger is updated
the moment any of those becomes a live candidate too.

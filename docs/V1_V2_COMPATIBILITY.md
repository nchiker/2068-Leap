# 2068-Leap V1 → V2 Compatibility Review

## BASIC source compatibility

- **Preserved**: every V1 program continues to run identically. All V2
  additions are additive syntax (multi-character names, decimal literals,
  ordering comparisons on strings, `PROC`/`FN`) — nothing in the committed
  V2.0 scope changes the meaning of a construct that already parses
  successfully today, with two explicit, intentional exceptions below.
- **Intentional incompatibility #1 — divide-by-zero**: today returns 0
  silently; V2 raises a real error. Any V1 program that depended on the
  silent-0 behavior (none are known; this is a leftover from before the
  error mechanism existed) will now stop with an error instead. **Reason**:
  consistency with every other error condition in the language; the silent
  behavior was never a designed feature, per its own commit history.
- **Intentional incompatibility #2 — unbalanced `IF`/`FOR`**: a V1 program
  with unmatched `IF`/`END IF` or `FOR`/`NEXT` that previously ran partway
  before erroring at runtime will now be rejected by the checker before
  `RUN` starts. **Reason**: matches the project's own marketing claim that
  a program with errors never half-runs; the V1 behavior was a checker gap,
  not a designed feature.
- **No other behavior changes** are committed for V2.0. `12345*6789`
  (today: `NUMERIC OVERFLOW`) auto-promoting to a correct FLOAT result is
  presented as a *new capability*, not a compatibility break, because no
  V1 program can be relying on receiving that specific error for that
  specific input as a feature.

## Tokenized/stored-program compatibility

There is no tokenized format to be compatible with — V1 stores plain
source text, and V2 keeps this representation (`SUBSYSTEM_BOUNDARIES.md`).
A V1 program's saved tape image is therefore automatically loadable and
editable under V2 with no format translation needed, **except** for the
widened identifier charset and record layout below.

- **Symbol/pool record layout changes**: V1's scalar records are
  `[kind][name:1][count:2][data]`. V2 widens the name field. **This is
  purely an in-RAM runtime layout change, not a saved-program-format
  change** — programs are saved as source text, not as pool records; a V1
  program loaded into a V2 ROM re-creates its (now-wider) pool records
  fresh from the same source text, with no migration step needed. This is
  a real, load-bearing consequence of Correction 1 in
  `ARCHITECTURE_VALIDATION.md`: because V1 already moved to text-driven,
  freshly-created-on-load pool records (rather than a serialized binary
  table), there is no stored-format compatibility risk here at all.

## Tape/storage compatibility

Unchanged. The 17-byte stock header + native payload format is untouched by
any V2 feature. A V1-saved program loads under V2 unchanged (subject to the
source-compatibility notes above); a V2-saved program using new syntax
loads back into a V1 ROM as plain text that V1's parser will reject at the
new construct — an expected, acceptable one-way compatibility boundary
(newer-language programs don't run on older interpreters), not a defect.

## Extension/package compatibility

**Policy, per explicit user direction (2026-09-19 session): breaking V1
compatibility is acceptable whenever it produces real, measured cost
savings.** This supersedes this document's earlier framing, which treated
every compatibility break as a reluctant, last-resort tradeoff to be
minimized. Preservation is the default only in the absence of a competing,
evidenced saving — it is not a goal to be weighed equally against ROM/RAM
recovery. Every break is still named explicitly with its reason, per the
task's own requirement, but the bar for accepting one is now "is the saving
real and measured," not "is preservation possible."

Unchanged for the four extensions untouched by any Phase 0/Phase 2
candidate (`CPLOT`, `BLOCK`, `FRAME`, `INVERT`); `OUT` is likewise
unaffected. Two intentional incompatibilities are now on the table:

- **LPRINT/LLIST → 7th loadable extension** (`ROM_BUDGET.md`/
  `IMPLEMENTATION_PLAN.md`): a V1 program using `LPRINT`/`LLIST` will now
  require `LOAD "PRINTER" EXT` before those statements work. **Reason**:
  printer use is rare/optional; this is a confirmed, evidence-backed
  EXROM-freeing move (~253 bytes) with no code-deduplication alternative
  (`CONSOLIDATION_AUDIT.md`). **Status: accepted, cost verified.**
- **Sprites → ABI-expanded loadable extension** (new, added after Phase 2
  completion — see `IMPLEMENTATION_PLAN.md` P0.2's leading candidate): a V1
  program using sprites would require a new `LOAD "SPRITES" EXT`-style step
  before `SHOW`/`MOVE`/`HIDE`/`HIT()` work, and could not simultaneously
  have a second extension (e.g. `AYREG`) loaded, since the mechanism is
  still single-module-at-a-time even after the ABI is expanded to support
  multiple keywords and a function per module. **This is a materially
  larger compatibility break than the printer case** — sprites are a
  mature, heavily-used, marquee feature, not a rare one — but per the
  policy above, that is not by itself a reason to reject the change.
  **Reason for considering it despite the break**: the potential saving
  (~750-900 bytes of freed EXROM, against a plan currently short by
  ~420-720 bytes) is large enough to plausibly resolve the entire EXROM
  shortfall on its own. **Status: candidate only, cost not yet verified**
  — specifically, the `BASIC_EVAL_PRIMARY` function-dispatch addition's
  HOME cost is an unmeasured guess (`ASSUMED`, not `LIKELY`) and must be
  measured by actually drafting that code (`IMPLEMENTATION_PLAN.md` P0.2's
  completion criteria) before this incompatibility is formally accepted.
  If the measured cost is materially worse than guessed, or if the
  single-module exclusivity proves to matter in practice (a common program
  needing both sprites and `AYREG` concurrently), this candidate should be
  re-weighed against the printer-only option, not assumed to win by default.

## ROM API compatibility

- The `KTAB_*` EXROM jump table gains new entries (numeric promotion helper,
  widened symbol-scan internals are not separately exposed since they're
  reached through the unchanged `BASIC_VAR_ADDR`/`BASIC_ARRAY_FIND` call
  shape) but no existing entry changes its calling convention, register
  usage, or address. This preserves compatibility for anything relying on
  the documented jump-table contract (the loadable-extension ABI's four
  fixed veneers, specifically).
- The extension ABI itself (`REGISTER`/`PRINT_ATTR`/`WRITE_PIXEL`/
  `READ_OVER`, two grammar shapes) is unchanged in V2.0. A third grammar
  shape is evaluated, not committed (`V2_LANGUAGE_SPEC.md`) — if it lands
  in a later milestone, existing extensions remain valid; only new
  extensions could use the new shape.

## What V2 explicitly does not preserve, and why

- **Resident LPRINT/LLIST** (see above) — accepted, cost verified.
- **Resident sprites** (see above) — a candidate, not yet accepted; pending
  P0.2's measurement of the function-dispatch cost. Per the compatibility
  policy stated above, the size of this break is not itself disqualifying —
  only an unfavorable measured cost, or a practical single-module
  exclusivity problem, would be.

No other V1 behavior, format, or API is knowingly broken by the committed
V2.0 scope in `V2_LANGUAGE_SPEC.md`.

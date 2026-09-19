# 2068-Leap V2 — String and Symbol Architecture (Phase 2 revision)

**This document supersedes the Phase 1 version.** Phase 2 found that V1's
scalar storage had already been migrated off the fixed 26-slot tables
Phase 1 based its design on — before Phase 1's own audit ran. See
`ARCHITECTURE_VALIDATION.md` Correction 1 for the full evidence trail. This
revision replaces the proposed new symbol-table subsystem with a much
smaller change to the system that already exists.

## Corrected baseline (`VERIFIED` against current `main`)

Scalars (both numeric and string) are **not** fixed 26-slot tables. They
were migrated to the dynamic pool in "Phase 4" (2026-08-23) — the same
pool that holds arrays and program text. `include/sysvars.inc:323-328,
2292-2297` confirm the old tables "lived here through Phase 3 — retired in
Phase 4." Record format: `[kind:1][name:1][count:2][data...]`. A numeric
scalar is 6 bytes total; a string scalar is 36 bytes total (31 chars + a
length byte, plus the 4-byte header). Both are auto-vivified via
`BASIC_VAR_FIND_OR_CREATE`, which shares its linear-scan logic with
`BASIC_ARRAY_FIND` (`basic/basic.asm:5741-5866`). Scalars grow down from
`PROG_AREA_MAX`; arrays grow up from `PROG_END`; the pool exhausting is
reported via `MSG_ARRAY_OUT_OF_MEMORY` — a real, already-existing failure
mode, not one V2 introduces.

**The actual, narrower cause of the single-character restriction**: the
pool record's `name` field is exactly 1 byte, and the scan compares it with
a single `cp b` (`basic.asm:5835`) — an exact single-character match. There
is no separate "fixed table" cause to redesign away; there is one field
width and one comparison to widen.

## Revised design: widen the name field, don't build a new subsystem

### Multi-character identifiers (numeric and string, unified)

- Widen the pool record's `name` field from 1 byte to a bounded
  multi-byte field (proposed: up to 8 characters, matching Phase 1's
  original bound, now cheaper to reach). New record shapes:
  - Numeric scalar: `[kind:1][name:8][type-tag:1][count:2][data:2]` = 14
    bytes (up from 6).
  - String scalar: `[kind:1][name:8][type-tag:1][count:2][data:32]` = 44
    bytes (up from 36).

  (The `type-tag` byte is the FLOAT/INT/STRING discriminator introduced in
  `NUMERIC_DESIGN.md`; it is folded into this same record rather than
  stored separately, since the record is already being widened.)
- Change `BASIC_VAR_FIND_OR_CREATE`/`BASIC_ARRAY_FIND`'s single-byte `cp b`
  compare to a bounded byte-by-byte loop (max 8 iterations) — a small,
  contained change to an already-generalized, already-tested routine, not
  a new routine.
- Widen `BASIC_PARSE_IDENTIFIER`'s character class to letters + digits +
  underscore (not digit-first), needed regardless of this change and
  already identified in `CURRENT_LIMITATIONS.md` §2 as a cheap, independent
  fix. Because identifier parsing is already unified across scalars,
  labels, and `DEF FN` parameters (`CONSOLIDATION_AUDIT.md`), this one
  change benefits all of them simultaneously — no separate work needed for
  labels vs. variables.

**This closes the single most user-visible restriction in the language at
a fraction of Phase 1's estimated cost**, because the mechanism it extends
(auto-vivifying pool records with a linear name-and-kind scan) already
exists, is already tested, and already handles growth/exhaustion
correctly.

### String length cap: explicitly deferred, not solved in V2.0

Phase 1 proposed a pool-allocated, reference-count-free, length-prefixed
string heap to remove the 31-byte cap entirely. Phase 2's finding changes
the priority calculus: the *identifier-length* half of "the string
problem" (per `CURRENT_LIMITATIONS.md`, arguably the more painful
half — `NAME$` not parsing at all) is now solved cheaply by the name-field
widening above, **without touching string representation at all**. The
*length-cap* half (strings capped at 31 bytes) still requires real
allocator work — a pool-allocated, variable-length buffer, exactly as
Phase 1 designed — and that work has not gotten any cheaper. Given the ROM
budget crisis identified in `ARCHITECTURE_VALIDATION.md` (no consolidation
savings exist to pay for it), **this half is explicitly deferred to V2.1+**
rather than committed to V2.0. See `ROM_BUDGET.md`/`V2_LANGUAGE_SPEC.md`
for the resulting scope change. This is exactly the kind of explicit
tradeoff the task requires documenting rather than silently letting scope
grow to match Phase 1's original ambition.

### Ordering comparisons (`<`, `<=`, `>`, `>=`)

Unchanged from Phase 1 in substance, cheaper in practice: with a length
byte already present in the (now-wider, but still fixed-size) string
record, a byte-wise comparison routine is small and self-contained,
independent of whether the string is fixed-31-byte (V2.0) or eventually
pool-allocated (V2.1+ stretch). Committed for V2.0.

## Revised bytes-per-symbol/string

| | V1 today | V2.0 (name widening only) |
|---|---:|---:|
| Numeric scalar | 6 bytes | 14 bytes (+8) |
| String scalar | 36 bytes | 44 bytes (+8) |

**This is a RAM cost, not a RAM saving** — a direct correction of Phase 1's
`RAM_BUDGET.md`, which claimed a net saving by comparing against the fixed
26-slot tables that no longer exist. See the revised `RAM_BUDGET.md` for
the corrected worst-case analysis.

## Revised cost estimate (`LIKELY`, pending a SPIKE)

| Item | Estimated cost | Bank |
|---|---:|---|
| Widen name field + byte-by-byte compare in `BASIC_VAR_FIND_OR_CREATE`/`BASIC_ARRAY_FIND` | ~80 bytes | HOME (hot path — every variable access) |
| Widen `BASIC_PARSE_IDENTIFIER` character class | ~30 bytes | HOME (shared across scalars/labels/DEF FN, one-time cost) |
| Ordering comparisons (`<`/`<=`/`>`/`>=`) | ~40-60 bytes | EXROM (string funcs) |
| **Total (V2.0 committed)** | **~150-170 bytes** | mostly HOME |

Compare to Phase 1's ~440-510 byte estimate for the full descriptor-lite
redesign — the committed V2.0 scope is now roughly a third of that cost,
because it reuses the existing pool-record mechanism entirely and defers
the genuinely expensive part (variable-length strings) rather than solving
it at V2.0's budget.

## Deferred to V2.1+ (not committed, cost unchanged from Phase 1's estimate)

Pool-allocated, variable-length scalar strings beyond 31 bytes, with the
in-place-reuse mitigation for reassignment-heavy loops — ~250-350 bytes
EXROM, per Phase 1's original analysis, revisited once V2.0's ROM budget
crisis (`ARCHITECTURE_VALIDATION.md`) is resolved and real headroom exists.

# 2068-Leap V2 — RAM Budget (Phase 2 revision)

**This document supersedes the Phase 1 version.** Phase 1 claimed a net RAM
*saving* from replacing a fixed 26-slot scalar table with a pool-based
symbol table. That fixed table does not exist on current `main` (retired in
V1's own "Phase 4," see `ARCHITECTURE_VALIDATION.md` Correction 1) — the
real comparison is against V1's *already pool-based* scalar records, and
the honest result is a modest RAM **cost**, not a saving.

## Baseline 48K RAM map (`VERIFIED`)

Unchanged from Phase 1 — re-confirmed, no discrepancy found:

| Region | Size | Contents |
|---|---:|---|
| $0000-$3FFF | 16,384 | HOME ROM (not RAM) |
| $4000-$7FFF | 16,384 | Display/video RAM |
| $8000-$8454 | 1,108 | System workspace / sysvars |
| $8455-$BFFF | 15,275 | Dynamic pool: program text + scalars + arrays |
| $C000-$DFFF | 8,192 | EXROM paging window (not usable as BASIC RAM) |
| $E000-$E7FF | 2,048 | FILL scratch (transient, HOME-only) |
| $E800-$F0FF | 2,304 | Sprite buffers |
| $F100-$F327 | 552 | Label table / UDGs / LOAD-name / detokenize buffer |
| $F328-$F3A7 | 128 | String-function scratch pool |
| $F3A8-$F3AE | 7 | `DEF FN` state |
| $F3AF-$F3FF | 81 | Extension registry / service ABI |
| $F400-$F5FF | 512 | Loadable-extension module window |
| $F600-$FEFF | 2,304 | Stack headroom |
| $FF00-$FFFF | 256 | Machine stack |

## Correction: scalar storage today is already pool-based, not a fixed reservation

`VAR_TABLE`/`STR_TABLE` (the ~884-byte fixed reservation Phase 1's
comparison was anchored on) do not exist on current `main`. Scalars are
pool records: `[kind:1][name:1][count:2][data]` — **6 bytes per numeric
scalar, 36 bytes per string scalar**, allocated only for variables that
actually exist, growing down from `PROG_AREA_MAX` within the same
15,275-byte dynamic pool that already holds program text and arrays. This
was already the RAM-efficient design Phase 1 was proposing to build — V1
already has it.

## Revised V2 change: widen the name field (a real RAM cost)

`STRING_AND_SYMBOL_DESIGN.md`'s revised design widens the name field from 1
byte to 8 bytes to support multi-character identifiers, changing record
sizes:

| | V1 today | V2.0 |
|---|---:|---:|
| Numeric scalar record | 6 bytes | 14 bytes (+8) |
| String scalar record | 36 bytes | 44 bytes (+8) |

This draws from the same shared dynamic pool as before — no new fixed
arena, no change to the pool's total size or its two-ended growth
discipline. But it is honestly a **per-variable RAM cost increase**, not a
saving, for every program that declares variables:

| Program shape | V1 (6B/36B records) | V2.0 (14B/44B records) | Net |
|---|---:|---:|---:|
| Small (10 numeric variables) | 60 bytes | 140 bytes | **+80** |
| Typical (20 numeric + 10 string) | 120 + 360 = 480 bytes | 280 + 440 = 720 bytes | **+240** |
| Large (50 numeric + 20 string) | 300 + 720 = 1,020 bytes | 700 + 880 = 1,580 bytes | **+560** |

This is a modest cost against a 15,275-byte shared pool (worst case above
is ~3.7% of the pool for a large program), but it is the opposite direction
from Phase 1's claim and is stated plainly here rather than glossed over.

## Procedure frames (unchanged from Phase 1 in mechanism, cost unchanged)

8 nested levels × (2-byte return address + up to 4 params × 2 bytes each) =
80 bytes, carved from the 2,304-byte stack-headroom region, leaving 2,224
bytes. This item was not independently re-validated in Phase 2 (no fork
traced procedure-call RAM mechanics in detail) and is carried forward
unchanged, flagged for its own validation pass before being locked in — see
`ARCHITECTURE_VALIDATION.md`.

## Worst-case behavior (updated)

| Scenario | V1 | V2.0 |
|---|---|---|
| Program needs >26 variables | Not a hard limit today (already pool-based) — degrades into pool exhaustion at the same threshold as any other pool consumer | Same failure mode, reached modestly sooner per variable due to the wider record (see table above) |
| Program does heavy string churn in a loop | No leak (fixed 36-byte record reused in place) | **Unchanged** — V2.0 keeps the fixed-size string record (the pool-allocated variable-length string design is deferred to V2.1+ per `STRING_AND_SYMBOL_DESIGN.md`), so this scenario's RAM behavior is identical to V1's, not the leak-prone dynamic-allocation scenario Phase 1's deferred design would have introduced |
| Deep procedure recursion | N/A | Hard 8-level cap, clean failure mode, unchanged from Phase 1 |

## Bottom line (revised)

V2.0's RAM plan is smaller in scope than Phase 1's (string representation
itself is unchanged in V2.0 — only the *name* field grows), and its net
effect is a modest, honestly-stated RAM cost rather than a saving. Total
RAM remains 48K; no new fixed region is introduced; the failure mode
remains "shared pool exhaustion," unchanged in kind from V1, reached
slightly sooner per variable declared.

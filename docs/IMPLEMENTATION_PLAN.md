# 2068-Leap V2 — Implementation Plan (Phase 2 revision)

**Superseded as the primary plan**: the rewrite feasibility study found
evolved-V1 (the plan below) cannot fund even its narrowed MUST HAVE feature
set within 24KB (`docs/REWRITE_ROM_BUDGET.md`), and a follow-up
statement-compiler spike (`docs/STATEMENT_COMPILER_SPIKE.md`) confirmed
Architecture B (replace the language core, keep the platform) fits with a
large measured ROM/RAM margin. Architecture B is now the accepted V2
direction (`docs/V2_ARCHITECTURE.md`); its milestone plan is
`docs/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`, first concrete step
`docs/ARCHITECTURE_B_MILESTONE_01.md`. This document's Phase 0
relocation work remains valid and already-landed (P0.3 `77fdc1f`, P0.4
`61bb8bb`) — Phase 0's ROM recovery benefits Architecture B too, since it
lowers V2 PLATFORM COST regardless of which language core sits on top. The
milestones below (M1-M6, incrementally extending V1's language core) are
superseded and should not be started; the language core is being replaced,
not incrementally extended.

**Supersedes the Phase 1 version.** The milestone order changes
substantially: Phase 0 (relocation) now precedes everything else and is
mandatory, per `ROM_BUDGET.md`/`V2_ARCHITECTURE.md`'s revised conclusions.
Nothing in this plan authorizes implementation by itself — the mutation
boundary from the project dossier still applies; see `FIRST_MILESTONE.md`
for the one concrete step ready to present for explicit user acceptance.

## Phase 0 — Architectural relocation (required, not optional)

### P0.1 — Benchmark fixture authoring (was Phase 1's M0, now scoped honestly)

- **Objective**: author the isolated benchmarks that don't exist
  (addition, multiplication, division, `FOR`/`NEXT`, `IF`/branching,
  variable-access), re-run the string benchmark past its old N=3 cap, and
  apply the documented 5-run protocol — per `PERFORMANCE_BASELINE.md`'s
  revised action plan.
- **Files/subsystems affected**: `~/2068-rom-benchmarks` only.
- **Expected ROM/RAM impact**: none (2068-Leap ROM/ASM untouched).
- **Regression tests required**: confirm the string-concat fix holds past
  N=3.
- **Benchmarks required**: this milestone *is* the benchmark work.
- **Completion criteria**: all six new fixtures run cleanly and produce a
  5-run statistical result; the string benchmark produces a valid,
  uncapped throughput number.

### P0.2 — HOME/EXROM relocation SPIKE

- **Objective**: measure, not assume, how many bytes of currently-HOME-
  resident code can safely move to EXROM (accepting the paging-call cost)
  without materially harming a hot path, using the placement-decision
  methodology adopted from structured-basic-poc in Phase 1
  (existence→residency→execution-frequency→paging-closure→interrupt/
  timing→RAM-ownership→net-cost→acceptance). Candidate starting point:
  `kernel/graphics`'s 2,761 HOME bytes — `CIRCLE`/`FILL`/mode-setup
  routines are called far less often per program than `PLOT`/`LINE` and are
  plausible, but unverified, relocation candidates.
- **Leading candidate (added after Phase 2 completion, per direct user
  request): convert sprites to an ABI-expanded loadable extension.**
  Sprites are 1,077 EXROM bytes (`rom/exrom_sprite.asm`, 899 lines) — larger
  than the entire committed core's EXROM shortfall. Converting them to a
  loadable extension is blocked today by two hard ABI limits, both
  verified directly against source: (1) `EXTENSION_NAME_PTR`/
  `EXTENSION_EXEC_PTR` (`include/sysvars.inc:2497-2498`) are single-value
  cells — the ABI registers exactly one keyword per loaded module, but
  sprites need at least `SHOW`/`MOVE`/`HIDE`/`HIT` (four vocabulary items);
  (2) the ABI has no function-call support at all — `HIT()` is called
  inside expressions, and there is no mechanism for a loaded module to
  register one. Expanding the ABI to fix both: turning the single-keyword
  check into a bounded N-way loop at its two dispatch sites (checker
  `rom/exrom_checker.asm:969`, EXROM; runtime `basic/basic.asm:10145,10164`,
  HOME) is small (~60-80 bytes total, per direct source inspection).
  Function-call support is **not** a cheap reuse of an existing mechanism —
  verified directly: `DEF FN` dispatch is a single hardcoded name check
  inline in `BASIC_EVAL_PRIMARY` (`basic.asm:2839-2855`), not a generic,
  extensible function table. Adding extension-function dispatch means new
  logic inside `BASIC_EVAL_PRIMARY` itself — the expression evaluator's hot
  path, executed on every primary-term evaluation. This is genuinely
  unverified (`ASSUMED`, not `LIKELY`) — a rough, un-measured guess is
  80-150 HOME bytes, but this is exactly the kind of number this project's
  own Phase 2 discipline says not to trust without a SPIKE. **Net picture
  if the guess holds**: remove 1,077 EXROM bytes, add ~60-80 bytes (mixed
  HOME/EXROM) + ~80-150 HOME bytes ≈ **750-900 bytes of net freed EXROM
  headroom, at a real but smaller HOME cost** — bigger than the plan's
  entire current EXROM shortfall. **Per explicit user direction (2026-09-19
  session): breaking V1 compatibility is acceptable when it produces real,
  measured cost savings — the LOAD-step compatibility break this would
  introduce for existing sprite-using programs (see the reopened
  `V1_V2_COMPATIBILITY.md` entry) is not, by itself, a reason to exclude
  this candidate.** This makes it the leading, highest-payoff candidate in
  this milestone's list, ahead of the `kernel/graphics` trim above — but
  its actual cost, especially the function-dispatch HOME figure, must be
  measured, not assumed, before P0.3 commits to it.
- **Files/subsystems affected**: read/measurement only in this milestone —
  no code moves yet. Candidates: `kernel/graphics/graphics.asm`;
  `rom/exrom_sprite.asm` + the extension-registration mechanism in
  `basic/basic.asm`/`rom/exrom_checker.asm`.
- **Expected ROM/RAM impact**: none yet (measurement only).
- **Regression tests required**: none yet.
- **Benchmarks required**: none yet — this milestone produces the *plan*
  for P0.3's actual move, using P0.1's now-available benchmark fixtures to
  pre-check that candidate routines aren't on a path P0.1's new benchmarks
  show to be hot.
- **Completion criteria**: a concrete, evidence-backed list of relocation
  candidates with sizes, each classified against the 8-gate placement
  checklist. For the sprite-extension candidate specifically: a real
  measured byte count for the `BASIC_EVAL_PRIMARY` function-dispatch
  addition (the one genuinely unverified figure above), obtained by
  actually drafting that dispatch code, not estimating it, before it is
  entered into `ROM_BUDGET.md`. Overall, this milestone must produce a
  total relocation/conversion figure this document can then use to re-open
  `ROM_BUDGET.md`'s shortfall calculation.

### P0.3 — Execute the relocation (or the scope cut, whichever the SPIKE justifies)

- **Objective**: actually move the candidates identified in P0.2, OR — if
  P0.2 finds insufficient relocatable headroom — formally cut
  `V2_LANGUAGE_SPEC.md`'s MUST HAVE scope (procedures already flagged as
  the first candidate for deferral) until the revised budget closes with a
  genuine reserve.
- **Files/subsystems affected**: whatever P0.2 identifies.
- **Expected ROM impact**: whatever P0.2 measures — not assumed here.
- **Expected RAM impact**: none expected (relocation, not new allocation).
- **Regression tests required**: full existing test suite for every moved
  routine, plus new tests confirming EXROM-paging correctness at each new
  call site (banking is already a solved, tested mechanism —
  `SUBSYSTEM_BOUNDARIES.md` — but every new call site needs its own
  DI/EI-correctness check).
- **Benchmarks required**: P0.1's new fixtures, re-run to confirm no moved
  routine that turned out to be hotter than assumed causes unacceptable
  regression.
- **Completion criteria**: `make budget` shows the real, achieved HOME/
  EXROM reserve; `ROM_BUDGET.md` is revised with real numbers in place of
  the current honest shortfall; only then do M1+ below become authorized
  to start.

## M1 — Quick-win language fixes (unchanged from Phase 1 in content, re-sequenced after Phase 0)

Identifier charset widen, `AND`/`OR` short-circuit, divide-by-zero raise.
Cost/tests/benchmarks unchanged from Phase 1's M1. **Gated on P0.3's
confirmed headroom.**

## M2 — Checker `IF`/`FOR` balance validation

Unchanged in content from Phase 1's M2, **decoupled from the now-retracted
checker-consolidation saving** — this is a standalone addition (~20-30
EXROM), not a byproduct of a bigger refactor. Gated on P0.3.

## M3 — Symbol table name-field widening

Objective, files, tests unchanged in kind from Phase 1's M3; cost revised
down (~80 HOME for the widen+scan, per `STRING_AND_SYMBOL_DESIGN.md`) and
RAM impact corrected to a modest *cost* (+8 bytes/scalar), not a saving,
per `RAM_BUDGET.md`. Gated on P0.3.

## M4 — Hybrid numeric promotion

Objective unchanged; mechanism substantially revised per
`NUMERIC_DESIGN.md` — this is now "propagate an existing tag and wire
`+`/`-`/`*` to calculator literals `/` already uses," not "build tagging
from scratch." Cost revised down (~90 HOME + ~250 mostly-EXROM). Depends on
M3 (tag lives in the widened scalar record) and P0.3. Acceptance test
unchanged: `x = SQR(2)+1` must now produce a correct composed FLOAT.
Benchmark gate: the new isolated integer-arithmetic-loop benchmark from
P0.1, confirming the non-negotiable "integer programs don't pay the full
float cost" requirement, now measurable for the first time.

## M5 — Multi-dimensional array revival

Unchanged from Phase 1. Gated on P0.3.

## M6 — Ordering comparisons on strings

**New, smaller milestone, split out of Phase 1's larger M6** (which also
included the now-deferred dynamic-string-length work). ~40-60 EXROM,
self-contained, works on the existing fixed-31-byte record. Gated on P0.3.

## Deferred to V2.1+ (not part of V2.0's committed plan)

- **Procedures/functions** — downgraded from a committed V2.0 milestone
  (Phase 1's M7) to a deferred, desirable feature per
  `V2_LANGUAGE_SPEC.md`, pending Phase 0's actual relocation yield and its
  own dedicated validation SPIKE (not performed in either phase to date).
- **Dynamic-length scalar strings beyond 31 bytes** — deferred per
  `STRING_AND_SYMBOL_DESIGN.md`.
- Everything already deferred in Phase 1 (`COS`/`TAN`/`EXP`/`LN`/`LOG10`,
  `REPeat`, `SELect ON`, `WHEN ERRor`, `DIM AS FLOAT`, `PLAY`/sequencer,
  statement-boundary/dispatch caching) — unchanged.

## Cross-cutting completion gate

Unchanged in spirit from Phase 1, formalized in `V2_IMPLEMENTATION_GATES.md`:
every milestone requires build, boot, regression tests, ROM measurement,
RAM-impact check, and relevant benchmarks before being marked complete, with
explicit stop conditions rather than automatic proceeding on any miss.

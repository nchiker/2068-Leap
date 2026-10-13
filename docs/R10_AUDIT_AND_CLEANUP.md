# R10 — Post-V2 audit, correctness, consolidation and cleanup

Date: 2026-09-27. Baseline: `da87dab` ("Post-R9 test-infrastructure
milestone"), treated as immutable per this milestone's own instructions.
This document is the authoritative record of R10's work; see
`docs/V2_SEMANTIC_CAPABILITY_AUDIT.md` for the pre-R9 audit this
milestone continues, and `docs/POST_R9_SEMANTIC_MILESTONE.md`/
`docs/POST_R9_TEST_INFRASTRUCTURE.md` for what the post-R9 milestone
already resolved before R10 began.

R10 is not R11. No new language features were begun. The six optional
V1 extensions (CPLOT, AYREG, OUT, BLOCK, FRAME, INVERT) remain out of
scope. R10.5 ROM optimization has not begun.

## Baseline confirmation

`make check`, `make test` (9/9 smoke, 2/2 editor flows, 11/11 storage
cases, 17/17 V2 standalone), `make budget` (HOME 15,066/16,384 — 1,318
free; EXROM 5,419/8,192 — 2,773 free), and `make v2-packages` were all
reproduced exactly as documented in a disposable sandbox before any
change was made, confirming `da87dab` as the authoritative baseline.

## Section 2 — Remaining semantic/correctness audit

Every item from `docs/V2_SEMANTIC_CAPABILITY_AUDIT.md`'s correction
matrix not already resolved by the post-R9 semantic milestone was
revisited. Disposition:

| # | Finding | Classification | R10 disposition |
|---|---|---|---|
| 6 | `VAL()` cannot parse a decimal point | Correctness defect | **Fixed.** `BUILTIN_FN_VAL` (`rom/exrom_v2_vm_core.asm`) now mirrors the compiler's own `LEX_SCAN_NUMBER` value/divisor scheme — digits before and after `.` accumulate into one running value; a separate counter tracks fractional-digit count, producing a real FLOAT result via the calculator when a decimal point was seen. Cost: part of the 129-byte HOME delta below. Regression test: `rom/test_v2_r10_numeric.asm`. |
| 7 | `OP_DIV`'s zero-check is skipped when the divisor is FLOAT-tagged | Correctness defect | **Fixed.** New shared `VM_FLOAT_TEST_ZERO` helper reads the packed float's own sign/zero encoding (small-int form: byte0=0, byte1=$00/$FF sign, bytes2-3=magnitude; general form: byte0≠0, never exactly zero) and is now called unconditionally in `OP_DIV`'s float path, replacing the old INT-only fast check. Regression test: `rom/test_v2_r10_numeric.asm` (divides by `VAL("0.0")`, confirms `VM_ERR_DIVIDE_BY_ZERO`/code 5). |
| 8 | All relational/equality operators reject any FLOAT operand | Correctness defect (intended language semantics — ordinary numeric comparison — were judged clear, not a "language design decision" requiring a stop) | **Fixed.** New shared `VM_CMP_DISPATCH` backend: two INT operands take the unchanged `MATH_COMPARE16` fast path; either FLOAT-tagged operand computes `a-b` via the real calculator and classifies the packed result's sign/zero, returning the same `0`/`1`/`$FF` contract `MATH_COMPARE16` already used. All six of `OP_CMP_LT/LE/GT/GE/EQ/NE` now route through it. `OP_AND`/`OP_OR`/`OP_NOT` were deliberately left INT-only — boolean-operand FLOAT semantics were not part of the audit's finding and are a separate, unscoped question. Regression test: `rom/test_v2_r10_numeric.asm` (`SQR(4)=2`, `1.5<2`, `2<1.5`). |
| 9 | `STRTAB_MAX_VARS` capped at 4, no RAM-scarcity justification | Optional enhancement, not a correctness defect | **Deferred, undone.** Raising a resource limit is a capacity increase, not a bug fix — per this milestone's own instruction not to auto-implement every historical wish-list item. Remains a candidate for R11 or whenever convenient (~384 bytes RAM to raise to 16, matching `CSYMTAB`). |
| — | `SGN`'s documented int-only scope vs. `ABS`'s float support | Intentional documented limitation | No action — already disclosed, low severity, not reopened. |
| — | `OP_MUL` overflow silently truncates rather than auto-promoting | Intentional documented limitation (explicitly commented as a deliberate scope boundary) | No action — not reopened. |

Combined cost of the three fixes: **+129 bytes HOME, +0 bytes EXROM**
(HOME 15,066→15,195, 1,318→1,189 free before the editor-restoration
work below; EXROM unchanged — all three fixes live entirely in
`rom/exrom_v2_vm_core.asm`). `make check`/`make test`/`make budget`/
`make v2-packages` all pass with these fixes in place; the new
standalone test `r10_numeric` is 1 of 18/18 passing V2 standalone
regressions (up from 17).

No other item from the pre-R9 audit's own correction matrix remained
open besides rows 6-9 above — rows 1-5 were resolved by the post-R9
semantic milestone (FLOAT/type-boundary, nested FOR/NEXT, DIM/decompiler,
PROC/DEF-FN recursion safety).

## Section 3 — Dead V1 RAM/sysvar audit

A systematic audit of `include/sysvars.inc` (258 `DEFS`-based RAM
allocations) found 94 V1-era symbols (347 bytes) with zero references
anywhere in the real production-consumed file set
(`rom/v2_home.asm`/`rom/v2_exrom.asm`'s full `INCLUDE` chains, the four
loadable packages, and `include/v2_ktab.inc`/`include/v2_layout.inc`'s
cross-bank service addresses).

**The `FOR_STACK_DEPTH` collision that originally motivated this audit
was a same-name/different-module grep confusion, not a real address or
allocation conflict.** V1's dead `FOR_STACK_DEPTH` (`include/sysvars.inc`)
and V2's live `VM_FOR_STACK_DEPTH` (`rom/exrom_v2_vm_core.asm`, a
separate fixed-address region documented in `R9_CUTOVER_LEDGER.md`'s RAM
table) already coexist safely at different addresses. Searching for
"FOR_STACK_DEPTH" finds both; only one is live.

**Reclamation attempted, then reverted — the premise was wrong.**
`include/sysvars.inc` computes every address as a sequential offset from
`ORG $8000`, so deleting the 94 dead symbols would shift `PROG_AREA_START`
($8455) and every address after it. Before executing this, a second pass
checked whether anything hardcodes the literal `$8455`/`0x8455` anywhere
in the `make check/test/budget/v2-packages` gate chain, the dev scripts,
or the physical tape fixture (`tests/atape`) — none do; all read
`PROG_AREA_START` symbolically. That check passed, but the deletion
itself failed differently: **`include/sysvars.inc` is a shared header**,
also pulled in by `rom/exrom_build.asm` (the legacy V1 EXROM, paired with
`basic/basic.asm`/`basic/editor_integration.asm`), which is still a live,
currently-passing part of `make check`/`make test` — the calc-smoke
images, `tools/run_editor_auto_test.sh`, and
`tools/run_storage_named_load_test.sh` are legitimate component tests
(`docs/POST_R9_TEST_INFRASTRUCTURE.md`), not stale fixtures, and they
genuinely reference almost all of the "dead" RAM. Deleting it broke
`make check` with 139 "Label not found" errors from
`exrom_dim.asm`/`exrom_arrays.asm`/`exrom_highlight.asm`/`exrom_printer.asm`.

**Disposition (explicit product decision): skip reclamation, document as
intentional.** `include/sysvars.inc` is unchanged from `da87dab`. The
94-symbol, 347-byte inventory above stands as evidence of what is
dead-to-production but alive-to-V1-test-scaffolding. Real reclamation
would require first retiring or isolating the V1 test scaffolding onto
its own, non-shared sysvars header — a separate, larger decision, out of
scope for this cleanup step. **Net RAM reclaimed this milestone: 0
bytes**, and that is a correct, deliberate outcome, not a shortfall.

## Section 4 — Dead/duplicate ROM audit

A read-only audit of the real production include set
(`rom/v2_home.asm`/`rom/v2_exrom.asm`, everything they `INCLUDE`) found
**no genuinely dead or duplicated code** in the current production
build. Specific findings:

- Opcodes 37/38 (`dw VM_ERR_ILLEGAL_OPCODE` placeholders left by
  LPRINT's externalization to the printer package) are confirmed
  intentional, already documented, correctly retired — not reclaimed
  further (reclaiming the numeric opcode slots is a future-feature
  question, not cleanup).
- `rom/exrom_checker.asm` is confirmed provably unreferenced by any of
  the three production build targets (`v2_home.asm`/`v2_exrom.asm`/
  `zesarux_combined.asm`) — consistent with `R9_CUTOVER_LEDGER.md`'s own
  documented deliberate historical retention, not an oversight.
- `basic/basic.asm`, `basic/editor_integration.asm`,
  `rom/exrom_strfuncs.asm`, `rom/exrom_dim.asm`, `rom/exrom_arrays.asm`
  (R9's documented V1 removal list) remain correctly excluded from
  production, still referenced only by the V1-derived component test
  harnesses (intentional, per Section 3 above).

A full line-by-line duplicate-helper sweep of the two largest files
(`rom/exrom_v2_compiler.asm`, `rom/exrom_v2_vm_core.asm`) was not
exhaustively completed — flagged as not-fully-covered, not as
confirmed-clean, should a future pass want to go deeper.

## Section 5 — Compiler/VM consistency audit

Spot-checked as part of the Section 2 fixes and general source reading
during this milestone:

- `TOK_KW_END`/`TOK_KW_STOP` are correctly wired end-to-end (keyword
  table → `COMPILE_STATEMENT_LIST` dispatch → `.end_stmt` handler) —
  confirmed by direct read, not assumed, resolving the pre-R9 audit's own
  "not independently verified" flag on this area.
- `LPRINT` is confirmed to dispatch entirely through the generic
  extension-registry mechanism (`EXT2_LOOKUP`/`COMPILE_LPRINT_RESOLVE_SLOT`)
  exactly like the sprite/mode/printer statements — no special-cased
  runtime dispatch — resolving the pre-R9 audit's own "lower-confidence"
  flag on this claim.
- The three new shared VM helpers this milestone added
  (`VM_FLOAT_TEST_ZERO`, `VM_CMP_DISPATCH`, plus `BUILTIN_FN_VAL`'s
  extended scan) were each verified against every call site that now
  routes through them (`OP_DIV`'s float path; all six relational
  opcodes) — no dead branch or orphaned old code path left behind (the
  old per-opcode `VM_POP`/tag-check/`VM_ERR_FLOAT_NOT_IMPLEMENTED`
  prefix was fully replaced, not left dormant, in all six relational
  handlers).

No dead opcodes or orphaned compiler paths were found or removed this
milestone beyond what Section 4 already covered.

## Section 6 — Extension/package boundary

Cleanup-only audit (no redesign, per this milestone's own instruction).
Confirmed uniform: all four resident packages (MODE, SPRITE, PRINTER,
SHAPES) register via `EXT2_REGISTER` inside their own `*_INSTALL` entry,
reached via `rom/v2_package_*.asm`'s single `jp *_INSTALL` header; the
VM/compiler call path (`OP_CALL_EXT`/`EXT2_LOOKUP`) is the single
mechanism, with no one-off special case (LPRINT reuses it too, per
Section 5). No obsolete V1 extension ABI or state was found consuming
production resources. The six optional V1 extensions
(CPLOT/AYREG/OUT/BLOCK/FRAME/INVERT) are not present in the tree under
any `rom/exrom_<name>.asm` naming — nothing to note, out-of-scope
investigation correctly not needed. **Section 6 is clean — no action
taken.**

## Section 7 — Complete editor/interactive-debugging audit

A systematic comparison of the current V2 production editor
(`rom/exrom_v2_shell.asm`, `rom/exrom_editor.asm`) against the mature
pre-R9 V1 editor (`basic/editor_integration.asm`, via Git history) found
and fully traced (not guessed from feature names) two capabilities
beyond what the post-R9 semantic milestone's own narrower editor audit
had already found:

- **Keyword bolding**: V1's `BASIC_PRINT_LINE_WRAPPED_COMMON` called
  into `rom/exrom_highlight.asm` (274 lines, EXROM-resident, confirmed
  NOT included in `rom/v2_exrom.asm`) to detect keyword spans and
  dispatch to `GFX_PUTCHAR_BOLD` vs plain `GFX_PUTCHAR`. The rendering
  primitive (`GFX_PUTCHAR_BOLD`, `kernel/graphics/graphics.asm`)
  survived R9; only the V1 keyword-detection table-walk didn't migrate.
  Trigger was never live-as-you-type — the actively-edited row was
  always plain; every other (settled) row, and LIST, got the bold scan.
- **Error navigation** ("step-through-errors", the user's own
  provisional name — the real V1 mechanism was
  `BASIC_FIND_NEXT_ERROR`/`PREV_ERROR`, SYMBOL SHIFT+A/S): V1's static
  checker populated a 16-entry `CHECK_ERROR_LIST` (statement positions)
  before RUN; the user could browse forward/backward through it,
  landing the cursor via ordinary line navigation (no separate mode,
  full editing context preserved). This applied to compile-time errors
  only — V1 had no equivalent multi-error mechanism for runtime faults.

Both were classified as **debugging/workflow** capability (not purely
cosmetic), and — per explicit instruction — investigated for a
V2-native design rather than a V1 restoration, with a design-fork
question (single-error vs. multi-error navigation) explicitly raised to
the user rather than picked unilaterally, since it materially changes
compiler behavior for the multi-error option.

### Disposition: all four editor items implemented in R10

| Item | Classification | Disposition |
|---|---|---|
| Status/line-position indicator | Usability | **Implemented.** "LINE n/m" on screen row 23, computed from V2's own generic line-store state (`V2_COUNT_LINES`/`CUR_EDIT_INDEX`), not V1's position-addressed mechanism. |
| Full-screen error display regression | Usability (V1 itself had already fixed this exact complaint once) | **Implemented.** `V2_SHOW_MESSAGE`'s error path no longer clears the whole screen; the message now shows on the status row, reusing its own mechanism, while the program view stays visible. |
| Keyword bolding | Debugging/workflow-adjacent, not purely cosmetic | **Implemented**, V2-native: reuses the COMPILER's real `KEYWORD_TABLE` directly (a tiny `V2_GET_KEYWORD_TABLE` HOME stub exposed via `include/v2_ktab.inc`, since HOME ROM is always readable regardless of EXROM's own paging state) — zero duplication of keyword data, no V1 table revived. Scans and bolds every keyword-shaped word in a line (not just the first), capped at 8 matches/line. |
| Error navigation | Debugging/workflow | **Implemented as single-error return-to-line** (see explicit design decision below), not V1's multi-error list. |

### Explicit design decision: single-error return-to-line, not multi-error list

This is an **intentional V2 design change from V1**, made explicitly by
the project owner after a cost/risk comparison (not picked
unilaterally):

- V1's static checker could collect and let the user browse up to 16
  compile-time errors (`CHECK_ERROR_LIST`).
- **V2 stops compilation at the first error and returns the cursor
  directly to that one source line** — `V2_JUMP_TO_ERROR_LINE`
  (`rom/exrom_v2_shell.asm`) captures `SRC_PTR` at the point
  `COMPILE_PROGRAM` fails, translates that staging-buffer offset back to
  a line-store index via a self-contained re-walk (deliberately NOT
  sharing code with `V2_BUILD_SOURCE`, so a future multi-error redesign
  can replace just this one routine), and sets `CUR_EDIT_INDEX` via the
  same `V2_SET_EDIT_FROM_INDEX` mechanism arrow-key navigation already
  uses. Only wired for stored-program RUN (`V2_RUN_STORED`), not
  immediate colon-statements, which have no separate stored line to jump
  to.
- **Full multi-error collection would require real compiler
  resynchronization/recovery** (`COMPILE_STATEMENT_LIST`'s own loop
  would need to catch-log-resync-continue instead of propagating the
  first error, plus a string-literal-aware panic-mode scanner to find
  the next safe statement boundary) — estimated ~350-500 bytes vs.
  single-error's actual measured 110 bytes, with a real, only
  prototype-provable cascade/spurious-error risk. **Deliberately
  deferred, not accidentally lost** — no compiler resynchronization or
  multi-error table was added in R10, per explicit instruction.
- **Runtime errors remain a separate, unresolved source-location
  problem in both designs**, not just this one: V1's `CHECK_ERROR_LIST`
  was populated by a *static* pre-RUN check, fundamentally different
  from V2's VM halting on the *first* runtime fault it actually reaches
  during execution — a halted VM has no way to know about "other"
  runtime errors it never reached. Mapping a runtime error back to a
  source line also has no mechanism today (bytecode carries no
  source-line backreference, and the decompiler that could reconstruct
  one isn't production-resident). Documented here as explicitly
  unresolved, not silently dropped.

### Known, disclosed edge case: trailing-operator errors can land one line late

Verified live on real hardware (ZEsarUX, via `ts2068-debug`), in two
shapes:

- **Mid-expression error** (e.g. `A = 3 + )`): lands exactly on the
  failing line. Confirmed.
- **Trailing-operator-at-end-of-line error** (e.g. `PRINT 3 +` followed
  by another line): lands one line **late** — on the line *after* the
  real failing line, not on it.

Root cause: `SRC_PTR` reflects wherever the compiler's own lexer
stopped, and most of the compiler's "`ld a,(COMPILE_ERROR_CODE)` / `or
a` / `jp nz,<bail>`" sites unwind without a further `LEX_NEXT_TOKEN`
call once the error is set — but a trailing-operator error specifically
needs one more lookahead token to discover "nothing valid follows,"
and that lookahead already crosses the line-separator CR into the next
line's first token before the error fires. This is a lexer-lookahead
artifact, not a bug in the line-translation logic itself (confirmed by
the mid-expression case landing exactly right).

**Per explicit instruction, no ROM was spent chasing this bounded edge
case in R10** — fixing it precisely would need the compiler's own
trailing-operator error site to capture its own `SRC_PTR` *before* the
extra lookahead, which is compiler surgery, not a small correction, and
was judged out of proportion to the benefit (the cursor still lands one
line away from the truth, not somewhere arbitrary). Recorded here as a
disclosed, known limitation for any future revisit, not a silent gap.

### Combined editor-restoration cost (measured, not estimated)

All four items were prototyped, measured individually AND merged
together into one real build (resolving a RAM-address collision where
all three independently-prototyped editor features had claimed the same
starting byte in the shared `$BE84-$BED7` reserved gap — a trivial
relocation, not a design conflict), and verified working together live
in ZEsarUX (status line, inline error display, bolded keywords, and the
error-navigation cursor-jump all observed simultaneously in one
session).

| | HOME delta | EXROM delta |
|---|---:|---:|
| Single-error return-to-line | 0 | −110 |
| Status line + inline error display (linked pair — the error-display fix reuses the status line's own row, not separable at comparable cost) | 0 | −78 |
| Keyword bolding | −6 | −257 |
| **All four combined** | **−6** | **−445** |

Combined with the Section 2 numeric fixes (+129 HOME), the total R10
ROM delta from the `da87dab` baseline is:

| | Before (`da87dab`) | After (R10) | Delta |
|---|---:|---:|---:|
| HOME free | 1,318 | 1,183 | −135 |
| EXROM free | 2,773 | 2,328 | −445 |

`make check`, `make test` (18/18 V2 standalone), and `make budget` all
pass with every R10 change combined in the primary tree.

## Sections 8-9 — Test/build infrastructure, ROM/RAM discipline

The test-architecture distinction established at `da87dab` (V1-derived
component harnesses vs. V2 HOME+EXROM standalone tests vs. genuine
production-integration tests) was preserved, not reopened. One new
standalone test (`rom/test_v2_r10_numeric.asm`) was added for the
Section 2 fixes, requiring a second shared calc-enabled EXROM build
variant in `tools/run_v2_standalone_tests.sh` (documented in that
script's own header) since it's the first migrated test needing
`TEST_V2_NEEDS_CALC`. No stale root-level binary dependency was
introduced. All generated test dependencies rebuild deterministically
(`make check`/`make test` confirmed clean from a fresh `da87dab`
checkout before any R10 change, and again after every change in this
milestone).

Every significant change's before/after/delta/purpose is recorded in
the tables above. RAM: 0 bytes reclaimed (Section 3, explained above);
0 bytes newly consumed for the Section 2 numeric fixes (they reuse
existing scratch cells: `VM_FLOAT_A/B_TAG/VAL` for the new `VM_CMP_
DISPATCH`, `VM_INPUT_TARGET_TMP`/`VM_INPUT_CHARBUF` aliased for `VAL`'s
own new decimal-point/fraction-count tracking); the editor restorations
consume 56 of the 84 bytes in the documented `$BE84-$BED7` reserved gap
(28 bytes remain free there). No valuable ROM/RAM was spent merely
because it became available — every byte above is tied to a specific,
disclosed correctness fix or user-approved capability restoration.

## Outstanding R10 work

- Stock TS2068 → V2 capability matrix (in progress, separate document:
  `docs/R10_STOCK_TS2068_CAPABILITY_MATRIX.md`).
- Final R10 completion commit (pending the above).
- Final report per the R10 spec's own Section 12 (pending the above).

R11 has not begun.

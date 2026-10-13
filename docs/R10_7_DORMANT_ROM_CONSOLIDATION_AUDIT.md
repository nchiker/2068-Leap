# R10.7 — Dormant ROM and consolidation audit (2026-10-03)

**STATUS UPDATE (2026-10-03, same day): the SAFE/LOW-risk candidates below
have since been APPLIED.** See `docs/R10_7_CAPABILITY_RESTORATION.md` §14
for the full implementation record (what was applied, measured byte deltas,
regression results). Summary of what changed from this audit's own original
findings:
- **Applied as-is**: all of §2.1's "B — Dead production ROM" except the 3
  `kernel/graphics/graphics.asm` sprite-routine findings (see correction
  below) — 367 bytes recovered (not the originally-estimated 543, due to that
  correction). D1, D2, D6, D7, D8 — 115 bytes recovered, matching estimates
  closely (D1 77B exact, D2 21B vs ~16B estimated, D6 9B exact, D7 5B vs
  ~3-6B estimated, D8 3B vs ~6B estimated).
- **CORRECTED — do not reuse these 3 findings**: `GFX_SPRITE_TRANSFER`,
  `GFX_SPRITE_BOUNDS_CHECK`, `GFX_SPRITE_INVALIDATE` (originally listed under
  §2.1 "B", ~137 bytes claimed) were all **false positives**, caught during
  pre-deletion verification, not left for a later surprise. All 3 are
  genuinely live: `GFX_SPRITE_BOUNDS_CHECK` is called internally by the live
  `GFX_SPRITE_SETUP` (same file, a plain `call` this audit's own search
  apparently missed); `GFX_SPRITE_TRANSFER` is reached via `jr` tail-jumps
  from the live `GFX_SPRITE_CAPTURE`/`DRAW` (not a `call`, exactly the shape
  a "grep for `call X`" search misses — flagged in this document's own §0 as
  a required check, but evidently not actually performed for this specific
  trio); `GFX_SPRITE_INVALIDATE` is called 4 times from elsewhere in the very
  same file (the search that produced this finding apparently excluded the
  defining file itself when checking for internal callers). **Lesson for any
  future pass reusing this methodology**: "called only by X" claims must be
  verified by a same-file self-reference check too, not just cross-file.
- **Deferred, not implemented**: D3 (needs a register-lifetime check first,
  not re-verified), D4, D5 (both need real design work, explicitly deferred
  per instruction, and D5 touches the exact `COMPILE_DIM`-family code where
  2 real correctness bugs — §0's own DIMN and identifier-length findings —
  were fixed in the same session; fix those first before any D5 attempt).
- **Two correctness bugs from §0 were fixed**, and verification found the
  identifier-length bug was **broader than this document originally
  reported** — it also affected string SCALAR assignment (`COMPILE_STR_
  ASSIGN_CONTINUED`) and `COMPILE_DIMN` itself, not only the 2 array sites
  originally listed. See `R10_7_CAPABILITY_RESTORATION.md` §14.3 for the
  full fix record and new test coverage.

---

**Status: READ-ONLY AUDIT. No production code was modified while producing this
document.** This audit was requested before any further HOME-budget work or
RAM-architecture change, on the hypothesis (borne out below) that recent
sessions kept finding useful dormant infrastructure or consolidation
opportunities that weren't obvious from the high-level architecture — dormant
`ARRAYS_END`/`VARS_START` infrastructure led to the dynamic-array redesign;
duplicated case-insensitive name-comparison loops produced a 42-byte win
(`NAME_CMP_FOLD`, see `R10_7_CAPABILITY_RESTORATION.md` §13); V1→V2/R9
transitions left some legacy infrastructure in the tree. This audit checks
whether more of the same remains before spending more HOME or restructuring
RAM for the deferred capacity increases.

**Method**: four parallel read-only research passes (forked from the same
session, each inheriting full prior context so they wouldn't re-flag
already-fixed issues), one per subsystem area, each doing direct
cross-repository reference search (not absence-of-obvious-caller) before
calling anything dead — explicitly checking indirect call paths (`VM_OP_TABLE`
dispatch, `include/v2_ktab.inc`'s `V2_KTAB_LIST`, `tools/write_v2_crossbank.py`'s
generated `NAMES` list, interrupt/startup vectors, extension dispatch) per the
task's own instruction. Findings below are organized by subsystem, each tagged
with the task's A-G classification.

---

## 0. Two real correctness bugs found (not shrink candidates)

Found incidentally while auditing `rom/exrom_v2_compiler.asm` for consolidation
opportunities. Neither was fixed (read-only task) — both should be triaged
separately from the shrink work below.

### Bug 1 — `DIMN` is not case-insensitive

`COMPILE_FACTOR.ident` matches the `DIMN` built-in via its own hand-rolled
4-byte compare loop against `DIMN_KEYWORD_TEXT` (`db "DIMN"`), using plain
`cp (hl)` with **no `FOLD_UPPER` call** — every other name-compare site in this
file was updated to use `FOLD_UPPER`/`NAME_CMP_FOLD` during the
case-insensitivity phase (item 12), but this one hand-rolled loop was missed.
`dimn(x)` or `Dimn(x)` typed in anything but all-uppercase silently falls
through (no match in `BUILTIN_FN_FIND` either) and compiles as a plain
identifier reference instead of the real `DIMN` builtin — a silent
misbehavior, not a compile error. `rom/test_v2_case_insensitive.asm` didn't
cover this because it doesn't happen to exercise `DIMN`. Fix is small (replace
the loop with `call NAME_CMP_FOLD`, B=4) but out of scope for this read-only
audit.

### Bug 2 — array names longer than 8 characters are broken for read/write

`COMPILE_DIM` clamps the array name length via `CLAMP_LEN8` before calling
`ARRSYM_FIND_OR_CREATE`, so a long name is stored truncated to 8 bytes. But
`COMPILE_FACTOR.ident`'s array-read path (`ld hl,(TOK_NAME) / ld a,(TOK_LEN) /
ld b,a / call ARRSYM_LOOKUP` — no clamp) and `COMPILE_ARRAY_ASSIGN` (via
unclamped `STMT_IDENT_NAME_LEN` from `STASH_IDENT_AND_PEEK`, which also never
clamps) both pass the full, unclamped length to `ARRSYM_LOOKUP`/`ARRSYM_SCAN`,
whose own length-compare requires an exact match against the stored (clamped)
length. Net effect: `DIM VERYLONGNAME(5)` followed by `VERYLONGNAME(0)=5`
raises error 42 ("never DIM'd") on write, and a read silently falls through to
auto-vivifying a plain scalar instead (wrong value, no error). Scalars don't
have this bug (`COMPILE_IDENT_LOAD`, the shared scalar read/create path,
always clamps). This appears pre-existing, not introduced this session, and
confined to arrays specifically. Not fixed — out of scope for this audit.

---

## 1. Findings by classification

### B — Dead production ROM

| Finding | File | Bytes | Confidence |
|---|---|---:|---|
| V1 runtime label-table subsystem (`MEM_LABEL_FIND/LOOKUP/ADD/REMOVE`) | `kernel/memory/memory.asm` | 331 | High — zero references outside this file, `basic/` (V1, unbuilt), old `include/exrom_jumptable.inc`/`kernel_api.inc` (unbuilt) |
| `GFX_SPRITE_TRANSFER` | `kernel/graphics/graphics.asm` | 95 | High — zero callers anywhere |
| `GFX_SPRITE_BOUNDS_CHECK` | `kernel/graphics/graphics.asm` | 28 | High — only caller (`rom/exrom_sprite.asm`) is itself unbuilt |
| `GFX_SPRITE_INVALIDATE` | `kernel/graphics/graphics.asm` | 14 | High — only caller is V1's `basic/editor_integration.asm` (unbuilt) |
| `STICK_READ` (joystick) | `kernel/io/io.asm` | 30 | High — V1-only callers |
| `IO_ANY_KEY_DOWN` | `kernel/io/io.asm` | 19 | High — V1-only callers |
| `IO_CHECK_BREAK` | `kernel/io/io.asm` | 18 | High — V1-only callers |
| `BANK_CALL_EXROM` | `kernel/bank/bank.asm` | 8 | High — only caller is an orphaned early isolation test, not run by any Makefile target or `tools/run_v2_standalone_tests.sh` |

**Subtotal: 543 bytes**, all HOME-resident, all verified via direct
cross-repository reference search. The `kernel/memory/memory.asm` V1
label-table block is the single largest finding in this entire audit — more
than 6× the size of this session's `NAME_CMP_FOLD` consolidation, and larger
than the entire S1-S5+N1 shrink pass combined (87 bytes).

Note: `rom/exrom_sprite.asm` and `basic/editor_integration.asm`/`basic/
basic.asm`/`include/exrom_jumptable.inc`/`include/kernel_api.inc` themselves
are **not** included by `rom/v2_home.asm` or `rom/v2_exrom.asm` — confirmed
not part of the shipped ROM at all. They are not separately counted as
"dead ROM" (they cost zero bytes in the actual build), but they are the
reason several `kernel/*.asm` routines above have no live caller: those
routines are V1-only machinery kept alive in shared kernel files that V2 also
includes, even though V2 itself never calls them.

### C — Dormant reusable service

None found with a clear "V2 should reuse this instead of X" shape beyond what
is already being reused. (`kernel/storage/storage.asm`'s services are already
the one real SAVE/LOAD/send/receive path, used directly by this session's own
array-persistence work.)

### D — Duplicate implementation

| Finding | File(s) | Net bytes | Risk |
|---|---|---:|---|
| D1 — 21× duplicated `xor a / call VM_PUSH / jp VM_RUN.loop` opcode-handler tail | `rom/exrom_v2_vm_core.asm` | **+77** | SAFE |
| D2 — 6× duplicated `cp TAG_INT / jp nz,VM_ERR_ARRAY_TYPE` type-check | `rom/exrom_v2_vm_core.asm` | **+16** | SAFE |
| D3 — 4× duplicated array/string-array operand-fetch prologue (2 shared routines, one per TMP-cell pair) | `rom/exrom_v2_vm_core.asm` | ~+24 (ESTIMADO) | SAFE, pending one check (see below) |
| D4 — `LEX_CLASSIFY_KEYWORD` vs `BUILTIN_FN_FIND` share a near-identical table-walk engine | `rom/exrom_v2_compiler.asm` | ~+20-35 (ESTIMADO) | MEDIUM — differing payload sizes and match contracts need careful parameterization |
| D5 — `COMPILE_DIM` vs `COMPILE_DIM_STR` share most of their skeleton | `rom/exrom_v2_compiler.asm` | ~+40-60 (ESTIMADO) | MEDIUM-HIGH — differing entry conventions and the string variant's extra comma/width branch |
| D6 — `EXT2_FOLD_UPPER` duplicates `FOLD_UPPER` byte-for-byte in every real production build | `kernel/extensions/ext_registry.asm` / `rom/exrom_v2_compiler.asm` | **+9** | LOW-MEDIUM — mechanically simple, but touches the exact case-insensitivity code that produced 3 regressions this session |
| D7 (micro) — `COMPILE_STR_FACTOR.ident` recomputes a clamp it already has | `rom/exrom_v2_compiler.asm` | ~+3-6 | SAFE, trivial |
| D8 (micro) — 2 sites in `COMPILE_ARR_ASSIGN_COMMON` could share a local raise-then-fall-through | `rom/exrom_v2_compiler.asm` | ~+6 | SAFE, trivial |

**Subtotal: ~195-233 bytes**, split between 2 unconditionally-SAFE VM-core
wins (D1+D2 = 93 bytes, no further verification needed) and several
MEDIUM-to-MEDIUM-HIGH-risk compiler-side candidates needing real design work,
not mechanical extraction.

D3's one open question: whether `VM_ARR_INDEX_TMP`/`VM_STRARR_INDEX_TMP` (and
their size/count counterparts) are ever live simultaneously within a single
opcode dispatch — if proven never simultaneous, all 4 sites (not just 2+2)
could share ONE routine for a larger win (~41 bytes instead of ~24); this
appears true by construction (array and string-array opcodes are disjoint)
but was not independently re-verified in this pass.

One explicitly-checked **non-finding**: the three near-identical tiny
case-fold routines now in the codebase (`FOLD_UPPER` and `EXT2_FOLD_UPPER`,
both HOME; `V2_MATCH_PREFIX`/`V2_MATCH_EXACT`'s own inline fold, EXROM) are
**not** consolidatable across the HOME/EXROM boundary — EXROM-resident code
cannot call a HOME routine directly without an `include/v2_ktab.inc` entry,
and adding one for a ~9-byte EXROM-side routine when EXROM has 1,708 bytes
free is not worthwhile. `EXT2_FOLD_UPPER`'s duplication (D6 above) is the one
real, same-bank instance worth fixing.

### E — Partially disconnected infrastructure

| Finding | File | Bytes | Note |
|---|---|---:|---|
| `MEM_LABEL_TABLE_CLEAR` | `kernel/memory/memory.asm` | 9 | Still executes (called unconditionally from `MEM_INIT`'s own tail `jr`), resetting state that finding B's label-table block shows nothing ever reads again. Technically live code serving only dead data. Removing it requires restructuring `MEM_INIT`'s own control flow (it currently ends by falling into this routine), not a pure deletion — bundle with the label-table removal rather than treat alone. |

### F — Test/legacy dependency

The 5 loadable extension modules (`rom/ext_mode_module.asm`,
`ext_sprite_module.asm`, `ext_printer_module.asm`, `ext_v2_shapes_module.asm`,
`ext_v2_graphics_module.asm`) and their `rom/v2_package_*.asm`
standalone-distribution wrappers are confirmed **not included by `rom/
v2_home.asm` or `rom/v2_exrom.asm` at all** — they exist only in their own
test files and as independently-assembled, separately-distributed TZX
binaries (`make v2-packages`). This is a legitimate, intentional parallel
distribution path (runtime-loadable extensions), not dead or legacy code, but
it means zero bytes of these modules are in the actual shipped HOME/EXROM
budget — no byte-recovery opportunity here regardless of what's inside them.
All 5 consistently use the real `EXT2_REGISTER` typed-argument mechanism — no
E finding (inconsistent adoption) here.

### G — Uncertain/indirect

- The ~300-byte "ROM driver, vectors and tables" block at the start of
  `rom/v2_home.asm` was not examined in depth in this pass (time-budget
  tradeoff by the auditing fork) — worth a quick dedicated look in a future
  pass, but nothing surfaced in a skim.
- Whether `rom/ext_sprite_module.asm` is wired into the default production
  EXROM boot path, or reachable only as a separately-loaded extension, was
  not resolved by either fork that touched sprite-adjacent code — doesn't
  change the "these 3 specific GFX_SPRITE_* routines are dead" finding
  either way, since nothing calls them regardless of that answer.

### A — Live/necessary (confirmed, no action)

- `include/v2_ktab.inc`'s `V2_KTAB_LIST` — all 24 entries verified to have a
  real caller in `rom/exrom_v2_shell.asm`. Already minimal; no dead entries.
- `tools/write_v2_crossbank.py`'s generated `NAMES` list — consumer-driven,
  spot-checked, no staleness found.
- `kernel/storage/storage.asm`'s SAVE/LOAD/send/receive routines — directly
  exercised by this session's own array-persistence work.
- `rom/exrom_format.asm`, `kernel/sound/sound.asm`, `rom/exrom_sound.asm`,
  `kernel/interrupt/interrupt.asm`'s `KBD_ISR_INIT/TICK`/`INT_GET_FRAMES`,
  `IO_KEY_STILL_DOWN` — all confirmed live via real test-stub patterns.
- `VM_PREPARE_BINARY_OPERANDS`, `VM_CMP_DISPATCH`, `VM_FLOAT_BINARY_COMMON`,
  `ARENA_ALLOC_NUMERIC`/`STRING`, `VM_ARR_VALIDATE_INDEX` — already correctly
  shared from prior passes; every `VM_OP_TABLE` opcode slot (0-66)
  cross-checked against the compiler's own `EMIT_OP_*` sites and confirmed
  genuinely emitted/live, including the late R10.7 FLASH/BRIGHT/OVER/
  INVERSE/AT/TAB/CLEAR additions.
- `COMPILE_1ARG_STMT`, `COMPILE_EXPECT_COMMA_EXPR`, `COMPILE_ARR_ASSIGN_COMMON`,
  `EMIT_IDX_COUNT`/`EMIT_ARR_OPERAND` — already genuinely shared, re-confirmed
  not to need further work.
- `rom/exrom_editor.asm` — checked specifically for a V1-holdover
  keyword-highlighter duplicating `V2_KW_DETECT_SPANS`; found none (the file's
  own comments correctly defer to where the real V2 mechanism now lives).

---

## 2. Total estimated opportunity

| Category | Bytes | Confidence |
|---|---:|---|
| B — dead production ROM | 543 | High (direct reference search) |
| D1+D2 — VM-core duplicate tails/checks (SAFE) | 93 | High (exact text match, arithmetic shown) |
| D3 — VM-core operand-fetch prologue | ~24 | Estimado, SAFE pending one easy check |
| D4+D5 — compiler table-walk/DIM skeleton | ~60-95 | Estimado, MEDIUM/MEDIUM-HIGH risk |
| D6-D8 — misc small compiler dups | ~18-21 | Estimado, SAFE/LOW-MEDIUM |
| E — `MEM_LABEL_TABLE_CLEAR` | 9 | Bundle with B's label-table removal |
| HOME/EXROM services (prior report) | 17 | High |
| **Total** | **~764-802 bytes** | — |

For scale: current HOME free is 91 bytes. The dead-code finding alone (543
bytes) is roughly 6× the entire shrink pass just completed this session, and
would take HOME free from 91 to approximately **634 bytes** on its own,
before any of the duplicate-code consolidation is even considered.

---

## 3. Recommended consolidation order

1. **Dead-code removal (B, 543 bytes + E's 9 bytes = 552 bytes)** — by far the
   largest, and the lowest-design-risk category: these are whole routines
   confirmed to have zero live callers, not partial extractions. The main
   residual risk is mechanical (don't delete a routine another dead routine
   in the same block still calls internally — check each block's own internal
   references before deleting, not just external ones) and the `MEM_INIT`
   control-flow restructuring needed for `MEM_LABEL_TABLE_CLEAR`. Recommend
   doing `kernel/memory/memory.asm` (331B, the label table) and `kernel/io/
   io.asm` (67B) first — both are clean "delete this unreferenced block"
   operations. `kernel/graphics/graphics.asm`'s 3 sprite routines (137B) and
   `BANK_CALL_EXROM` (8B) next.
2. **D1+D2 (VM core, 93 bytes, SAFE)** — same mechanical, low-risk shape as
   this session's own S1-S5/N1 work; apply with the same build+budget+test-
   after-each-group discipline already established.
3. **D3 (VM core, ~24 bytes)** — after confirming the TMP-cell
   never-simultaneous assumption, either as 2 routines (~24B) or 1 (~41B if
   the stronger assumption holds).
4. **D6-D8 (compiler, misc, ~18-21 bytes)** — small, mechanical, same
   discipline.
5. **D4/D5 (compiler, ~60-95 bytes, MEDIUM/MEDIUM-HIGH risk)** — hold for a
   dedicated design pass, not a quick mechanical extraction; the two
   correctness bugs found in this same file (§0) suggest extra care is
   warranted here specifically before further mechanical changes.

---

## Safe consolidation candidates before further R10.7 work

- Dead-code removal: `kernel/memory/memory.asm`'s V1 label-table subsystem
  (331B) + `MEM_LABEL_TABLE_CLEAR` (9B), `kernel/io/io.asm`'s `STICK_READ`/
  `IO_ANY_KEY_DOWN`/`IO_CHECK_BREAK` (67B), `kernel/graphics/graphics.asm`'s
  `GFX_SPRITE_TRANSFER`/`BOUNDS_CHECK`/`INVALIDATE` (137B), `BANK_CALL_EXROM`
  (8B). **552 bytes, high confidence, low mechanical risk.**
- D1 (21-site `PUSH_INT_CONTINUE` tail, 77B) and D2 (6-site `VM_POP_CHECK_INT`,
  16B) in `rom/exrom_v2_vm_core.asm`. **93 bytes, SAFE, same discipline as
  this session's own shrink pass.**
- D6 (`EXT2_FOLD_UPPER`/`FOLD_UPPER` dedup, 9B) — small but real, same risk
  class as the rest of the case-insensitivity machinery; do it alongside a
  full regression run specifically because of that history.
- D7/D8 (micro compiler dups, ~9-12B) — trivial, do opportunistically.

**Combined: ~654 bytes recoverable with LOW-to-SAFE risk**, before touching
anything flagged MEDIUM or higher. This alone would take HOME free from 91
bytes to roughly 745 bytes — more than enough headroom to revisit the
capacity-increase question without the RAM-relocation pressure that made it
feel urgent.

## Items that should wait for the full pre-R11 dormant-architecture audit

- D3's TMP-cell simultaneity question (if resolved favorably, folds into the
  SAFE list above, but deserves its own explicit verification step first).
- D4 (`LEX_CLASSIFY_KEYWORD`/`BUILTIN_FN_FIND` table-walk consolidation,
  ~20-35B) and D5 (`COMPILE_DIM`/`COMPILE_DIM_STR` skeleton consolidation,
  ~40-60B) — both MEDIUM/MEDIUM-HIGH risk, both need real design work (not
  mechanical extraction), and D5 in particular touches the same file where
  this audit found 2 real pre-existing correctness bugs — worth fixing those
  bugs first and re-establishing full test coverage before further structural
  changes to `COMPILE_DIM`/`COMPILE_DIM_STR`.
- The two correctness bugs in §0 (`DIMN` case-insensitivity gap, array names
  >8 chars broken for read/write) are not shrink candidates at all and should
  be triaged as bugs — recommend fixing them before or alongside D5, since
  D5's own consolidation will necessarily touch the exact code paths involved.
- The ~300-byte ROM driver/vectors block at the start of `rom/v2_home.asm`
  (unexamined in this pass — G, uncertain).
- Whether `rom/ext_sprite_module.asm` is reachable from the default
  production boot path (doesn't block removing the 3 dead `GFX_SPRITE_*`
  routines either way, but is a relevant architecture question for the full
  audit).

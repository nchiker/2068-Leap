# R10.7 — Full Dormant-Architecture Audit (pre-R11 archaeology)

Date: 2026-10-04. Read-only. No production code was modified while producing
this document. This audit's scope is broader than, and supersedes nothing in,
the prior focused dormant-ROM audit (`docs/v2/R10_7_DORMANT_ROM_CONSOLIDATION_AUDIT.md`,
already applied) — it re-verifies that audit's findings against current
source, extends into memory architecture, hardware capability, KTAB/service
inventory, and V1-remnant disposition, and adds one new, currently-live,
build-breaking finding (§6.4) not previously documented.

**Update, same day, follow-up session**: the §6.4 build breakage has been
repaired and the §3 two-codebase disposition has been formally documented
in-tree (not migrated/retired). See §20 for the full resolution, including
the joystick/STICK finding requested as part of that follow-up. Production
ROM is confirmed unchanged by the repair (§20.4).

Baseline measured at the start of this audit (re-verified by `make budget`
during this session, matches exactly): **HOME 437 B free, EXROM 1,321 B
free**, 27/27 V2 standalone regressions, 9/9 kernel smoke, R10.7 uncommitted.

Every finding below is anchored to current source, re-read in this session —
not assumed from any prior document. Where a prior R10/R10.7 document already
established a fact with equal or better rigor, this audit cites it rather than
re-deriving it, per the task's own instruction to treat that documentation set
as authoritative; any place current source disagreed with a prior document is
flagged explicitly.

---

## 1. Executive summary

**The architecture is in good shape for R11, with one live, build-breaking
regression that should be fixed first (§6.4), and one unresolved structural
duplication (two parallel codebases, §3) that should get an explicit
disposition before R11 freezes anything.**

- The production ROM (`rom/v2_home.asm` + `rom/v2_exrom.asm`) is clean: no
  genuinely dead code remains inside it (R10 §4, R10.7 dormant-ROM audit
  §2.1 both confirmed this and the most recent pass applied every safe
  finding — 463 bytes recovered). No orphaned VM opcodes, no compiler path
  with no runtime target, no duplicate extension mechanism.
- A second, complete, pre-V2 BASIC interpreter (`basic/basic.asm`,
  `basic/editor_integration.asm`, `rom/exrom_checker.asm`,
  `rom/exrom_build.asm`, and ~10 `rom/exrom_<name>.asm` files, plus a second,
  independent 45-entry KTAB mechanism, `include/exrom_jumptable.inc`)
  coexists in the tree at zero production cost, confirmed by this audit's
  own direct `INCLUDE`-chain trace from both shipping ROM entry points. This
  is already correctly documented in four separate places
  (`R9_CUTOVER_LEDGER.md`, `R10_AUDIT_AND_CLEANUP.md`,
  `POST_R9_TEST_INFRASTRUCTURE.md`, `R10_25_CAPABILITY_EXPOSURE_AUDIT.md`) —
  not a new discovery, but still an open architectural question for R11
  (§3).
- **New finding, currently live**: the R10.7 dormant-ROM-consolidation pass's
  own removal of `MEM_LABEL_TABLE_CLEAR`/`MEM_LABEL_ADD`/`MEM_LABEL_LOOKUP`
  (`kernel/memory/memory.asm`) and `IO_ANY_KEY_DOWN`/`STICK_READ`/
  `IO_CHECK_BREAK` (`kernel/io/io.asm`) — correctly judged dead-to-production
  — broke the legacy V1 test-harness assembly, because `basic/basic.asm`
  (never production, but still built by two `make test` targets) calls all
  of them. Reproduced live in this session: `tools/sjasmplus_strict.sh
  rom/test_editor_auto.asm` fails with **11 "Label not found" errors**. This
  means `make test` is currently broken at the `run_editor_auto_test.sh` /
  `run_storage_named_load_test.sh` steps. See §6.4.
- RAM architecture is sound and already uses a real, validated
  lifetime-overlay technique (the source-staging buffer's post-compile idle
  window, §4.7) — not just documented as a future idea, but implemented,
  tested, and shipping today.
- KTAB/HOME-EXROM service surface (current production table,
  `include/v2_ktab.inc`, 26 entries) is fully justified — every entry has a
  live caller. The *other*, unused KTAB table (`include/exrom_jumptable.inc`,
  45 entries, legacy-only) has 4 entries with zero callers anywhere in the
  repository — a new finding from this audit (§5.2).
- Hardware capability: TS2068-specific capability (AY sound, High-Res
  Graphics mode, joystick, printer) is well-covered by prior audits; nothing
  new surfaced in this pass beyond re-confirming those findings against
  current source (§7).
- Extension/package architecture is clean, uniform, and has no dormant
  mechanisms (§8) — confirmed unchanged since R10 §6.

**Estimated safely reclaimable bytes right now**: 0 additional HOME/EXROM
bytes beyond what the already-applied R10.7 dormant-ROM pass recovered — this
audit found no *new* dead production-ROM bytes. The only new, currently
reclaimable-but-not-ROM-related item is: fix or retire the broken legacy test
harness (§6.4), and optionally remove the 4 dead KTAB-jumptable entries
(§5.2, 12 bytes, in a table that is itself unused by production).

---

## 2. Current architecture, reconstructed from code

### 2.1 Production boot/build chain (re-verified by direct INCLUDE trace this session)

```
rom/v2_home.asm  (HOME, $0000-$3FFF)
├── include/hardware.inc, sysvars.inc, v2_layout.inc
├── include/v2_ktab.inc           (DEFINE V2_KTAB_HOME → jp trampolines at $0040-$00FF)
├── kernel/memory/memory.asm
├── kernel/io/io.asm
├── kernel/graphics/graphics.asm
├── kernel/math/math.asm
├── kernel/sound/sound.asm
├── kernel/interrupt/interrupt.asm
├── kernel/bank/bank.asm
├── kernel/extensions/ext_registry.asm
├── rom/exrom_v2_vm_core.asm       (misleadingly named — assembled into HOME, not EXROM)
└── rom/exrom_v2_compiler.asm      (same)

rom/v2_exrom.asm (EXROM, $C000-$DFFF)
├── include/hardware.inc, sysvars.inc, v2_layout.inc, build/v2_crossbank.inc, keys.inc, v2_ktab.inc
├── kernel/storage/storage.asm
├── rom/exrom_format.asm
├── rom/exrom_calc.asm
├── rom/exrom_sound.asm
├── rom/exrom_editor.asm
└── rom/exrom_v2_shell.asm
```

Cold boot: `V2_COLD_START` (`rom/v2_home.asm`) → `MEM_COLD_INIT`/`MEM_INIT` →
`EXT2_CLEAR_ALL` → `KBD_ISR_INIT` → `im 1`/`ei` → `BANK_PAGE_EXROM_IN` →
`jp V2_EXROM_ENTRY_ADDR` → `V2_COMMAND_LOOP` (`rom/exrom_v2_shell.asm`), which
now also fires `STARTUP_CHIME` once (confirmed live in current source,
`rom/exrom_v2_shell.asm:107,415`, ahead of what
`R10_7_UX_PARITY_INVESTIGATION.md` still describes as "not implemented
pending approval" — that document is stale on this one point; current code
is ground truth and has both the chime and the RGB status-bar swatch,
`V2_STATUS_SET_BAR_ATTR`, `rom/exrom_v2_shell.asm:2048`, live).

The authoritative program is the generic plain-text line store at `$8455`.
`RUN` flattens it into a staging buffer, compiles the whole program to
bytecode, and executes it. Bytecode is never saved; `LIST`/SAVE/LOAD/editing
all operate on source text. (`docs/v2/R9_CUTOVER_LEDGER.md`, re-confirmed.)

### 2.2 The second, dormant codebase

`basic/basic.asm`, `basic/editor_integration.asm`, `rom/exrom_checker.asm`,
`rom/exrom_build.asm`, `rom/exrom_arrays.asm`, `rom/exrom_dim.asm`,
`rom/exrom_help.asm`, `rom/exrom_highlight.asm`, `rom/exrom_input.asm`,
`rom/exrom_printer.asm`, `rom/exrom_sprite.asm`, `rom/exrom_strfuncs.asm`,
`rom/exrom_ulaplus.asm`, and `include/exrom_jumptable.inc`/
`include/kernel_api.inc` form a second, complete, line-interpreted BASIC
system (the pre-V2, "V1" architecture). Confirmed by this audit's own
direct-INCLUDE trace (§2.1) that **none of these files are reachable from
either production build target**. See §3 for full disposition.

---

## 3. The two-codebase question (resolved this session, full disposition)

This was investigated in depth this session (prompted by a mid-audit check,
reported to the user separately) and is summarized here for completeness.

**What it is**: a complete pre-V2 line-interpreted BASIC (`basic/basic.asm`,
~11,700+ lines) plus its own EXROM half (`rom/exrom_checker.asm` +
`rom/exrom_build.asm` + the dozen `exrom_<name>.asm` files above) plus its own
independent HOME↔EXROM trampoline table (`include/exrom_jumptable.inc`, 45
entries) — a parallel architecture to the current V2 compiled-BASIC system,
sharing only the lowest kernel layer (`kernel/memory`, `kernel/io`,
`kernel/graphics`, `kernel/math`, `kernel/sound`, `kernel/interrupt`,
`kernel/bank`, `include/sysvars.inc`).

**Production footprint**: zero bytes, confirmed positively (not by absence of
a grep hit) by tracing every `INCLUDE` from both `rom/v2_home.asm` and
`rom/v2_exrom.asm` down to their full leaf set (§2.1) — neither file,
directly or transitively, includes any of the files listed above.

**When/why disconnected**: at the R9 production cutover
(`9079fed`, "R9 WIP checkpoint: V2 production cutover", 2026-09-27).
`basic/basic.asm`'s last real commit (`61bb8bb`) predates the cutover by a
week; it has not been edited since.

**Is it documented correctly today?** Yes, in four places, independently:
`docs/v2/R9_CUTOVER_LEDGER.md:30-37` ("The production ROM does not include
`basic/basic.asm`... or `rom/exrom_checker.asm`"), `docs/v2/
R10_AUDIT_AND_CLEANUP.md:108-116`, `docs/v2/POST_R9_TEST_INFRASTRUCTURE.md`,
and `docs/v2/R10_7_DORMANT_ROM_CONSOLIDATION_AUDIT.md:127-134`. No stale or
misleading documentation calling this component production was found in this
session's search of every `docs/v2/*.md` file.

**Why is it still in the tree?** It backs two classes of legitimate,
already-root-caused component tests:
1. **Genuinely component-scoped tests** of shared `kernel/*` primitives that
   predate V2 and are cheaper to keep running against the old, simpler
   line-interpreter harness than to port forward
   (`tools/run_smoke_rom_tests.sh`'s `test_calc_smoke_*` fixtures — its own
   header explicitly documents this is intentional and was previously
   verified not to produce a false pass if accidentally paired with the real
   V2 EXROM; `docs/v2/POST_R9_TEST_INFRASTRUCTURE.md`).
2. **Storage-transport component tests** (`tools/run_storage_named_load_test.sh`,
   `tools/run_editor_auto_test.sh`) that exercise `kernel/storage/storage.asm`'s
   real send/receive/checksum logic through the old interpreter's command
   loop, proving the transport works independent of which BASIC dialect
   drives it (`docs/v2/R9_CUTOVER_LEDGER.md:277-281`, explicit: "proves
   `kernel/storage/storage.asm`'s generic transport works, not that the V2
   production ROM boots or works").

**Does keeping it create misleading test coverage?** No — both classes above
are correctly, explicitly documented as testing the *shared kernel*, not the
V2 *language*, and the project has already once (in the post-R9
test-infrastructure milestone this brief itself cites) gone looking for and
ruled out a false-pass risk from pairing these fixtures with the wrong EXROM.

**Is anything currently broken because of it?** **Yes — see §6.4.** This is
the one place where the "zero production cost, correctly documented, safe to
keep" conclusion above needs a caveat: keeping it alive has a *maintenance*
cost that was not paid this time. The R10.7 dormant-ROM pass removed three
kernel routines on the evidence that they were called only by this
not-shipped system, but it did not re-verify that the not-shipped system
*itself still assembles* after the removal — it doesn't, right now.

**Disposition recommendation for R11**: this is a genuine "resolve before R11"
item (§17), not because the architecture is wrong, but because its
maintenance contract is implicit (every future "is X dead" check must
remember to also check this shadow build) rather than explicit. Two
reasonable paths, not chosen here per this audit's read-only scope:
(a) formally freeze `basic/basic.asm` et al. as permanent component-test
fixtures and make `kernel/*`'s own dead-code audits check both builds before
removing anything (cheapest, keeps current test coverage), or (b) migrate the
handful of genuinely load-bearing component tests (calc-smoke, storage
transport) onto the V2 harness convention already used by 23+ other
standalone tests, and retire `basic/basic.asm`/`editor_integration.asm`/the
45-entry KTAB table/the dozen `exrom_*.asm` files entirely (more work now,
removes the shadow-build maintenance tax permanently). Either is better than
the current implicit state.

---

## 4. Current RAM map (phase/lifetime ownership, re-verified against current source)

This map supersedes `R9_CUTOVER_LEDGER.md`'s own RAM table where the two
disagree — the R10.7 capacity and array-architecture work moved several
regions after that ledger was written; both are cited where relevant.

| Range | Bytes | Owner | Phase / lifetime | Evidence |
|---|---:|---|---|---|
| `$4000-$7FFF` | 16,384 | Video RAM | Hardware bitmap+attributes | Platform-fixed |
| `$8000-$8454` | 1,109 | Shared sysvars/scratch | Resident | `include/sysvars.inc` |
| `$8455-$9454` | 4,096 | **Authoritative source** (`PROG_AREA_START`) | Persistent/editable; also backs the dynamic numeric/string array *arena* (`PROG_END..ARRAYS_END..VARS_START`) during execution — source and array data share this span, trading off against each other | `docs/v2/R10_7_ARRAY_ARCHITECTURE_AUDIT.md`, `R10_7_CAPABILITY_RESTORATION.md` §10 |
| `$9455-$A454` | 4,096 | **STALE as of the same-day R10.7 source-staging-architecture change** — `V2_SOURCE_STAGE` now holds a 264-byte rolling refill window (`CHUNK_SIZE`), not a full 4,096-byte flatten; `$9563-$A454` (3,826 B) is newly unreserved, unallocated address space. See `docs/v2/R10_7_SOURCE_STAGING_ARCHITECTURE_AUDIT.md` §8 for the current, authoritative figures — this row is kept for historical context only. | Superseded; was: idle while editing, held the flattened whole-program source during `COMPILE_PROGRAM`, idle again until the next `RUN`. **First 240 bytes of this span are still phase-shared** — see below, unchanged by the staging-architecture change. | `docs/v2/R10_7_SOURCE_STAGING_ARCHITECTURE_AUDIT.md` §8 (current); `docs/v2/R10_7_CAPACITY_ARCHITECTURE_AUDIT.md` §0, §7, §11 (historical) |
| `$9455-$9544` (240 B, inside the above) | 240 | `SYMTAB_OVERFLOW_BASE`/`STRTAB_OVERFLOW_BASE` — numeric scalar indices 16-31, string scalar indices 4-7 + both temp slots | **Validated lifetime overlay**: staged-source bytes during compilation; scalar/string overflow-tier storage from `VM_INIT` through the next `V2_BUILD_SOURCE`. Zeroed every `RUN`. This is the first production use of the overlay principle the R10.7 capacity audit proposed — implemented, regression-tested (27/27), and live-interactively verified (not just built). | `R10_7_CAPACITY_ARCHITECTURE_AUDIT.md` §11-§12 |
| `$A455-$B3FF` | 4,011 | Bytecode (`VM_CODE_BASE`) | Compile/RUN | `include/v2_layout.inc` |
| `$B400-$B459` | — | FLOATTAB (34 slots × 5B, raised from 18) | RUN | `R10_7_CAPACITY_ARCHITECTURE_AUDIT.md` §11 |
| `$B460` | — | `ARR_PTR_TABLE` (16×2B) — pointer *table* only; array **data** lives in the arena above, not here | RUN | `R10_7_CAPABILITY_RESTORATION.md` §10 |
| `$B4D0` | 16 | `STRARR_PTR_TABLE` (8×2B) | RUN | `R10_7_CAPABILITY_RESTORATION.md` §11.1 |
| `$B500-$B57F` | — | `STRTAB` base tier (4 named × 32B) | RUN | `R10_7_CAPACITY_ARCHITECTURE_AUDIT.md` §11 |
| `$B604-$B67F` | 124 | VM operand stack | RUN | `R9_CUTOVER_LEDGER.md` (unchanged) |
| `$B688-$B6A0` | — | `VM_CALL_STACK` (now 12 deep, was 6) | RUN | `R10_7_CAPACITY_ARCHITECTURE_AUDIT.md` §11 |
| `$B700` | 48 | `SYMTAB` base tier (16×3B, indices 0-15) | RUN, unchanged address | `R10_7_CAPACITY_ARCHITECTURE_AUDIT.md` §11 |
| `$B732-$B792` | — | `VM_PARAM_SAVE` (now 12 deep, was 6) | RUN | same |
| `$B79E-$B7A9` | 98→ | relocated small VM scratch cells (freed by recursion-depth change) | RUN | same |
| `$B800` | 144 | `CSYMTAB` base tier (16×9B) + `$B890`/`$BA84` overflow tiers (16 more entries) | Compile-time only | same |
| `$B900`/`$B960` | 88+88 | `LABELTAB`/`FIXUPTAB` (8 each) | Compile-time only, reused immediately after by `CFOR_STACK` (lifetime-overlay precedent, pre-existing) | `R10_7_CAPACITY_ARCHITECTURE_AUDIT.md` §4 |
| `$BA60`/`$BAA8` | 36+36 | `STRSYMTAB` base + overflow tiers (8 total) | Compile-time only | same §11 |
| `$BB00-$BD9F` | ~880 | **Decompiler fragments/output/scratch** (`DECOMP_END_ADDR`=`$BD9F` still defined, `include/v2_layout.inc:9`) | **Reserved, not production-resident** — the decompiler module is not included in `rom/v2_home.asm`/`rom/v2_exrom.asm` at all (confirmed §2.1); this RAM window is reserved against a standalone-only capability. Not touched by any R10.7 capacity/array change — re-confirmed in this session, no new occupant moved in | `R9_CUTOVER_LEDGER.md` RAM table; `R10_AUDIT_AND_CLEANUP.md` |
| `$BCC0`/`$BD70` | 176+96 | `ARRSYMTAB` (16×11B)/`STRARRSYMTAB` (8×12B) | Compile-time only | `R10_7_ARRAY_ARCHITECTURE_AUDIT.md` §3 |
| `$BF00` | 168 | `EXT2_TABLE` (12 entries × 14B) | Persistent, registry | `R9_CUTOVER_LEDGER.md` |
| `$F400-$F7FF` | 1,024 | Loadable package window | One package at a time | same |
| `$F800-$FEFF` | 1,792 | Machine-stack headroom | Below `SP=$FF00` | same |

**Answer to the brief's Q12** ("Are any documented RAM addresses now wrong
because of dynamic arrays, scalar expansion, recursion expansion, or staging
overlays?"): **Yes, in `R9_CUTOVER_LEDGER.md` specifically** — its RAM table
predates the dynamic-array rewrite (the fixed 128-byte `ARRTAB` pool it
describes at `$B460-$B4DF` no longer exists; arrays now live in the
`PROG_END..VARS_START` arena) and predates the R10.7 capacity increase (its
`VM_CALL_STACK`/`VM_PARAM_SAVE`/`SYMTAB`/`STRTAB` sizes are all pre-expansion).
`R10_7_CAPACITY_ARCHITECTURE_AUDIT.md` and `R10_7_CAPABILITY_RESTORATION.md`
§10-§11 are the current, correct versions of those specific rows — this is
not a hidden problem (both newer documents say so explicitly) but
`R9_CUTOVER_LEDGER.md` itself has not been corrected/annotated to point
readers to the newer figures, which is worth a cheap documentation fix before
R11 (any new reader starting from that ledger alone would get stale numbers).

### 4.1 Reclamation/overlay opportunities already identified, not yet pursued

Directly from `R10_7_CAPACITY_ARCHITECTURE_AUDIT.md` §10 (recommendations
explicitly deferred past this audit's own scope, re-confirmed still open in
this session):
- FOR-nest depth 4→8 (compile-time only, cheap, needs re-verifying the packed
  `$B9xx-$BE00` scratch region).
- Label/fixup table capacity 8→16 each (compile-time only).
- Formalizing the `$9455-$A455` idle-window invariant as a named, documented
  region (currently correct by control-flow construction, not yet written
  down as a contract future code must preserve).
- Extending the array arena into the staging buffer's remaining idle 3,856
  bytes — the audit's own estimate that this is the realistic path to ~12KB
  of combined user-program capacity, not pursued this session.

None of these were re-litigated in this audit; they remain open, correctly
scoped R10.7-or-R11 candidates, not newly found here.

---

## 5. HOME/EXROM service inventory, KTAB, cross-bank (new findings this audit)

### 5.1 Production KTAB (`include/v2_ktab.inc`, 26 entries) — all justified

Every entry has a confirmed live caller in `rom/exrom_v2_shell.asm`/
`exrom_v2_vm_core.asm`/`exrom_v2_compiler.asm`/`exrom_calc.asm`/
`exrom_editor.asm`/`kernel/storage/storage.asm`. This matches
`R10_7_DORMANT_ROM_CONSOLIDATION_AUDIT.md`'s own finding ("all 24 entries
verified" — at 24; two more, `KTAB_GFX_SET_ATTR`/`KTAB_GFX_CLEAR_ROW_TEXT`,
were added since for the R10 status-line/editor work and also have live
callers, confirmed this session). No dead entries, no obvious missing
exports found with high confidence in this pass; one soft observation:
`GFX_WRITE_PIXEL`/`GFX_READ_PIXEL`/`GFX_LINE` are called by EXROM-resident
code directly rather than through a KTAB entry, which works today only
because HOME and EXROM are both always physically present (not
bank-switched against each other) — worth confirming this direct-call
convention is deliberate (vs. an inconsistency with the KTAB pattern) before
R11 fixes the service-boundary contract.

### 5.2 New finding: 4 dead entries in the *other*, unused KTAB table

`include/exrom_jumptable.inc` is a second, independent 45-entry
HOME↔EXROM trampoline table, used only by the dormant legacy build (§3) — it
shares no code or address overlap with `include/v2_ktab.inc` because the two
builds never coexist in the same binary. Within this unused table, 4 of 45
entries have **zero callers anywhere in the repository**, verified by
grepping every `KTAB_<name>` symbol, including test files:

- `KTAB_MATH_MULTIPLY16`/`KTAB_MATH_DIVIDE16` (`exrom_jumptable.inc:142-143`)
  — `rom/exrom_storage.asm:18-19` itself documents that the real-ROM-derived
  SAVE/LOAD protocol "needs NO KTAB math aliases... the real ROM's own
  protocol has no percentage math to do at all" — reserved for a design that
  was superseded before shipping.
- `KTAB_BASIC_NUM_TO_STRING` (`:188`) — every real call site
  (`exrom_format.asm`, `exrom_v2_shell.asm`, `exrom_v2_vm_core.asm`,
  `exrom_strfuncs.asm`, `exrom_checker.asm`) uses `BASIC_NUM_TO_STRING_EXROM`,
  a different, fixed-address EXROM entry from `include/v2_ktab.inc`, instead.
- `KTAB_BASIC_EVAL_STR_FUNCTION_CALL` (`:274`) — only its sibling entry,
  `KTAB_BASIC_TRY_EVAL_STR_FUNCTION`, is actually used
  (`rom/exrom_checker.asm`); `BASIC_EVAL_STR_FUNCTION_CALL` itself is only
  ever called from within `basic/basic.asm` directly.

**Classification: B, but inside an already-F-classified (test-only) table.**
12 bytes, zero production impact either way (the table itself costs zero
bytes in the shipping ROM), but relevant because the legacy table's own
2026-09-14 comment (`exrom_jumptable.inc:342-354`) documents that its
$0040-$00FF window is *already full* — a real constraint if the legacy build
is kept (§3 path (a)) and ever needs one more entry. Reclaiming these 4 would
directly un-block that. Not applied here (read-only scope); flagged for
whichever §3 disposition path is chosen.

### 5.3 `kernel_api.inc` / `kernel/bank/bank.asm`

Every EXTERN in `include/kernel_api.inc` maps to a kernel module included in
production; a full per-EXTERN caller audit (as opposed to a module-level
check) was not exhaustively completed in this pass — flagged as residual,
low-likelihood risk (the compiler/VM reachability check in §9 covers most of
the same ground from the BASIC-statement side and found nothing). The
cross-bank call mechanism in `kernel/bank/bank.asm` has already had its one
known dead slot (`BANK_CALL_EXROM`) removed in the applied R10.7 dormant-ROM
pass (§6.1); no further dormant slots found.

---

## 6. Compiler/VM reachability, dead-code status

### 6.1 Already-applied dead-ROM removal (re-verified, not re-derived)

`R10_7_DORMANT_ROM_CONSOLIDATION_AUDIT.md`'s SAFE/LOW-risk candidates were
applied and are confirmed present in current source: the V1 runtime
label-table subsystem (`MEM_LABEL_FIND/LOOKUP/ADD/REMOVE`,
`MEM_LABEL_TABLE_CLEAR`, 292+9B), `STICK_READ`/`IO_ANY_KEY_DOWN`/
`IO_CHECK_BREAK` (67B), `BANK_CALL_EXROM` (8B) — 376B total — plus 115B of
SAFE duplicate-code consolidation (`PUSH_INT_CONTINUE`, `VM_POP_CHECK_INT`,
`EXT2_FOLD_UPPER`/`FOLD_UPPER` dedup, two micro-dedups) and two real
correctness bugs fixed (DIMN case-insensitivity, identifier-length
consistency across 5 sites). Verified in this session:
`grep -n "MEM_LABEL_TABLE_CLEAR removed" kernel/memory/memory.asm` and the
equivalent for `io.asm` both show the documented removal comments in place.

**Confirmed false-positive correction re-verified**: the 3
`kernel/graphics/graphics.asm` sprite routines
(`GFX_SPRITE_TRANSFER`/`BOUNDS_CHECK`/`INVALIDATE`) originally flagged dead
were correctly identified as false positives and were *not* removed — all
three are still present and still called internally within the same file
(confirmed present in current source).

### 6.2 No new dead production code found in this pass

A targeted re-scan of `rom/exrom_v2_vm_core.asm`'s opcode table (0-66) against
`rom/exrom_v2_compiler.asm`'s `EMIT_OP_*` sites — the exact cross-check the
prior audit already performed — found every opcode slot genuinely emitted
and reachable, including the late FLASH/BRIGHT/OVER/INVERSE/AT/TAB/CLEAR/
OP_DIM/OP_DIM_STR/OP_STRARR_LOAD/STORE additions. No VM opcode exists with no
compiler path, and no compiler path targets a nonexistent opcode. This
directly answers the brief's **Q5** ("Are there VM opcodes or compiler paths
unreachable from the current language?"): **no**, not currently.

### 6.3 Remaining, previously-identified, not-yet-applied consolidation candidates (unchanged, re-confirmed open)

From the dormant-ROM audit, still open, still correctly deferred:
- **D3** (~24B, SAFE pending one check): array/string-array operand-fetch
  prologue consolidation in `exrom_v2_vm_core.asm` — the "never
  simultaneous" assumption about `VM_ARR_INDEX_TMP`/`VM_STRARR_INDEX_TMP`
  was not independently re-verified in this pass either; still open.
- **D4/D5** (~60-95B, MEDIUM/MEDIUM-HIGH risk): `LEX_CLASSIFY_KEYWORD`/
  `BUILTIN_FN_FIND` table-walk consolidation, and `COMPILE_DIM`/
  `COMPILE_DIM_STR` skeleton consolidation — both correctly held for a
  dedicated design pass, not mechanical extraction, and D5 specifically
  touches code where two real correctness bugs were already found and fixed
  this cycle (§6.1). Answers the brief's **Q10** ("source/editor/compiler
  operations that duplicate essentially the same parsing/scanning logic"):
  yes, these two pairs, already identified, consolidation deliberately
  deferred pending design work, not newly found here.
- The ~300-byte "ROM driver, vectors and tables" block at the start of
  `rom/v2_home.asm` — flagged by the prior audit as unexamined; also not
  examined in depth in this pass (a quick read found nothing suspicious, but
  this is not the same as a full trace). Residual **G — uncertain**.

### 6.4 NEW FINDING — currently live build breakage in the legacy test harness

**Severity: should be fixed before any further dormant-ROM-style cleanup
touches `kernel/memory`/`kernel/io`, and ideally before R11.**

Reproduced live in this session:

```
$ tools/sjasmplus_strict.sh rom/test_editor_auto.asm
...
exrom_jumptable.inc(94): error: Label not found: MEM_LABEL_TABLE_CLEAR
exrom_jumptable.inc(94): error: Label not found: MEM_LABEL_ADD
exrom_jumptable.inc(94): error: Label not found: MEM_LABEL_LOOKUP
basic.asm(797/800/803): error: Label not found: IO_ANY_KEY_DOWN
basic.asm(1404/7675/7750): error: Label not found: MEM_LABEL_LOOKUP
basic.asm(3580): error: Label not found: STICK_READ
basic.asm(10895): error: Label not found: IO_CHECK_BREAK
Errors: 11, warnings: 0
```

**Mechanism**: the R10.7 dormant-ROM-consolidation pass removed
`MEM_LABEL_TABLE_CLEAR`/`MEM_LABEL_ADD`/`MEM_LABEL_LOOKUP`
(`kernel/memory/memory.asm`) and `IO_ANY_KEY_DOWN`/`STICK_READ`/
`IO_CHECK_BREAK` (`kernel/io/io.asm`) on the correct evidence that production
(`rom/v2_home.asm`/`rom/v2_exrom.asm`) never calls them. But `kernel/memory`
and `kernel/io` are **shared** files — also pulled in by the legacy build
(§3) via `basic/basic.asm`, which *does* still call all six removed routines
(confirmed above, by file:line). The removal was verified against the
production include set only; it was not verified against the legacy
build's own assembly, which this audit found genuinely still relies on
these exact symbols.

**Who already found this**: `docs/v2/R10_7_UX_PARITY_INVESTIGATION.md`
(2026-10-04, today) root-caused this exact failure mid-session while
validating unrelated work, explicitly noted it predates and is unrelated to
that session's own task, and left it unfixed per that task's own scope
boundary ("do not reopen... the dormant-architecture audit"). This audit is
that dormant-architecture audit, so it is now in scope to document (not fix,
per this task's own boundary) here, prominently, as the hand-off point.

**Practical impact**: `make test`'s `run_editor_auto_test.sh` (both
invocations) and `run_storage_named_load_test.sh` (all 11 cases, which also
assemble a `basic.asm`-based Home image per
`docs/v2/R9_CUTOVER_LEDGER.md:278`) are currently broken. The V2-only test
targets (`run_v2_standalone_tests.sh`, `run_smoke_rom_tests.sh`) are
unaffected — confirmed by this session's own `make budget` run completing
cleanly, and by the fact that `test_calc_smoke_*`/`test_memory`/`test_math`/
etc. (the smoke-ROM set) do not include `basic.asm` and have no dependency on
the removed symbols.

**Does this affect production correctness?** No — zero production bytes are
involved (§2.1, §3); this is purely a broken build for a non-shipping
component-test harness. It does not corrupt source, RAM, bytecode, or stack
state. Per this task's own boundary, not fixed here.

**Recommended fix** (not applied, for whoever picks this up): either (a)
restore trivial local stub copies of the six routines inside `basic/basic.asm`
itself (same pattern already used for the three other routines the same
dormant-ROM pass removed and stubbed locally —
`TEST_ANY_KEY_DOWN`/`TEST_BANK_CALL_EXROM`, per
`R10_7_CAPABILITY_RESTORATION.md` §14.1's own notes on `rom/test_io.asm`/
`rom/test_exrom_isolation.asm`), or (b) resolve the §3 disposition first and
let that decision determine whether this legacy build is worth repairing at
all versus retired outright.

---

## 7. Hardware capability (TS2068-specific)

No new findings; this audit re-confirmed `docs/v2/R10_25_CAPABILITY_EXPOSURE_AUDIT.md`
and `docs/v2/R10_STOCK_TS2068_CAPABILITY_MATRIX.md`'s own thorough treatment
against current source and found nothing to add or correct:

- **AY sound**: `SOUND` (`rom/exrom_sound.asm`) already drives the full raw
  AY register space (confirmed, unchanged) — richer than the deferred
  `AYREG` V1 extension it would have restored; AYREG is correctly classified
  F (redundant).
- **High-Res Graphics mode**: `GFX_SET_MODE`/`GFX_SET_ATTR_EXT`
  (`kernel/graphics/graphics.asm`) are resident and reachable (`MODE`
  package); GRAPHICS' own CPLOT/BLOCK/FRAME/INVERT pixel-level validation
  (§ R10.7 capacity audit §13) tested standard mode only — extended mode was
  not independently re-verified live, flagged (not newly) as a residual,
  low-likelihood gap since the underlying `GFX_WRITE_PIXEL` call path has no
  mode-dependent branch of its own.
  **Answers Q4** ("useful TS2068 hardware capabilities already implemented
  but not exposed through V2?"): resolved by R10.7's own work — CPLOT/BLOCK/
  FRAME/INVERT (GRAPHICS package) and CIRCLE (SHAPES package) closed this
  gap; nothing further surfaced.
- **Joystick** (`STICK_READ`): now removed from production-shared kernel
  code (§6.1/§6.4) as V1-only; no V2 `STICK` builtin or statement exists.
  This is a genuine stock-capability gap, already correctly listed as
  ABSENT-via-removal rather than newly discovered here — restoring it as a
  V2 builtin (`BUILTIN_FN_STICK`, same shape as `BUILTIN_FN_IN` would need)
  is cheap but was out of scope for every prior audit's "capability
  exposure" pass, which focused on stock-BASIC parity items the capability
  matrix already tracks; `STICK`/joystick never appeared on that matrix at
  all, worth adding as an explicit R11 line item rather than an audit
  finding here.
- **Printer**: covered by the PRINTER package, already production.
- **Sprites**: SPRITE package, already production; confirmed this session
  that the 3 `GFX_SPRITE_*` routines flagged dead by the prior audit are
  genuinely live internal callees (§6.1), not newly checked here.

---

## 8. Extension/package architecture

Confirmed unchanged and clean, matching `R10_AUDIT_AND_CLEANUP.md` §6 and
`R10_7_CAPABILITY_RESTORATION.md` §7/§3: **five** live production packages
now (MODE, SPRITE, PRINTER, SHAPES, GRAPHICS — GRAPHICS added since R10's
original four-package count), all through the identical
`EXT2_REGISTER`/`OP_CALL_EXT`/`EXT2_LOOKUP` mechanism, no one-off special
case (LPRINT reuses the same path). No obsolete V1 extension ABI consumes any
production resource — the six V1-era optional extensions
(CPLOT/AYREG/OUT/BLOCK/FRAME/INVERT) that use the *old* `EXT_SERVICE_*`
gateway remain exactly where `R10_25_CAPABILITY_EXPOSURE_AUDIT.md` found
them: fully implemented, tested, Makefile-wired, but on the superseded V1
ABI, zero production footprint, zero byte cost. Four of the six (CIRCLE via
SHAPES, CPLOT/BLOCK/FRAME/INVERT via the new GRAPHICS package) have since
been ported to V2's real ABI; AYREG stays excluded (redundant with SOUND);
OUT remains a pure product-policy question (§ brief's note on OUT/IN,
re-confirmed unchanged — cheap, not yet approved).

**Answers Q8** ("Does the current EXT2 architecture contain dormant or
unnecessary mechanisms?"): no — the registry, typed-argument dispatch, and
package-window lifecycle are uniformly used by all five live packages with no
unused branch or legacy fallback found in this pass.

---

## 9. Source/editor/compiler/decompiler findings

- **Keyword recognition**: single source of truth
  (`KEYWORD_TABLE`/`LEX_CLASSIFY_KEYWORD`, case-insensitive via
  `FOLD_UPPER`), reused by both the compiler and the editor's bolding
  (`V2_KW_DETECT_SPANS`, via `KTAB_GET_KEYWORD_TABLE` — zero duplicate
  table). Authoritative source is now canonicalized to uppercase keywords at
  commit time (`R10_7_KEYWORD_CANONICALIZATION_AUDIT.md`, applied, +199B
  EXROM, re-verified live in current source this session via the same
  `V2_KW_WORD_START`/`V2_TOKENIZE` call sequence the doc describes).
- **No duplicated source-processing machinery found** inside the production
  path itself — `V2_BUILD_SOURCE` (staging), the lexer, and the editor's
  render/bold pass are each a single, non-duplicated mechanism. The only
  duplication in this area is the D4 table-walk pair (§6.3), already
  tracked.
- **Decompiler**: confirmed, again, not production-resident (§2.1, §4) —
  `DECOMP_END_ADDR` RAM remains reserved but unoccupied in the shipping ROM;
  the decompiler module itself exists only in standalone test builds and
  retains its own tests (`rom/test_v2_decompiler*.asm`). **Known, carried-
  forward gap, re-confirmed not newly broken**: `OP_DIM`/`OP_DIM_STR`/
  `OP_STRARR_LOAD`/`STORE` have no decompiler support (`R10_7_
  CAPABILITY_RESTORATION.md` §10/§11, explicitly flagged there, unchanged).
  **Answers Q13** ("Is any decompiler-related RAM still unnecessarily
  reserved?"): the reservation is not *unnecessary* — it backs a real,
  tested, standalone capability (`rom/test_v2_decompiler*.asm`) — but it is
  genuinely idle in every production boot, which is a legitimate overlay
  candidate *if* the decompiler is ever confirmed permanently
  standalone-only; not recommended to touch without that explicit decision,
  consistent with `R10_AUDIT_AND_CLEANUP.md`'s own prior caution on this
  exact point.
- **V1 remnants in editor/source handling**: none found beyond the two
  legacy files already fully characterized in §3 — `rom/exrom_editor.asm`
  was specifically checked (again) for a duplicate keyword-highlighter and
  found clean, matching the dormant-ROM audit's own prior check.

---

## 10. V1-remnant inventory (systematic, final state)

| Category | Status |
|---|---|
| Services/dispatchers | `basic/basic.asm`'s command loop, `include/exrom_jumptable.inc`'s 45-entry KTAB — all zero-production-cost, test-only (§3). |
| Sysvars | `include/sysvars.inc`'s 94 V1-era symbols (347 bytes) — confirmed dead-to-production but alive-to-V1-test-scaffolding; deliberately not reclaimed (`R10_AUDIT_AND_CLEANUP.md` §3, re-confirmed unchanged this session — same file, same symbol count referenced by the same still-present legacy harness). |
| Tables | The legacy KTAB table itself (§5.2); `FOR_STACK`/`FOR_STACK_MAX=8` (V1, unused by V2 — V2's real limit is 4, `VM_FOR_NEST_MAX`, per `R10_7_CAPACITY_ARCHITECTURE_AUDIT.md` §6, correcting a stale cross-reference in an earlier doc). |
| Editor assumptions | None found migrated into V2's editor; `editor_integration.asm` confirmed unused by production (`R9_CUTOVER_LEDGER.md:33-35`). |
| Runtime label machinery | `MEM_LABEL_*` — removed from production-shared code already (§6.1); still called by the legacy build (§6.4, the live break). |
| Extension infrastructure | V1's `EXT_SERVICE_REGISTER`/`EXTENSION_MODULE_BASE` gateway — superseded, zero production cost, used only by the 6 deferred V1 extensions (§8). |
| BASIC runtime support | None found reachable from V2. |
| Test scaffolding | The entire §3 shadow build is test scaffolding by definition. |
| Memory reservations | Covered in §4; no V1-specific reservation found inside the *production* RAM map beyond the already-documented 94-symbol sysvars block (which is in `include/sysvars.inc`'s address space, not the production RAM map's live working set). |

**Answers Q1** ("Are there any remaining substantial blocks of V1
language/runtime code in the production ROM?"): **No.** Every substantial V1
block identified is confirmed outside the production INCLUDE chain (§2.1).
**Answers Q2** ("Are production ROM bytes being retained solely to support
obsolete component tests?"): **No** for ROM bytes specifically — the
dormant-ROM audit already established production contains zero dead bytes
for this reason; the cost this architecture actually imposes is *build/test
maintenance* (§6.4), not ROM bytes. **Answers Q3** ("Are any RAM regions
reserved for facilities that no longer exist in production?"): the decompiler
window (§9) is the one real example — reserved for a facility that exists
only in standalone builds, not "no longer exists" but "never resident."

---

## 11. Test/scaffolding findings

Summarized from §3/§6.4/§10: the project already has a mature, explicit
three-way test taxonomy (V1-derived component harnesses / V2 standalone
HOME+EXROM tests / genuine production-integration tests —
`R10_AUDIT_AND_CLEANUP.md` §8-9, re-confirmed unchanged and still the
governing convention). The one gap this audit found in that taxonomy's
actual upkeep is §6.4 — a cross-build dependency that broke silently because
a cleanup pass checked reachability against only one of the two builds that
share the kernel files it touched. This is a process finding as much as a
code finding: any future dead-code audit touching `kernel/*` must check
reachability against **both** `rom/v2_home.asm`+`rom/v2_exrom.asm` *and*
`basic/basic.asm`+`rom/exrom_build.asm` (or whichever disposition §3 reaches
removes that second check entirely).

---

## 12. Dormant/unconnected capability inventory (consolidated)

| Capability | Where it lives | Class | Status |
|---|---|---|---|
| CIRCLE | SHAPES package | A (now exposed) | Resolved in R10.7 |
| CPLOT/BLOCK/FRAME/INVERT | GRAPHICS package | A (now exposed) | Resolved in R10.7 |
| AYREG raw register poke | `rom/extensions/ayreg.asm` | F (redundant w/ SOUND) | Correctly excluded |
| OUT (port write) | `rom/extensions/out.asm` | C (cheap, policy question) | Unresolved product decision |
| IN (port read, expression position) | none exists | E (needs resident builtin or EXT2 expression-dispatch) | Unresolved, correctly scoped as harder than OUT |
| STICK/joystick | `STICK_READ` (now removed from shared kernel, §6.1/§6.4) | E (small, never scoped by any prior capability audit) | **New observation this audit** — worth an explicit R11 line item |
| ASN/ATN/EXP/LN | none | E | Unchanged, substantial |
| VAL$ | none (needs reentrant evaluator) | E | Unchanged, substantial |
| SCREEN$ | none | E | Unchanged, substantial |
| String slicing `a$(2 TO 5)` | none (grammar-only gap) | E | Unchanged |
| DATA/READ/RESTORE | none | E | Largest deferred item, unchanged |
| DRAW | none (LINE is deliberately absolute-only) | E | Unchanged |
| MERGE | none | E | Unchanged |
| Decompiler (standalone) | `rom/exrom_v2_decompiler.asm` | F/G (reserved RAM, no production occupant) | Intentional, re-confirmed |
| Legacy V1 interpreter | `basic/basic.asm` + friends | F | §3, needs explicit R11 disposition |

---

## 13. Potential ROM/RAM reclamation (summary table)

| Item | ROM/RAM | Risk | Before R11? | Evidence |
|---|---:|---|---|---|
| 4 dead legacy-KTAB entries (§5.2) | 12 B HOME (in unused table) | SAFE | Only if §3 path (a) is chosen | This audit |
| D3 operand-fetch prologue consolidation | ~24 B HOME | SAFE pending 1 check | Either | Dormant-ROM audit, unresolved |
| D4 table-walk consolidation | ~20-35 B HOME | MEDIUM | Either | Dormant-ROM audit, unresolved |
| D5 COMPILE_DIM/DIM_STR consolidation | ~40-60 B HOME | MEDIUM-HIGH | Either, hold for design pass | Dormant-ROM audit, unresolved |
| Decompiler RAM overlay (~880 B) | RAM | Needs explicit standalone-only decision first | Before, if ever pursued | §9, this audit |
| Retiring the legacy build entirely (§3 path b) | 0 ROM (already zero-cost); removes build-maintenance tax | Non-trivial migration effort | **Recommend deciding before R11** | §3/§6.4, this audit |

No new ROM reclamation beyond what is already tracked was found in this
audit. The one genuinely new, zero-risk, immediately actionable item is
fixing §6.4 (restoring local stub copies, matching the pattern already used
for the other three routines removed in the same pass) — not a byte-recovery
item, a correctness-of-tooling item.

---

## 14. Phase-overlay opportunities

Already covered in depth in §4/§4.1. The one validated-in-production example
(scalar/string overflow tiers sharing the staging buffer's idle window) is
real and shipping. The next two candidates identified but not pursued
(formalizing the idle-window invariant; extending the array arena into the
remaining 3,856 idle bytes) are both already correctly scoped as R10.7-or-R11
follow-ons in `R10_7_CAPACITY_ARCHITECTURE_AUDIT.md` §10 — not re-litigated
here.

---

## 15. Uncertainties requiring further proof

- **G**: the ~300-byte ROM driver/vectors block at the start of
  `rom/v2_home.asm` (unexamined in depth, both by the prior audit and this
  one).
- **G**: whether `rom/ext_sprite_module.asm` is reachable from the default
  production EXROM boot path versus only as a separately-loaded extension
  (doesn't change any dead-code finding either way; a pure architecture
  question for R11's own documentation).
- **G**: whether the High-Res Graphics mode path (`GFX_SET_ATTR_EXT`)
  behaves identically for GRAPHICS' four operations as standard mode does —
  theoretically yes (no mode branch in the GRAPHICS package itself), not
  independently verified live (§7).
- **UNVERIFIED** (carried from `R10_7_CAPACITY_ARCHITECTURE_AUDIT.md` §0): no
  explicit bounds check was found guarding `V2_BUILD_SOURCE`'s staging write
  against overrunning `$A455` at the absolute maximum-length, CR-dense
  program edge case — the safety margin is an invariant, not an enforced
  check. Worth a dedicated edge-case test before R11 if this path is touched
  again.

---

## 16. Items that should be resolved before R11 freezes architecture

1. **§6.4 — fix the legacy test-harness build breakage**, or decide to retire
   the legacy build (§3) and let that decision subsume the fix. Either way,
   leaving `make test` silently broken for two of its targets across an R11
   freeze is the wrong default.
2. **§3 — give the two-codebase coexistence an explicit, written
   disposition** (freeze as permanent component-test fixture with an
   explicit cross-build dependency-check rule, or migrate/retire). This is
   not urgent in the sense of blocking anything today, but it is exactly the
   kind of implicit, easy-to-forget contract that gets expensive to unwind
   once R11 adds more weight on top of the assumption that `kernel/*` dead
   code checks only need to look at one build.
3. **§5.1 — settle whether EXROM-resident code calling `GFX_WRITE_PIXEL`/
   `GFX_READ_PIXEL`/`GFX_LINE` directly (bypassing KTAB) is the intended,
   permanent service-boundary convention**, before R11 fixes what "public
   HOME/EXROM service" means.
4. **§4 — correct or annotate `R9_CUTOVER_LEDGER.md`'s RAM table** to point
   to the current figures (it is stale on array/scalar/recursion capacity,
   known and documented elsewhere, but not flagged in the ledger itself).
5. **OUT/IN** (unresolved product-policy question, re-confirmed unchanged) —
   decide before R11 if raw port I/O is in-scope for the managed BASIC
   surface at all; adding it after an ABI freeze is strictly harder than
   deciding now (per the brief's own Q16 framing).

---

## 17. Items safe to defer until after R11

- D3/D4/D5 ROM consolidation candidates (§6.3) — pure internal-structure
  changes, no ABI/API surface involved, can happen any time.
- FOR-nest depth, label/fixup capacity increases (§4.1) — additive,
  non-breaking.
- Decompiler RAM overlay (§9/§13) — depends on a standalone-only decision
  that itself can be made any time; not urgent.
- Extending the array arena into the staging buffer's idle remainder (§14) —
  additive capacity, no existing contract broken by doing it later.
- STICK/joystick exposure as a V2 builtin (§7) — new capability, not an ABI
  risk either way.

---

## 18. Recommended bounded R10.7 cleanup sequence

1. Fix §6.4 (restore 6 local stub routines in `basic/basic.asm`, matching the
   existing `TEST_ANY_KEY_DOWN`/`TEST_BANK_CALL_EXROM` precedent) — smallest,
   least risky, unblocks `make test` immediately. Does not require the §3
   decision to be made first.
2. Get an explicit decision on §3 (keep-as-fixture vs. migrate-and-retire).
3. If "keep": add the cross-build reachability check this audit's §6.4
   finding shows was missing, to whatever tooling/checklist governs future
   `kernel/*` dead-code passes.
   If "retire": plan the migration of the calc-smoke and storage-transport
   component tests onto the V2 standalone harness convention, then delete
   `basic/basic.asm`/`editor_integration.asm`/`exrom_checker.asm`/
   `exrom_build.asm`/the dozen `exrom_<name>.asm` files/`exrom_jumptable.inc`/
   `kernel_api.inc` and the 94 dead V1 sysvars in one pass.
4. Annotate `R9_CUTOVER_LEDGER.md`'s RAM table with a pointer to
   `R10_7_CAPACITY_ARCHITECTURE_AUDIT.md`/`R10_7_CAPABILITY_RESTORATION.md`
   §10-11 for the current figures (cheap, no code change).
5. Only then, pick up D3 (cheap, SAFE) if further HOME headroom is wanted;
   leave D4/D5 for a dedicated design pass regardless of timing.

---

## 19. Report back to the user

- **Highest-priority findings**: (1) `make test` is currently broken for two
  targets (§6.4), a direct side effect of R10.7's own dead-code removal not
  checking the legacy build; (2) the two-codebase coexistence (§3) needs an
  explicit R11-adjacent decision, not because it's unsafe today but because
  it's an implicit contract that just broke once already.
- **Estimated safely reclaimable HOME/EXROM/RAM**: no *new* bytes beyond
  what's already tracked (D3 ~24B SAFE, D4/D5 ~60-95B MEDIUM-risk, both
  pre-existing findings). The 4 dead legacy-KTAB entries (12B) are inside an
  already-zero-cost table.
- **Important dormant capabilities**: none newly found beyond what R10.25/
  R10.7 already catalogued; STICK/joystick exposure is a small, previously
  un-scoped gap worth a line item.
- **Architecture issues requiring resolution before R11**: §3 (two-codebase
  disposition), §6.4 (fix the break), §5.1 (KTAB-bypass convention), the
  stale RAM-ledger cross-reference.
- **What should intentionally remain unchanged**: the production KTAB/
  service surface (§5.1), the five-package EXT2 mechanism (§8), the
  fixed-slot/compile-time-indexed scalar and array addressing scheme (no
  runtime name search anywhere — re-confirmed, R10.7 capacity audit §8), the
  decompiler's standalone-only status pending an explicit decision to change
  it.
- **Recommended next R10.7 action**: fix §6.4 first (cheapest, unblocks
  tooling), then get the §3 decision, per §18's sequence.
- **Tree status**: this audit modified no files except creating this one
  document. One Bash command (`tools/sjasmplus_strict.sh rom/test_editor_auto.asm`)
  was run to reproduce §6.4 live — it only assembles to a disposable
  `rom0.bin`/`.lst`/`.sym` in the working directory (the project's own normal
  build-tool output location, not a new location this audit introduced) and
  made no source edits. `git status` was not re-captured at the end of this
  session, but no `Write`/`Edit` tool call touched any file other than this
  document.

---

## 20. Resolution — bounded post-audit cleanup (follow-up session, same day)

Scope of this follow-up: repair §6.4's build breakage without spending any
production ROM/RAM, formally document §3's two-codebase disposition in-tree,
determine (not implement) a joystick/STICK finding, and reconfirm production
accounting. No D3/D4/D5 optimization, no production service restoration, no
wholesale test migration, no joystick implementation, no KTAB/EXT2 change,
no R11 work, no commit — all per this follow-up's own explicit boundary.

### 20.1 §6.4 repair — legacy fixture owns its own obsolete dependencies

**Mechanism**: a new file, `basic/legacy_kernel_compat.asm`, holds verbatim
restorations of the six routines the R10.7 dormant-ROM pass correctly
removed from the shared, production-resident `kernel/memory/memory.asm` and
`kernel/io/io.asm` (`MEM_LABEL_TABLE_CLEAR`, the internal `MEM_LABEL_FIND`
helper `MEM_LABEL_LOOKUP` needs, `MEM_LABEL_ADD`, `IO_ANY_KEY_DOWN`,
`STICK_READ`, `IO_CHECK_BREAK`). Bodies are copied unchanged from the
pre-removal source (recovered via `git diff HEAD` against the uncommitted
removal), not reimplemented. This file is `INCLUDE`d exactly once, from
`basic/basic.asm` itself — the one file every affected legacy test harness
already includes — so no per-test-file plumbing was needed for the symbols
themselves.

**The deeper fix, not just an assembly error**: production's own `MEM_INIT`
used to tail-jump into `MEM_LABEL_TABLE_CLEAR` (clearing `LABEL_TABLE_TOP`/
`LABEL_TABLE_USED` at `$F100`, outside `MEM_COLD_INIT`'s `$8000..
PROG_AREA_MAX` zero-fill range) and no longer does, correctly, since V2 has
no use for it. But `basic/basic.asm`'s `BASIC_RUN` still does an
unconditional label pre-pass (`MEM_LABEL_ADD` for every label in the
program) on every run — if `LABEL_TABLE_USED` held stale/garbage RAM instead
of a clean `2`, that pre-pass could write past the table's real bounds. This
was a latent correctness risk, not just a missing symbol, so the fix adds an
explicit `call MEM_LABEL_TABLE_CLEAR` immediately after every `call
MEM_INIT` that used to rely on the old tail-jump — ten call sites total,
across `basic/basic.asm` (2, its own NEW handler and load-failed-dirty path)
and the eight legacy cold-start sequences that call `MEM_INIT` directly:
`rom/test_basic.asm`, `rom/test_editor_auto.asm`, `rom/test_storage_named_load.asm`,
`rom/test_storage_extension_roundtrip.asm`, `rom/test_storage_autorun_roundtrip.asm`,
`rom/demo_inject.asm`, and `rom/test_suite_inject.asm` (2 sites — cold boot,
and its own `TEST_RAM_EXTENSION_CLEAR` path that explicitly exercises
`MEM_INIT`'s reset behavior).

**`basic/basic.asm`'s own header was also corrected**: it previously
described itself as "Production BASIC implementation... covered by the
automated Fuse regression suite" — true before the R9 cutover, false today,
and exactly the kind of stale self-description this follow-up's §20.2 is
about. Rewritten to state plainly, at the top of the file, that it is a
non-production legacy/component-test fixture, cites this document, and
explains why it still exists and what it must not be used to justify.

**Lightweight guard added**: `make check` (run far more often than the
emulator-based `make test`, which is what actually caught this break)
now also assembles the legacy chain's two entry points
(`rom/exrom_build.asm` with `-DEDITOR_TEST_EXROM`, `rom/test_editor_auto.asm`
with `-DEDITOR_AUTO_OMIT_DEF_FN`) as a fast, assemble-only syntax/link check
— about 0.1-0.2s added to `make check`'s own runtime. This does not run the
emulator or verify behavior, only that the shared-kernel symbol surface this
fixture depends on still resolves; a future `kernel/*` dead-code pass that
breaks this contract again will now be caught at `make check` time instead
of silently, at the next full `make test` run (or never, if `make test`'s
two affected targets aren't run routinely).

### 20.2 §3 disposition — formally documented as a non-production fixture, not migrated

Per this follow-up's explicit instruction, the two-codebase coexistence is
**not** migrated or retired in this task. It is now explicitly, prominently
documented in the one place most likely to be read before anyone acts on
this code again — `basic/basic.asm`'s own file header (§20.1) — stating in
plain terms that it:
- contributes zero bytes to the shipping V2 ROM;
- is not the implementation of BASIC used by the production ROM;
- remains temporarily because legitimate component tests depend on it;
- must not drive production architecture decisions;
- must not cause obsolete services to be restored to production merely to
  satisfy its tests.

This document (§3, §18) already carries the two concrete eventual-disposition
paths (freeze-as-fixture-with-a-cross-build-check vs. migrate-and-retire);
nothing about that recommendation changes here. The §20.1 `make check`
guard is the "cross-build reachability check" §18 step 3 called for under
the freeze path — it is now in place regardless of which path is eventually
chosen, since both benefit from not finding out about a break only when
`make test` happens to be run.

### 20.3 Joystick/STICK — determination only, not implemented

**What currently exists**: `STICK_READ` (now in `basic/legacy_kernel_compat.asm`,
legacy-fixture-only) reads a joystick's direction bits through the AY-3-8912's
I/O port A — select register 14 (`$0E`) via `PORT_AY_REG` ($F5), read back via
`PORT_AY_DATA` ($F6). This is a real-hardware-confirmed mechanism (the real
ROM's own `READ-STICK`/M28F8 disassembly), not invented for this project.
Stick 1 reports a full 4-bit direction nibble; stick 2 reports a single bit —
a genuine hardware asymmetry, not a simplification.

**Does production V2 already have the underlying input service?** Partially.
`kernel/io/io.asm`'s `IO_KEY_SCAN_ALL`/keyboard-scan primitives are production
and unrelated (keyboard matrix, not the AY port). The actual AY port-A read
primitive production needs for STICK does **not** currently exist in any
production-resident file — `rom/exrom_sound.asm`'s `SOUND_EXROM` only ever
**writes** `PORT_AY_REG`/`PORT_AY_DATA` (registers 1-16, validated range), it
never reads them back. Restoring STICK would mean adding a small, new,
read-capable routine to the production side (the removed `STICK_READ` body is
~24 lines/~30 bytes per the original removal's own accounting) — not merely
re-exposing something already resident.

**One architectural note worth flagging, not resolved here**: `SOUND_EXROM`'s
accepted register range (1-16) already includes register 14 — the same AY
I/O-port-A register `STICK_READ` reads. A BASIC program issuing `SOUND 14,x`
today would write that port's data-direction/output state; if `STICK` is
ever added, its read-side behavior after such a `SOUND 14,...` call has not
been characterized here (register 14's real hardware semantics as an AY I/O
port, not a tone/noise channel, make this a genuinely different kind of
register than 0-13). Worth a dedicated real-hardware/accurate-emulator check
before shipping `STICK`, not a blocking concern for this follow-up.

**Approximate cost/architecture if pursued**: cheap and additive, same shape
as the existing single-argument integer builtins. `rom/exrom_v2_compiler.asm`'s
`BUILTIN_FN_TABLE` (currently 29 entries, `BUILTIN_FN_TABLE_COUNT`, confirmed
table-driven — "only the table grows... needs no \[grammar\] change per
function added") would take one new row (`db 5,"STICK",1,<next_index>,0`,
matching `ABS`/`SGN`/`RND`'s existing one-argument-integer shape) plus one new
`rom/exrom_v2_vm_core.asm` opcode handler wrapping a production-resident
AY-port-A read routine. No compiler grammar change, no new VM stack
discipline, no EXT2 involvement — this is resident-builtin-function shaped,
not package-shaped (unlike `OUT`, which the extensions lane already
identified as a natural EXT2 statement) and not expression-position-ABI-new
the way `IN` would be (STICK's "device 1 or 2" argument is a plain compile-
time-typed integer expression already handled by the existing builtin-
function calling convention, not a new ABI shape).

**Recommendation**: resident builtin function (`STICK(n)`), not a package —
cheap, additive, no ABI novelty — but **deferred past this follow-up**
per its explicit boundary. It belongs on the same pre-R11 decision list as
`OUT`/`IN` (§12, §16 item 5): a product-scope question (is raw joystick
input in-scope for the managed V2 BASIC surface at all), not an architecture
blocker — adding it after R11 freezes the builtin-function table is no
harder than adding it before, since the table is explicitly designed to
grow without a grammar change. Unlike `OUT`/`IN`, this one is *not* an ABI
question — it can safely move to the "defer past R11" list (§17) rather
than the "resolve before R11" list (§16), and this document's own §12/§16
are corrected accordingly below.

### 20.4 Production accounting — reconfirmed unchanged

Re-ran `make build` + `make budget` after every edit above. Every edit in
this follow-up touched only `basic/basic.asm`, the new `basic/
legacy_kernel_compat.asm` (not `INCLUDE`d by either production file), eight
non-production `rom/test_*.asm`/`rom/demo_inject.asm` fixture files, and
`Makefile`'s `check` target (an added build-verification step, not a change
to what ships). None of `rom/v2_home.asm`, `rom/v2_exrom.asm`, or any
`kernel/*.asm` file was touched.

| | Before this follow-up | After this follow-up |
|---|---:|---:|
| HOME free | 437 B | **437 B** (unchanged) |
| EXROM free | 1,321 B | **1,321 B** (unchanged) |

RAM layout: unchanged (no `include/v2_layout.inc`/`include/sysvars.inc`
production-side address changed; `include/sysvars.inc`'s existing legacy
label-table symbols, already counted in the prior audit's "94 dead V1-era
symbols" finding, §10, are reused as-is, not added to).

### 20.5 Validation results (this follow-up, live)

| Suite | Result |
|---|---|
| `make build` | 0 errors, HOME/EXROM unchanged (§20.4) |
| `make check` (incl. new legacy-fixture assemble-only guard) | clean, 0 errors |
| `tools/sjasmplus_strict.sh` on all 7 directly-edited legacy `.asm` files + `rom/exrom_build.asm` (4 flag combinations) | 0 errors each (previously 11 errors on `test_editor_auto.asm`) |
| `tools/run_editor_auto_test.sh` (default + `insert`) | **PASS**, **PASS** |
| `tools/run_storage_named_load_test.sh` — all 11 cases (`program`, `extension`, `extension_bad_length`, `extension_bad_version`, `extension_wildcard`, `extension_save_missing`, `extension_roundtrip`, `autorun_roundtrip`, `autorun_zero`, `autorun_trailing`, `autorun_out_of_range`) | **PASS** × 11 |
| `tools/run_v2_standalone_tests.sh` (V2 production-shaped regression suite) | **27/27 PASS**, unaffected (none of this follow-up's edits touch anything these tests include) |

All legacy-fixture tests now pass live in Fuse, not merely assemble —
confirming the `MEM_LABEL_TABLE_CLEAR` re-insertion (§20.1) didn't just fix
the build but restored correct runtime behavior for the paths these specific
tests exercise.

### 20.6 Corrections to this document's own earlier sections

- §12's dormant-capability table: STICK/joystick's "Class" is corrected from
  the unqualified "E" this audit's §7/§12 originally gave it, to **E, but
  explicitly a §17 defer-past-R11 item, not a §16 resolve-before-R11 item**
  (§20.3's reasoning: no ABI novelty, the builtin-function table is designed
  to grow without a grammar break).
- §16/§17: STICK/joystick was already listed under §17 ("safe to defer")
  in the original pass; §20.3 re-confirms that placement with concrete
  cost/mechanism evidence rather than the original's more general note.
- §6.4 and §3 are now RESOLVED/DOCUMENTED respectively, per §20.1/§20.2 — the
  original §16 items 1 and 2 are closed by this follow-up; §16 items 3-5
  (KTAB-bypass convention, stale `R9_CUTOVER_LEDGER.md` cross-reference,
  OUT/IN product decision) remain open, untouched by this follow-up's
  bounded scope.

### 20.7 Files changed in this follow-up

New:
- `basic/legacy_kernel_compat.asm` (legacy-fixture-only; zero production
  INCLUDE path)

Edited (non-production unless noted):
- `basic/basic.asm` — header rewritten (§20.1); `INCLUDE` of the new file;
  two internal `MEM_INIT` call sites get an explicit `MEM_LABEL_TABLE_CLEAR`
  follow-up call
- `rom/test_basic.asm`, `rom/test_editor_auto.asm`,
  `rom/test_storage_named_load.asm`, `rom/test_storage_extension_roundtrip.asm`,
  `rom/test_storage_autorun_roundtrip.asm`, `rom/demo_inject.asm`,
  `rom/test_suite_inject.asm` — same explicit `MEM_LABEL_TABLE_CLEAR`
  follow-up call added after each file's own cold-start `MEM_INIT`
- `Makefile` — `check:` target gained the two-line legacy-fixture
  assemble-only guard (§20.1)
- `docs/v2/R10_7_DORMANT_ARCHITECTURE_AUDIT.md` — this section

Not touched: every file under `kernel/`, `rom/v2_home.asm`, `rom/v2_exrom.asm`,
`include/v2_ktab.inc`, `include/v2_layout.inc`, and every other file this
audit found already modified/untracked before this follow-up began (the
pre-existing R10.7 work, unrelated to this task).

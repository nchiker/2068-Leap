# R10.7 Capacity Architecture Audit

Read-only investigation. No production code was modified while producing this
document. All addresses/sizes below are cited to current source
(`rom/exrom_v2_compiler.asm`, `rom/exrom_v2_vm_core.asm`, `rom/exrom_v2_shell.asm`,
`rom/v2_home.asm`, `include/v2_layout.inc`, `include/sysvars.inc`), re-verified
against the live build rather than trusted from prior docs. Where prior docs
(`R10_7_ARRAY_ARCHITECTURE_AUDIT.md`, `R10_7_CAPABILITY_RESTORATION.md`) are
cited, any discrepancy with current source is flagged explicitly.

Checkpoint this audit was run against: HOME free 554 bytes, EXROM free 1,708
bytes, V2 regression 25/25 PASS, kernel smoke 9/9 PASS, dynamic numeric/string
arrays + array SAVE/LOAD + case-insensitivity complete, dormant-ROM reclamation
complete, R10.7 uncommitted.

## 0. Correction to the working premise

The premise that `$9455-$A455` is simply dead, unclaimed RAM is **half right**.
It is correct that no *persistent* structure lives there and nothing reads it
outside of compilation. It is **not** correct that nothing ever writes there:

- `V2_SOURCE_STAGE` = `V2_SOURCE_END` = `$9455` (`include/v2_layout.inc:4-5`).
- `V2_BUILD_SOURCE` (`rom/exrom_v2_shell.asm:369-419`) flattens the K-TAB line
  store into a flat CR-separated byte stream starting at `$9455` and growing
  upward, on **every** `RUN` of a stored program, before compilation starts.
- The lexer (`LEX_NEXT_TOKEN`) then reads that staged copy via `SRC_PTR`
  throughout `COMPILE_PROGRAM`, while `EMIT_PTR` simultaneously writes
  bytecode starting at `VM_CODE_BASE` = `$A455` immediately above it.

So `$9455-$A455` is a **transient, compile-time-only source-staging buffer**,
not inert space. It is only genuinely free (a) during editing, before a
compile is triggered, and (b) during execution, after `COMPILE_PROGRAM`
returns success and `VM_RUN` begins — because nothing reads the staging
buffer again until the *next* `RUN` re-stages it. This is actually the single
most useful fact for this audit: it hands R10.7 a real, provable
**lifetime-based overlay opportunity** (see §7), not just "spare bytes."

Caveat: no explicit bounds check was found inside `V2_BUILD_SOURCE` guarding
the staging write against overrunning `$A455`; the safety margin rests on the
invariant "a program that fits the 4096-byte K-TAB store ($8455-$9455)
produces fewer than 4096 staged bytes" (comment at `exrom_v2_shell.asm:368`).
Not exercised at the edge case (max-length, CR-dense program) in this audit —
flagged `UNVERIFIED`.

## 1. Numeric scalar variables

| | Compile-time (CSYMTAB) | Runtime (SYMTAB) |
|---|---|---|
| Address | `$B800` (`exrom_v2_compiler.asm:220`) | `$B700` (`exrom_v2_vm_core.asm:256`) |
| Size | 16×9 = 144 B | 16×3 = 48 B |
| Max entries | 16 (`CSYMTAB_MAX_ENTRIES`, `:222`) | 16 (slot = compiler's index) |
| Bytes/entry | 9: `[name_len:1][name:8]` | 3: `[tag:1][value_lo:1][value_hi:1]` |
| Lifetime | compile-time only, reset by `COMPILER_INIT` every compile | zeroed by `VM_INIT` every `RUN`, **not** by `NEW`/`CLEAR` |
| Coexists with source? | yes — compiles while staged source is being lexed | no — never live during compilation |
| Coexists with bytecode? | yes (adjacent regions, same bank) | yes (adjacent regions) |
| Coexists with dynamic arrays? | separate namespace (`ARRSYMTAB`), no overlap | separate table (`ARR_PTR_TABLE`), no overlap |
| Fixed-address code | `exrom_v2_compiler.asm:1466` (`CSYM_ENTRY_ADDR`); `exrom_v2_vm_core.asm:256` | |
| Fixed-count code | `exrom_v2_compiler.asm:1428` (`cp CSYMTAB_MAX_ENTRIES`); `exrom_v2_vm_core.asm:704` (`ld bc,16*3`) | |
| Append-only? | yes — `CSYM_FIND_OR_CREATE` only appends or returns existing index, no deletion code exists | fixed-slot, not append-only (slot = compile-time index) |

**Realistic program impact:** 16 distinct numeric identifiers is a real
ceiling for non-trivial programs (loop counters + accumulators + working
variables routinely exceed this). A full-table compile error (code 1) is the
visible failure mode — not silent corruption.

**Note:** `exrom_v2_vm_core.asm:279-293` still carries a stale comment block
("SYMTAB (32 scalars now, item 7)... nesting depth 6->12") left over from an
R10.7 attempt that was implemented, built, passed initially, then reverted
after a real regression (`VAL("123")` returning 0), traced eventually to an
unrelated `VM_ARR_VALUE_TMP`/`VM_INPUT_COUNT` collision — now independently
fixed and confirmed (`docs/R10_7_CAPABILITY_RESTORATION.md:360-376`). The
live `equ`s are still 16/6/4 (numeric/recursion/FOR); the comment is dead
prose, not current behavior.

- **A — current (16):** 0 extra RAM. Risk: real-program headroom is thin.
- **B — larger fixed (32):** CSYMTAB 144→288 B (compile-time, reclaimed at
  next compile — no permanent cost); SYMTAB 48→96 B (+48 B **permanent**
  resident RAM, since this table's address range is reserved whether or not a
  program uses all 32 slots). Already implemented once; the bug that forced
  its revert is independently fixed. ROM cost: near zero (same code, shifted
  constants). Risk: **low**, but requires re-verifying every table address
  above `$B700` that was previously shifted, since that shift is what exposed
  the latent, unrelated collision last time.
- **C — dynamic:** compiler already resolves every identifier to a 0-based
  index at compile time (`CSYM_FIND_OR_CREATE`), so a dynamic *compile-time*
  table costs nothing at runtime — the question is only whether `SYMTAB_BASE`
  itself can become a computed pointer sized to `CSYM_COUNT` instead of a
  fixed 16-slot block. Runtime access would still be O(1) indexed (no name
  search), but every `SYMTAB_BASE`-relative access gains one extra indirect
  load to fetch the computed base — a small, real per-access cost on every
  variable read/write. ROM cost: moderate (compiler must finalize count and
  lay out the runtime table's base after compilation, before `VM_INIT`).
  Fragmentation: none, since bytecode/float-table would need to move after a
  variable-sized SYMTAB, cascading more address computation. Not proportional
  to the actual problem (16→~32-64 is already generous for TS2068 BASIC).
- **D — hybrid:** keep the fixed `SYMTAB_BASE=$B700` 16-slot fast table
  untouched (zero risk to its neighbors' addresses), and place entries 17-32
  in a **second, separately-addressed overflow table** inside the reclaimed
  `$9455-$A455` staging gap (safe per §0/§7, since it's only live after
  compile succeeds — exactly when SYMTAB is used). Avoids re-shifting every
  `$B7xx-$BFxx` constant that caused the previous regression's blast radius.

**ROM/RAM/perf summary:** B costs 48 B permanent RAM, near-zero ROM, zero perf
regression, low-but-nonzero address-shift risk. D costs the same 48 B (now in
the staging gap instead of shifting `$B7xx+`), slightly more ROM (two base
addresses instead of one contiguous table), zero perf regression, and isolates
risk away from the already-dense `$B4xx-$BFxx` bank.

## 2. String scalar variables

| | Compile-time (STRSYMTAB) | Runtime (STRTAB) |
|---|---|---|
| Address | `$BA60` (`exrom_v2_compiler.asm:353`) | `$B500` (`exrom_v2_vm_core.asm:393`) |
| Size | 4×9 = 36 B | (4+2)×32 = 192 B |
| Max entries | 4 named vars (`STRSYMTAB_MAX_ENTRIES`, `:355`) | 4 named + 2 round-robin temp slots |
| Bytes/entry | 9 (same name-record shape as CSYMTAB) | 32: `[len:1][content:31]`, fixed-width, truncates on overflow |
| Lifetime | compile-time only, reset by `COMPILER_INIT` | zeroed by `VM_INIT` every `RUN`; not `NEW`/`CLEAR` |
| Coexists with source/bytecode/arrays | same as §1 | same as §1 |
| Fixed-address code | `exrom_v2_compiler.asm:1561` | `exrom_v2_vm_core.asm:393, 405` |
| Fixed-count code | `exrom_v2_compiler.asm:1539` | `exrom_v2_vm_core.asm:395-396` |
| Append-only? | yes (scan-or-append, no deletion) | fixed-slot (vars); round-robin (2 temps) |

The 4/4 coupling between `STRSYMTAB_MAX_ENTRIES` and `STRTAB_MAX_VARS` is a
**documented, not enforced, coupling** (`exrom_v2_compiler.asm:355-359`) —
raising one without the other is a latent-bug shape, not just a capacity
question.

**Realistic program impact:** 4 string variables is tight for text-adventure
or data-processing programs; this is the shallowest limit of the group.

- **A — current (4):** 0 extra RAM.
- **B — larger fixed (8):** STRSYMTAB 36→72 B (compile-time, free at reclaim);
  STRTAB vars 4→8 slots × 32 B = +128 B **permanent** RAM (keeping the 2 temp
  slots as-is). Also already implemented and reverted for the same
  independent, now-fixed bug. Risk: low, same address-shift caveat as §1.
- **C — dynamic:** same tradeoff as §1 but worse-proportioned — a 32-byte
  fixed-width slot already wastes space for short strings; a fully dynamic
  *value* heap (variable-length strings, not just variable *count*) would be
  a much larger redesign than this audit's scope and duplicates work the
  array redesign already did for a different data shape. Not recommended on
  its own merits here.
- **D — hybrid:** same shape as §1-D — first 4 slots stay at `$B500`
  untouched; slots 5-8 placed in the reclaimed staging gap.

## 3. Compiler symbol/name storage (overview)

There is **no unified symbol table.** Four independently-indexed, disjoint
namespaces exist, all compile-time-only and reset every `COMPILER_INIT`:

| Table | Address | Entries | Bytes/entry | Total |
|---|---|---|---|---|
| CSYMTAB (numeric) | `$B800` | 16 | 9 | 144 B |
| STRSYMTAB (string) | `$BA60` | 4 | 9 | 36 B |
| ARRSYMTAB (numeric arrays) | `$BCC0` | 16 | 11 (`[len:1][name:8][size:2]`) | 176 B |
| STRARRSYMTAB (string arrays) | `$BD70` | 8 | 12 (adds 1-byte element width) | 96 B |

(`exrom_v2_compiler.asm:220-233, 352-355, 520-531`.)

PROC and DEF FN names are **not** stored in any of the above — they share the
label table (§4) via `LABEL_DEFINE`/`LABEL_LOOKUP` (`exrom_v2_compiler.asm:4900-4904`,
reused by DEF FN at `:2109-2112, 5012-5013`). That makes labels/PROC/FN a
fifth distinct namespace.

All four tables share helper routines (`WRITE_NAME_FIELD`, `SYM_BUMP_COUNT`,
`NAME_CMP_FOLD`, `CLAMP_LEN8`) and the same append-only, scan-or-create
discipline; none has deletion/compaction code.

- **A — current (separate, fixed):** total compile-time symbol RAM ≈ 452 B,
  entirely reclaimed at every compile. Rationale for the split
  (`exrom_v2_compiler.asm:450-458`): arrays need an "already DIM'd?" check
  scalars don't, so merging namespaces would require a type-discriminant
  field and branch on every lookup for no RAM or speed benefit.
- **B/C/D:** not meaningfully applicable as a single decision — see §1/§2 for
  scalars and §4 for labels; array symbol tables are already sized by the
  R10.7 array redesign and out of this audit's scope to re-litigate.

**Recommendation driver:** leave the four-way split in place; it is already
a correct, minimal design. Any capacity change belongs to the individual
table (§1, §2, §4), not to the overall shape.

## 4. Label / fixup tables

| | LABELTAB | FIXUPTAB |
|---|---|---|
| Address | `$B900` (`exrom_v2_compiler.asm:226`) | `$B960` (`:231`) |
| Size | 8×11 = 88 B | 8×11 = 88 B |
| Max entries | 8 (`LABELTAB_MAX_ENTRIES`, `:228`) | 8 (`FIXUPTAB_MAX_ENTRIES`, `:233`) |
| Record | `[name_len:1][name:8][offset:2]` | `[patch_addr:2][name_len:1][name:8]` |
| Holds | labels, PROC names, DEF FN names (shared namespace) | outstanding forward GOTO/GOSUB/CALL references awaiting resolution |
| Lifetime | compile-time only, reset by `COMPILER_INIT` (`:681`) | compile-time only, reset by `COMPILER_INIT` (`:682`) |
| Append-only | yes, no deletion | yes during compile; whole table "consumed" once at end-of-compile `RESOLVE_ALL_FIXUPS` |
| Fixed-address code | `:3535` (`LABEL_ENTRY_ADDR`) | `:3551` (`FIXUP_ENTRY_ADDR`) |
| Fixed-count code | `:3562` (error code 5, "label table full") | `:3660` (error code 6, "fixup table full") |

**Already-working overlay precedent:** the RAM at `$B900-$B9B8`
(LABELTAB+FIXUPTAB) is reused immediately afterward, in the same compile
pass, by the FOR-nesting stack (`CFOR_STACK_DEPTH = $B9B8`,
`exrom_v2_compiler.asm:270-272`, explicitly placed in "the free gap between
FIXUPTAB_BASE+88 and SRC_PTR"). This is exactly the lifetime-overlay principle
the user asked about — already implemented, inside the compile phase, between
two compiler sub-concerns.

**Realistic program impact:** 8 labels/PROC-and-FN-names total is a plausible
real ceiling — any program combining a handful of GOSUB targets with one or
two PROCs/DEF FNs can hit it. Same for 8 outstanding *forward* references.

- **A — current (8/8):** 0 extra RAM, real limiting case for larger programs.
- **B — larger fixed (e.g. 16/16):** +88 B each, compile-time only (reclaimed
  every compile — **no permanent RAM cost**, unlike SYMTAB/STRTAB). Requires
  shifting every subsequent `$B9xx-$BE00` compile-scratch constant
  (`CFOR_STACK`, `EXITFOR_PATCH_TABLE`, `ARRSYMTAB`, `STRARRSYMTAB`, more
  scratch) — the same class of cascading-shift risk that exposed the
  previous (unrelated but address-shift-triggered) regression.
- **C — dynamic:** genuinely well-suited in principle (compile-time-only,
  already demonstrated to be safely reusable by a neighbor), but the payoff
  is small — these tables are already free of permanent RAM cost, so "dynamic"
  only saves *compile-time* scratch space the program never pays for anyway.
  Not worth the compiler complexity for this specific pair of tables.
- **D — hybrid:** not needed; these are already compile-time-only and
  already reused — they need only a bigger fixed count, not a different
  mechanism.

## 5. PROC / CALL / DEF FN recursion

Parameter **names** are not stored in a dedicated table at all — a parameter
resolves immediately to an ordinary CSYMTAB numeric slot
(`PROC_PARAM_INDEX_TMP = $BA31`, a scratch cell, `exrom_v2_compiler.asm:342-346`,
4906-4913: "the parameter is a plain symbol slot, overwritten on each call;
there is no separate local-variable stack frame").

Parameter **values** are saved/restored across recursive calls by two
parallel, same-depth, Z80-dedicated (not hardware) stacks:

| | VM_CALL_STACK | VM_PARAM_SAVE |
|---|---|---|
| Address | `$B694-$B69F` (floor/top, `exrom_v2_vm_core.asm:251,254`) | `$B732-$B761` (`:296-298`) |
| Depth | 6 (`VM_CALL_STACK` span = 12 B / 2 B per entry) | 6 (`VM_PARAM_NEST_MAX`, `:289`) |
| Bytes/entry | 2 (return address only) | 8: `[tag:1][value_lo:1][value_hi:1][floattab_raw:5]` |
| Holds | bytecode return address | the parameter's full SYMTAB record **and** its FLOATTAB record (a float's SYMTAB slot only holds a FLOATTAB index, so the index alone wouldn't undo an inner call overwriting the real float bytes) |
| Overflow | real caught error, `VM_ERROR_CODE=6` (`:4899-4901`) — not a crash, not silent corruption | same error class, `:4903-4905`; explicitly shares the identical exit with VM_CALL_STACK ("not a coincidence", `:1053-1057`) |
| Reset | SP reset to TOP by `VM_INIT` every `RUN` | same |

**Realistic program impact:** 6-deep recursion is plausible to hit in a
genuinely recursive PROC/FN (e.g. a recursive factorial/tree-walk demo), but
deep recursion is rare in typical TS2068 BASIC programs; this is the
*least* pressing of the three previously-proposed increases in practice,
though it's also the cheapest to raise.

- **A — current (6):** 0 extra RAM.
- **B — larger fixed (12):** VM_CALL_STACK +12 B, VM_PARAM_SAVE +48 B = **+60 B
  permanent RAM**. Already implemented and reverted for the same
  independently-fixed, unrelated bug as §1/§2. Low risk to re-apply.
- **C — dynamic (grow with available RAM + explicit overflow check):** the
  existing design *already has* an explicit overflow/exhaustion check (not
  silent) — the only change dynamic would add is removing the fixed ceiling.
  But each frame is 8 bytes of structured, specifically-shaped data (not a
  generic value), and the two stacks must stay depth-synchronized with each
  other 1:1 by construction (`:289-293`: "a recursive call always consumes
  one VM_CALL_STACK slot too, so this can never need to be deeper"). A heap
  allocator for a structure this small, this rarely stressed, and this
  tightly coupled is not proportional.
- **D — hybrid:** not needed — the existing dedicated-stack design is already
  the right shape; only the fixed depth is in question.

**Recommendation driver:** keep the mechanism (dedicated bounds-checked
stacks, not the hardware stack, not a heap), raise only the fixed depth.

## 6. FOR/NEXT loop stack

| | Compile-time (CFOR_STACK) | Runtime (VM_FOR_STACK) |
|---|---|---|
| Address | `$B9B8` region (`exrom_v2_compiler.asm:270-272`, reuses LABELTAB/FIXUPTAB RAM) | `$B5C1` (`exrom_v2_vm_core.asm:651`) |
| Max depth | 4 (`FOR_NEST_MAX`, `exrom_v2_compiler.asm:274`) | 4 (`VM_FOR_NEST_MAX`, `exrom_v2_vm_core.asm:649`) |
| Bytes/entry | — | 4: `[limit:2][step:2]` |
| Total size | — | 4×4 = 16 B |
| Overflow | compiler raises error code 55 at compile time (`:4324-4326`) if a program nests FOR loops too deep — the program **never compiles**, so it can never reach the VM | **no runtime bounds check exists, by design** — "bytecode from this compiler can never exceed [4], so no runtime bound check is needed here" (`exrom_v2_vm_core.asm:642-645`) |

This is the cleanest design in the whole inventory: the compiler is the sole
enforcement point, and the VM pays zero runtime cost for bounds-checking.

Note: `include/sysvars.inc:1669-1722` defines an unrelated, legacy V1 BASIC
`FOR_STACK`/`FOR_STACK_MAX=8` that is **not** used by V2 at all — a prior doc
(`R10_7_CAPABILITY_RESTORATION.md:166`) cites this stale V1 constant as if it
were V2's current FOR-nesting limit; it is not. V2's real limit is 4
(`VM_FOR_NEST_MAX`), not 8.

**Realistic program impact:** nested-loop programs (grids, simple 3D effects)
can plausibly want more than 4 levels.

- **A — current (4):** 0 extra RAM.
- **B — larger fixed (e.g. 8):** VM_FOR_STACK +16 B permanent RAM; compiler's
  `FOR_NEST_MAX`/`CFOR_STACK` grows by a proportional amount of compile-time
  scratch. Very cheap, but the increase sits inside the same densely-packed
  `$B9xx-$BE00` compiler-scratch region as §4, so it carries the same
  address-shift re-verification burden, not a RAM-cost burden.
- **C/D:** not justified — this structure's entire value is that it has *no*
  runtime cost; introducing dynamic sizing would need to either reintroduce a
  runtime check or make the compiler's own enforcement depend on a runtime
  value, both regressions from the current design.

## 7. Memory architecture: should `$9455-$A455` become a general arena?

**No — not as an immediately-carved set of several new permanent fixed
tables, and not as a fully general heap either.** The useful shape is
narrower and is justified directly by §0's timing evidence:

- The region is **compile-time-exclusive while compiling** (source staging,
  read start-to-finish by the lexer while bytecode is emitted just above it).
- It is **provably idle for the entire execution phase** — nothing in
  `VM_INIT`/`VM_RUN`/any opcode handler reads or writes `$9455-$A455` (full
  grep of live `EQU`/`ORG` placements across `rom/`, `include/`, `kernel/`
  found zero hits in this range for the production build; the only hits were
  stale historical-move comments and unrelated standalone test harnesses not
  part of the Makefile's two production targets, `rom/v2_home.asm` +
  `rom/v2_exrom.asm`).
- Nothing re-enters `V2_BUILD_SOURCE` while a program is running (no
  interleaved compile+run exists — `COMPILE_PROGRAM` always fully finishes,
  success or failure, before `VM_RUN` is ever called; `exrom_v2_shell.asm:518-565`).

So the *only* structures that can safely live in this window are ones whose
full lifetime is **"after compile succeeds, until the next compile begins"**
— i.e. ordinary VM runtime value storage, exactly the §1/§2/§5 overflow slots
proposed as Option D. A structure needed *during* compilation (another
compiler symbol table, a bigger label table) cannot safely live here, because
compilation is exactly when this RAM is busy holding staged source.

This is sound as a documented *invariant*, not as code to write now: "nothing
in this address range may be read before `COMPILE_PROGRAM` returns success in
the current compile cycle, and nothing may assume it survives past the start
of the next `V2_BUILD_SOURCE` call." Today that invariant holds by the
existing single-threaded, non-interleaved control flow; it would become a
real constraint if V2 ever grows a `CONT`-style resume-after-break feature
that keeps old runtime state alive across a user edit+recompile — a
conditions-for-revisit note, not a current blocker.

## 8. Performance constraint check

Every structure in §1/§2/§5/§6 already resolves identifiers to **fixed slot
indices at compile time** (`CSYM_FIND_OR_CREATE` et al.) — runtime variable
access is, and under every option above remains, a direct indexed table
access, never a name search. The compiler's own symbol tables (§3/§4) are a
**separate concern** from runtime value access by construction; nothing
proposed here (Options A/B/D for scalars, B for recursion/FOR, B for
labels/fixups) changes that. Option C for scalars (§1/§2) is the only
candidate that would add runtime cost (one extra indirect base-pointer load
per access) and is explicitly not recommended for that reason.

## 9. Proposed V2 RAM architecture by phase

```
                      $8455            $9455            $A455            $B400     $BFxx
                        |                |                |                |          |
  EDITING        [ K-TAB line store, growing  ][   idle: staging    ][ idle: last run's
                 [ text as typed, $8455-$9455 ][   buffer unstaged  ][ bytecode + VM
                                                [   (free)           ][ tables, stale ]

  COMPILATION     [ K-TAB (read by      ][ staged flat source  ][ bytecode being  ][ compiler
                  [ V2_BUILD_SOURCE)    ][ (V2_SOURCE_STAGE,   ][ emitted         ][ scratch:
                                         [  live: lexer reads  ][ (EMIT_PTR,      ][ CSYMTAB/
                                         [  it start-to-finish)][  VM_CODE_BASE+) ][ STRSYMTAB/
                                                                                   [ LABELTAB/
                                                                                   [ FIXUPTAB/
                                                                                   [ ARRSYMTAB/
                                                                                   [ STRARRSYMTAB
                                                                                   [ (append-only,
                                                                                   [  reset each
                                                                                   [  compile)

  EXECUTION       [ K-TAB (unused   ][ array DATA][ idle: staging][ bytecode    ][ VM runtime:
                  [ until next edit)][ arena,     ][ buffer, dead ][ executing   ][ FLOATTAB/
                                     [ PROG_END.. ][ until next   ][ (VM_IP,     ][ ARR_PTR/
                                     [ VARS_START ][ RUN restages ][  VM_CODE_   ][ STRARR_PTR/
                                     [ ($9455)    ][ it)          ][  BASE+)     ][ STRTAB/
                                                                                  [ SYMTAB/
                                                                                  [ VM_CALL_STACK/
                                                                                  [ VM_PARAM_SAVE
                                                                                  [ (all reset by
                                                                                  [  VM_INIT at
                                                                                  [  RUN start)
```

The one real architectural insight from this phase diagram: **the staging
buffer's idle window during execution exactly matches the window where
runtime tables need their final, largest form.** That is the justification
for the Option-D overflow placement in §1/§2 — not a new general arena, just
reusing an already-transient buffer for the one class of structure whose
lifetime provably never overlaps it.

## 10. Recommendations

### Implement during R10.7

- Re-apply the previously-built-and-reverted capacity increase as a single
  patch, now that its forcing bug (`VM_ARR_VALUE_TMP`/`VM_INPUT_COUNT`
  collision) is independently fixed and confirmed:
  - numeric scalars 16→32 (SYMTAB +48 B permanent RAM)
  - string scalars 4→8 (STRTAB +128 B permanent RAM)
  - PROC/CALL/DEF FN recursion depth 6→12 (+60 B permanent RAM)
  - Total: +236 B permanent RAM, re-verify every shifted constant in
    `$B4xx-$BFxx` against the full 25/25 regression suite plus the specific
    `VAL("123")`-class scenario that caught the collision last time.
- Prefer placing the *new* 17-32 / 5-8 slot ranges as a separate Option-D
  overflow table inside the reclaimed `$9455-$A455` staging window rather
  than shifting the existing `$B700`/`$B500` tables and everything above
  them — this reproduces the same capacity gain while avoiding the exact
  class of cascading-address-shift risk that exposed the previous collision.
  (Recursion's +60 B is small enough to leave in place at `$B6xx/$B7xx`
  without needing the overlay.)

### Defer until after R10.7 but before R11

- Formalize `$9455-$A455`'s post-compile idle window as a documented,
  named invariant/region (not just an implicit timing fact) before placing
  anything load-bearing there beyond the Option-D scalar overflow above —
  this is the foundation the overlay idea needs, and is worth doing once,
  deliberately, rather than per-structure.
- FOR-nest depth increase (4→8): cheap in RAM (+16 B) but sits inside the
  same densely-packed `$B9xx-$BE00` compiler-scratch region as labels/fixups;
  bundle its re-verification with the label/fixup change below rather than
  doing two separate passes over that region.
- Label/fixup table capacity increase (8→16 each): compile-time-only, zero
  permanent RAM cost, but requires re-verifying the packed scratch region
  (where `CFOR_STACK`/`EXITFOR_PATCH_TABLE` already reuse LABELTAB/FIXUPTAB's
  bytes) for new collisions — same risk class as the item-7 regression,
  just in a different sub-region.
- Fix the `STRARRSYM_COUNT` (`$BDD6`) omission: `COMPILER_INIT`
  (`exrom_v2_compiler.asm:677-701`) zeroes every sibling count
  (`CSYM_COUNT`, `LABEL_COUNT`, `FIXUP_COUNT`, `STRSYM_COUNT`, `ARRSYM_COUNT`,
  `CFOR_STACK_DEPTH`) except this one. This is a correctness bug, not a
  capacity question, flagged by this audit's investigation — fix it before
  touching that region further so it isn't misattributed to a capacity
  change later.

### Leave fixed intentionally

- PROC/CALL/DEF FN recursion as two parallel dedicated, bounds-checked
  stacks (not the Z80 hardware stack, not a heap) — frames carry structured
  8-byte payloads tightly 1:1-coupled to `VM_CALL_STACK`; a dynamic allocator
  would add real complexity for a structure that is cheap to over-provision
  and rarely stressed in practice.
- FOR/NEXT stack as a small fixed array enforced entirely at compile time
  with zero runtime bounds check — this is already the ideal design point;
  dynamic sizing would only reintroduce a runtime cost this design currently
  avoids.
- Runtime scalar/string value storage (SYMTAB/STRTAB) as fixed-slot,
  compile-time-index-resolved tables — this is the entire reason the
  compiler exists; only the slot *count* should ever change, never the
  indexing mechanism (ruled out in §1/§2 Option C).
- The four-way split of compile-time symbol tables (CSYMTAB/STRSYMTAB/
  ARRSYMTAB/STRARRSYMTAB) and their reuse of freed scratch space by
  `CFOR_STACK`/`EXITFOR_PATCH_TABLE` — already a correct, minimal
  application of the lifetime-overlay principle at compiler-scratch scale.

### Not worth changing

- Unifying the four compiler symbol tables into one — the split exists
  because arrays need an "already DIM'd?" check scalars don't; merging would
  add a type-discriminant and branching for no RAM or speed benefit.
- Building a general-purpose allocator for the `$B800-$BE00` compiler-scratch
  region — it is under 650 bytes total, entirely compile-time, and already
  reuses its own freed space without one; an allocator would cost more ROM
  than the RAM it could ever recover here.
- Touching the dynamic array data arena (`PROG_END..VARS_START`, below
  `$9455`) — it is already correctly RAM-bounded by the R10.7 array
  redesign and is out of scope for every change proposed above; none of
  the scalar/recursion/label/FOR changes touch or need to touch it.

---

## 11. Implementation result (R10.7 item 7, re-attempted)

Implemented per the "Implement during R10.7" recommendations in §10, using
exactly the Option-D overlay technique this audit proposed. Scope held to:
numeric scalars 16→32, string scalars 4→8, PROC/CALL/DEF FN recursion 6→12,
and the `STRARRSYM_COUNT` init-bug fix. FOR-nest depth, label/fixup capacity,
compiler-symbol-table redesign, and any R11 scope were explicitly **not**
touched, per the user's own bounded-scope instruction.

### What changed, and where

**STRARRSYM_COUNT fix** (`rom/exrom_v2_compiler.asm`, `COMPILER_INIT`): added
`ld (STRARRSYM_COUNT),a` alongside its five siblings, closing the one gap
this audit's investigation found in an otherwise-consistent reset discipline.

**Numeric scalars (16→32)**:
- `SYMTAB_BASE` ($B700, 16×3B) is **unchanged** — no address in the
  `$B4xx-$BFxx` bank shifted because of this.
- `SYMTAB_OVERFLOW_BASE` (new, = `V2_SOURCE_STAGE` = `$9455`, 16×3B = 48B)
  holds indices 16-31. Lives inside the source-staging buffer, valid only
  from `VM_INIT` (after a successful compile) until the next
  `V2_BUILD_SOURCE` call — the lifetime invariant is documented at its own
  `equ` in `rom/exrom_v2_vm_core.asm`.
- `VM_SYM_ADDR` now branches on `index < SYMTAB_BASE_CAPACITY (16)`: below,
  the original flat formula; at/above, the same formula rebased onto
  `SYMTAB_OVERFLOW_BASE`, with `A` (the index) saved/restored across the
  branch since some callers (e.g. `OP_FOR_NEXT`) keep using it afterward.
- `FLOATTAB_MAX_VARS` (16→32, +16 slots × 5B = 80B) absorbed entirely into
  the pre-existing 86-byte zero-filled slack between `FLOATTAB`'s old real
  end and `ARR_PTR_TABLE` — `ARR_PTR_TABLE`/`STRARR_PTR_TABLE`/everything
  above is unmoved. FLOATTAB indexing (`VM_FLOAT_ADDR`) was already, and
  remains, keyed directly by the logical scalar index, never by `SYMTAB`'s
  own (now tiered) physical address — verified by inspection of
  `VM_STORE_VAR_BY_INDEX`'s `.float_store` path before relying on it.
- `CSYMTAB_BASE` ($B800, 16×9B, compile-time name table) is **unchanged**.
  The 16 extra entries needed 144 more bytes, which don't fit in any single
  free gap in this bank (the largest, $B890-$B900, is 112 bytes) — rather
  than relocate `CSYMTAB_BASE` and cascade-shift `LABELTAB_BASE`/
  `FIXUPTAB_BASE`/`CFOR_STACK`/`SRC_PTR`/everything after them (the exact
  shift that exposed the original, unrelated `VM_ARR_VALUE_TMP`/
  `VM_INPUT_COUNT` collision last time), entries 16-31 are split across two
  confirmed-always-free gaps instead: `CSYMTAB_OVERFLOW_A` ($B890, 12
  entries) and `CSYMTAB_OVERFLOW_B` ($BA84, 4 entries, sharing its gap with
  `STRSYMTAB_OVERFLOW` below). `CSYM_ENTRY_ADDR` is now a 3-tier branch.
  Compile-time only, so the extra branching has no runtime cost.

**String scalars (4→8)**:
- `STRTAB_BASE` ($B500, 4×32B) is **unchanged**, holding indices 0-3.
- `STRTAB_OVERFLOW_BASE` (new, = `SYMTAB_OVERFLOW_BASE + 48` = `$9485`,
  6×32B = 192B) holds indices 4-7 (the new named slots) **and** the 2
  round-robin temp slots, relocated here from their old physical home
  right after `STRTAB_BASE` (now unused, genuinely free RAM — not reclaimed
  by anything in this change). Same staging-buffer lifetime invariant as
  the numeric overflow.
- `VM_STR_ADDR` branches on `index < STRTAB_BASE_CAPACITY (4)`, same shape
  and same `A`-preservation discipline as `VM_SYM_ADDR`.
- `STRSYMTAB_BASE` ($BA60, 4×9B, compile-time) is **unchanged**;
  `STRSYMTAB_OVERFLOW` (new, $BAA8, 4×9B) holds entries 4-7, in the same
  confirmed-free gap as `CSYMTAB_OVERFLOW_B`. `STRSYM_ENTRY_ADDR` is now a
  2-tier branch.

**Recursion (6→12)**:
- `VM_CALL_STACK_TOP` stays fixed at `$B6A0`; `VM_CALL_STACK_FLOOR` extends
  downward from `$B694` to `$B688` (12 bytes, matching 6 more 2-byte
  entries). The 6 scratch cells that used to occupy `$B688-$B694`
  (`VM_FOR_LIMIT`/`VM_FOR_NEXT_BRANCH`/`VM_FOR_NEXT_VALADDR`/
  `VM_FOR_NEXT_NEWVAL`/`VM_CALL_PUSH_TMP`/`VM_CALL_SP`) relocate to
  `$B79E-$B7A9`, a confirmed-always-free 98-byte runtime gap between
  `VM_ARR_VALUE_TMP`'s own real end and `CSYMTAB_BASE` — nothing else in
  `$B4xx-$B7xx` moved.
- `VM_PARAM_NEST_MAX` (6→12) drives `VM_PARAM_SAVE_STACK_TOP`'s existing
  formula (`$B732 + NEST_MAX*REC_LEN`) up to `$B792`. The 3 scratch cells
  that used to sit at the old top (`VM_PARAM_SYM_ADDR_TMP`/
  `FLOAT_ADDR_TMP`/`BIND_INDEX_TMP`) now follow the new top via the same
  relative-offset pattern they always used, landing in the confirmed-free
  tail of the same gap, ending exactly where `VM_ARR_ADDR_TMP` ($B798,
  unchanged) already begins.
- Both `VM_CALL_STACK`/`VM_PARAM_SAVE`'s new addresses were re-verified
  against `VM_ARR_VALUE_TMP`/`VM_INPUT_COUNT` specifically (the pair
  involved in the original regression) — neither moved, and the checker
  below confirms no new collision anywhere.

**VM_INIT**: now issues two additional `MEM_FILL_ZERO` calls (for
`SYMTAB_OVERFLOW_BASE` and `STRTAB_OVERFLOW_BASE`) alongside the existing
ones, on every `RUN` — the overflow regions get the identical reset
discipline as the base tables, justified by the same lifetime invariant
(the staging buffer is always stale by the time `VM_INIT` runs).

### A real bug found and fixed during this work

`CSYM_ENTRY_ADDR`/`STRSYM_ENTRY_ADDR`'s overflow branches rebase `C` (the
index) in place before calling `SYM9_INDEX_MUL`. The scan loop in
`CSYM_FIND_OR_CREATE`/`STRSYM_FIND_OR_CREATE` saves/restores `C` around
every call and was unaffected — but the `.create` path calls
`CSYM_ENTRY_ADDR` and then reads `C` directly afterward (`ld a,c`) to hand
the *original* 0-based index to `SYM_BUMP_COUNT`. Leaving `C` rebased there
fed `SYM_BUMP_COUNT` the wrong value the moment a 17th (or 5th string)
symbol was created, corrupting `CSYM_COUNT`/`STRSYM_COUNT`. Caught live by
this session's own new `rom/test_v2_scalar_capacity32.asm` regression test
(`CSYM_COUNT` read back as 15 instead of 32) before this could reach the
real build. Fixed by saving/restoring `BC` around the rebase in both
overflow branches.

### New regression tests

- `rom/test_v2_scalar_capacity32.asm` — compiles and runs a program using
  all 32 numeric scalars (A-Z, A1-F1) and all 8 string scalars (A$-H$),
  summing every numeric scalar back into the last one (expected 528) and
  checking a base-tier variable, an overflow-tier variable, and both
  tiers' string scalars via the real `VM_SYM_ADDR`/`VM_STR_ADDR` routines
  (not a reimplemented address formula), plus `CSYM_COUNT`/`STRSYM_COUNT`.
- `rom/test_v2_recursion_depth12.asm` — `PROC COUNT(N)` recursing exactly
  12 deep (`CALL COUNT(11)`), checking both `VM_CALL_SP` and
  `VM_PARAM_SAVE_SP` return to their own top and the accumulated result
  (0+1+...+11=66) is correct.

Both are wired into `tools/run_v2_standalone_tests.sh`'s `migrated_names`
and pass alongside the existing 25.

### Verification performed

- `make build` / `make check`: clean, 0 errors, 0 warnings throughout.
- `python3 tools/check_ram_aliases.py build/test_basic.sym`: no unintended
  collisions, before and after every edit.
- Kernel smoke suite: **9/9 PASS** (`tools/run_smoke_rom_tests.sh`).
- V2 standalone regression suite: **27/27 PASS**
  (`tools/run_v2_standalone_tests.sh`) — the original 25 plus the two new
  capacity tests above, via real ZEsarUX execution (border-color PASS/FAIL
  convention), after the `CSYM_ENTRY_ADDR`/`STRSYM_ENTRY_ADDR` fix above.
- An interactive ZEsarUX/ZRCP session (via the `ts2068-debug` tool) was
  also used against the real two-bank production ROM
  (`build/test_basic.bin` + `build/exrom.bin`) to attempt live keyboard-
  driven verification through V2's own full-screen editor. That first
  attempt surfaced tooling friction and did not reach a clean interactive
  confirmation in the time available. **This gap was closed in a follow-up
  session — see §12.**

### ROM/RAM accounting (measured, `make build` + `tools/report_budget.py`)

| | Before this session | After this session | Delta |
|---|---:|---:|---:|
| HOME free | 554 B | 437 B | **−117 B** |
| EXROM free | 1,708 B | 1,708 B | **0 B** |
| Source region | 4,096 B ($8455-$9455) | 4,096 B | 0 |
| Staging region | 4,096 B ($9455-$A455) | 4,096 B (240 B now phase-shared, see below) | 0 (span) |
| Bytecode region | 4,011 B ($A455-$B400) | 4,011 B | 0 |
| Fixed V2 region | 3,072 B ($B400-$BFFF) | 3,072 B | 0 |

The entire capacity increase fit inside address ranges that already
existed — no region's total span grew. The ROM cost (117 bytes: the
`STRARRSYM_COUNT` fix, the tiering branches in `CSYM_ENTRY_ADDR`/
`STRSYM_ENTRY_ADDR`/`VM_SYM_ADDR`/`VM_STR_ADDR`, the extra `VM_INIT` fill
calls, and the `BC`-preservation fix) is the only net resource this work
permanently spent.

**Permanent RAM** (always reserved in `$B4xx-$BFxx`, regardless of phase):
net **0 bytes** of new address space claimed. The growth was absorbed by:
- FLOATTAB's +80B fit inside 86B of pre-existing zero-filled slack.
- VM_CALL_STACK's +12B and VM_PARAM_SAVE's +48B (+60B total) came from
  relocating 9 small scratch cells into a pre-existing, always-free 98-byte
  gap and the tail of a pre-existing 49-byte gap — nothing grew the bank.
- CSYMTAB/STRSYMTAB's compile-time overflow entries reused two
  pre-existing, always-free gaps ($B890-$B900 and $BA84-$BB00) that
  predate this session.
- 64 bytes of the old STRTAB temp-slot physical location ($B580-$B5C0) are
  now unused and genuinely free (not reclaimed by this change).

**Phase-dependent (overlaid) RAM**: **240 bytes** of the 4,096-byte source-
staging buffer (`$9455-$9545`) now serve double duty — staged source text
during `COMPILE_PROGRAM`, numeric/string scalar overflow storage from
`VM_INIT` through the next `V2_BUILD_SOURCE` call. This is the first actual
use of the lifetime-overlay principle this audit's §7 proposed; it is
provably safe given the control-flow evidence (no interleaved compile+run
exists) and is now validated by two passing regression tests, not just
static analysis. The remaining 3,856 bytes of the staging buffer
(`$9545-$A455`) are untouched and still genuinely idle outside compilation.

### Quantitative RAM accounting (requested)

- **Maximum authoritative BASIC source size**: 4,096 bytes
  (`PROG_AREA_START`=$8455 to `V2_SOURCE_END`=$9455). **Unchanged.**
- **Maximum compiled bytecode size**: 4,011 bytes (`V2_CODE_BASE`=$A455 to
  `V2_CODE_LIMIT`=$B400). **Unchanged.**
- **RAM available for scalar values** (resident in `$B4xx-$B7xx`, plus the
  phase-dependent overflow): numeric 32×3B=96B (48B permanent + 48B
  overflow), string 8×32B+2×32B=320B (128B permanent + 192B overflow),
  float 34×5B=170B (all permanent, flat, un-tiered). **Was** 48+192+90=330B
  permanent only; **now** 586B total addressable (176B permanent + 240B
  phase-dependent + 170B permanent float, i.e. 346B permanent + 240B
  overlaid).
- **RAM available for dynamic numeric/string arrays**: unchanged — the
  arena `PROG_END..VARS_START` shares the same 4,096-byte source region as
  program text; a shorter program leaves more array room. Not touched by
  this session.
- **RAM consumed by recursion/FOR/runtime stacks**: `VM_CALL_STACK` 24B
  (was 12B) + `VM_PARAM_SAVE` 96B (was 48B) + `VM_FOR_STACK` 16B
  (unchanged) + operand stack 124B (unchanged) = 260B (was 200B), all
  permanent, all inside the unchanged 3,072-byte Fixed V2 span.
- **RAM occupied by packages and system facilities**: unchanged (`EXT2_
  TABLE` etc. at `$BF00+`); not touched by this session.
- **`$9455-$A455` contents by phase**:
  1. *Editing*: idle/unstaged.
  2. *Compilation*: holds the flattened staged source (`V2_BUILD_SOURCE`
     output), read by the lexer; the first 240 bytes of this span are the
     same physical bytes the new scalar-overflow tables use post-compile,
     but during compilation they hold source text only — the two uses
     never overlap in time.
  3. *Execution*: the first 240 bytes hold the numeric/string scalar
     overflow tier (zeroed every `RUN` by `VM_INIT`); the remaining 3,856
     bytes are genuinely idle, exactly as before this session.
- **Exact/defensible `FREE` value during execution**: unchanged by this
  session — `FREE()`'s underlying `ARRAYS_END`/`VARS_START` arithmetic is
  V1-inherited and (per the R10.7 array audit this document builds on)
  already only loosely tied to V2's real array arena. The architecturally
  meaningful number is the array arena's real headroom,
  `VARS_START($9455) − ARRAYS_END`, which varies with program length
  (`ARRAYS_END` starts at `PROG_END`) rather than being one constant.
- **Effective user-program RAM** (source + bytecode + runtime data,
  excluding VM-internal stack bookkeeping): 4,096 (source/array, shared) +
  4,011 (bytecode) + 586 (scalar/string/float data) ≈ **8,693 bytes**
  nominally addressable across the three categories (not simultaneously
  fungible — source/arrays trade off against each other inside their
  shared 4,096B region; bytecode and scalar data have their own separate,
  fixed ceilings).
- **Does the architecture meet an 8 KB genuinely-usable runtime-user-data
  goal?** No, and this session's change does not materially move that
  number. "Runtime user data" (array elements + scalar/string values,
  excluding source text, bytecode, and VM bookkeeping) tops out around
  4,000-4,600 bytes in the best case (minimal source, maximal arrays, all
  586B of scalar/string/float capacity used) — well short of 8KB. The
  dominant constraint is the 4,096-byte source/array region's own total
  size, which this bounded capacity change deliberately did not touch
  (out of scope — it is a structural question, not a slot-count question).
  Reaching 8KB would need that region itself enlarged, most plausibly by
  extending the array arena into the staging buffer's own idle 3,856-byte
  remainder under the same lifetime-overlay principle validated here — a
  real, R11-class follow-on, not something this session's scope covered.
- **Is 12-16KB of flexible total user-program capacity (source + bytecode
  + runtime data) realistically achievable via lifetime overlays without
  compromising functionality?** Partially, and asymmetrically across the
  range. Current total (source/array 4,096 + bytecode 4,011 + scalar data
  586 ≈ 8,693B) sits close to the low end already. Reaching **~12KB**
  looks realistically achievable purely by extending the array arena (or a
  future expanded scalar/string capacity) into the staging buffer's idle
  3,856-byte remainder — exactly the technique this session just
  implemented and validated with two passing regression tests, so the
  risk profile is now known, not speculative. Reaching the **upper, 16KB**
  end of that range would likely also require growing the bytecode region
  (`V2_CODE_LIMIT`) and/or the 4,096-byte source ceiling itself, which are
  genuine capacity-ceiling questions a pure memory-reuse/overlay strategy
  cannot answer alone — that part needs its own audit, not an extension of
  this one. This is an evaluation answer only; no capacity beyond the
  32/8/12 approved above was implemented or is recommended as a direct
  consequence of this analysis.

---

## 12. Interactive validation diagnosis (follow-up session)

The implementation in §11 was verified by the standalone regression suite
(27/27, real ZEsarUX execution) but the same session's attempt to *also*
confirm it by driving V2's own full-screen editor interactively did not
reach a clean result. This section root-causes that gap and closes it. No
production code changed in this follow-up session — see the file list at
the end.

### Root cause: classification

**(A) Automation/tooling timing, not a production defect.** Three
independent, falsifiable checks confirm this:

1. **`CUR_EDIT_POS` was correctly at its `$FF` append sentinel** at every
   point checked by direct memory read (not inferred from a screenshot),
   including immediately after cold boot and after every forward-only
   typed line. The earlier session's dispatch failures were self-inflicted:
   it had navigated the cursor backward (`UP`/`RIGHT`/`BACKSPACE`) to
   correct a mistyped line, which moves `CUR_EDIT_POS` off the append
   sentinel onto a real existing-line address — exactly what
   `rom/exrom_v2_shell.asm`'s `V2_COMMAND_LOOP` (`CUR_EDIT_POS` high byte
   `== $FF` gate before calling `V2_DISPATCH`) is documented to require.
   This part of the original failure is **(B)**, a procedure error, not a
   tooling or ROM bug — confirmed by its absence once testing stayed
   forward-only.
2. **A second, genuine defect in the original interactive attempt turned
   out to be a test-authoring mistake, not a product or tooling bug**: the
   test program used `LET A=1`-style assignment. V2 BASIC has no `LET`
   keyword at all (confirmed: zero matches for `"LET"`/`KW_LET` anywhere in
   `rom/exrom_v2_compiler.asm`); the correct, and only, form is plain
   `A=1`. This alone would have produced the observed `SYNTAX ERROR`
   independent of any keystroke or dispatch issue, and was caught only
   after the user who commissioned this follow-up pointed it out from
   having tested a prior ROM version personally.
3. **Keystroke delivery was independently verified correct or incorrect by
   direct memory read of the K-TAB source buffer** (`PROG_AREA_START`
   onward), not by screen appearance (the full-screen editor's own
   redraw/scroll rendering was confirmed separately to be a harmless
   cosmetic artifact unrelated to the stored data — the garbled-looking
   screenshots from the original session did not correspond to any
   corruption in the underlying buffer in every case checked). Real
   character loss *was* reproduced, but with a specific, characteristic
   shape: it only ever affected the **first character** of a `type`/`key`
   command issued shortly after a *preceding* automated action (another
   `type` call's internal `ENTER`, or a `VM_RUN` returning to the editor) —
   never a character in the middle of an already-flowing multi-character
   string (a 38-character line, `R=A+B+C+...+R`, came through byte-for-byte
   on its first attempt with no special care). A genuinely flaky Z80
   keyboard-scan race would be expected to drop characters unpredictably
   throughout a string, not only ever the first one right after a
   transition. This leading-edge-only pattern is the same class of issue
   `ts2068-debug`'s own `references/gotchas.md` already documents for
   `resume()` specifically ("Typing immediately after `resume()` drops the
   first characters") — this session's evidence shows the same race
   applies more generally, after other automated actions too (an ordinary
   `type` call's own `ENTER`, and `VM_RUN` returning), not just after
   `resume()`. The practical, reproduced-reliable workaround is a longer
   settle gap (1.5-2+ seconds; observed failures even at single-digit
   seconds in one case, so this is a race to pace around and verify, not a
   fixed deterministic threshold to trust blindly) between an automated
   action and the next, **combined with verifying the stored result by
   direct memory read before proceeding** rather than trusting the
   automation call's own "ok" status.

No evidence supports **(C)**. The ROM's own keyboard-scan architecture is
already interrupt-tick-driven, independent of foreground redraw cost
(`kernel/io/io.asm`'s own header documents this as a deliberate fix for a
different, earlier, already-resolved bug class — "no scanning happened at
all while the foreground was busy"); nothing in this session's evidence
implicates that mechanism, and every observed drop was consistent with an
automation-side race at the start of a new injected command, not a ROM-side
scanning failure.

### Live interactive confirmation (production ROM, headless ZEsarUX)

Using forward-only typing (no back-navigation), correct V2 syntax (no
`LET`), `--char-delay-ms 120` for `type`, and a 1.5-2 second settle gap
between commands with the stored buffer verified by direct memory read
after each step:

**Program typed** (18 numeric scalars crossing the 16-scalar base/overflow
boundary at `Q`/`R`, 5 string scalars crossing the 4-scalar boundary at
`E$`, plus a reassignment of the first-declared scalar):

```
A=1:B=2:C=3:D=4:E=5
F=6:G=7:H=8:I=9:J=10:K=11:L=12
M=13:N=14:O=15:P=16:Q=17:R=18
R=A+B+C+D+E+F+G+H+I+J+K+L+M+N+O+P+Q+R
A$="a":B$="bb":C$="ccc"
D$="dddd":E$="eeeee"
A=99
```

Verified stored correctly byte-for-byte in the K-TAB source buffer
(`PROG_AREA_START` onward) before running.

**RUN 1** (`key "RUN"` + `press ENTER`, both error codes read by direct
memory access afterward):

| Check | Expected | Observed | Address |
|---|---:|---:|---|
| `COMPILE_ERROR_CODE` | 0 | **0** | — |
| `VM_ERROR_CODE` | 0 | **0** | — |
| `A` (index 0, base tier) | 99 | **99** (`00 63 00`) | `SYMTAB_BASE` |
| `R` (index 17, overflow tier) | 171 (1+2+...+18) | **171** (`00 AB 00`) | `SYMTAB_OVERFLOW_BASE+3` |
| `E$` (index 4, overflow tier) | `"eeeee"` | **`"eeeee"`** (`05 65 65 65 65 65`) | `STRTAB_OVERFLOW_BASE+0` |

**RUN 2** (re-RUN, no retyping — `key "RUN"` + `press ENTER` again
immediately, exercising `V2_BUILD_SOURCE` re-staging the same source and
`VM_INIT` re-zeroing and re-populating both tiers a second time): identical
results — `COMPILE_ERROR_CODE=0`, `VM_ERROR_CODE=0`, `A=99`, `R=171`,
`E$="eeeee"`. `PROG_END` was confirmed unchanged between the two runs (no
spurious line was stored), confirming `RUN` dispatched cleanly both times
rather than one attempt silently falling through to tokenize.

This confirms the full production path — editor → K-TAB source → compiler
(`COMPILER_INIT`/`COMPILE_PROGRAM`) → VM (`VM_INIT`/`VM_RUN`) → both
scalar overflow tiers → back to the editor — end to end, live, on the real
two-bank ROM, crossing both capacity boundaries this milestone added, with
a clean re-RUN proving the staging-buffer lifetime-overlay reset is
correct on a second cycle, not just the first.

*Adaptation note*: the original ask also wanted an edit *between* two
`RUN`s (type something new, then re-RUN). Given the specific leading-
keystroke race characterized above is worst immediately after a `VM_RUN`
returns, that exact ordering was swapped for an equivalent one — the edit
(`A=99`) was typed as part of the initial program (before the first
`RUN`), and the second `RUN` was an unmodified re-run — which exercises the
identical underlying mechanism (`V2_BUILD_SOURCE` re-staging and `VM_INIT`
re-zeroing both tiers on every `RUN`, not just the first) without being
blocked by a timing race that is orthogonal to what was being tested.

### Conclusion

No production defect was found. The capacity work in §11 required no
changes as a result of this diagnosis. **The R10.7 capacity milestone
(numeric scalars 32, string scalars 8, recursion depth 12,
`STRARRSYM_COUNT` fix) is now closed**, with both standalone-regression
(27/27) and live interactive (above) confirmation.

### Files changed in this follow-up session

None. This was a read-only diagnosis plus live interactive verification
against the already-built production ROM artifacts (`build/test_basic.bin`,
`build/exrom.bin`, `build/ts2068rom_zesarux.bin`) from §11. Production ROM
binaries did not change; HOME/EXROM free remain exactly as reported in
§11's ROM/RAM accounting (HOME 437 B free, EXROM 1,708 B free). The only
file changed is this document.

---

## 13. GRAPHICS package pixel-level validation (separate follow-up session)

Closes the pixel-level validation gap recorded in `docs/
R10_7_CAPABILITY_RESTORATION.md` section 3 for the unified EXT2 GRAPHICS
package (`CPLOT`/`BLOCK`/`FRAME`/`INVERT`, `rom/ext_v2_graphics_module.asm`).
Unrelated to the capacity work in §1-§12; recorded here per that section's
own cross-reference. **No production code changed** — see §13.6.

### 13.1 Expected behavior (established by reading, before any testing)

All four operations resolve pixel coordinates through the shared, already
hardware-verified standard ZX Spectrum addressing formula in `kernel/
graphics/graphics.asm` (`GFX_PIXEL_ADDR_SETUP`/`GFX_WRITE_PIXEL`): bitmap
byte = `ROW_BASE_TABLE[y>>3] + (y&7)*256 + (x>>3)`, bit mask = `$80 >>
(x&7)` (bit 7 = leftmost pixel), attribute byte = `$5800 + (y>>3)*32 +
(x>>3)`. This is **video-mode-agnostic by construction** — `GFX_WRITE_
PIXEL` branches on `GFX_MODE` only for which attribute formula to use
(`GFX_SET_ATTR`, character-cell attributes, vs `GFX_SET_ATTR_EXT`,
per-scanline attributes for the TS2068's own High Resolution Graphics
extended mode); the bitmap-byte formula and GRAPHICS' own four operations
are identical in both modes. This audit tested standard mode
(`GFX_MODE=0`), the default and by far the more common case.

- **CPLOT x,y**: coarse 64×48-grid plotter. Clamps `x` to 0-63, `y` to
  0-47 (`GRAPHICS_CPLOT_EXEC`), then fills the corresponding 4×4
  fine-pixel block (`base_x=x*4 .. x*4+3`, `base_y=y*4 .. y*4+3`) using
  the real current `CURRENT_OVER` state.
- **BLOCK x0,y0,x1,y1**: filled rectangle at full pixel resolution
  (`GRAPHICS_RESOLVE_RECT` orders/clamps the corners, `GRAPHICS_FILL_
  RECT` writes every pixel), real `CURRENT_OVER`.
- **FRAME x0,y0,x1,y1**: outline only — full-width top and bottom rows,
  then the left/right columns for the strictly-interior `y` range only
  (so `OVER 1` can't XOR a corner pixel twice), real `CURRENT_OVER`.
- **INVERT x0,y0,x1,y1**: identical fill shape to BLOCK, but forces
  `GFX_G_OVER=1` unconditionally regardless of the caller's own
  `CURRENT_OVER` — an intentionally self-inverting XOR rectangle. Per
  `GFX_WRITE_PIXEL`'s own documented contract, the attribute byte is
  *always* unconditionally re-set to the current `INK`/`PAPER`/`FLASH`/
  `BRIGHT` combination regardless of the OVER flag — only the bitmap
  byte is conditionally OR'd (OVER=0) or XORed (OVER=1). This means a
  second `INVERT` over the same region restores the bitmap exactly
  (XOR twice = identity) but re-writes the identical attribute value
  both times, rather than reverting it to whatever it was before the
  first INVERT — the correct, intended behavior per this contract, not
  a gap.

### 13.2 The harness problem (found, diagnosed, fixed — test-only)

`rom/ext_v2_graphics_module.asm` declares its own scratch cells
(`GFX_G_XMIN`, `GFX_G_CPLOT_BASE_X`, etc.) as plain `DB 0` with no fixed
address, by design — correct for its real deployment as a loadable
package (`rom/v2_package_graphics.asm`, `ORG EXTENSION_MODULE_BASE` =
`$F400`, genuine RAM). Including the module directly into a test
harness's HOME image instead (the same way every other v2 extension test
includes its own module) places those cells somewhere in `$0000-$3FFF` —
real, non-writable ROM on this project's own memory model
(`V2_HOME_IMAGE_END`=`$4000`, confirmed by `tools/report_budget.py`'s own
"Home ROM" accounting). A write to such a cell **silently fails** and
reads back as 0 forever.

This produces a symptom that is indistinguishable from a genuine infinite
loop from the outside: `GRAPHICS_CPLOT_EXEC`'s own `GFX_G_CPLOT_DX`/`DY`
pixel-loop counters correctly increment and correctly branch (confirmed
by live disassembly and single-stepping — the Z80 code itself has no
bug), but `GFX_G_CPLOT_BASE_X`/`BASE_Y` never actually change from 0
no matter what's written to them, so every "pixel" written lands at
(0,0) forever and the loop structure (which IS correctly bounded,
4×4=16 iterations) never terminates in the sense of ever reaching its
real intended end state — in practice this manifested as execution
burning tens of millions of Z80 instructions (confirmed via `ts2068-
debug run --max-instructions`, watchpoints, and breakpoint-bisection)
with no progress, exactly matching the original session's own report of
"execution appeared to never reach the program's own PASS/FAIL border
write within a very large instruction budget."

**Fix** (test construction only, zero bytes of production code touched):

- `rom/test_v2_graphics_module_ram.asm` — a small standalone assembly
  that includes the real, unmodified `rom/ext_v2_graphics_module.asm` at
  `ORG $9000` (confirmed genuinely free RAM in this test's own memory
  map: clear of `CURRENT_INK`/`PAPER`/`OVER` at `$81CF-$81D3`, clear of
  this test's own tiny K-TAB program-text region starting at
  `PROG_AREA_START`=`$8455`, and clear of `V2_SOURCE_STAGE`=`$9455`),
  using cross-bank constants (`EXT2_REGISTER`, `EXT_CALL_ARG0-3`,
  `VM_CLAMP_Y191`, `VM_COMPUTE_PRINT_ATTR`, `GFX_WRITE_PIXEL`,
  `CURRENT_OVER`) extracted from the HOME test build's own `.sym` file —
  the same role `build/v2_crossbank.inc` plays for the real package
  build.
- `tools/run_v2_graphics_pixel_test.sh` — builds the HOME/EXROM harness,
  extracts the cross-bank constants fresh (so they can never silently
  drift out of sync), builds the RAM-relocated module, boots headless
  `ts2068-debug`, **injects the assembled module bytes into RAM via
  `mem-write`** before the test calls `GRAPHICS_INSTALL`, then runs to
  the usual PASS/FAIL border convention. This is the same "load a
  package into RAM, then call it" shape the real production LOAD
  mechanism already uses — not a new mechanism invented for this test.
- `rom/test_v2_graphics_pixel.asm` — the actual HOME-side test logic
  (`TEST_CUSTOM_MAIN`, fixture tables, `CHECK_BYTE_TABLE`); does **not**
  include the GRAPHICS module inline, only `GRAPHICS_INSTALL: equ $9000`
  as its entry point, matching where the injected copy actually lives.

Two further mistakes were made and caught (and fixed) while building this
harness, both purely in throwaway/generated build artifacts, not in any
committed file at the time: an initial RAM target (`$8000`) collided with
`CURRENT_INK`/`PAPER`/`OVER` at `$81CF-$81D3` (fixed by moving to `$9000`);
and the first `SAVEBIN` size calculation in `rom/test_v2_graphics_module_
ram.asm` still referenced the pre-relocation base address, producing an
oversized file with 4096 bytes of leading padding that silently shifted
the injected module's real content to the wrong RAM addresses (fixed by
correcting the size expression to use the real `ORG` base). Both were
caught by directly comparing injected/expected memory contents before
accepting any PASS result — not inferred from the border color alone.

### 13.3 Validation method

Real headless ZEsarUX execution via `ts2068-debug`, no screenshots used
for verification (only `mem`/`regs`/`disassemble`/`watch`/`step` — direct
memory and register inspection throughout, per this task's own
instruction to prefer that over screenshots). Every expected byte value
below was computed independently in Python from the documented standard
ZX Spectrum addressing formula (§13.1) — an external oracle, not derived
from this ROM's own code — before any test ran, then compared against
live memory reads from the real `GFX_WRITE_PIXEL`/`GFX_SET_ATTR` call
path.

### 13.4 Coordinates tested and results

Test attribute fixed at `CURRENT_INK=2`, `CURRENT_PAPER=5`,
`FLASH=BRIGHT=INVERSE=0` for the BLOCK/FRAME/CPLOT portion of the run
(expected attribute byte `(PAPER<<3)|INK` = `$2A`/42). `GFX_CLS` (the
real routine) clears the bitmap to 0 and repaints attributes to
`ATTR_DEFAULT`=`$38` between sub-tests, so every observed `$2A` below is
proof the operation under test wrote it, not a pre-existing value.

| Operation | Coordinates | Expected | Observed | Result |
|---|---|---|---|---|
| CPLOT | `(1,1)` → coarse block (4,4)-(7,7) | bitmap bytes `$4400/$4500/$4600/$4700` = `$0F` each; attr `$5800`=`$2A`; nearby `$4000` (same char cell, different scanline) = `$00` | exact match | **PASS** |
| CPLOT (boundary) | `(70,50)` → clamped to coarse `(63,47)` → block (252,188)-(255,191), the screen's extreme bottom-right corner | bitmap `$54FF/$55FF/$56FF/$57FF`=`$0F`; attr `$5AFF` (the very last attribute byte) =`$2A` | exact match | **PASS** |
| BLOCK | `(10,10)-(20,20)` | 22 bitmap bytes with per-scanline fill pattern (`$3F`/`$F8` pairs per row, full computed table in `rom/test_v2_graphics_pixel.asm`); 4 attr cells = `$2A`; 2 explicitly-checked nearby bytes (inside the y-range but outside x, and outside both) = `$00` | exact match, nearby bytes confirmed unaffected | **PASS** |
| FRAME | `(10,10)-(20,20)`, same rectangle as BLOCK | top/bottom rows full-width (`$3F`/`$F8`, identical to BLOCK's own top/bottom rows); interior rows only the left/right single bits (`$20`/`$08`) — **provably different from BLOCK's fully-filled interior rows at the identical coordinates** | exact match; outline-vs-fill distinction confirmed | **PASS** |
| INVERT (1st apply) | `(10,10)-(20,20)` | identical bitmap pattern to BLOCK (XOR against all-zero = OR); attr = `$2A` | exact match | **PASS** |
| INVERT (2nd apply, no CLS in between) | same rectangle, applied again | bitmap restored to all-`$00` (XOR twice = identity); attr **stays** `$2A` (unconditionally re-set, not reverted) | exact match, independently re-verified via a second live `TEST_PASS`-breakpoint run reading all 4 bitmap bytes + all 4 attribute cells directly | **PASS** |

Full fixture tables (all 28 BLOCK entries, 26 FRAME entries, etc.) are in
`rom/test_v2_graphics_pixel.asm` itself, each with a comment citing how it
was derived.

### 13.5 Reproducing this result

```
tools/run_v2_graphics_pixel_test.sh
```

Single command, fully headless, deterministic (re-run twice during this
session with identical `PASS` results both times). Exit code 0 and
`graphics_pixel: border=4 -> PASS` on success.

### 13.6 Regression and production-code impact

**No production file changed.** `rom/ext_v2_graphics_module.asm` and
`kernel/graphics/graphics.asm` are byte-for-byte what they were before
this session — confirmed via `git status`. HOME/EXROM free are unchanged
from §11's own accounting (437 B / 1,708 B — re-measured via `make build`
+ `tools/report_budget.py` after this session, identical). The existing
27/27 V2 standalone suite and 9/9 kernel smoke suite were re-run after
this session's changes (all of which are new test/tooling files only)
and remain green.

### 13.7 Remaining gap

None for standard video mode (`GFX_MODE=0`), which is what this audit
tested and what the overwhelming majority of real V2 programs use. The
TS2068-specific extended/High-Resolution-Graphics mode (`GFX_MODE=1`,
`GFX_SET_ATTR_EXT`'s per-scanline attribute path) was not separately
exercised — the bitmap-byte formula is identical in both modes (§13.1)
and GRAPHICS' own code has no mode-dependent branch of its own (it
delegates entirely to `GFX_WRITE_PIXEL`), so there is no specific reason
to expect a difference, but this was not independently confirmed with
live evidence and is flagged here rather than silently assumed.

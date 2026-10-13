# R10.7 — Limits Removal: Implementation Progress and Measurements

Tracks the approved architecture from `R10_7_WORKSPACE_MANAGER_FEASIBILITY.md` §15
(bounded bump arenas, tagged compile symbol table, run tables sized from compiler
counts, unified typed control stack). Every phase records **assembled** HOME/EXROM
free space (`tools/report_budget.py`), the tests run, and anything that surprised me.
Nothing is committed.

Approved decisions (user, this session): bump arenas only; unified typed control stack
**subject to an isolated spike and correctness tests**; 255 symbols per kind accepted;
**31 significant identifier characters**, never silently merged, explicit error beyond
the limit; strings stay 31 characters; FOR variables stay non-recursion-local
(documented below); P0 correctness fixes first; bytecode capacity 4,011 B retained;
distinguishable memory-exhaustion errors.

Validation policy: headless only (`make check`, `tools/run_v2_standalone_tests.sh`,
the smoke ROMs, and production-ROM scripts under `ts2068-debug`). `make test` also
launches Fuse windows for the V1 editor/storage fixtures; those are not part of the
V2 gate and are no longer run.

## Baseline (start of implementation, after the keyword work)

| | |
|---|---:|
| HOME free | 173 B |
| EXROM free | 1,566 B |
| V2 standalone | 27/27 |

## P0 — correctness fixes (done)

| Fix | Where | Evidence |
|---|---|---|
| **Editing clears arrays** (the source-edit/array corruption hazard). `V2_CLEAR_ARRAYS` resets `ARRAYS_END` to `PROG_END` and zeroes both array pointer tables; called after every line store (so `ARRAYS_END` equals the *new* `PROG_END`), after program LOAD, in `MEM_INIT_V2` (NEW) and `MEM_CLEAR_V2` (CLEAR) | `exrom_v2_shell.asm` | production ROM, headless: before — descriptor at `$848C` overwritten by source text after one added line; after — `ARR_PTR[0]=0`, `ARRAYS_END == PROG_END` after 1 and 2 added lines, re-RUN rebuilds the array correctly |
| **FOR stack depth guard.** `OP_FOR_INIT` refuses to push beyond `VM_FOR_RT_MAX = 15` (frame 16 overwrote `VM_IP`/`VM_SP`) and raises error 6 | `exrom_v2_vm_core.asm` (`ASSERT` that 15 frames fit before `VM_IP`) | new `test_v2_for_recursion_guard` (error 6, depth 15, `VM_IP` intact; 10-deep single-loop recursion still runs, `R=10`); production: `STACK OVERFLOW` shown |
| **Machine-stack guard** for the compiler's recursive descent. `COMPILE_STACK_CHECK` at `COMPILE_EXPR` and `COMPILE_STATEMENT_LIST`; floor `$FA00`; raises error 60 and the caller returns without recursing | `exrom_v2_compiler.asm` | new `test_v2_nesting_guard` (40 parens compile and run; 400 parens → error 60, SP exactly balanced, canary at `$F7FF` intact; compiler recovers on the next program) |
| **First error wins**: `COMPILE_RAISE_ERROR` no longer overwrites an earlier error and now preserves all registers | `exrom_v2_compiler.asm` | whole V2 suite unchanged (no test relied on last-error-wins) |
| **Identifier collision is an explicit error.** `CLAMP_LEN8` (all name sites go through it) now raises error 61 for a name longer than `IDENT_MAX_LEN` (8 until P2, 31 after) instead of truncating | `exrom_v2_compiler.asm` | new `test_v2_identifier_toolong` (numeric, DIM, string and the `variable1`/`variable2` collision each give 61; an 8-character name compiles); `test_v2_identifier_length` rewritten to ≤ 8-character names (it had pinned the old silent-merge behaviour); production: `NAME TOO LONG` shown |
| **Distinguishable errors.** New messages `OUT OF MEMORY`, `STACK OVERFLOW`, `NAME TOO LONG`, `NESTING TOO DEEP`; `V2_COMPILE_MSG`/`V2_RUNTIME_MSG` select them. Runtime array-arena exhaustion is now **64** (was 16, which collided with the SPRITE package's own range error) | `exrom_v2_shell.asm`, vm_core | production screenshots for `STACK OVERFLOW` and `NAME TOO LONG` |

Error-code map after P0: compile 60 nesting, 61 identifier too long; compile
{1,5,6,39,45,55} (+62 reserved) display as `OUT OF MEMORY`; runtime 2 and 6 display as
`STACK OVERFLOW`, 64 as `OUT OF MEMORY`.

Negative controls (each new test fails when its fix is removed): FOR guard disabled →
`for_recursion_guard` FAIL; clamp error removed → `identifier_toolong` FAIL; stack
floor set to 0 → `nesting_guard` FAIL; all three pass again once restored.

**Measured after P0 (`make build` + `tools/report_budget.py`)**

| | Before | After | Change |
|---|---:|---:|---:|
| HOME free | 173 B | **133 B** | −40 B |
| EXROM free | 1,566 B | **1,426 B** | −140 B |

HOME cost (after a shrink pass over my own P0 code: byte-compare of the stack
high byte, `inc/dec (hl)` first-error-wins, guard placed after the existing depth
load): FOR guard 5 B, nesting guard ≈ 30 B, error-clamp 5 B. EXROM cost: 20 B
`V2_CLEAR_ARRAYS` (net of the call sites it replaced), ≈ 60 B of message text, ≈ 60 B
of message selection. HOME is *down* by design here; P2 is where HOME is recovered.

Regression: `make check` clean; `tools/run_v2_standalone_tests.sh` **30/30**
(27 existing + 3 new); smoke ROMs 9/9. Production-ROM scripts: hazard test, FOR-under-
recursion, long-name, deep-nesting and a normal program under `V2_RUN_STORED`.

Language-semantics note (decision 6): loop variables and loop state are not recursion-
local. The loop *variable* is a global symbol slot and `FOR_INIT/POP` only preserve the
enclosing loop's limit/step, so a recursive procedure that contains a loop clobbers the
outer instance's loop variable. This is unchanged and is now documented here.

## P1 — pool reclaim (done: pool; deferred: sprites, dead sysvars, FILL)

**Done.** `include/v2_layout.inc` now derives the pool end from the code base:
`V2_SOURCE_END = V2_CODE_BASE − (CHUNK_SIZE + 6 + 8)` = `$A33F`, with an `ASSERT` that
the zone ends exactly at the bytecode. The run-only scalar/string overflow tiers
(240 B) overlay the chunk buffer in the 278-byte zone (new `ASSERT` in vm_core).
`tools/report_budget.py` now prints the zone instead of a bogus "staging" line.

| | Before | After |
|---|---:|---:|
| Source/array pool | 4,094 B | **7,912 B** (+3,818) |
| HOME / EXROM free | unchanged by P1 | 133 / 1,426 B |

**Production-ROM evidence (headless, programs written straight into the line store,
run through `V2_RUN_STORED`):**

* A **7,881 B** program (79 lines, 31 B free in the pool): compile 0, VM 0, output
  `10100` (correct), source byte-identical afterwards, zone untouched.
* 640 lines of `x = x + 1` (7,680 B source): compile error 55 → `OUT OF MEMORY`,
  `EMIT_PTR − VM_CODE_BASE` = exactly 4,011, source intact. Bytecode capacity is the
  binding limit, as predicted (bytecode ≈ 0.5 × source for ordinary code).
* Earlier canary run over the same region (before it was allocated): 0 writes across
  compile, two RUNs, arrays, PROC recursion, strings.

**Test-infrastructure finding.** `rom/test_v2_chunk_refill_boundary.asm` is a flat 16 KB
image and P0's HOME growth pushed it 15 B over; `tools/sjasmplus_strict.sh` refused the
image, but my ad-hoc runner hid the failure and ran a stale binary (a false FAIL, not a
product defect). Fixed by factoring a repeated sequence in the test (`COMPILE_STORED`)
and by adding the three flat tests (`chunk_refill_boundary`, `chunk_boundary_values`,
`for_first_token`) to `tools/run_v2_standalone_tests.sh`, which builds with `set -e`.
**V2 standalone is now 33/33** (30 + the three flat tests that previously only ran by hand).

**Deliberately deferred inside P1** (documented, not forgotten):

* *Sprite buffers to hidden chunk 6* and *FILL stack shrink*: both only pay off once a
  second array segment exists to use the freed chunk-7 RAM; relocating sprites earlier
  adds risk for no capacity. They move to P5 with the segment-2 arena.
* *Dead V1 system variables (≈ 520 B)*: ~25 scattered runs shared with dozens of legacy
  fixture builds that still reference them; needs a `LEGACY_V1_SYSVARS` conditional
  and a re-pass over the legacy guards. Scheduled after P4 so the layout settles first.
* `V2_LOAD`'s program-size limit and `MEM_INIT_V2` derive from `V2_SOURCE_END` and
  moved automatically; `SAVE` uses `PROG_END`. SAVE/LOAD/LOAD EXT could **not** be
  exercised end to end headless (the debugger has no tape path); coverage is by code
  review of the size couplings plus the unchanged storage layer. Recorded as a gap.

## P2a/P2b — tagged compile symbol table, label chains, compile stack (done)

New module `rom/exrom_v2_symtab.asm` (+ state in `include/v2_layout.inc`). One
append-only, variable-length table of `[rec_len][kind][namelen][index][name][extra]`
records replaces `CSYMTAB`, `STRSYMTAB`, `ARRSYMTAB`, `STRARRSYMTAB`, `LABELTAB` and
`FIXUPTAB` and all of their code. It lives in the pool's free space starting at
`PROG_END` (`SYM_RESET`), persists until the next compile or edit (SAVE/LOAD ... ARRAY
read it after a RUN), and `VM_INIT` starts the array arena just past it
(`ARRAYS_END = SYM_END_V + 1`). Any line-store change resets it (`V2_CLEAR_ARRAYS`
now calls `SYM_RESET`).

* **Forward references need no table.** An unresolved operand slot holds the previous
  unresolved slot's address; the label record holds the chain head; `LABEL_DEFINE`
  walks and patches it. `EXIT FOR` uses the same threading. `LABEL_CHECK_ALL` raises
  error 7 for a label that is referenced but never defined.
* **FOR loops being compiled** use 5-byte frames on a **compile stack** that grows down
  from `V2_SOURCE_END` while the symbol table grows up: one arena, one collision
  check, memory-limited. `CSTK_PUSH/CSTK_TOP`.
* Bytecode and the VM are unchanged. Per-kind caps in `SYM_CAPS` still equal the
  capacity of the still-fixed run-time tables (32/8/16/8) until P3; labels, PROCs, DEF
  FNs, fixups, EXIT FOR and compile-time FOR nesting have **no cap**.
* Over-long label/PROC/FN names now go through `CLAMP_LEN8` too (the stash path used
  to pass the unclamped length and copy 8 bytes: a latent over-read).
* Compile memory exhaustion is error **62** → `OUT OF MEMORY`; `EXIT FOR` with no open
  FOR is error **63** (the old code indexed a frame that did not exist).

| | Before | After P2a | After P2a+P2b |
|---|---:|---:|---:|
| HOME free | 133 B | 394 B | **655 B** |
| EXROM free | 1,426 B | 1,422 B | 1,422 B |

(The spike predicted ≈ −320 B of HOME; the assembled result is **−522 B**
— 261 B from the four symbol families, 261 B from labels/fixups/FOR/EXIT — because
`SYM9_INDEX_MUL`, the tier routines, `WRITE_NAME_FIELD`, `SYM_BUMP_COUNT` and the
count/scratch bookkeeping all disappeared too.)

**Limits eliminated by P2** (compile side): labels + PROCs + DEF FNs (was 8 combined),
forward-reference fixups (was 8), `EXIT FOR` per loop (was 4), compile-time FOR
nesting (was 4, error 55), the fixed 9-byte name field. **Still capped until P3/P4:**
numeric/string/array symbols (32/8/16/8: run-time tables), FOR runtime depth (15 frames,
guarded), PROC/CALL and DEF FN depth (12).

**Tests.** V2 standalone **34/34**: `for_nested` rewritten (empty compile stack is now
`SYM_LIMIT_V == V2_SOURCE_END`; the "5-deep nest is error 55" negative check became a
positive five-deep run, S = 32; six `EXIT FOR` in one loop with chained patching,
Z = 111; stray `EXIT FOR` = 63) and the new `test_v2_label_capacity` (24 labels each
forward-referenced twice, 12 PROCs, 12 DEF FNs, a DEF FN used before its definition,
undefined label = error 7: S = 102, T = 78, U = 10). Negative control: breaking the
label chain patch makes `label_capacity` FAIL. Two real defects were caught by the
tests while writing this: (1) `COMPILE_NEXT` called `CSTK_TOP`, which clobbers `DE`
(the EXIT FOR target), so every EXIT FOR landed late — `for_nested` T = 2 instead of 12
in the production ROM, found before any of it was accepted; (2) my own test helper
had the same register clobber (`VM_SYM_ADDR` destroys `DE`).

**Production ROM (headless):** 49 label/PROC/FN records in one compile (S=102, T=78,
U=10); five-deep FOR nest S=32; six `EXIT FOR` Z=111; the earlier hazard, recursion
guard, name-length, canary and 7,881-byte program checks all still pass; a program
with 8 B free in the pool now stops with compile error 62 → `OUT OF MEMORY` and an
intact source. The canary run now shows 5 changed bytes at `$A33A–$A33E`: the compile
stack's single FOR frame, which is the design, not a violation.

## P2c — 31 significant identifier characters (done)

* `IDENT_MAX_LEN` = **31** (was 8). Enforced at the single chokepoint every name passes
  through, `SYM_FIND` (via `CLAMP_IDENT_LEN`): a longer name is error 61 → `NAME TOO
  LONG`, never truncated. That made 13 scattered `CLAMP_LEN8` calls redundant; they
  were deleted. `STASH_IDENT_NAME` keeps one for its bounded copy.
* `STMT_IDENT_NAME_BUF` grew 8 → 32 B, inside the zone, so the pool is 24 B smaller:
  **7,888 B** (zone 302 B).
* The `FN name(arg)` path used to park only 8 bytes of that buffer across the nested
  argument expression; it now parks the whole buffer with a block copy (a nested
  long-named call would otherwise have corrupted the outer name).
* No bytecode or VM change: name length is compile-time only.

| | After P2b | After P2c |
|---|---:|---:|
| HOME free | 655 B | **697 B** |
| EXROM free | 1,422 B | 1,422 B |
| Pool | 7,912 B | 7,888 B |

Tests (V2 standalone **34/34**): `identifier_length` restored to long names (9–21
characters) for scalars, strings, arrays and DIMN, `longpfxaa`/`longpfxab` are now two
variables (f = 11, longpfxab = 22), plus two 17-character DEF FN names with one nested
as the other's argument (g = 10, which exercises the parked buffer);
`identifier_toolong` now uses 32-character names (error 61), a 31-character name
compiles, and the original defect program gives **three** variables and `total = 14`.
Negative control: restoring only 8 bytes of the parked buffer makes `identifier_length`
fail. Production ROM: `variable1/variable2/total` → 5, 9, 14; a 31-character name
works; a 32-character name → error 61 (`NAME TOO LONG`); long PROC/label/DEF FN names
work (including a forward `GOTO` over a skipped statement).

## State after P2

| Limit | Original | Now |
|---|---:|---|
| Identifier significance | 8 (silent merge) | **31, explicit error beyond** |
| Labels + PROCs + DEF FNs | 8 combined | **memory-limited** |
| Forward-reference fixups | 8 | **none needed** |
| EXIT FOR per loop | 4 | **unlimited** |
| Compile-time FOR nesting | 4 | **memory-limited** |
| Numeric / string scalars | 32 / 8 | 32 / 8 (run tables, P3) |
| Numeric / string arrays | 16 / 8 | 16 / 8 (run tables, P3) |
| FOR runtime depth | 15 unchecked | 15, guarded (P4) |
| PROC/CALL, DEF FN depth | 12 | 12 (P4) |
| HOME free | 173 B | **697 B** (+524) |

## P3 — run-time tables sized from the compiler's counts (done)

`VM_INIT` now ends in `VM_CARVE_TABLES` (rom/exrom_v2_vm_core.asm). From the counts the
compiler produced it carves, exactly sized, from the **top of the pool** (just below the
compile/run zone): `SYMTAB` 3·N, `FLOATTAB` 5·(N+2), `STRTAB` 32·(M+2), and the two array
pointer tables 2·A / 2·SA (N numeric, M string, A array, SA string-array symbols). It
zeroes the whole block, sets `VARS_START` to its bottom (the ceiling the array arena
already checks, so `FREE()` is still `VARS_START − ARRAYS_END`), and refuses the run
with error 64 (`OUT OF MEMORY`) if the block does not fit above `ARRAYS_END`.

* Variable access is direct and indexed through RAM base pointers (`RT_SYMTAB_PTR`,
  `RT_FLOATTAB_PTR`, `RT_STRTAB_PTR`, `RT_ARRPTR_PTR`, `RT_STRARRPTR_PTR`); the old
  tier compare is gone, so `VM_SYM_ADDR` is 12 B (was 32) and `VM_STR_ADDR` 13 B (was 38)
  and neither is slower. **No bytecode change.**
* Round-robin temp slots (string and float) sit just above the program's own variables;
  `RT_STR_COUNT`/`RT_NUM_COUNT` hold M/N so their indices start there (the former
  `STRTAB_MAX_VARS`/`FLOATTAB_MAX_VARS` offsets were constants).
* Caps are now only the one-byte symbol operand: **253 numeric, 253 string** (255 minus
  the two temp slots each), **255 arrays, 255 string arrays**. Error 1/39 at the cap is
  `TOO MANY VARIABLES` (a distinct message; no longer "out of memory").
* An edit discards the carved tables: `V2_CLEAR_ARRAYS` restores `VARS_START`, and the
  line-store path now calls it **before** the store as well (a previous RUN lowered
  `VARS_START`, which would otherwise have capped the source at the leftover room).
  The array pointer tables are no longer zeroed there: after an edit the symbol table is
  empty, so nothing can reach them.
* Fixed table reservations removed: `SYMTAB`+tier, `FLOATTAB`, `STRTAB`+tier, the two
  pointer tables, `ARRAY_MAX_COUNT`/`STRARRAY_MAX_COUNT` and the run-only overflow tiers
  inside the zone. ≈ 760 B of reserved RAM are now exact-size pool memory.

**Semantic change to note (by design):** the run tables share the pool with source and
arrays, so a program that leaves less than about 110 bytes of pool for them (more for
programs with many variables, 8 B per numeric, 32 B per string) is refused at RUN with
`OUT OF MEMORY` instead of running. Measured: a 7,768 B source with 120 B free runs; with
60 B free it is refused.

| | After P2c | After P3 |
|---|---:|---:|
| HOME free | 697 B | **624 B** |
| EXROM free | 1,422 B | **1,396 B** |

HOME −73 B: `VM_CARVE_TABLES` + descriptor table (≈ +113 B) against the removed tier
branches and fixed fills; the `LEX_NEXT_TOKEN` fix below (+8 B). EXROM −26 B: the
`TOO MANY VARIABLES` message and its selection.

### Two pre-existing defects found by the 40-array production run (fixed)

Sizing the tables with a 40-array program exposed wrong array reads. Root cause (a
write-watch on the corrupted bytecode led straight to it): **`LEX_NEXT_TOKEN` clobbers
`DE` on every call** (the refill gate loads `CHUNK_MARGIN` into it) **and `BC` whenever it
refills the chunk buffer**, but `COMPILE_ARR_READ_COMMON` keeps the array INDEX in B and
the declared COUNT in DE across the call that consumes the closing `)`. Consequences, in
the working tree before this work:

1. **Every array READ emitted count = 128** instead of the declared size. The VM validates
   indices against that operand, so out-of-range reads of indices up to 127 were not
   caught.
2. When the `)` sat on a chunk-refill boundary, the emitted **index was 0**: `R7 = A7(2)`
   silently returned `A1(2)`.

Fix: `LEX_NEXT_TOKEN` is now a wrapper that preserves BC and DE around the core
(`LEX_NEXT_TOKEN_CORE`), restoring the contract callers assumed. Evidence: the new flat
test `test_v2_chunk_array_reads` (16 arrays then 16 reads, each its own stored record so
the reads walk across every alignment of the chunk window, plus an out-of-range read that
must raise error 10) fails without the wrapper and passes with it; the 40+20-array
production program went from `s = 670` (wrong) to `s = 820`, `n = 6` (correct); in the
production ROM `DIM a(4)` / `x = a(10)` and `a(10) = 1` now both raise array-bounds error
10, including after 24 preceding source lines.

### Tests and evidence (V2 standalone **36/36**)

* Every test that read `SYMTAB_BASE + n`, `STRTAB_BASE + n` or the array pointer tables
  by absolute address (≈ 150 sites in 25 files) was converted to the run-table pointers
  through `rom/test_v2_symmacros.inc` (`TSYM_ADDR/LD16/LD8`, `TSTR_ADDR/LD8`), which
  preserve the registers the originals preserved. `MEM_FILL_ZERO` moved into the shared
  harness tail because `VM_INIT` now zeroes the tables in every build (before, only
  production did, and the tests silently relied on zeroed cold RAM).
* New `test_v2_run_tables`: 100 numeric variables, 40 strings, 24 arrays, 12 string
  arrays, float and string-temp expressions in one program; every value read back through
  the real `VM_SYM_ADDR`; the carve ordering and bounds checked; and the refusal path
  (error 64, VM halted) when the symbol table is made to fill the pool. Negative
  controls: a wrong STRTAB slot size and a missing overflow check both fail it. (It uses
  the calculator-enabled harness group; in the plain harness the float division
  recursed forever because that EXROM has no calculator.)
* Production ROM (headless): 202 numeric variables, 61 string variables, 253 numeric
  accepted and the 254th rejected with `TOO MANY VARIABLES`, 40 arrays + 20 string arrays
  with correct sums and concatenations, and every earlier production check (hazard,
  recursion guard, identifiers, labels, FOR/EXIT, capacity errors) still green.

## State after P3

| Limit | Original | Now |
|---|---:|---|
| Numeric / string scalars | 32 / 8 | **253 / 253** (operand limit) |
| Numeric / string arrays | 16 / 8 | **255 / 255** |
| Identifier significance | 8 (silent merge) | 31, explicit error beyond |
| Labels + PROCs + DEF FNs | 8 | memory-limited |
| Fixups, EXIT FOR, compile FOR nesting | 8, 4, 4 | none / memory-limited |
| FOR runtime depth | 15 unchecked | 15, guarded (**P4**) |
| PROC/CALL, DEF FN depth | 12 | 12 (**P4**) |
| HOME free | 173 B | **624 B** (+451) |

## P4 — unified typed control stack (done)

**Change.** The three fixed run-time stacks (12-deep call stack at `$B688`, 12-deep
parameter-save stack at `$B730`, 15-frame FOR stack at `$B5C1` plus the P0 guard) are gone.
All three are frames on one memory-limited stack, `VM_CSP` (`$B819`), growing DOWN from
`VARS_START` (the bottom of the carved run tables) toward `ARRAYS_END`; arrays grow UP and
their ceiling is now `VM_CSP` (`OP_DIM` numeric and string). `FREE()` returns
`VM_CSP − ARRAYS_END`, the real remaining gap.

| Frame | Layout | Size |
|---|---|---:|
| FOR | `[1][enclosing limit:2][enclosing step:2]` | 5 B |
| CALL | `[2][return address:2]` | 3 B |
| PARAM | `[3][SYMTAB rec:3][FLOATTAB rec:5]` | 9 B |

* `VM_CS_ALLOC` is the single bounds check (frame must not cross `ARRAYS_END`); failure is
  the existing clean error 6 (STACK OVERFLOW) with the hardware stack balanced. The Z80
  hardware stack is separate and untouched (compiler nesting is bounded by
  `COMPILE_STACK_CHECK`).
* `VM_CALL_POP` / `VM_PARAM_SAVE_POP` skip FOR frames above their owner (`VM_CS_UNWIND`),
  so a `GOTO` out of a loop heals at the procedure's exit. `OP_FOR_POP` requires a FOR
  frame on top (error 7 otherwise).
* Semantics preserved: FOR variables and limits remain NON-recursion-local (only the
  enclosing loop's limit/step are saved), exactly as before.

**Measured (production build).** HOME free 624 → **661 B** (+37), EXROM free **1,396 B**
(unchanged; vm_core is in HOME). Recursion depth 12 → memory-limited (≈ 650 PROC levels
with no other data); FOR depth 15 → memory-limited.

**Tests.** `make check` clean. V2 standalone now 37 entries: new `control_stack`
(150-deep parameter recursion R=11325; three GOTO-out-of-FOR leaks healed; stack into
arrays → error 6 with the array's last element intact; arrays into stack → DIM 3300
succeeds alone but is refused with error 64 from 200 levels deep). `for_recursion_guard`
reworked (41 levels × 2 loops passes, unbounded recursion → clean error 6, VM_IP intact);
`recursion_depth12`, `proc_recursion`, `for_nested` now check `VM_CSP == VARS_START`.
Negative control: making `VM_CS_UNWIND` not skip FOR frames fails `control_stack`.

## State after P4

| Limit | Original | Now |
|---|---:|---|
| FOR runtime depth | 15 unchecked | **memory-limited, clean error 6** |
| PROC/CALL, DEF FN depth | 12 | **memory-limited, clean error 6** |

## P4 production-ROM validation checkpoint (`tools/v2_production_checks.py`)

Real HOME+EXROM image (`build/ts2068rom_zesarux.bin`), headless, program written to the line
store and run through the real `V2_RUN_STORED`. Re-run after every P5 step.

| Case | Result |
|---|---|
| PROC recursion 150 deep (old limit 12) | R = 11325, no error |
| 3-level nested FOR/NEXT | S = 300 |
| GOTO out of a FOR inside a PROC, 3 calls | R = 3, no error |
| two 31-char names differing in the last char | 5, 9, sum 14 |
| 32-char name | compile error 61 (NAME TOO LONG) |
| 20 PROCs + 20 DEF FNs + 20 forward labels | S = 210, no error |
| unbounded recursion after `DIM A(2000)` | runtime error 6, `A(1999)` intact |
| `DIM A(3300)` alone / from 200 frames deep | ok / error 64 (OUT OF MEMORY) |
| 253 / 254 numeric variables | ok / compile error 1 (TOO MANY VARIABLES) |
| ordinary FOR program | S = 6 |

12/12 pass. Measurements at this checkpoint: HOME free 661 B, EXROM free 1,396 B,
zone 302 B (`$A327–$A454`), source/array pool `$8457–$A327`.

## P5.1 — dead V1 system variables reclaimed

113 `DEFS` declarations in `include/sysvars.inc` (V1 editor/checker/FOR/GOSUB scratch with no
reference in any V2 production file, package or kernel module) are now wrapped in
`IFNDEF V2_COMPACT_SYSVARS`. The flag is defined by the V2 production roots
(`v2_home`, `v2_exrom`, `v2_package_*`, `ext_v2_shapes_module`), the V2 harness
(`test_v2_harness_home_head.inc`, `test_v2_harness_exrom`) and every `rom/test_v2_*.asm`
that includes sysvars directly, so they all share one compact layout; the legacy V1 builds
(`basic/basic.asm`, `exrom_build`, V1 smoke/component ROMs) keep the full layout and
assemble unchanged. Layout is assembler-computed, so every live variable shifted
consistently. Region scoped to `$8000–$8456` only; the upper-RAM leftovers (`$F100` label
table etc., packed layout with assertions) are deliberately untouched.

**Measured:** `PROG_AREA_START` `$8457` → `$825A`: **+509 B** of source/array pool (7,888 →
8,397 B). HOME/EXROM free unchanged by this step (661 / 1,396 B). Validation:
`make check` clean, headless `make test` green — smoke ROMs, V2 standalone 37/37,
production checks 12/12 (production checks now read `PROG_AREA_START` from the symbol file).

## P5.2 — FILL stack reduced (4 KB → 1 KB) by replacing the fill algorithm

The old FILL (shapes package) was a per-pixel 4-neighbour fill that needed up to 4,096 B of
stack, measured at 2,112 B for a plain 80×50 rectangle, and it silently lost part of a
region whenever the stack filled (a 1-pixel-tooth comb came out wrong: 32,516 pixels
differed from an independent flood fill). Simply shrinking that stack would have cut FILL's
capability, so the algorithm was replaced instead: a **scanline span fill** that paints a
horizontal run and pushes one seed per run on the rows above and below
(`SHAPES_FILLABLE`, `SHAPES_FILL_ROW`, `SHAPES_VISITED_ADDR` in
`rom/ext_v2_shapes_module.asm`; the visited bitmap, target/attr semantics and pixel writes are
unchanged; package 762 → 795 B, limit 1,024 B).

`tools/v2_fill_check.py` (in `make test`) runs the real package on the production ROM with
EXROM paged out, compares each result pixel-for-pixel against an independent Python
4-connected flood fill and reports the stack high-water mark:

| Scenario | Old: diff px / stack | New: diff px / stack |
|---|---|---|
| rectangle | 0 / 2,112 B | 0 / 4 B |
| circle r50 | 0 / 4,096 B (full) | 0 / 4 B |
| whole screen | 0 / 4,096 B (full) | 0 / 4 B |
| coarse comb | **32,516 wrong** / 4,096 B | 0 / 184 B |
| 1-px-corridor comb | (not run on old) | 0 / 384 B |
| ring, border, lit-seed, serpentine, slats | 0 | 0 (≤ 8 B) |

V2 builds (`V2_COMPACT_SYSVARS`) now reserve 1,024 B (`GFX_FILL_STACK_END = $DC00`, ≥ 2.6×
the worst measured case); legacy V1 builds keep 4,096 B. FILL's transient footprint is now
`$C000–$DBFF`, entirely inside the hidden chunk, so **`$E000–$E7FF` (2,048 B of always-visible
RAM) is free in V2 builds.** Validation: `make check`, headless `make test` (smoke 9/9, V2
standalone 37/37, production 12/12, FILL 10/10).

## P5.3 — sprite buffers to hidden RAM: not done (evaluated, infeasible without loss)

The sprite image/background buffers are 2,304 B (`$E800–$F0FF`) and are live between
statements. Hidden chunk-6 RAM (`$C000–$DFFF`, 8,192 B) is the only space that moving them
would use, but FILL's transient working set (6,144 B visited bitmap + stack, `$C000–$DBFF`)
overwrites it, so persistent sprite data there would be destroyed by any FILL, and 2,304 +
7,168 > 8,192 so the two cannot coexist. Also, the sprite driver would need EXROM-out access on
every SHOW/MOVE. Moving them gains nothing in V2 anyway: the freed always-visible space is
not needed for sprites. Left in place; the freed `$E000–$E7FF` is used by P5.4 instead.

## P5.4 — second array segment (done) and P5.5 — `FREE(1)` (done)

**Design.** The array pointer tables already hold absolute descriptor addresses, so element
access, bounds checks, `DIMN`, array SAVE (descriptor-based) need no change. Only allocation
changed: `VM_ARENA_FIT` (called by `ARENA_ALLOC_NUMERIC` and `ARENA_ALLOC_STRING`) tries the
main pool first (`ARRAYS_END + need < VM_CSP`); if that fails it tries segment 2
(`ARR2_END + need < $E800`) and, if it fits, exchanges `ARRAYS_END` and `ARR2_END` so the
unchanged allocator code writes there; `VM_ARENA_DONE` exchanges them back. If neither fits,
the existing error 64 (OUT OF MEMORY). Segment 2 is `$E000–$E7FF`: always-visible RAM, no
overlap with FILL (ends `$DC00`), the sprite buffers (`$E800`), the unified stack or the
main pool. `ASSERT`s in `include/v2_layout.inc` keep it that way. `VM_INIT` and
`V2_CLEAR_ARRAYS` empty it (`ARR2_END = $E000`); programs run twice start clean.

**Semantics preserved.** An array that fit in the main pool before is placed there exactly as
before (verified: pointer in the main pool, `ARR2_END` untouched). Segment 2 is only ever
used where the old behaviour was an error. Per-array SAVE/LOAD: SAVE serialises from the
descriptor wherever it lives; LOAD receives into the main pool, so `V2_LOAD_ARRAY` now sets
`VM_CSP = VARS_START` first (outside a RUN `VM_CSP` is stale, and 0 after a cold boot) and
caps the received length one byte lower so the allocator can never relocate a received
array to segment 2 away from its data.

**`FREE(1)`.** `FREE(n)` is the one built-in with an optional argument: `BUILTIN_FN_FIND`
still matches the 0-argument `FREE` row; `.fn_have_lparen` switches to fn_index 29 when the
call has an argument. `FREE(1)` = `$E800 − ARR2_END` (2,048 when nothing is there);
`FREE(0)`/`FREE()` = main pool. Any other argument behaves like `FREE()`.

**Measured.** HOME free 661 → **546 B** (−115: allocator fit/swap 56, `FREE(n)` 59);
EXROM free 1,396 → **1,385 B** (−11, array LOAD/clear glue). Usable array capacity
+2,048 B (+24% of the 8,397 B pool, which itself grew by 509 B in P5.1).

**Tests (production ROM, `tools/v2_production_checks.py`).** `seg2-numeric` (`DIM a(3600)`
fills the main pool; `DIM b(900)` lands at `$E000`; values read back across both segments;
`ARR2_END = $E70B`; `ARRAYS_END < VM_CSP` after the swap-back), `seg2-main-first` (a small array
stays in the main pool), `seg2-string` (`DIM s$(10,100)` in segment 2), `seg2-exhausted`
(third array → error 64), `seg2-reset-on-rerun` (same program run twice, second run clean),
`free-1`, `free-expr-arg`. Negative control: removing the swap-back fails five cases.

**Known pre-existing gap (not caused by this work).** `DECOMP_BUILTIN_FN_TABLE`
(`rom/exrom_v2_decompiler.asm`) stops at fn_index 21 (`SIN`); `FREE`, `COS`, `TAN`, `MID` and
now `FREE(n)` have no decompiler names. The V2 editor stores and LISTs source text, so this
only affects the decompiler component, but it should be fixed in the pre-R11 gap analysis.

# R10.7 final summary (P0–P5)

| Resource | Start of R10.7 | End |
|---|---:|---:|
| Source + array pool (`PROG_AREA_START`→`V2_SOURCE_END`) | 7,888 B shared with fixed tables | **8,397 B**, tables carved exact-size from it |
| HOME free / EXROM free | 173 B / ~1,396 B | **546 B / 1,385 B** |
| Array space | pool only | pool + **2,048 B segment 2** (`FREE(1)`) |
| Numeric / string scalars | 32 / 8 | 253 / 253 |
| Numeric / string arrays | 16 / 8 | 255 / 255 |
| Identifier significance | 8 (silent merge) | 31, explicit error 61 beyond |
| Labels+PROCs+DEF FNs, fixups, EXIT FOR, FOR compile nesting | 8, 8, 4, 4 | memory-limited |
| PROC/CALL, DEF FN, FOR runtime depth | 12 / 12 / 15 (unchecked) | memory-limited, clean error 6 |
| FILL stack | 4,096 B, lossy | 1,024 B reserved, 4–384 B used, exact |
| Dead V1 sysvars | 509 B held | reclaimed |

**Remaining limits:** 255 symbols per kind (1-byte operand; `TOO MANY VARIABLES`); 31-char
strings and identifiers; compile nesting `NESTING TOO DEEP`; bytecode 4,011 B; segment 2 is
2,048 B and holds whole arrays only; FOR variables stay non-recursion-local (unchanged
semantics); the Z80 hardware stack is separate (compile recursion guarded). Sprite buffers
left in place (P5.3, infeasible without breaking FILL). Upper-RAM V1 leftovers (`$F100`
region, ~450 B) untouched. `DECOMP_BUILTIN_FN_TABLE` gap noted above.

**Evidence:** `make check` clean; headless `make test` — smoke 9/9, V2 standalone 37/37,
production-ROM checks 19/19 (`tools/v2_production_checks.py`), FILL 10/10
(`tools/v2_fill_check.py`). Not run: `make test-legacy` (Fuse), by instruction.

## Built-in function decompiler audit and correction

**Audit.** The compiler `BUILTIN_FN_TABLE`, the VM `BUILTIN_FN_JUMP_TABLE` and the decompiler
`DECOMP_BUILTIN_FN_TABLE` all use the same fn_index 0–29, in agreement: compiler and VM each
have 30 entries; the decompiler had 25 (fn_index 0–24). So this was an **incomplete name
table**, not an index mismatch and not a structural limitation: `FREE` (25), `COS` (26), `TAN`
(27), `MID$` (28) and `FREE(n)` (29) were simply never added. No other function was missing or
mis-mapped (names, `$` suffix, argument counts and string-argument bits of the other 25 rows
agree with the compiler). The generic `.op_call_fn` handler already supports up to four
arguments, so no code change was needed.

**Not shared.** The decompiler is test-only (the production ROM does not contain it), so a
shared definition would have added production bytes or cross-bank plumbing to save
test-image bytes; instead the tables stay separate and a static check keeps them in step.

**Change.** Five rows plus four name strings in `rom/exrom_v2_decompiler.asm` (39 bytes in the
test-harness EXROM). **Production ROM: HOME 0 B, EXROM 0 B** — HOME stays 0x3DDE used / **546 B
free**, EXROM 0xDA97 / **1,385 B free**.

**Tests.**
* `tools/check_builtin_tables.py` (in `make check`): fails if the three tables disagree on
  fn_index, name (including the `$` suffix), argument count or argument-type bits.
* `rom/test_v2_builtin_roundtrip.asm` (V2 standalone, now 38/38): for programs covering all 30
  built-ins (numeric, string, string-variable arguments, float, RND, USR, FREE(), FREE(1),
  FREE(0), and nested calls such as `LEFT$(UPPER$("hello"),3)` and `FREE(MOD(2,3)-1)`) it
  compiles, decompiles, recompiles the decompiled text, and requires **identical bytecode**;
  deterministic programs are also run both ways and the complete run-time tables compared.
  `FREE()` / `FREE(1)` decompile to exactly `V0 = FREE()` / `V1 = FREE(1)`. Negative controls:
  a wrong argument count for `FREE(n)`, a swapped `COS`/`TAN` name and a wrong `MID$` string
  bit each fail the test (the last needed the string-variable program), and the static check
  catches an argument-count drift.

**Limits found (pre-existing, unchanged).** The decompiler rebuilds each expression in a
31-byte fragment; longer expressions give clean DECOMP error 4. The float functions are
compared at bytecode level only, because the calculator and decompiler do not fit together in
the harness EXROM. `FREE()` depends on the compile symbol-table size, so equal-behaviour
comparison needs same-length variable names (the decompiler writes `V0…` / `S0$…`).
The harness constant `TEST_V2_SOURCE_END = $A33F` in `rom/test_v2_harness_home_head.inc` is stale
(real value `$A327`); it only seeds `VARS_START` and all tests pass, so it was left alone.

## Harness correction and known gaps carried to R10.8

* `TEST_V2_SOURCE_END` in `rom/test_v2_harness_home_head.inc` was a stale hardcoded `$A33F`;
  it is now `EQU V2_SOURCE_END`, derived from the canonical `include/v2_layout.inc` value
  (`$A327`). The harness now seeds `VARS_START` exactly as production does; all tests still pass.

**Known gaps for R10.8 (recorded, deliberately not addressed in R10.7):**
1. **Decompiler fragment limit.** Each reconstructed expression is held in a 31-byte fragment
   (`DECOMP_FRAG_TEXT_MAX = 31`); a longer expression gives clean DECOMP error 4. The decompiler
   is test-only, so no user-visible impact, but round-trip tests must keep nested expressions
   under 31 characters.
2. **Float-function behavioural round trip.** The calculator and decompiler cannot both fit in
   the standalone harness EXROM, so `SQR PI RAD DEG SIN COS TAN` are verified by identical
   bytecode after decompile/recompile, not by running both versions. (Their runtime behaviour
   is covered separately by `r10_numeric` and the production checks.)
3. **`FREE()` equivalence needs same-length names** because it depends on the symbol-table size
   (the decompiler writes `V0…`/`S0$…`).
4. Upper-RAM V1 leftovers (`$F100` region, about 450 B) remain unreclaimed; sprite buffers
   remain at `$E800` (P5.3: infeasible alongside FILL).

## R10.7 closure

Final measured state: HOME 546 B free (0x3DDE used), EXROM 1,385 B free (0xDA97 used); source
and array pool 8,397 B plus 2,048 B array segment 2. Validation: `make check` clean;
headless `make test` — smoke 9/9, V2 standalone 38/38, production-ROM checks 19/19, FILL 10/10;
V1 Fuse tests (`make test-legacy`) intentionally not run.

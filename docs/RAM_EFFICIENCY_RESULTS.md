# V2 RAM efficiency and memory management: results

Branch `v2-development`, 2026-10-12. Every number here was measured on the production image (HOME +
EXROM, ZEsarUX through `tools/qual/qharness.py`) or read from the assembler's symbol tables and
listings. Before = `v2.0.1-emu.1` ROM (HOME `3f13ec2c…`, EXROM `24b1ebb0…`, reproduced from the tag
and from `a20ad12`); after = this change.

## 1. Result in one table

| | Before | After | Change |
|---|---:|---:|---:|
| Main pool (`PROG_AREA_START`..pool top) | 8397 B `$825A-$A326` | **9211 B** `$825A-$A654` | **+814 (+9.7%)** |
| `FREE()`, one-line program `PRINT FREE()` | 8153 | **8967** | +814 |
| Largest program of a representative unit (PROC + FOR + string + IF, 11 lines) | 34 units, 5784 B text | **38 units, 6472 B** | +4 units (+12%) |
| Lines of `PRINT n` that still run | 815 | **896** | +81 |
| Largest main-pool array `DIM a(n)` | 4036 | **4443** | +407 elements |
| Largest main-pool `DIM a$(n,31)` | 260 | **286** | +26 |
| One-character string variables in an empty program | 155 | **170** | +15 |
| Recursion depth, one-parameter `PROC` | 671 | **739** | +68 |
| Bytecode area | 4011 B | 4011 B `$A655-$B5FF` | unchanged |
| Segment 2 (`FREE(1)`) | 2048 B | 2048 B | unchanged |
| HOME ROM free | 19 B | **25 B** | +6 |
| EXROM free | 26 B | 26 B | 0 |
| Speed (9 `qbench` programs, T-states) | | | within ±0.01% (interrupt-phase noise) |
| Bytecode emitted for the 667 corpus programs | | | **byte-identical** (`qbytecode.py`) |

No package ABI change (2.0 stays; every pinned cell and constant is where it was), no tape-format
change, no new code path. Programs, arrays and packages saved on the release load unchanged; `SAVE … ALL`
tapes were already tied to the exact ROM by the identity CRC and remain so.

## 2. Corrected RAM map (after)

| Range | Bytes | Contents | Lifetime / banking |
|---|---:|---|---|
| `$4000-$5AFF` | 6912 | display file + attributes | hardware |
| `$5B00-$5FFF` | 1280 | **unused by V2** (user machine code) | |
| `$6000-$77FF` | 6144 | second display file (MODE 1); free otherwise | |
| `$7800-$7FFF` | 2048 | **unused by V2** | |
| `$8000-$8259` | 602 | system variables (pinned package cells `$8106-$81B5`, `$8232-$8252`) | permanent |
| `$825A-$A654` | **9211** | **main pool**: text ↑, names, 80-byte session gap, arrays ↑ … control stack ↓, run-time tables (top) | program / run |
| `$A655-$B5FF` | 4011 | bytecode (rebuilt every RUN; immediate statements after the session's code) | run |
| `$B600-$B6ED` | 238 | VM registers, VM value stack `$B604-$B67F`, string-array scratch (pinned `VM_ERROR_CODE`/`VM_HALTED` `$B683-4`) | run |
| `$B792-$B7A7`, `$B800-$B84B` | 98 | VM scratch; symbol-table/run-table/session cells (`$B800-$B830` is the `SAVE … ALL` cell image) | run / session |
| `$B850-$B97D` | 302 | **compile zone**: chunk buffer (264), chunk state, `LEX_LINE`, identifier buffer (32) | compile (+ `LEX_LINE` for error reports) |
| `$B9E9-$B9EC`, `$BA00-$BA5D`, `$BDD0-$BDE0` | 115 | compiler cells | compile |
| `$BE70-$BEEF` | 128 | shell/editor cells, package call arguments (pinned `$BED8-$BEED`) | permanent |
| `$BF00-$BFBA` | 187 | package registry (168), package scratch `$BFB0-$BFBA` | permanent |
| **dead** in `$B600-$BFFF` | **1407** | `$B6EE-$B791`, `$B7A8-$B7FF`, `$B84C-$B84F`, `$B97E-$B9E8`, `$B9ED-$B9FF`, `$BA5E-$BDCF` (the V1 decompiler workspace; no decompiler ships), `$BDE1-$BE6F` | never touched |
| `$C000-$DFFF` | 8192 | RAM under the EXROM: visible only during package calls; SHAPES' FILL bitmap + span stack `$C000-$DBFF` | package call |
| `$E000-$E7FF` | 2048 | segment 2: Array Store + arrays that do not fit the pool | session |
| `$E800-$F0FF` | 2304 | sprite images + backgrounds (only the SPRITE package touches them) | reserved always |
| `$F100-$F17F` | 128 | **dead** (V1 label table) | |
| `$F180-$F227` | 168 | UDGs | permanent |
| `$F228-$F327` | 256 | edit-line / LOAD-name buffer, detokeniser buffer | editor |
| `$F328-$F3AE` | 135 | **dead** (V1 string pool, DEF FN cells) | |
| `$F3AF-$F3FF` | 81 | misc. live cells (`EXTENSION_MAGIC`, `GFX_LINE_*`, slot count) + V1 leftovers | |
| `$F400-$F7FF` | 1024 | package window (one package at a time) | package |
| `$F800-$F9FF` | 512 | **unused**: below the compile-stack floor `$FA00` | |
| `$FA00-$FEFF` | 1280 | machine stack (compile recursion is guarded at `$FA00`) | permanent |
| `$FF00-$FFFF` | 256 | above the initial SP; unused by the ROM (test harnesses park a return address at `$FF00`) | |

How "dead" and "unused" were established:

* **Static census**: every RAM symbol referenced by an emitted (not conditionally skipped) code line of
  the HOME, EXROM and all six package listings, closed over `EQU` definitions. The guard
  `tools/check_ram_layout.py` (now in `make check`) keeps that census for HOME + EXROM.
* **Canary over the qualification corpus** (`tools/qual/qcanary.py`, new): before each of the 667
  corpus cases every candidate span is filled with `$A5`; after the case (packages installed, program
  compiled and run, INPUT keys delivered) nothing in them had changed. Before the change the probe covered
  2,138 bytes (`$B400-$B4DF`, `$B4EA-$B5FF`, `$B6E4-$B791`, `$B7A8-$B7FF`, `$B84C-$B9E8`, `$B9ED-$B9FF`,
  `$BA5E-$BD9E`, `$BDA1-$BDCF`, `$BDE1-$BE6F`): 0 writes. After the change it covers the remaining dead
  spans of the table above (1,670 bytes incl. `$F100-$F17F` and `$F328-$F3AE`): again 0 writes in 667 cases.
* **Stack**: the deepest machine-stack byte written in the corpus was `$FDE8`, **280 bytes** below the
  initial `$FF00` (the compile-stack guard allows 1280).

### Corrections to the existing documentation

| Where | Was | Is |
|---|---|---|
| Manual Appendix E | system variables `$8000-$8454` (1109), pool `$8456-$A326` | `$8000-$8259` (602), pool `$825A-…` (the R10.7 sysvar reclaim was never reflected) |
| Manual Appendix E | `$F100-$F17F` "label table" | unused by this release (V1 leftover) |
| Manual Appendix D, `04_concepts.md` | "749 lines of `PRINT n` is the most that runs" | **815** on the release (816: error 64), not reproducible as 749; now 896 |
| `include/v2_layout.inc` | `V2_SOURCE_END … ; = $A33F`, identifier buffer "8B" | the zone was 302 bytes (`$A327`), the buffer 32 bytes |
| `include/sysvars.inc` | `PROG_AREA_START` "current value $8455"; sprite buffers "visible to the EXROM-resident sprite driver" | `$825A`; in V2 only the SPRITE package (run with EXROM paged out) uses them |
| `docs/V2_ROM_RAM_BUDGET.md` | release ROM free 54 / 25 | the maintenance release is 19 / 26 (`V2_MAINT_RELEASE_STATUS.md`); a current-layout note was added |

The manual's and the language reference's pool figures (`FREE()` 8153→8967, the `mem.*` example
outputs, recursion 671→739, strings 155→170, code addresses) were re-measured, not shifted.

## 3. What was implemented

**3.1 The compile zone left the pool's way.** The 302-byte zone (chunk buffer, its state, `LEX_LINE`,
identifier buffer) sat between the pool and the bytecode. Its only remaining users are the compiler (it
is compile-only scratch since the run-only overflow tiers that once overlaid it were removed in R10.7 P3)
and the error-line lookup (`LEX_LINE`). It now lives in dead fixed-area space at `$B850`; the pool ends at
the bytecode base (`V2_SOURCE_END = V2_CODE_BASE`). Every user addresses it by symbol.

**3.2 `$B400-$B5FF` joined the bytecode area.** Its only live cells were the ten bytes of string-array
scratch at `$B4E0` (moved to `$B6E4`, same internal offsets); `V2_FLOATTAB_BASE` (unused) was removed.
`V2_CODE_LIMIT` `$B400`→`$B600`, and the bytecode area keeps its 4011 bytes by moving its base up
(`V2_CODE_BASE` `$A455`→`$A655`), which is where the pool's 512 bytes come from. Measured: code size is
not the binding limit for real programs (median code/text ratio 0.48 over the corpus; the 38-unit program
uses 2707 of 4011), so the pool, not the code area, gets the space.

**3.3 Dead decompiler store.** `COMPILE_PROGRAM` stored the final `EMIT_PTR` into the decompiler's
`DECOMP_END_ADDR` on every RUN; no decompiler is in the release. Now `IFNDEF V2_PRODUCTION` (the standalone
decompiler tests keep it): HOME **+6 bytes**.

Safety invariants, and how each is enforced:

| Invariant | Enforced by |
|---|---|
| The pool ends exactly at the bytecode base; the bytecode area is `V2_CODE_SIZE` (4011) | `check_ram_layout.py` (`make check`); `zone-outside-pool` production case |
| No live HOME/EXROM cell lies inside the pool + bytecode range | `check_ram_layout.py` (negative control: string-array cell put back at `$B4E0` → reported) |
| No live cell lies inside the compile zone | `check_ram_layout.py` (control: an EXROM shell cell moved to `$B860` → reported); `ASSERT` zone end ≤ `FOR_FRAME_ADDR_TMP` and session cells < zone (control: build stops) |
| No pinned package cell or package scratch overlaps the pool, bytecode or zone | `check_ram_layout.py`; the existing `PKG_PIN` `ASSERT`s |
| The `SAVE … ALL` span (run tables + code, `SESS_CODE_END - RT_SYMTAB_PTR`) stays contiguous and ends below `V2_CODE_LIMIT` | symbolic in `SA_SIZES`/`SA_BUILD`; `make qual` lifecycle + `v2_saveall_checks` |
| Run-time tables and the compile stack (both start at the pool top) never touch the code | corpus bytecode identical; the full suites; `pool-814-program`, `pool-top-array` |

New regression cases (`tools/v2_production_checks.py`, all fail on the release build — negative control):
`pool-814-program` (38 units run; the release stops with error 64), `pool-top-array` (`DIM a(4443)` in the
main pool, last element read back), `zone-outside-pool`. Two existing cases encoded the old pool size and
were updated by exactly the measured amount, not loosened: `free-1` (813 → 1627 = 813 + 814, bounds moved
by 814) and `seg2-string` (filler `a(3600)` → `a(4000)` so that the string array still overflows to
segment 2); likewise `sa-no-room` in `v2_saveall_checks.py` (§4).

## 4. Test results

All on the emulator (ZEsarUX through ts2068-debug / qharness), 2026-10-12, on the final tree.

| Suite | Result | Release record (`V2_MAINT_RELEASE_STATUS.md`) |
|---|---|---|
| `make check` (incl. new `check_ram_layout.py`, package ABI 2.0: 16 slots, 34 pins, 6 packages) | pass | pass |
| `make test`: smoke ROMs / V2 standalone | 9/9, 40/40 | 9/9, 40/40 |
| production checks / FILL check | 22 cases (19 + 3 new), 0 failures / 0 failures | 0 / 0 |
| production regression / Array Store / known defects / SAVE ALL | 114 / 100 / 15 / 13 PASS | 114 / 100 / 15 / 13 |
| `make qual` corpus | 663 PASS, 2 XFAIL (Q-24, Q-26), 2 N/A, 0 FAIL | identical |
| session lifecycle | 23/23 | 23/23 |
| `make qual-maint`: AY BEEP / cbeep / interrupts off / cbeep tape | 59/59, 27/27, 14/14, 3/3 | identical |
| `make doc-examples` (manual, with the re-measured `FREE()` outputs) | 325/325 | 325/325 |
| bytecode identity, 667 corpus programs, release vs new (`qbytecode.py`) | 667 identical | — |
| `qbench.py`, 9 programs | ±0.01% | — |
| `qcanary.py`, 667 cases, dead spans before and after | 0 writes; stack high-water 280 B | — |
| negative controls | 3 new production cases fail on the release; 3 layout faults caught by `make check` | — |
| release images | `v2.0.1-emu.1` rebuilt from its tag: HOME `3f13ec2c…`, EXROM `24b1ebb0…` = recorded; tags `v2.0.0-emu.1`, `v2.0.1-emu.1` unmoved | — |

Not run: `make test-legacy` (V1, Fuse window; untouched code paths). A first full run surfaced the three
tests that encoded the old sizes (`free-1`, `seg2-string`, `sa-no-room`: `a(600)` no longer fills the larger
pool, so its "too big" session was enlarged to `a(1000)`); each was updated to
keep testing the same condition, and the final run above is clean.

## 5. Remaining opportunities (not done: each needs a package-ABI major version)

| Opportunity | Gain | Cost / risk |
|---|---:|---|
| **Pack the fixed area**: move all live cells of `$B600-$BEFF` (≈ 880 B incl. the zone) into one block and let the bytecode base rise | pool **up to +1,407** | moves pinned `VM_ERROR_CODE`/`VM_HALTED` → ABI 3.0 (every package rebuilt and re-stamped); 0 ROM |
| **Sprite buffers into chunk 6** (`$C000-$C8FF`, seen only inside package calls, as FILL already is) and end segment 2 at `$F180` | segment 2 **2048 → 4480** | `SPRITE_SLOT_*_BUF` constants change → ABI 3.0; the package's install must clear `SPRITE_SLOT_DEFINED/SHOWN` (sprites no longer survive loading another package, ~10 package bytes); PACKAGE_ABI §9 rule 5 needs the "resident package owns chunk 6" wording. The R10.7 P5.3 rejection ("FILL would destroy them") does not hold: only one package is ever resident, so SPRITE and SHAPES' FILL never coexist |
| **System variables to `$5B00`, pool from `$7800`** (the 602-byte block fits the unused `$5B00-$5FFF`) | pool **+≈2,650**, contiguous | pinned sysvar cells move → ABI 3.0; takes `$7800-$7FFF` and most of `$5B00-$5FFF`, which the manual promises to users for machine code (3.3 KB → ≈0.7 KB); the sysvars would then sit in lower RAM (speed to be measured) |
| **Bytecode compiled into the pool** (one arena instead of a fixed 4011-byte code area) | ≈ +1–2 KB for typical programs (code is ≈0.48× the text; the 38-unit program uses 2707 of 4011) | no ABI change, but ROM: `VM_CODE_BASE` becomes a variable (4 VM sites, compiler, `SAVE … ALL`); est. tens of bytes against HOME's 25 free — needs a measured study and a shrink to pay for it |
| Variable-length strings (every string name holds a fixed 32-byte slot) | large for string-heavy programs | needs a heap + garbage collection: hundreds of ROM bytes and slower string operations — not recommended |
| Chunk-7 tidy: `$F328-$F3AE` (135), `$F800-$F9FF` (512), `$FF00-$FFFF` (256) | ≈ 900, fragmented | only useful together with moving the package window (ABI constant) — low value |
| Raising `FREE()` further inside the pool | — | the pool has no waste left: arrays bump-allocate up, the control stack grows down, run tables are carved exactly; the session gap and the 4+4 spare temporaries are measured requirements (Q-02, owner decision 2) |

The first two ABI-3.0 items are pure `EQU` changes for HOME/EXROM (0 ROM bytes) and could ship together in one
major bump: pool ≈ 10.6 KB and segment 2 4.4 KB, ≈ +3.8 KB of BASIC data RAM over today. That is an owner
decision (it re-issues every package tape), so it is left as a recommendation.

## 6. Does V2 need a more capable memory manager?

**No.** The evidence:

* The pool already behaves as a two-ended arena with exact-size carving: text and arrays grow up, the
  control stack grows down, run-time tables are sized from the compiler's counts, temporaries are
  reused. Every collision is checked (`OUT OF MEMORY` 64 at DIM / RUN / compile, error 6 when the control
  stack meets the arrays, `NESTING TOO DEEP` when compile recursion reaches `$FA00`) and covered by tests.
* All remaining waste is **static layout** (dead V1/decompiler cells, a fixed sprite reservation), which
  an `EQU` change removes at zero ROM cost; an allocator would not recover a byte of it.
* Lifetimes are already disjoint by construction: compile vs run (zone), one package at a time (window,
  chunk 6), FILL only inside a package call.
* ROM: HOME has 25 free bytes. The R10.7 spike measured the smallest useful manager at 37–64 bytes, and
  every allocation through it would cost run-time on the VM's hot paths.
* Stack: measured high-water 280 bytes against a 1,280-byte guarded reserve; no runtime recursion uses the
  machine stack (procedures and loops use the pool's control stack). No collision detection is missing;
  `qcanary.py` gives the high-water figure on demand without ROM cost.

A manager would only pay if V2 gained several optional clients that need the same RAM at different times
(e.g. multiple resident packages). Until then: keep the static lifetime map, guard it in `make check`,
and take the ABI-3.0 layout step when packages are next re-issued.

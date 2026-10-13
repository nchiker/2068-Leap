# R10.9 Phase 2B — HOME-minimal Array Store architecture

**Status:** investigation complete. **No production file was changed.** The only repository changes are this report, a
short note in [`R10_9_WORK_SEQUENCE.md`](R10_9_WORK_SEQUENCE.md) step 2.5, and the prototype/probe sources under
[`tools/spikes/r10_9_phase2b/`](../tools/spikes/r10_9_phase2b/README.md) (new files, not part of any build target). Phase 2C
(the real implementation) is not started.

Baseline: `main` at `2aff9b2`, clean tree. **[M]** HOME 546 B free (15,838 used), EXROM 1,278 B free (6,914 used) — re-measured here
from a fresh build. Floors (D-9, unchanged): HOME ≥ 350, EXROM ≥ 800.

**Evidence tags.** **[M]** measured on the real production image through the project's harness (`tools/v2_prod.py`); **[P]** measured on
an *assembled, executed prototype* built in a disposable `git worktree` (never the primary tree — see §9); **[S]** read from source
(`file:line`); **[E]** estimate; **[H]** hypothesis. Every byte count tagged [P] is the difference of `make budget` against the
baseline; "free" is `make budget`'s free-byte figure.

Companion documents: [`R10_9_ARRAY_PERSISTENCE_AUDIT.md`](R10_9_ARRAY_PERSISTENCE_AUDIT.md) (approved A2 baseline, not edited),
[`R10_9_PHASE2A_REPORT.md`](R10_9_PHASE2A_REPORT.md), [`PACKAGE_ABI.md`](PACKAGE_ABI.md), [`TESTING.md`](TESTING.md).

---

## 1. Summary and recommendation

**Recommended: architecture C — an EXROM-owned array service with *eager bind* — implemented so that HOME only loses code.**

| | HOME free | EXROM free | combined | cost of the whole feature |
|---|---:|---:|---:|---:|
| baseline [M] | 546 | 1,278 | 1,824 | — |
| **A** original split (adopt + zero-fill in HOME) [P] | 441 (−105) | 895 (−383) | 1,336 | 488 B |
| **B** hooks in HOME, logic in EXROM [P] | 518 (−28) | 807 (−471) | 1,325 | 499 B |
| **C** EXROM-owned, eager bind [P] | **585 (+39)** | 760 (−518) | **1,345** | **479 B** |

(Full feature: bind, adopt, `DIM` zero-fill, store loader with validation and atomic replace, saver, `NEW`, messages. A, B and C share
byte-identical loader/saver/validator code, tightened once; see §4. All three were assembled and C was executed, §5.)

Why C:

1. **HOME gets *larger* headroom than today** (+39 B), because the two `DIM` handlers (`OP_DIM`, `OP_DIM_STR`, 39 B) are deleted and their
   opcode-table entries point into EXROM. A pays 105 B of HOME, B 28 B. **A is marginal at best: it lands 4 B under the HOME floor in the mid case and 54 B under in the worst case (§6).**
2. **Smallest total** (479 B vs 488/499): no duplicated slot/adopt logic across the two ROMs, and `DIM` zero-fill (D12) costs no HOME bytes.
3. **No new class of banking risk.** The VM is only ever started by the EXROM shell and EXROM stays mapped for the whole run except inside
   `OP_CALL_EXT` (§3). I probed the real image and the prototype: EXROM is mapped at every site C needs, in `RUN` and in immediate statements [M][P].
4. It needs **no new HOME→EXROM call site** — only two opcode-table pointers — and no ABI change (§7).

**The price is EXROM.** C leaves EXROM at 760 B free, **40 B under the 800 floor before the rest of R10.9 is added** (§6). Moving code between ROMs
trades almost exactly 1 HOME byte for 1 EXROM byte (§4.3), so this is a placement decision, not a free lunch. §6 lists the levers that close
the gap (defer SAVE-from-store −70 B; further hand tightening; clamp-on-read; floor adjustment) and §10 states the decisions I need.

**The audit's estimate was too low by about 2×** (HOME +35…+65 and EXROM +60…+200 ⇒ 95…265 B total; measured 479…499 B total). Reasons in §4.2.

**Three findings change the approved design** and need owner confirmation (§8): (1) binding must check declared size/width *at bind time*, which
moves the "mismatch" error from the `DIM` to the start of `RUN`; (2) string-element validation must cap at **31**, not `width−1`, because the
VM's string read path copies into a 32-byte slot with no clamp; (3) `NEW`'s store reset must live in the `NEW` command, not `MEM_INIT_V2`.

---

## 2. Source facts that fix the design space [S]

* **Where things live.** `rom/v2_home.asm:99-100` includes `exrom_v2_vm_core.asm` and `exrom_v2_compiler.asm` (which includes
  `exrom_v2_symtab.asm`) into **HOME**; despite the file names, the VM and compiler are HOME code. `rom/v2_exrom.asm` assembles the
  shell, storage and editor into **EXROM**. EXROM→HOME calls are free (HOME is always mapped; HOME symbols reach EXROM through the generated
  `build/v2_crossbank.inc`, `tools/write_v2_crossbank.py`). HOME→EXROM calls need a **fixed address**: `include/v2_ktab.inc` (`V2_EXROM_*_ADDR`), each normally a
  6-byte `call V2_VERIFY_KTAB / jp routine` trampoline (`rom/v2_exrom.asm:17-100`).
* **Who starts the VM.** The only runtime caller of `VM_INIT`/`VM_RUN` is `V2_COMPILE_RUN` in the EXROM shell (`rom/exrom_v2_shell.asm:600-605`, via
  `KTAB_VM_INIT`/`KTAB_VM_RUN`). `RUN` (`V2_RUN_STORED`) and immediate statements (`V2_RUN_IMMEDIATE`) both funnel into it.
* **EXROM is paged in once at cold start** (`v2_home.asm:54-68`: `BANK_PAGE_EXROM_IN` then `jp V2_EXROM_ENTRY_ADDR`; `BANK_EXROM_DEPTH` = 1) and is only
  paged out around the package call in `OP_CALL_EXT` (`exrom_v2_vm_core.asm:3535-3541`) and in `CALC_EXIT_TRAMPOLINE`/package service wrappers.
* **Precedent for VM→EXROM calls**: `OP_CLEAR` → `MEM_CLEAR_V2`, and every `PRINT`/calculator/sound path (`exrom_format.asm`, `exrom_calc.asm`).
* **Array allocation** is `ARENA_ALLOC_NUMERIC`/`_STRING` + `VM_ARENA_FIT/DONE/SWAP` (HOME). Their *only* callers are `OP_DIM`, `OP_DIM_STR`, the EXROM
  `V2_LOAD_ARRAY` pool path that the store replaces, and one standalone test (`rom/test_v2_array_save_load.asm:146`, which exercises that old path) (`grep`, whole tree). Element access is `VM_ARR_ADDR`/`VM_STRARR_ADDR` through the pointer tables.
* **Symbol records** (`exrom_v2_symtab.asm:1-40`) carry the declared size (+ width) for every array, so a bind needs no new compile-time data.
* **`V2_EXROM_ENTRY` is reached only from `V2_COLD_START`** (`grep`; the reset vector re-enters it), so it is the correct one-shot cold-start hook.

## 3. Is EXROM mapped at every call site? (required investigation)

**Yes. Evidence: source (S) and a runtime probe of the real image (M).** The probe (`tools/spikes/r10_9_phase2b/probe_bank.py`, `probe_extra.py`) places breakpoints at
the sites, runs the real `V2_RUN_STORED`/`V2_DISPATCH`, and reads `BANK_EXROM_DEPTH` and `PORT_FF_SHADOW` plus the emulator's real `Timex FF port`.

| Context | What runs | EXROM mapped? | Evidence |
|---|---|---|---|
| Cold start | `V2_COLD_START` pages EXROM in (depth 1) then enters the shell | yes, for the life of the machine | [S] `v2_home.asm:54-68` |
| **`RUN` init** (`VM_INIT`, `VM_CARVE_TABLES`, post-init bind) | `V2_COMPILE_RUN` (EXROM) calls `VM_INIT` | **yes** | [M] depth = 1, FF = $80 at both HOME sites; [P] same at `ARR_RUN_INIT` |
| **`DIM` / `DIM$`** | `VM_RUN` dispatch `jp (hl)` | **yes** | [M] baseline `OP_DIM`/`OP_DIM_STR`; [P] `ARR_OP_DIM`/`ARR_DIM`/`ARR_OP_DIM_STR`, depth = 1 |
| **Immediate statement** (`: …`) | `V2_RUN_IMMEDIATE` → the same `V2_COMPILE_RUN` | **yes** | [M] depth = 1 at `VM_INIT`, `OP_DIM`; [P] `: DIM a(5)` adopts the stored array |
| **`CLEAR`** | `OP_CLEAR` → `MEM_CLEAR_V2` (existing HOME→EXROM call) | **yes** | [M] depth = 1 at `OP_CLEAR`, `MEM_CLEAR_V2` |
| **`NEW`** | `V2_DISPATCH` (EXROM) | yes — **no HOME call site exists** | [S] shell code; [P] probe L8 |
| **Program `LOAD`**, failed `LOAD` (wipe) | `V2_LOAD` (EXROM) → `V2_CLEAR_ARRAYS` | yes — no HOME call site | [S]; [P] probes C4, C5 |
| `LOAD`/`SAVE … ARRAY` at the prompt | shell | yes — EXROM-only | [P] |
| Package call window | `OP_CALL_EXT` pages EXROM **out**, runs the package, pages it back in | **no — but nothing array-related is reachable**: the 16 service slots (`PACKAGE_ABI.md` §3) include no array/DIM service, and a package cannot execute VM opcodes | [S] |
| Keyboard ISR | `KBD_ISR_TICK` touches chunk-4 sysvars only; never chunk 6, never segment 2 | n/a | [S] `kernel/bank/bank.asm` header |

**Invariants to protect with tests** (I propose them as Phase 2C gate cases): (I1) the VM is only entered from `V2_COMPILE_RUN`; (I2) no HOME→EXROM array site runs while
`BANK_EXROM_DEPTH == 0`; (I3) `probe_extra.py` B1/B2 re-run on the shipped image. I also recommend `ARR_RUN_INIT` call `V2_VERIFY_KTAB`: the opcode-table entries
bypass the usual trampoline, so an HOME/EXROM image mismatch would otherwise jump into the wrong code at the first `DIM` (3 B).

## 4. The three architectures, measured

### 4.1 What each one is

All variants share: store at `$E000` (segment 2), `PAS_END` (absolute end, 2 B at `$B81E`, set at cold start and by `NEW`), entry
`[len:2][kind:1][namelen:1][name][descriptor]`, **eager bind** after `VM_INIT` (one walk over the program's array symbols, each looked up in the store), the same loader/saver/validator.
Bind runs in the EXROM shell between `KTAB_VM_INIT` and `KTAB_VM_RUN` (`call ARR_RUN_INIT`, 3 B EXROM, **0 B HOME**).

| | HOME code added | EXROM code added |
|---|---|---|
| **A** | adopt test `VM_DIM_STORED` (33 B) + 36 B added to each of `OP_DIM`/`OP_DIM_STR` for the call and the zero-fill (`OP_DIM` 18→54, `OP_DIM_STR` 21→57); `VM_INIT` reads `PAS_END` at no extra cost | bind walk, loader/saver |
| **B** | in `OP_DIM`/`OP_DIM_STR`: `call` adopt-test and `call` zero-fill hooks (3 fixed slots) | bind walk, adopt test, zero-fill hooks, loader/saver |
| **C** | **none.** `OP_DIM`/`OP_DIM_STR` deleted; `VM_OP_TABLE[63/64]` point at 2 fixed slots in EXROM | whole `DIM` handler (decode, adopt test, call the *unchanged* HOME allocator, zero-fill), bind walk, loader/saver |

### 4.2 Measured ROM cost [P]

Differential part only (first-cut code, loader/saver excluded) — useful because it isolates the architecture choice:

| Variant | HOME free | ΔHOME | EXROM free | ΔEXROM | combined |
|---|---:|---:|---:|---:|---:|
| baseline [M] | 546 | — | 1,278 | — | 1,824 |
| A | 433 | −113 | 1,099 | −179 | 1,532 |
| B | 514 | −32 | 1,007 | −271 | 1,521 |
| C | 585 | **+39** | 959 | −319 | 1,544 |
| VC — C with *lazy* bind (rejected, §4.4) | 577 | +31 | 882 | −396 | 1,459 |
| C+ — C and the allocation cores moved verbatim into EXROM | 806 | +260 | 738 | −540 | 1,544 |

Full feature, with the common loader/saver (first cut → one tightening pass) [P]:

| Variant | HOME free | EXROM free | note |
|---|---:|---:|---|
| C first cut | 585 | 687 | service + loader 779 B |
| **A** tightened | 441 | 895 | |
| **B** tightened | 518 | 807 | |
| **C** tightened | **585** | **760** | service + loader 704 B; pass 1 saved 77 B |

Where C's 704 B go (tightened) [P]: `ARR_RUN_INIT` 110, `ARR_DIM` + 2 stubs 129, iteration/slot helpers 32, `V2_LOAD_ARRAY` 216, `ARR_VALIDATE` 85,
`ARR_FIND` 42, `ARR_SAVE_STORE` 70, `V2_PAD_NAME` 20. Offsetting deletions: old `V2_LOAD_ARRAY` −187, array-name scan −31, duplicated filename-pad loop −22, one message −18.

**Why the audit under-estimated.** (a) Audit "bind walk 55–75" → 110 measured. (b) Audit "adopt helper + 2 call sites 30–50 HOME" → 105 measured for A once the range test and the
zero-fill are included. (c) The audit priced the validator at +25…+45; the string validator that is actually safe (§8.2) is 85 B. (d) SAVE-from-store (70 B) is priced inside "save-from-store" but the
loader net came out +195 B vs the audit's −40…+110. None of this is a flaw in the A2 *design*; it is a pricing error that the prototypes now correct.

### 4.3 The HOME↔EXROM exchange rate

C+ moved the 216 B allocation cores (`ARENA_ALLOC_NUMERIC` 71, `_STRING` 89, `VM_ARENA_FIT` 37, `_DONE` 9, `_SWAP`) from HOME to EXROM and the budget moved by exactly 221 B each way (combined unchanged). So placement is a near-1:1 trade:
A→C buys 144 HOME bytes for 135 EXROM bytes (1.07 : 1), B→C 67 for 47 (1.4 : 1), A→B 77 for 88 (0.9 : 1). The only genuine *savings* come from removing duplication: C's deletion of the HOME decode (the two handlers, 39 B) and the shared pad routine (−22 B).

### 4.4 Rejected variants

* **VC — lazy bind** (a single `ARR_BIND(index, kind)` used for both `DIM` and the slot-0 exit of `VM_ARR_ADDR`/`VM_STRARR_ADDR`): *answers the "share one implementation for init and DIM" question* —
  it works, but needs a reverse symbol lookup (index→name) and a per-call store walk: 184 B for `ARR_BIND` alone, **+77 B EXROM and +8 B HOME vs eager C** (4 B for the two slot-0 hooks, 4 B for the `PAS_LEN` base in `VM_INIT`), and puts a hook on the element-access error exit.
  Eager wins on both ROMs. (Its one advantage — the mismatch error lands exactly at the `DIM` — is obtained more cheaply by fail-fast, §8.1.)
* **C+ now** (move/unify `ARENA_ALLOC_*` into EXROM): HOME 806 B free but EXROM 738 — below the floor and the full feature not yet counted. Kept as a *reserve lever* (§6): once the store loader no longer uses the
  allocator, `DIM` is its only caller, so a later unification (one parametrised allocator instead of two near-duplicates, est. −40…−60 B combined [E]) is cheap to do and safe to defer.
* **Patching the compiled bytecode** at bind time (skip adopted `DIM`s): needs the compiler to record `DIM` addresses (HOME bytes) and rewrites variable-length bytecode in RAM. Rejected: more HOME, more risk.
* **Sharing one entry for init and `DIM`**: both already share `ARR_SLOT`, the entry iterator and the adopt predicate; a selector byte would add ≈ 6 B of dispatch and save nothing (the stubs are 2–4 B each).

## 5. Functional evidence on the C prototype [P]

The tightened C build was executed on the production harness (headless ZEsarUX): `probe_store.py` (hand-built store), `probe_loader.py`, `probe_extra.py`. All pass.

* **Adopt / bind:** `DIM a(5)` adopts a stored array (`y = 33`); writes persist into the next `RUN` and are visible in the store bytes; **D6 shape** (`GOTO` over the `DIM`) sees the loaded array; string arrays adopt; an unrelated program ignores the store; **D12**: all four `D12-*` known-defect cases flip to XPASS on the first-cut C build (zero-fill, at no HOME cost).
* **Mismatch:** size or width differing from the declaration → runtime error 65 (`ARRAY SIZE MISMATCH`) before the first statement, store byte-identical.
* **Overflow coexistence:** an array that spills to segment 2 lands at `$E012`, directly above an 18-byte store; store untouched.
* **Loader/saver:** `LOAD … ARRAY` with **no prior compile**; an 11-character name (D14); same-name `LOAD` replaces atomically (a middle entry is removed, others keep their bytes, new entry last, both then bind to the right descriptors); `SAVE … ARRAY` writes a **type-8** header (D13) from the live array *and* from the store (after an edit).
* **Eleven rejected tapes**, each with the store byte-identical afterwards: `dim_count 7`, `count 0`, `count 100` with a short body, trailing byte, string-into-numeric, numeric-into-string, string `width 1`, element length 40, element length ≥ width, **bad checksum** (`LOAD FAILED`), **bad version word** (`BAD TAPE VERSION` — this repairs D16 as a by-product). "No room for the entry header" → `ARRAY STORE FULL`.
* **Lifecycle:** `NEW` clears the store; `CLEAR` keeps it and `ARR2_END` stays ≥ `PAS_END`; typing a line, an immediate statement, a plain program `LOAD`, and a **failed** program `LOAD` (which wipes the program) all leave the store intact; a value written by one `RUN` is seen by the next.
* **Existing suites on the first-cut C build:** the full production gate `v2_prod_regress.py` — **57 PASS, 0 FAIL** (49 in the first run + the 8 package cases rerun after `make v2-packages`, which my scratch worktree had not run); `D15-control-*` positive controls PASS (old pool loader untouched in that build); D6 stays XFAIL there (loader not present) as expected.
* **Static gates on the tightened build:** `check_package_abi.py` ("ABI 2.0 — 16 service slots, 34 pinned cells, 11 constants, 5 packages: all checks passed"), `check_storage_contract.py`, `check_ram_aliases.py`, `check_asm.py`: pass.

Not run on the prototype: the 38-test standalone suite (they cannot assemble — §7), `v2_production_checks.py`, `v2_fill_check.py`, and the full `make test`. They are Phase 2C gates.

### 5.1 Runtime overhead [P]

RUN-start bind (`ARR_RUN_INIT`), T-states per `RUN` on the real image (3.528 MHz; measured with the emulator's T-state counter and the ISR frame counter):

| Store entries | Program symbols | Arrays declared | **forward** bind (walk entries, `SYM_FIND` each) | **reverse** bind (walk array symbols, `ARR_FIND` each) |
|---:|---:|---:|---:|---:|
| 0 | 10 | 0 | 163 T (0.05 ms) | 91 T (0.03 ms) |
| 3 | 10 | 3 | 5,320 T (1.5 ms) | 6,396 T (1.8 ms) |
| 20 | 120 | 5 | 230,716 T (65 ms) | 25,528 T (7.2 ms) |
| 100 | 200 | 0 | 2,205,975 T (**625 ms**) | 25,564 T (**7.2 ms**) |
| 100 | 200 | 100 | 2,300,056 T (652 ms) | 2,797,549 T (793 ms) |

The forward walk (the audit's formulation) costs O(entries × symbols) because `SYM_FIND` rescans the whole compile symbol table per entry. The **reverse walk costs O(symbols + declared arrays × entries)**: 86× faster in the 100-entry case, and the
only slow row is the unrealistic one where the program declares 100 arrays against a 100-entry store. The reverse walk costs +4 B EXROM (110 vs 106 B) and reuses `ARR_FIND`, which the loader needs anyway; **the report's C numbers use it**. (A and B were re-measured with the same routine.)

Programs with an empty store pay 91 T-states (the routine returns on the first test). `DIM` in EXROM adds one `jp` indirection (10 T) to a statement that is already the most expensive
in the language (allocation plus now a `LDIR` zero-fill, ≈ 21 T per byte: `DIM a(1000)` ≈ 12 ms). Element access (`VM_ARR_ADDR`) is **unchanged** — no hot-path byte or cycle is added.

## 6. Budget outlook and how to close the EXROM gap

Remaining R10.9 consumption from `R10_9_WORK_SEQUENCE.md` §2a: HOME +55…+105 (+20…+40 if 2.7 is implemented), EXROM 0…+55 (+10…+20). I use 55 / 95 / 145 B HOME and 0 / 35 / 75 B EXROM as best / mid / worst.

| Free after the rest of R10.9 (best / mid / worst) | HOME (floor 350) | EXROM (floor 800) |
|---|---|---|
| A | 386 / **346** / **296** ✗ | 895 / 860 / 820 ✓ |
| B | 463 / 423 / 373 ✓ | 807 / **772** / **732** ✗ |
| **C** | **530 / 490 / 440** ✓ | **760 / 725 / 685** ✗ |

No placement puts *both* ROMs above their own floor in the mid case without further savings. The **combined slack** (HOME + EXROM above both floors) is +56 B (A), +45 B (B) and +65 B (C) at mid, so the feature fits overall, but it fits in the wrong ROM: C is 75 B short in EXROM with 140 B spare in HOME, B is 28 B short in EXROM, A is 4 B short in HOME.
Moving work back to HOME is possible only in lumps of 30–110 B (§4.1) and spends the HOME the project is trying to protect. The available levers are also lopsided: about **150–200 B of EXROM savings are on the table (L1–L3) against only 40–60 B of HOME (L4)**, which is why closing C's EXROM gap is far more tractable than closing A's HOME gap. Levers, cheapest first:

| # | Lever | Saves | Cost / risk | Tag |
|---|---|---:|---|---|
| L1 | **Defer SAVE-from-store** (`ARR_SAVE_STORE`) | 70 EXROM | After an edit or immediate statement a store array cannot be `SAVE`d until the next `RUN` (bound arrays still save through the live path — probe L7b). Audit §5.3 listed it; no owner decision requires it for the core. | [P] size |
| L2 | Further hand tightening of the 704 B | 50…100 EXROM | pass 1 took 77 B (−11 %) in one sitting; riskless, needs the tests below | [E] |
| L3 | Clamp string-element length on the **read** path (`OP_STRARR_LOAD`) and drop the loader's element scan | ≈ 30 EXROM for ≈ 6…8 HOME | memory-safe by construction at the single consumer; a corrupt length byte then reads as a clamped string instead of `BAD ARRAY TAPE` | [E] |
| L4 | Unify `ARENA_ALLOC_NUMERIC/STRING` (after the loader stops using them) | 40…60 combined | refactors working code; independent of the store | [E] |
| L5 | C+ (allocator into EXROM) | +221 HOME for −221 EXROM | **wrong direction for the EXROM floor**; a HOME-buying reserve if HOME becomes the constraint | [P] |
| L6 | Floor for R10.9 close: EXROM 800 → ≈ 720 | n/a | R10.10's planned floor is EXROM ≥ 500; R10.10 will in any case consume EXROM +385…+655 [E] (work sequence) and is already unaffordable on paper | policy |
| — | Transport class "tape too long" for the exact `ARRAY STORE FULL` message | **costs** ≈ 6 EXROM | without it an oversized tape reports `LOAD FAILED` (probe L9) | [E] |

L1 + L2 alone bring C to ≈ 880…930 B EXROM free before the rest of R10.9 and ≈ 805…930 after it (≥ 800 in every case), with HOME untouched at 440…530. Without L1, L2 alone gives 810…860 before and 735…860 after, which clears the floor in the best case and in the mid case only if L2 delivers ≥ 75 B.

## 7. Compatibility, ABI and test infrastructure

* **Package ABI 2.0 is unchanged.** The two fixed EXROM slots (`$C0E6`, `$C0E9`) are a private HOME↔EXROM contract in `include/v2_ktab.inc`, not a package service. No pinned cell or constant moves; the new `PAS_END` cell at `$B81E` lies in the verified-free gap (`check_ram_aliases.py` passes). The tape version words stay `$8100`/`$8200`; type 8 stays type 8 (D13 only fixes the writer). [P]
* **No new HOME→EXROM call site and no change to `VM_ARR_ADDR`.** HOME changes for C: two table pointers, delete two handlers, one `EQU` alias, one sysvar constant.
* **Standalone test impact (real cost, not ROM bytes).** 12 of 54 `rom/test_v2_*.asm` use `DIM` (`array_save_load, arrays, case_insensitive, chunk_array_reads, chunk_boundary_values, chunk_refill_boundary, control_stack, dynamic_arrays,
  identifier_length, identifier_toolong, run_tables, string_arrays`). With C **every harness HOME build stops assembling** (each includes `exrom_v2_vm_core.asm`) until `V2_EXROM_ARR_DIM_ADDR`/`…_STR_ADDR` exist — observed [P]: `tools/run_v2_standalone_tests.sh` aborts on the first build with `Label not found: V2_EXROM_ARR_DIM_ADDR`. Of the 6 *flat* tests that concatenate a test HOME with the *production* `build/exrom.bin`
  (`deffn`, `vm_milestone01`, `chunk_refill_boundary`, `chunk_boundary_values`, `for_first_token`, `chunk_array_reads`), the three that use `DIM` (`chunk_array_reads`, `chunk_boundary_values`, `chunk_refill_boundary`) would additionally jump into the production service, which is linked to production HOME addresses. `rom/test_v2_array_save_load.asm` calls `ARENA_ALLOC_NUMERIC` directly, so it also pins C+ (allocator in EXROM) out of scope for the first step.
  Options: (i) test-only `IFDEF` keeps the original handlers in the test HOME (0 ROM bytes, but those tests stop exercising the production DIM code); (ii) the harness EXROM includes the real service with a harness cross-bank include (higher fidelity, more work);
  (iii) move the array-exercising checks to the production-image gate (where D12/D6/D15 and my probes already live). I recommend (iii) for the new semantics plus (i) to keep the legacy component tests green.
* **`CLEAR` coupling (audit §11.3).** The repaired `CLEAR` (step 2.6) must *not* reset the compile symbol table or raise `VARS_START`, and must end with `call ARR_RUN_INIT` after zeroing the pointer slots. With eager bind that is one call; today's `CLEAR` is untouched by the prototype and `ARR2_END` already honours `PAS_END` (probe C1).

## 8. Findings that change or sharpen the approved design

### 8.1 Bind must validate size/width; the mismatch error moves to the start of `RUN` (needs owner OK)

The audit binds on (name, kind) and checks size at `DIM`. But `DIM` can be jumped over (that is exactly the D6 program), and element access bounds-checks against the **compile-time declared size**, not the descriptor's count. A bound-but-unchecked
`count 2` descriptor under a declared `a(5)` would let indices 2…4 read **and write** the next store entry. Safe designs: validate at bind (C, as built) or add a size check in the access path (HOME bytes, hot path). I chose bind-time validation: a mismatch raises error 65 `ARRAY SIZE MISMATCH`
from `ARR_RUN_INIT` before the first statement, with the store untouched. This differs from D-3's wording ("clean runtime error **at `DIM`**") only in *when*; it is stricter, cheaper, and gives one code path. It re-targets `D15-count-short`/`-long` (Phase 2A decision 1) from "`DIM`" to "`RUN` start".

### 8.2 String-array element validation must cap at 31, not `width−1`

`OP_STRARR_LOAD` (`exrom_v2_vm_core.asm`, `.load_copy`) copies `len` bytes from the element into a **32-byte** `STRTAB` temp with no clamp, and the compiler accepts widths 2…255. Program-written elements are ≤ 31 (they come from a `STRTAB` record), so this is latent today, but a tape-supplied length byte up to `width−1` (≤ 254) would overflow the temp into neighbouring run-time tables.
The audit's validator rule "every element `len ≤ width−1`" is therefore insufficient. Implemented: `len < 32` **and** `len < width`; `probe_loader.py` rejects element length 40 and element length ≥ width. (Lever L3 moves this check to the read path.)

### 8.3 `NEW` must clear the store in the `NEW` command, not in `MEM_INIT_V2`

`MEM_INIT_V2` is also the failed-`LOAD` wipe (Phase 2A: "known-safe empty state, exactly `NEW`"). Clearing the store there would destroy persistent arrays because an unrelated program tape failed mid-block. The prototype resets `PAS_END` in `V2_DISPATCH`'s `NEW` branch (6 B); probe C5 verifies a mid-block failure leaves the store intact.

### 8.4 `DIM` zero-fill must not live in the shared `ARENA_ALLOC_*` tails (audit §6, Stage 0)

While `V2_LOAD_ARRAY` still receives into the pool and *then* calls `ARENA_ALLOC_*` to commit in place, a fill in those tails would zero the data it just received. In C the fill sits in the EXROM `DIM` handler; in A/B it is in the `DIM` path, not the shared cores.

### 8.5 Smaller items

* **Cold-start init.** A zero default for `PAS_LEN` would be fail-safe; `PAS_END` (absolute) saves the `+ARR2_BASE` add at each use (and keeps `VM_INIT` at 0 HOME bytes in A/B) but requires the one-shot init in `V2_EXROM_ENTRY` (9 B fit in the existing 18-byte slot) and a `arr-coldboot-empty` gate case.
* **`STORAGE_LOAD` cannot say "too long"** (probe L9): a tape larger than the free store is refused with the generic clean failure → `LOAD FAILED`. "No room for the header" does give `ARRAY STORE FULL`.
* **Shared filename padding.** `V2_LOAD` and the array loader carried the same 12-line pad loop; one `V2_PAD_NAME` serves both (−22 B).
* **Order of fills:** the new entry is built in the free tail with its key copied *before* `STORAGE_LOAD_NAME_BUF` (== `EDIT_LINE_BUF`, where the typed array name lives) is overwritten — the same hazard the old loader documented.
* **Bind direction matters for run time, not for correctness.** Walking the store and `SYM_FIND`-ing each entry (the audit's formulation) is O(entries × symbols); walking the program's array symbols and `ARR_FIND`-ing each is O(symbols + arrays × entries) (§5.1) for +4 B.
* **Stale entries have no per-array delete.** A stale `x(10)` fails a new program that declares `x(20)`; `LOAD` of a new `x` replaces it, `NEW` clears everything. A `KILL`-style command is out of scope but is the obvious follow-up.

## 9. Method and reproducibility

All prototype builds were made in `git worktree`s of `2aff9b2` outside the repository; the primary tree was only read (a pre-existing `build/` there was not rebuilt). `tools/spikes/r10_9_phase2b/README.md` lists every prototype, how to apply it
(`WT=<scratch worktree> tools/spikes/r10_9_phase2b/build.sh mk_fullopt.py copt2|aopt2|bopt2`), and which probe produced which number in this report. The probes use the production harness with an isolated `TS2068_DEBUG_STATE_DIR` and port. No Fuse/X11 was started and `make test-legacy` was not run.

## 10. Decisions requested from the owner

1. **Architecture C** (EXROM-owned, eager bind) as the Phase 2C baseline? (Alternative if EXROM is the hard constraint: B, which costs 67 B more HOME than C and frees 47 B more EXROM.)
2. **Fail-fast size/width check at `RUN` start** instead of at `DIM` (§8.1) — amends D-3's timing and re-targets two Phase 2A D15 cases.
3. **How to close the EXROM gap** (§6): defer SAVE-from-store (L1)? accept a lower R10.9 EXROM floor (L6)? both? Neither is needed for the core to work; the floor is what is at stake.
4. **String-element cap at 31** in the loader now (§8.2), or clamp-on-read (L3, +6…8 HOME)?
5. **Standalone-test strategy** for the 12 DIM tests (§7 options i–iii).
6. Whether an exact `ARRAY STORE FULL` for oversized tapes (≈ 6 B transport class) is worth it.

## 11. Proposed Phase 2C sequence (once decisions 1–5 are made)

| # | Step | Gate |
|---|---|---|
| 1 | Stage-0 repairs that commit nothing to the store: D13 type byte, 31-character names, `V2_PAD_NAME` factoring | `D13-*`, `D14-*` flip |
| 2 | `PAS_END` cell, cold-start init, `V2_CLEAR_ARRAYS` base, `NEW` hook; no users yet | all existing gate cases unchanged; `arr-coldboot-empty` |
| 3 | Store loader + validator + replace, `SAVE` fallback (per decision 3) | `arr-load-*`, `arr-store-replace-*`, `D15-*` structural cases; D16 flips |
| 4 | `ARR_RUN_INIT` bind + EXROM `DIM` handlers + zero-fill; remove HOME handlers; harness changes (§7) | **D6 flips**, `D12-*` flip, `arr-dim-*`, `arr-store-survives-*`, `arr-banking-sites`; 38/38 standalone |
| 5 | Measure and publish; re-plan against §6 | floors HOME ≥ 350, EXROM ≥ 800 |

The probes under `tools/spikes/r10_9_phase2b/` map one-to-one onto these gate cases and can be ported into `tools/v2_prod_regress.py`/`v2_known_defects.py` largely as written.

## 12. Limits of this evidence

Prototype sizes are first/second-pass assembly, not final code. The common loader/saver/validator is byte-identical across A, B and C; the `DIM`/bind code was tightened for C and written in the same style for A and B, so a careful Phase 2C rewrite may move any variant by tens of bytes (not by hundreds — the rankings in §4.2/§6 rest on differences of 45–150 B that come from placement, not from style).
**Only C was executed.** A and B were assembled and measured but not run; the 11 + 25 + 9 functional checks (§5), D12 and the full 57-case production gate were run on C (the gate on the first-cut build, the probes and static gates on the tightened build). Timings are from the emulator's T-state counter and the ISR frame counter. Tape behaviour is the project's synthetic EAR stream (no analogue path; physical validation still owed, per `TESTING.md`). The standalone suite, `v2_production_checks.py`, `v2_fill_check.py` and a full `make test` were not run on any prototype. Estimates tagged [E] have not been assembled.

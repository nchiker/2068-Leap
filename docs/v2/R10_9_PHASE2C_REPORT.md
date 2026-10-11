# R10.9 Phase 2C — the persistent Array Store (architecture C)

**Status:** implemented on top of `c36c4ed` (Phase 2B), committed locally on `v2-development`, **not pushed**. Evidence tags as in the
Phase 2B report: **[M]** measured on the real production image through the project's harness, **[S]** read from source.
Decisions followed: [`R10_9_PHASE2B_REPORT.md`](R10_9_PHASE2B_REPORT.md) (architecture C, eager reverse bind, fail-fast size/width check at
`RUN`, string-element cap 31) and the audit's lifecycle contract ([`R10_9_ARRAY_PERSISTENCE_AUDIT.md`](R10_9_ARRAY_PERSISTENCE_AUDIT.md) §5.3,
§11) where Phase 2B does not correct it. Package ABI 2.0, the pinned RAM cells and the tape version words are unchanged.

## 1. What was built

| Area | Implementation |
|---|---|
| Store | segment 2 from `$E000` to `PAS_END` (`$B81E`, absolute end; `$E000` = empty). Entry `[len:2][kind:1 (2 num | 3 str)][namelen:1][name][descriptor]`, descriptor = the tape body verbatim. Set at cold start (`V2_EXROM_ENTRY`) and by `NEW` only — **never** by `MEM_INIT_V2` (it is also the failed-program-`LOAD` recovery). `ARR2_END >= PAS_END` always |
| Service | `rom/exrom_v2_arrstore.asm` (EXROM, new): `ARR_RUN_INIT` (bind + validate), `ARR_OP_DIM`/`ARR_OP_DIM_STR`, `ARR_FIND`, `ARR_VALIDATE`, `V2_LOAD_ARRAY`, `ARR_SAVE_STORE`, `V2_PAD_NAME` |
| Bind | after `VM_INIT`, the shell calls `ARR_RUN_INIT`: it walks the program's **array symbols** once and looks each up in the store (reverse bind: O(symbols + arrays × entries)). A hit publishes the descriptor in the run's pointer slot **iff** the stored count (and width) equals the declared size; otherwise the run stops with error 65 `ARRAY SIZE MISMATCH` before the first statement. The same routine rebinds after `CLEAR`. It begins with `call V2_VERIFY_KTAB` (HOME/EXROM image check; the DIM slots bypass the usual trampolines) |
| `DIM` / `DIM$` | the two HOME handlers are **deleted**; `VM_OP_TABLE[63/64]` point at two fixed `jp` slots in EXROM (`$C0E6`, `$C0E9`, `include/v2_ktab.inc`). A slot already bound into the store is *adopted* untouched; anything else is allocated by the unchanged HOME allocator and **zero-filled** (D12) |
| Tape | `LOAD ... ARRAY` receives into the free tail, validates the received bytes, then commits `PAS_END`; a same-name (case-insensitive) entry is replaced with one `LDIR` that carries the new entry down (atomic: a failure before the commit leaves every byte untouched). `SAVE ... ARRAY` writes a type-8 header (D13) from the live array, or **from the store** when the name is not live (`ARR_SAVE_STORE`, finishing through `V2_SAVE_ARRAY.send`). Names 1–31 characters (D14). A bad version word reports `BAD TAPE VERSION` (D16) |
| `CLEAR` | `MEM_CLEAR_V2` is now run-scoped: it zeroes the carved run tables in place, restarts the ordinary-array arena as `VM_INIT` leaves it, then calls `ARR_RUN_INIT`. It no longer resets the compile symbol table or `VARS_START`, and no longer clears loaded packages (D8) |
| `NEW` | `V2_DISPATCH`'s `NEW` branch resets `PAS_END` before `MEM_INIT_V2` |

HOME changes: two table pointers, two handlers deleted, one exported label (`VM_RUN_LOOP`), the `VM_ERR_COMMON` cross-bank name. EXROM: the service, three messages
(`ARRAY STORE FULL`, `BAD ARRAY TAPE`, `ARRAY SIZE MISMATCH`), two removed routines (the old pool-path loader, the 8-character name fold), one
shared filename pad.

## 2. Defects repaired

| ID | Defect | Now |
|---|---|---|
| D6 | a loaded array could not reach a `RUN` | persists across `RUN`, edits, immediate statements, program `LOAD` (and failed `LOAD`), `CLEAR`; gate `D6-array-load-survives-run` + 7 lifecycle cases |
| D8 | `CLEAR` did not reset scalars, reset the compile symbol table / `VARS_START` under a running program, and unregistered packages | run-scoped `CLEAR` (§1) |
| D12 | `DIM` did not zero-fill | zero-filled on the main pool and in segment 2, numeric and string |
| D13 | `SAVE ... ARRAY` wrote a type-0 (program) header | type 8, word `$8100`; plain `LOAD` refuses it; own tape reloads |
| D14 | array names > 8 characters unusable | 1–31 characters, case-folded; 32 is refused |
| D15 | `LOAD ... ARRAY` accepted any body | structure validated before commit (§3); declared-size compatibility is checked at `RUN` start (retargeted `count-short` / `count-long`, Phase 2B §8.1) |
| D16 | array tape with a bad version word said `LOAD FAILED` | `BAD TAPE VERSION`, store untouched |

## 3. Array tape body (format 1.0 normative; the version word and header type did not change)

* numeric `[1][count:2][count × 2]`, `1 <= count < 2048`, length exactly `3 + 2·count`;
* string `[1][count:2][width:1][count × width]`, `width >= 2`, **every element length byte `<= 31` and `< width`**, length exactly `4 + count·width`
  (the VM copies a string element into a 32-byte slot with no clamp, Phase 2B §8.2);
* `dim_count` must be 1 (the pre-2C pool loader rewrote other values; the audit §11.4 says reject — rejected);
* anything else → `BAD ARRAY TAPE`, nothing stored. Defective pre-2C array tapes are not supported (owner decision D-8).

## 4. Memory safety found and fixed during implementation

Two defects in the **Phase 2B prototype code** were found by the new tests and fixed before they entered the tree:

1. **Validator rejected every numeric array with `count >= 8`** (`ld a,b / or c / cp 8` compared `B|C`, not `B`). The Phase 2B probes only used counts ≤ 5.
   Regression `D15-large-numeric` (8, 10, 100, 255, 256, 1000 elements); a negative control with the prototype order restored fails exactly as expected
   (`BAD_ARRAY` for every size except 256).
2. **The entry header and key name were written before the room check**, so a nearly full store (e.g. `PAS_END = $E7FC`, or a 31-character name) wrote up to
   35 bytes past `ARR2_LIMIT` into the sprite buffers at `$E800`. The room check now precedes every write; `arr-store-full-header` / `-name31` / `-body` /
   `-exact-fit` plant a guard pattern at `$E800` and assert it is intact.

## 5. `CLEAR` design

`OP_CLEAR` → `MEM_CLEAR_V2` (EXROM, mapped during VM execution). Previously `V2_CLEAR_ARRAYS` called `SYM_RESET` and raised `VARS_START` to `V2_SOURCE_END`
while the carved tables still lived below it, never touched scalars, and cleared the package registry. Now: `ARRAYS_END ← SYM_END_V + 1` (exactly
as `VM_INIT`), the block `[VARS_START, V2_SOURCE_END)` is zero-filled (scalars, floats, strings, temp slots, array pointers — the control stack lies below
`VARS_START` and is untouched), then `ARR_RUN_INIT` sets `ARR2_END ← PAS_END` and rebinds. Consequences, all tested: stored arrays keep their data
and stay reachable after `CLEAR` (also by a re-executed `DIM`); ordinary arrays are discarded (reading one is runtime error 10, a re-executed `DIM` is zero);
the program continues with valid symbols; packages stay registered.

## 6. ROM budget [M] (`make budget`)

| | HOME free | EXROM free | note |
|---|---:|---:|---|
| Phase 2B baseline | 546 | 1,278 | |
| Phase 2B architecture-C prototype | 585 | 760 | |
| Phase 2C first integration (prototype + fixes + `CLEAR` + KTAB verify) | 585 | 738 | |
| **Phase 2C final** | **585** | **788** | hand tightening below |
| Floor | ≥ 350 | ≥ 800 | |

HOME is +39 B above the baseline (floor met with 235 B to spare). **EXROM is 12 B below the 800 target** before the rest of R10.9. Not hidden by lowering the target.
The remaining R10.9 estimate (work sequence §2a: EXROM 0…+55) would take the shortfall to 12…67 B.

Hand tightening applied (all measured, sizes from `make budget`): `SAVE`-from-store finishes through `V2_SAVE_ARRAY.send` instead of its own transport call (−24),
`VM_ERR_COMMON` for error 65 (−6), room check by `LIMIT-1` (−4), adopt test through `ARR_AT_END` (−4), shared message exit (−3 and −2), no `push af` in the string validator (−2), empty-store test (−2), index kept
in `A` across `ARR_SLOT` (−3), `jp`→`jr` where in range. **Z80 Shrink:** the project's tool is the `shrink-z80` skill's scanners (`~/z80-skills`); `z80_pattern_scan.py` accepts the project's `sjasmplus` syntax and
the single-file ASM, but it is text-based and knows nothing about HOME/EXROM banking, fixed slots or the ABI. It was run on `rom/exrom_v2_arrstore.asm`; its candidates (repeated `ld e,(hl)/inc hl/ld d,(hl)`,
`inc hl ×3`, IX use, zero loads) were each evaluated by hand and none is a net saving as a shared routine at this size (a 4-byte helper costs more than its call sites save). Transformations were
accepted only after reading registers/flags/stack and re-measuring.

Levers still available if the 800 target must be met without further hand work (not taken): drop `ARRAY STORE FULL` (≈ 22 B; the tape would report `LOAD FAILED`); defer
`SAVE`-from-store (now ≈ 38 B); clamp-on-read (Phase 2B L3, ≈ 30 EXROM for 6–8 HOME).

## 7. Tests

See `docs/v2/TESTING.md` ("Array Store"). Results of the final qualification are in §9.

* `tools/v2_prod_arrays.py` (new, 98 cases, all gate): D6 (1), D8 (4), D12 (5), D13 (4), D14 (11), D15 (26, including the controls and the retargeted `count-short`/`count-long`), D16 (2) and 45 `arr-*` cases: adoption,
  persistence ×3 runs, string arrays, jump over `DIM` (valid and mismatching), mismatch before the first statement, kind isolation, case folding, immediate `DIM`, segment-2 coexistence and exhaustion,
  edit / immediate / program `LOAD` / failed `LOAD` / `NEW`, replacement (middle, smaller/equal/larger, case, kind), compaction + rebind, failed replacement and dropout, store-full variants
  (header, 31-character name, body, exact fit, replace peak), save-from-store, banking at every new HOME→EXROM site (RUN, DIM, DIM$, CLEAR, immediate), `V2_VERIFY_KTAB`.
* `tools/v2_known_defects.py`: D6, D8, D12–D15 removed (they are fixed and live in the array suite); D1–D5, D7, D9–D11 expectations unchanged (strict XFAIL/XPASS accounting kept).
* Standalone component tests: the 12 `DIM`-using tests (and every harness that assembles `vm_core`) bind opcodes 63/64 to the **test-only** handlers in `rom/test_v2_local_dim.inc` (the old
  allocate-only handlers plus the D12 zero-fill). They do not exercise the production `DIM` or the store; the production-image suites do.
* `tools/run_v2_prod_tests.sh` runs the gate, the array suite and the known-defect suite concurrently.

## 8. Known limitations (and deferred items)

* No per-array delete (`KILL`): a stale stored array whose size differs from a new program's `DIM` stops that `RUN` with `ARRAY SIZE MISMATCH`; `NEW`, or a `LOAD ... ARRAY` of the right size, clears it.
* 2,048 bytes total, shared with segment-2 overflow arrays. Replacement needs room for old + new (atomicity).
* Width and size mismatches share one message (`ARRAY SIZE MISMATCH`).
* `LOAD ... ARRAY` is a prompt-time mutation: it discards the live arrays and the compile symbol table (as an edit does), so `SAVE ... ARRAY` of a non-stored live array is `ARRAY NOT DIMD` until the next `RUN` (a stored array can still be saved by name).
* `CLEAR` inside a `FOR` zeroes the loop variable (the loop bound lives in the control stack).
* Deferred by decision: program + arrays bundle (D-6), in-program `LOAD/SAVE ... ARRAY` (D-7). The **program + all current variables** snapshot (storage goal 2) is a separate, unimplemented requirement; nothing here is one.
* The generated user-manual `.docx` was not rebuilt.

## 9. Final qualification [M]

One full `make test` on the committed tree (`1f282d9` + docs), exit status 0, no Fuse/X11 (`make -n test | grep -ci fuse` = 0; `make test-legacy` was **not** run), after
`make check` rc 0 (including `check_package_abi.py`: "ABI 2.0 — 16 service slots, 34 pinned cells, 11 constants, 5 packages: all checks passed", `check_storage_contract.py`,
`check_ram_aliases.py`, `check_docs.py`, `check_test_targets.sh`):

| Check | Phase 2A | Phase 2C |
|---|---|---|
| Headless smoke ROMs | 9/9 | **9/9** |
| V2 standalone (fake services; test-only DIM handlers) | 38/38 | **38/38** |
| `v2_production_checks.py` | 19/19 | **19/19** (`FAILURES: 0`) |
| `v2_fill_check.py` | 10/10 | **10/10** |
| Production gate `v2_prod_regress.py` (incl. 5 packages, `abi-*`, D1/D2) | 57 PASS | **57 PASS**, 0 XFAIL, 0 FAIL, 0 XPASS |
| Array Store gate `v2_prod_arrays.py` | — | **98 PASS**, 0 FAIL |
| Known defects `v2_known_defects.py` | 15 PASS, 72 XFAIL | **9 PASS, 44 XFAIL**, 0 FAIL, 0 XPASS |

Known-defect arithmetic: XFAIL 72 − 28 fixed (D6 1, D8 2, D12 4, D13 4, D14 8, D15 9) = 44; PASS 15 − 6 positive controls moved with their defects (D14 ×3, D15 ×3) = 9. The 44 remaining
are D3, D4, D5, D7, D9, D10, D11 and U6 — none belongs to Phase 2C. The array suite was additionally run in full on the pre-optimisation build (88 PASS + 10 test/harness
corrections, then 98 PASS) and again in full on the final optimised build (98 PASS) before the commit.

Final budget [M]: HOME 585 free (floor 350 ✔), EXROM 788 free (floor 800 — **12 B short**, §6).

## 10. Physical hardware still required (nothing here is hardware-qualified)

Real-recorder `SAVE ... ARRAY` → `LOAD ... ARRAY` round trip of a small and a ≈ 2 KB array and a string array; deliberate dropout and SPACE abort during an array `LOAD`; wrong-name tape;
EXROM/Dock paging at `RUN` start, `DIM` and `CLEAR` on a real machine (the emulator maps EXROM at `$C000` the same way, but the Dock timing is not modelled); behaviour of the store at `$E7FF/$E800`
next to the sprite buffers with sprites visible; the earlier Phase 1/2A checklist (`R10_9_PHASE1_REPORT.md` §6, `R10_9_PHASE2A_REPORT.md` §11) is unchanged.

# 2068-Leap V2 — Remaining completion budget (qualification study, Phase C)

**Status:** complete for the scope below. The anchor points in §1 are measured on assembled production images. Everything after them is a projection,
marked **[E]**. No projection is presented as a saving or a cost that was assembled. Nothing is integrated: `~/2068-Leap` / `v2-development` stay at `7ae0599`,
nothing was pushed.

**Evidence classes:** **[M]** measured (`make budget` on an image built from the named commit, by `tools/qual/build_configs.sh`); **[S]** read from source;
**[E]** estimate. Signs follow the cost study: “HOME −12” = 12 bytes consumed, “HOME +40” = 40 bytes freed. “Free” = unallocated bytes of the 16 KB HOME
image / 8 KB EXROM image.

Companion reports: `V2_LANGUAGE_CONFORMANCE_REPORT.md` (what is wrong, by test), `V2_INDEPENDENT_Z80_AUDIT.md` (root causes, shrink).

---------------------------------------------------------------------------------------------------------------------------

## 0. Summary

1. **The budget question is settled by one measured change.** Essential with **every fix this study measured** plus the **RST-vector shrink** builds at
   **HOME 741 free / EXROM 482 free [M]** (`study/qualification-final`, `b716d4e`; `make check` rc 0). That is more HOME than the Phase 2D baseline had (565) and
   twice what Essential has today (353). **Enhanced with the same fixes and shrink was built too: HOME 578 / EXROM 233 free [M]**
   (`study/qualification-enh-final`, `162dd59`; `make check` rc 0, corpus identical to Essential-final in every status).
2. **Correctness costs HOME −157 / EXROM −6 / package +2 / RAM +74 [M].** The fixes cover all 6 critical defects, 7 of the 8 high ones (Q-10 is still open, and Q-08 is
   only *mitigated*: a float `FOR` is now a clean error 11 instead of a wrong result) and 9 medium/low ones.
   The single largest item is the `FOR` frame redesign (−102). The temporary-slot fix (Q-02) *saves* 40.
3. **What remains to make V2 complete [E]:**

   | Group | HOME | EXROM |
   |---|---:|---:|
   | Open correctness defects (required) | −156 … −289 | −10 … −20 |
   | Spec MUST-HAVE language gaps (string ordering, short-circuit `AND/OR`) | −50 … −80 | 0 |
   | **Storage goal 2: save/restore the program with its current variables** (§5) | −15 … −30 | −140 … −250 |
   | Optional (`ELSEIF`, bare `NEXT`, `INSTR`, 9 glyphs, D11-DISP …) | −152 … −200 | −40 … −80 |

4. **Projected final configurations (§6), from the measured fixes + RST builds:**

   | Final configuration | HOME free | EXROM free |
   |---|---:|---:|
   | **Essential** + fixes + RST + required + spec + goal 2 | **≈ 342 … 520 [E]** | **≈ 212 … 332 [E]** |
   | **Enhanced** + the same, goal 2 in EXROM | ≈ 179 … 357 [E] | **≈ −37 … +83 [E]** (may not fit) |
   | **Enhanced** + the same, goal 2 in HOME | **≈ −71 … +217 [E]** (may not fit) | ≈ 213 … 223 [E] |
   | **Enhanced**, goal 2 in HOME + the further HOME shrink candidates (§3) | ≈ 141 … 532 [E] | ≈ 213 … 223 [E] |

   **Essential fits with room at every end of the ranges. Enhanced fits only with more shrink.** Its EXROM (233 free with the fixes, measured) cannot take goal 2 at the
   pessimistic estimate. Its HOME can take goal 2 only together with the further HOME shrink candidates (`EMIT_OP` inlining and the rest, [E] +212 … +315).
5. **Reserve policy (§7):** the 350/800 figures are planning targets, not limits. The study recommends a *release* reserve of **≥ 200 HOME / ≥ 150 EXROM** for
   hardware-qualification fixes. Every projected Essential range meets it, through goal 2 and before the optional items. Enhanced meets it only with goal 2 in HOME
   *and* the further shrink candidates, at the middle of their ranges or better.

---------------------------------------------------------------------------------------------------------------------------

## 1. Measured anchor points

| Build | Commit | HOME free | EXROM free | Verification |
|---|---|---:|---:|---|
| Phase 2D baseline | `7ae0599` | 565 | 802 | corpus 619 cases (conformance report) |
| V2 Essential | `0dedab3` `study/combined-essential` | 353 | 488 | corpus |
| V2 Enhanced | `8379ab5` `study/combined-enhanced` | 180 | 239 | corpus |
| Essential + RST shrink | `ff7f0be` `study/qualification-shrink` | **912** (+559) | 488 | `make check`, 38/38, gate 115, arrays 98, defects, prodchecks 19/19, FILL 10/10, corpus identical to Essential |
| Essential + all measured fixes | `b1463c7` `study/qualification-costs` | **196** (−157) | **482** (−6) | `make check` rc 0; corpus with the fixes' markers dropped: §2.2; gate: §2.3 |
| **Essential + fixes + RST** | `b716d4e` `study/qualification-final` | **741** | **482** | `make check` rc 0; corpus and gate: §2.3 |
| Enhanced + all measured fixes | `c461d7c` `study/qualification-enh-final~1` | **23** (−157) | **233** (−6) | corpus identical to Enhanced-final |
| **Enhanced + fixes + RST** | `162dd59` `study/qualification-enh-final` | **578** (+555) | **233** | `make check` rc 0, standalone 38/38; corpus: 551 PASS / 61 XFAIL / 5 FAIL (the same 5 as Essential); gate 113/98/15, FILL 10/10: §2.3 |

Per-commit figures are from `make budget` on each commit's own export. The RST saving measured on top of the fixes is **+545**, against +559 on plain Essential.
The fix branch has 85 `VM_POP`/`VM_POP_COERCE_INT` call sites against 89 (typed pops such as `VM_POP_CHECK_INT` replaced some), and a different set of raise sites.

---------------------------------------------------------------------------------------------------------------------------

## 2. Correctness fixes — measured ledger (Essential base)

### 2.1 Costs

| Commit | Defects | HOME | EXROM | Other |
|---|---|---:|---:|---|
| `ead8885` | Q-01 string compare (0); Q-03 + Q-18 via `VM_RUN_SP` unwind | −11 | 0 | RAM cell `$BED0` |
| `e3356ca` | Q-04 DIM size arithmetic | −8 | −6 | |
| `98b7b5b` | Q-06 (−1), Q-13 (−2), Q-14 (−6), Q-09 (−5), Q-17 stop (0), Q-12 (−4), Q-11 (−16), Q-05 (−18) | −52 | 0 | |
| `602549b` | Q-02 temporaries (shared allocator, 4 slots per kind) | **+40** | 0 | RAM +74; scalar caps 253 → 251 |
| `3eb57e0` + `f0d62ca` | Q-07, Q-08 (mitigation), Q-19, Q-20: `FOR` frame redesign | −102 | 0 | +4 B per active loop on the control stack |
| `b478b31` | Q-27, Q-28 strings printed by length | −12 | 0 | |
| `00cb2a5` | Q-29 SPRITE `MOVE` | 0 | 0 | SPRITE package 832 → 834 |
| `b1463c7` | Q-30 float arguments coerced (0); Q-31 `MID$` 16-bit start (−12) | −12 | 0 | |
| **Total** | 22 defect ids | **−157** | **−6** | package +2, RAM +74 |

The critical set alone (Q-01, Q-02, Q-03, Q-04, Q-18, Q-27/Q-28) is **HOME +9 net** (it frees bytes, because Q-02's shared allocator replaces three inline copies).

### 2.2 Verification on the corpus

Run `qual-runs/costs5` + `supp3` (619 cases, Essential expectations, markers of the 22 fixed ids dropped so each must PASS):
**551 PASS, 61 XFAIL (defects still open, all documented), 5 FAIL, 0 XPASS, 2 N/A [M].** All 5 FAILs are recorded honestly; no expectation was changed:

* `for.float_step`, `for.float_limit`, `for.float_start`, `for.float_var_limit`: Q-08 is **mitigated, not fixed**. A float `FOR` bound is now runtime error 11; before, it was a
  silently wrong loop. The R10.8 matrix says “float STEP accepted”, so this is a behaviour change against a documented capability. Either an owner decision makes `FOR`
  integer-only and documents it (0 B), or float loops are implemented (**[E] HOME −80 … −150**).
* `str.val_big`: Q-17 is **partly fixed**. `VAL` now stops at the first non-digit. `VAL("99999")` still wraps to −31073 (**[E] −10 … −30**).

### 2.3 Gate battery

Identical on `b1463c7` (fixes) and `b716d4e` (fixes + RST) **[M]**: gate 115 PASS, Array Store gate 98 PASS, known-defect suite 15 PASS, FILL 10/10, production checks
17/19, `make check` rc 0. The two failing production checks (`253-vars`, `free-1`) assert the scalar cap and the `FREE` window that the Q-02 fix changes by design
(cap 253 → 251, `FREE` 893). They are left failing until the owner accepts the new capacities. The corpus runs on the two builds agree case for case (0 status, 0 output
differences). Details: conformance report §6.2.

Enhanced, `c461d7c` / `162dd59` **[M]**: gate 113 PASS (Enhanced's own gate has 113 cases), Array Store 98, known-defect 15, FILL 10/10, production checks 17/19 (same two),
`make check` rc 0, standalone 38/38, corpus with the same 5 FAILs and no other change, and every prototype tool passing (conformance report §6.3).

---------------------------------------------------------------------------------------------------------------------------

## 3. Shrink — measured and candidate ledger

| Item | HOME | Status |
|---|---:|---|
| RST vectors `$08 $10 $18 $20 $30` (5 hottest targets, 280 sites) | **+559** on Essential, **+545** on Essential + fixes | **[M]**; speed +0.1 … +0.3 % emulated; all suites pass (audit §4.1) |
| `EMIT_OP_*` stubs inlined as `ld a,N / rst $20` | +150 … +250 | [E], needs RST |
| `CHK_ERR` for `ld a,(COMPILE_ERROR_CODE) / or a / ret nz` (15 sites) | +23 | [E] |
| `VM_PUSH_INT` entry for `xor a / jp VM_PUSH` (20 sites) | +18 | [E] |
| shared `LEFT$/RIGHT$` clamp prologue | +12 … +15 | [E] |
| `VM_TOS_TAG` write-only cell | +6 | [S] |
| `call X / ret` → `jp X` | +3 | [S] |
| **Further HOME candidates** | **+212 … +315** | [E], not assembled |
| EXROM | 0 | no EXROM shrink was searched for beyond the audit's scanner pass. All 8 RST vectors are now used, so EXROM can only reuse the five HOME targets, and it calls none of them |

---------------------------------------------------------------------------------------------------------------------------

## 4. Remaining items (none assembled) — [E]

### 4.1 Open correctness defects (required for release)

| Item | Bank | Cost [E] | Note |
|---|---|---:|---|
| Q-10 float arguments of `SGN SQR RAD DEG` / `SIN COS TAN` / `MOD DIV` | HOME | −80 … −130 | float paths through the calculator; `SIN` already has one |
| Q-15 / Q-16 `INPUT` of decimals / numbers > 32767 | HOME | −25 … −55 | reuse the literal scanner + promotion |
| Q-17 `VAL` > 32767 | HOME | −10 … −30 | promote, or error 64 like a literal |
| D11-EXT `ABS(-32768)`, `-32768/-1`, `DIV(-32768,-1)`, `INT(x>32767)` | HOME | −10 … −25 | |
| Q-21 `CLEAR` inside `FOR` | HOME | −6 … −12 | decision: `CLEAR` ends active loops, or error |
| Q-22 `SQR` of a negative → error | HOME | −5 | |
| Q-23 `STICK(n)` range | HOME | −6 … −8 | |
| Q-24 `CALL` of a plain label | HOME | −10 … −20 | |
| L3 string literal > 31 characters → error | HOME | −4 | |
| D10 float display rounding (4th decimal) | EXROM | −10 … −20 | |
| **Total** | | **HOME −156 … −289; EXROM −10 … −20** | Q-08 float `FOR` (−80 … −150) is excluded: owner decision, §2.2 |

### 4.2 Language gaps the V2 spec marks MUST HAVE (DD-2)

| Item | Bank | Cost [E] |
|---|---|---:|
| String ordering `<> > <= >=`, string comparison inside expressions (L-STR, Q-25) | HOME | −30 … −60 |
| `AND/OR` short-circuit (L-SC) | HOME | −20 |
| **Total** | | **HOME −50 … −80** |

Multi-dimensional arrays (also in DD-2) are not costed here. They are an architecture item (R10.7 array audits), not a completion fix.

### 4.3 Optional

| Item | Bank | Cost [E] |
|---|---|---:|
| `ELSEIF` (L-ELIF) | HOME | −10 … −20 |
| bare `NEXT` (L-NEXT) | HOME | −10 |
| `INSTR` (L-INSTR) | HOME | −40 … −60 (or a package: 0) |
| 9 missing font glyphs (Q-26) | HOME | −72 … −90 (or document: 0) |
| array name as scalar without `(` (N-4) | HOME | −20 |
| D11-DISP: fraction of floats ≥ 32768, values ≥ 2³² | EXROM | −40 … −80 |
| **Total** | | **HOME −152 … −200; EXROM −40 … −80** |

### 4.4 Decisions with no or negligible cost

Integer-only `FOR` (Q-08), `INT` truncation (R10.8 L6), `PLOT` coordinate wrap (DEC-PLOT), `MID$` start 0, `POKE` value range, literal rule L-A vs L-C (L-C [E] HOME −40 … −60),
the default string-array width (DD-1), and the `PACKAGE_ABI.md` slot-15 record wording (drop “NUL”, Q-27/Q-28).

---------------------------------------------------------------------------------------------------------------------------

## 5. Storage goal 2 — save and restore the program **with its current variables**

### 5.1 What exists today [S][M]

* `SAVE "x"` writes `PROG_AREA_START … PROG_END` (source text) only. `SAVE "x" ARRAY a` / `LOAD "x" ARRAY a` move one array of the persistent Array Store.
  The R10.9 bundle increment C2 (`SAVE "x" ALL`: program + Array Store, **[E] EXROM −60 … −110** in R10.9 §5.5) would store **program + persistent arrays only**.
  R10.9 §11.5 already says this is *not* a program-plus-variables snapshot.
* Variables are run-scoped state: `RUN` compiles, carves the run tables from the pool top (`VARS_START … V2_SOURCE_END`: scalars, float table, string table,
  array pointers) and **zeroes them** (`VM_INIT` / `MEM_CLEAR_V2`). Any edit, `LOAD`, `NEW` or `CLEAR` calls `V2_CLEAR_ARRAYS`, which resets the symbol table
  (at `PROG_END`) and the ordinary-array arena (`… ARRAYS_END`) and empties segment 2 (`$E000 … ARR2_END`) [S] `rom/exrom_v2_shell.asm` `V2_CLEAR_ARRAYS`, `MEM_CLEAR_V2`.
* There is no way to start a program without zeroing its variables. There is no `GOTO` from the prompt, and no `CONT`.

### 5.2 What goal 2 requires

1. **Serialise** the variable state: the symbol table, the carved run tables, the ordinary-array arena, segment 2 and the Array Store (or a subset), plus about 16 B of pointers.
   The pointers are `SYM_END_V`, `ARRAYS_END`, `VARS_START`, the six `RT_*` pointers and counts, and `ARR2_END`.
2. **Restore** it at the same addresses. Carving is deterministic for an identical program and symbol table, so a *raw image* can be reloaded in place after
   `LOAD` recompiles the loaded program. The sizes must be verified against the header before anything is committed (D2 failure policy).
3. **Run without zeroing:** a new entry such as `CONTINUE`, or `RUN` with a “variables loaded” flag that the first edit clears. It must skip `VM_INIT`'s clear and
   `ARR_RUN_INIT`'s re-zero. **Owner decision:** what `RUN`, `CLEAR`, `DIM` of an existing array and an edit do to restored variables.
4. **Not captured** (as R10.9 lists): the control stack (`FOR`/`PROC` in progress), `RND` seed, display/attribute state, loaded packages. A snapshot taken
   from the prompt has an empty control stack anyway.

### 5.3 Options and costs [E]

| Option | What it gives | HOME | EXROM | Tape format |
|---|---|---:|---:|---|
| C2 bundle (R10.9) | program + persistent arrays | 0 | −60 … −110 | header `proglen` < `length`, minor `$8101` |
| **G2-A raw snapshot** (recommended) | program + every variable, reloaded in place; valid while the program is unchanged | −15 … −30 (skip-zero flag in `VM_INIT`/`RUN`, flag cleared on edit) | −140 … −250 (`ALL` parsing 10–20, header + 3–4 extra blocks 40–70, load: recompile, size check, receive in place 60–110, failure/rollback 30–50) | one type-0 file, header `proglen` = program bytes, tail = state blob with its own version byte |
| G2-B name-keyed | as A, and survives edits (variables rebound by name and kind) | −15 … −30 | −200 … −350 | per-variable records |

RAM: 0 for A and B, which stream through the existing tape buffer [E]. Test cost: the R10.9 bundle cases plus a variables round trip, a truncated state blob,
an old ROM refusing the new minor, and a load into a changed program.
**Placement:** the code is mostly tape framing and pointer bookkeeping and could live in HOME. That matters for Enhanced (§6).

---------------------------------------------------------------------------------------------------------------------------

## 6. Projection: final configurations

All rows after the first two of each block are **[E]**; ranges add the low and high ends of §4. “Required” = §4.1, “spec” = §4.2, goal 2 = G2-A.

### 6.1 V2 Essential

| Step | HOME free | EXROM free |
|---|---:|---:|
| Essential today | 353 [M] | 488 [M] |
| + measured fixes + RST (`b716d4e`) | **741 [M]** | **482 [M]** |
| − required (§4.1) | 452 … 585 | 462 … 472 |
| − spec MUST HAVE (§4.2) | 372 … 535 | 462 … 472 |
| − goal 2 (G2-A in EXROM) | **342 … 520** | **212 … 332** |
| − every optional item (§4.3) | 142 … 368 | 132 … 292 |
| further HOME shrink candidates (§3) | +212 … +315 | 0 |

### 6.2 V2 Enhanced

**Built and measured** (`study/qualification-enh-final`, from `study/qualification-b` = Enhanced + the test-infrastructure commits). The nine fix commits
cherry-picked without a conflict. I had expected conflicts where the fixes overlap Enhanced's extra code: the compiler's `FOR` handling (N-3 against the `FOR`
redesign) and `VM_PRINT_COMMON` / `OP_PRINT_STR` (multi-item `PRINT` against Q-27/Q-28). There were none textually, and the corpus shows no semantic one:
against unfixed Enhanced, every status change is a case of a fixed defect, and all 11 Enhanced-specific cases (multi-item `PRINT`, prompted `INPUT`, the `FOR` error line) still PASS.
The RST rule was re-applied with `tools/qual/apply_rst_rule.py`.

| Step | HOME free | EXROM free |
|---|---:|---:|
| Enhanced today | 180 [M] | 239 [M] |
| + fixes (`c461d7c`) | **23 [M]** (−157, exactly as on Essential) | **233 [M]** (−6) |
| + RST (`162dd59`) | **578 [M]** (+555) | **233 [M]** |
| − required − spec | 209 … 372 | 213 … 223 |
| − goal 2 in **EXROM** (HOME −15 … −30, EXROM −140 … −250) | 179 … 357 | **−37 … +83** (may not fit) |
| − goal 2 in **HOME** (HOME −155 … −280) | **−71 … +217** (may not fit) | 213 … 223 |
| … and the further HOME shrink candidates (§3, +212 … +315) | 141 … 532 | 213 … 223 |

**Enhanced + fixes alone leaves 23 bytes of HOME.** The fixes are not affordable in Enhanced without the RST shrink (or an equivalent). For Enhanced, goal 2
must not take EXROM. It should be placed in HOME together with further HOME shrink. Alternatively it can be a loadable package (0 ROM, but needs the tape path
to load it first), or EXROM must be shrunk first (not studied).

---------------------------------------------------------------------------------------------------------------------------

## 7. ROM reserve policy

* **The cost study's 350 B (HOME) / 800 B (EXROM) are planning targets, not hard limits** (the brief). The real limit is a build that fits 16 384 + 8 192 bytes, which `make budget`
  enforces.
* **Recommended release reserve: ≥ 200 B HOME and ≥ 150 B EXROM, measured on the release build.** It is sized from evidence:
  * hardware qualification has not happened, and its typical fixes are small (`STICK`'s `B` register 2 B, `BORDER`/port masking, tape-timing constants, the ULAplus reset
    the manual promises);
  * the largest single correctness fix this study measured is 102 B (the `FOR` redesign), and the median is 6 B;
  * a reserve below ~100 B forces every later fix to be paired with a shrink, which is how Q-class defects were left in place before.
* **The reserve should be re-measured, never projected**, at each integration step. An [E] range whose low end falls below the reserve (Enhanced, §6.2) needs a
  measured build before the feature is committed.
* Bytes the RST change frees should go to correctness first (§4.1, §4.2), then goal 2, then the optional items.

---------------------------------------------------------------------------------------------------------------------------

## 8. Next step (recommendation)

1. **Adopt the critical fixes and the RST shrink together.** Apply the nine fix commits of `study/qualification-costs` (with the two test-infrastructure
   commits) and the RST change to whichever prototype set is chosen. Measured: Essential 741/482 (`study/qualification-final`), Enhanced 578/233
   (`study/qualification-enh-final`), `make check` passing on both. In Enhanced the fixes do not fit comfortably without the shrink (23 B HOME left).
2. **Place goal 2 by configuration:** in Essential anywhere; in Enhanced in HOME, together with further HOME shrink, or as a package (§6.2).
3. Owner decisions, in order: integer-only `FOR` (Q-08); the goal-2 semantics (§5.2 point 3); L-A vs L-C; the reserve (§7).
4. Implement §4.1, then L-STR/L-SC, then goal 2 (G2-A), re-measuring after each.


# R10.9 — Updated work sequence (after Phase 1)

**Status:** proposal for owner review. Supersedes §3 "R10.9" of
[`R10_8_PRE_R11_PLAN.md`](R10_8_PRE_R11_PLAN.md); the R10.8 audit documents themselves are not edited.
Phase 1 (regression infrastructure + ABI foundation) is implemented in the working tree and
described in [`R10_9_PHASE1_REPORT.md`](R10_9_PHASE1_REPORT.md). **Nothing below Phase 1 has been
started.** Budgets are *measured* for Phase 1 and **[E]** (estimated, not assembled) for the rest.

## 0. Approved decisions this sequence follows

| # | Decision | Where it lands |
|---|---|---|
| 1 | **Withdrawn (owner correction after Phase 1).** The earlier proposal to retire `SAVE/LOAD … ARRAY` no longer stands. Array persistence is an intentional V2 feature, the designed replacement for `DATA/READ/RESTORE`. Storage goals: program alone; program with its current variables/data; array data independently. Which of the three are implemented is **not assumed** — a separate architecture audit establishes it | step 2.5 (audit first, then repair). Header type 8 and its version word are preserved (Phase 1) |
| 2 | Integer overflow never wraps silently; prefer promotion to float, *if* correctness and ROM cost are demonstrated | step 2.7 is a **costed prototype and proof first**, not an implementation |
| 3 | Strict compilation (unknown token / trailing junk / incomplete expression → error) | step 2.1 |
| 4 | V1 is legacy/build-only; no Fuse suite without explicit approval | unchanged; `make test-legacy` stays out of every gate |
| 5 | Editor key chords provisional until physically tested | R10.10; not in R10.9 |
| 6 | `CLEAR` is corrected in R10.9 (not optional) | step 2.6 |
| 7 | Multi-item `PRINT` / prompted `INPUT`: minimal cost/benefit assessment before the R11 freeze, not implemented | step 2.8 (assessment document only) |
| 8 | Physical hardware validation required before any "hardware qualified" claim | gates 2.3 and R10.9 close; list in the Phase 1 report §6 |

## 1. What Phase 1 changed in the plan

* **S-7 (production-ROM test gap) is closed for the headline paths** — and more cheaply than the
  plan assumed. The real tape receiver can be fed a synthesised EAR stream, so D1/D2 are tested
  *end to end* headlessly (dropout, truncation, SPACE abort, bad flag, bad checksum, VERIFY mismatch).
  The tape fix (step 2.3) therefore needs physical validation only for the analogue path, not for
  its logic.
* **Every R10.8 defect in scope (D1–D9, D11) is a strict expected-failure case** in
  `tools/v2_known_defects.py`; each fix flips its case (XPASS → remove marker → becomes a gate
  test). D10 (float display) is covered by notes, not a case yet. `D6` stays a strict expected failure and now documents a defect to be *repaired*, not a feature to be removed.
* **M-6 (ABI) is done and was bigger than estimated**: an extra finding (ABI-F1: `LPRINT <number>`
  executed stray RAM in production) turned up and is fixed inside the ABI work. HOME cost **0 B**
  (measured), EXROM cost **45 B** (measured).
* **New work items** (small): see §3.

## 2. Remaining R10.9 sequence

| Step | Items | Scope | Gate (all headless unless noted) | Budget [E] |
|---|---|---|---|---|
| **2.0** | owner review of Phase 1 — **done**; both policy questions decided (§4) | — | Phase 1 approved with corrections | — |
| **2.1** | **M-2 → M-3** strict compile + exact error line (D3, D4) | `COMPILE_PROGRAM`/`.after_stmt` terminator check, `)` required, open `FOR` at EOF; lexer line counter; delete the chain walk. New error code "unexpected token" | all 18 `D3-*` cases and the `D4-*` matrix flip XFAIL→PASS (marker removal in the same change); 38/38 + 19/19 + `D3-ok-*` unchanged | HOME +35…+60, EXROM −20…−25 net |
| **2.2** | **M-4 + D5b, M-8** BREAK, edit preservation (D5, D5b, D9) | `VM_BREAK` set by the ISR, polled on backward branches / `PAUSE`; ignore codes < `$20` in `EDITOR_LOOP`; commit-on-navigate; keep buffer on `PROGRAM FULL`. **Pins:** any new sysvar goes in the `$BE84–$BED7` gap — the ABI asserts will fail the build otherwise | `D5*`, `D9*` flip; BREAK test needs no hardware. Physical: BREAK keycap matrix position | HOME +20…+35, EXROM +20…+40 |
| **2.3** | **M-1** tape failure semantics (D1, D2) — **done in Phase 2A** ([`R10_9_PHASE2A_REPORT.md`](R10_9_PHASE2A_REPORT.md); EXROM +62 B measured, HOME 0; physical round trip still owed) | `STORAGE_RECEIVE_BLOCK` success = carry set convention or `scf` at the four failure exits; `V2_LOAD.failed` must not wipe on VERIFY. **Interacts with Phase 1:** keep `STORAGE_LOAD_BAD_VERSION` ($FE) distinct from "touched" ($FF) | `D1-*`, `D2-*` flip; `tape-*`, `abi-*` stay green. **Owner, physical:** SAVE→LOAD→VERIFY of a small and a ≈ 6 KB program on a real recorder, deliberate dropout, SPACE abort, wrong-name tape, a package tape | HOME 0, EXROM −4…+10 |
| **2.4** | **M-9** FILL completeness (D7) | package-only: overflow flag + rescan | the five failing `D7-*` flip; `v2_fill_check.py` 10/10 | package +60…+100 of 229 B spare |
| **2.5** | **Array persistence — architecture-first repair** (D6). *Audit approved (A2); Phase 2A cassette integrity done; **Phase 2B** (HOME-minimal architecture comparison, assembled prototypes) done — [`R10_9_PHASE2B_REPORT.md`](R10_9_PHASE2B_REPORT.md): recommends an EXROM-owned service with eager bind (HOME +39 B free, EXROM −514 B); owner decisions pending; Phase 2C not started.* | **Preceded by a separate read-only architecture audit** (not started, not part of Phase 1): establish which of the three storage modes (program alone / program + current variables / array data independently) exist today, what the intended lifetime of a loaded array is across `RUN`, immediate statements and edits, and what the tape formats must carry. The audit produces the design; only then is a repair planned. No removal of array code is proposed. Header type 8 and its version word stay | the audit document; afterwards `D6-array-load-survives-run` flips (or is replaced by cases the audit defines); `array_save_load` standalone test stays | **not estimated** — depends on the audit |
| **2.6** | **S-1** `CLEAR` (D8) | zero the carved variable/array-pointer block, reset `ARRAYS_END`, **stop clearing packages** | both `D8-*` cases flip | HOME 0…+10, EXROM −6…0 |
| **2.7** | **Decision 2 — study first**: overflow → float promotion (D11) | measure `+ - *` promotion cost on the existing float path and the literal rule (> 32767 → float literal); prove with an exhaustive 16-bit boundary oracle against an exact reference; report cost. **Implement only if the cost fits the floor below and correctness is demonstrated** | `D11-*` cases flip only when implemented | HOME +20…+40, EXROM +10…+20 (to be measured) |
| **2.8** | **Decision 7**: multi-item `PRINT` / prompted `INPUT` assessment | document only: minimal grammar, bytecode/VM cost, interaction with strict compile (2.1 already turns today's silent truncation into an error) | none (no code) | — |
| **2.9** | small related items surfaced by Phase 1 | `U6` display/attribute reset on return to the editor (R10.8 S-5, cheap, covered by `U6-mode1-return`); ABI error-code namespace (A3) as a *minor* ABI addition if wanted | `U6` flips | EXROM +15…+25 |
| **Close** | `make check`, `make test` green with **no XPASS**; `make budget`; budget floors **HOME ≥ 350 B, EXROM ≥ 800 B** (R10.8 proposal, still reachable: Phase 1 left 546 / 1,340); physical tape round trip (§5 of the plan) done or each open item explicitly accepted | | |

Ordering rationale: the ABI is pinned (Phase 1), so HOME-moving changes are now *safe* — they cannot
silently re-break package tapes. 2.1 before 2.2 because the editor status/cursor code shares
`V2_JUMP_TO_ERROR_LINE`. 2.3 is last of the tape-touching steps so its physical validation is one
round trip together with the Phase 1 version check. 2.5 starts with an audit because the correct repair depends on the intended array/variable lifetime, which is a design question. 2.7 is
deliberately a study: decision 2 conditions the change on demonstrated cost and correctness.

## 2a. Projected headroom (measured vs estimated)

The earlier projection assumed −430…−470 B of EXROM from deleting array support. **That saving is
removed** — array persistence stays. Nothing below includes any array-repair cost: step 2.5's size is
unknown until its audit.

**Measured (Phase 1, `make budget`):** HOME 546 B free (unchanged from the R10.7 baseline); EXROM 1,340 B free
(baseline 1,385; Phase 1 cost 45 B).

**Estimated [E] — R10.8 plan figures, not assembled; "use" is bytes added (negative = frees):**

| Step | HOME use | EXROM use |
|---|---:|---:|
| 2.1 strict compile + error line | +35…+60 | −25…−20 |
| 2.2 BREAK, edit preservation | +20…+35 | +20…+40 |
| 2.3 tape failure semantics | 0 | −4…+10 |
| 2.6 `CLEAR` | 0…+10 | −6…0 |
| 2.9 display reset | 0 | +15…+25 |
| **Subtotal (excluding 2.5, 2.7)** | **+55…+105** | **0…+55** |
| 2.7 overflow promotion, *if* the study approves it | +20…+40 | +10…+20 |
| 2.5 array repair | unknown | unknown |

| Projected free after R10.9 [E] | HOME | EXROM |
|---|---:|---:|
| without 2.7 | 441…491 | 1,285…1,340 |
| with 2.7 | 401…471 | 1,265…1,330 |

Both stay above the proposed R10.9 close floors (HOME ≥ 350, EXROM ≥ 800) *before* the unknown 2.5 cost.
R10.10 is not yet affordable on paper without savings: the R10.8 plan estimated R10.10 at HOME +75…+140 and
EXROM +385…+655 (editor work), which with the table above leaves roughly HOME 260…416 and EXROM 630…955, and the
R10.10 close floors are HOME ≥ 250 / EXROM ≥ 500. `IN`/`OUT` (below) and the 2.5 repair are on top of that and
unestimated, so the R10.10 editor figures must be re-measured, not assumed.

## 2b. R10.10 language requirements recorded now

* **`IN(port)` and `OUT port,value` — high priority for R10.10.** Support the full 16-bit Z80 port address
  (`IN (C)`/`OUT (C),r` with `BC` = port, not just the low byte), subject to implementation cost and
  validation. Neither exists in V2 today (R10.8 L9; `STICK` was removed in R10.7 and is a separate item).
  Needed before the R11 language freeze: statement/function syntax, the 16-bit operand range check, and the
  decision whether they live in HOME, EXROM or a package. Validation must include a hardware check of a
  non-`$FE`-mirrored port. Cost is not yet estimated.

## 3. New items found in Phase 1 (not in the R10.8 plan)

| ID | Item | Class | Where |
|---|---|---|---|
| **ABI-F1** | `LPRINT <number>` jumped into EXROM with EXROM paged out | **fixed** in Phase 1 (service slot 14 wrapper; test `pkg-printer-lprint-number`) | `PACKAGE_ABI.md` §3 |
| **ABI-F2** | SPRITE state in HOME sysvars is also written by HOME (`GFX_SPRITE_INVALIDATE`, `MEM_INIT`) | documented + pinned | `PACKAGE_ABI.md` §4 |
| **ABI-F3** | SPRITE uses literal addresses (`$BFB0–$BFBA`) not backed by any assertion | now a named, checked reserved block | `include/v2_package_abi.inc`, checker §3/§6 |
| **ABI-F4** | package error codes 12–20 overlap the VM's namespace; `OP_CALL_EXT` ignores the return status (R10.8 A3) | open; documented | 2.9 optional |
| **T-1** | `LOAD` accepts any well-framed body; the record chain is not validated after receive (R10.8 R3, remainder) | open | R10.10 or a minor format addition |
| **T-2** | policy: pre-R10.9 V2 program tapes (header word `0000` or stale) and stock tapes are refused | decided: keep strict (§4) | |
| **X-1** | the production suites add ≈ 9 minutes to `make test` (99 cases; `make test` is now ≈ 23 min) | tooling | consider a `quick` subset if it hurts |

## 4. Owner decisions (resolved)

1. **Legacy program tapes (T-2): keep strict rejection.** Unversioned pre-R10.9 V2 program tapes and stock tapes
   stay refused (`BAD TAPE VERSION`); no `$0000` compatibility path.
2. **Known-defect suite stays inside `make test`**, strict XPASS detection preserved.

## 5. Physical-hardware checkpoints (unchanged in intent, narrowed by Phase 1)

| When | Test | Why it cannot be headless |
|---|---|---|
| 2.3 | real-recorder SAVE→LOAD→VERIFY; dropout; SPACE abort; wrong-name; a versioned package tape and program tape (the new header words) | analogue path, leader/sync thresholds were calibrated against emulator signal |
| 2.2 | BREAK of a `GOTO` loop; BREAK keycap matrix position | physical matrix |
| R10.10 | typing latency/flicker/chord ergonomics; `MODE 1` return; ULAplus | contention, display, keyboard |
| any | AY `SOUND`, printer `LPRINT/LLIST`, EXROM/Dock paging on a real machine | hardware |

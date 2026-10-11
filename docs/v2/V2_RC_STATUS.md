# 2068-Leap V2 release candidate -- status and handoff

**Start here.** This is the entry document for the V2 release candidate: what was built, where it
is, how it was qualified, what is still open, and what the owner has to decide next.

| | |
|---|---|
| State | **emulator-qualified release candidate, ready for physical TS2068 testing** |
| Branch | `integration/v2-final-rom` in `~/2068-Leap` (worktree `~/2068-Leap-v2-final-rom`) |
| Base | `v2-development` at `7ae0599` (untouched) |
| Merged / pushed | **no** -- both wait for the owner's approval |
| ROM images last changed | `ef81f49`; every later commit is tests or documents |
| Hardware | nothing tried on a real TS2068 yet: **HARDWARE PENDING** (`V2_HARDWARE_CHECKLIST.md`) |

## 1. What the release candidate is

The V2 compiler/VM ROM pair with every qualification fix and owner decision applied:

* all qualification defects fixed except two LOW ones (Q-24, Q-26); float `FOR` (owner decision 1,
  variant D); literal rule L-C (decision 3); exact float display; string relations `< > <= >=`;
  short-circuit `AND`/`OR`; float arguments everywhere; float overflow beyond ~1.7E38 is error 67
  instead of a silently wrong number (RC-1);
* **session variables** (decision 2): `RUN` starts fresh; the variables survive the end of the
  program, `STOP`, BREAK and run-time errors; `:` immediate statements use (and may add to) that
  session; `: GOTO label` resumes at a label; `CLEAR` resets variables but keeps the program and
  the Array Store; `NEW` resets everything; an edit ends the session (`V2_SESSION_VARIABLES.md`);
* **`SAVE "name" ALL`** (decision 2): program + session + Array Store in one ordinary program
  block, restored by `LOAD` only after a block CRC, an identity CRC (exact ROM pair + package
  registry), an address-chain check, an exact-partition check and a check of every saved pointer;
  any failure keeps the program and refuses the variables (`NO VARIABLES`) or, for a corrupt block,
  fails the load (`V2_SAVE_ALL_FORMAT.md`). Tape format minor 1; minor-0 tapes still load.

Intentionally not in V2 (documented, tested as compile errors): `INSTR`, `ELSEIF`, `GOSUB`/`RETURN`,
single-line `IF ... THEN stmt` (only `THEN GOTO`), line numbers -- see `V2_FEATURE_MATRIX.md`.

## 2. Commits on the branch (first parent, after `7ae0599`)

| Commit | What |
|---|---|
| `bb9c990` | integrate V2 Enhanced: combined Enhanced + qualification fixes + RST + float FOR (D) + L-C + Q-32/Q-33 + emit-stub inlining |
| `0e271fb` | integrate the qualification and owner-decision reports and `tools/qual` |
| `3c42a6c` `e951c82` | float arguments for SGN/INT/MOD/DIV/RAD/DEG and SIN/COS/TAN/SQR (Q-10), SQR of a negative (Q-22), D11 boundaries |
| `02ed291` | exact float display (D10, D11-DISP) |
| `d55d636` | shared number parser for literals, VAL, INPUT (Q-15/16/17, L-C) |
| `09fdc2a` `3136322` | string relations, short-circuit AND/OR (L-STR, Q-25, L-SC); oracle precision model |
| `1a395c7` `96787a2` | bare NEXT, N-4, PLOT clamp, STICK range, CLEAR ends loops, L3; shrinks |
| `f8042ab` | session variables |
| `85d59ee` | float overflow is error 67 (RC-1) |
| `d404b57` `6f44b56` `5e5d7b0` | session fixes from the gates (RC-2..RC-4); OP_AND/OR removed; jp->jr; test adaptations |
| `07616e7` | `SAVE "name" ALL` and the space work (RC-5..RC-7) |
| `7d2d59d` | `make qual` in the normal workflow; corpus decisions INSTR / ELSEIF / DD-1 (RC-8) |
| `a91cffe` | the V2 documents |
| `ef81f49` | identity CRC covers the package registry (RC-9) -- **last ROM change** |
| `970dc30` | gate checks follow the packed EXROM slots and format minor 1; battery checks promotion on the RC (RC-10, RC-11) |
| `c57e968` | test-only DIM aliases bound after their handlers (RC-12); the four logical-float corpus cases expect the exact value -- **final test commit** |
| (the commit carrying this file) | documents only: regression report, this status, register and budget updates |

95 commits in all after `7ae0599`, including the merged study branches (`study/proto-enh-shrink2`,
`study/decisions-review` and what they contain).

## 3. Artifacts

`make rc-assets` writes `build/release-v2-rc/`:

| File | |
|---|---|
| `roms/leap_v2_home.bin` | HOME ROM, 16384 bytes, SHA-256 `dddd4cbba2e74e4d260be517499759d9e5d32d016d36644c50b0972549e40dca` |
| `roms/leap_v2_exrom.bin` | EXROM, 8192 bytes, SHA-256 `c180464120cb94af517ae5448c47c86806cb746fdabc83deb73679afb291b527` |
| `roms/leap_v2_zesarux.bin` | both concatenated, for ZEsarUX `--romfile` only, SHA-256 `8c10453dbc5d78896d7c7cb0fa9b8480f53065e0e7e3e1ca2c094ffea839ef20` |
| `packages/v2_package_{mode,sprite,printer,shapes,graphics}.bin`, `packages/v2_{mode,sprite,printer,shapes,graphics}.tzx` | the five packages and their tapes |
| `docs/` | the V2 documents |
| `SHA256SUMS`, `BUILD_INFO.txt` | hashes; commit, budget, identity CRC |

Identity CRC-16 that `SAVE ... ALL` stamps with no package loaded: **`$5E95`** (checked against a
real stamped block, not only computed).

## 4. ROM and RAM

| | Used | Free | Provisional reserve target |
|---|---|---|---|
| HOME | 16330 / 16384 | **54** (+6 in the old KTAB space) | 200 |
| EXROM | 8167 / 8192 | **25** | 150 |

The reserve targets (owner decision 4: provisional hardware-release contingencies, not limits) are
**not met**; the options to restore them, with costs, are in `V2_ROM_RAM_BUDGET.md`. RAM: main pool
`$825A-$A326` (8397 bytes); the pool a program sees is 154 bytes smaller than in R10.7 (Q-02
temporaries 74, session gap 80); 251 numeric + 251 string names; compile zone 302, bytecode area
4011, segment 2 2048 bytes. Nothing in the fixed V2 area moved; new cells `$B82A-$B84A`.

## 5. Qualification (emulator)

Details and logs: `V2_REGRESSION_REPORT.md`.

| Evidence | Result |
|---|---|
| `make test` from a fresh clone (`970dc30`; smoke, standalone, production checks, FILL, production gate, Array Store gate, known defects, SAVE ALL, corpus, session lifecycle) | **1010 cases: 1006 PASS, 2 XFAIL (Q-24, Q-26), 2 N/A, 0 FAIL, 0 XPASS** (47 min) |
| second fresh clone at the final test commit `c57e968` | identical images; `make check`; standalone 40 / 40; corpus 663 PASS, 2 XFAIL, 0 FAIL; lifecycle 23 / 23 |
| study battery on the RC (16 prototype tools incl. editor-redraw diff and 4 exact-arithmetic oracles, 4 x 8476 pairs) | all 16 pass; 0 oracle mismatches; 0 redraw mismatches |
| bytecode identity rc6 -> rc8 / rc5 -> rc6 | 667 / 667 and 663 / 663 identical |
| speed vs the qualified Enhanced build | -0.8 % .. +0.4 % (vs production: see RC-O6) |
| identity CRC in `BUILD_INFO.txt` vs a real `SAVE ... ALL` block | both `$5E95` |

Defects found by this final qualification were all in tests and tools (RC-10, RC-11, RC-12; the
ROM was not changed after `ef81f49`).

## 6. Open defects and limits

From `V2_DEFECT_REGISTER.md`: **Q-24** (LOW, `CALL` of a plain label), **Q-26** (LOW, nine ASCII
glyphs print blank) -- both XFAIL in the corpus; **RC-O1** (cosmetic message for a too-big
literal); **RC-O2..RC-O4** (documented limits of SAVE ALL and of numeric arrays); **RC-O5** (ROM
reserve below target); **RC-O6** (a bare `FOR`/`NEXT` iteration is ~45 % slower than in production,
the measured cost of the Q-07/Q-19/Q-20 fixes; loops with bodies 0.3-1.5 %); **T-3** (15 legacy
component tests in no runner). No open defect is above LOW severity. Found and fixed during the
final qualification, all in tests and tools (no ROM change): RC-10, RC-11, RC-12.

## 7. Hardware

Nothing has been run on a physical TS2068. `V2_HARDWARE_CHECKLIST.md` lists 26 steps (boot and
editor, programs, tape incl. a SAVE ALL power-cycle round trip and a damaged tape) and the
machine-specific risks (EXROM paging, keyboard bounce, tape margins, AY ports), all **HARDWARE
PENDING**.

## 8. Documents

| Document | For |
|---|---|
| `V2_USER_MANUAL.md` | users (examples verified on the RC) |
| `V2_LANGUAGE_REFERENCE.md` | the language, statement by statement |
| `V2_SESSION_VARIABLES.md`, `V2_SAVE_ALL_FORMAT.md` | the two decision-2 features: rules, tape format, checks |
| `V2_FEATURE_MATRIX.md` | V1 vs V2, what is intentionally unsupported |
| `V2_DEFECT_REGISTER.md` | every defect: open, fixed, decided |
| `V2_ROM_RAM_BUDGET.md` | measured space history and reserve options |
| `V2_REGRESSION_REPORT.md` | the test evidence |
| `V2_HARDWARE_CHECKLIST.md` | what to do on the real machine |
| `AUTHORITATIVE_SOURCE.md` | where V2 lives; build and test from a fresh clone |
| `V2_WORKSPACE_CLEANUP_INVENTORY.md` | what can be retired, for approval |
| `V2_SKILLS_RETENTION_REVIEW.md` | skill methods kept / improved / new; the unapplied patch |
| `PACKAGE_ABI.md` | the package interface |

`docs/user_manual.md`, `docs/basic_language_reference.md` and the `.docx` manuals describe V1.

## 9. Skills

Reviewed in `V2_SKILLS_RETENTION_REVIEW.md`. Proposed changes to the shared `~/z80-skills`
(contract checks in `audit-z80`, fixed-point jp->jr and production reachability in `shrink-z80`)
are a patch, **not applied**: `docs/v2/skills_patches/z80-skills-rc-lessons.patch`. No installed
or shared skill was modified.

## 10. Retirement list (nothing deleted)

`V2_WORKSPACE_CLEANUP_INVENTORY.md`: after the merge, the 35 study worktrees under
`~/2068-Leap-study` (~520 MB) can be removed (branches kept or tagged `archive/`), the exported
builds `qual-builds/` (366 MB, all reproducible) deleted, the runs the reports cite archived as one
tarball and the rest deleted, one already-merged agent branch deleted, and finally the RC worktree
removed. Nothing has been deleted, moved or pushed.

## 11. What the owner decides next

1. **Approve the merge** of `integration/v2-final-rom` into `v2-development`, and the push of both
   (nothing is pushed; `v2-development` itself is 3 commits ahead of `origin` from before).
2. **Hardware**: burn `leap_v2_home.bin` / `leap_v2_exrom.bin` and work through
   `V2_HARDWARE_CHECKLIST.md`.
3. **The reserve**: accept 54 / 25 bytes for the hardware release, or choose options from
   `V2_ROM_RAM_BUDGET.md` (each must then be measured).
4. **Cleanup**: approve (or edit) `V2_WORKSPACE_CLEANUP_INVENTORY.md`.
5. **Skills**: review `docs/v2/skills_patches/z80-skills-rc-lessons.patch`.

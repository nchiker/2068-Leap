# 2068-Leap V2 Enhanced — Emulator-Qualified Release: status

**Start here.** This is the entry document for the accepted V2 release: what was built, where it
is, how it was qualified, and what is still open.

| | |
|---|---|
| Designation | **2068-Leap V2 Enhanced — Emulator-Qualified Release** |
| Meaning | the production ROMs passed the documented emulator qualification; the release is reproducible; the accepted limitations are documented; **physical TS2068 compatibility has not been verified** |
| Accepted | by the owner, 2026-10-11 |
| Release source | branch `integration/v2-final-rom`; ROM-producing commit `ef81f49` (every later commit is tests or documents) |
| Authoritative branch | `v2-development` in `~/2068-Leap`, merged and pushed (section 12) |
| Hardware | **NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE** (`V2_HARDWARE_CHECKLIST.md`): deferred, not a release blocker |

## 1. What the release is

The V2 compiler/VM ROM pair ("V2 Enhanced") with every qualification fix and owner decision applied:

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
| `7ecffcf` `a4e4641` `118e148` | documents: regression report, this status, register and budget updates |
| `f4cabad` | the release designation (documents, `BUILD_INFO`) and the closeout integrity check -- **release source** (`integration/v2-final-rom` ends here; `v2-development` fast-forwarded to it) |
| `2c79b44` and the closeout documents (on `v2-development` only) | qualification-tool defaults; handoff, inventory, skills review, authoritative source, README note |

All commits after `7ae0599` (`git log 7ae0599..integration/v2-final-rom`) include the merged study branches (`study/proto-enh-shrink2`,
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

| | Used | Free (accepted reserve) | Bank limit |
|---|---|---|---|
| HOME | 16330 / 16384 | **54** (+6 in the old KTAB space) | `$0000-$3FFF`, end `$3FCA` |
| EXROM | 8167 / 8192 | **25** | `$C000-$DFFF`, end `$DFE7` |

The owner accepted these reserves on 2026-10-11; the provisional 200 / 150 targets of decision 4
are dropped (`V2_ROM_RAM_BUDGET.md` keeps the options, for reference only). RAM: main pool
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
reserve 54 / 25 bytes, accepted); **RC-O6** (a bare `FOR`/`NEXT` iteration is ~45 % slower than in production,
the measured cost of the Q-07/Q-19/Q-20 fixes; loops with bodies 0.3-1.5 %); **RC-O7** (a 3-byte
unreachable EXROM stub found at the closeout, left unchanged); **T-3** (15 legacy
component tests in no runner). No open defect is above LOW severity. Found and fixed during the
final qualification, all in tests and tools (no ROM change): RC-10, RC-11, RC-12.

## 7. Hardware

No physical TS2068 was available. `V2_HARDWARE_CHECKLIST.md` keeps the 26 physical tests (boot and
editor, programs, tape incl. a SAVE ALL power-cycle round trip and a damaged tape) and the
machine-specific risks (EXROM paging, keyboard bounce, tape margins, AY ports) for the future, all
marked **NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE** -- neither passes nor failures.

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
| `V2_DOCUMENTATION_HANDOFF.md` | documentation status, verified gaps, plan for the manual |
| `V2_HARDWARE_CHECKLIST.md` | what to do on the real machine |
| `AUTHORITATIVE_SOURCE.md` | where V2 lives; build and test from a fresh clone |
| `V2_WORKSPACE_CLEANUP_INVENTORY.md` | what can be retired, for approval |
| `V2_SKILLS_RETENTION_REVIEW.md` | skill methods kept / improved / new; the unapplied patch |
| `PACKAGE_ABI.md` | the package interface |

`docs/user_manual.md`, `docs/basic_language_reference.md` and the `.docx` manuals describe V1.

## 9. Skills

Applied at the closeout to `~/z80-skills` (commit `54bc4f2`, local; not pushed -- its remote is
the upstream project): `shrink-z80` (new, validated `production_reachability.py` with a test;
banked-ROM lessons), `audit-z80` (code-change contracts), `develop-z80` (release qualification),
`ts2068-debug` (parallel-suite gotchas). Details, what was not applied and why:
`V2_SKILLS_RETENTION_REVIEW.md`.

## 10. Workspace

Consolidated at the closeout (`V2_WORKSPACE_CLEANUP_INVENTORY.md`): 19 clean, fully integrated study
worktrees removed (branches kept), the 32 exported builds and 21 frozen tree copies removed after
verification (their logs kept), `~/2068-Leap-study` 1.3 GB -> 357 MB. Kept: the release-source
worktree, 16 study worktrees whose branches hold unmerged commits, all run logs, notes and every
branch.

## 11. Owner acceptance (2026-10-11)

Accepted as the V2 Enhanced emulator-qualified release, subject to the release-integrity
verification in `V2_REGRESSION_REPORT.md` section 9 (done: the rebuilt images match the accepted
hashes and the qualified builds byte for byte):

1. the 54-byte HOME and 25-byte EXROM reserve (the provisional 200 / 150 targets are dropped; the
   ROM is not to be changed to recover them);
2. the 154-byte RAM reduction;
3. Q-24 and Q-26 as known LOW limitations;
4. the empty `FOR`/`NEXT` slowdown (RC-O6) as a correctness trade-off;
5. the current feature set as V2 Enhanced.

Hardware qualification is deferred. The merge, push and release-tag record follows in the closeout
section below.

## 12. Closeout record (2026-10-11)

| Action | Result |
|---|---|
| release-integrity check (before the merge) | passed: `V2_REGRESSION_REPORT.md` s9 |
| release designation | commit `f4cabad` on `integration/v2-final-rom` (documents and the `BUILD_INFO` designation only; ROM images unchanged) |
| merge | `v2-development` **fast-forwarded** `7ae0599` -> `f4cabad` (no merge commit, no history rewritten) |
| verification after the merge | fresh clone of `v2-development`: identical images and `SHA256SUMS`, `make check`, `make rc-assets`, `make qual` 663 PASS / 2 XFAIL / 2 N/A / 0 FAIL, lifecycle 23/23 |
| push | `origin` (`github.com/nchiker/2068-Leap`): `v2-development` `6789f36..f4cabad` (fast-forward), `integration/v2-final-rom` new at `f4cabad`; later closeout commits pushed on `v2-development` |
| after the release commit, on `v2-development` | `2c79b44` qualification tools default to an in-repository export root, `build_configs.sh` fixed for the main checkout; then the closeout documents (this section, handoff, inventory, skills review, authoritative source, README release note, RC-O7) |
| release tag | **not created**: the existing tags (`v0.1.0-preview.1`, `v1.0.0-beta.1`, the checkpoint `v2-r10.9-pre-array-store`) do not determine a name for an emulator-qualified release. Recommended: an annotated `v2.0.0-emu.1` on the release source `f4cabad` (semver pre-release, like `v1.0.0-beta.1`; `v2.0.0` kept for a hardware-qualified release): `git tag -a v2.0.0-emu.1 f4cabad -m "2068-Leap V2 Enhanced — Emulator-Qualified Release"` then `git push origin v2.0.0-emu.1` |
| skills | `~/z80-skills` `54bc4f2` (section 9) |
| workspace | section 10 |
| documentation | `V2_DOCUMENTATION_HANDOFF.md`: the manual is authoritative but thin; 13 verified gaps (README examples with line numbers, `LPRINT` is a package statement, packages undocumented, `INPUT` prompts, five missing messages, ...) and a plan for a QL-User-Guide-style manual |

Release identity, for every future reference: HOME SHA-256
`dddd4cbba2e74e4d260be517499759d9e5d32d016d36644c50b0972549e40dca`, EXROM SHA-256
`c180464120cb94af517ae5448c47c86806cb746fdabc83deb73679afb291b527`, identity CRC `$5E95`, built
from `ef81f49` (and every later commit).


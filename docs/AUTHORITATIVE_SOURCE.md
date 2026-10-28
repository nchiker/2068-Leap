# Authoritative source for 2068-Leap V2

**The permanent authoritative repository is `~/2068-Leap`** (Git, remote `origin` =
`https://github.com/nchiker/2068-Leap.git`). Everything needed to build, test and release V2 is in
that repository; nothing outside it is required or authoritative.

## Where V2 is

| What | Where |
|---|---|
| Accepted release | **2068-Leap V2 Enhanced — Emulator-Qualified Release** (owner acceptance 2026-10-11) |
| Authoritative branch | **`v2-development`** (checked out in `~/2068-Leap`, the only active working directory; pushed). It contains the release by fast-forward to `f4cabad` and the closeout commits after it |
| Release source | branch `integration/v2-final-rom` at `f4cabad` (pushed; kept as the record of the release source; its worktree was retired 2026-10-12, the branch and `v2.0.0-emu.1` remain) |
| ROM-producing commit | `ef81f49` -- no production source changed after it (`V2_REGRESSION_REPORT.md` s9) |
| Release tag | **`v2.0.0-emu.1`** (annotated, pushed) -> `f4cabad`; a clean export of it builds the accepted hashes |
| Maintenance release tag | **`v2.0.1-emu.1`** (annotated) on `v2-development`: the sound maintenance release, emulator-qualified, not hardware-qualified (`V2_MAINT_RELEASE_STATUS.md`); `make build EXTRA_DEFS=` on it still builds the `v2.0.0-emu.1` images |
| Compiler maintenance release tag | **`v2.0.2-emu.1`** (annotated) on `v2-development`: the compiler maintenance release, emulator-qualified, not hardware-qualified (`V2_COMPILER_MAINT_RELEASE_STATUS.md`) |
| Current release tag | **`v2.1.0-emu.1`** (annotated) on `v2-development`: the speed and package functions release (the back-port of 2068-Leap-C's improvements, developed on branch `backport/leapc`), emulator-qualified, not hardware-qualified (`V2_1_RELEASE_STATUS.md`) |

`integration/v2-final-rom` contains, by merge, the qualification and owner-decision study work it
was built on (`study/proto-enh-shrink2`, `study/decisions-review` and what they contain).

## What is authoritative inside the repository

| Area | Path |
|---|---|
| HOME ROM source | `rom/v2_home.asm` and what it includes from `rom/`, `kernel/`, `include/` |
| EXROM source | `rom/v2_exrom.asm` and what it includes (compiler, VM core, shell, Array Store, editor, storage) |
| Packages | `rom/v2_package_{mode,sprite,printer,shapes,graphics}.asm` (each includes its `rom/ext_*_module.asm`); ABI `include/v2_package_abi.inc`, documented in `docs/PACKAGE_ABI.md` |
| Build system | `Makefile` (`build`, `v2-packages`, `check`, `budget`, `rc-assets`, `test`, `qual`, `test-prod`) |
| Emulator integration | `tools/v2_prod.py`, `tools/v2_headless.py` (through `ts2068-debug`), `tools/qual/qharness.py` (snapshot harness) |
| Regression and conformance | `tools/run_v2_prod_tests.sh` (gate, Array Store, known defects, SAVE ALL), `tools/v2_production_checks.py`, `tools/v2_fill_check.py`, `tools/run_v2_standalone_tests.sh`, `tools/run_smoke_rom_tests.sh`, `tools/qual/` (corpus, lifecycle, oracles, bytecode identity, benchmark, defect list), `tools/study_*.py` + `tools/qual/run_study_battery.sh` |
| Release artifacts | `tools/make_rc_assets.py` (`make rc-assets`) |
| Current documentation | `docs/V2_RC_STATUS.md` (start here), `V2_USER_MANUAL.md`, `V2_LANGUAGE_REFERENCE.md`, `V2_SESSION_VARIABLES.md`, `V2_SAVE_ALL_FORMAT.md`, `V2_FEATURE_MATRIX.md`, `V2_DEFECT_REGISTER.md`, `V2_ROM_RAM_BUDGET.md`, `V2_REGRESSION_REPORT.md`, `V2_HARDWARE_CHECKLIST.md`, `V2_DOCUMENTATION_HANDOFF.md`, `V2_SKILLS_RETENTION_REVIEW.md`, `V2_WORKSPACE_CLEANUP_INVENTORY.md`, `PACKAGE_ABI.md`, this file |

Not current: `docs/v1/user_manual.md`, `docs/v1/basic_language_reference.md`, the `.docx` files and most
of `docs/*.md` describe the V1 "Release 1 Beta" ROM; `docs/V2_LANGUAGE_SPEC.md` and the `R*`,
`ARCHITECTURE_*`, study and audit documents in `docs/` are historical design and qualification
records (classified in `V2_DOCUMENTATION_HANDOFF.md`). `tools/study/` holds the study's tool copies
as committed for reproducibility; its `*_ablate.py` scripts expect a worktree of their study branch,
which is no longer kept (recreate one with `git worktree add ~/2068-Leap-study/<name> study/<name>`;
the 2026-10-12 consolidation retired `~/2068-Leap-study`). Paths such as `~/2068-Leap-study/...`,
`~/2068-Leap-v2-development` in the historical study and audit reports describe where that work
was done at the time; none is a current location.

The `*.bin` files in the repository root are ignored scratch outputs of the assembler (some are
stale); the release images are `build/test_basic.bin` (HOME), `build/exrom.bin` (EXROM),
`build/ts2068rom_zesarux.bin` and, after `make rc-assets`, `build/release-v2-rc/roms/`.

## Building, testing and regenerating the release from a fresh checkout

Requirements: `sjasmplus` 1.23.1, Python 3 (3.12 used), `zip`; for the emulator suites
`ts2068-debug` (`python3 -m pip install -e ~/ts2068-debug`) and ZEsarUX 13.0 at
`~/Applications/ZEsarUX-13.0` (the path `tools/qual/qharness.py` and `ts2068-debug` use). Fuse is
needed only by `make test-legacy` (V1 tests under X11).

```
git clone https://github.com/nchiker/2068-Leap.git leap && cd leap   # or: git clone ~/2068-Leap leap
git checkout v2-development        # or the release itself: git checkout v2.0.0-emu.1
make build v2-packages        # build/test_basic.bin (HOME), build/exrom.bin, the five packages
make check                    # assemble/lint/ABI/doc checks, no emulator
make budget                   # HOME 54 / EXROM 25 bytes free
make rc-assets                # build/release-v2-rc/: ROMs, packages, docs, SHA256SUMS, BUILD_INFO
make test                     # all headless emulator suites, ends with make qual (~47 min)
make qual                     # language corpus (667) + session lifecycle alone (~5 min)
```

Expected: `build/release-v2-rc/roms/leap_v2_home.bin` SHA-256
`dddd4cbba2e74e4d260be517499759d9e5d32d016d36644c50b0972549e40dca`,
`leap_v2_exrom.bin` `c180464120cb94af517ae5448c47c86806cb746fdabc83deb73679afb291b527`,
identity CRC `$5E95` in `BUILD_INFO.txt`.

Comparing builds (exports of commits into the ignored `build/qual-builds/`):
`tools/qual/build_configs.sh "" name=<ref> ...`, then `tools/qual/qbytecode.py`, `qbench.py`,
`qrun.py --cfg`, `tools/qual/run_study_battery.sh build/qual-builds/<name> <port> <outdir>`. For a
compiler change meant to be output-neutral, also `tools/qual/qdiff.py` (full-RAM differential with
generated and error-path programs) and `tools/qual/qcov_changed.py` (did that corpus execute every
changed instruction): `docs/TESTING.md`, "Proving a compiler change leaves its output unchanged".

**Verified independent of the study directories** (2026-10-11): a fresh clone of `v2-development`
(`f4cabad`) builds byte-identical release images, passes `make check`, `make rc-assets`
(`SHA256SUMS` identical to the qualified release's) and `make qual` (663 PASS, 2 XFAIL, 2 N/A,
0 FAIL; lifecycle 23/23); full `make test` from fresh clones: `V2_REGRESSION_REPORT.md` s2. No
Makefile target, script default or test reads anything under `~/2068-Leap-study`.

## Historical evidence and retired workspaces

`~/2068-Leap` is the only active 2068-Leap working directory (workspace consolidation,
2026-10-12). Every other directory was retired after its unique contents were verified in an
archive or in Git; all local branches and tags were kept.

| Where | What | Status |
|---|---|---|
| `study/*` branches (local, in `~/2068-Leap`) | every qualification, cost-study and prototype branch; 17 of them hold commits that are on no remote and **must not be pruned** | kept (historical record); no worktrees; recreate one with `git worktree add <dir> study/<name>` |
| `docs/` study reports | the qualification, cost and owner-decision reports | kept in the repository |
| `~/2068-Leap-backups/v2.0.0-emu.1-qualification-evidence/` | the verified archive of the v2.0.0 qualification evidence (run logs, study notes and tools, the release artifact set) with `MANIFEST.md` and its SHA-256 | kept outside the repository |
| `~/2068-Leap-backups/*-20261012.*`, `MANIFEST-workspace-consolidation-20261012.md`, `SHA256SUMS-20261012.txt` | the consolidation archives: a `git bundle --all` of this repository (all 59 refs, including the commits on no remote), bundles of `~/z80-skills`, `~/ts2068-debug` and the former Preview clone, the maintenance-release qualification logs, the study leftovers, the upgraded `z80sim` | kept outside the repository |
| `~/z80-skills`, `~/ts2068-debug` | independent shared repositories (Z80 skills; the ZRCP debugger/test controller that `make test` and `make qual` use) with local commits that are not pushed upstream | kept in place, independent of this repository; bundled as above |
| `~/2068-Leap-Preview` | the public download mirror `nchiker/2068-Leap-Preview` | local clone retired; `tools/sync_to_preview.sh` re-creates it from GitHub when needed |

What was removed, and why the rest remains: `V2_WORKSPACE_CLEANUP_INVENTORY.md`.

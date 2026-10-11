# Authoritative source for 2068-Leap V2

**The permanent authoritative repository is `~/2068-Leap`** (Git). Everything needed to build,
test and release V2 is in that repository; nothing outside it is required or authoritative.

## Where V2 is, today

| What | Where | State |
|---|---|---|
| The release candidate | branch `integration/v2-final-rom` of `~/2068-Leap` (checked out in the worktree `~/2068-Leap-v2-final-rom`) | complete, emulator-qualified, **not merged, not pushed** (awaiting the owner) |
| The production line it starts from | branch `v2-development` (`7ae0599`), checked out in `~/2068-Leap` | untouched by the RC work; 3 commits ahead of `origin/v2-development` from before this work |
| Remote | `origin` (GitHub) | nothing of the RC has been pushed |

Once the owner approves, the intended path is: merge `integration/v2-final-rom` into
`v2-development` (a fast-forward-free merge keeps the history readable), push both, then retire the
worktree `~/2068-Leap-v2-final-rom` (`git worktree remove`). The RC branch contains, by merge, the
qualification and owner-decision study work it is built on (`study/proto-enh-shrink2`,
`study/decisions-review`), so those branches need not be merged separately.

## What is authoritative inside the repository

| Area | Path |
|---|---|
| ROM source | `rom/` (V2 images: `rom/v2_home.asm`, `rom/v2_exrom.asm` and what they include), `kernel/`, `include/` |
| Packages | `rom/v2_package_*.asm`, ABI `include/v2_package_abi.inc` |
| Build | `Makefile` (`build`, `v2-packages`, `check`, `budget`, `rc-assets`) |
| Tests | `make test` (smoke ROMs, standalone component tests, production checks, FILL, the production gates incl. SAVE ALL, then `make qual`: corpus + session lifecycle); `tools/qual/` (corpus, harness, oracles, bytecode identity, defect list); `tools/study_*.py` (study battery, `tools/qual/run_study_battery.sh`) |
| Language and release documents | `docs/v2/V2_*.md`, `docs/v2/PACKAGE_ABI.md`, this file |

`docs/user_manual.md`, `docs/basic_language_reference.md` and the `.docx` files describe the V1
"Release 1 Beta" ROM; for V2 they are superseded by `docs/v2/V2_USER_MANUAL.md` and
`docs/v2/V2_LANGUAGE_REFERENCE.md`.

## Building and testing from a fresh checkout

Requirements: `sjasmplus` 1.23.1, Python 3 (3.12 used), `zip`; for the emulator suites
`ts2068-debug` (`python3 -m pip install -e ~/ts2068-debug`) and ZEsarUX 13.0 at
`~/Applications/ZEsarUX-13.0` (the path `tools/qual/qharness.py` and `ts2068-debug` use). Fuse is
needed only by `make test-legacy` (V1 tests under X11).

```
git clone ~/2068-Leap leap-v2 && cd leap-v2
git checkout integration/v2-final-rom
make build v2-packages        # build/test_basic.bin (HOME), build/exrom.bin, packages
make check                    # assemble/lint checks, no emulator
make budget                   # HOME 54 / EXROM 25 bytes free
make test                     # headless emulator suites, ends with make qual (~47 min)
make qual                     # corpus (RC expectations) + session lifecycle alone (~5 min)
make rc-assets                # build/release-v2-rc/: ROMs, packages, docs, SHA256SUMS, BUILD_INFO
```

None of the study directories, exported builds or logs under `~/2068-Leap-study` is needed for any
of these (verified from a fresh clone: `V2_RC_STATUS.md`).

## What is not authoritative

| Path | What it is |
|---|---|
| `~/2068-Leap-study/*/` | Git worktrees of the historical `study/*` branches (qualification study, owner-decision review, prototypes); their content that mattered is merged into the RC |
| `~/2068-Leap-study/qual-builds/`, `qual-runs/` | exported builds (`git archive` + build) and logs of the qualification and RC runs |
| `~/2068-Leap-study/NOTES.md`, `tools/` | the study's running notes and one-off scripts |
| `~/2068-Leap-Preview` | a mirror repository of an older 2068-Leap state (Release 1 Beta preview) |
| `~/2068-Leap-C`, `~/2068-Leap-backups` | other investigations / bundles |

Their fate is listed, for the owner's approval, in `V2_WORKSPACE_CLEANUP_INVENTORY.md`.

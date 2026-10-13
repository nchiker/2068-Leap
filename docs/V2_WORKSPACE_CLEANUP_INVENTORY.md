# V2 workspace cleanup inventory

Closeout of 2026-10-11, after the release was merged into `v2-development` and pushed. Rule
applied (owner authorization): remove only **verified disposable generated artifacts** and **clean,
fully integrated study worktrees**, with `git worktree remove` (never `--force`); keep every branch,
every unique commit, untracked source and every file of uncertain ownership. (The earlier version
of this file was the proposal; this is the record.)

## Removed

| What | Size | Verification before removal |
|---|---|---|
| 19 study worktrees under `~/2068-Leap-study/`: `bare-ident`, `break`, `bugfix-callfn`, `combined-enhanced`, `d11-promote`, `d11-promote-lit`, `decisions-review`, `edit-preserve`, `eof-for-line`, `fill-d7`, `flicker-i2`, `lang-hw`, `list-abort`, `proto-enh-shrink2`, `qualification-a`, `qualification-b`, `qualification-enh-final`, `report`, `u6-display` | ~260 MB | each clean (no modified or untracked files); its branch tip contained in `v2-development`; its ignored files only `build/`, root `*.bin` and `__pycache__` (no logs or results). Removed with `git worktree remove`; **all 19 branches kept** |
| `~/2068-Leap-study/qual-builds/` (32 exports) | 393 MB | every export's commit (`QUAL_COMMIT`) reachable from a kept branch; no file in any export outside its commit's tree except build outputs; each reproducible with `tools/qual/build_configs.sh`. Its 32 `qual_budget.log`/`qual_build.log` + `QUAL_COMMIT` were copied (and compared) to `qual-runs/qual-builds-logs/` first |
| 20 `tree/` copies inside `~/2068-Leap-study/qual-runs/*/` and the tree copy `qual-runs/standalone-rc3/` | ~260 MB | frozen copies of exports used by the gate and battery runs; every commit reachable; the one file not in its commit (`a3-essential/tree/tools/qual_vm_oracle_fmtfix.py`) was preserved as `qual-runs/a3-essential/qual_vm_oracle_fmtfix.py`; every run log kept |
| this session's scratch clones (`/tmp/claude-*/.../scratchpad/fresh*`, the exports of the FOR bisect) | ~280 MB | temporary verification copies; their results are in `qual-runs/` |

`~/2068-Leap-study` went from ~1.3 GB to 357 MB.

## Final housekeeping (2026-10-11, after the release tag)

| Action | Result |
|---|---|
| qualification evidence archived | `~/2068-Leap-backups/v2.0.0-emu.1-qualification-evidence/2068-Leap-v2.0.0-emu.1-qualification-evidence-2026-10-11.tar.xz` (1.5 MB; SHA-256 `f635e9d35fec7bf76b7125f3b5ada0db18b71576b4e9c918d41391e5e5f09cf7` in the `.sha256` beside it; `MANIFEST.md` describes it): all 511 run-log files of `qual-runs/` (incl. the export build/budget logs), the study's `NOTES.md` and `tools/`, and the release artifact set of `f4cabad` (ROMs, packages, `SHA256SUMS`, `BUILD_INFO.txt`). Excluded: 183 `state*` directories (emulator session files). Verified by extracting and comparing every file with the originals; the originals are **kept** |
| orphaned emulators | the three ZEsarUX processes on ports 10271, 10281, 10282 (started 2026-10-10, parent PID 1, no client connected) were ts2068-debug sessions of the completed cost-study job `1a79d5ac` (`state.json`: done, nothing in flight); stopped through their own sessions (`ts2068-debug stop`); no emulator is left running |
| worktrees and branches | unchanged: 16 study worktrees with unique commits, the release worktree, all 42 branches |

## Retained, and why (as of 2026-10-11; superseded by the consolidation below)

| What | Size | Why kept | Later (needs owner approval) |
|---|---|---|---|
| `~/2068-Leap` (`v2-development`) | -- | the authoritative repository | -- |
| `~/2068-Leap-v2-final-rom` (worktree of `integration/v2-final-rom`) | 28 MB | the release-source worktree; kept until the final handoff is accepted (owner instruction) | `git worktree remove ~/2068-Leap-v2-final-rom` (the branch stays, also on `origin`) |
| 16 study worktrees: `baseline`, `combined-essential`, `d11-error`, `extfn`, `flicker-i1`, `flicker-i1b`, `lang-hw-exrom`, `lang-print`, `proto-enh-decisions`, `proto-float-for` (17 commits not in `v2-development`), `proto-lc` (20), `proto-shrink2` (21), `qualification-costs` (12), `qualification-final` (13), `qualification-shrink` (2), `shrink-pos` (one each for the rest) | ~270 MB | **not fully integrated**: their branches hold commits that are not in `v2-development` (alternative variants, the Essential line, ablations). All are clean, so removing a worktree would lose nothing -- the branch keeps the commits -- but that is outside this closeout's authorization | `git worktree remove` each (branches stay); optionally tag them `archive/<name>` first |
| `~/2068-Leap-study/qual-runs/` | 85 MB | archived and verified (above); the original directory is kept too. The qualification evidence: logs and JSONL of every corpus, gate, battery, benchmark, bytecode and fresh-clone run; cited by `V2_REGRESSION_REPORT.md` (`fresh-970dc30`, `fresh-c57e968`, `fresh-v2dev-f4cabad`, `qual-final`, `gate-rc6`, `battery-rc8`, `bytecode-rc6-rc8`, `bytecode-rc5-rc6`, `bench-rc8`) and by the study reports | may now be deleted (the archive is verified): `rm -r ~/2068-Leap-study/qual-runs` |
| `~/2068-Leap-study/NOTES.md`, `~/2068-Leap-study/tools/` | small | the study's running notes and one-off scripts; in no repository (unique) | archived with the run logs; originals kept |
| 42 local branches: 35 `study/*`, `integration/v2-final-rom`, `v2-development`, `main`, `feature1-alone`, `feature2-alone`, `worktree-agent-a481c44e9ba966c5c`, `worktree-agent-a0a2286569ceed7e3` | -- | branch deletion was not authorized; `worktree-agent-a0a2…` is already merged, `feature*-alone` and `worktree-agent-a481…` are unmerged WIP measurements of 2026-09-27 | delete `worktree-agent-a0a2…`; decide on the WIP branches |
| `~/2068-Leap-Preview` | 8.5 MB | a mirror repository of the Release 1 Beta preview; not part of V2 | owner |
| `~/2068-Leap-C` | 40 KB | an unrelated investigation | owner |
| `~/2068-Leap-backups` | 3.1 MB | a Git bundle of `v2-development` before the Array Store work (a safety copy) | keep |
| ignored `*.bin` files in the root of `~/2068-Leap` | small | assembler scratch outputs (some stale, e.g. `test_basic.bin` of 2026-10-04); ignored by Git; an external emulator configuration might point at them | `git clean -n -X` to review, then remove if wanted |

## Where the historical evidence is

* Code and history: the `study/*` branches in `~/2068-Leap` (and the merged history of
  `v2-development`).
* Reports: `docs/` (qualification, cost study, owner-decision review, independent audit,
  regression report, defect register).
* Run logs: the verified archive in `~/2068-Leap-backups/v2.0.0-emu.1-qualification-evidence/` (and the original `~/2068-Leap-study/qual-runs/`).
* Release record: `docs/V2_RC_STATUS.md`, `V2_REGRESSION_REPORT.md`, `AUTHORITATIVE_SOURCE.md`.

## Workspace consolidation (2026-10-12)

Owner-approved after the sound maintenance release (`v2.0.1-emu.1`). Result: **`~/2068-Leap` is the
only active 2068-Leap working directory**, checked out on `v2-development` at `38339f0` (equal to
`origin/v2-development`; tags `v2.0.0-emu.1` and `v2.0.1-emu.1`, the GitHub releases and their
assets were not touched). Every worktree was verified clean immediately before removal and removed with
`git worktree remove` (never `--force`). No branch, tag or commit was deleted or rewritten (59 refs
before and after); nothing was pushed.

### Preserved before anything was removed (`~/2068-Leap-backups/`, `MANIFEST-workspace-consolidation-20261012.md`)

| File | SHA-256 |
|---|---|
| `2068-Leap-all-refs-20261012.bundle` (`git bundle --all`: 59 refs, incl. the 36 commits on no remote) | `009186153fb5ab7fa773fc1b23b6088da8b2d839d4107ae7310ab7d5e3e02650` |
| `z80-skills-all-refs-20261012.bundle` (2 unpushed commits) | `9beccf7561887b1f1d130899d18e00fb39721b5191edcdc63e9ad0304460a945` |
| `ts2068-debug-all-refs-20261012.bundle` (3 unpushed commits) | `87fb1e9312ff46f7bb2399d3fc5cf701edd977fa14541ca6c5f5217c9dfe16e8` |
| `2068-Leap-Preview-all-refs-20261012.bundle` | `ec88f71141503291e06ddf837cbe796324e7581142f6d0c9f1cf3b95383abbbb` |
| `2068-Leap-maintenance-evidence-20261012.tar.xz` (maintenance-release logs, `build/qual/*.jsonl`, the `release-v2-rc` asset set of `v2.0.0-emu.1`) | `cf8b65f7e29909d8074c45443a9ae89d7f5904d14ee0c6c0e91a50937c1522fd` |
| `2068-Leap-study-leftovers-20261012.tar.xz` (`qual-runs/`, `NOTES.md`, `tools/`) | `6da2842dfbe313bbca695faa1ee27ed8e775cbb616da113c6b25c1abc72d22d9` |
| `z80SimUpgrade-20261012.tar.xz` (the upgraded Z80 simulator and its tests) | `4cf8de1bf9f77d9808508fbcb605f74efe3792bba1148481f46f3981f29aeae6` |
| `repo-local-configs-20261012.tar.xz` (`.git/config` of this repository and of the Preview clone) | `66df2a28fad31c221239d3f1c7fb8e5377c52ef325c106c1a604b491a105108d` |

Verification: each bundle passes `git bundle verify`, mirror-clones, has every ref identical to its
source and passes `git fsck`; every commit of this repository that is on no remote is in its bundle;
each archive was extracted and compared with its source (identical).

### Removed

| What | Verification before removal |
|---|---|
| 19 study worktrees (`ay-beep`, `baseline`, `beep-compat`, `classicbeep`, `combined-essential`, `d11-error`, `extfn`, `flicker-i1`, `flicker-i1b`, `lang-hw-exrom`, `lang-print`, `proto-enh-decisions`, `proto-float-for`, `proto-lc`, `proto-shrink2`, `qualification-costs`, `qualification-final`, `qualification-shrink`, `shrink-pos`) | clean; ignored files were build outputs, `__pycache__` and `build/qual/*.jsonl` (archived); **all branches kept** (17 hold commits that are on no remote, now also in the bundle) |
| `~/2068-Leap-v2-development` (worktree of `v2-development`) | clean; branch equals origin; its ignored `build/maint-qual/` and `build/qual/` archived |
| `~/2068-Leap-v2-final-rom` (worktree of `integration/v2-final-rom`) | clean; branch pushed; its `build/release-v2-rc/` archived (same `SHA256SUMS` as the v2.0.0 evidence archive) |
| `~/2068-Leap-study/qual-runs`, `NOTES.md`, `tools/` | archived and compared; `NOTES.md` equals `V2_FEATURE_COST_STUDY_NOTES.md`, `tools/` equals `tools/study/` |
| `~/2068-Leap-Preview` (independent clone of `nchiker/2068-Leap-Preview`) | clean; local `main` = GitHub `main` (`04f0608`); all 92 commits found in a fresh mirror clone of GitHub; local config archived. `tools/sync_to_preview.sh` now clones it from GitHub when absent |

### Deliberately left in place

| What | Why |
|---|---|
| `~/z80-skills`, `~/ts2068-debug` | independent shared repositories (not vendored; unpushed commits bundled; no upstream push); `make test`/`make qual` use `ts2068-debug` |
| `~/z80SimUpgrade` | the upgraded `z80sim`, not yet integrated (next development task); archived as above |
| the 59 refs, including every `study/*`, `feature*-alone` and `worktree-agent-*` branch and the local tag `latest` (older than the remote `latest`) | branch/tag deletion not authorized; local-only commits live only here and in the bundle |
| `~/2068-Leap-backups` | the offline archive, not a working directory |
| `~/2068-Leap-study` (empty directory) | it was the working directory of the Claude session that performed the consolidation; remove it with `rmdir ~/2068-Leap-study` |
| `~/2068-Leap-C`, `~/2068-Leap_Release_1_Beta_Announcement.docx` | not part of this workspace (unrelated investigation; V1 announcement) |


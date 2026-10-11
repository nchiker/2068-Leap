# V2 workspace cleanup inventory (for the owner's approval)

**Nothing listed here has been deleted, moved or rewritten.** This is the proposal; deletion
happens only after explicit approval, item by item or in groups. The authoritative repository is
`~/2068-Leap` (`AUTHORITATIVE_SOURCE.md`). Sizes measured 2026-10-11.

## A. Git refs in `~/2068-Leap`

Branches are cheap (references only); the recommendation is to keep every study branch, or to
replace each by an `archive/...` tag before deleting the branch, so that no investigated
alternative is lost.

| Branch | In the RC by merge? | What it is | Recommendation |
|---|---|---|---|
| `integration/v2-final-rom` | -- | the release candidate | keep; merge into `v2-development` after approval |
| `v2-development` | base | production line (3 unpushed commits from before this work) | keep |
| `main` | yes | older line, 69 commits ahead of `origin/main` | keep (owner decides its role) |
| `study/combined-enhanced`, `study/proto-enh-shrink2`, `study/decisions-review`, `study/qualification-a`, `-b`, `-enh-final`, `study/report`, `study/bare-ident`, `study/break`, `study/bugfix-callfn`, `study/d11-promote`, `study/d11-promote-lit`, `study/edit-preserve`, `study/eof-for-line`, `study/fill-d7`, `study/flicker-i2`, `study/lang-hw`, `study/list-abort`, `study/u6-display` | yes | the work the RC is built on | keep as history, or tag `archive/<name>` and delete the branch |
| `study/baseline`, `study/combined-essential`, `study/qualification-final`, `study/qualification-costs`, `study/qualification-shrink`, `study/proto-shrink2`, `study/shrink-pos`, `study/proto-float-for`, `study/proto-lc`, `study/proto-enh-decisions`, `study/d11-error`, `study/extfn`, `study/flicker-i1`, `study/flicker-i1b`, `study/lang-hw-exrom`, `study/lang-print` | no | measured alternatives, the Essential configuration, prototypes whose results were re-implemented in the RC | keep or tag `archive/<name>` (the study reports cite their commits) |
| `feature1-alone`, `feature2-alone`, `worktree-agent-a481c44e9ba966c5c` | no | WIP measurements from 2026-09-27 (status/line indicator, full-screen error fix) | owner to judge; tag before any deletion |
| `worktree-agent-a0a2286569ceed7e3` | yes | already merged (post-R9 test infrastructure) | safe to delete after approval |

## B. Worktrees and directories

| Path | Size | What | Recommendation |
|---|---|---|---|
| `~/2068-Leap-v2-final-rom` | 27 MB | worktree of the RC branch | keep until the merge; then `git worktree remove` |
| `~/2068-Leap-study/<35 worktrees>` | 9-25 MB each (~520 MB) | worktrees of the `study/*` branches | remove the worktrees (`git worktree remove`, branches stay) -- nothing in them is needed to build or test |
| `~/2068-Leap-study/qual-builds/` | 366 MB | exported builds of study and RC commits (`QUAL_COMMIT` in each) | delete: every one is reproducible with `tools/qual/build_configs.sh` |
| `~/2068-Leap-study/qual-runs/` | 331 MB | logs and JSONL of every corpus / gate / battery run | archive the runs the reports cite (`fresh-970dc30`, `fresh-c57e968`, `qual-final`, `gate-rc6`, `battery-rc8`, `bytecode-rc6-rc8`, `bytecode-rc5-rc6`, `bench-rc8` for `V2_REGRESSION_REPORT.md`; the study runs cited by `V2_LANGUAGE_CONFORMANCE_REPORT.md`, `V2_OWNER_DECISIONS_REVIEW.md` and `V2_INDEPENDENT_Z80_AUDIT.md`) as one tarball, delete the rest |
| `~/2068-Leap-study/NOTES.md`, `tools/` | small | the study's running notes, one-off ablation scripts | copy `NOTES.md` into the archive tarball; the scripts are superseded by `tools/qual/` |
| `~/2068-Leap-Preview` | 8.5 MB | mirror repository of the Release 1 Beta preview | not part of V2; keep (owner) |
| `~/2068-Leap-C` | 40 KB | an unrelated investigation directory | not part of V2; owner |
| `~/2068-Leap-backups` | 3.1 MB | a Git bundle of `v2-development` before the Array Store work, with its checksum | keep (a safety copy) |

## C. Untracked and generated files

* `~/2068-Leap-v2-final-rom/build/` (generated, ignored by Git): rebuildable; `build/release-v2-rc/`
  holds the RC artifacts (`make rc-assets`).
* Session scratch (`/tmp/claude-*`): temporary; not referenced by anything.
* `~/2068-Leap` (`v2-development` checkout): clean, no untracked files.

## D. Suggested order, once approved

1. Merge the RC into `v2-development`; push.
2. Tag the `study/*` branches `archive/...` (or keep them); delete the merged `worktree-agent-a0a2...`.
3. Archive the cited `qual-runs` and `NOTES.md` into one tarball beside `~/2068-Leap-backups`.
4. `git worktree remove` the study worktrees; delete `qual-builds` and the uncited `qual-runs`.
5. Remove the RC worktree.

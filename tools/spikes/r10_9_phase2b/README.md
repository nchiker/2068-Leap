# R10.9 Phase 2B — Array Store architecture prototypes

**Not part of any build target and not production code.** (Phase 2C implemented architecture C in `rom/exrom_v2_arrstore.asm`; the production code differs from these prototypes — see `docs/R10_9_PHASE2C_REPORT.md` §8 for the defects the prototype had, e.g. the `count >= 8` validator bug and the header write past `ARR2_LIMIT`. Do not re-apply the `mk_*.py` scripts to the current tree.) These are the measurement prototypes and probes behind
[`docs/R10_9_PHASE2B_REPORT.md`](../../../docs/R10_9_PHASE2B_REPORT.md). Nothing here is assembled by `make`, `make check` or `make test`.

## How a prototype is applied

Every `mk_*.py` patches a **disposable** worktree of `2aff9b2` (never the real tree) and `build.sh` then runs `make budget` there:

```bash
git worktree add --detach /tmp/wt 2aff9b2
WT=/tmp/wt tools/spikes/r10_9_phase2b/build.sh mk_fullopt.py copt2    # architecture C, full feature  (the report's numbers)
WT=/tmp/wt tools/spikes/r10_9_phase2b/build.sh mk_fullopt.py bopt2    # architecture B
WT=/tmp/wt tools/spikes/r10_9_phase2b/build.sh mk_fullopt.py aopt2    # architecture A
# aopt/bopt/copt (no "2") are the same with the forward bind (walk store entries, SYM_FIND each) -- slower at RUN start
```

`build.sh` resets `rom include tools` in `$WT` before every run, so variants never stack. `make v2-packages` must be run in the worktree before the production gate suite.

## Variants and the report numbers they produce

| Script | Variant | Report table |
|---|---|---|
| `mk_a.py`, `mk_b.py`, `mk_ce.py` | A / B / C, first-cut code, differential only (no loader/saver) | §4.2 first table |
| `mk_vc.py` | C with **lazy** bind (`exrom_v2_arrstore_vc.asm`) | §4.2, §4.4 |
| `mk_cplus.py` | C plus the allocation cores moved verbatim into EXROM | §4.2, §4.3 |
| `mk_full.py ce` | C first cut with the common loader/saver (`exrom_v2_arrstore_loader.asm`) | §4.2 second table |
| `mk_fullopt.py aopt2|bopt2|copt2` | A / B / C, tightened, full feature, **reverse bind** (`*_aopt2.asm`, `*_bopt2.asm`, `*_copt2.asm` + `*_copt_loader.asm`) | §1, §4.2, §6 |
| `mk_fullopt.py aopt|bopt|copt` | same with the forward bind (first tightening pass) | §4.2 ("pass 1"), §5.1 |

`common.py` holds the shared patch helpers (fixed-address slots, `PAS_END`/`PAS_LEN`, shell edits, crossbank names).

## Probes (run from the worktree root, isolated emulator state)

```bash
export TS2068_DEBUG_STATE_DIR=$(mktemp -d) TS2068_V2_PORT=10931
python3 /path/to/probe_store.py     # hand-built store: adopt, D6 shape, mismatch, string, overflow, D12   (tightened C)
python3 /path/to/probe_loader.py    # LOAD/SAVE ... ARRAY into/from the store, replace, 11 corrupt tapes     (tightened C)
python3 /path/to/probe_extra.py     # EXROM-mapped at each site, immediate stmt, CLEAR, edit, program LOAD, failed LOAD
python3 /path/to/probe_time.py      # T-states of the RUN-start bind (slow: single-steps the debugger)
python3 /path/to/probe_bank.py      # same banking probe on the UNMODIFIED image (baseline evidence)
```

The probes import the project's own harness (`tools/v2_prod.py`, `tools/tape_synth.py`, `tools/v2_known_defects.py`) from the worktree they are run in, so they
must be run with that worktree as the current directory. Use a different port/state dir from any other running session; do not use `pkill -f`.

## Reading the prototypes

* Store entry: `[len:2][kind:1 (2 numeric | 3 string)][namelen:1][name][descriptor]`, descriptor = the tape body verbatim.
* `ARR_RUN_INIT` is called by the shell between `KTAB_VM_INIT` and `KTAB_VM_RUN`; it binds by `SYM_FIND` and fails the run with error 65 on a size/width mismatch.
* `ARR_DIM` replaces `OP_DIM`/`OP_DIM_STR`; `VM_OP_TABLE[63/64]` point at the fixed EXROM slots `$C0E6`/`$C0E9`.
* The loader receives into the free tail, validates, then commits `PAS_END`; a same-name entry is removed with one `LDIR` that carries the new entry down.

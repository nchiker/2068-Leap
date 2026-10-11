# V2 skills retention review

Which skill methods earned their place in the V2 qualification and release work, which should
change, and what is new. **Applied at the closeout (2026-10-11)** to `~/z80-skills` -- commit
`54bc4f2` on its `main`, local only (its `origin` is the upstream `ignacioMonge/z80-skills`; nothing
pushed) -- after review against the installed versions (section "Applied"). The prepared patch
`docs/v2/skills_patches/z80-skills-rc-lessons.patch` is kept as the historical proposal; the commit
supersedes it.

Classes: **KEEP** (worked as is), **IMPROVE** (worked, with a gap now addressed), **NEW**
(a method this work needed that no skill had), **RETIRE** (not worth keeping).

## z80-skills: shrink-z80

| Method | Class | Evidence |
|---|---|---|
| Measure-first, byte evidence per candidate, never sum unbuilt candidates | KEEP | every step of `V2_ROM_RAM_BUDGET.md` is a measured build |
| RST call vectors for hot call targets | KEEP | study shrink (`apply_rst_rule.py`), merged; bytecode identical |
| Emit-stub inlining with bytecode-identity proof | KEEP | `apply_emit_inline.py` + `qbytecode.py` (663/663 identical) |
| jp -> jr | IMPROVE | must be iterated to a fixed point (each pass brings more in range: 63 then 2 then 1) |
| `z80_pattern_scan.py` | IMPROVE | lists generic patterns across test sources too; it found none of the four biggest wins below |
| Dead-code scan (textual references) | IMPROVE | counts references from legacy/test builds that share a source file; misses code dead only in the shipped image |
| Production-image reachability (listings, precise fall-through, entry roots, EQU aliases) | NEW (applied) | found ~170 bytes of legacy-only routines during the release work; now `scripts/production_reachability.py` |
| Cross-bank slot-table packing | NEW | +153 bytes EXROM (unused slots and padding) |
| Removing indirection made redundant by full linking (the KTAB) | NEW | +81 bytes HOME |
| RST tail calls (`rst n : ret` for a tail `jp X`) | NEW | +41 bytes HOME |
| Dispatch return through IY with a foreign-code audit | NEW | +32 bytes HOME, faster dispatch |
| Small routines in RST-slot padding, with a fall-through gate | NEW (with a hard gate) | +32 bytes; one violation (RC-6) caught by the lifecycle test |
| Compression, generative tables, demoscene tricks | not needed | the SAFE lanes were enough |

## z80-skills: audit-z80

| Method | Class | Evidence |
|---|---|---|
| Independent read-only audit with evidence tags, promotion gate | KEEP | `V2_INDEPENDENT_Z80_AUDIT.md` (study) found real CRITICAL defects (Q-32, Q-33) |
| Register-clobber / ABI checks | KEEP | still the most common Z80 bug class in this codebase (memory note: audit-z80 should become part of the build workflow) |
| Contract checks for code *being changed* | IMPROVE (applied) | five of this release's regressions (RC-2..RC-6) broke unwritten contracts: saved-SP unwinding vs tail jumps, flag pass-through ("keeps carry"), skip-trick lengths, ignored status outputs, fall-through into relocated code -- now in `references/asm-abi.md` |

## z80-skills: debug-z80 and 2068-debug (ts2068-debug)

| Method | Class | Evidence |
|---|---|---|
| Bounded runs, breakpoints, register/memory snapshots, symbol-resolved PCs | KEEP | the session re-carve stride bug (7 vs 6-byte descriptors) was found in two single-step traces |
| Real keyboard-matrix events (`send-keys-event`) | KEEP | BREAK cases incl. `brk-session-vars` |
| Capturing a transport call (SAVE) and replaying a synthesized tape (LOAD) | KEEP | `capture_save` / `tape_op`: the whole SAVE ALL suite runs on the real routines |
| Memory diff between two points in time | NEW (tool gap) | done by hand in a script (session tables before SAVE / after LOAD); worth a `ts2068-debug diff` command |
| Two harnesses (ts2068-debug CLI and the snapshot-based `tools/qual/qharness.py`) | IMPROVE | both useful (the snapshot harness is ~10x faster for the corpus); they should share symbol loading and the message map |

## Project tools (tools/qual, kept in the repository)

| Tool | Class |
|---|---|
| `corpus.py` + `qexpect.py` + `qrun.py` (strict PASS/FAIL/XFAIL/XPASS, `--fixed rc`, `--tree`) | KEEP -- now `make qual` |
| `qlifecycle.py` (session rules), `v2_saveall_checks.py` (SAVE ALL) | KEEP -- in `make qual` / `make test` |
| `qbytecode.py` (compiler-output identity between builds) | KEEP -- the proof that shrinks changed nothing |
| `study_vm_oracle.py` (exact-arithmetic oracle) | KEEP -- in the study battery |
| `build_configs.sh`, `run_gate_suites.sh`, `run_study_battery.sh` | KEEP for qualification runs on exported commits |
| one-off ablation scripts in `~/2068-Leap-study/tools` | RETIRE (superseded) |

## Applied (closeout, `~/z80-skills` `54bc4f2`)

`~/z80-skills` was clean at `ea73e2e` (the version the patch was written against); the patch
applied cleanly; its own test suite passed before (102 + 1 skipped) and after (105 + 1 skipped).

| Skill | File | Change |
|---|---|---|
| shrink-z80 | `scripts/production_reachability.py` (new) | the reachability tool, **rewritten** before adding: roots given explicitly (`--root`, `--root-prefix`, `--roots-below`; the patch had 2068-Leap symbol names as defaults), and four defects of the proposed version fixed: lines of false `IF` blocks (sjasmplus `~`) were parsed as labels; labels sharing an address were sized as separate code (an end marker took the next routine's bytes); `EQU` aliases were never followed although the docstring said so; `halt` was treated as a transfer. Validated on the release listings: with the real roots it reports one 3-byte candidate (`EDITOR_BLOCK_DELETE`, RC-O7); the ROM was not changed |
| shrink-z80 | `references/high-impact.md` | "Multi-image / banked ROM sets": bank-aware accounting, production-only reachability, slot packing, redundant indirection, RST tail calls, IY dispatch, padding reuse, jp->jr fixed point, bytecode-identity proof |
| shrink-z80 | `references/dispatcher.md` | routes the new script (baseline list, `deadcode` mode) |
| audit-z80 | `references/asm-abi.md` | "Contracts that inserted code breaks silently": saved-SP unwinding, flag pass-through, skip tricks, library status outputs, relocated fall-through, dispatch registers, temporaries, persisted-image validation |
| develop-z80 | `references/verification.md` | "Qualifying a ROM, interpreter, or compiler release": strict PASS/FAIL/XFAIL/XPASS accounting and expectation ledger, arithmetic oracles, output identity, T-state bisection, frozen `git archive` configurations, reproducible-release checks, emulator-qualified designation, branch integration and worktree removal |
| ts2068-debug | `references/gotchas.md` | parallel suites (ports, load-induced ZRCP drops, orphaned emulators); SAVE capture / LOAD replay for tape formats |
| (repository) | `scripts/test_production_reachability.py`, `CHANGELOG.md` | unit test with a synthetic listing; changelog entry |

Skills created: none (existing skills improved instead). These lessons are generic Z80/sjasmplus
practice and apply to the Pascal, Forth V2 and C implementations as well.

## Not applied, and pending proposals

1. **`~/.claude/skills/2068-debug`** (the globally installed copy of the TS2068 debugging skill) was
   not modified: it is a separate, already diverged copy of `z80-skills`' `ts2068-debug`. Proposal:
   retire it in favour of the plugin's skill, or copy the new gotcha section into it.
2. **Memory diff in `ts2068-debug`** (the tool, `~/ts2068-debug`): a code change in another project,
   not a skill edit -- still proposed.
3. **`audit-z80` in the build workflow** for changed files (owner request on record): a project
   workflow change, deferred.
4. **One harness**: `tools/qual/qharness.py` and `ts2068-debug` should share symbol loading and the
   message map -- 2068-Leap project work.
5. Pushing `~/z80-skills`: its remote is the upstream project; contributing upstream is the
   owner's decision.

Retained in the 2068-Leap repository (project-specific): `tools/qual/` (corpus, expectations,
lifecycle, bytecode identity, benchmark, oracles, exports), the production gates and their
harnesses, `tools/make_rc_assets.py`.

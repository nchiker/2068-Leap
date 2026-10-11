# V2 skills retention review

Which skill methods earned their place in the V2 qualification and release-candidate work, which
should change, and what is new. Proposed changes to the shared skills are a patch for review --
`docs/v2/skills_patches/z80-skills-rc-lessons.patch` (against `~/z80-skills` at `ea73e2e`) -- **not
applied**: the installed and shared skills are unchanged.

Classes: **KEEP** (worked as is), **IMPROVE** (worked, with a gap the patch addresses), **NEW**
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
| Production-image reachability (listings, precise fall-through, entry roots, EQU aliases) | NEW | found ~170 bytes of legacy-only routines; proposed `scripts/production_reachability.py` |
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
| Contract checks for code *being changed* | IMPROVE | five of this RC's regressions (RC-2..RC-6) broke unwritten contracts: saved-SP unwinding vs tail jumps, flag pass-through ("keeps carry"), skip-trick lengths, ignored status outputs, fall-through into relocated code -- the patch adds them to `references/asm-abi.md` |

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

## Recommended follow-ups

1. Review and apply the patch to `~/z80-skills` (or reject parts of it).
2. Wire `audit-z80` into the build workflow for changed files (owner request on record).
3. Add a memory-diff command to `ts2068-debug`.

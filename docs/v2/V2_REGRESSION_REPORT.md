# 2068-Leap V2 Enhanced — Emulator-Qualified Release: regression report

This is the qualification evidence for the accepted release (owner acceptance 2026-10-11). Earlier
parts of this report call it the release candidate (RC), the name it had while it was qualified.

All results are emulator results (ZEsarUX 13.0 through `ts2068-debug` / `tools/qual/qharness.py`,
headless). Nothing here is hardware evidence (`V2_HARDWARE_CHECKLIST.md`). Accounting is strict:
**PASS** = the specified result; **FAIL** = anything else; **XFAIL** = a registered open defect
reproduced as registered (`V2_DEFECT_REGISTER.md`); **XPASS** = a registered defect that no longer
reproduces (counted as a failure until the register is updated). No case was removed. Every
expectation that changed is listed in section 5 with its reason: most changed because an owner
decision or the specification changed, several were made stricter, and one acceptance rule was
widened (numeric displays within the 5-byte float's precision, where its ulp reaches the 4th
decimal).

## 1. What was tested

| Build | Commit | ROM images |
|---|---|---|
| fresh clone of `~/2068-Leap`, branch `integration/v2-final-rom` | `970dc30` | identical to the worktree build and to the exports below |
| export `rc8` (`tools/qual/build_configs.sh`) | `970dc30` | identical (HOME 54 / EXROM 25 free) |
| export `rc7` | `ef81f49` | identical -- the last ROM change |
| export `rc6` | `07616e7` | SAVE ALL; registry not yet in the identity CRC |

After `970dc30` come `c57e968` (one test-only include, `rom/test_v2_local_dim.inc`, RC-12, and four
corpus expectations made exact, section 5) and a documents-only commit; the ROM images are
unchanged. `c57e968` was cloned fresh once more and its standalone suite, corpus and session
lifecycle re-run (section 2).

## 2. `make test` from a fresh clone (`970dc30`)

`git clone ~/2068-Leap`, `git checkout integration/v2-final-rom`, `make build v2-packages` (every
image and package byte-identical to the worktree's), `make check` (all checks passed), `make budget`
(HOME 54 / EXROM 25 free), then `make test` -- which runs, in order:

| Stage | What it runs | Result |
|---|---|---|
| smoke ROMs | 15 standalone kernel ROMs built, 9 run (border signature) | 9 PASS, 0 FAIL |
| standalone component tests | 40 harness images (compiler, VM, decompiler, packages) | 40 / 40 PASS |
| production checks `v2_production_checks.py` | the production image: capacity, recursion, segment 2, `FREE`, 251/252 names | 19 PASS, 0 failures |
| FILL `v2_fill_check.py` | exact flood fill against a reference, fill-stack bounds | 10 PASS, 0 failures |
| production gate `v2_prod_regress.py` | editor, tape receiver fed real EAR streams (corrupt, truncated, interrupted), packages, package ABI, format words | **114 PASS**, 0 XFAIL, 0 FAIL, 0 XPASS |
| Array Store gate `v2_prod_arrays.py` | DIM/adoption/CLEAR/RUN, ARRAY tapes, banking, sessions | **100 PASS**, 0 XFAIL, 0 FAIL, 0 XPASS |
| known defects `v2_known_defects.py` | the R10.9 defect list, now required to be fixed | **15 PASS**, 0 XFAIL, 0 FAIL, 0 XPASS |
| SAVE ALL `v2_saveall_checks.py` | round trips, plain SAVE unchanged, Array Store, no session, VERIFY, CRC corruption, other ROM, bad chain, bad pointer, package mismatch/same, no room, store entries | **13 PASS**, 0 FAIL |
| `make qual`: language corpus (`qrun --fixed rc`) | 667 programs, strict expectations | **663 PASS, 2 XFAIL** (Q-24, Q-26), 2 N/A (baseline-only `IN`/`OUT` cases), **0 FAIL, 0 XPASS** |
| `make qual`: session lifecycle `qlifecycle.py` | the owner-decision-2 rules | **23 / 23 PASS** |

Total in `make test`: 1010 cases -- 1006 PASS, 2 XFAIL (both registered LOW defects), 2 N/A, **0 FAIL,
0 XPASS**. Wall time 47 minutes.

**Second fresh clone, final test commit `c57e968`** (after RC-12 and the four exact corpus
expectations): images and packages byte-identical, `make check` clean, budget 54 / 25, standalone
40 / 40 PASS with no assembler warning, corpus 663 PASS / 2 XFAIL / 2 N/A / 0 FAIL / 0 XPASS,
lifecycle 23 / 23 (`qual-runs/fresh-c57e968/`). The gates were not re-run there: `c57e968` changes
no ROM byte and none of the gate, Array Store, known-defect or SAVE ALL suites.

None of the study worktrees, exported builds or logs was used: the clone builds and tests on its
own (`AUTHORITATIVE_SOURCE.md`). Log: `~/2068-Leap-study/qual-runs/fresh-970dc30/make-test.log`.

## 3. Production gates on the `rc6` export (07616e7)

Run before the RC-10 test corrections (`tools/qual/run_gate_suites.sh`, logs in
`qual-runs/gate-rc6/`):

| Suite | Result |
|---|---|
| production gate `v2_prod_regress.py` | 112 PASS, 1 FAIL |
| Array Store gate `v2_prod_arrays.py` | 99 PASS, 1 FAIL |
| known defects `v2_known_defects.py` | 15 PASS |
| production checks | 19 PASS, 0 failures |
| FILL | 0 failures |

The two FAILs were test defects, not ROM defects (RC-10): `arr-ktab-verify` had been mis-adapted
in `07616e7` (it compared the opcode 63/64 slots with the DIM handlers; they point at the fixed
`ARRSVC_TABLE` jumps), and `abi-prog-reject-newer-minor-8101` fed the word that became the ROM's own
format word. Both were corrected without weakening (the slot check now also requires each entry to
be a `jp` to its handler; "newer" is now the ROM's word + 1), a positive case
`abi-prog-load-older-minor` was added, and all three pass on the RC images (section 2).

## 4. The study battery (`tools/qual/run_study_battery.sh`) on `rc8`

The qualification study's own prototype tools, re-run unchanged on the RC
(`qual-runs/battery-rc8/`):

| Tool | Result |
|---|---|
| `study_bare_ident` | 13 PASS |
| `study_callfn` | 7 PASS |
| `study_d11_literals` | 14 PASS |
| `study_d11_print` | 15 PASS |
| `study_lang_hw` | 6 PASS |
| `study_lang_print` | 13 PASS |
| `study_eof_for` | 5 PASS |
| `study_u6` | 4 PASS |
| `study_edit_preserve` | 9 PASS |
| `study_break_matrix` | 7 PASS |
| `study_fill_break` | BREAK during FILL returns to the caller |
| `study_flicker` (editor redraw, full-redraw reference diff) | 12 scenarios, 0 mismatches |
| `study_vm_oracle` mul / add / sub / mulop (real Z80 code against exact Python arithmetic, D11 promotion) | 4 x 8476 pairs (boundaries + 3000 random), **0 mismatches** |

All 16 tools exit 0. On `rc6` the oracles had been run without `ORACLE_PROMOTE=1`, because the
battery's promotion marker no longer existed in the RC, so every overflow pair was counted as a
mismatch, and `study_flicker` lost its emulator connection under machine load (its 7 completed
scenarios had 0 mismatches). Both were tool problems (RC-11). The re-runs above are clean.

## 5. Every expectation that changed in the release candidate

No case was deleted (one production check was renamed, `253-vars` -> `251-vars`, below). These are all the expectation changes on the branch after `7ae0599` and the
study (`git log -p` of `tools/qual/corpus.py`, `qexpect.py`, `tools/v2_*.py`, `tools/study_*.py`),
each with its reason. "Tighter" = it now rejects outcomes it used to accept.

| Case(s) | Was | Now | Why | Commit |
|---|---|---|---|---|
| `str.instr` | the `INSTR` result | compile error | decision L-INSTR: not in V2 (no ROM room); the V1 manual entry is withdrawn | `7d2d59d` |
| `if.elseif_kw`; new `if.else_if_nested` | `ELSEIF` works | compile error; `ELSE` + nested `IF` gives the result | decision L-ELIF | `7d2d59d` |
| `arr.str_default_width` | 31-character elements | 15 (16-byte default elements) | DD-1: the manual contradicted V2's design (R10.7 s11.1) | `7d2d59d` |
| `crash.and_float`, `crash.or_float`, `crash.and_float_rhs`, `crash.not_float` | any error (the only safe outcome while a FLOAT operand crashed the machine, Q-03) | the exact value (`y`, `y`, `1`, `0`), program kept | V2 now specifies FLOAT truth values (nonzero is true; AND/OR/NOT give 0/1). Between `3136322` and the final commit they accepted "that value or an error"; the final commit makes them exact (**tighter**) | `3136322`, final |
| `fn.div.min_m1` (`DIV(-32768,-1)`) | `32768` or an error | `32768.0000` | 32768 is not an INT, so V2 displays it as a float; an error is no longer accepted (**tighter**) | `3136322` |
| numeric matching (`qexpect.within_float_precision`) | exact 4-decimal display | also accepts a display within 2 ulp of the 5-byte float + half a display unit | only reachable where the float's ulp reaches the 4th decimal (\|v\| >= 2^18); D10's truncation error (up to 0.0001) is still detected. The calculator's 32-bit mantissa cannot carry more | `3136322` |
| new `arith.overflow.*` (4), `arith.big.ok`, `lit.float.too_big`, `lit.float.1e38` | -- | error 67 / compile error 64 / correct value | RC-1: a result beyond ~1.7E38 was silently wrong | `85d59ee` |
| `tools/study_d11_literals.py` | the superseded literal rule L-A / D11 | literal rule L-C, Q-15/16, D10 | owner decision 3 replaced L-A | `85d59ee` |
| new `fn.int.neg_trunc`, `fn.mod.neg_trunc`, `fn.div.neg_trunc` | -- | truncation toward zero | pins the documented V2 design (R10.8 L6; stock BASIC floors) | `a91cffe` |
| known-defect suite (`D5`, `D5b`, `D7-fill-*`, `D9` x2, `D11-*`, `U6`, 15 cases) | XFAIL: the defect reproduces | PASS: the defect must be gone (**tighter**) | fixed in the study's Essential line (`1a9dc39`); any recurrence is now a FAIL | study |
| production check `free-1` | `FREE()` 900..1100 | 746..946 (measured 813) | the pool is 154 bytes smaller, measured: Q-02 temporaries 74, session gap 80 (`V2_ROM_RAM_BUDGET.md`) | `5e5d7b0` |
| production checks `253-vars`/`254-vars` | 253 names fit | `251-vars`/`252-vars` | Q-02's two extra float temporaries take two symbol slots | `5e5d7b0` |
| component tests `for_step`, `group6_math`, `sqr_decomp`, `vm_milestone01`, `input`, `group6_math` run phases | old bytecode / old parse | the new bytecode (FOR_INIT operand, folded literals), calculator-parsed VAL/INPUT, L3 | the code they decompile or drive changed; their assertions are unchanged | `f0d62ca` (study), `6f44b56` |
| gate `arr-ktab-verify`, `abi-prog-reject-newer-minor-*`; new `abi-prog-load-older-minor` | slots compared with the handlers; newer minor = `$8101` | slots = the fixed ARRSVC entries **and** each a `jp` to its handler (**tighter**); newer minor = ROM word + 1 | RC-10 (the packed EXROM slots; format minor 1) | `970dc30` |

The open defects still reproduce as registered: `proc.goto_label` (Q-24) and `print.font_brackets`
(Q-26) are the corpus's only XFAILs.

## 6. Performance (emulated T-states, `tools/qual/qbench.py`, compile + run)

| Program | production `7ae0599` | Enhanced (`enh-all`) | RC (`rc8`) | RC vs Enhanced | RC vs production |
|---|---:|---:|---:|---:|---:|
| `int_loop` | 16 562 115 | 42 658 138 | 42 808 173 | +0.35 % | not comparable* |
| `for_empty` (3000 bare iterations) | 2 451 405 | 3 577 922 | 3 572 543 | -0.15 % | +45.7 % |
| `for_nested` | 2 734 268 | 3 952 841 | 3 944 493 | -0.21 % | +44.3 % |
| `for_float_step` | 1 395 201 | 42 638 482 | 42 718 052 | +0.19 % | not comparable** |
| `for_int_3001` | 2 452 118 | 3 578 998 | 3 573 617 | -0.15 % | +45.7 % |
| `float_loop` | 16 403 575 | 16 581 662 | 16 643 190 | +0.37 % | +1.5 % |
| `strings` | 2 208 628 | 2 392 131 | 2 373 640 | -0.77 % | +7.5 % |
| `builtins` | 7 964 297 | 13 729 028 | 13 727 490 | -0.01 % | not comparable* |
| `compile_only` | 3 708 853 | 3 702 417 | 3 718 444 | +0.43 % | +0.3 % |

\* the sums pass 32767: production wraps to a wrong result, V2 promotes to a float and computes the
exact one (D11). \*\* production's float `FOR` used slot indexes (Q-08) and did not run the loop.

The RC work itself (session variables, SAVE ALL, the space work) costs nothing measurable: within
-0.8 % .. +0.4 % of the qualified Enhanced build. Against production, a **bare** `FOR`/`NEXT`
iteration is ~45 % slower (about 1190 vs 817 T-states). Bisected (`qbench` on each study commit):
the qualification FOR-frame redesign that fixes Q-07/Q-19/Q-20 accounts for +36 % (`602549b` ->
`f0d62ca`), D11's overflow-checked add for +2 %, float FOR variant D for +5 %; loops with real
bodies differ by 0.3-1.5 %. This is recorded as **RC-O6** (a correctness cost, kept). Logs:
`qual-runs/bench-rc8.log`.

## 7. Other evidence

| Check | Result |
|---|---|
| bytecode identity `qbytecode.py rc6 rc8` (compile every corpus program on both, compare the emitted bytecode and compile error) | 667 / 667 identical (12 957 bytes): the CRC/registry change and the test commits changed no compiler output |
| bytecode identity rc5 -> rc6 (SAVE ALL and the space work) | 663 / 663 identical |
| identity CRC that `make rc-assets` writes in `BUILD_INFO.txt` vs. the CRC in a block a real `SAVE ... ALL` wrote on the RC | both `$5E95`; the block CRC of that block also checks |
| `test_v2_local_dim.inc` fix (RC-12) | the 40 standalone component tests re-run after it: 40 / 40 PASS, no assembler warning in any image |

## 8. Known test debt

T-3 (15 legacy component-test sources in no runner) is unchanged. The production builds assemble
with 0 warnings; after RC-12 no standalone component-test build has a warning either.

## 9. Release-integrity verification (closeout, 2026-10-11)

Before the merge into `v2-development`, bounded and without re-running the 47-minute suite (no
production source changed after the qualification):

| Check | Result |
|---|---|
| changes after the ROM-producing commit `ef81f49` | `970dc30`, `c57e968`, `7ecffcf`, `a4e4641`, `118e148`: tests, test tools, one test-only include (`rom/test_v2_*`), documents; **no production source** (`rom/`, `kernel/`, `include/`, `basic/`, `Makefile` outside `rom/test_*`) |
| fresh clone of `118e148`: `make build v2-packages`, `make check`, `make budget`, `make rc-assets` | all succeed; HOME end `$3FCA` (54 free), EXROM end `$DFE7` (25 free): inside both bank limits |
| release images vs. the accepted SHA-256s | HOME, EXROM and the ZEsarUX image match exactly; the ZEsarUX image is HOME + EXROM |
| `SHA256SUMS` (ROMs and the five packages and tapes) | every entry verifies; identical to the qualified worktree's manifest |
| the images vs. the builds the qualification ran on | byte-identical to `rc7` (`ef81f49`), `rc8` and the fresh clone of `970dc30` (gates, battery, `make test`) and the fresh clone of `c57e968` |
| identity CRC | `BUILD_INFO.txt` `$5E95`; a real `SAVE ... ALL` on the rebuilt image stamps `$5E95`, block CRC valid |
| open defects | only LOW, LIMIT, RESERVE, PERF and TEST items (`V2_DEFECT_REGISTER.md`); the HIGH entries D11, N-1, N-2 of the defect list are production-baseline defects fixed in Essential/Enhanced (their corpus markers apply to the baseline only and the cases pass on the release) |


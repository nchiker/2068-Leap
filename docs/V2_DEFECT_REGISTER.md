# V2 defect register (V2 Enhanced release)

Branch `integration/v2-final-rom`. Severity as found; **Status** is the state in the release
candidate: **Fixed** (the corpus case now passes on the corrected expectation), **Decided** (a
documented V2 design choice; the corpus case expects it), **Doc** (the documentation was wrong and
is corrected), **Open** (still reproduced: the corpus keeps the case as XFAIL). Evidence = corpus
case ids (`tools/qual/corpus.py`) or suite case names. Source of the Q-/D-/L-/N- entries:
`tools/qual/defects.py` (qualification study and owner-decision review).

## Open

| Id | Sev | Defect | Why open | Evidence |
|---|---|---|---|---|
| Q-24 | LOW | `CALL` of a plain label (not a `PROC`) is accepted: it jumps there, and the code runs on without returning | deferred: needs a label-kind check in the compiler; no ROM reserve; **accepted LOW limitation** (owner, 2026-10-11) | `proc.goto_label` (XFAIL) |
| Q-26 | LOW | the nine characters `[` `\` `]` `^` `` ` `` `{` `\|` `}` `~` print as blanks (no glyphs in the ROM font) | deferred: 9 glyphs cost ~72-90 bytes of HOME; **accepted LOW limitation** (owner, 2026-10-11) | `print.font_brackets` (XFAIL) |
| RC-O1 | LOW | A literal beyond the float range (~1.7E38) is compile error 64, whose message reads "UNEXPECTED TOKEN" | cosmetic; a "NUMBER TOO BIG" message costs ~20 bytes | `lit.float.too_big` (passes on the code) |
| RC-O2 | LIMIT | `SAVE ... ALL` refuses (`OUT OF MEMORY`) when bytecode + segment 2 + 53 bytes exceed the bytecode area plus free memory | the in-place layout must end at `V2_CODE_LIMIT` | `sa-no-room` |
| RC-O3 | LIMIT | A `SAVE ... ALL` tape restores its variables only on the exact ROM build, with the same package registration, that wrote it (otherwise: program only, `NO VARIABLES`) | by design: the image includes bytecode, layout and package references | `sa-other-rom`, `sa-package-mismatch` |
| RC-O4 | LIMIT | Numeric array elements are 16-bit integers: storing a float or a value outside -32768..32767 is runtime error 11 | V2 array format | `arr.float_value` (OkOrErr) |
| RC-O6 | PERF | A bare `FOR`/`NEXT` iteration costs ~1190 T-states, ~45 % more than in production `7ae0599` (817 T); loops with real bodies differ by 0.3-1.5 % | measured cause (bisected with `qbench`): the qualification FOR-frame redesign that fixes Q-07/Q-19/Q-20 (NEXT works through its own control-stack frame) +36 %, D11 overflow-checked add +2 %, float FOR variant D +5 %. A correctness cost, kept; a faster INT-only NEXT path would need ROM space; **accepted as a correctness trade-off** (owner, 2026-10-11) | `V2_REGRESSION_REPORT.md` s6 |
| T-3 | TEST | 15 legacy component-test sources (`call_fn`, the `compiler_r2` to `compiler_r7` series, `decompiler_phase2`, `editor_integration`, `ext_concurrent`, `graphics_module_ram`, `graphics_pixel`, `print`, `sprite_module`, `sqr`) are in no runner | test debt, unchanged from the study | `tools/run_v2_standalone_tests.sh` |

## Fixed or decided in the V2 Enhanced release

| Id | Sev | Defect | Status | Evidence |
|---|---|---|---|---|
| Q-01 | CRITICAL | string comparison compared lengths only | Fixed (qualification branch, merged) | `str.cmp_*` |
| Q-02 | CRITICAL | temporaries reused while live | Fixed | `strrec.*`, Q-02 cases |
| Q-03 | CRITICAL | AND/OR with a float jumped to the value | Fixed | `crash.and_float`, `log.float` |
| Q-04 | CRITICAL | DIM > 8 KB wrapped and overwrote the stack | Fixed (error 64) | `dim.big*` |
| Q-05 | MEDIUM | -32768 printed +32768.0000 | Fixed | `lit.int.neg32768` |
| Q-06 | HIGH | IF tested a float's slot index | Fixed | `if.float_cond` |
| Q-07 | HIGH | FOR ran once when already past the limit | Fixed | `for.zero_trip*` |
| Q-08 | HIGH | float FOR used slot indexes / hung | Fixed (owner decision 1, variant D) | `for.float_*`, `ffor.*` |
| Q-09 | MEDIUM | 5+ fractional digits overflowed silently | Fixed (exact float literals) | `lit.dec.*` |
| Q-10 | HIGH | float arguments of SGN/SQR/RAD/DEG/SIN/COS/TAN/MOD/DIV truncated | Fixed | `fn.abs.f`, `fn.sin.f`, `fn.sqr.f`, `fn.mod.float` |
| Q-11 | MEDIUM | PROC/DEF FN inside a PROC corrupted it | Fixed | `proc.nested_def` |
| Q-12 | LOW | duplicate label accepted | Fixed (error 57) | `label.dup` |
| Q-13 | MEDIUM | MOD/DIV by zero returned 0 | Fixed (error 5) | `fn.mod.zero` |
| Q-14 | LOW | CLS kept the PRINT position | Fixed | `print.cls` |
| Q-15/Q-16 | MEDIUM | INPUT ignored '.', wrapped above 32767 | Fixed (shared number parser) | `input.*` |
| Q-17 | LOW | VAL skipped non-digits, wrapped | Fixed | `str.val_*` |
| Q-18 | CRITICAL | out-of-range array stores still wrote | Fixed | `mem.*` |
| Q-19 | MEDIUM | NEXT without its FOR looped forever | Fixed (error) | `for.goto_into` |
| Q-20 | HIGH | GOTO out of an inner FOR broke the outer | Fixed | `for.goto_out_inner*` |
| Q-21 | LOW | CLEAR inside FOR never ended | Fixed (CLEAR ends loops; NEXT = error 7) | `clear.loop` |
| Q-22 | LOW | SQR of a negative returned 0 | Fixed (error 15) | `fn.sqr.neg` |
| Q-23 | LOW | STICK(n) out of range returned a value | Fixed (error 15) | `hw.stick_bad` |
| Q-25 | LOW | string comparison not usable in AND/OR | Fixed | `str.cmp_and` |
| Q-27 | HIGH | PRINT of a string-function result showed a stale tail | Fixed | `strrec.stale_tail*` |
| Q-28 | CRITICAL | 31-character strings corrupted array 0 | Fixed | `strrec.31_*` |
| Q-29 | HIGH | SPRITE MOVE garbage (package) | Fixed | sprite package checks |
| Q-30 | HIGH | float arguments of CHR$/LEFT$/RIGHT$/MID$/PAUSE/BORDER were slot indexes | Fixed | Q-30 cases |
| Q-31 | LOW | MID$ start used its low byte | Fixed (clamped) | `str.mid_*` |
| Q-32 | CRITICAL | addresses above 32767 saturated (POKE wrote the wrong byte) | Fixed | `lit.addr.*`, `hw.*` |
| Q-33 | HIGH | package float arguments were slot indexes | Fixed | package cases |
| Q-34 | HIGH | the calculator never rounded (`INT(3.1*10)` = 30, `1/10*10` <> 1) | Fixed (R1, `backport/leapc`: Leap-C's float core, rounds to nearest) | `tools/qual/qcalcround.py` |
| D10 | MEDIUM | float display truncated the 4th decimal | Fixed (exact formatter, rounded) | `arith.f.*`, `print.multi_float` |
| D11 / D11-EXT / D11-DISP | HIGH..LOW | 16-bit overflow wrapped; edge cases; big-float display | Fixed (promotion, exact display) | `arith.*`, `lit.*` |
| L-A | DECISION | literal rule | Superseded by **L-C** (owner decision 3): 32768..65535 are positive floats, addresses still work | `lit.int.*` |
| L3 | LOW | string literal > 31 cut silently | Fixed (compile error 70) | `lit.str.32` |
| L-STR | MEDIUM | no string <> > <= >= | Fixed | `str.cmp_*` |
| L-SC | LOW | AND/OR did not short-circuit | Fixed (opcodes 72/73) | `log.shortcircuit` |
| L-NEXT | LOW | bare NEXT rejected | Fixed | `for.bare_next` |
| N-4 | LOW | scalar beside an array of the same name needed '(' | Fixed | N-4 cases |
| DEC-PLOT | DECISION | PLOT/POINT coordinates wrapped | Decided: clamped to the screen | `gfx.plot_clamp` |
| L-INSTR | LOW | INSTR documented, absent | **Decided**: not in V2 (no ROM room); manual entry withdrawn | `str.instr` (expects the compile error) |
| L-ELIF | LOW | ELSEIF documented, absent | **Decided**: not in V2; `ELSE` + nested `IF` | `if.elseif_kw`, `if.else_if_nested` |
| F11 | DECISION | float `FOR` counts after R1's rounding (`FOR i = 0 TO 1 STEP 0.1` runs 10 times) | **Decided** (`backport/leapc`): the BASIC standards' loop, step accumulated, exact end test (ECMA-55 §13.4, ANSI X3.113 §8.3.4); manual FOR | `ffor.count.*`, manual `kw.for.6` |
| ED4 | LOW | the cursor's line could fall below row 22 and lose its cursor (a 97+ character line starting low, or wrapped lines above it: the view always showed 20 lines above) | Fixed (`SH_VIEW`, `backport/leapc`: `V2_VIEW`, Leap-C's view rule) | `ED4-*` (prod-regress), `tools/qual/qeditview.py` |
| ED3 | MEDIUM | a command typed on any line but the empty last one was stored as program text (`RUN` typed over line 12 replaced it) | Fixed (`backport/leapc`): ENTER carries a command out on any line; the line keeps its text | `ED3-*` (prod-regress), manual `con.edit.5` |
| ED7 | LOW | the cursor after a last row of exactly 32 characters was at column 32, off the screen; LEFT/RIGHT from there whitened the status bar's first cell | Fixed (`backport/leapc`): the edit buffer gets an empty row after a full last row | `ED7-*` (prod-regress), `tools/qual/qeditview.py` |
| RC-O7 | SPACE | `EDITOR_BLOCK_DELETE` (3 bytes, EXROM `$D0CE`, a `jp` to the line-range delete) is unreachable in the production EXROM: its only caller, `rom/exrom_checker.asm`, is not in the image | Resolved on `backport/leapc` (plan item 1.1): `EDITOR_BLOCK_DELETE` is no longer in the production EXROM | the tool's report on the release listings |
| RC-O5 | RESERVE | ROM reserve 54 (HOME) / 25 (EXROM) bytes free in the release, below the provisional 200 / 150 targets (`v2.0.1-emu.1`: 19 / 26; `v2.0.2-emu.1`: 275 / 26) | Resolved on `backport/leapc` (plan, phases 1-4 and R1): HOME 441 / EXROM 778 B free; the 64 / 32 B emergency reserve is enforced by `make check` | `make budget` |
| DD-1 | DOC | manual: string array elements hold 31 characters | **Doc**: V2's design is 16-byte (15-character) elements by default; manual corrected | `arr.str_default_width` |
| T-1, T-2 | TEST | component-test images silently truncated / over size | Fixed (strict builds) | standalone runner |
| T-4 | TEST | test decompiler gaps | Fixed for opcodes 71-73 (string `>`, short-circuit AND/OR); 70 (5-byte float literal) is not decompiled | `relational` |

## Found during the release-candidate work

| Id | Sev | Defect | Status | Commit |
|---|---|---|---|---|
| RC-1 | HIGH | float results beyond ~1.7E38 were silently wrong (4294967296^4 printed 2^96; a 41-digit literal printed 9.0000) -- the VM ignored the calculator's overflow flag | Fixed: runtime error 67; literal: compile error 64 | `85d59ee` |
| RC-2 | HIGH | (introduced by the session work, caught by the gates) a line that did not fit was dropped without PROGRAM FULL | Fixed before release (flag-neutral session reset) | `d404b57` |
| RC-3 | HIGH | (introduced, caught by the Array Store gate) error 65 at RUN unwound into a reused stack slot | Fixed (call at VM_INIT's level) | `d404b57` |
| RC-4 | MEDIUM | (introduced, caught by new tests) an immediate `DIM` mismatching a stored array made every later immediate statement fail with 65 | Fixed (`ARR_RUN_CHECK` before the re-carve) | `d404b57` |
| RC-5 | HIGH | (introduced, caught by the gates) the check-only bind entry never cleared its flag, so binding was skipped after the first check | Fixed (2-byte skip) | `07616e7` |
| RC-6 | HIGH | (introduced during the space work, caught by the lifecycle test before commit) relocating a fall-through target (`VM_STORE_VAR_LOOP`) stopped every program after its first store | Fixed before commit (left in place) | `07616e7` |
| RC-7 | MEDIUM | the first SAVE ALL design copied the session into free memory, so any session with segment-2 arrays could never be saved | Fixed: in-place layout | `07616e7` |
| RC-8 | TEST | `make test` ran stale smoke images (no `smoke-build` dependency) | Fixed | `7d2d59d` |
| RC-9 | HIGH | (found reviewing the SAVE ALL design) after a reboot the package generation counter restarts, so a restored session's package statements could be answered by a different package registered in the same slot with the same generation | Fixed: the identity CRC covers the package registry | `ef81f49` |
| RC-10 | TEST | (found by the rc6 gate run) two gate checks were pinned to pre-RC values: `arr-ktab-verify` was mis-adapted in `07616e7` (it compared the opcode 63/64 slots with the DIM handlers, but they point at the fixed `ARRSVC_TABLE` jumps), and `abi-prog-reject-newer-minor-8101` used the word that became the ROM's own format word | Fixed in the tests: the slot check now also requires each slot to be `jp` to its handler; "newer minor" is the ROM's word + 1 (`$8102`); new case `abi-prog-load-older-minor` proves minor-0 tapes still load. ROM unchanged | `970dc30` |
| RC-11 | TEST | the study battery ran the integer oracles without `ORACLE_PROMOTE=1` on the RC (its promotion marker `FLOAT_BIG_TO_STRING` was replaced by the exact float formatter), so every overflow pair was reported as a mismatch, and the oracle's mismatch printout crashed | Fixed in `run_study_battery.sh` (VM-source marker as well) and `study_vm_oracle.py`. With promotion checked, 0 mismatches. ROM unchanged | `970dc30` |
| RC-12 | TEST | (found reading the fresh-clone `make test` log) the component-test image `vm_milestone01` had its DIM opcode slots 128 bytes off (`$31CF`/`$31FD`, handlers at `$324F`/`$327D`): `rom/test_v2_local_dim.inc` bound the slot names with an `EQU` before the handlers, a forward reference that lags one assembler pass (sjasmplus "Label has different value in pass 3"). The test passed only because it runs no DIM. Present since R10.9 Phase 2C; production images never include the file | Fixed: the names are bound after the handlers; no warning, slots correct; production images unchanged | `c57e968` |

## Sound maintenance release `v2.0.1-emu.1`

Found or changed after `v2.0.0-emu.1`, in the BEEP/SOUND maintenance work (`V2_AY_BEEP_STUDY.md`, `V2_CLASSICBEEP_STUDY.md`), and released in `v2.0.1-emu.1` (`V2_MAINT_RELEASE_STATUS.md`); "the candidate" below is that release.

| Id | Sev | Defect | Status | Evidence |
|---|---|---|---|---|
| M-PAUSE | MEDIUM | **`PAUSE n` could end at once.** It waited until `FRAMES` reached `FRAMES + n` in 16 bits, so whenever that sum passed 65535 the target wrapped and the pause ended immediately: `PAUSE 20` with `FRAMES` = 65530 waited 0 frames. Probability n / 65536 per `PAUSE` (about 5 % for a one-minute `PAUSE 3000`). Present in `v2.0.0-emu.1` | Fixed in the candidate: `PAUSE`, `BEEP` and the startup chime share one `HALT`-counting wait (`AY_WAIT_FRAMES`, HOME), which BREAK ends | `tools/maint/ay_beep_tests.py` (`PAUSE 20 from FRAMES=65530`; the release-behaviour assertion on the AY build) |
| M-1 | DESIGN | `BEEP` took raw cycle/delay counts, not Sinclair's seconds and semitones | Changed in the candidate: AY-based `BEEP seconds,semitones`; the loudspeaker routine moved to the optional cbeep package (`CBEEP ms,semitones,border`) | `ay_beep_tests.py`, `cbeep_tests.py`, `cbeep_tape_test.py` |
| M-2 | LOW | `SOUND` refused register 0 (the stock ROM accepts 0 to 16) | Fixed in the candidate | `ay_beep_tests.py` (`SOUND 0,123` ... `SOUND 20,1`) |
| M-3 | LIMIT | With the frame interrupt off (port `$FF` bit 6, or machine code that leaves interrupts off), `PAUSE n` and `PAUSE 0` never end and BREAK cannot stop them; `BEEP` never ends if the frame interrupt is inhibited at port `$FF` | Documented (manual: `PAUSE`, `BEEP`); the same as the release for `PAUSE` | `tools/maint/di_wait_tests.py` |
| T-4 | TEST | `make test-legacy`: 5 of its 13 V1 storage cases (`extension_roundtrip`, `autorun_*`) cannot be built: the legacy test EXROM (`rom/exrom_build.asm` with `STORAGE_TEST_FAKE_SEND`) overflows by 42 / 17 bytes, so `sjasmplus_strict.sh` refuses it. Identical on the release tag; the production images do not use this build | test debt, open; the other 8 cases pass | `V2_CLASSICBEEP_STUDY.md` s10 |

## Compiler maintenance release `v2.0.2-emu.1`

Found after `v2.0.1-emu.1` and fixed in `v2.0.2-emu.1` (`V2_COMPILER_MAINT_RELEASE_STATUS.md`).

| Id | Sev | Defect | Status | Evidence |
|---|---|---|---|---|
| M-4 | MEDIUM | **An array access whose subscript or assigned value reads an array of the other kind was compiled as the wrong kind.** The two array-read paths and the array assignment shared one "string?" flag cell, and a nested read of the other kind overwrote it: `PRINT names$(pick(0))` read the *numeric* array table (a wrong value, no error), `pick(1) = LEN(w$(0))` stored with the string opcode (a wrong value), and `names$(pick(0)) = "x"` or `pick(LEN(w$(0))) = 1` were rejected as `SYNTAX`. Plain subscripts (`names$(k)`) and same-kind nesting (`a(b(0))`) were correct. Present in `v2.0.0-emu.1` and `v2.0.1-emu.1` | Fixed in `v2.0.2-emu.1` (`f40ffed`): the read kind travels in a register across the subscript compile; only the (statement-level) assignment uses the flag | `arr-nested-kind` (`tools/v2_prod_arrays.py`) |

## Hardware

Nothing in this register has been checked on a physical TS2068 (all evidence is ZEsarUX): **NOT
TESTED — PHYSICAL HARDWARE UNAVAILABLE** (`V2_HARDWARE_CHECKLIST.md`). Hardware qualification is
deferred; it is not a release blocker.

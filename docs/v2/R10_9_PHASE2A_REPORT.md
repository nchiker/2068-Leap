# R10.9 Phase 2A — Cassette integrity and array regression coverage

**Status:** implemented on top of `59610d5`; **owner-approved** (§12). Phase 2B (Array Store design
comparison), Phase 2C (Array Store) and everything after are not started. Evidence tags: **[M]** measured in this
phase on the production image by the project's own harness; **[S]** read from source; **[H]** hypothesis.

Companion documents: [`R10_9_ARRAY_PERSISTENCE_AUDIT.md`](R10_9_ARRAY_PERSISTENCE_AUDIT.md) (design baseline, not
edited), [`R10_9_PHASE1_REPORT.md`](R10_9_PHASE1_REPORT.md), [`R10_9_WORK_SEQUENCE.md`](R10_9_WORK_SEQUENCE.md) (step 2.3
marked done), [`TESTING.md`](TESTING.md), [`PACKAGE_ABI.md`](PACKAGE_ABI.md) (unchanged).

## 1. Summary of changes

| Area | Change | Cost |
|---|---|---|
| `kernel/storage/storage.asm` | `STORAGE_RECEIVE_BLOCK`: **every** failure exit now returns carry **set** through one shared `.fail`; `STORAGE_LOAD`: VERIFY failures are always "clean", SPACE aborts end the header search and are reported in `B`; success returns `B = 0` | EXROM +30 B |
| `rom/exrom_v2_shell.asm` | `V2_LOAD`/`V2_VERIFY`: restructured failure handler (class → wipe decision → message), `ABORTED` message, VERIFY length-equality check; `V2_LOAD_ARRAY` shows `ABORTED` | EXROM +32 B |
| `docs` | `TESTING.md`, `user_manual.md` message table, `R10_9_WORK_SEQUENCE.md` step 2.3, this report | — |
| `tools/v2_prod.py` | `press_space()`, `capture_save()`, `tape_op(prepare=…)`, extra state in `tape_op` results, `wait_in_data(dest=…)` | test tooling |
| `tools/v2_prod_regress.py` | the former `D1-*`/`D2-*` expected failures are now **gate** cases, extended to 24 (§5) | test |
| `tools/v2_known_defects.py` | D6 precondition hardening; **new** D12–D15 strict expected failures with positive controls (§6) | test |

Package ABI 2.0, tape version words (`$8100` programs/arrays, `$8200` packages), the RAM layout and all sysvar pins are
**unchanged**. HOME is untouched (all changes are in EXROM). No Array Store, DIM, allocation or compiler change was made.

## 2. Root causes and fixes

### D1 — failed receive reported as success [S][M]

`STORAGE_RECEIVE_BLOCK` documents (and `STORAGE_LOAD` tests with `jr c,.data_failed` / `jr nc,.header_found`) *carry
set = failure, carry clear = success*. The routine was ported from the stock `LD-BYTES`, whose convention is the
**opposite** (carry set = success): the ported return paths were never all inverted. Of the seven exits only two were
right (retry-budget exhausted, checksum mismatch). The other five returned **carry clear = "success"**:

| Exit | Condition | Was | Now |
|---|---|---|---|
| `.break: ret nz` | SPACE held while waiting for / inside a pilot, sync | clear | **set** |
| second sync edge `ret nc` | dropout / SPACE at sync | clear | **set** |
| `.flag: ret nz` | data-block flag byte ≠ requested type | clear | **set** |
| `.verify: ret nz` | VERIFY byte mismatch | clear | **set** |
| `.bits8: ret nc` | dropout / SPACE inside a byte | clear | **set** |

Consequences measured on the unmodified ROM [M]: `LOAD` of a tape that dropped out, was cut short, had a wrong flag
byte or was aborted with SPACE printed `LOADED` (`STORAGE_OP_STATE = 4`) with the tail of the program being stale
RAM; a `VERIFY` of a *different* program printed `VERIFIED`; and a package tape cut short was "installed" and
**executed** (`call EXTENSION_MODULE_BASE`). The fix funnels all five into one `.fail: scf / ret` placed after the
checksum test (which also removes the old `jr z,.success` / `.success: ret` pair); the routine's header comment now
states the contract.

### D2 — VERIFY (three separate faults) [S][M]

1. **Mismatch reported as VERIFIED** — same root cause as D1 (`.verify` exit).
2. **A failed VERIFY erased the program.** `STORAGE_LOAD` classifies a failure as "touched" when the receiver's
   outstanding byte count differs from the start. In VERIFY mode the receiver never stores, but a mismatch or bad
   checksum after the first byte looks "touched", and `V2_LOAD` answered `$FF` with `MEM_INIT_V2` (NEW). Fix:
   `STORAGE_LOAD` returns a *clean* failure whenever `STORAGE_VERIFY_MODE ≠ 0` (the transport knows it wrote nothing).
3. **Length was never compared.** The receiver verifies the first *tape-length* bytes against RAM. A tape that is a
   prefix of the program, or a longer tape whose extra bytes happen to match stale RAM beyond `PROG_END`, would
   verify. Fix: on transport success `V2_LOAD` requires `PROG_AREA_START + tape length == PROG_END`
   (13 B of EXROM); otherwise it fails like any mismatch.

VERIFY reuses the existing transport (`STORAGE_RECEIVE_BLOCK`'s carry-clear compare path, which was already there) and
needs **no** staging buffer: nothing is copied, the only extra state is one comparison.

## 3. LOAD failure-state policy

The transport reports one of four classes (`A`), plus an abort flag (`B`):

| `A` | Meaning | Program / package state | Message |
|---|---|---|---|
| `0` | failed **before the first destination byte was stored** (no header, wrong name/type, header length > room, bad flag byte, dropout before byte 0, VERIFY of anything) | **untouched** | `LOAD FAILED` / `VERIFY FAILED` |
| `$FF` (`STORAGE_LOAD_DATA_TOUCHED`) | failed **after** destination bytes were stored (dropout/truncation/abort mid-block, **bad checksum** — all bytes are already in place) | **known-safe empty program** (`MEM_INIT_V2` + `V2_RESET_EDIT`, i.e. exactly `NEW`): `PROG_END = PROG_AREA_START`, edit cursor reset, arrays/registry cleared. A half-overwritten source is never left executable | `LOAD FAILED` |
| `$FE` (`STORAGE_LOAD_BAD_VERSION`) | header version word not ours — refused before any byte | untouched | `BAD TAPE VERSION` |
| `B ≠ 0` (any failure) | the user held SPACE | as `A` says | `ABORTED` |

* No success is ever reported for an incomplete receive: the carry contract is now uniform and tested through every
  exit (§5).
* The old program cannot be restored after a destructive failure without a program-sized staging buffer. None was
  added (explicitly out of scope); the empty state is the safe fallback, and the message tells the user.
* **Package LOAD** (`LOAD "x" EXT`) already cleared the registry and window length on *any* failure; that policy is
  unchanged and now also fires for the previously-mis-reported cases.
* **Array LOAD** (`LOAD … ARRAY`) receives into free arena space *above* `ARRAYS_END` and only then commits
  (`ARENA_ALLOC_*`), so a failed receive of either class leaves everything intact; it now also shows `ABORTED`. Its
  validation gaps (D15) and the missing `BAD TAPE VERSION` wording (D16 — it still says `LOAD FAILED`) are untouched.
* **Version policy unchanged**: programs and arrays `$8100`, packages `$8200`; pre-R10.9 program tapes remain refused
  (`abi-prog-reject-*` still pass); no legacy compatibility was added.
* **User abort.** The receiver can only return carry. `STORAGE_LOAD` re-reads SPACE (port `$7F`) at the moment it
  classifies a failure and returns `B ≠ 0` if it is still down. The receiver samples SPACE thousands of times a second
  and a key press lasts milliseconds, so the re-read is reliable for a human; a press shorter than a few microseconds
  between the receiver's sample and the re-read would degrade to a plain `LOAD FAILED` (same state handling, only the
  word differs). During the *header search* a SPACE press now stops the search immediately (previously every failure
  was mis-read as "header found" or silently retried up to 15 times, so SPACE could not abort a waiting `LOAD`).

## 4. VERIFY behaviour and safety

| Case | Result [M] |
|---|---|
| identical program | `VERIFIED`, program byte-identical |
| different program, valid checksum | `VERIFY FAILED`, intact |
| only the final text byte differs | `VERIFY FAILED`, intact |
| bad checksum | `VERIFY FAILED`, intact (**was: program erased**) |
| truncated / dropout mid block | `VERIFY FAILED`, intact |
| tape is a prefix of the program / extends over stale RAM | `VERIFY FAILED`, intact |
| wrong name / wrong type (package) | `VERIFY FAILED`, intact |
| unsupported version | `BAD TAPE VERSION`, intact (`abi-prog-reject-verify`) |
| SPACE | `ABORTED`, intact |

In every case `STORAGE_VERIFY_MODE` is back to 0 afterwards (asserted — a stuck flag would turn the next `LOAD` into a
verify). `PROG_END`, the program bytes and the editor state are never written on any VERIFY path: the data-block
receiver runs in its compare-only mode, `.data_failed` is bypassed for VERIFY, and `.program_loaded` is only reached
through the LOAD branch. No duplicate buffer exists.

## 5. Production-ROM regression coverage — cassette (all gate cases, all PASS)

Run on the real image through the real receiver fed a synthesised EAR stream. Every case asserts the message **and**
the resulting state (program bytes intact, or empty state: `PROG_END`, `CUR_EDIT_POS`, `CUR_EDIT_INDEX`;
`STORAGE_VERIFY_MODE == 0`).

* LOAD: `D1-dropout`, `-truncated` (wipe), `-checksum` (wipe), `-flag-mismatch`, `-dropout-before-data`,
  `-header-truncated`, `-wrong-name`, `-wrong-type` (intact), `-space-abort` (`ABORTED`, wipe),
  `-space-abort-header` (`ABORTED`, intact), `-recovers` (after a wiping failure the editor accepts input and a second
  LOAD of a good copy of the same tape succeeds), `-pkg-truncated`, `-pkg-space-abort` (registry and window cleared).
* VERIFY: `D2-verify-identical`, `-mismatch`, `-last-byte`, `-checksum`, `-truncated`, `-dropout`, `-shorter-tape`,
  `-longer-tape`, `-wrong-type`, `-wrong-name`, `-space-abort`; bad version is covered by the existing
  `abi-prog-reject-*` / `abi-prog-reject-verify`.

**Baseline comparison [M]** (`59610d5` in a clean worktree with the *new* test files copied in): every destructive or
mis-reported case fails there — e.g. `D1-dropout` `msg=LOADED`, `D1-flag-mismatch` `LOADED`, `D2-verify-mismatch`
`VERIFIED`, `D2-verify-last-byte` `VERIFIED`, `D2-verify-checksum` `VERIFY FAILED` **with the program erased**, the
shorter/longer-tape cases `VERIFIED`; the `ABORTED` cases fail (no such message/symbol). Only the cases whose
behaviour was already right (`D1-checksum` message, wrong name/type, truncated header, `D2-verify-identical`) pass
on both. The Phase 1 xfail cases for D1/D2 (6 XFAIL on the baseline) flipped to XPASS on the first run and were moved
to the gate, as `TESTING.md` requires.

## 6. Array regression coverage — D12–D15 (strict expected failures; nothing repaired)

`tools/v2_known_defects.py`; each case asserts the **correct** behaviour. *Baseline = this phase's ROM* (the cassette fix
does not touch any of these paths), measured [M]:

| Defect | Cases (XFAIL unless noted) | Observed |
|---|---|---|
| **D12** DIM not zeroed | `D12-dim-zero-repeat-run` (`DIM a(5)`, `y=a(2)`, `a(2)=33`, RUN ×3); `-dirty-ram` (arena pre-filled `$A5`); same two for a string array (`LEN(s$(1))`) | y per RUN `[0, 33, 33]`; dirty RAM reads `42405` (`$A5A5`); string `[0, 5, 5]` / `5` |
| **D13** SAVE ARRAY header | `-save-array-header-numeric`, `-string` (type 8, word `$8100`, length, body); `-array-tape-refused-by-plain-load`; `-own-array-tape-loads-as-array` | header **type 0** (`word=8100 length=13 body_ok=True`); the type-0 array tape **replaces the program** under plain `LOAD` (`LOADED`, program not intact); `LOAD … ARRAY` of the ROM's own array tape → `LOAD FAILED` (header search never matches; ≈ 143 s wall-clock of header search) |
| **D14** names > 8 | `D14-save/load-name-{9,11,31}`, `-mixedcase` (13 + 17 chars, other-case reference); controls `-name-8` (save+load) and `-name-8-mixedcase` **PASS** | every long name → `ARRAY NOT DIMD` |
| **D15** descriptor validation | `count-short` (2 into `a(5)`), `count-long` (100), `count-zero`, `len-count-mismatch` (len 13 / count 100), `len-below-descriptor` (len 2), `numeric-into-string`, `string-into-numeric`, `string-width-0`, `string-width-1`; controls `control-numeric`, `control-string`, `dimcount-normalised` **PASS** | all nine `LOADED`, slot registered, arena advanced `+7 … +203` bytes |
| **D6** | existing case | now raises (FAIL, not XFAIL) if its LOAD did not complete or the program stops compiling, so it can only XFAIL on the real lifecycle defect: `load_msg=LOADED ptr=8293 → RUN: vm_err=10 y=0` |

Notes and judgement calls:

* **Harness safety (D15).** All malformed bodies are ≤ 203 bytes and land in free arena space; no case advances a
  pointer beyond RAM or `RUN`s a malformed array. No case writes outside the arena.
* **`dim_count ≠ 1`** is *accepted and rewritten to 1* by design (audit §5.1) — kept as a positive control, not a defect.
* **Declared-size mismatches (`count-short`, `count-long`)** are asserted as *refused at LOAD*, which is the safe behaviour
  of today's pool-path loader (it knows the target's declared size). The audit's Array Store design instead checks
  size at `DIM` ("adopt or `ARRAY SIZE MISMATCH`"). If Phase 2B/2C moves the check, these two cases must be **deliberately
  re-targeted** to the new location (owner decision 1, §12), not deleted or loosened; the structural cases (zero count, length≠count, width<2,
  kind swap, length<3) stay LOAD-time checks in either design.
* The string element-length overflow pass (audit §5.1 "optional") is not covered.
* D16 (`BAD TAPE VERSION` wording for array tapes) was not requested and is untouched.

## 7. Budget and RAM [M]

| | Before (`59610d5`) | After | Δ | Floor |
|---|---:|---:|---:|---:|
| HOME free | 546 | **546** | 0 | ≥ 350 ✔ |
| EXROM free | 1,340 | **1,278** | −62 | ≥ 800 ✔ |
| `storage.asm` / shell | 754 / 2,996 | 784 / 3,028 | +30 / +32 | |
| fixed RAM, ABI pins, package sizes | — | unchanged | 0 | `check_package_abi.py` passes |

EXROM was the right home (the whole transport lives there; no banking path changed). Remaining EXROM headroom for
Phase 2B/2C is **478 B above the floor** (the audit's EXROM estimate for the core was +60…+200 B net).

## 8. Verification

Targeted runs during development: all `D1-*`/`D2-*` cases (before and after), D6, D12–D15 (§5–§6), `make check`
(including the ABI drift checker, storage-contract checker and the V1 legacy assemblies) and `make budget`. The
baseline comparison used a temporary `git worktree` of `59610d5` with only the new test files copied in (removed
afterwards): **7 PASS / 17 FAIL** of the 24 new gate cases there (the 7 are the cases whose behaviour was already
right: `D1-checksum` message, `-wrong-name`, `-wrong-type`, `-header-truncated`, `D2-verify-identical`, `-wrong-type`,
`-wrong-name`); the `ABORTED` cases fail there with a harness `KeyError` because `STORAGE_LOAD.space_held` does not exist.

## 9. Final release-gate run [M]

`make check` rc 0; `make budget` HOME 546 / EXROM 1,278 free; one full `make test` (gate suite 1,304 s and known-defect suite 866 s, run concurrently; Phase 1 total was ≈ 23 min; **no Fuse/X11** —
`make -n test | grep -ci fuse` = 0; `make test-legacy` was **not** run), `make` exit status 0:

| Check | Phase 1 | Phase 2A |
|---|---|---|
| Headless smoke ROMs | 9/9 | all PASS |
| V2 standalone (fake services) | 38/38 | **38/38** |
| `v2_production_checks.py` | 19/19 | **19/19** (`FAILURES: 0`) |
| `v2_fill_check.py` | 10/10 | **10/10** |
| Production gate `v2_prod_regress.py` | 35 PASS | **57 PASS**, 0 XFAIL, 0 FAIL, 0 XPASS |
| Known defects `v2_known_defects.py` | 11 PASS, 53 XFAIL | **15 PASS, 72 XFAIL**, 0 FAIL, 0 XPASS |

Gate arithmetic: 35 − 2 (Phase 1 `tape-load-checksum`, `tape-verify-identical`, superseded by `D1-checksum` /
`D2-verify-identical`) + 24 new = 57. Known-defect arithmetic: XFAIL 53 − 6 (D1/D2, now fixed and in the gate) + 25 new
(D12 ×4, D13 ×4, D14 ×8, D15 ×9) = 72; PASS 11 − 2 (moved controls) + 6 new controls (D14 ×3, D15 ×3) = 15.
There is no XPASS and no unexpected failure. The gate suite is now the long pole of `make test` (the header-search timeouts of the
wrong-name/-type cases are the slow ones, ≈ 135 s each; tooling item X-1 in the work sequence).

## 10. Remaining limitations

1. **Destructive failure is not undoable.** A LOAD that fails after data started leaves an empty program; only a
   program-sized staging buffer could restore the old one (out of scope).
2. **Trailing garbage / corrupt record chains** in a tape with a valid checksum are still accepted (T-1, unchanged).
3. **Abort classification** uses a second SPACE read (§3); not testable for sub-microsecond taps.
4. **User-facing wording.** `docs/user_manual.md` message table updated; the generated `.docx` manual was not rebuilt.
5. D15/D14/D13/D12/D6 remain open by design (Phase 2C).
6. `LOAD … ARRAY` with a wrong version still says `LOAD FAILED` (D16; deferred to Phase 2C by the owner).

## 11. Not covered by synthetic tests — physical validation still required

The EAR signal is synthesised (15.6 kHz point-sampled pulses, ±226 T edge jitter); SPACE is injected at the port read.
Owner-run on a real recorder (work-sequence checkpoint 2.3): SAVE→LOAD→VERIFY of a small and a ≈ 6 KB program;
**deliberate dropout and a VERIFY mismatch**; **SPACE during LOAD (header wait and mid-block) — confirm `ABORTED`,
and that a mid-block abort leaves an empty program**; wrong-name tape; a package tape and a program tape carrying the
`$8200`/`$8100` words. None of the above is claimed as hardware-qualified.

## 12. Owner decisions at approval

1. **Array Store validation split.** Tape descriptor *structure and bounds* are validated at LOAD; *compatibility* with a
   program's declared array dimensions/type/width is checked at `DIM`. `D15-count-short` and `D15-count-long` are
   therefore **retargeted in Phase 2C** (not deleted, not weakened); the structural D15 cases remain LOAD-time checks.
2. **D16** (`BAD TAPE VERSION` wording for array tapes) is deferred to Phase 2C.
3. Floors unchanged: HOME ≥ 350 B, EXROM ≥ 800 B.
4. **Phase 2B** must investigate a HOME-minimal, EXROM-heavy Array Store architecture before any Phase 2C implementation.

## 13. Next step

Phase 2B (HOME-minimal vs EXROM-heavy Array Store comparison) — no Phase 2B recommendation was implemented here.

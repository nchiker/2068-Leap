# R9 production cutover ledger

Status: **R9 is a WIP and is not complete.** Production V2 cutover is active
on top of the immutable `cd2f1df` pre-cutover reference. The V2 HOME/EXROM
images build and boot in ZEsarUX.
The production command loop and core language paths are wired. The full R9
hardware gate is not yet closed: physical fixture playback has not completed
a production LOAD in ZEsarUX. The six V1-only optional extensions CPLOT,
AYREG, OUT, BLOCK, FRAME, and INVERT are outside this cutover's required
scope; they are omitted from the V2 production package set and are not
blockers. They may be reconsidered for later ROM or V2 package integration.

## Production architecture

The authoritative program remains the generic plain-text line store at
`$8455`. `RUN` traverses those records, creates a CR-separated whole-program
staging buffer, compiles the whole program, and executes the resulting V2
bytecode. `LIST`, editing, SAVE, and LOAD use the source representation.
Bytecode is regenerated on every RUN and is not saved to tape.

Cold boot initializes the shared memory, keyboard, and extension services,
sets `VARS_START` to the source ceiling, pages in EXROM, and enters
`V2_COMMAND_LOOP`. That loop uses the retained EXROM editor/input services.
Numbered lines are stored, replaced, inserted, deleted, navigated, and listed
through generic line-store operations. `RUN` returns to the editor after
execution or an error. Immediate statements use a leading colon. The
dispatcher also handles `NEW`, `SAVE`, `LOAD`, and `LOAD EXT`.

The production ROM does not include `basic/basic.asm`, the V1 command loop,
or `rom/exrom_checker.asm`. Shared memory, graphics, math, sound, keyboard,
banking, tape/storage, formatting, calculator, and editor modules remain in
the production image. `basic/editor_integration.asm` is not used: its
row-shadow renderer is tied to the old editor, while production reuses
`rom/exrom_editor.asm` and the V2 source renderer. `rom/exrom_checker.asm`
remains in the tree as a mixed-purpose historical source; its shared
calculator, SAVE/LOAD, and formatting services are included individually.

The decompiler remains available in standalone V2 builds and retains its
tests. Production `LIST` reads authoritative source and does not decompile
bytecode. The decompiler is not resident in this ROM: its assembled 4,716-byte
module cannot fit wholly in either current bank's remaining 2,166-byte HOME
or 2,773-byte EXROM space. A split/cross-bank implementation has not been
made. Bytecode decompilation/debugging therefore remains a standalone
capability.

## Assembled ROM accounting

Measured from the current SjASMPlus listings (`make budget`):

| Image/section | Assembled bytes used | Capacity | Free |
|---|---:|---:|---:|
| HOME | 14,218 | 16,384 | 2,166 |
| EXROM | 5,419 | 8,192 | 2,773 |
| Combined production ROM | 19,637 | 24,576 | 4,939 |

The production images are still padded to full 16KB and 8KB binary files.
The “used” numbers are exact addresses before the final padding directives,
not file sizes after padding.

HOME contains 788 bytes of memory services, 504 of I/O, 2,118 graphics,
403 math, 55 sound, 144 interrupt, 54 banking, 260 extension registry,
4,423 V2 VM, and 5,168 V2 compiler bytes, plus the 301-byte driver/vector
area. EXROM contains 719 bytes of storage, 196 format, 1,931 calculator,
17 sound, 730 editor, and 1,602 V2 shell bytes, plus 224 bytes of service
entries/driver. The V2 decompiler is not included.

## Integrated RAM map

Ranges below are assembled reservations and architectural ceilings unless
explicitly marked observed. “Peak use” has not been exhaustively measured
for every runtime path.

| Range | Bytes | Class | Lifetime / capacity evidence |
|---|---:|---|---|
| `$4000-$7FFF` | 16,384 | N: video RAM | Platform/hardware-sensitive bitmap and attributes. |
| `$8000-$8454` | 1,109 | A, G, I, M: shared sysvars and service scratch | Resident, editor, keyboard, tape/storage, calculator, graphics. |
| `$8455-$9454` | 4,096 | B: authoritative source line store | Persistent/editable. 4,096 encoded bytes including per-line headers and CRs; effective text bytes depend on line count. |
| `$9455-$A454` | 4,096 | G: whole-program source staging | Compile only; coexists with durable source. |
| `$A455-$B3FF` | 4,011 | C: bytecode | Compile/RUN; compiler checks the `$B400` ceiling. |
| `$B400-$B459` | 90 | D/F: 18 floating records × 5 | RUN; 16 scalar values plus two temporaries. |
| `$B460-$B4DF` | 128 | E: arrays | RUN; four arrays × 16 signed 16-bit elements. |
| `$B4E0-$B4FF` | 32 | N: reserved gap | No live allocation. |
| `$B500-$B5BF` | 192 | F: six string records × 32 | RUN; four named strings plus two temporaries, up to 31 content bytes each. |
| `$B5C0-$B5FF` | 64 | N: reserved gap | No live allocation. |
| `$B600-$B6E3` | 228 | A/J/M: VM state envelope | RUN. Operand stack `$B604-$B67F`: 124 bytes/41 three-byte records. Call stack `$B694-$B69F`: six return addresses. Gaps are reserved. |
| `$B700-$B72F` | 48 | D: scalar symbol/value records | RUN; 16 three-byte entries. |
| `$B730-$B7FF` | 208 | N: reserved gap | No live allocation. |
| `$B800-$B88F` | 144 | G: compiler symbol names | Compile; 16 entries × 9 bytes; retained for debugging/decompilation. |
| `$B890-$B8B7` | 40 | G: array compiler symbols | Compile; four entries × 10 bytes. |
| `$B8B8-$B8FF` | 72 | N: reserved gap | No live allocation. |
| `$B900-$B957` | 88 | G: label table | Compile; eight entries × 11 bytes. |
| `$B960-$B9B7` | 88 | G: branch-fixup table | Compile; eight entries × 11 bytes. |
| `$B9B8-$B9FF` | 72 | N: reserved gap | No live allocation. |
| `$BA00-$BA5B` | 92 | G: parser/compiler scratch | Compile. Includes `SRC_PTR`, `EMIT_PTR`, token, expression, and statement state. |
| `$BA60-$BA83` | 36 | G: string compiler symbols | Compile; four entries × 9 bytes. |
| `$BA84-$BAFF` | 124 | N: reserved gap | No live allocation. |
| `$BB00-$BBFF` | 256 | H: decompiler fragments | Decompile only; retained reservation, not production-resident code. |
| `$BC00-$BD8F` | 400 | H: decompiler output | Decompile only. |
| `$BD90-$BE6F` | 224 | H/M: decompiler state/scratch | Decompile only. |
| `$BE70-$BE7F` | 16 | I/M: V2 shell traversal/draw/command scratch | Editor/command loop. |
| `$BE80` | 1 | N: reserved gap | No live allocation. |
| `$BE81-$BE83` | 3 | I/M: request type and package length | Command loop and package load/save. |
| `$BE84-$BED7` | 84 | N: reserved gap | No live allocation. |
| `$BED8-$BEEF` | 24 | L/M: extension call and registry scratch | Registration or VM package invocation. |
| `$BEF0-$BEFF` | 16 | N: reserved gap | No live allocation. |
| `$BF00-$BFA7` | 168 | L: extension registry | Persistent, 12 records × 14 bytes. |
| `$BFA8` | 1 | L/M: extension type scratch | Registration only. |
| `$BFA9-$BFAF` | 7 | N: reserved gap | No live allocation. |
| `$BFB0-$BFBA` | 11 | L/M: sprite package scratch | Package call only. |
| `$BFBB-$BFFF` | 69 | N: reserved gap | No live allocation. |
| `$C000-$D7FF` | 6,144 | M/N: flood-fill visited map | HOME RAM; package calls page EXROM out so this region is accessible. |
| `$D800-$E7FF` | 4,096 | M: flood-fill work stack | Temporary graphics work. |
| `$E800-$F0FF` | 2,304 | L/N: sprite storage | Eight 288-byte image/background slots. |
| `$F100-$F17F` | 128 | A: label storage | Reserved platform data. |
| `$F180-$F227` | 168 | A/N: UDG patterns | Persistent platform graphics. |
| `$F228-$F2A7` | 128 | I: edit/input and LOAD-name buffers | Editor/command input. |
| `$F2A8-$F327` | 128 | I/M: text/display buffer | Reusable source display copy. |
| `$F328-$F3D2` | 171 | A/M: legacy scratch/service ABI reservation | Some V1-owned state is dormant after cutover. |
| `$F400-$F7FF` | 1,024 | L: loadable package window | One package at a time; registry is cleared before replacement. |
| `$F800-$FEFF` | 1,792 | K: machine-stack headroom | Available below initial `SP=$FF00`; exact worst-case production peak not measured. |
| `$FF00-$FFFF` | 256 | N: above initial stack pointer | Not counted as downward stack growth. |

Lifetime overlays are not used for the source, staging, bytecode, runtime
tables, or extension state. Compiler scratch and decompiler scratch are not
both active in production, but the decompiler is not resident. No claim is
made that its reserved RAM can be reused without a separately verified
layout change.

### Fixed symbols and entry addresses

The integrated source/code ceilings are in `include/v2_layout.inc`. The
compiler, VM, registry, and decompiler table symbols remain symbolic `EQU`s
in their owning modules:

| Symbol | Address |
|---|---:|
| `PROG_AREA_START` | `$8455` |
| `V2_SOURCE_END` / `V2_SOURCE_STAGE` | `$9455` |
| `VM_CODE_BASE` | `$A455` |
| `V2_CODE_LIMIT` | `$B400` |
| `FLOATTAB_BASE` | `$B400` |
| `ARRTAB_BASE` | `$B460` |
| `STRTAB_BASE` | `$B500` |
| `VM_STACK_FLOOR` / `VM_STACK_TOP` | `$B604` / `$B680` |
| `VM_CALL_STACK_FLOOR` / `VM_CALL_STACK_TOP` | `$B694` / `$B6A0` |
| `SYMTAB_BASE` | `$B700` |
| `CSYMTAB_BASE` | `$B800` |
| `ARRSYMTAB_BASE` | `$B890` |
| `LABELTAB_BASE` / `FIXUPTAB_BASE` | `$B900` / `$B960` |
| `SRC_PTR` / `EMIT_PTR` | `$BA00` / `$BA02` |
| `STRSYMTAB_BASE` | `$BA60` |
| `DECOMP_OUT_BUF` / `DECOMP_END_ADDR` | `$BC00` / `$BD9F` |
| `EXT2_TABLE` | `$BF00` |
| `PROG_AREA_MAX` | `$C000` |
| `EXTENSION_MODULE_BASE` / `EXTENSION_MODULE_LIMIT` | `$F400` / `$F800` |

The HOME-to-EXROM service entries are centralized as `_ADDR` constants in
`include/v2_ktab.inc`; both the EXROM `ORG`s and HOME references use those
constants. The code region end guard uses `V2_CODE_LIMIT`. The V2 package
execution target is copied through `VM_EXT_EXEC_PTR` instead of being held in
a register across bank changes. Source searches found no remaining direct
references in the production driver to the former experimental `$8500`
FLOATTAB placement. Fixed platform boundaries such as `$C000`, `$F400`, and
`$FF00` remain defined through their owning platform symbols or layout
constants.

## Runtime limits and observed use

| Resource | Architectural maximum | Observed/tested |
|---|---:|---|
| Stored source | 4,096 encoded bytes | A 210-byte multi-line program ended at `$8527`, beyond the old `$8500` collision point; it ran and returned 25. |
| Staged source | 4,096 bytes | Whole-program line traversal tested with labels and REM lines. |
| Bytecode | 4,011 bytes | Emit-bound guard assembled; full-ceiling compile not yet measured. |
| Numeric variables | 16 scalar slots; 18 float records including two temporaries | Integer and FLOAT arithmetic tests passed. |
| Arrays | 4 × 16 × 16-bit values = 128 payload bytes | Multiple arrays, reads/writes, and upper bound tested. |
| Strings | Four named × 31 content bytes, plus two temporary records | String functions and string assignment tests passed. |
| VM operand stack | 124 bytes, 41 complete records | Standalone VM and production error-return paths passed; production high-water not instrumented. |
| VM call stack | Six return addresses | Reserved; recursion is not implemented. |
| Machine stack | 1,792 bytes maximum available below `$FF00` | Earlier nested-expression canary observed 126 bytes at the R8.9 checkpoint; new production worst case not measured. |
| Package RAM | 1,024 bytes for one active module | Current modules: MODE 165, SPRITE 832, PRINTER 345, SHAPES 762 bytes. |
| Extension registry | 12 entries | Packages tested through real V2 registration and calls. |

## SAVE/LOAD and listing semantics

Program SAVE writes the generic source-record region from `$8455` to
`PROG_END`. LOAD restores source records, sets `PROG_END`, restores the
`$9455` source ceiling, and resets editor/runtime state. RUN recompiles the
source. Bytecode is not persisted. `LIST` and source editing never depend on
the decompiler. Decompiler output remains a bytecode debugging/inspection
path in standalone builds.

Production SAVE/NEW/LOAD/verification passed in real ZEsarUX using the
deterministic receive/send harness. A production real-tape LOAD attempt has
not yet received a complete header/data block there. The committed TZX
fixture’s measured leader count was `$BE`; `$C6` rejected it, so the receiver
now uses the existing `$A0` calibrated threshold. The R8-era real Fuse
round-trip remains the successful physical tape test. This does not count as
a completed ZEsarUX production cassette round-trip.

`STORAGE_PROGRESS_HOOK` is not initialized by the V2 production boot/shell.
`STORAGE_REPORT_PROGRESS` therefore returns without drawing the V1-style
status bar during the autoload probe. `V2_AUTOLOAD_TEST` calls `V2_LOAD` at
boot, but that call alone does **not** imply a visible `LOADING` message. An
earlier expectation that this test should visibly display `LOADING` was
incorrect. The project owner reported that the proposed autoload image did
not show that text. The owner had previously seen a loading screen during a
ZEsarUX session, but this session did not establish which ROM/process or UI
produced it; do not attribute that observation to the production autoload
test.

## Cassette investigation evidence and limits

The production path under investigation is `V2_COMMAND_LOOP` in
`rom/exrom_v2_shell.asm` → `V2_SAVE`/`V2_LOAD` → `STORAGE_SAVE`/
`STORAGE_LOAD` in `kernel/storage/storage.asm` →
`STORAGE_SEND_BLOCK`/`STORAGE_RECEIVE_BLOCK`. A program LOAD supplies the
destination `$8455` (`PROG_AREA_START`) and its 4,096-byte source-store limit;
it receives the generic source records, then returns to V2 source listing and
RUN recompiles them. The optional `LOAD EXT` path receives into the package
window instead.

The physical fixture is `tests/fixtures/storage_verify.tzx`, a TZX Direct
Recording block at 80 T-states/sample. `tools/check_tape_fixture.py` decodes
its two pulse segments and verifies the `verify` program header, three
length-prefixed BASIC source lines (`PRINT -123`, `PRINT str$(456)`,
`PRINT sqr(2)`), declared lengths, and header/data XOR checksums. This
validates the fixture encoding, not the ROM's live receiver.

The receiver originally used the stock leader comparison `$C6`. The real
ZEsarUX timing monitor measured this fixture's pilot count as `$BE`; because
`$BE` is below `$C6`, the stock threshold rejects this recording. `$A0` was
selected because the measured `$BE` count exceeds `$A0`, and the ROM's
comparison then accepts the pilot. The change is in
`STORAGE_LEADER_GAP` in `kernel/storage/storage.asm`; the data-bit boundary
remains `$CB`. The separate real ZEsarUX timing monitor reached its green
PASS indication at about 9 seconds, confirming that the leader pulse passes
the calibrated threshold. This does not establish successful sync or data
decoding.

With the sync monitor and a ZRCP breakpoint set at its `START.sync` label
(`$0135`), the test reached `PC=$0135` after about 10.5 seconds. This shows
that the pilot was counted and execution entered sync search. It does not
show that either sync edge was accepted or that a header byte was received.
The production autoload probe later remained in `STORAGE_RECEIVE_BLOCK`'s
edge-sampling/polling path with `STORAGE_OP_STATE=3` (LOADING), an all-zero
`STORAGE_HEADER_BUF`, and `PROG_END=$8455`. No complete header/data block was
observed. No exact PC/register snapshot was retained for that production
receiver observation.

During one graphical ZEsarUX run, `/proc/<pid>/fdinfo` showed the open
`/tmp/zesarux-1000/tmp_storage_verify.tzx.rwa` offset advancing (4,096 bytes
at roughly 0.25 s and 16,384 bytes at roughly 1.0 s). This confirms that the
emulator consumed the converted recording; it does not prove what pulse the
ROM sampled. `realtape-open` was issued through local ZRCP after converting/
opening the fixture, then the TS2068 was reset so playback overlapped the
autoload receiver.

Environment limitations materially constrained this session. `ts2068-debug`
starts headless with `--ao null`; this does not provide ZEsarUX's cassette
audio-sampling path. The earlier physical playback attempt therefore used
`--vo xwindows --ao pulse`, `DISPLAY=:1`, and ZRCP. At the end of the session,
the shell still reported `DISPLAY=:1`, but `xdpyinfo` could not open it. A
later launch printed `Error opening display`, fell back to null video, and
was stopped. No GUI state was observed in that later attempt. The owner
reported that the autoload image did not show `LOADING`; as described above,
that text was not expected without a progress hook. Do not infer tape state
from that screen report.

Deterministic receive/send tests execute the real storage header search,
filename/type/length checks, callbacks, and state transitions while replacing
only the timed pulse transport. The repository's `make test` includes eleven
storage/package/autorun cases through `tools/run_storage_named_load_test.sh`;
the separate V2 standalone set has 14 passing tests. Earlier real-ZEsarUX
production interaction also exercised SAVE/NEW/LOAD/LIST/RUN and package
calls with deterministic transport. These results prove the non-physical
storage and production control paths only. The legacy `rom/test_v2_save_load.asm`
is a standalone bytecode-persistence experiment and is not proof of the R9
authoritative-source tape representation.

## Test results and open items

- `make check`: pass, including storage framing/contract, source analysis,
  Z80 simulator checks, and standalone ROM assembly.
- `make test`: pass, including nine real-ZEsarUX smoke images, two editor
  flows, eleven storage/package/autorun cases, and the 14 V2 standalone
  regressions. The complete target was rerun after the shared layout-symbol
  changes and passed.
- `make budget`: pass; exact ROM and principal RAM regions reported above.
- `make v2-packages`: pass; all four modules fit the 1,024-byte package
  window and TZX files assemble.
- `make build`: passed again while preparing the handoff. A test-only
  24,576-byte combined image with `V2_AUTOLOAD_TEST` also assembled; its
  visible screen behavior was not validated in this session.
- Final `make test`: passed after granting the headless ZEsarUX runner its
  required localhost ZRCP access. Results: 9/9 smoke tests, 2/2 editor flows,
  11/11 deterministic storage/package/autorun cases, and 14/14 V2 standalone
  regressions. An initial sandboxed invocation stopped because localhost
  ZRCP was denied; the escalated rerun completed with exit 0.
- Final `make budget`: passed and reproduced the exact HOME/EXROM, source,
  staging, and bytecode figures above.
- Final `make v2-packages`: passed; MODE 165, SPRITE 832, PRINTER 345, and
  SHAPES 762 payload bytes were generated as TZX packages.
- V2 standalone regressions: 14/14 green-border PASS in real ZEsarUX after
  the cutover changes.
- Production interactive tests already exercised in real ZEsarUX: cold
  boot, immediate statements, multi-line store/replace/insert/delete,
  navigation, LIST, RUN/re-entry, rerun after edits, syntax/runtime error
  recovery, integer/FLOAT/string/array/control flow, graphics/system calls,
  and source-capacity growth past `$8500`.
- A fresh post-relocation production-ROM run stored three numbered lines
  (`A=2`, `A=A+3`, `PRINT A`), advanced `PROG_END` to `$8476`, executed RUN,
  and returned to `IO_READ_KEY.wait_hit` with `VM_ERROR_CODE=0` and
  `VM_HALTED=1` in real ZEsarUX.
- Deterministic production SAVE/NEW/LOAD/LIST/RUN and MODE/SHAPES package
  calls passed in real ZEsarUX.
- The old `tests/*.txt` V1-language suite is no longer the production test
  target. Several old package fixtures require V1-only service symbols and
  do not assemble against the V2 production image. Their last known V1
  implementation remains available at `cd2f1df` in Git. The new default
  V2 standalone target is `tools/run_v2_standalone_tests.sh`.

## Still open before declaring R9 complete

1. Complete and record the production hardware SAVE → clear/NEW → physical
   LOAD → LIST → RUN round-trip in ZEsarUX. No complete physical production
   header/data receive or end-to-end round-trip has been proven there.
2. The four semantic-audit corrections remain pending: FLOAT operand/type
   boundary correctness; nested FOR/NEXT; DIM/decompiler semantics; and
   recursion-safe PROC/DEF FN parameter handling. DIM's source LIST/edit/
   SAVE/LOAD impact is reduced by authoritative source storage, but its
   bytecode decompiler behavior is unchanged and is not solved.

The project owner has explicitly classified CPLOT, AYREG, OUT, BLOCK, FRAME,
and INVERT as optional for R9. The production set is MODE, SPRITE, PRINTER,
and SHAPES. Omitting those six optional capabilities does not change the R9
completion gate; any later ROM integration or V2 package grouping belongs to
subsequent work.

The DIM/decompiler round-trip defect is not solved. Authoritative source
means production source LIST, editing, SAVE, and LOAD do not lose DIM
declarations through bytecode decompilation, which lowers its production
severity. Bytecode decompiler round-trip semantics remain unchanged and the
standalone decompiler test remains required.

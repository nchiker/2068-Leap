# R9 WIP handoff for Claude

**R9 is not complete.** This is a safety/handoff note for the WIP checkpoint,
not an acceptance report. The immutable pre-cutover reference is `cd2f1df`.
The current WIP checkpoint commit will contain the R9 implementation and
these documents; it must not be read as closing the physical cassette gate.

Read this file and [`R9_CUTOVER_LEDGER.md`](R9_CUTOVER_LEDGER.md) first. The
ledger is the detailed source for addresses, assembled ROM accounting, and
the integrated RAM map. No further cassette-receiver, timing, display, or
progress changes were made while preparing this handoff.

## Current implementation

Production builds now use `rom/v2_home.asm` and `rom/v2_exrom.asm`; the V1
language core is not linked into production. Cold boot initializes shared
platform state, sets the source-store bound, pages EXROM, and enters
`V2_COMMAND_LOOP` in `rom/exrom_v2_shell.asm`. The shell uses the retained
editor and generic line-store services. It supports numbered source entry,
replacement/insertion/deletion, navigation, source `LIST`, immediate
statements, `RUN`, `NEW`, `SAVE`, `LOAD`, and package loading. `RUN` collects
the complete authoritative source, compiles it as one unit, runs the V2 VM,
and returns to the editor after completion or an error. SAVE/LOAD persist
source records; bytecode is regenerated at each RUN.

The production packages are MODE (165 bytes), SPRITE (832), PRINTER (345),
and SHAPES (762), each under the 1,024-byte package window. Six optional
V1-only packages—CPLOT, AYREG, OUT, BLOCK, FRAME, and INVERT—are deliberately
omitted from R9 scope. Do not restore them or redesign the package system as
part of this handoff.

`LIST`, editing, and persistence use authoritative source text. The V2
decompiler remains a standalone/debugging capability with its tests; it is
not resident in the production image. The DIM/decompiler round-trip defect
is not solved. See the ledger for the production dependency classification
and full RAM allocation table.

## PROVEN

### Builds, regression tests, and assembled sizes

The ledger records these completed results:

- `make check` passed, including source/storage checks, simulator checks, and
  smoke-image assembly.
- `make test` passed: nine ZEsarUX smoke images, two editor flows, eleven
  storage/package/autorun cases, and 14 standalone V2 regressions.
- `make budget` passed. Assembled production usage is HOME **14,218 / 16,384
  bytes** (2,166 free), EXROM **5,419 / 8,192 bytes** (2,773 free), combined
  **19,637 / 24,576 bytes** (4,939 free). These are pre-padding code/data
  extents; distribution images are padded to bank size.
- `make v2-packages` passed; all four packages assembled and fit their
  package window.
- This handoff session reran `make build` successfully. It also assembled a
  24,576-byte test-only combined image with `V2_AUTOLOAD_TEST`; this is an
  assembly result only, not GUI or physical-tape evidence.

The ledger records the full real-ZEsarUX standalone result: 14/14 green-border
tests. It also records observed production interaction: cold boot, immediate
statements, multiline insertion/replacement/deletion, navigation, LIST,
RUN/re-entry, edits and reruns, syntax/runtime error recovery, integer/FLOAT,
strings, arrays, control flow, graphics/system calls, and a source program
larger than the old `$8500` collision point. A recorded production run stored
three lines, reached `PROG_END=$8476`, returned to the editor, and had
`VM_ERROR_CODE=0`, `VM_HALTED=1`.

### Deterministic storage and package execution

Production SAVE/NEW/LOAD/LIST/RUN and MODE/SHAPES package calls were
previously exercised in real ZEsarUX with deterministic receive/send
transport. The deterministic replacement preserves the real storage
header/type/name/length/state paths and substitutes only the timed pulse
transport. `make test` also builds and runs the eleven `run_storage_named_load_test.sh`
cases (program, package, invalid package metadata, wildcard, save-missing,
roundtrip, and autorun bounds/roundtrips).

The old `rom/test_v2_save_load.asm` proves a standalone bytecode
save/load/decompile/run experiment with fake transport; it does not prove R9's
source-record persistence path. Likewise, deterministic storage tests do not
prove real tape waveform reception.

### RAM and ROM measurements

The authoritative RAM ledger is in `R9_CUTOVER_LEDGER.md`. Major bounded
regions are:

- source records: `$8455-$9454`, 4,096 encoded bytes;
- complete-source compiler staging: `$9455-$A454`, 4,096 bytes;
- bytecode: `$A455-$B3FF`, 4,011 bytes;
- runtime float records: 90 bytes, arrays: 128 bytes, strings: 192 bytes;
- VM operand stack: 124 bytes (41 three-byte records), VM call stack: six
  return addresses;
- maximum machine-stack headroom below `$FF00`: 1,792 bytes; production
  high-water is not measured;
- active package window: `$F400-$F7FF`, 1,024 bytes.

No source/staging/bytecode/runtime overlays are claimed. The entire ledger
contains the remaining fixed allocations, gaps, symbols, platform-sensitive
areas, and measured/estimated distinctions.

## UNPROVEN: physical cassette gate

The R9 completion gate is still the complete production hardware sequence:

**SAVE → clear/NEW → physical LOAD → LIST → RUN** in production ZEsarUX,
followed by confirmation that the source listing and program behavior match.

No complete physical production header/data receive has been observed in
ZEsarUX, and no production physical-tape round-trip has passed. The R8-era
real Fuse Direct Recording round-trip on 2026-08-26 is a successful physical
transport test for the earlier V1-linked image; it is not production V2
ZEsarUX validation.

The production execution path is:

1. `V2_COMMAND_LOOP` dispatches SAVE/LOAD in `rom/exrom_v2_shell.asm`.
2. `V2_SAVE`/`V2_LOAD` prepare filename/type and call `STORAGE_SAVE` or
   `STORAGE_LOAD` in `kernel/storage/storage.asm`.
3. Program LOAD requests at most `V2_SOURCE_END-PROG_AREA_START` bytes into
   `PROG_AREA_START` (`$8455`). On success it updates `PROG_END`; later RUN
   recompiles the source. `LOAD EXT` uses the package receive region.
4. `STORAGE_LOAD` searches a header and then receives the data block through
   `STORAGE_RECEIVE_BLOCK`; `.leader`, `.sync`, `.edge2`, and `.edge1` implement
   pulse search and sampling.

### Cassette threshold evidence

`STORAGE_LEADER_GAP` was changed from stock `$C6` to `$A0` in
`kernel/storage/storage.asm`. A real ZEsarUX pilot timing probe measured the
checked-in fixture's pilot count as `$BE`: `$BE < $C6`, so `$C6` rejected it;
`$BE > $A0`, so `$A0` admits it under the receiver's comparison. `$A0` was
chosen from this measured fixture result. The data-bit comparison remains
`$CB`; the stock `EDGE2` fall-through into a second `EDGE1` measurement is
also retained. The standalone timing monitor reached green at about 9 s,
showing the pilot passes the calibrated cutoff.

After this correction, a ZRCP breakpoint at `START.sync=$0135` in
`rom/test_tape_sync_monitor.asm` hit at about 10.5 s. This proves leader
counting reached sync search only. It does **not** prove that sync edges or a
header were accepted. A later production real-tape autoload probe observed
`STORAGE_OP_STATE=3`, an all-zero `STORAGE_HEADER_BUF`, `PROG_END=$8455`, and
the CPU polling/edge-sampling path in `STORAGE_RECEIVE_BLOCK`. No complete
header or data block arrived; no precise PC/register snapshot was retained
for that production probe.

The fixture `tests/fixtures/storage_verify.tzx` is a Direct Recording TZX at
80 T-states/sample. Its decoded content is the `verify` header and three
native source lines: `PRINT -123`, `PRINT str$(456)`, and `PRINT sqr(2)`, with
declared lengths and both checksums validated by `tools/check_tape_fixture.py`.
During an earlier graphical ZEsarUX run, the RWA file descriptor advanced
from 4,096 bytes at about 0.25 s to 16,384 bytes at about 1.0 s. This proves
ZEsarUX consumed the converted recording, not that the ROM decoded the same
pulses.

### Environment and disproven screen assumption

The physical probe used local ZRCP `realtape-open` for the TZX and reset the
TS2068 while playback was active. `ts2068-debug`'s usual headless launch uses
`--ao null`; this does not provide the audio path needed for real-tape
sampling. The earlier physical run therefore used `--vo xwindows --ao pulse`
with `DISPLAY=:1`.

At the end of this session, the shell still had `DISPLAY=:1`, but
`xdpyinfo` could not connect. A later `zesarux --vo xwindows --ao null`
launch printed `Error opening display`, fell back to null video, and was
stopped. There is no observed GUI state from that launch. The project owner
reported that the proposed test image did not show `LOADING`.

**Correction: the earlier assumption that the autoload path should visibly
display `LOADING` was incorrect.** `V2_AUTOLOAD_TEST` invokes `V2_LOAD` at
boot, but V2 production never sets `STORAGE_PROGRESS_HOOK`. The storage
routine's `STORAGE_REPORT_PROGRESS` therefore returns without drawing a
status display. Do not treat presence/absence of a `LOADING` message as
evidence that the autoload call did/did not reach tape reception. The owner
had seen a loading screen in an earlier session, but its source was not
identified here; preserve that as an unattributed observation.

## Four semantic corrections remain pending

Do not start these as part of this handoff:

1. FLOAT operand/type-boundary correctness.
2. Nested FOR/NEXT handling and matching the NEXT variable to the active FOR.
3. DIM/decompiler semantics. Authoritative-source LIST/edit/save/load removes
   source DIM loss from normal production behavior; bytecode decompilation
   remains unchanged, so the original defect is not solved.
4. Recursion-safe PROC/DEF FN parameter handling.

Do not implement DEF FN, start R10/R11, restore optional V1 packages, or make
unrelated architecture changes.

## Recommended first action

Read `R9_CUTOVER_LEDGER.md`, verify the WIP checkpoint and clean tree, and
coordinate the physical SAVE/LOAD test with the project owner using the
interactive/manual handling that this path requires. Begin by reproducing
the production SAVE → NEW → LOAD → LIST → RUN sequence and record the actual
screen and machine/receiver state separately. Do not use the autoload
`LOADING` text as a success criterion. R9 remains open until that physical
production round-trip is demonstrated and documented.

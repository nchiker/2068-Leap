# SAVE "name" ALL -- tape format, checks and lifecycle

Status: implemented in the V2 Enhanced release (`integration/v2-final-rom`, commit `07616e7`; the
identity CRC covers the package registry from `ef81f49`). **Format minor 2 (v2.2): segment 2 is a second
data block** (section "The block"). Code: `rom/v2_saveall.asm` (HOME: layout, CRC, LOAD checks, the gap),
`rom/v2_saveall_crc.asm` (HOME, in the old KTAB space), `SA_BUILD`, the block-2 send in `V2_SAVE` and
`V2_RECV_S` in `rom/exrom_v2_shell.asm` (EXROM). Tests: `tools/v2_saveall_checks.py` (part of
`tools/run_v2_prod_tests.sh` and so of `make test`).

## Commands

| Command | Writes | On LOAD |
|---|---|---|
| `SAVE "name"` | the program text (unchanged) | program, no variables |
| `SAVE "name" ALL` | program + the variable session + the Array Store | program and its session; the Array Store is replaced by the saved one |
| `LOAD "name"` | -- | whatever the tape holds (`LOAD "name" ALL` is the same command) |
| `VERIFY "name"` | -- | compares a plain or an ALL tape with memory |

`SAVE "name" ALL` with no session since the last edit first starts one for the stored program
(fresh variables), so the tape then carries zero / empty variables and the Array Store. If the
program does not compile, its compile error is shown and nothing is written.

## The block

A 17-byte header (type 0, name, length, the V2 format word in the autostart field, PROGLEN), a data
block 1 and, from format minor 2, a data block 2. PROGLEN -- the Spectrum "program part" length -- is
the program's own length; a plain `SAVE` has PROGLEN = data length (and no block 2); in a
`SAVE ... ALL` tape block 1 is longer than PROGLEN and the rest is the session. The header's length is
block 1's. **Block 2 is segment 2, sent from its own address** (`ARR2_BASE .. ARR2_END`, S bytes, no
copy), after a silent gap of about 4.5 s (`SA_GAP`; see "The gap"). Block 1:

| Offset in the data | Bytes | Contents |
|---|---|---|
| 0 | PROGLEN | the program text (`PROG_AREA_START .. PROG_END`), exactly as `SAVE` writes it |
| PROGLEN | `ARRAYS_END - PROG_END` | the compile symbol table, the 80-byte session gap and the array arena, at their own addresses |
| ... | W | `VARS_START .. SESS_CODE_END`: the run-time tables, the compile zone and the session's bytecode |
| ... | 49 | the session cells `$B800 .. $B830` (symbol counts, table bases, ends, `SESS_*`, `SA_AE` = ARRAYS_END) |
| ... | 2 | the **segment-2 CRC**: CRC-16 of block 2's S bytes (`$FFFF` for an empty segment 2) |
| ... | 2 | the **identity CRC**: CRC-16 of HOME `$0000-$3FFF`, then EXROM `$C000-$DFFF`, then the package registry `EXT2_TABLE` (168 bytes: each slot's generation, name, entry) |
| ... | 2 | CRC-16 of every preceding byte of block 1 (program included) |

The tail is 55 bytes (it was 53 in minor 1, where segment 2 was part of this block).

CRC-16/CCITT-FALSE: polynomial `$1021`, initial value `$FFFF`, MSB first, no final XOR, stored low
byte first. `tools/v2_saveall_checks.py` has a Python reference (`crc16`).

Block 1 is laid out *in place*: for the SAVE the W span is moved down to `ARRAYS_END` (not copied),
the tail is written after it, the block is sent, and the span is moved back; segment 2 is sent where it
is. So SAVE ALL needs no free memory for a copy; its one limit is that block 1 must end at or below
`V2_CODE_LIMIT` (`$B600`): bytecode + 55 bytes must not exceed the bytecode area (~4.0 KB) plus the free
main memory, which holds in practice. Otherwise `OUT OF MEMORY` and nothing is sent. (In minor 1 segment
2 was part of this image, which is what limited a program with a large Array Store.)

The tape format word's minor version is 2 from v2.2 (`V2_FORMAT_MINOR`; it was 1 for the first ALL tapes).
The version rule is unchanged: a tape's minor may not exceed the ROM's, so older V2 ROMs refuse every
tape this ROM writes (instead of misreading a session), and this ROM loads minor-1 and minor-0 tapes.
A minor-1 ALL tape comes from another ROM build, so its identity CRC cannot match: it loads its program
and says `NO VARIABLES`, as any other-ROM tape does (its single-block layout is never interpreted).

## The gap between the blocks

After block 1 the SAVE leaves **about 4.5 s of silence** (`SA_GAP`, 4650 passes of 3,389 T at 3.5 MHz,
interrupts off, SPACE tested every pass) and then sends block 2. LOAD needs the time: after block 1 it
computes the block CRC and the identity CRC (about 3-4 s together, section "LOAD") before it listens for
block 2, whose pilot lasts only about 1.8 s; the receiver then waits up to 8.6 s for it. The figure is a
hardware number: it is checked in emulation (`sa-gap`) and by the real tape only once the hardware
checklist is run. SPACE during the gap: `ABORTED`, block 2 not sent. SPACE during block 2: `ABORTED`.

## LOAD: checks before anything is used

LOAD receives block 1 into `PROG_AREA_START ..` (up to `V2_CODE_LIMIT`). A plain block
longer than the main pool is refused (`LOAD FAILED`). For an ALL block (`SA_RESTORE`):

1. the data must be long enough for the 55-byte tail;
2. **block CRC** (block 1) -- mismatch: `LOAD FAILED`, the program is cleared (as for any corrupt load: the
   old program was already overwritten);
3. **identity CRC** -- the image is only valid with exactly the ROM and the package registration that
   wrote it (the bytecode, the layout and the package-statement references depend on them);
   mismatch: the program is kept, the variables are not loaded (`NO VARIABLES`);
4. the session cells are installed (the Array Store's end is remembered first);
5. **address chain** -- these words must be nondecreasing: `PROG_END`, `SYM_BASE_V`, `PROG_END`,
   `SYM_END_V`, `SESS_ARENA_BASE`, `ARRAYS_END`, the five table bases, `V2_SOURCE_END`,
   `VM_CODE_BASE`, `SESS_CODE_END`, `V2_CODE_LIMIT`, `ARR2_BASE`, `PAS_END`, `ARR2_END`,
   `ARR2_LIMIT` -- every region boundary lies where the layout allows;
6. **partition** -- `ARRAYS_END + W + 55` must equal block 1's end exactly;
7. **pointers** -- every array pointer in the saved tables (read in the image) must be 0, inside
   the arena or inside segment 2: no pointer from the tape is used unchecked;
8. **block 2** (`V2_RECV_S`, then `SA_FINISH`) -- segment 2 (S bytes, from the cells; it cannot pass
   `ARR2_LIMIT`: step 5) is received straight into `$E000`, and its CRC must equal the one in the tail;
9. only then: the W span is moved up into place, `VARS_START` and the VM registers are set, and the
   session is current.

Any failure in steps 4-7 restores the Array Store's end, discards the variables (`NO VARIABLES`)
and keeps the program: **the Array Store present is kept** (so a tape from another ROM never costs the
store). A failure of step 8 -- no block 2 within the receiver's 8.6 s, SPACE, a dropout, the transport
checksum or the segment-2 CRC -- happens after segment 2 was written, so it also **empties the Array
Store** (`PAS_END = ARR2_BASE`); the report is the same (`NO VARIABLES`, program kept). An interrupted
or truncated block 1 fails in the transport as before (`LOAD FAILED` / `ABORTED`, the existing failure
classes).

After a successful LOAD, `: PRINT x`, `: GOTO label`, `CLEAR`, `RUN` behave exactly as after the
program had run on this machine (`V2_SESSION_VARIABLES.md`).

**Packages.** The saved bytecode names package statements by registry slot and generation, and the
generation counter restarts at every boot -- so another package could answer to them. The identity
CRC therefore covers the package registry: load the same package, once, before the ALL tape
(`LOAD ... EXT` ends any session, so it must come first); with another package or none, the program
loads and the variables are refused (`NO VARIABLES`) -- `sa-package-mismatch`, `sa-package-same`.

## VERIFY

`VERIFY "name"` with a session first lays memory out exactly as `SAVE ... ALL` would (CRCs
included), compares block 1, and for an ALL tape then compares block 2 with segment 2; it moves the span
back before its message. A plain tape compares only the program part (PROGLEN, which equals the data
length). If the layout does not fit (the SAVE would have been `OUT OF MEMORY`), an ALL tape reports
`VERIFY FAILED`. A missing, damaged or different block 2 is `VERIFY FAILED` (SPACE: `ABORTED`).

## Restoring the span: SA_BUILT

`SA_BUILD` sets `SA_BUILT`; `V2_SHOW_MESSAGE` -- which every SAVE and VERIFY outcome ends in,
success, failure or SPACE abort -- moves the span back first. `SA_BUILT` is zeroed at cold start.

## Hardware notes (NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE)

The format is a standard header + data pair at the stock speed; nothing here has been tried on a
real TS2068 and cassette yet -- see `V2_HARDWARE_CHECKLIST.md` (round trip, a long ALL block, a
deliberately damaged tape, the identity-CRC time of ~2.4 s on SAVE, LOAD and VERIFY, and from v2.2 that
block 2 is found after the 4.5 s gap).

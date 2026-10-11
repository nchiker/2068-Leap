# SAVE "name" ALL -- tape format, checks and lifecycle

Status: implemented in the release candidate (`integration/v2-final-rom`, commit `07616e7`).
Code: `rom/v2_saveall.asm` (HOME: layout, CRC, LOAD checks), `rom/v2_saveall_crc.asm` (HOME, in the
old KTAB space), `SA_BUILD` in `rom/exrom_v2_shell.asm` (EXROM). Tests: `tools/v2_saveall_checks.py`
(11 cases, part of `tools/run_v2_prod_tests.sh`).

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

One ordinary TS2068 program block: a 17-byte header (type 0, name, length, the V2 format word in
the autostart field, PROGLEN) and one data block. PROGLEN -- the Spectrum "program part" length --
is the program's own length; a plain `SAVE` has PROGLEN = data length, a `SAVE ... ALL` block is
longer than PROGLEN and the rest is the session:

| Offset in the data | Bytes | Contents |
|---|---|---|
| 0 | PROGLEN | the program text (`PROG_AREA_START .. PROG_END`), exactly as `SAVE` writes it |
| PROGLEN | `ARRAYS_END - PROG_END` | the compile symbol table, the 80-byte session gap and the array arena, at their own addresses |
| ... | W | `VARS_START .. SESS_CODE_END`: the run-time tables, the compile zone and the session's bytecode |
| ... | S | segment 2, `ARR2_BASE .. ARR2_END`: the Array Store and arrays that overflowed into it |
| ... | 49 | the session cells `$B800 .. $B830` (symbol counts, table bases, ends, `SESS_*`, `SA_AE` = ARRAYS_END) |
| ... | 2 | CRC-16 of the ROM pair that wrote it: HOME `$0000-$3FFF` then EXROM `$C000-$DFFF` |
| ... | 2 | CRC-16 of every preceding data byte (program included) |

CRC-16/CCITT-FALSE: polynomial `$1021`, initial value `$FFFF`, MSB first, no final XOR, stored low
byte first. `tools/v2_saveall_checks.py` has a Python reference (`crc16`).

The data is laid out *in place*: for the SAVE the W span is moved down to `ARRAYS_END` (not
copied), segment 2 and the tail are written after it, the block is sent, and the span is moved
back. So SAVE ALL needs no free memory for a copy; its one limit is that the laid-out image must
end at or below `V2_CODE_LIMIT` (`$B400`): roughly, bytecode + segment 2 + 53 bytes must not
exceed the bytecode area (~3.9 KB) plus the free main memory. Otherwise `OUT OF MEMORY` and nothing
is sent (`SAVE "name"` and `SAVE ... ARRAY` remain available).

The tape format word's minor version is 1 from this release (`V2_FORMAT_MINOR`): older V2 ROMs
refuse every tape this ROM writes (instead of loading a session as program text); this ROM loads
minor-0 tapes.

## LOAD: checks before anything is used

LOAD receives the whole block into `PROG_AREA_START ..` (up to `V2_CODE_LIMIT`). A plain block
longer than the main pool is refused (`LOAD FAILED`). For an ALL block (`SA_RESTORE`):

1. the data must be long enough for the 53-byte tail;
2. **block CRC** -- mismatch: `LOAD FAILED`, the program is cleared (as for any corrupt load: the
   old program was already overwritten);
3. **ROM CRC** -- the image is only valid with exactly the ROM that wrote it (bytecode and layout
   depend on it); mismatch: the program is kept, the variables are not loaded (`NO VARIABLES`);
4. the session cells are installed (the Array Store's end is remembered first);
5. **address chain** -- these words must be nondecreasing: `PROG_END`, `SYM_BASE_V`, `PROG_END`,
   `SYM_END_V`, `SESS_ARENA_BASE`, `ARRAYS_END`, the five table bases, `V2_SOURCE_END`,
   `VM_CODE_BASE`, `SESS_CODE_END`, `V2_CODE_LIMIT`, `ARR2_BASE`, `PAS_END`, `ARR2_END`,
   `ARR2_LIMIT` -- every region boundary lies where the layout allows;
6. **partition** -- `ARRAYS_END + W + S + 53` must equal the block's end exactly;
7. **pointers** -- every array pointer in the saved tables (read in the image) must be 0, inside
   the arena or inside segment 2: no pointer from the tape is used unchecked;
8. only then: segment 2 is copied to `$E000`, the W span is moved up into place, `VARS_START` and
   the VM registers are set, and the session is current.

Any failure in steps 4-7 restores the Array Store's end, discards the variables (`NO VARIABLES`)
and keeps the program. An interrupted or truncated tape fails in the transport as before (`LOAD
FAILED` / `ABORTED`, the existing failure classes).

After a successful LOAD, `: PRINT x`, `: GOTO label`, `CLEAR`, `RUN` behave exactly as after the
program had run on this machine (`V2_SESSION_VARIABLES.md`).

## VERIFY

`VERIFY "name"` with a session first lays memory out exactly as `SAVE ... ALL` would (CRCs
included), compares, and moves the span back before its message; a plain tape compares only the
program part (PROGLEN, which equals the data length). If the layout does not fit (the SAVE would
have been `OUT OF MEMORY`), an ALL tape reports `VERIFY FAILED`.

## Restoring the span: SA_BUILT

`SA_BUILD` sets `SA_BUILT`; `V2_SHOW_MESSAGE` -- which every SAVE and VERIFY outcome ends in,
success, failure or SPACE abort -- moves the span back first. `SA_BUILT` is zeroed at cold start.

## Hardware notes (HARDWARE PENDING)

The format is a standard header + data pair at the stock speed; nothing here has been tried on a
real TS2068 and cassette yet -- see `V2_HARDWARE_CHECKLIST.md` (round trip, a long ALL block, a
deliberately damaged tape, the ROM-CRC timing of ~2.4 s on SAVE, LOAD and VERIFY).

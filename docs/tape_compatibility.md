# TS2068 tape compatibility contract

## Scope

SAVE and LOAD use the stock TS2068/Sinclair program-tape framing, while
the data payload remains this ROM's native program representation. This
is transport compatibility, not Sinclair BASIC source compatibility.

## Serialized payload

The data block is the contiguous byte range from `PROG_AREA_START` up to,
but not including, `PROG_END`. Statements are this ROM's length-prefixed
plain-text records. Scalars, arrays, labels, editor state, and display
state are not serialized.

## Tape blocks

Each SAVE writes exactly two blocks:

1. `$00` block flag, 17-byte header payload, XOR checksum.
2. `$FF` block flag, native program payload, XOR checksum.

The 17-byte header payload is:

| Offset | Size | Meaning |
|---:|---:|---|
| 0 | 1 | File type `$00` (BASIC program) |
| 1 | 10 | Filename, space padded |
| 11 | 2 | Payload length, little endian |
| 13 | 2 | `$8000`, no autostart |
| 15 | 2 | Program length, equal to payload length |

Filenames are limited to ten characters. `LOAD ""` accepts the next
BASIC-program header regardless of its filename. Other stock file types
are skipped during header search.

## LOAD state contract

The header length must not exceed `VARS_START - PROG_AREA_START`. On a
successful data-block checksum, LOAD updates `PROG_END`, clears scalar and
array state through the established reset path, resets editor/view/error
state, restores default display state, rebuilds labels, and forces a full
redraw. On failure it does not update `PROG_END` or run the success reset.

The decoder currently receives directly into the program area. Therefore
a data block that fails only at its trailing checksum may have overwritten
bytes below the unchanged `PROG_END`. Eliminating that limitation requires
a full-size staging area or a streaming rollback mechanism and is outside
the framing migration.

## Compatibility limits

A stock TS2068 can recognize the header framing, but it cannot execute the
native payload because this ROM is not Sinclair BASIC. Conversely, this
ROM does not import stock tokenized BASIC. Fuse tape-trap acceleration is
not guaranteed by standard framing alone; trap recognition may also depend
on stock ROM identity or execution addresses. Cycle-level tape operation
remains the correctness baseline.

The receiver retains the stock `$C6` leader and `$CB` data thresholds.
Its `EDGE2` path must measure two consecutive half-pulses by falling
through into `EDGE1` after the first call, exactly as the stock routine
does. Returning after the first edge halves the measurement and can make
an all-zero header appear checksum-valid.

Status-bar progress is deliberately milestone-based because rendering
during a tape block would corrupt SAVE timing or make LOAD miss edges.
The safe updates are 0% at entry, 10% between the header and data blocks,
and 100% after the data block has completed.

## Confirmed result

On 2026-08-26, real Fuse round-trips were confirmed with both `LOAD ""`
and `LOAD "verify"`: the redesigned ROM saved a three-statement program
to a Direct Recording TZX and restored its listing. The receiver required
the stock LD-EDGE-2 fall-through into a second LD-EDGE-1 measurement.
Named loading additionally requires its padded comparison name to remain
outside redraw scratch and its HL pointer to survive the maximum-length
calculation before entering `STORAGE_LOAD`; both invariants are guarded by
`tools/check_storage_contract.py`.

The confirmed Direct Recording TZX is retained as `export/verify`.
`tools/check_tape_fixture.py` deterministically decodes its sample-level
pulses during `make check` and verifies the `verify` header, native
three-statement payload, declared lengths, and both XOR checksums. This is
an artifact/framing regression check; the interactive Fuse round-trip
remains the end-to-end test of the ROM's live pulse receiver.

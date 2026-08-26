# Archived: from-scratch tape SAVE/LOAD protocol

**Archived 2026-08-24.** `storage.asm` here is the full from-scratch tape
block protocol (~1700 lines: `STORAGE_PULSE`/`PILOT_TONE`/`SYNC`/
`SEND_BYTE`/`SEND_BLOCK`/`WAIT_EDGE`/`RECEIVE_INIT`/`RECEIVE_BYTE`/
`RECEIVE_BLOCK`/`WAIT_PILOT`/`REPORT_PROGRESS`/`BUILD_HEADER`/`SAVE`/
`LOAD`) that used to live at `kernel/storage/storage.asm` and was
`INCLUDE`d into `rom/exrom_storage.asm`.

**Why archived, not deleted:** it was never a reproduction of the real
Sinclair tape format (see the file's own original header) — many small
128-byte blocks, two full redundant passes, individually checksummed,
tracked via a bitmap. Real-hardware/real-Fuse testing across this whole
session kept surfacing genuine, real bugs one layer deeper than the
last fix: an unbounded outer retry loop (fixed), an inner pilot-search
budget so large a single failed attempt looked like a hang (fixed), the
header-search path's own separate retry logic breaking when that budget
was tightened (fixed), and finally an entirely unbounded loop inside
`STORAGE_WAIT_PILOT`'s own sync-detection (`.wait_end`) with no cap at
all (fixed, but by that point EXROM had zero bytes of margin left and
every fix was costing budget faster than sweeps could recover it). The
user's call: stop patching a from-scratch design pattern-matched
against real signal timing we don't have ground truth for, and instead
adapt the **real** TS2068 ROM's own tape routines (`LD-BYTES`/
`SA-BYTES` equivalents) — proven-correct, real T-state timing, no
guessed thresholds — as the new basis. See `Resource Docs/Timex
Sinclair 2068 ROM Disassembly.pdf` (repo root) and the real stock ROM
binaries at `~/fuse-build/roms/tc2068-0.rom`/`tc2068-1.rom` for that
work.

**What's still probably worth reusing from this file:** `STORAGE_
PULSE`/`STORAGE_WAIT_EDGE`/`STORAGE_PILOT_TONE`/`STORAGE_SYNC` are each
marked in their own headers as "UNCHANGED, proven, real-signal-tested"
— these are the low-level pulse-timing primitives, not the from-scratch
block-framing design that's actually being replaced. The block-level
design above them (128-byte blocks, two non-interleaved redundant
passes, `STORAGE_BLOCK_BITMAP`) and the tuned-by-guesswork constants
(`STORAGE_BIT_THRESHOLD`, `STORAGE_PILOT_THRESHOLD`, and every retry/
attempt cap added chasing this session's bugs) are what should NOT
carry forward as-is into a real-ROM-based design.

**Do not `INCLUDE` this file from an active build** — `rom/
exrom_storage.asm` no longer references it; `STORAGE_SAVE`/`STORAGE_
LOAD` there are now placeholder stubs (`STORAGE_OP_STATE` 8, "SAVE/LOAD
NOT AVAILABLE") until the real-ROM-based replacement lands.

Related archived test/tooling (same reason, same date):
`rom/archive/test_storage.asm`, `rom/archive/test_storage_save_
toolarge.asm`, `tools/archive/fuse_load_inject.py`, `tools/archive/
run_storage_roundtrip_test.sh`, `tests/archive/storage_roundtrip1.txt`.

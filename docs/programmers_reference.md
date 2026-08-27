# 2068 Leap Programmer's Reference

Status: DRAFT — grows one module at a time, alongside the code. Each section
below corresponds to a kernel module; only `kernel/editor` exists so far.

## Static checks

`tools/check_asm.py` runs three checks against any `.asm` file, purely
from reading the source — no assembler needed: duplicate global
labels, local-label scope errors (see the "IF WITHOUT END IF" story's
own header comment in `basic/basic.asm` and the "Recurring bug
patterns" note this project has tracked across sessions for why this
matters), and a stack-ordering fingerprint (a routine popping
something before pushing anything of its own — the exact shape of a
real, hard-to-find bug documented in this file's "IF/ELSEIF/ELSE/
END IF" section below). Run it after any non-trivial edit to a large
`.asm` file:
```
python3 tools/check_asm.py basic/basic.asm
```
This doesn't replace actually assembling and testing — it's a cheap,
fast first pass that catches classes of bug this project has
genuinely shipped before, not a substitute for real verification.

`tools/check_docs.py` runs a smaller, different check: it cross-checks
specific numbers/names quoted in the docs against the source tables
they're quoting (font glyph count, punctuation character count, HELP
topic coverage), not the code's correctness. This project has shipped
doc staleness twice (a glyph/punctuation count going stale after a
later addition) — this catches that class mechanically instead of
relying on remembering to grep for every mention by hand. Run it
after any change that adds a font glyph, a punctuation mapping, or a
HELP topic:
```
python3 tools/check_docs.py
```

`tools/z80sim/` is a source-level Z80 interpreter — parses this
project's own `.asm` files directly and executes instruction-by-
instruction against seeded real state, respecting local-label scoping.
Built to settle a real bug empirically after repeated hand-tracing and
"reasoned" Python translations of the same routines kept saying code
was correct when it genuinely wasn't (see `tools/z80sim/README.md`'s
own header for that story). Best used once static analysis and hand-
tracing are exhausted on a specific, narrowed-down routine — not a
general-purpose emulator, no port I/O, no interrupts/timing. See that
README for the full usage pattern (`extract_routine.py` + a small
driver script) and its documented limitations, including `(IX+d)`/
`(IY+d)` indexed-addressing support (added when a table-walking
routine first needed it — requires seeding the index register with a
real numeric address, not a label, since this tool has no memory image
for arbitrary `DB`/`DW` data).

`tools/preload_gen.py` encodes a plain-text BASIC program listing
(one statement per line) into this ROM's exact program-storage byte
format (`kernel/memory.asm`'s own documented `[length:2][content]
[$0D]` layout) and generates a standalone `rom/test_preload_*.asm`
harness that copies those bytes straight into RAM at boot and hands
off to the normal `BASIC_COMMAND_LOOP` — the program is already
sitting in the editor, ready to `LIST`/`RUN`/edit, with no typing and
no `SAVE`/`LOAD` tape round-trip needed (that mechanism only reads a
tape `SAVE` itself produced; it can't import external text). Verified
against the real `MEM_LINE_FIRST`/`MEM_LINE_NEXT` instructions via
`tools/z80sim` before being trusted. Usage:
```
python3 tools/preload_gen.py <program.txt> rom/test_preload_NAME.asm NAME
sjasmplus rom/test_preload_NAME.asm
fuse --machine ts2068 --rom-ts2068-0 test_preload_NAME.bin --rom-ts2068-1 rom1.bin
```

## kernel/editor — full-screen program editor

Replaces the original ROM's line editor, which could only edit the single
line currently being typed. This editor treats the whole program listing as
a scrollable, cursor-addressable view.

**Moved to EXROM (2026-08-22)**: the production ROM no longer builds this
module Home-resident — see the dedicated "`kernel/editor` moved to EXROM"
section under `basic/` below for the full migration writeup (why, the
paging design, and live interactive verification). `kernel/editor/
editor.asm` itself is unchanged and still builds/runs standalone (`rom/
test_editor.asm`); it's no longer part of `include/kernel_api.inc`'s
contract, since `basic/` now reaches it through its own `BASIC_EDITOR_*_
EXROM` wrappers instead of calling these labels directly. The rest of this
section (behavioural design, routine list) still describes the module's
actual logic correctly — just read "the real routine, wherever it's
compiled" for every routine name below.

### Public routines (was `include/kernel_api.inc` — see the move note above)

| Routine              | Purpose                                              |
|-----------------------|-------------------------------------------------------|
| `EDITOR_INIT`          | Reset editor state. Call at cold start and on `NEW`. |
| `EDITOR_ENTER`         | Take over screen/keyboard, run the edit loop.        |
| `EDITOR_EXIT`          | Commit the current line, return to BASIC.            |
| `EDITOR_INSERT_CHAR`   | Insert one char at the cursor.                       |
| `EDITOR_DELETE_CHAR`   | Delete the char at the cursor.                       |
| `EDITOR_MOVE_CURSOR`   | Move cursor one step, or jump (home/end/top/bottom). |
| `EDITOR_BLOCK_DELETE`  | Delete a contiguous range of program lines, by editor position. |

### No line numbers

Following QL SuperBASIC rather than classic Sinclair BASIC, this ROM's
BASIC has **no line numbers**. `GOTO`/`GOSUB` targets are labels, and
structured control flow (procedures, `REPeat`/`END REPeat`, etc. — design
TBD in `basic/`) covers most of what line numbers used to be needed for.

This removes `EDITOR_RENUMBER` entirely rather than replacing it: renumbering
only ever existed to keep line numbers and their GOTO references in sync
after edits, so with no line numbers there's nothing left for it to do.
`EDITOR_BLOCK_DELETE` addresses a range by editor line *position* (0-based,
set by a mark-start/mark-end selection) instead of by line number.

Open question this pushes into `basic/`: block-deleting a range that
contains a label still needs a story — either warn if anything outside the
range references a label being deleted, or let it surface as an ordinary
"undefined label" run-time error. **Partially resolved**: see
`docs/basic_language_reference.md`'s "Label table" section for the design
— block delete should abort non-destructively on a dangling reference,
mirroring the guarantee originally scoped for `EDITOR_RENUMBER`. What
`kernel/memory` actually provides so far is only half of this:
`MEM_LABEL_LOOKUP` against the label *definition* table. The other half —
scanning program text for `GOTO`/`GOSUB`/`RESTORE` references to a label
— needs a BASIC-syntax parser and is explicitly `basic/`'s job, not
`kernel/memory`'s (see that module's header comment). Still open until
`basic/` exists.

### Behavioural guarantees

- **Bounded insert**: `EDITOR_INSERT_CHAR` refuses to grow a line past
  `EDIT_LINE_BUF_LEN` (128 chars) and signals via carry rather than
  corrupting adjacent memory.
- **Redraw discipline**: the editor never pokes the screen bitmap directly
  from an edit routine. All screen changes route through
  `EDITOR_REDRAW_SCREEN` (or, once written, a lighter per-line redraw), so
  there's exactly one place that knows how to paint the program view.

### Status

**Single-line editing is genuinely working now**: `EDITOR_INSERT_CHAR`,
`EDITOR_DELETE_CHAR`, `EDITOR_BACKSPACE`, `EDITOR_MOVE_CURSOR`
(LEFT/RIGHT/HOME/END), and `EDITOR_REDRAW_SCREEN` are all implemented
and hand-traced, wired together through the real `EDITOR_ENTER`/
`EDITOR_LOOP`. A shared internal `EDITOR_SCAN_LEN` helper (not in
`kernel_api.inc`) replaced what would otherwise have been four separate
copies of "scan the buffer for its null terminator."

**Fixed a real usability bug caught in testing**: the editor's DELETE
key (CAPS SHIFT+0 / Fuse's mapped Backspace) was originally wired
straight to `EDITOR_DELETE_CHAR`'s forward-delete, so it deleted the
character *in front of* the cursor rather than *before* it — wrong for
a key that's physically a backspace key. `EDITOR_BACKSPACE` composes
the already-tested `EDITOR_MOVE_CURSOR`(LEFT) and `EDITOR_DELETE_CHAR`
rather than duplicating the shift logic, and `EDITOR_LOOP` now calls it
instead. `EDITOR_DELETE_CHAR` itself is unchanged and still available
as a forward-delete primitive for whenever that's needed separately.

`EDIT_PROGRAM_POS` (new scratch var) is now tracked by `EDITOR_ENTER`
and available to `EDITOR_EXIT` — but **`EDITOR_EXIT` deliberately does
NOT call `MEM_LINE_STORE` yet**. Checking the two format contracts
against each other surfaced a real bug before it shipped:
`EDIT_LINE_BUF` holds raw null-terminated ASCII, while `MEM_LINE_STORE`
expects the length-prefixed, tokenized statement format. Calling it as
originally stubbed would have misread the first two typed characters as
a length field and corrupted the program area. That conversion (raw
text -> tokenized statement) is a `basic/` tokenizer concern, not
`kernel/editor`'s — deferred until `basic/` exists, with the position
already tracked and ready for when it does.

**Now has a blinking cursor indicator**: `EDITOR_REDRAW_SCREEN` shows
the cursor as an inverse-video block at `EDIT_BUF_OFFSET`'s column, via
`kernel/graphics`'s `GFX_INVERT_ATTR`, which sets the ULA's hardware
FLASH bit — the blink itself is done by the hardware, no interrupt or
timer code needed on our end. Inherits `GFX_PRINT_STRING`'s existing
no-line-wrap limitation: if the line buffer grows past 32 characters
(the buffer allows up to 126), the cursor indicator's column math isn't
clamped either, and would land in the wrong place — a known, shared
gap, not something new to this feature specifically.

**New: `EDITOR_REDRAW_HOOK`** — an optional custom-rendering callback.
`EDITOR_REDRAW_SCREEN` checks it first (a sysvar, 0 by default, zeroed
by `EDITOR_INIT`); if set, control passes there instead of the built-in
rendering, via a plain `JP` so the hook's own `RET` correctly returns to
whatever called `EDITOR_REDRAW_SCREEN` in the first place. This exists
so `basic/` can own keyword auto-uppercase + bold highlighting (see
that module's docs) without `kernel/editor` needing to hardcode BASIC
keywords — keeps this module generic and reusable by other future
software, matching the stated design goal for `kernel/*` modules.

**Fixed a latent gap while touching `EDITOR_INIT` for the hook
addition**: it only zeroed `EDIT_BUF_OFFSET`'s low byte (an 8-bit store
on a 2-byte sysvar), leaving the high byte as whatever was in RAM at
cold start. Never caused a visible bug — the offset never exceeds 126
in practice — but a real correctness gap, fixed to a proper 16-bit
store while already in this routine for an unrelated reason.

**New: `EDITOR_NAV_HOOK`** — same pattern as `EDITOR_REDRAW_HOOK`, for
`UP`/`DOWN`. Zeroed by `EDITOR_INIT`; if set, `EDITOR_LOOP` calls it
(with `A` = `EDIR_UP` or `EDIR_DOWN`) instead of the built-in (still
no-op) `MOVE_CURSOR` `UP`/`DOWN` handling. Z80 has no indirect `CALL`
instruction, only indirect `JP` — the standard idiom is used: push the
address execution should return to, then `JP (HL)`, so the hook's own
`RET` lands back there, same effect a `CALL (HL)` would have if it
existed. This is what lets `basic/` implement real navigation between
existing program lines (`BASIC_HANDLE_NAV`, see that module's docs)
without `kernel/editor` needing to know statements or BASIC exist at
all — the hook just says "the user wants to move; you decide what that
means for whatever's in `EDIT_LINE_BUF`."

**Deliberately omitted**: FIND/search. The never-wired `EDITOR_SEARCH`
stub was removed on 2026-08-27; editor ROM and interaction budget is being
spent on language and showcase features instead. Lines longer than
32 characters now use the production EXROM editor's word-wrap table,
including correct cursor mapping across physical rows. `kernel/editor`'s OWN built-in
`MOVE_CURSOR` `UP`/`DOWN` remain no-ops by design, not an oversight —
real vertical navigation now exists, but it lives in `basic/` via the
nav hook rather than here, since "moving to a different line" requires
knowing what a program statement is, which this module deliberately
doesn't. `EDITOR_BLOCK_DELETE` calls a real `kernel/memory` routine now
but its own mark-selection input mechanism and the dangling-label-
reference check are both still open (see that routine's own comments).

See "Testing kernel/editor" in the README, and inline comments in
`kernel/editor/editor.asm` for the hand-traces behind INSERT_CHAR and
DELETE_CHAR specifically.

## kernel/memory — line storage, program iterator, label table

Owns the BASIC program area's storage format, the routines that walk it,
and the per-scope label table that replaced `EDITOR_RENUMBER` (see
`docs/basic_language_reference.md`, "Label table"). Also owns
`include/sysvars.inc` — every fixed RAM address shared by more than one
module lives there now, not scattered across whichever module needed it
first (this replaced placeholder addresses `kernel/editor` had defined
for itself before this module existed).

### Public routines (`include/kernel_api.inc`)

| Routine | Purpose | Status |
|---|---|---|
| `MEM_INIT` | Set program area + label table to empty | Working |
| `MEM_FILL_ZERO` / `MEM_FILL` | Zero-fill or fill-with-byte a range | Working |
| `MEM_SHIFT_UP` / `MEM_SHIFT_DOWN` | Generic overlap-safe block move | Implemented, hand-traced against concrete addresses |
| `MEM_LINE_FIRST` / `MEM_LINE_NEXT` | Program iterator | Working — `MEM_LINE_NEXT` now detects end-of-program via `PROG_END` |
| `MEM_LABEL_LOOKUP` | Name -> program position | Implemented via internal `MEM_LABEL_FIND` scan helper (not in `kernel_api.inc` — shared by LOOKUP and REMOVE) |
| `MEM_LABEL_ADD` / `MEM_LABEL_REMOVE` | Add/remove a label table entry | Implemented, hand-traced through a two-entry scenario exercising REMOVE's shift-close-the-gap logic |
| `MEM_LINE_STORE` | Replace the statement at a position, or append if none exists yet | Fixed a real bug (see below) — now hand-traced through both cases |
| `MEM_LINE_DELETE_RANGE` | Delete statements in a position range | Implemented, hand-traced; does NOT include the dangling-label-reference check (that's `basic/`'s job — see below) |
| `MEM_FREE_BYTES` | `PROG_AREA_MAX - PROG_END` — bytes still free in the program area | Working, confirmed on real Fuse/TS2068 emulation — backs `basic/`'s `FREE()` (2026-08-22) |

All of the above are hand-traced against concrete addresses (each routine's own comments show the trace). `MEM_INIT`, `MEM_FILL_ZERO`/`MEM_FILL`, `MEM_LINE_FIRST`, `MEM_SHIFT_UP`/`MEM_SHIFT_DOWN`, `MEM_LABEL_LOOKUP`/`ADD`/`REMOVE`, and now `MEM_LINE_STORE`/`MEM_LINE_DELETE_RANGE` are all confirmed on real Fuse/TS2068 emulation via `rom/test_memory.asm`.

### The most significant bug caught in this project so far

`MEM_LINE_STORE` always assumed a statement already existed at the
given position, unconditionally reading 2 bytes there as "the old
statement's length" before doing anything else. That's correct when
*replacing* an existing statement — which is all `rom/test_memory.asm`'s
own `TEST_MEM_LINE_STORE` ever exercised — but the very first time this
routine was used for real, by `basic/`'s new `BASIC_COMMAND_LOOP`
storing the first statement ever typed, the position given was
`PROG_AREA_START`, which had never been written to. Those 2 bytes were
uninitialized RAM, and every downstream shift/copy computed from that
garbage corrupted memory in ways that surfaced as **misplaced text and
corrupted screen attributes several rows away from where anything
should have been** — a real, reproducible integration bug, caught only
because `basic/` finally exercised the "store into an empty program"
path that no unit test had ever covered.

Fixed by checking `position == PROG_END` (or `>`, defensively) before
touching anything, and skipping the old-statement read entirely when
there's genuinely nothing there — `old_total` becomes `0` directly
rather than `old_len + 2` computed from a zeroed `old_len`, which would
have wrongly implied a 2-byte header existed to remove. A dedicated
regression test, `TEST_MEM_LINE_STORE_EMPTY`, now exercises exactly this
path (`MEM_INIT` then store immediately) so this class of bug can't
silently return. **The lesson**: a module's own unit tests proving every
individual routine works doesn't guarantee the *first real use* of that
routine, in combination with everything else, will go through a
genuinely tested code path — this is exactly what integration testing
is for, and exactly why `rom/test_basic.asm` (testing the whole
pipeline together) was worth building even with `kernel/memory` already
fully "tested."

### Line storage format

No line numbers (see `docs/basic_language_reference.md`). Each statement:
`[length: 2 bytes][tokenised text][terminator: $0D]` — the classic
Sinclair BASIC format's 2-byte line-number field is simply absent; the
length-prefix mechanism that lets the iterator skip a whole statement
without scanning it byte-by-byte is otherwise unchanged from that
lineage.

### Label table format

Per scope (top-level program body, or a `DEFine PROCedure`/`DEFine
FuNction` — only the top-level table exists so far, since procedure
storage isn't designed yet): a 2-byte count, followed by that many
entries of `[name_len: 1 byte][name: name_len bytes][position: 2 bytes]`,
unsorted, linear-scanned (tables are expected to be small — see
`docs/basic_language_reference.md`'s open question on the size budget).

### What kernel/memory deliberately does NOT do

Scan program text for `GOTO`/`GOSUB`/`RESTORE` references to a label.
That requires understanding BASIC statement syntax, which belongs to
`basic/` once it exists. `kernel/memory` only maintains the label
*definition* table (`MEM_LABEL_LOOKUP` et al.) — the non-destructive
block-delete guarantee described in `docs/basic_language_reference.md`
needs both halves, and only one is implemented here.

### Testing gotcha (hit twice — worth remembering)

Any test harness's *mutable* scratch data must be a RAM address (an
`EQU`), never `DS`-reserved space inside the test file's own assembled
code — `DS` space lives inside the ROM image, and writes to ROM silently
fail on real hardware and accurate emulators. This bit Milestone 0's
border-cycle counter first, and `rom/test_memory.asm`'s own
`MEM_FILL_ZERO` test a second time — the test's buffer was pre-zeroed by
`sjasmplus`'s `DS` default, so a completely broken (never-actually-fills)
`MEM_FILL_ZERO` would have passed the test just as easily as a working
one did. Fixed by moving all mutable test buffers to RAM `EQU`
addresses. Read-only *expected* comparison data is fine as ROM — only
data the test *writes to* at runtime needs to be RAM.

### Status

**All public routines implemented, and all now have test coverage** in
`rom/test_memory.asm` — the gap flagged last (`MEM_LINE_STORE`/
`MEM_LINE_DELETE_RANGE` had no test at all) is closed, using multi-
statement fixtures specifically so the shift math gets exercised rather
than degenerating to the `BC=0` no-op path a single-statement case would
hit. Not yet run through the real assembler for these two additions —
see "Testing kernel/memory" in the README for exactly what's confirmed
on real hardware vs. hand-traced-only.

This module's known remaining gap isn't a missing routine or missing
test, it's the one described above under "What kernel/memory
deliberately does NOT do" — the dangling-label-reference check needs
`basic/`'s parser, which doesn't exist yet.

## kernel/io — keyboard scanning

Owns raw keyboard matrix scanning, a key-to-ASCII table for unshifted
letters/digits/space/enter, CAPS SHIFT+digit cursor/delete combo
detection, and CAPS SHIFT+letter for uppercase. The scanning mechanism
(8x5 matrix read through port `$FE`, row selected by the value in `A`
at the time of the `IN` instruction) is standard across the whole
Spectrum/Timex family and confirmed by design — it's the same mechanism
Fuse itself uses to emulate TS2068 keyboard input.

**Corrected**: an earlier draft of this section claimed the TS2068 has
dedicated cursor keys. It doesn't — the TS2068 keyboard is laid out the
same as the original Spectrum (CAPS SHIFT duplicated on both sides,
plus an added BREAK key, otherwise identical — see
`docs/hardware_notes.md`). This means the standard CAPS
SHIFT+5/6/7/8/0 cursor/delete combo scheme applies directly and is now
implemented, not blocked. What's still genuinely unconfirmed is only the
BREAK key's exact matrix position — see `docs/hardware_notes.md`'s
"Still open" list. `kernel/io` does not implement BREAK detection.

**Case is a design choice, not a hardware fact**: a real Sinclair-family
keyboard has no separate upper/lowercase keys at all, so some scheme had
to be chosen for this ROM. Unshifted letters are lowercase; CAPS
SHIFT+letter gives uppercase (`KEY_ASCII_TABLE_UPPER`) — the typewriter/
modern-keyboard convention, not the machine's own historical BASIC-
editor default (uppercase-first, with mode-switching for lowercase).
This changed existing behaviour: unshifted letters used to be uppercase.

**Real bug found and fixed during testing**: `IO_READ_KEY` originally
decided what key was pressed off a single instantaneous scan, taken the
moment it first detected *anything* down. Fixed with a settle delay +
re-scan, then — after diagnostic testing (`rom/test_keycode.asm`, shows
`IO_READ_KEY`'s raw return value in hex live on screen) — found that
even a small fixed retry budget (5 attempts, ~76ms by rough cycle-count
estimate) still wasn't enough for real human timing. Backspace (Fuse's
CAPS SHIFT+0 mapping) worked with just 5 retries, since Fuse appears to
assert both matrix bits as one atomic simulated action, but CAPS
SHIFT+letter (typed by a real person actually holding Shift and then
reaching for a separate key) still failed even then — actual finger-
movement timing between the two keys can run into hundreds of
milliseconds, far more than a single simulated combo needs. Widened the
retry budget to roughly 1 second (~65 attempts) and changed the exit
condition to "CAPS SHIFT released" rather than "attempts exhausted" as
the primary case, so it naturally waits exactly as long as the person
keeps holding shift rather than an arbitrary short window. The exact
timing was calculated from instruction cycle counts, not measured on
real hardware — a reasonable starting point, not a finely tuned value.

**Also observed via the diagnostic tool, not a bug**: toggling Caps
Lock (as opposed to holding Shift) and then pressing a letter produces
the same result as no shift at all. This appears to be because Fuse's
Caps Lock doesn't actually assert the emulated CAPS SHIFT key in the
matrix — it's a host/Fuse-side convenience toggle, not a held keypress
in the sense `IO_READ_KEY` scans for. Holding the mapped Shift key (not
Caps Lock) is what actually asserts CAPS SHIFT for testing purposes.

### Public routines (`include/kernel_api.inc`)

| Routine | Purpose | Status |
|---|---|---|
| `IO_KEY_SCAN_ROW` | Scan one keyboard row | Implemented |
| `IO_KEY_SCAN_ALL` | Scan all 8 rows into `IO_SCAN_TABLE` | Implemented, hand-traced |
| `IO_ANY_KEY_DOWN` | Is anything pressed right now | Implemented |
| `IO_READ_KEY` | Blocking single-key read: cursor/delete combos, then CAPS SHIFT+letter, then lowercase ASCII | Implemented and confirmed working on real hardware, including the settle-delay fix |

### What's implemented, and what's deliberately not

**SYMBOL SHIFT** now covers the confirmed-confidence subset of the real
punctuation table: the full digit row (`!@#$%&'()_`) plus `Z`=`:`,
`M`=`.`, `N`=`,`, `L`=`=`, `K`=`+`, `J`=`-`, `O`=`;`, `V`=`/`, `B`=`*`,
`R`=`<`, `T`=`>`, `C`=`?` — 23 characters total, each with a font glyph now too
(`kernel/graphics`'s `FONT_TABLE` grew to 86 glyphs). `V` and `B` were
added once `basic/`'s expression evaluator actually needed `/` and `*`
for division and multiplication; `R` and `T` were added once `basic/`'s
new IF/ELSEIF relational operators needed `<` and `>` — all four
verified via the same source (a Spectrum keyboard layout chart,
cross-checked against every letter-row mapping already independently
confirmed in this table, which matched exactly) as the rest of this
table, not guessed. Adding a punctuation mapping without also adding
its font glyph would repeat this project's earliest character-
rendering bug (the quote character typed correctly but rendered as
nothing, since no glyph existed for it yet) — both are always added
together now. Verified via web search before implementing, not
guessed — this project already got the *PC-key* side of `SYMBOL SHIFT`
wrong once (assumed Ctrl before the user's own testing against a stock
Spectrum ROM confirmed it), so the *combo table* itself got the same
scrutiny rather than trusting memory.

**Deliberately NOT implemented, rather than guessed**: the real
`SYMBOL SHIFT` table is more complex than a flat symbol lookup. Row 1
(`A`-`G`) gives BASIC keyword tokens on real hardware (`STOP`, `NOT`,
`STEP`, `TO`, `THEN`) — not simple characters, so it isn't
representable this way at all, independent of our own BASIC not using
that keyword-entry-mode system anyway. `Q`, `W`, `E` (the rest of row
2) give compound TWO-CHARACTER tokens on real hardware (`<=`, `<>`,
`>=` respectively) that this project's flat one-key-to-one-character
table has no way to represent — `basic/`'s own parser reads those as
two typed characters in sequence anyway (`<` then `=`, etc.), so
nothing is lost by leaving these three unmapped rather than building
multi-character key output just for them. A handful of individual
keys (`X`, `I`, `U`, `Y`, `H`) have no confirmed mapping either
way and report unmapped (`0`).

- **CAPS SHIFT+non-cursor-digit** (2,3,4,9) — real Spectrum-family
  machines gave these special meanings (CAPS LOCK, TRUE VIDEO, etc.),
  none of which are implemented here; they currently just report
  unmapped (`0`). **CAPS SHIFT+1** is the one exception: real hardware
  gives it EDIT, not implemented here either, but this project
  repurposes the combo as `KEY_DELETE_LINE` (see `include/keys.inc`)
  — a project-specific one-keystroke "delete whole line" command, the
  same way `CAPS SHIFT+ENTER` and `SYMBOL SHIFT+A`/`S` are repurposed
  elsewhere rather than left unmapped.
- **Physical BREAK keycap** — its separate matrix position remains
  unconfirmed, but the standard CAPS SHIFT+SPACE BREAK combination is
  implemented and polled during program execution.
- **Keyboard sampling is interrupt-driven**: `KBD_ISR_TICK` performs the
  scan/debounce continuously and `IO_READ_KEY` consumes the latched event,
  allowing ordinary two-key rollover while editor redraw work is active.

### Testing

`rom/test_io.asm` is **interactive**, unlike `kernel/memory`'s tests —
keyboard input can't be synthesized from a script the way test data
could be. Run it in Fuse and press real keys; the border reacts live
(green while held, black when released). This only confirms
`IO_ANY_KEY_DOWN`/the scan primitives, not `IO_READ_KEY`'s ASCII table —
testing *which* key was detected needs a way to display it, which needs
`kernel/graphics` (not written yet).

## kernel/graphics — text-mode character output

Owns the screen bitmap/attribute addressing and character output
(`GFX_CLS`, `GFX_PUTCHAR`, `GFX_PUTCHAR_BOLD`, `GFX_PRINT_STRING`,
`GFX_INVERT_ATTR`). Covers space, 0-9, A-Z, a-z, and 23 punctuation
characters (86 glyphs total) — see `docs/hardware_notes.md`'s SYMBOL
SHIFT table for exactly which punctuation and why that specific subset.
`?` (glyph index 85) is the newest addition, alongside `kernel/io`'s
new `SYMBOL SHIFT+C` mapping — a hook shape reusing `2`'s top curve,
tapering to a point then a gap-and-dot close matching `!`'s existing
style, staying within the same column range (`$80`-`$08`) every other
letter/digit glyph already uses. `<` and `>` (glyph indices 83/84,
`SYMBOL SHIFT+R`/`+T`) were the addition before that — simple mirrored
single-pixel-diagonal chevrons.

**Two different confidence levels in this module, worth keeping
separate**:
- **Screen addressing** (`ROW_BASE_TABLE`, the scanline/column math in
  `GFX_PUTCHAR`, and the row×32+col attribute math in `GFX_INVERT_ATTR`)
  was verified *numerically* — Python scripts checked the standard
  Spectrum-family screen layout formula against 576 spot-check (row,
  column, scanline) combinations, and separately checked the ink/paper
  bit-swap instruction sequence against all 256 possible attribute byte
  values, before either was trusted. High confidence.
- **Font glyph shapes** (`FONT_TABLE`) have no equivalent check — there's
  no formula to verify pixel art against, only human judgement. Each
  glyph was designed deliberately as ASCII art and visually rendered for
  self-review, rather than recalled from memory of a specific ROM's font
  (to avoid transcription errors), but this still needs **your** visual
  confirmation once actually on screen — see "Testing" below.

### Public routines (`include/kernel_api.inc`)

| Routine | Purpose | Status |
|---|---|---|
| `GFX_CLS` | Clear bitmap + attributes | Implemented |
| `GFX_CHAR_TO_FONT_OFFSET` | ASCII -> absolute glyph pointer (ROM `FONT_TABLE`, RAM `UDG_TABLE`, or a freshly-generated block-graphics byte pair) | Implemented (internal, not in `kernel_api.inc`) |
| `GFX_CHAR_SETUP` | Shared address computation for `GFX_PUTCHAR`/`GFX_PUTCHAR_BOLD` | Implemented (internal, not in `kernel_api.inc`) |
| `GFX_PUTCHAR` | Plot one character at (row, col) | Implemented, address math verified numerically |
| `GFX_PUTCHAR_BOLD` | Plot one character, synthesized bold (widened strokes) | Implemented, bold technique verified numerically against representative font bytes |
| `GFX_PRINT_STRING` | Print a null-terminated string | Implemented as clipped low-level output for editor/help layouts; `GFX_PRINT_STRING_ATTR`, used by BASIC `PRINT`, wraps and scrolls all 24 output rows |
| `GFX_PRINT_STRING_ATTR` | Print a null-terminated string, also setting the attribute cell under each character to a given byte | Implemented; built for `basic/`'s `INK`/`PAPER`/`FLASH`/`INVERSE` support — kept as a separate routine from `GFX_PRINT_STRING` rather than adding a parameter to it, so HELP screens/error messages/the editor (which must stay at the plain default attribute) don't need to change |
| `GFX_INVERT_ATTR` | Swap ink/paper + set hardware FLASH at one cell (blinking cursor indicator) | Implemented, bit-swap verified numerically against all 256 attribute values |
| `GFX_INVERT_ATTR_STATIC` | Swap ink/paper at one cell, no FLASH (static highlight, e.g. a status bar) | Implemented, shares `GFX_ATTR_SWAP` with `GFX_INVERT_ATTR` |
| `GFX_SET_BORDER` | Set the screen border colour via the ULA port ($FE) | Implemented — masks to the low 3 bits before `OUT`, so it can't disturb the EAR/MIC bits sharing that port; built for `basic/`'s new `BORDER <n>` statement |
| `GFX_PIXEL_ADDR_SETUP` | Shared address computation for `GFX_WRITE_PIXEL`/`GFX_READ_PIXEL` | Implemented (internal, not in `kernel_api.inc`) — same "one shared computation, not duplicated in every caller" pattern as `GFX_CHAR_SETUP`/`GFX_ATTR_SWAP` above |
| `GFX_WRITE_PIXEL` | Set/XOR-toggle one pixel, colour its covering attribute cell | Implemented — PLOT's mechanism; address math verified numerically two independent ways (see below) |
| `GFX_READ_PIXEL` | Test whether a pixel is set | Implemented — POINT's mechanism |
| `GFX_LINE` | Draw a line between two absolute points (Bresenham) | Implemented — LINE's mechanism; algorithm verified via Python simulation against a reference implementation before any Z80 was written (see below) |
| `GFX_PLOT_CLIPPED` | Bounds-checked wrapper around `GFX_WRITE_PIXEL` | Implemented (internal) — CIRCLE's off-screen points get silently skipped here rather than wrapped onto the wrong edge |
| `GFX_BLOCK` | Fill a rectangle | Implemented — BLOCK's mechanism, one pixel at a time via `GFX_WRITE_PIXEL` |
| `GFX_CIRCLE` | Draw a circle outline (midpoint circle algorithm) | Implemented — CIRCLE's mechanism; verified via Python simulation, including the x=0/x==y point-deduplication and a real 16-bit-width requirement the verification surfaced (see below) |
| `GFX_CPLOT` | Coarse 2x2-per-cell block-graphics plot | Implemented — CPLOT's mechanism; a byte-level OR/XOR shortcut, verified in Python to exactly match plotting all 16 individual pixels in the quadrant before any Z80 was written (see below) |
| `GFX_SET_ATTR_EXT` | High Resolution Graphics mode's attribute setter | Implemented — same row*32+col formula as `GFX_SET_ATTR`, different base address and row semantics (see below) |
| `GFX_SET_MODE` | Switch video mode (real port `$FF` write) | Implemented — MODE's mechanism; done via a read-modify-write shadow, same established pattern as `GFX_SET_BORDER` (see below) |

### Block graphics (128-143) + UDGs (144-164) (2026-08-22)

Real TS2068/Spectrum-family hardware treats these two 16/21-code ranges
completely differently from the ordinary printable-character font, and
this implementation follows suit rather than adding static glyph data
for either:

- **Block graphics (128-143)** are never stored as bitmap data on real
  hardware at all — the ROM disassembly's `PO-GR-1` (`MKBLKGR`)
  generates the 8-byte pattern from the character code's low nibble
  every time one is printed, via a compact `SBC A,A`+mask trick (each
  of the 4 bits picks whether one quadrant of a 2x2 grid is a solid
  4x4 block or blank — confirmed bit mapping: bit0=top-right,
  bit1=top-left, bit2=bottom-right, bit3=bottom-left). `GFX_CHAR_TO_
  FONT_OFFSET`'s `.is_block_graphics` branch reproduces this exact
  algorithm, generating into a small RAM scratch buffer
  (`BLOCK_GFX_SCRATCH`, `include/sysvars.inc`) rather than a ROM
  table — costs ~50 bytes of ROM code and 8 bytes of RAM, versus a
  128-byte static table.
  **Provenance caveat**: the top-half generation (rows 0-3, bits 0-1)
  is read directly from the disassembly. The *bottom* half (rows 4-7,
  bits 2-3) is reconstructed, not directly read — the source PDF's
  text extraction cuts out at exactly the point where `PO-GR-1`'s body
  would call the same inner routine a second time (a page-break
  artifact, not a genuine 4-line routine — the alternative would leave
  every block-graphic character's bottom half permanently undefined,
  which no shipped ROM would do). The reconstruction is the
  well-documented standard Spectrum-family technique (identical
  `PO-GR-1` shape in the original 48K ROM), not a guess from first
  principles, but it's still one derived step removed from "read
  straight off the page," unlike the block-graphics/UDG facts recorded
  earlier in `/home/charlie.day/.claude/plans/noble-painting-owl.md`.
- **UDGs (144-164, 21 slots)** are plain RAM, POKE-defined, on real
  hardware — no font data ships for them at all, by design. `UDG_TABLE`
  (`include/sysvars.inc`, 168 bytes) reserves the RAM; `GFX_CHAR_TO_
  FONT_OFFSET`'s `.is_udg` branch just computes `UDG_TABLE +
  (code-144)*8`, the same offset math the ROM `FONT_TABLE` case uses.
  Cold-boot/`RUN` leave this RAM at whatever it last held — same as
  every other sysvar in this project, no special initialization added
  (a program wanting a specific glyph POKEs it first, matching real
  hardware behavior exactly).

`GFX_CHAR_TO_FONT_OFFSET`'s contract changed alongside this: it now
returns an **absolute pointer** to the glyph's 8 bytes in every case
(ROM, RAM UDG, or the RAM scratch buffer), not a `FONT_TABLE`-relative
offset — `GFX_CHAR_SETUP` no longer adds `FONT_TABLE` itself. The one
caller of this routine (`GFX_CHAR_SETUP`) was updated accordingly; it
was the only caller anywhere in the codebase.

**Verified working**: `rom/test_graphics.asm` (previously never
actually assembled — its own header said so — turned out to be
missing a `kernel/math` `INCLUDE` that `GFX_LINE`/`GFX_CIRCLE` need;
fixed alongside this change) now also prints all 16 block-graphics
codes and three POKE'd UDG test patterns (a diamond, a checkerboard, a
diagonal stripe) on rows 6-7. Confirmed by screenshot: code 128 renders
blank, code 143 renders as a fully solid block, the sequence between
them visibly fills in quadrant-by-quadrant, and all three UDG shapes
render pixel-exact to their source data.

**Not yet reachable from BASIC**: there is still no way for a running
BASIC *program* to print one of these characters — no `CHR$`, no
string type, and no keyboard combo exists for codes 128-164 (real
hardware doesn't offer one either; block-graphics/UDG codes were never
part of the typed-character range). This work makes the kernel-level
mechanism real and verified; wiring it up to BASIC waits on Phase 3
(Strings) or a narrower dedicated statement, whichever comes first.

Cost: ~75 bytes Home ROM, 176 bytes RAM (comes out of the program-area
budget, same as every other sysvar addition this project has made).

### BLOCK / CIRCLE (new this round, on top of the PLOT/LINE/POINT foundation)

Continuation of the Tier 2 slice from the graphics design conversation.
`FILL` (the third Tier 2 command) is deliberately not built this
round — see `docs/basic_language_reference.md`'s Graphics section for
why it's a different kind of problem (traversal + a bounded RAM stack,
not a closed-form point formula) and belongs in its own verification
pass rather than being rushed alongside BLOCK/CIRCLE.

**BLOCK** — filled rectangle. `BASIC_STMT_BLOCK` normalizes the two
parsed corners into `GFX_BLOCK_XMIN`/`XMAX`/`YMIN`/`YMAX` while
parsing (min/max-via-CP logic verified in Python first, 2000 random
pairs, zero mismatches) — `GFX_BLOCK` itself never compares corners,
it just fills whatever already-ordered rectangle it's given. Plots one
pixel at a time via the same `GFX_WRITE_PIXEL` PLOT/LINE already use —
correctness first, matching this project's "optimize only after
correctness" standard, over a faster row-at-a-time byte-fill approach
(plausible future speed-up for large blocks, not built).

**CIRCLE** — outline via the midpoint circle algorithm (8-way
symmetry), integer only. Verified in Python against a reference
implementation before any Z80 was written: 309 circles (r=0, radii far
larger than the screen, 300 random center/radius combinations), zero
mismatches — including the algorithm's own real subtlety:

- **The x=0 and x==y duplicate-point problem.** The textbook 8-way
  reflection formula plots the same pixel twice at x=0 (the circle's
  four "poles" — top/bottom/left/right) and again at the x==y
  diagonal crossing. Harmless under `OVER 0` (setting the same pixel
  twice is a no-op), but wrong under `OVER 1`/XOR (a second toggle
  cancels the first, leaving a gap in the outline). Verified in Python
  exactly which named offset pairs coincide in each case before
  writing any Z80 — `GFX_CIRCLE_PLOT_POLES` handles x=0 once, before
  the main loop; `GFX_CIRCLE_PLOT_GENERAL` skips the "swapped" 4
  points whenever x==y.
- **The decision variable's x-y term needs real 16-bit width.** The
  same verification pass measured `|x-y|` reaching 238 across the
  tested radii — well outside an 8-bit signed byte's -128..127 range.
  An implementation that reached for a plain 8-bit `SUB` there (a
  reasonable-looking first instinct, since x and y are each bytes)
  would have silently produced wrong circles at larger radii. `GFX_
  CIRCLE` zero-extends both x and y into a real 16-bit pair before
  subtracting.

Off-screen points (a circle's bounding box routinely extends past the
screen edge, not an edge case) are handled by the new `GFX_PLOT_
CLIPPED` — every `GFX_CIRCLE_PLOT_OFFSET` call goes through it rather
than `GFX_WRITE_PIXEL` directly, since GFX_WRITE_PIXEL's own byte-sized
x/y parameters would silently wrap a negative or >255/>191 coordinate
onto the wrong edge of the screen instead of skipping it. The bounds
check itself is a small trick worth recording: for a signed 16-bit
value, "high byte is exactly zero" is both necessary and sufficient
for "0-255" in one test (it rules out negative AND >255 at once) —
`GFX_CIRCLE`'s y check adds the one extra explicit `cp 192` for its
narrower 0-191 range, same as PLOT/LINE's own y-clamping already does.

New sysvars: `GFX_CLIP_ATTR`/`OVER` (2 bytes), `GFX_BLOCK_XMIN`/`XMAX`/
`YMIN`/`YMAX`/`ATTR`/`OVER`/`CUR_X`/`CUR_Y` (8 bytes), `GFX_CIRCLE_XC`/
`YC`/`R`/`ATTR`/`OVER`/`X`/`Y`/`D` (9 bytes) — 19 bytes total,
`PROG_AREA_START` moved `$6198`->`$61AB`, full sysvar overlap check
(164 entries) confirmed zero collisions. `check_asm.py`/`check_docs.py`
clean (only the same pre-existing `BASIC_EVAL_RHS_AND_COMPARE`
`[REVIEW]` flag as every round before this one). **NOT YET ASSEMBLED
OR HARDWARE-TESTED** — same caveat as PLOT/LINE/POINT carried before
their own hardware confirmation.

### CPLOT, and TS2068 hardware research for MODE/PALETTE (background — MODE itself is implemented further down)

**CPLOT** — coarse 2x2-per-cell block-graphics plot. Originally scoped
in the graphics design conversation as "wraps existing `GFX_PUTCHAR`,
no new drawing engine" — checking that assumption against the actual
font (`FONT_TABLE`, 86 glyphs, all text characters, indexed by ASCII
code through `GFX_CHAR_TO_FONT_OFFSET`) found it was wrong: there are
no block-graphics quadrant glyphs to wrap. Rather than add 16 new
glyphs and route them through the character-code machinery (which
exists for *text*, and would need CPLOT to somehow have its own
pseudo-ASCII-code space), a simpler design fell out once actually
worked through: filling a 4x4-pixel quadrant is just OR/XOR-ing a
repeated byte pattern (`$F0` left half, `$0F` right half) into 4
consecutive scanline bytes of the cell — verified in Python that this
byte-level shortcut produces exactly the same result as plotting all
16 pixels in the quadrant individually, across random pre-existing
cell content (2000 trials, zero mismatches), before writing any Z80.
No font glyphs needed at all — an initial 16-entry lookup-table design
was worked out and Python-verified too, then discarded once the
simpler equivalence was actually checked rather than assumed to need
one. `cx`/`cy` are both explicitly clamped (0-63 / 0-47) — unlike
`PLOT`'s `x`, neither is a full byte's natural range.

**TS2068 hardware research for MODE/PALETTE** — before writing any of
Tier 3's mode-switching code, went back to verify the actual hardware
facts (project's own established rule: never guess), and found the
real TS2068 Technical Reference Manual (archive.org) rather than
relying on the looser community terminology this project's own
earlier design conversation had used. The manual's own terms and
exact port `$FF` values:

| Manual's name | VIDMOD / port `$FF` value | What it actually is |
|---|---|---|
| Normal | 0 | Standard 256x192, 8x8 attribute — what this ROM already implements |
| Dual Screen | 1 (2nd file active) / 128 (1st file active) | A second, independent 256x192+8x8-attribute display file — not a different pixel format at all |
| High Resolution Graphics | 2 | Same 256x192 bitmap as Normal, but attribute resolution is 8x1 instead of 8x8 (this is what community sources call "Extended Color") |
| 64-Column Mode | 6/14/22/.../62 (bits 3-5 select 1 of 8 ink/paper pairs) | True 512x192 two-color mode (what community sources call "Hi-Res") — mode selection and palette selection are the *same* port write, not two separate operations |

**A real architectural conflict this surfaced, resolved further down**:
High Resolution Graphics mode's 6144 attribute bytes (32 cols x 192
rows x 1 byte, 8x1 each) live in the *second display file*'s memory,
at `$6000`-`$77FF` per the manual's own RAM map. This ROM's own
`PROG_AREA_START` was, at the time this was found, `$61AD` — squarely
inside that same range — with BASIC program text growing upward from
there. Turning on High Resolution Graphics mode with any real program
loaded would have had the video hardware and the BASIC program
fighting over the same bytes. Dual Screen mode has an even bigger
version of this problem: the manual's own `CHNG_VID` service relocates
the *machine stack* and *all* OS RAM routines out of that area before
enabling it, because the stock Timex ROM's memory map assumes that
space is free for a second screen — this ROM's memory map was never
designed with that constraint in mind. See the RAM migration section
right after this one for how this got resolved — not deferred.

### RAM migration: entire sysvar/program-area region moved from $5D00+ to $8000+ (new this round, resolves the conflict above)

[stated]'s call, after separately confirming this decision tree
didn't need to wait on their own stated future intent to audit other
places this project may have inherited 2068-era convention without
re-deriving it from scratch: fix the conflict above properly rather
than narrowly. Checked the TS2068's real memory topology instead of
assuming one shared RAM pool — the machine has two *physically
separate* RAM chip pools: a dedicated 16K "Video Display RAM" at
`$4000`-`$7FFF` (wired directly to the SCLD's video address
generation) and a completely separate 32K general RAM at
`$8000`-`$FFFF`. This project's entire custom sysvar region started at
`$5D00` — inside the video pool, apparently because it was placed to
mirror the *stock* Spectrum/TS2068 ROM's own system variables at
`$5C00` (`docs/memory_map.md`'s old UDG-area note even said as much:
"mirrors 48K Spectrum convention"). That inherited placement was
invisible while only Standard video mode existed, but High Resolution
Graphics/64-Column/Dual-Screen modes use the *rest* of that same 16K
pool — fixed by the hardware, not something software can relocate.

Migrated the *entire* sysvar block into the general RAM pool: a
uniform +$2300 shift (166 sysvars, `EDIT_CURSOR_ROW` $5D00->$8000
through `PROG_AREA_START` $61AD->$84AD; `PROG_AREA_MAX` excluded from
the shift, since $FF00 was already correctly inside the destination
pool as the stack ceiling) — verified in Python before touching the
real file (every non-`PROG_AREA_MAX` entry shifts by exactly the same
delta; zero collisions after), then re-verified against the actual
committed file afterward. This permanently eliminates the conflict for
every current *and future* video mode, with no runtime relocation and
no "not enough memory" failure tied to switching modes — deliberately
not copying the stock ROM's own answer to this same problem (`CHNG_
VID` dynamically relocated the machine stack and OS RAM routines out
of the way only when a program actually needed the second display
file, giving Out-of-Memory if the shuffle didn't fit): this ROM has
real, physically separate RAM to just use instead, so it does.

Confirmed the migration's blast radius was genuinely contained to
`sysvars.inc` alone before doing it: grepped every other `.asm` file
for hardcoded addresses in the affected range and found none outside
comments — every real reference goes through a symbolic name, per this
project's own coding standard. `check_asm.py` re-run against every
kernel module (not just the ones touched this session) plus
`basic.asm`, all clean (same single pre-existing `[REVIEW]` flag).
`check_docs.py` clean. `docs/memory_map.md` rewritten with the new
address table and the full hardware/decision writeup (that document is
now the authoritative source for *why*, not just *what*) — a genuinely
useful side effect: ~31.8K now sits between `PROG_AREA_START` and the
stack, versus a much tighter margin before, and `PROG_AREA_MAX`'s own
long-standing "round number, not a considered budget" placeholder note
is resolved by simply landing comfortably inside it rather than
needing to be revisited under pressure.

Generated preload harnesses (`rom/test_preload_*.asm`) need no
changes — they reference `PROG_AREA_START` symbolically, so they pick
up the new address automatically on the next assembly.

**NOT YET ASSEMBLED OR HARDWARE-TESTED.** This is a foundational,
whole-project change — worth a full regression pass (not just a smoke
test) once assembled, given every existing feature's state now lives
at different absolute addresses even though no code logic changed.

### sysvars.inc: assembler-computed addresses, not hand-typed hex (2026-08-23)

Prerequisite step for the still-open "option 3" scalar-into-dynamic-pool
migration (see the Numeric arrays section's own "option 2"/"option 3"
discussion below) — done first, on its own, because it was identified
as that migration's real risk concentration: relocating `VAR_TABLE`/
`STR_TABLE` out of the fixed sysvar region means every downstream
address shifts, and until this change that meant hand-recomputing and
retyping ~285 hex `EQU` values by hand, exactly the "stray wrong
address" bug class `check_asm.py` exists to catch and this project's
own single most expensive debugging arc to date (per `CLAUDE.md`).

Every `NAME EQU $HEX` address declaration in `sysvars.inc` (285 of
them — everything from `EDIT_CURSOR_ROW` through `PROG_AREA_START`,
excluding `PROG_AREA_MAX`, an out-of-band hardware boundary constant
declared inline rather than part of the sequential chain) is now
`NAME: DEFS <size>` instead — sjasmplus computes each address itself
as a running offset from `ORG $8000`, the same way it already computes
label addresses in real code. `PROG_AREA_START` itself (the chain's
last entry, and the movable boundary marking where the growable
program area begins) becomes a bare label with no `DEFS`, since it
never reserved fixed bytes of its own. The ~36 plain-integer constants
that were never addresses to begin with (`EDIT_LINE_BUF_LEN`,
`UDG_COUNT`, `STRFUNC_ID_*`, etc.) were left untouched — this is a
format change for *addresses*, not a rewrite of the file's constants.
`SYSVARS_RETURN_ORG` (captured via `EQU $` immediately before `ORG
$8000`, restored via `ORG SYSVARS_RETURN_ORG` at the very end of the
`IFNDEF` guard) lets the ~130 files that `INCLUDE` this file resume
normal ROM assembly exactly where they left off — this $8000+ range is
RAM-only and never reaches any `SAVEBIN`, so declaring it via `DEFS`
costs zero actual ROM bytes, same as the old `EQU`s did.

**Verified byte-for-byte, not just "it assembles"**: built both
`rom/test_basic.asm` and `rom/exrom_build.asm` against the old and new
`sysvars.inc`, dumped `--sym` symbol tables for each, and diffed them —
every one of ~1400 symbols in the full merged build matched exactly,
the only addition being `SYSVARS_RETURN_ORG` itself. `check_asm.py`
(all kernel modules + `basic.asm`) and `check_docs.py` both still clean
(same single pre-existing `[REVIEW]` fingerprint in
`BASIC_EVAL_RHS_AND_COMPARE`, unrelated). Regression suite: `mem1`/
`mem2` (this change's own stated priority target), `storage_
roundtrip1`, and one fixture each from `arr`/`cf`/`err`/`io`/`math`/
`str`/`gfx`/`spr`/`snd`/`usr`/`misc` all green (or the deliberate cyan
"aborted before reaching the fail-color `BORDER`" sentinel `mem2`/
`err1` use on purpose).

**One real downstream break found and fixed**: `tools/
fuse_load_inject.py`'s `read_equ()` regex-scraped `NAME EQU $HEX`
straight out of `sysvars.inc`'s source text to get `PROG_AREA_START`/
`STORAGE_OP_STATE`/`STORAGE_PROGRESS_PCT` for its
Fuse debugger-injection script — silently stale now that those
addresses no longer appear as literal hex in the source. Fixed by
having it assemble a throwaway stub (`ORG $0000` + `INCLUDE "include/
sysvars.inc"`) and read the real `--sym` output instead of re-parsing
source text — strictly more robust than the regex ever was (survives
*any* future sysvars.inc format change, not just this one), and keeps
the exact same "read live, don't hardcode" intent its own header
comment already documented. `preload_gen.py`, `check_asm.py`,
`check_docs.py`, and `tools/z80sim/sim.py` were all checked and don't
parse `sysvars.inc`'s address format at all — no changes needed there.

**Two unrelated pre-existing issues surfaced while checking the blast
radius, confirmed NOT caused by this change** (reproduced identically
against the untouched old `sysvars.inc`): `rom/test_exrom_isolation.
asm` fails to assemble (`Label not found: STORAGE_MATH_MULTIPLY16`/
`STORAGE_MATH_DIVIDE16` in `storage.asm`) — looks like a missing
`kernel/math` `INCLUDE` in that specific test file, same bug class
`test_graphics.asm` had before its own fix (see that section above).
`rom/test_editor_auto.asm` has a `warning[shortblock]: init data ...
truncated to length: 0` — the razor-thin 16K test-binary margin
`CLAUDE.md` already flags as a known issue. Neither was in scope here;
noted so they aren't mistaken for something this change introduced.

Next step: the scalar migration itself (`VAR_TABLE`/`STR_TABLE` ->
dynamic pool) can now proceed as a purely mechanical relocation in this
file, with the assembler — not a human — re-deriving every downstream
address.

### Scalar variables in the dynamic pool — Phase 4 (2026-08-23)

Completes the "option 3" path flagged back in the Numeric arrays
section above: `VAR_TABLE`/`STR_TABLE` (26 fixed 2-/32-byte slots each,
reserved whether or not a program ever uses all 26 letters) are gone,
replaced by two more record kinds in the same pool arrays already use
— `ARRAY_KIND_NUM` (0, existing), `VAR_KIND_NUM` (1), `VAR_KIND_STR`
(2). Reclaims the 884 bytes those fixed tables always cost, whether
used or not, back into the growable region: `PROG_AREA_START` moved
from `$BC01` to `$B8B1`, taking the program+array+scalar ceiling from
1023 to 1871 bytes.

**The real design problem, found during implementation, not anticipated
up front**: arrays reset every `RUN` (`ARRAYS_END := PROG_END`, RUN-
scoped, matching classic BASIC's "RUN implies CLEAR"); scalars had
never worked that way — `VAR_TABLE` was only ever zeroed at `NEW`/
`LOAD`, persisting across `RUN`. Naively putting scalars in the same
upward-growing region arrays use would force a choice between wiping
live scalar data every `RUN` (a real regression) or risking program
edits between runs (which grow `PROG_END`) silently overwriting scalar
data sitting just above it (arrays get away with that only because
they're always freshly re-created after such an edit; scalars weren't).

**Fix: a genuine two-ended pool.** Arrays keep growing UP from
`PROG_END` to `ARRAYS_END`, completely unchanged. Scalars grow DOWN
from `PROG_AREA_MAX` to a new `VARS_START` — "empty" is `VARS_START ==
PROG_AREA_MAX`, mirroring `ARRAYS_END == PROG_END`. `VARS_START` resets
only at `MEM_INIT` (cold boot + `NEW`) and `LOAD`, exactly matching
`VAR_TABLE`'s old schedule — and, as a genuine side effect rather than
a deliberate extra fix, this closes two latent gaps at once: `VAR_TABLE`
was never actually zeroed at cold boot before (folding its reset into
`MEM_INIT` fixes that for free), and `STR_TABLE` never had ANY reset
schedule at all (it now gets the same one `VAR_TABLE` always had,
correcting what looks like an oversight rather than intended
behavior). `MEM_FREE_BYTES` and the program-growth boundary check
(`MEM_LINE_INSERT`/`MEM_LINE_STORE` in `kernel/memory/memory.asm`) both
now compare against `VARS_START` instead of the fixed `PROG_AREA_MAX`.
LOAD's own max-accepted-length bound (`basic/basic.asm`'s `BASIC_DO_
LOAD`) can no longer be the compile-time constant `PROG_AREA_MAX -
PROG_AREA_START` it used to be, since the ceiling is a runtime value
now — computed fresh from the CURRENT (not-yet-reset) `VARS_START` at
LOAD time, correctly accounting for whatever scalar-pool space the
program *being replaced* still has in use.

**One shared routine, not three.** `BASIC_ARRAY_FIND` is now generic
(`A` = letter, `C` = kind) — region bounds picked by kind rather than
passed in, since there are only ever two possible regions, and record-
matching now genuinely compares kind (previously always assumed 0 and
skipped). A neat, verified-safe merge collapses what would otherwise be
a duplicated "skip past this record" branch: kind values (0-2) can
never equal a real letter (65-90 ASCII), so on a kind mismatch the scan
falls through into the SAME name-compare-and-skip code used on a kind
match, using the stale kind byte still sitting in `A` as an
unconditionally-false stand-in for the name compare — cheaper than two
copies of the skip logic, and correct because the value ranges are
provably disjoint. New shared `BASIC_VAR_FIND_OR_CREATE` backs both
`BASIC_VAR_ADDR`/`BASIC_STR_ADDR` (now thin kind-tagged wrappers,
mirroring the KTAB trampoline / `STR_FUNC_DEST` "thin wrapper, shared
core" pattern already used elsewhere): looks a scalar up via `BASIC_
ARRAY_FIND`, and on a miss, auto-vivifies it — creates a fresh zero-
initialized record, prepending at `VARS_START` (mirrors `BASIC_STMT_
DIM`'s own append-and-zero-init, just growing the other direction) —
since a classic BASIC scalar reads as 0/"" on first reference with no
`DIM` needed, unlike arrays. This is also a real, NEW failure mode
neither fixed table could ever hit: OUT OF MEMORY on first reference,
if the two ends of the pool would cross. All 9 existing `BASIC_VAR_
ADDR`/`BASIC_STR_ADDR` call sites needed a carry check added — one
(`BASIC_EVAL_STR_PRIMARY`'s `.var_ref`) had ALSO been relying on `C`
(a caller's own budget value) surviving the call, true under the old
fixed-table contract but not this one; caught by design review, not by
a failing test, before it shipped as a silent corruption.

**`BASIC_CHECK_ONLY` guard, added where arrays already needed one, for
the same reason**: a static whole-program check pass must not mutate
real state (`BASIC_CHECK_ARRAY_ASSIGNMENT`'s own header already
established this for arrays) — without a guard, referencing a variable
in a statement that hasn't run yet would auto-vivify a real pool
record, or spuriously OUT-OF-MEMORY, purely from being checked. One
guard inside the shared `BASIC_VAR_FIND_OR_CREATE` (returns a dedicated
`VAR_CHECK_SCRATCH` dummy address, real pool state untouched) covers
all 9 call sites at once — cheaper and simpler than arrays' own per-
call-site guards, since every scalar call site wants the exact same
"just give me a safe address" fallback, unlike arrays' several
genuinely different check-mode behaviors (DIM, read, assignment, DIMN).

**A real, deliberate behavior change, not a bug** (found via `tests/
mem1.txt` going red after the migration, then explained rather than
"fixed" away): `F = FREE()` evaluates `FREE()` before creating F's own
scalar record — so the RHS is measured, then storing it into F consumes
4(header)+2(data)=6 bytes from the SAME pool `FREE()` just measured.
`mem1.txt`'s expected delta moved from 22 (`DIM A(9)`'s own cost alone)
to 28 (+ F's own 6-byte creation cost). This is correct, not a
regression: a real dynamic pool should charge for naming a variable,
which the old free-standing `VAR_TABLE` never did.

**ROM budget, measured not estimated, at every step**: Home ROM was
147 bytes free before this Phase started, EXROM 19 bytes (`rom/test_
basic.asm`/`rom/exrom_build.asm`). Landed at 2 bytes Home ROM free, 17
bytes EXROM free — verified via repeated real `sjasmplus` builds
throughout, not projected. Getting there needed real register-
allocation cleanup in the new code (all verified safe, not just
"probably fine"): `BASIC_ARRAY_FIND`'s kind-byte comparison stashes the
target letter in `B` before the bounds-setup clobbers `A`, instead of a
`push af`/`pop af` pair (`B` is dead at entry, cheaper); `BASIC_VAR_
FIND_OR_CREATE` exploits that `BASIC_ARRAY_FIND` only ever *reads* `C`
(kind), never writes it, so the caller doesn't need to preserve it
across the call at all; two `or a`s (`BASIC_VAR_FIND_OR_CREATE`'s own
zero-init tail, and the *pre-existing* identical shape in `BASIC_STMT_
DIM`'s own zero-init tail, fixed alongside once the pattern was
spotted) turned out to be provably redundant — both are only ever
reached via a zero-init loop's own `or e` check, which already clears
carry, and nothing between there and the `ret` touches flags again.

**Testing infrastructure had to be overhauled to keep up** — see `CLAUDE.md`'s
own build/test section and this file's `kernel/storage` section's Track
A material for the mechanism (`rom/test_suite_inject.asm` + `tools/
fuse_suite_inject.py`, Fuse-debugger injection instead of baking test
programs into the ROM image). All 61 `tests/*.txt` fixtures pass
through the new mechanism; 6 (`spr1-4`, `gfx7`, `misc3`) needed
hardcoded `PEEK`/`POKE` addresses corrected, since they referenced
absolute sysvar addresses that shifted along with everything else once
`VAR_TABLE` was removed — a reminder that a hardcoded address in a TEST
fixture is exactly as fragile as one would be in real product code.

### MODE (implemented — Tier 3's remaining items, on top of the RAM migration above)

With the memory conflict resolved, came back to finish Tier 3's
missing pieces. First round's scope: `MODE 0`/`MODE 1` (Normal / High
Resolution Graphics) fully working, including making `PLOT`/`LINE`/
`BLOCK`/`CIRCLE` draw correctly in either mode; `PALETTE` and true
64-Column mode deferred at the time — see the "64-Column mode" section
further down for where that got picked back up.

**Port `$FF` is shared, so `GFX_SET_MODE` never writes it directly.**
Per `hardware.inc`'s own `PORT_SCLD` comment, that single byte also
carries INTEN (bit 6) and Extension ROM/cartridge select (bit 7) —
neither this project's to disturb. `GFX_SET_MODE` reads `PORT_FF_
SHADOW`, replaces only bits 0-2, and writes the merged byte back to
both the shadow and the port — the same read-modify-write pattern
`GFX_SET_BORDER` already uses for port `$FE`, adopted here from the
start rather than risking the exact bug that pattern exists to
prevent (`GFX_SET_BORDER` itself used to lack a shadow and silently
zeroed bits it didn't mean to touch — see that routine's own header).
Confirmed this ROM never enables the maskable interrupt (`rom/main.
asm`'s handler is a placeholder `ret`; `kernel/io`'s keyboard scan is
polled, not interrupt-driven) before treating INTEN as safely
ignorable rather than something that needed preserving from some
other source of truth.

**`PLOT`/`LINE`/`BLOCK`/`CIRCLE` become mode-aware for free.** All
four already funnel through the shared `GFX_WRITE_PIXEL` (`BLOCK`/
`LINE` call it directly per pixel; `CIRCLE` through `GFX_PLOT_
CLIPPED`) — exactly the payoff the "one shared primitive" design
decision from the PLOT/LINE/POINT round was for. Made `GFX_WRITE_
PIXEL`'s attribute step branch on `GFX_MODE`: Normal mode calls the
existing `GFX_SET_ATTR` unchanged; High Resolution Graphics mode
reconstructs a real scanline row (`GFX_PIXEL_ROW*8 + GFX_PIXEL_
SCANLINE` — both already computed by `GFX_PIXEL_ADDR_SETUP`, no need
to re-derive from the original x/y, which are no longer live in any
register by that point) and calls the new `GFX_SET_ATTR_EXT`, which
uses the same `row*32+col` formula as `GFX_SET_ATTR` but based at
`SECOND_DISPLAY_ADDR` (`$6000`) instead of `ATTR_ADDR` — deliberately
its own small routine rather than a parameterized version of `GFX_
SET_ATTR`, since changing a proven, hardware-confirmed routine's
calling contract to save a few duplicated lines of arithmetic is the
worse trade (same reasoning already given for `MATH_NEGATE16` in a
near-identical spot). Address formula and the row/scanline
reconstruction both verified in Python before any Z80 was written —
the reconstruction identity (all 192 values), the address formula
itself (all 6144 (y,col) pairs land on unique, in-range addresses),
and the two chained together end-to-end exactly as `GFX_WRITE_PIXEL`
executes them — zero mismatches across all three checks.

**`GFX_READ_PIXEL`/`POINT` need no changes at all** — High Resolution
Graphics mode uses the identical pixel bitmap layout as Normal, only
the attribute scheme differs, so pixel-level reads are already
correct regardless of mode.

**`GFX_CPLOT` is a known, documented exception.** It sets attributes
via its own direct `GFX_SET_ATTR` call (not through `GFX_WRITE_
PIXEL`, for efficiency — it operates on a whole quadrant per call, not
a single pixel), and that call was not made mode-aware this round:
`CPLOT` always colors the whole 8x8 cell, even in High Resolution
Graphics mode, where the hardware wouldn't be reading from that
address at all. The pixels themselves still draw correctly (same
bitmap either way) — only the color is wrong in that mode. Doing this
properly needs a small loop (one attribute write per touched
scanline, not one per cell) rather than being a drop-in reuse of the
`PLOT` fix, so it's flagged as a real gap rather than silently
patched over or silently left unmentioned.

**Entering High Resolution Graphics mode initializes its own memory.**
The RAM migration made `$6000`-`$77FF` genuinely unused by anything
in this ROM except this mode — not "probably zero," actually
never-written, whatever was in RAM at power-on. `GFX_SET_MODE` clears
all 6144 attribute bytes to `ATTR_DEFAULT` (the same PAPER 7/INK 0
`GFX_CLS` already uses) the first time mode 1 is entered, specifically
choosing a real default over raw zero — zero would decode as PAPER 0/
INK 0 here, i.e. black-on-black, the exact same "invisible" trap a
real test program already hit once with `INK`/`PAPER` (see the Tier-2
session above). `MODE 0` needs no such initialization — the primary
screen is already maintained by every existing routine regardless of
which mode is active.

**`MODE`'s own range validation is a runtime error, not a static
one**, and deliberately doesn't silently clamp the way `BORDER` does.
`BORDER`'s masking makes sense because every one of the 8 values a
mask can produce is a legitimate color — there's no wrong answer to
clamp toward. `MODE` has no such safe default: 64-Column mode isn't
implemented, so a value like `MODE 3` has no sensible interpretation
to fall back to, and silently mapping it onto Normal or High
Resolution Graphics would be actively misleading. Raises a new `MSG_
INVALID_MODE` ("INVALID MODE") the same way `DIVISION BY ZERO` already
demonstrates for "this can only be known once the expression's actual
value is seen" — `BASIC_CHECK_STATEMENT_CONTENT`'s static pass only
validates that `MODE`'s grammar is one expression (reusing `.check_
border`, identical shape), the same split `DIVISION BY ZERO` already
has between grammar-checking and value-checking.

**`PALETTE` and true 64-Column mode were deferred at this point** —
see the dedicated section below for how and when that got picked back
up.

**ULAplus support was later added as an independent extension.**
`ULAPLUS 0|1` selects register 64 through `$BF3B` and writes its enable
bit through `$FF3B`; `PALETTE index,value` writes registers 0-63 through
the same port pair using `GGGRRRBB` values. Both commands share one
EXROM entry and require no RAM palette mirror. The raw-port probe was
verified in ZEsarUX 13.0; the installed Fuse 1.9.1 lacks ULAplus.

New sysvars: `GFX_MODE` (1 byte, this project's own friendly 0/1
numbering, not the raw port `$FF` value) and `PORT_FF_SHADOW` (1
byte) — `PROG_AREA_START` moved `$84AD`->`$84AF`, 168 sysvars, zero
collisions confirmed. `check_asm.py` clean on both modified files
(same single pre-existing `[REVIEW]` flag as every round).
`check_docs.py` clean.

**Real gap found and fixed after real-hardware/Fuse testing**: `GFX_
MODE` had no defensive reset anywhere — every other piece of drawing
state (`BORDER_DEFAULT`, `BASIC_RESET_TEXT_ATTR`'s INK/PAPER/FLASH/
INVERSE/OVER) is explicitly re-established at cold boot, `NEW`, and a
successful `LOAD`, precisely because RAM can't be trusted to start at
a known value on real hardware. `GFX_MODE` was the one exception —
relying entirely on whatever an emulator's own RAM-zero-at-load
convention happens to provide, which isn't something real hardware
guarantees. Found while investigating a real visual discrepancy (an
identical `CIRCLE` statement looked different than in an earlier,
already-confirmed test) — traced to this gap rather than a bug in the
mode-branching logic itself (which reads correctly once `GFX_MODE` is
known-good). Fixed with `xor a` / `call GFX_SET_MODE` added at all
three of `BASIC_RESET_TEXT_ATTR`'s own call sites (cold boot, `NEW`,
post-`LOAD`) — same defensive pattern, same places, immediately after
the existing call in each case.

**Confirmed on real hardware/Fuse**: `MODE 0`/`MODE 1`, `PLOT`/`LINE`/
`BLOCK`/`CIRCLE` drawing correctly in both, and `POINT()` reading back
correctly regardless of mode — all confirmed via `test_preload_mode.
asm` and the follow-up control test. The one open visual question from
that testing (a circle looking "blockier" in one screenshot than
another) turned out to be pixel-density clustering at 256x192
resolution, present in both modes and unrelated to any of this work —
see the graphics design conversation's own corrected framing for the
full explanation.

### 64-Column mode: PLOT/POINT support, MODE 2, PALETTE (new this round)

**REMOVED 2026-08-20** — mode 2 (64-Column) and the `PALETTE`
statement were removed entirely: real overhead (~750-950 bytes across
`kernel/graphics`/`basic.asm`) versus value, freed for more core
language features. `MODE` now validates 0-1 only. This section (and
the "LINE, BLOCK, and CIRCLE gain 64-Column mode support" section
below) is kept as history of what was built and why, not current
behavior.

Came back to finish what MODE 0/1 deferred, prompted by a direct
question: is there any way to reduce attribute clash further than
mode 1 already does? The honest answer pointed here — 64-Column mode
has no per-pixel attribute concept at all, so it isn't a "less clash"
mode, it's a "no clash" mode, at the cost of only 2 colors screen-wide.

**Verified the real combination scheme before writing any Z80** — not
assumed from the port-value table alone. The manual states it
directly: "The two display files are combined to provide a 64 column
X 24 line screen. Even columns are derived from data in the Primary
Display File and odd columns from the 2nd Display File." That's a
column-level interleave, not a bit-level one — each of the 64
character-columns (8 pixels wide, same as always) comes entirely from
one file or the other, alternating.

**The real architectural fork this raised**: 512 pixels wide needs 9
bits of `x`, and every existing coordinate parameter in this project
(`GFX_WRITE_PIXEL`'s `B`, `BASIC_STMT_PLOT`'s truncate-to-`E`) is a
single byte. Rather than invent a separate `PLOT`-alike statement,
made `PLOT` and `POINT()` themselves mode-aware: both already have the
full 16-bit expression result in hand before truncating it, so in mode
2 they simply keep 9 bits instead of 8 (`D` masked to its bit 0, `E`
already exactly bits 0-7 — verified this exact masking against a
plain 9-bit `AND` across 2000 random signed 16-bit values before
writing it). `LINE`/`BLOCK`/`CIRCLE`/`CPLOT` do **not** get this
extension yet — each would need the same treatment individually, not
a shared fix, so this round is `PLOT`/`POINT` as one complete,
verified slice rather than a half-finished sweep across five
statements.

**Addressing reuses the already-proven `ROW_BASE_TABLE` rather than
deriving a second one.** The Second Display File keeps the exact same
non-linear row layout as the Primary — confirmed arithmetically
(`$6000` - `$4000` = `$2000` exactly) — so `GFX_PIXEL64_ADDR_SETUP`
computes the Primary file's address the normal way and just adds
`SECOND_DISPLAY_DELTA` ($2000) when the pixel's 64-column index is
odd. Verified in Python before any Z80 was written: all 512x192 =
98,304 pixel positions land on unique addresses inside the correct
file's real range, zero collisions — plus the 16-bit `x>>3` shift
sequence (`SRL H`/`RR L` x3) checked against plain division for every
value 0-511.

**No attribute step in `GFX_WRITE_PIXEL64` at all** — unlike
`GFX_WRITE_PIXEL`, there's no per-pixel color to compute or write in
this mode, so the routine is simpler, not just differently addressed.
`GFX_READ_PIXEL64` needed no attribute awareness either, for the same
reason.

**`GFX_SET_MODE` extended, not duplicated**, for mode 2: writes
`palette*8+6` (bits 0-5 combined — mode-select and palette-select
share those bits in mode 2, unlike modes 0/1 where only bits 0-2
matter) via the same `PORT_FF_SHADOW` read-modify-write already
established for modes 0/1. Entering mode 2 clears the Second Display
File's *bitmap* region to raw zero (not `ATTR_DEFAULT` — this is
pixel data now, not an attribute byte, and zero genuinely means
"nothing set" here) — without this, switching from mode 1 (which
left old attribute bytes there) or from cold power-on would show
speckled garbage across every odd 64-column position.

**`GFX_SET_PALETTE` is new and small**: masks to 0-7 like `GFX_SET_
BORDER`'s own colour parameter (every value is genuinely valid, no
runtime error needed), stores the choice in a new `GFX_PALETTE`
sysvar regardless of current mode (so re-entering mode 2 later
remembers the last palette rather than resetting to Black/White), and
only touches the port immediately if mode 2 is already active.

**`MODE`'s validation extended from 0-1 to 0-2**; `PALETTE`'s own
grammar reuses `.check_border` (single expression, identical shape) —
same "static check validates grammar, values are a runtime concern"
split `MODE`'s own check already established.

New sysvars: `GFX_PALETTE` (1 byte) + `GFX_PIXEL64_MASK`/`WHICH_FILE`/
`BYTECOL`/`OVER` (4 bytes, mirroring `GFX_PIXEL_*`'s own scratch but
for the wider coordinate space — `GFX_PIXEL_ROW`/`SCANLINE` are
reused directly, since y's addressing is identical either way) — 5
bytes total, `PROG_AREA_START` moved `$84AF`->`$84B4`, 173 sysvars,
zero collisions confirmed. `check_asm.py` clean on both modified files
(same single pre-existing `[REVIEW]` flag as every round).

**Confirmed on real hardware/Fuse**: all three self-check assertions
PASS — a dotted line spanning both display files with no seam or
misalignment where Primary hands off to Second, and the mode-0
round-trip point landed correctly. `LINE`/`BLOCK`/`CIRCLE`/`CPLOT`'s
own mode 2 support and `PRINT`'s mode 2 awareness remain open
follow-ups.

### Round 1 of the deferred-gaps list: BRIGHT, GFX_CHAR_SETUP bounds check, CPLOT mode-1 attribute fix (new this round)

Smallest-to-biggest pass through the accumulated deferred-work list,
grouped so the smallest, most independent items ship and test
together rather than trickling out one at a time.

**`BRIGHT <n>`** — new statement, built as a direct mirror of `FLASH`/
`INVERSE`: new `CURRENT_BRIGHT` sysvar (0/1, same masking), a new
`BASIC_STMT_BRIGHT` copy-pasted from `BASIC_STMT_FLASH`'s own shape,
and one new branch in `BASIC_COMPUTE_PRINT_ATTR` that ORs in `$40`
(the attribute byte's BRIGHT bit) the same way the existing FLASH
branch ORs in `$80`. Not a new capability at the hardware level — bit
6 of the attribute byte has always existed and `GFX_SET_ATTR`/`GFX_
SET_ATTR_EXT` never cared which bits their caller set — just a
missing statement to reach it. Reset alongside the other text
attributes at all three of `BASIC_RESET_TEXT_ATTR`'s call sites (cold
boot, `NEW`, post-`LOAD`), same defensive-initialization discipline
`GFX_MODE` needed adding after the fact — `CURRENT_BRIGHT` got it from
the start instead.

**`GFX_CHAR_SETUP` bounds check** — the real fix behind a caveat this
project has been carrying since the SAVE/LOAD debugging arc: a
`PRINT` string running past column 31 had no bounds check anywhere in
its actual runtime path, only in `BASIC_PRINT_LINE_HIGHLIGHTED` (the
`LIST`-redraw path, fixed back then). `GFX_CHAR_SETUP` — the shared
address computation both `GFX_PUTCHAR` and `GFX_PUTCHAR_BOLD` call —
now checks row (0-23) and column (0-31) itself, before computing any
address, and signals out-of-range via carry rather than silently
producing a wrong address. Both call sites now check that carry and
skip drawing entirely rather than writing into whatever memory
happens to sit past the intended row — same "silently clip rather
than corrupt" precedent `GFX_PLOT_CLIPPED` already established for
pixel graphics. Test programs have been manually avoiding this by
convention (keeping `PRINT` strings under 32 characters); this closes
the actual gap rather than just avoiding it.

**`GFX_CPLOT` mode-1 attribute fix** — the known, documented gap from
when `MODE`/`PALETTE` first shipped: `CPLOT` writes attributes via its
own direct `GFX_SET_ATTR` call (not through `GFX_WRITE_PIXEL`, since
it operates on a whole quadrant per call rather than one pixel), so it
never inherited that routine's mode-awareness the way `PLOT`/`LINE`/
`BLOCK`/`CIRCLE` did automatically. Now branches the same way `GFX_
WRITE_PIXEL` does: Normal mode colors the whole 8x8 cell as before;
High Resolution Graphics mode writes one attribute per touched
scanline (4, via `GFX_SET_ATTR_EXT`) instead, matching that mode's 8x1
resolution. Unrolled 4 times rather than a counted loop — `GFX_SET_
ATTR_EXT` destroys `DE`, which would otherwise have to double as the
loop counter across each call; unrolling sidesteps the conflict
instead of fighting it. `B`/`C` (real-y/column) genuinely do survive
each call, per that routine's own documented `Destroys: AF, DE, HL`
contract. Still not mode-2-aware — 64-Column mode needs the same
coordinate-width extension `PLOT` already got, not attempted here.

New sysvar: `CURRENT_BRIGHT` (1 byte) — `PROG_AREA_START` moved
`$84B4`->`$84B5`, 174 sysvars, zero collisions confirmed. `check_asm.
py` clean on both modified files (same single pre-existing `[REVIEW]`
flag as every round).

**Real hardware testing found a second half of this same bug that
static analysis and the first fix both missed.** `test_preload_round1.
asm` showed the two `AT row,0` prints plus `BRIGHT` rendering
perfectly in isolation (`test_preload_isolate_a.asm` confirmed this
cleanly), which pointed the remaining corruption at the long-line
clip test or `MODE 1`/`CPLOT`. Tracing it: `GFX_CHAR_SETUP`'s new
bounds check protects the *bitmap* write, but `GFX_PRINT_STRING_ATTR`
calls `GFX_SET_ATTR` — the *attribute* write — completely separately,
unconditionally, for every character including ones `GFX_PUTCHAR`
now correctly skips past column 31. `GFX_SET_ATTR` itself never had
any bounds check at all. Since attribute memory is a flat
`row*32+col` array, walking `col` past 31 silently spills into the
*next* row's attribute bytes. Verified in Python before touching any
Z80: a 31-character string (`PRINT`'s own `PRINT_BUF` clamp) starting
at column 20 lands its overflow at row+1, columns 0-18 — real,
traceable corruption, not hypothetical.

Fixed the same way `GFX_CHAR_SETUP` was: row/col bounds-checked at
entry, silent no-op on out-of-range (no carry-flag contract change
needed here, since none of `GFX_SET_ATTR`'s existing callers check
any return status — a strictly additive safety fix). **Caught a real
mistake in my own first draft of this exact fix before it shipped**:
the bounds-check code used `A` as scratch for the row/col comparison
without stashing the caller's actual attribute byte first, which
would have silently written the wrong value on every successful call,
not just the out-of-range ones — same stash-before-scratch pattern
`GFX_CHAR_SETUP` already used, just missed on the first pass here.
Caught by re-reading the draft before running it, then confirmed via
real z80sim instruction simulation (not hand-tracing) for both the
in-range case (correct attribute byte lands at the correct address)
and the out-of-range case (nothing written at all) — same rigor
applied to the sibling fix in `GFX_SET_ATTR_EXT` (bounds `0-191`/`0-31`
for its own real-scanline-row/column parameters), verified the same
three ways (in-range, out-of-range row, out-of-range column).

`test_preload_isolate_b.asm` (5 statements) tests this directly:
prints at row 5 in one color, then deliberately changes color before
running the overflowing long-line print at row 4 — if the bug were
still present, row 5's first ~19 characters would visibly change
color (revealing exactly where the overflow landed); with the fix,
row 5 should stay entirely in its original color. Round-tripped the
encoded bytes to confirm byte-perfect delivery.

**Confirmed on real hardware/Fuse.** A follow-up investigation into an
apparent lingering symptom (several printed lines showing a missing
first character) turned out to be a coordinate collision in the test
program itself, not a ROM defect — a `CPLOT` demo's coordinates
happened to land on the exact same character cell as already-printed
text, and correctly overwrote it (that's what filling all 4 quadrants
of a cell is supposed to do). Every actual fix from this round —
`BRIGHT`, the `GFX_CHAR_SETUP` clip, the `GFX_SET_ATTR`/`GFX_SET_ATTR_
EXT` overflow fix — is genuinely correct and confirmed.

### LINE, BLOCK, and CIRCLE gain 64-Column mode support; FILL still pending (new this round)

**REMOVED 2026-08-20** — see the note atop the "64-Column mode:
PLOT/POINT support" section above; this section is history, not
current behavior.

Picked back up the deferred-gaps list, continuing past Round 1 to the
medium-sized item: `PLOT`/`POINT` already worked in mode 2 (64-Column)
from the earlier round; `LINE`, `BLOCK`, and `CIRCLE` still didn't.

**`LINE` and `BLOCK` each got a full parallel kernel routine** (`GFX_
LINE64`, `GFX_BLOCK64`) — same reasoning already established
throughout this project for the 64-Column work: widening a proven,
hardware-confirmed routine's own data layout to fit a wider case is
the worse trade compared to a small amount of duplication. Both
widen only what genuinely needs it (`X0`/`X1`/`DX` for `LINE`; `XMIN`/
`XMAX`/`CUR_X` for `BLOCK` — all to 2 bytes, for the 0-511 range) and
leave Y untouched (its range is the same regardless of mode). Neither
carries an attribute parameter — mode 2 has no per-pixel colour.
`BASIC_STMT_LINE`/`BASIC_STMT_BLOCK` now populate both the byte-sized
and wide sysvar sets while parsing, then dispatch once at the end
(same shape `BASIC_STMT_PLOT` already established) — chosen over
branching mid-parse, which would have meant duplicating the parsing
logic itself, not just the arithmetic.

**`CIRCLE` needed no new parallel routine at all** — a different shape
of problem than `LINE`/`BLOCK`. Its own midpoint algorithm (`GFX_
CIRCLE_X`/`Y`/`D`) is purely radius-relative and never touches an
absolute screen coordinate until the very last step, where every
plotted point (regardless of which of up to 8 symmetric reflections
it came from) funnels through one shared helper, `GFX_CIRCLE_PLOT_
OFFSET`. Added a single mode branch there instead: modes 0/1 run
completely unchanged; mode 2 adds a new, separately verified `GFX_
CIRCLE64_XC` (the only new state CIRCLE needed) instead of `GFX_
CIRCLE_XC`, and calls a new `GFX_PLOT_CLIPPED64` instead of `GFX_PLOT_
CLIPPED`. This left the actual midpoint algorithm — the complex,
already-proven part — completely untouched, at the cost of touching
one small, focused helper routine instead.

**`GFX_PLOT_CLIPPED64`'s bounds check stays a single instruction**,
the same way the original's does: for a signed 16-bit x, checking the
high byte as an *unsigned* value against 2 correctly rejects both
negative x (whose high byte reads as 128-255 unsigned) and x>511 in
one comparison — verified in Python against the full signed 16-bit
range before writing it, mirroring the original routine's own `H==0`
trick for its narrower 0-255 case.

**A real bug surfaced during verification — caught in my own draft
before it shipped.** `BASIC_STMT_BLOCK`'s wide corner-normalization
logic first tried to recover x1's original value by subtracting and
then re-adding it (`SBC HL,DE` / `ADD HL,DE`) after using the
subtraction's carry flag to decide min vs. max — except `ADD HL,DE`
sets its own carry flag, silently clobbering the exact flag the code
still needed to test. Fixed by keeping x1 in `BC` throughout instead
of trying to reconstruct it, testing the carry immediately after the
`SBC`, and re-verified with a standalone simulation of the corrected
snippet — 8 cases, all correct.

**A second, unrelated real bug — this one in the verification tooling
itself, not the ROM — was found and fixed along the way.**
`GFX_LINE64`'s first simulation run hung indefinitely rather than
terminating around 512 points for a corner-to-corner diagonal.
Traced to `tools/z80sim/sim.py`: its 16-bit `SBC HL,rr` handler
computed the sign flag from whichever single byte of the 16-bit
result happened to be nonzero (via a stray `or` fallback), rather
than from bit 15 of the full result — so a genuinely positive value
like 129 (`$0081`) had its sign flag read from the low byte `$81`'s
own bit 7, incorrectly reporting it as negative. Confirmed with a
minimal isolated test (`SBC HL,DE` with `HL=640, DE=511`: the 16-bit
result, 129, was correct; the sign flag was not) before touching the
tool's code. Fixed and reverified against a spread of values,
including the case that originally exposed it.

**All three verified via real z80sim instruction simulation, not just
static review** (all run against the *actual* shipped code, after the
simulator fix above): `GFX_LINE64` against 48 lines (every corner-to-
corner extreme plus 40 random lines), byte-for-byte identical to a
Python reference; `GFX_BLOCK64` against 6 rectangles including full-
width and single-pixel degenerate cases, exact pixel-set matches;
`GFX_CIRCLE_PLOT_OFFSET`'s new mode-2 branch and `GFX_PLOT_CLIPPED64`
against 6 cases spanning in-range placement and off-screen clipping
in every direction, plus 4 more confirming the mode-0/1 path is
completely unaffected.

New sysvars: `GFX_LINE64_*` (16 bytes), `GFX_BLOCK64_*` (10 bytes),
`GFX_CIRCLE64_XC` (2 bytes) — 28 bytes total, `PROG_AREA_START` moved
`$84B5`->`$84D1`, 193 sysvars, zero collisions confirmed at every
step along the way. `check_asm.py` clean across every module.

`CPLOT` still does not support mode 2 — coarse quadrant-fill graphics
don't obviously generalize to a mode with no per-pixel attribute the
way pixel-level drawing did, and wasn't attempted this round.

**Update (2026-08-19): fixed.** The bitmap-plotting half of `GFX_CPLOT`
was always mode-independent (it writes a 4x4 block of raw pixels the
same way regardless of `GFX_MODE`) — the only real gap was the
`.attr` step unconditionally writing a per-cell or per-scanline
attribute even in mode 2, which has none. `GFX_CPLOT` now checks for
mode 2 first and returns right after the bitmap write, skipping
attribute logic entirely — same "no attribute in mode 2" convention
`GFX_PLOT_CLIPPED64` already established for PLOT/LINE/BLOCK/CIRCLE.
`check_asm.py` clean. **Deliberately NOT addressed**: whether `CPLOT`'s
own coarse coordinate range (`cx` 0-63, `cy` 0-47, fixed to the
256x192 canvas) should widen to address mode 2's 512-pixel-wide
canvas too — that's a real open design question (does block graphics
want a wider grid in high-res mode, or does the coarse feature stay
canvas-agnostic?), not an implementation detail, and needs a decision
before code, not a guess. NOT yet hardware/emulator-confirmed — this
was written and static-checked in a sandbox with no sjasmplus/Fuse
access.

**Confirmed on real hardware/Fuse.** A `SYNTAX ERROR` on `BLOCK`
specifically (`LINE` worked) traced to a real bug: `BASIC_STMT_BLOCK`'s
mode-2 corner-normalization reused `HL` as scratch for a 16-bit
comparison, not realizing `HL` is also the parser's own current-
source-position cursor throughout that routine — clobbering it
silently corrupted parsing for everything after that point. Fixed
with `push`/`pop hl` around the block; re-verified via a standalone
simulation that both the min/max math and `HL` preservation hold
together. After the fix, all three shapes render correctly and both
self-check assertions pass.

### FILL (new this round)

Picked back up the deferred-gaps list at its last remaining graphics
item. Genuinely different kind of problem than everything before it:
`BLOCK`/`CIRCLE`/`LINE` all generate their pixel set from a closed-
form formula, but a flood fill has to *traverse* the screen's actual
current pixel state outward from a seed point — no formula tells you
in advance which pixels that touches.

**Algorithm chosen and sized from real measurements, not a guess.**
A naive per-pixel 4-connected flood fill (check "already visited" only
when a pixel is popped) was measured in Python needing *more* stack
pushes than there are pixels in the fill for a large open area —
19,801 pixels filled needed over 49,162 pushes before hitting the
limit, purely from the same pixel being queued multiple times before
it's ever processed. Switching to "mark claimed the moment a pixel is
pushed, not when it's popped" fixed this dramatically: peak stack
usage dropped to roughly 25-30% of the final pixel count across every
size tested (768 for a radius-30 circle's interior, 2069 for radius-
50, 3996 for radius-70). Went one step further and confirmed the
bitmap itself can serve as the "already claimed" tracker — a neighbor
is written (flipped from target to new value) the instant it's found
to still match, immediately before being pushed — so no separate
visited-set is needed at all, and `GFX_READ_PIXEL`/`GFX_WRITE_PIXEL`
can be reused wholesale for the actual pixel work. Verified this
refinement produces byte-identical results to the separate-visited-
set version across 15 random circle fills before writing any Z80.

**`GFX_FILL_STACK` is sized directly from those measurements**: 2048
entries (4096 bytes), comfortably covering circles up to roughly
radius 50 on this screen and similarly-sized enclosed regions. A
genuinely huge enclosed area can still exhaust it — the fill then
simply stops expanding further from that point (pixels already queued
still get processed and colored correctly) rather than crashing or
corrupting memory. This costs real RAM (`PROG_AREA_START` moves by
4103 bytes, roughly 13% of the ~30KB that was free) — a real,
deliberate trade-off, not an accident.

**Reuses `GFX_READ_PIXEL`/`GFX_WRITE_PIXEL` entirely** for the actual
pixel work, rather than a separate byte-level bitmap routine — every
touched pixel's covering attribute cell gets colored the normal way
for free, no separate attribute logic needed in `GFX_FILL` at all.
The `OVER` flag passed to every `GFX_WRITE_PIXEL` call is chosen once,
from the seed pixel's own value: filling FROM an unset pixel means OR
(target 0 -> new 1, the everyday "paint bucket into an empty area"
case); filling FROM an already-set pixel means XOR (target 1 -> new
0 — XORing 1 against 1 correctly flips it back off). Both directions
are genuinely symmetric and well-defined this way, reusing `GFX_
WRITE_PIXEL`'s existing OR/XOR contract exactly as designed rather
than needing a new "write absolute value" primitive.

**A real bug caught in `GFX_FILL_PUSH`'s own first draft before it
shipped**: it tried the same "SBC then ADD to recover the compared
value" pattern already caught once this session in `BASIC_STMT_
BLOCK`'s own corner-normalization — `ADD HL,DE` sets its own carry,
silently clobbering the flag the code still needed to test. Fixed by
re-reading `GFX_FILL_SP` fresh from memory after the carry check
instead of trying to reconstruct it.

**Verified against the actual shipped code via real z80sim instruction
simulation, not just the Python design** — and this surfaced a second
real bug, this time in the test setup rather than `GFX_FILL` itself.
The first simulation run of an enclosed-rectangle fill came back with
19 wrong pixels, all in one specific row. Tracing it found the test's
own placeholder addresses for `GFX_FILL_STACK` had been sized to only
128 entries (a shortcut for keeping the simulation's memory map small)
— nowhere near the real 2048-entry design — so the fill was silently
hitting *that* undersized limit partway through and never actually
exercising the real algorithm's own scale. Widening the test's stack
region to the real size made it *worse* (159 wrong pixels) at first,
which turned out to be a second, compounding test-harness mistake:
the wider placeholder region now overlapped the test's own placeholder
`BIT_MASK_TABLE`/`ROW_BASE_TABLE` addresses, corrupting them as the
fill's own stack grew. Fixed by giving every test region a distinct,
non-overlapping placeholder address and confirming that arithmetically
before rerunning. With genuinely non-overlapping test memory, both the
circle and the rectangle fills came back with zero mismatches against
the Python reference.

New sysvars: `GFX_FILL_STACK` (4096 bytes) + `GFX_FILL_SP`/`TARGET`/
`OVER`/`ATTR`/`X`/`Y` (7 bytes) — 4103 bytes total, `PROG_AREA_START`
moved `$84D1`->`$94D8`, 200 sysvars, zero collisions confirmed.
`check_asm.py` clean across every module.

**NOT YET ASSEMBLED OR HARDWARE-TESTED.**

### PLOT / LINE / POINT (confirmed on real hardware — from the previous round)

### Bug found and fixed while building a graphics test program: colon-joined statements with a space after the colon

Unrelated to PLOT/LINE/BLOCK/CIRCLE/POINT themselves, but found while
building a preload test program for them. `BASIC_EXEC_MULTI_STATEMENT`
and `BASIC_CHECK_STATEMENT_CONTENT`'s colon-splitter (`BASIC_CHECK_
MULTI_STATEMENT`) both advance to the next segment with a bare `inc hl`
right past the `:` — no leading-space skip. `"CLS: BORDER 0"` (space
after the colon, the natural way anyone would type it) left the second
segment starting on that space; nothing downstream tolerates a leading
space before a keyword, so it fell through to SYNTAX ERROR. `"CLS:
BORDER 0"` with no space would have worked — which is almost certainly
why this had never surfaced before: every earlier colon-joined test
happened not to use the spaced style. A 26-statement preload test
program with 10 naturally-spaced colon-joined lines hit it on every
single one (`10 ERRORS FOUND`, matching exactly the 10 colon-containing
lines — confirmed by literally counting which of the 26 source lines
contained a colon before touching any code, rather than guessing from
the symptom). Fixed with one `call BASIC_SKIP_SPACES` added right after
the `inc hl` in both splitters (identical fix, two places). Traced from
symptom to root cause entirely via static reading and a Python trace of
the corrected split logic against the actual failing lines — no z80sim
needed this time, the pattern (every colon line fails, nothing else
does, exact count match) was specific enough to pin down directly.
**Not yet re-confirmed on real hardware** — the original PLOT/LINE/
POINT/BLOCK/CIRCLE code this was found alongside is unaffected by this
fix (it's pure colon-splitter behavior, upstream of any single
statement's own grammar).


Grew out of a design conversation covering what graphics commands the
TS2068 (Standard/Extended Color/Hi-Res/Dual Screen video modes) and the
QL (absolute-coordinate pixel addressing, turtle-style relative variants,
`SCALE`, `WINDOW`) each offer, plus hardware neither BASIC ever exposed
cleanly (dual-screen flip, vblank sync, block-graphics coarse plot,
rectangle blit, sprite-style save/restore). That conversation settled on
a tiered build order — shared low-level primitives first (`GFX_WRITE_
PIXEL`, and a still-unbuilt `GFX_RECT_SAVE`/`RESTORE` for `COPY`/sprite
work later), then the statements/functions that sit directly on top.
This round built the foundation tier plus `PLOT`/`LINE`/`POINT`, the
first three commands in `docs/basic_language_reference.md`'s new
"Graphics" section.

**Verification, before any Z80 was written**:
- **Pixel addressing** (`GFX_PIXEL_ADDR_SETUP`'s row/col/scanline/mask
  math) was cross-checked two independent ways: this project's own
  already-verified `ROW_BASE_TABLE` plus a row/col/scanline
  decomposition, against the canonical, independently-known ZX
  Spectrum-family screen address formula
  (`$4000 | (y&$C0)<<5 | (y&$07)<<8 | (y&$38)<<2 | x>>3`). All 49,152
  (x,y) pixel positions in the 256x192 space checked, zero mismatches
  between the two methods, and every resulting bitmap/attribute address
  confirmed within the real 6144/768-byte ranges.
- **`GFX_LINE`'s Bresenham algorithm**: the exact planned Z80-level
  arithmetic — byte-sized `dx`/`dy` magnitudes (not the usual
  already-negated `dy`; this implementation negates it itself via
  `MATH_NEGATE16` where the algorithm needs that), a signed 16-bit error
  term with truncating add (same truncation behaviour `MATH_ADD16` already
  has), and `MATH_COMPARE16`-style three-way branch tests (`0`/`1`/`$FF`)
  in place of a hand-rolled overflow-correcting compare — was simulated
  in Python against a textbook reference Bresenham implementation across
  512 lines (every degenerate case: a single point, pure horizontal,
  pure vertical, both screen corners; plus 500 random endpoint pairs
  across the full 256x192 space). Zero mismatches.

**Design decisions worth recording**:
- `PLOT`/`LINE` colour the covering 8x8 attribute cell(s) using the
  current `INK`/`PAPER`/`FLASH`/`INVERSE` state, via the same
  `BASIC_COMPUTE_PRINT_ATTR` `PRINT` already uses — real hardware
  attribute clash, not a choice this ROM makes, and honest reuse of an
  already-tested computation rather than a second implementation of the
  same bit-packing logic.
- `CURRENT_OVER` (added earlier for text, but never actually consulted
  by any print routine — see its own `sysvars.inc` comment) gets its
  first real consumer here: `GFX_WRITE_PIXEL`'s `D` parameter selects
  OR-plot (`OVER 0`) vs. XOR-toggle (`OVER 1`), matching real Sinclair
  BASIC's own `OVER` semantics for `PLOT`/`DRAW`/`CIRCLE`, not just
  `PRINT`.
- `LINE` takes **absolute** coordinates for both endpoints, QL
  SuperBASIC style, not classic Sinclair BASIC's relative-only `DRAW` —
  a deliberate deviation from this project's usual "mimic SuperBASIC
  where hardware matches, mimic the original ROM otherwise" rule (see
  `docs/basic_language_reference.md`'s Graphics section for the full
  reasoning: this one's a genuine improvement, not a hardware
  constraint either way).
- `GFX_WRITE_PIXEL`'s attribute write reuses the already-tested
  `GFX_SET_ATTR` rather than re-deriving its row×32+col addressing
  formula a third time — same "duplicated addressing logic is this
  project's most common bug source" reasoning that already motivated
  `GFX_CHAR_SETUP`/`GFX_ATTR_SWAP`.
- `GFX_LINE` takes all six of its inputs from memory
  (`GFX_LINE_X0`/`Y0`/`X1`/`Y1`/`ATTR`/`OVER`, `sysvars.inc`), not
  registers — more live state than survives a loop that itself calls
  `GFX_WRITE_PIXEL` and `MATH_COMPARE16` (both destroy registers freely)
  every iteration. `BASIC_STMT_LINE` fills these in directly rather than
  the usual register-parameter convention.
- `POINT(x,y)` is this language's first built-in function that isn't
  itself a `kernel/math` routine — `BASIC_EVAL_PRIMARY`'s `.call_point`
  case is a small register-convention adapter (`GFX_READ_PIXEL`'s own
  `B`=x/`C`=y contract, vs. every `MATH_*` function's shared HL-in/DE-in
  convention), not a sign the dispatch design is wrong.
- **Confirmed on real hardware/Fuse**: `PLOT 128,96` + `LINE 0,0 TO
  255,191` + `PRINT POINT(128,96)` rendered a clean single-pixel-wide
  monotonic diagonal (correct Bresenham stepping, no gaps or
  stairstepping) and `POINT` correctly reported the pixel as set —
  confirms `GFX_WRITE_PIXEL` and `GFX_READ_PIXEL` agree on actual
  bitmap state, not just that each looks right in isolation.



- `GFX_CHAR_TO_FONT_OFFSET`'s offset math originally computed `N×10`
  instead of the needed `N×8` — an inline comment claimed `x2,x4,x5,x8`
  but the actual instruction sequence didn't match its own comment.
  Caught by re-deriving the arithmetic with a script rather than trusting
  the comment, and fixed to three plain doublings.
- `GFX_PRINT_STRING` didn't preserve `BC` across its call to
  `GFX_PUTCHAR`, which is documented to destroy `BC` entirely — meaning
  the row would go stale after the first character printed, corrupting
  every character after it on the line. Caught by checking
  `GFX_PUTCHAR`'s own contract against what the loop assumed, not by
  running it.
- **This one shipped and was only caught through real testing**: when
  `PUNCT_CHAR_TABLE` was added to `GFX_CHAR_TO_FONT_OFFSET`, its scan
  loop used `B` as a counter (`ld b, PUNCT_CHAR_COUNT` / `djnz`) —
  but `GFX_PUTCHAR` calls this routine *before* reading `B` (its row
  parameter), with no protection around the call. Letters and digits
  never reach the punctuation scan, so they were unaffected; any
  punctuation character got drawn on a corrupted row instead of the
  real one, while its column stayed correct (tracked separately by
  `GFX_PRINT_STRING`). This is the exact same category of bug
  `GFX_PRINT_STRING` itself had already been fixed for one level up —
  the fix just wasn't applied consistently at every call site that
  needed it. Found via a screenshot showing `=` rendered on a
  completely different row than the rest of the line it was typed on,
  after a dedicated diagnostic (`rom/test_editor_debug.asm`)
  independently confirmed the underlying typed-text buffer was
  correct — narrowing the bug to rendering specifically before the
  code was re-examined. Fixed by having `GFX_PUTCHAR` push/pop `BC`
  around the call, mirroring `GFX_PRINT_STRING`'s own existing
  pattern.
- **`basic/`'s new status line inherited the cursor's blink** — its
  row-inversion loop called `GFX_INVERT_ATTR`, which is deliberately
  built to force the hardware `FLASH` bit for the blinking cursor
  indicator. Reusing it for the status bar made the whole bar blink
  too, reported as the status text "flashing." A single screenshot
  catching it mid-cycle also happened to show it looking uninverted —
  same root cause explaining both symptoms. Fixed by splitting the
  shared address/swap logic out into `GFX_ATTR_SWAP` (mirroring how
  `GFX_CHAR_SETUP` was factored out for `GFX_PUTCHAR`/
  `GFX_PUTCHAR_BOLD`) and adding `GFX_INVERT_ATTR_STATIC`, a genuinely
  static inverted highlight with no `FLASH` forcing, for anything that
  should stand out visually without blinking like the cursor.

### Testing

`rom/test_graphics.asm` is **visual**, like `rom/test_io.asm` is
interactive — there's no formula to check glyph shapes against, only
your eyes. It prints the entire font table across a few rows so every
glyph can be checked in one screenshot, then sets the border cyan as a
"finished rendering" signal (not a verdict). If the address math were
wrong you'd likely see garbled/overlapping text even before considering
individual glyph shapes, so this also doubles as the first real test of
`ROW_BASE_TABLE` together with `GFX_CLS`.

## kernel/sound — speaker output (BEEP)

`SOUND_BEEP` — the only routine here — produces a square-wave tone by
toggling port `$FE` bit 4 (the speaker) at a fixed rate for a fixed
number of cycles. Hardware facts confirmed directly from the ROM
disassembly's `BEEPER`/`PARP` routine: sound comes purely from
alternating that bit; border colour (bits 0-2) must survive untouched;
MIC output (bit 3) is forced off for the duration, same as real
`BEEPER` — all via the existing `PORT_FE_SHADOW` read-modify-write
discipline `kernel/graphics`'s `GFX_SET_BORDER` and `kernel/storage`'s
tape pulse routine already established.

**Deliberately not a port of the real timing loop.** Real `BEEPER`
computes an exact T-state period from a musical note number, via a
self-modifying `IX`-relative NOP sled and the floating-point
calculator's own note-frequency table. Replicating that needs the full
note table AND a way to confirm the resulting pitch actually sounds
right — and this project's test environment has no audio output to
verify against. `SOUND_BEEP` instead exposes the mechanism directly:
`BEEP <duration>,<pitch>` where duration is a plain cycle count and
pitch is the per-half-cycle busy-wait length (bigger = slower =
lower). Honestly scoped as a narrower reinterpretation rather than
presented as the authentic command — see `basic/basic.asm`'s
`BASIC_STMT_BEEP` and this module's own file header for the full
reasoning.

**Implementation note**: `IX` holds the pitch value for the whole
routine (reloaded into `BC` fresh before each half-cycle's countdown,
since `BC` itself gets decremented to zero every time) — `DE` is free
throughout to serve as the untouched outer cycle counter. Two toggles
always complete one full waveform cycle, so the speaker bit is
guaranteed back at its pre-`BEEP` value when the loop ends regardless
of the cycle count; only MIC needs an explicit restore.

**Verified**: `rom/test_beep.asm`/`rom/test_beep2.asm` (throwaway
preload harnesses, `BASIC_RUN` + border-color checkpoint method) confirm
the checker accepts `BEEP <expr>,<expr>`, a zero-duration `BEEP 0,100`
correctly no-ops, and a real workload (`BEEP 300,800`, ~480,000 busy-
wait iterations) returns cleanly without hanging and without disturbing
subsequent `PRINT`/`BORDER` execution. **Not verified**: that any
specific `pitch` value produces a specific audible frequency — no audio
output exists in this environment to check that against.

## kernel/math — 16-bit signed multiply and divide

Z80 has no hardware multiply or divide instructions. This module owns
general-purpose 16-bit integer arithmetic — built specifically to
support `basic/`'s expression evaluator, but deliberately kept generic
and free of any BASIC-specific assumptions, matching this project's
stated principle that kernel modules should be reusable by other
future assembly-language software.

- **`MATH_UMUL16`** — unsigned 16×16→16 multiply via shift-and-add.
  **`MATH_UDIV16`** — unsigned 16-bit divide via 16-iteration
  shift-and-subtract (restoring division), generalizing `basic/`'s own
  `DIV10` (which stays where it is, unchanged — a narrower, fixed-
  divisor routine serving decimal-string conversion, not something
  this module replaces) to an arbitrary runtime divisor. `DIV10` could
  use `B`/`DJNZ` for its loop counter since 10 never needed a
  register; here `BC` is needed for the divisor throughout all 16
  iterations, so the counter lives in memory (`DIV_COUNTER`) instead.
- **`MATH_MULTIPLY16`** / **`MATH_DIVIDE16`** — signed wrappers:
  determine the result's sign (negative iff exactly one operand is
  negative — the XOR of their sign bits), take absolute values,
  operate unsigned, apply the sign to the result. `MATH_DIVIDE16`
  truncates toward zero (`-17/5 = -3`, not `-4`), matching typical
  integer BASIC division, since it's a direct consequence of the
  sign-then-magnitude approach.
- **Verification discipline**: both algorithms were verified via a
  Python simulation mirroring the exact planned Z80 register steps —
  `MATH_UDIV16` against 16,165 dividend/divisor combinations, the
  signed multiply/divide wrappers against 32,720 signed value pairs
  each (including `-32768`, `32767`, `0`) — all with zero failures,
  *before* any Z80 assembly was written. Same discipline as this
  project's other tricky arithmetic (the screen address formula, the
  ink/paper bit-swap, `DIV10` itself). That verifies the algorithms;
  `rom/test_math.asm` (see "Testing" below) is what confirms the
  actual assembled code matches that verified design.
- **Divide by zero**: `MATH_DIVIDE16` returns `0` rather than the
  nonsense result the raw algorithm would otherwise produce (a
  divisor of `0` means "remainder ≥ divisor" is trivially true every
  iteration, giving a quotient of all 1-bits, i.e. `-1`) — a
  deliberate, safe default, not an oversight. `basic/` gained real
  error reporting (`BASIC_REPORT_ERROR`) after this was written, but
  that doesn't change the answer here: `kernel/math` is a generic,
  reusable module with no knowledge of `basic/` at all (the reverse
  dependency, `basic/` calling down into `kernel/math`, is the only
  direction this project's layering allows), so it can't call up into
  `basic/`'s error display even if it wanted to. A caller that cares
  about divide-by-zero specifically (like a future `IF`/expression
  check) would need to test the divisor itself before calling this.
- **Overflow**: both routines simply truncate to 16 bits, matching how
  this project's other integer arithmetic already behaves
  (`BASIC_NUM_TO_STRING`, `DIV10`) — no overflow flag or signal.
- **`MATH_COMPARE16`** — signed 16-bit comparison (`A` = `0`/`1`/`$FF`
  for equal/greater/less), built to support `basic/`'s new IF/ELSEIF
  relational operators. Z80 has no signed-compare instruction, only
  `SBC HL,DE` (unsigned-magnitude subtract) plus a P/V flag that
  doubles as a signed-overflow indicator — the sign flag after the
  subtract tells the truth UNLESS overflow occurred, in which case
  it's backwards and must be inverted. Verified the same way as
  multiply/divide: a Python simulation of the exact flag logic against
  boundary values (`0`, `±1`, `±5`, `±32767`, `±32768`) plus 200,000
  random signed pairs, zero failures, before any Z80 was written.

- **`MATH_COMPARE16`** — signed 16-bit comparison (`A` = `0`/`1`/`$FF`
  for equal/greater/less), built to support `basic/`'s new IF/ELSEIF
  relational operators. Z80 has no signed-compare instruction, only
  `SBC HL,DE` (unsigned-magnitude subtract) plus a P/V flag that
  doubles as a signed-overflow indicator — the sign flag after the
  subtract tells the truth UNLESS overflow occurred, in which case
  it's backwards and must be inverted. Verified the same way as
  multiply/divide: a Python simulation of the exact flag logic against
  boundary values (`0`, `±1`, `±5`, `±32767`, `±32768`) plus 200,000
  random signed pairs, zero failures, before any Z80 was written.
- **`MATH_ADD16`** / **`MATH_SUB16`** — thin, documented wrappers
  around plain `ADD HL,DE`/`SBC HL,DE`, formalizing arithmetic
  `basic/`'s evaluator was already doing inline — no behavior change,
  just a single call site instead of the same instructions retyped
  wherever they came up.
- **`MATH_NEGATE16`** / **`MATH_ABS16`** / **`MATH_SGN16`** — two's-
  complement negate, absolute value, and sign (returns `-1`/`0`/`1` in
  `HL`). All five of this batch verified via a Python simulation
  (50,011 values — every edge case plus 50,000 random signed 16-bit
  values) before any Z80 was written, then confirmed against the
  actual assembled instructions via `tools/z80sim` (560 cases, zero
  failures) — same two-stage discipline as multiply/divide/compare.
  **Edge case**: `MATH_NEGATE16(-32768)` and `MATH_ABS16(-32768)` both
  return `-32768` unchanged, not `32768` — the positive equivalent has
  no representation in signed 16-bit two's complement. Confirmed via
  the same verification, not just reasoned about; matches ordinary
  two's-complement behavior everywhere, not a bug specific to this
  implementation. `MATH_MULTIPLY16`/`MATH_DIVIDE16`'s own internal
  negation steps were deliberately left as their original inline code,
  not changed to call `MATH_NEGATE16` — those routines are already
  verified and working; this batch adds a reusable entry point for
  future callers without touching them.- **`MATH_MOD16`** — signed remainder, matching `MATH_DIVIDE16`'s own
  truncating-toward-zero convention: the remainder takes the
  *dividend's* sign (or 0), not the divisor's — `-17 MOD 5 = -2`, not
  `3` (a flooring-division language's `%` would give `3`; this matches
  C's `%`, consistent with `-17/5 = -3`: `-3*5 + (-2) = -17`). Cheap to
  add: `MATH_UDIV16` already computes the unsigned remainder internally
  (in `DE`) as a side effect of computing the quotient, so this is a
  sign-then-magnitude wrapper reading `DE` instead of `HL` out of that
  same division pass — no second division. Verified via Python (6,048
  cases: edge values plus 2,000 random dividends × 3 random divisors
  each, checking `a = q*b + r`, `|r| < |b|`, and `r`'s sign matches the
  dividend's) before any Z80, then via `tools/z80sim` against the real
  instructions (17 cases including the `-32768` boundary), zero
  failures either stage.
- **`MATH_SQRT16`** — signed 16-bit integer square root, truncating
  (largest `R` such that `R*R <= n`). Negative input treated as 0, no
  error mechanism at this layer (matches `MATH_DIVIDE16`'s divide-by-
  zero convention, and keeps this routine consistent with every OTHER
  kernel/math routine being signed — see this routine's own header for
  a real near-miss on that point below). Classic "digit by digit"
  binary integer square root, same iterative shift/compare/subtract
  shape as `MATH_UDIV16` above, extracting 2 input bits per iteration
  over a FIXED 8-iteration loop (Python-verified equivalent to the
  textbook version's own variable-length leading loop, and considerably
  simpler as a Z80 loop). New scratch sysvars `SQRT_OP`/`SQRT_RES`
  (2 bytes each) / `SQRT_COUNTER` (1 byte) — same "needs a copy in `HL`
  for the compare, but `HL` is also busy that same iteration" reasoning
  as `MATH_UDIV16`'s own `DIV_DIVIDEND`/`DIV_QUOT`/`DIV_COUNTER`.
  **A real near-miss caught by `tools/z80sim`, not by the Python
  verification**: the core shift/compare/subtract algorithm was
  Python-verified against all 65,536 possible *unsigned* 16-bit
  magnitudes — correctly, zero mismatches — but the routine's own
  negative-input check (needed because every kernel/math routine is
  signed, and BASIC has no unsigned type) was then written treating
  bit 15 as a sign bit, silently zeroing every input from 32768–65535
  even though the isolated algorithm had just been verified correct
  for exactly that range. The Python check and the actual Z80 design
  were quietly testing two different things. `tools/z80sim`'s own
  broad random sample immediately flagged 243 failures, all with bit
  15 set, which is what caught the mismatch. Fixed by re-verifying the
  ACTUAL combined behavior (all 65,536 *signed* 16-bit inputs: negative
  → 0, non-negative → its own root) rather than trusting the core
  algorithm's isolated verification to also cover the wrapper around
  it — zero mismatches once checked correctly, then reconfirmed via
  `tools/z80sim` against the real instructions (1,021 cases). Worth
  remembering: verifying a sub-algorithm in isolation doesn't verify
  the routine that wraps it — the combination needs its own check.
- **`MATH_RND16`** — pseudo-random integer in `[0, x-1]` for a positive
  `x` (`x<=0` returns 0, same safe-default convention as everything
  else in this file). Generator: a 16-bit maximal-length Fibonacci-form
  LFSR (feedback = XOR of bit positions 1, 2, 4, 13 of the current
  state; new state = shifted right 1 with that bit inserted at bit 15).
  **The taps used here were found by direct search, not trusted from
  memory** — an initial attempt using a commonly-cited tap constant,
  applied as a single-mask Galois-style feedback, turned out to have
  only a 73-state cycle; a second attempt using several textbook-cited
  Fibonacci tap sets hit the degenerate all-zero state entirely,
  because none of them included tap position 1 (required for the
  transition to be invertible — confirmed empirically, not just
  reasoned about, after the first few candidates all failed the same
  way). A systematic search over tap combinations that DO include
  position 1 found `{1,2,4,13}` on essentially the first useful
  attempt, verified by direct simulation to visit all 65,535 nonzero
  16-bit states exactly once before returning to its start. The exact
  register-level bit-extraction sequence (shift-and-mask each tap bit
  individually, XOR-fold them, then a real 16-bit logical shift with a
  conditional bit-15 set) was then separately checked against the
  reference recurrence for all 65,536 possible states — zero
  mismatches — before being trusted as a faithful translation.
  Persistent state in the new `RND_STATE` sysvar (2 bytes) — never 0
  (a maximal-length LFSR treats 0 as a fixed point that never
  advances); `MEM_INIT`'s cold-start zeroing doubles as "not yet
  seeded," so the first `RND(x)` call seeds it from the Z80 `R`
  register (the classic technique — increments on every instruction
  fetch, unpredictable from a BASIC program's perspective though not
  cryptographically random) OR'd with 1 to guarantee it isn't 0 itself.
  This seeding step is hardware-timing-dependent and can't be
  meaningfully checked by `tools/z80sim` (no real timing model — same
  category of gap as `kernel/storage`'s tape-signal primitives); only
  the deterministic LFSR step and the range-scaling below it were
  verified there (555 cases: the LFSR chained across 200 consecutive
  calls matches the reference recurrence exactly, results stay in
  range across a spread of `x` values and seeds, `x<=0` always returns
  0 without touching `RND_STATE`, and a 2,000-draw sample from
  `RND(10)` visits all 10 possible values — not a rigorous randomness
  test, just confirms no obvious bias). Range-scaling: the raw state,
  sign bit masked off (0-32767 — that bit is ordinary LFSR noise, not
  meaningful), is fed to this file's own `MATH_MOD16` as a guaranteed
  non-negative dividend against `x`, so `MOD16`'s dividend-sign
  handling never triggers — same reuse-not-reinvent shape as `DIV(x,y)`
  wrapping `MATH_DIVIDE16` above.

### Testing

`rom/test_math.asm` follows the same border-color pass/fail pattern as
every other kernel-module test — green on all tests passing, red on
the first failure. Covers positive×positive, negative×positive,
negative×negative, zero, a boundary case (`32767 * 1`), truncating
division (`-17/5 = -3`, confirming truncation toward zero rather than
floor), divide-by-zero, equal/greater/less, a negative-vs-positive
case, the widest possible signed boundary (`-32768` vs `32767`, where
the signed-overflow flag genuinely matters), a basic add/subtract case
each, `NEGATE16`/`ABS16`'s own `-32768` boundary, `SGN16`'s three
cases (positive/negative/zero), a `MOD16` case each for basic/negative-
dividend/negative-divisor (sign follows the dividend only)/divide-by-
zero, a `MATH_SQRT16` perfect square, non-perfect square (confirming
truncation), zero, negative input (confirming the 0 default), and the
`32767` boundary, and (added alongside `MATH_RND16`) a range check
(5 consecutive `RND(10)` calls, each checked `0 <= r < 10` — doesn't
pin an exact value, since the whole point is that it varies; that's
what `tools/z80sim`'s own broader verification is for), `RND(0)`,
`RND(-5)`, and `RND(1)` (the degenerate single-value range). `DIV(x,y)`
and `INT(x)` get no new kernel-level test of their own — `DIV` is a
thin wrapper directly over the already-tested `MATH_DIVIDE16`, and
`INT` calls no kernel routine at all (a true no-op in this pure-
integer BASIC). A representative set, not exhaustive — the underlying
algorithms were already verified against tens of thousands of cases in
Python and against the real instructions via `tools/z80sim`; this
exists to catch any transcription error between that verified design
and the actual assembled code.

## kernel/bank + the EXROM calculator engine

Not previously documented here — this section covers both `kernel/
bank`'s paging trampoline and `rom/exrom_calc.asm`'s RST $28 float
calculator, which is EXROM-resident and depends on it.

### kernel/bank — EXROM paging trampoline

The Home ROM is hard-capped at 16K (`$0000-$3FFF`, always paged in). A
second 8K image (EXROM, built by `rom/exrom_build.asm` into
`exrom.bin`) is paged into chunk 6 (`$C000-$DFFF`) on demand via:

- **`BANK_PAGE_EXROM_IN`** — pages chunk 6 to EXROM (port `$F4`
  chunk-select via `PORT_BANK_HOME`, port `$FF`/`PORT_SCLD` bit 7 to
  pick EXROM over Dock). Every other chunk stays Home.
- **`BANK_PAGE_EXROM_OUT`** — restores chunk 6 to Home.

Chunk 6 was chosen because it's general RAM (not video RAM),
architecturally distant from live sysvar/stack state, and
independently corroborated by the stock TS2068 ROM's own `EXTINIT`
routine marking that chunk expendable too — see `docs/memory_map.md`
for the full hardware audit this was based on (Timex Sinclair 2068 ROM
Disassembly, David Anderson, 2023). Chunk 7 (`$E000-$FFFF`, the
machine stack) must never be paged. Interrupts are disabled only
across the two port writes that actually change paging state, never
across the caller's subsequent use of the paged window — holding `DI`
for the whole window would reintroduce the keyboard-lag problem this
project already fixed once for anything nontrivial running from EXROM;
safe because `KBD_ISR_TICK`'s own sysvars all live in chunk 4, which
stays Home-mapped the entire time chunk 6 is paged out.

**Hardware-confirmed** (`rom/test_exrom_isolation.asm`, PASS/PASS) —
the first bank-switching code in this project, proven on real
hardware, not just designed.

**Reentrancy-safe as of 2026-08-22** (`BANK_EXROM_DEPTH`, `include/
sysvars.inc` — a 1-byte nesting counter): a real bug surfaced while
building `PI`/`RAD`/`DEG` — see this file's own basic/ section ("PI/
RAD/DEG and a real EXROM-paging reentrancy bug") for the full incident
writeup. Short version: these two routines used to be bare port
writes, correct only for the single, non-nested call every original
caller made. The whole-program/live-typing checker breaks that
assumption — it pages EXROM in, runs EXROM-resident code, which calls
back into Home, which can itself page EXROM in/out again (any
"function-result float" built-in touching the calculator engine) — and
the inner page-OUT used to unmap chunk 6 out from under the outer
checker call's own still-in-flight return address. `BANK_PAGE_EXROM_
IN`/`_OUT` now only do the real port write on the 0->1 / 1->0 depth
transitions; any nested pair in between just adjusts the counter. The
single-call case (the only one ever exercised before this) is
unchanged in behavior.

**Second real confirmation (2026-08-22, same day)**: the `BASIC_
FORMAT_STORAGE_STATUS` EXROM migration (this file's own basic/
section, "ROM-size audit") hit the identical nesting pattern through a
completely different call path — `STORAGE_SAVE`/`STORAGE_LOAD`
(EXROM-resident) call it repeatedly mid-transfer via `STORAGE_
PROGRESS_HOOK` while EXROM is already paged in for their own entire
run. A real end-to-end `SAVE` in the emulator confirmed this works
correctly, which is good evidence `BANK_EXROM_DEPTH` generalizes
beyond the one call pattern it was built to fix, not just a second
coincidentally-similar case.

### EXROM image structure

`rom/exrom_build.asm` is the real build driver (`sjasmplus rom/
exrom_build.asm` → `exrom.bin`) — `DEVICE`/`ORG $C000`/`SAVEBIN` live
only there now. It `INCLUDE`s, in address-sensitive order (the first
one declares all seven fixed entry stubs, six bytes apart, before any
routine body advances `$` past them):

1. `rom/exrom_checker.asm` — the whole-program/statement grammar
   checker (`BASIC_CHECK_PROGRAM` and friends), moved here verbatim
   from `basic/basic.asm` to resolve a Home ROM size overage.
   **Hardware-confirmed** (live-typing validation showing red-while-
   typing through EXROM paging).
2. `rom/exrom_storage.asm` — `STORAGE_SAVE`/`STORAGE_LOAD`'s EXROM
   half.
3. `rom/exrom_help.asm` — `BASIC_SHOW_HELP` and its topic tables.
4. `rom/exrom_calc.asm` — the calculator engine (this section).

Since EXROM is a separate `sjasmplus` compilation unit with no linker,
calls from EXROM back into Home-resident routines (`MEM_LINE_FIRST`,
`BASIC_EVAL_EXPR`, `CALC_EXIT_TRAMPOLINE`, etc.) go through fixed-
address `jp` trampolines generated by `include/exrom_jumptable.inc`'s
`KTAB_LIST` macro (`KTAB_*`), never a direct label reference — those
addresses shift on every Home-side edit, and this file has no way to
see that shift. `EXROM_VERIFY_KTAB_MAGIC` (in `rom/exrom_checker.asm`)
runs before every one of the seven entry stubs' real jumps, checking a
magic byte both sides agree on, so a stale/mismatched `exrom.bin` fails
loudly instead of jumping into garbage.

### The calculator engine (`rom/exrom_calc.asm`)

A rework, not a byte-for-byte port, of the real Spectrum ROM's
CALCULATE (RST $28) engine — see that file's own header for the full
before/after. It has NO `exx`, NO `ex (sp),hl`, and NO primed
registers anywhere (the real ROM leans on both purely to save bytes/
registers under 1982 hardware scarcity that doesn't apply the same way
here); the literal-stream position lives in `CALC_LITERAL_PTR`
(sysvar), and dispatch goes through `LD HL,(table entry)` / `JP (HL)`
rather than the real ROM's push-then-RET trick.

**Entry**: `CALC_EXROM_ENTRY` (reached via the `$C024` stub). Stack top
= pointer to the literal-op byte stream (RST $28's own return address,
untouched throughout). `CALC_RE_ENTRY` fetches the next literal byte,
decodes it (simple/manipulatory literals `<$80`, "multi-purpose"
literals `>=$80` — decode arithmetic matches the real ROM's 335B.html,
the register plumbing around it does not), computes operand pointers
via `CALC_STK_PNTRS_UNARY`/`_BINARY` (recomputed fresh from `CALC_SP`
every call, never carried incrementally), and dispatches through
`CALC_TABLE` (66 entries, `$00`-`$41`, matching the real ROM's own
`CALCADDR` table size).

**Internal record format** (`CALC_UNP_A`/`CALC_UNP_B`, 6 bytes each,
filled by `CALC_UNPACK` and read by `CALC_PACK`/the arithmetic
engines): byte0 = sign (`$00`/`$FF`), byte1 = biased exponent
(`0` = zero value, bias `128`), bytes2-5 = 32-bit mantissa MSB-first
with the implicit leading bit made explicit (bit7 of byte2 set for any
nonzero value) — i.e. value = sign × (mantissa/2³²) × 2^(exponent-128),
mantissa normalized into [2³¹, 2³²). `CALC_UNPACK` transparently
handles both the packed 5-byte GENERAL float form and the small-int
FAST form (byte0=`$00` marker, byte1=sign, bytes2-3=16-bit magnitude);
`CALC_PACK` always writes GENERAL form.

**Ops implemented in `CALC_TABLE`** (everything else still dispatches
to `CALC_OP_UNIMPLEMENTED`, which hangs via `jr`-to-self and records
the table index in `CALC_UNIMPLEMENTED_LITERAL_FLAG` — this project's
"store the real value, don't guess" idiom, not the Z80 `HALT` opcode):

| Literal | Op | Status |
|---|---|---|
| `$01` | `CALC_OP_EXCHANGE` | Ported directly from the real ROM (335B.html). Python/`z80sim`-verified only — `rom/test_calc_smoke_stackops.asm` exists but not yet run against real hardware/Fuse. |
| `$02` | `CALC_OP_DELETE` | Same as above. |
| `$03` | `CALC_OP_SUB` | **Hardware/Fuse-confirmed** (`rom/test_calc_smoke_arithmetic.asm`, green). Computed as `A + (-B)` via the shared `CALC_ADDSUB_ENGINE`. |
| `$04` | `CALC_OP_MUL` | **Hardware/Fuse-confirmed.** Real 32×32→64 unsigned multiply via shift-add (`CALC_MUL_ACC`/`CALC_MUL_CAND`), sign = XOR, one conditional post-loop renormalization shift. |
| `$05` | `CALC_OP_DIV` | **Hardware/Fuse-confirmed** (`rom/test_calc_smoke_division.asm`, green — added 2026-08-21, see below). |
| `$0F` | `CALC_OP_ADD` | **Hardware/Fuse-confirmed.** Shared `CALC_ADDSUB_ENGINE`: picks the larger-magnitude operand as the "winner," aligns the loser's mantissa by shifting, same-sign→add-with-renormalize, different-sign→subtract-with-renormalize. |
| `$31` | `CALC_OP_DUPLICATE` | Ported from the real ROM's "MOVE A FLOATING-POINT NUMBER" (33C0.html), with a different bounds check (this project's `CALC_STACK` is a fixed 8 slots, not the real ROM's free-RAM growth). Python/`z80sim`-verified only — `rom/test_calc_smoke_dupoverflow.asm` exists but not yet run. |
| `$38` | `CALC_OP_END_CALC` | Tail-jumps to `CALC_EXIT_TRAMPOLINE` (Home-resident) via `KTAB_CALC_EXIT_TRAMPOLINE` — can't page Home back in and then jump to a Home label directly, since that would change what's at this same address range mid-instruction-fetch if not done carefully. Python/`z80sim`-verified only — `rom/test_calc_smoke_endcalc.asm` exists but not yet run. |

**`CALC_OP_DIV`** (added 2026-08-21, wired in alongside this
documentation): computes first(lower)/second(top), matching
`CALC_OP_SUB`'s operand convention. Both mantissas are already
normalized into `[0.5,1)`; the routine pre-shifts the dividend
mantissa right by 1 whenever it's `>=` the divisor mantissa
(guaranteed possible since a normalized mantissa is always `< 2×` the
other), which guarantees the post-division quotient lands back in
`[0.5,1)` with **no post-loop renormalization branch at all** — unlike
`CALC_OP_MUL`, which decides renormalization after the fact. Main loop:
32 iterations of shift-and-subtract (`CALC_DIV_REM`/`CALC_DIV_QUOT`,
new 4-byte sysvars), same shape as `kernel/math`'s `MATH_UDIV16` scaled
from 16-bit to 32-bit. One detail `MATH_UDIV16` doesn't need to handle
at 16-bit width: the shift-left step's carry-out (remainder's true
value transiently exceeding 32 bits) is checked explicitly and forces
an unconditional subtract when set, rather than truncating and
comparing the truncated value — the actual subtract (mod 2³²) is
provably correct either way, so no special-casing is needed in the
subtract itself, only in deciding whether to take it. **Truncates
toward zero** (matches `MATH_DIVIDE16`'s own convention — does not
round). Division by zero hangs via the same `jr`-to-self idiom as
`CALC_OP_UNIMPLEMENTED` (no error-reporting path into this engine from
BASIC exists yet). Dividend-zero short-circuits straight to a zero
result. Verified via a Python simulation of the exact algorithm
(abstract-integer model) AND a byte-accurate simulation of the actual
instruction sequence (4-byte arrays, 8-bit wraparound sub/sbc chains),
both cross-checked against Python's native float division on >5000
random signed cases, before any Z80 was written.

**A real bug caught during this work, worth recording**: the first
draft of `rom/test_calc_smoke_division.asm`'s expected result byte for
`1/3` was computed via Python's `round(1/3)` rather than by running the
verified truncating simulation — off by one in the last mantissa byte
(`$AB` instead of the correct `$AA`), since `1/3`'s binary expansion
rounds up at the 33rd bit but this engine truncates. Caught by the real
Fuse run coming back RED on that one case while `32761/181=181` (an
exact result, no rounding ambiguity) passed in isolation — see
`rom/test_calc_div_debug.asm`, a per-byte-color diagnostic kept as a
worked example of bisecting a border-color-only failure. The bug was in
the test's hand-computed constant, not in `CALC_OP_DIV` itself.

**`CALC_INT_TO_FP`/`CALC_FP_TO_INT`** — boundary converters (the real
ROM's `STACK-A`/`STACK-TO-A` analogs), NOT `CALC_TABLE` literals; no
RST $28 entry point or `KTAB_*` trampoline slot exists for either yet.
`CALC_INT_TO_FP` pushes a signed 16-bit int as small-int form.
`CALC_FP_TO_INT` pops the top of stack and converts to a signed 16-bit
int, truncating toward zero, setting `CALC_TRUNC_FLAG` on overflow —
turning a set flag into a real BASIC error is explicitly deferred to
future LET-assignment integration work, not built yet.

**Known gaps**: no BASIC integration (see `basic/` section — as of
this writing `basic/`'s `+ - * /` still call `kernel/math` directly,
not this engine); no exponent overflow/underflow guard (`CALC_OP_MUL`/
`CALC_OP_DIV`'s exponent arithmetic is plain 8-bit, same trust level as
the rest of this file, not yet range-checked); division/multiplication
by numbers whose product/quotient would over/underflow the biased
exponent range isn't specifically handled.

### Testing

Each smoke test follows the same green/red border signal as every
other kernel-module test, standalone (no BASIC keyword needed):

- `rom/test_calc_smoke_stackops.asm` — exchange/delete. Not yet run
  against real hardware/Fuse.
- `rom/test_calc_smoke_endcalc.asm` — end-calc round trip. Not yet run.
- `rom/test_calc_smoke_dupoverflow.asm` — duplicate, including the
  8-slot overflow path. Not yet run.
- `rom/test_calc_smoke_unimpl.asm` — confirms an unimplemented literal
  actually hangs (only real hardware can confirm the machine actually
  stops, not just that the simulator's model says it should). Not yet
  run.
- `rom/test_calc_smoke_arithmetic.asm` — add/sub/mul.
  **Hardware/Fuse-confirmed, green.**
- `rom/test_calc_smoke_division.asm` — division, two cases (an exact
  result exercising the preshift branch, a repeating-fraction result
  exercising the non-preshift branch). **Hardware/Fuse-confirmed,
  green** (after the test-constant fix above).
- `rom/test_calc_div_debug.asm` — diagnostic, not a feature test: same
  division case as smoke test step 1, but with a distinct border color
  per compared result byte, for bisecting a border-color-only failure
  down to a specific byte.
- `rom/test_exrom_isolation.asm` — `kernel/bank`'s paging primitives.
  **Hardware-confirmed, PASS/PASS.**

## kernel/storage — SAVE/LOAD (2026-08-23, first real writeup)

**ARCHIVED 2026-08-24 — everything below describes the from-scratch
protocol as it existed, kept for historical/reference value only. It
is no longer part of the active build.** `kernel/storage/storage.asm`
now lives at `kernel/storage/archive/storage.asm`; `rom/exrom_storage.
asm`'s `STORAGE_SAVE`/`STORAGE_LOAD` are placeholder stubs. Real-signal
testing (real Fuse tape I/O, not the Track A injection technique below)
kept surfacing genuine bugs one layer deeper than the last fix — an
unbounded outer retry loop, an inner pilot-search budget so large a
single failed attempt looked like a hang, the header-search path's own
separate retry logic breaking once that budget was tightened, and
finally a completely unbounded loop inside pilot-sync detection with
no cap of its own — each fix costing EXROM budget faster than sweeps
could recover it. Decision: stop patching a from-scratch protocol
against real signal timing with no ground truth, and instead adapt the
REAL TS2068 ROM's own tape routines as the new basis — see repo root's
`Resource Docs/Timex Sinclair 2068 ROM Disassembly.pdf` and the real
stock ROM binaries at `~/fuse-build/roms/tc2068-0.rom`/`tc2068-1.rom`.
See `kernel/storage/archive/README.md` for the full reasoning and what
of this design is/isn't worth carrying forward (short version: the
low-level pulse primitives `STORAGE_PULSE`/`STORAGE_WAIT_EDGE`/
`STORAGE_PILOT_TONE`/`STORAGE_SYNC` were real-signal-proven; the block-
framing design and every guessed timing threshold above them are what's
being replaced).

Not previously documented here despite being ~1700 lines — this section
covers the protocol itself, the real user-hit bug found and fixed this
session, and the Fuse-only testing technique (Track A) built to get
reliable SAVE/LOAD coverage without waiting on the real pulse-timing
work (Track B) that's still open.

### Protocol design

`kernel/storage/storage.asm`'s own header is the authoritative design
doc — summary: NOT a reproduction of the real Sinclair tape format.
Standard ZX pulse widths at the low level (pilot/sync/bit0/bit1,
`STORAGE_PULSE`/`STORAGE_WAIT_EDGE`), but a from-scratch higher-level
framing above them: many small 128-byte blocks, each sent in two full
redundant passes (not interleaved, so a localized noise burst is
unlikely to hit both copies of the same block), each individually
checksummed and preceded by its own short pilot. A receiver tracks
which block IDs it still needs (`STORAGE_BLOCK_BITMAP`) and fills them
in from whichever copy arrives intact — a bad block is a small,
recoverable, local event, not the all-or-nothing failure the original
real-ROM-faithful design (abandoned) required. `STORAGE_SAVE`/
`STORAGE_LOAD`'s own `In:`/`Out:`/`Destroys:` contracts
(`kernel/storage/storage.asm`) are the ground truth for exact register
conventions — `STORAGE_SAVE`: `HL`=filename ptr, `B`=filename length,
`IX`=data ptr, `DE`=data length; `STORAGE_LOAD`: `IX`=destination,
`HL`=filename ptr (ignored if `B`=0, the wildcard `LOAD ""` case),
`B`=filename length, `DE`=max length; both live in EXROM (`rom/
exrom_storage.asm`), reached from Home via `BASIC_SAVE_EXROM`/
`BASIC_LOAD_EXROM` (`basic/basic.asm`) through the fixed trampolines
`EXROM_ENTRY_SAVE`/`EXROM_ENTRY_LOAD` (`$C012`/`$C018`, `rom/
exrom_checker.asm`).

### Real bug found and fixed this session: filename padding

`STORAGE_LOAD`'s own filename-matching requires the caller's name
already space-padded to the header's fixed 10-char width — documented
as a precondition but never actually built into `BASIC_DO_LOAD`, so
any real (non-wildcard) `LOAD "name"` shorter than 10 characters —
virtually always — was rejected as a false mismatch regardless of
what was actually on tape. Found via a `debug.bin` memory dump after a
`LOAD FAILED` against a tape independently verified byte-perfect.
Fixed in `BASIC_DO_LOAD` (`basic/basic.asm`, see its own "REAL BUG
FOUND AND FIXED" comment) — pads into `DETOK_BUF` before calling
`STORAGE_LOAD`.

### Track A: Fuse debugger-injected SAVE/LOAD (`tools/fuse_load_inject.py`)

The real receive path decodes tape pulses via a busy-loop edge-timing
routine (`STORAGE_WAIT_EDGE`) that turned out to be non-deterministic
under Fuse — the *same* tape file gave different `LOAD` results across
separate runs, and with no tape connected at all the floating/noisy
EAR bit reading can keep `STORAGE_WAIT_PILOT` finding spurious
near-pilot edges indefinitely instead of timing out cleanly. That
real-hardware-timing problem is still open (Track B, below) — Track A
sidesteps it entirely for day-to-day Fuse testing rather than waiting
on it.

Technique: `--debugger-command` (Fuse 1.9.1's own scripting, confirmed
against the real binary, not just the manual) sets a breakpoint at
`EXROM_ENTRY_LOAD`/`_SAVE` — fixed addresses, stable across any future
EXROM edit — and a `commands <id> ... end` block attached to it pokes
the requested payload bytes and fakes the routine's own successful-
return register/flag contract (and, for SAVE, an instant `STORAGE_
OP_STATE=2`) before jumping back, so the real pulse-transmission body
never runs at all. `tools/fuse_load_inject.py <program.txt>
<out_prefix>` generates the `.dbg` script plus two harnesses:
`<prefix>_check.asm` (calls `BASIC_LOAD_EXROM` directly — quick
injection-correctness check, bypasses command parsing) and `<prefix>
_roundtrip.asm` (the real regression test — calls `BASIC_DO_SAVE`/
`BASIC_DO_LOAD`, the actual command-level entry points, so it also
exercises filename parsing/padding, the exact bug class above; wipes
`PROG_AREA` between SAVE and LOAD so a pass proves LOAD actually
restored the program; covers both the named and wildcard `LOAD ""`
dispatch paths). `tests/storage_roundtrip1.txt` is the current fixture;
run via `tools/run_storage_roundtrip_test.sh storage_roundtrip1`.

Gotchas discovered building this, worth knowing before touching it
again:
- **`set address value` (Fuse's debugger poke command) only accepts a
  bare numeric literal for `address`** — not an expression, despite
  the manual's general "anywhere a numeric value is expected you can
  use an expression" wording. `set (z80:ix+0) val` and even `set
  (0xbc01+1) val` (pure literal arithmetic, no register at all) both
  fail with `Invalid debugger command: syntax error` the moment the
  breakpoint actually fires — confirmed empirically, not assumed.
  Expressions DO work fine in a `set`'s *value* slot and in `print`.
  Fixed by computing poke addresses as Python-side literals
  (`PROG_AREA_START + i`) rather than `z80:ix`-relative — valid
  because every real caller of `BASIC_LOAD_EXROM` sets `IX =
  PROG_AREA_START` first, there's no other call site.
- **`EXROM_VERIFY_KTAB_MAGIC` (`rom/exrom_checker.asm`) halts forever**
  on every single EXROM entry point unless the calling Home-side build
  stamps `KTAB_MAGIC` at `KTAB_BASE` (`include/exrom_jumptable.inc`'s
  `KTAB_LIST` macro, `DEFINE EXROM_JUMPTABLE_HOME_SIDE` before
  including it — see `tools/preload_gen.py`'s own `HARNESS_TEMPLATE`
  for the working shape). The original scratch `rom/test_storage_
  load_*.asm` diagnostic harnesses from earlier this session never did
  this and had gone stale relative to that check — every one of them
  now hangs (visible as a rapidly flickering border, not a clean
  freeze) rather than reaching real `STORAGE_LOAD` code at all. `tools/
  fuse_load_inject.py`'s own generated harnesses do this correctly.
- **`print`'s "standard output" is the GUI debugger pane's own text
  widget, not the process's real stdout** — nothing appears in a
  captured log file even though the command runs without error. This
  is *why* SAVE-side capture-to-a-host-file was abandoned as a design
  (see the script's own module docstring): there's no way to turn a
  live SAVE's actual bytes into a reusable artifact through Fuse's
  debugger scripting alone. The SAVE breakpoint exists only to make
  `SAVE` itself instant/deterministic (skips real pulse transmission
  entirely), not to capture what was saved.
- To read a value back deterministically for verification (rather than
  trusting a screenshot), set a second breakpoint further along and
  use the debugger's own `exit <expression>` command — the process's
  real exit code, fully scriptable, used throughout this session's own
  testing instead of eyeballing screenshots.

### Track B: real pulse-protocol hardening (open, real-hardware-bound)

Not started. Track A can't help here — no Fuse, no debugger, real
hardware only. The plan (self-calibrating pilot/bit thresholds instead
of the current hand-tuned `STORAGE_PILOT_THRESHOLD`/`STORAGE_BIT_
THRESHOLD` constants; a per-SAVE generation tag folded into every
block's checksum, closing a real "stale/accumulated tape" corruption
path where a leftover block from an earlier recording on the same tape
could be silently accepted as current data if it happens to share a
block ID with one still missing; more generous header-retry count; a
two-tier verification method — a `tools/z80sim`-based deterministic
state-machine test plus a real-Fuse repeatability gate, N identical
runs required, not a single green one) is written up in this session's
own planning notes but not yet implemented.

## kernel/storage — SAVE/LOAD, current design (real-ROM-derived port)

Replaces the from-scratch protocol archived above. `kernel/storage/
storage.asm` is a direct, instruction-by-instruction-verified port of
the real Timex Sinclair 2068 ROM's own SA-BYTES/LD-BYTES cassette
routines (verified against `~/fuse-build/roms/tc2068-1.rom`'s own
bytes, not just the disassembly book's prose — that file's own top
header documents the full protocol shape, every deliberate deviation
from the real ROM, and cross-references every real-ROM M-address). Two
tape blocks per SAVE/LOAD: a stock 17-byte BASIC header, then one data
block. The data remains this ROM's native structured-BASIC representation,
not Sinclair-tokenized BASIC; `docs/tape_compatibility.md` defines the
exact boundary. `STORAGE_SAVE`/`STORAGE_LOAD`'s own `In:`/
`Out:`/`Destroys:` contracts in `storage.asm` are the ground truth for
exact register conventions; both live in EXROM (`rom/exrom_storage.
asm`), reached from Home via `BASIC_SAVE_EXROM`/`BASIC_LOAD_EXROM`
(`basic/basic.asm`) through the fixed trampolines `EXROM_ENTRY_SAVE`/
`EXROM_ENTRY_LOAD` (`$C012`/`$C018`, `rom/exrom_checker.asm`).

**Status**: SAVE is confirmed working — a real user-captured TZX
recording of its actual tape output was parsed (as a TZX "Direct
Recording" block, i.e. the raw sampled port signal, not a standard
ROM-block capture) and its pulse widths measured directly against the
real ROM's own timing constants; they match. LOAD is NOT yet confirmed
reliable end-to-end. Real testing under Fuse repeatedly shows the
header search failing to detect any tape signal edge at all for
extended periods (seconds), even against a recording independently
confirmed to contain a clean, correctly-timed leader tone at the point
the search should be listening. Investigated and ruled out as the
cause: the two retry-bound constants (`STORAGE_HEADER_ATTEMPTS_MAX`/
`STORAGE_ENTRY_RETRY_MAX`, both in `storage.asm`) themselves — their
arithmetic was corrected against real measured timing and the failure
signature didn't change; Fuse's tape-trap auto-play mechanism
(confirmed via Fuse's own source that it doesn't apply to non-standard
loaders like this one, and doesn't matter once a tape is already
playing, which was independently confirmed to be the case during the
failing runs); and the checksum/type-flag logic deviations documented
in `storage.asm`'s own header (both independently verified via
`tools/z80sim` against this file's own send/receive convention).

**If resuming this work**: the most useful next artifact is a real Fuse
register/PC trace captured *during* an active, confirmed-playing tape
read — not another full-memory `debug.bin` snapshot (several of those
were captured and analyzed this round; they can confirm *whether*
`STORAGE_LOAD` is still running and roughly where in its own retry
budget, via `STORAGE_OP_STATE`/`STORAGE_ENTRY_RETRY`, but can't show
*why* individual edge-detection attempts are failing, since that needs
a per-sample or per-attempt view, not a single point-in-time snapshot).
A hand-written T-state-accurate Python simulation of the edge-detection
algorithm was attempted and abandoned after it failed its own sanity
check against a clean synthetic signal — not trustworthy, don't reuse
without first fixing and re-validating it against a known-good
synthetic case. `tools/fuse_load_inject.py`/`tools/
run_storage_roundtrip_test.sh`/`tests/storage_roundtrip1.txt` (the OLD
design's debugger-injection test tooling, described under Track A
above) were built for the archived from-scratch protocol's own
register/timing contract and have not been adapted for this one.

## basic/ — the BASIC interpreter (growing)

Owns tokenization, the command loop tying `kernel/editor` + storage
together, and program execution. Still a deliberately small subset of
the language, not the full implementation — see `basic/basic.asm`'s
file header for the exact scope statement. What exists:

- **Built-in functions in expressions** — `ABS(x)`, `SGN(x)`, and
  `MOD(x,y)`, matched by `BASIC_TRY_EVAL_FUNCTION` against
  `FUNCTION_TABLE` (name pointer + a `FUNC_ID_*` byte + a 1-byte
  argument count per entry, not a raw code address — see
  `FUNCTION_TABLE`'s own header in `basic/basic.asm` for why an
  indirect jump-table call was rejected: every current function takes
  at least one argument in `HL`, the same register `JP (HL)` would
  need to hold the call target instead, a genuine register conflict,
  not a style choice). `BASIC_EVAL_PRIMARY` tries a function-name match
  *before* the single-letter-variable check, since `ABS(5)`'s leading
  `A` would otherwise be misread as variable `A` with `BS(5)` left
  over. Adding a fourth function means: one `FUNCTION_TABLE` row, one
  `FUNC_ID_*` constant, one `CP id / JR Z` line in
  `BASIC_EVAL_PRIMARY`'s own `.dispatch` chain, and (if it needs a
  genuinely new kernel routine) that routine in `kernel/math` or
  elsewhere. New sysvars: `FUNC_CALL_ID` (1 byte, `$617B`) and
  `FUNC_CALL_ARGC` (1 byte, `$617C`) — see the re-entrancy bug below
  for why these are snapshotted onto the real stack rather than read
  directly at dispatch time.

  **Three real bugs found and fixed while building this** (all via
  `tools/z80sim`, not static analysis):
  1. `BASIC_TRY_EVAL_FUNCTION` destroys `A` along with the rest of
     `AF`/`BC`/`DE`/`HL`/`IX`, but the pre-existing single-letter-
     variable code right after it assumed `A` still held the original
     character — every plain variable reference (`X`, `Y`, ...) was
     failing with a bogus `SYNTAX ERROR` until `A` was explicitly
     reloaded from `(HL)` after the function-table lookup returns no
     match.
  2. A genuinely pre-existing, unrelated bug in `BASIC_EVAL_FACTOR`'s
     unary-minus handling, unrelated to this feature and only
     surfaced by testing `ABS(-32768)`: `SBC HL,DE` during the
     negation sets carry on any nonzero borrow, and that carry fell
     straight through to the routine's own `RET` — meaning *any*
     expression with a literal unary minus on a nonzero value (`-5`,
     `X=-5`, `PRINT -5`, `IF X>-1 THEN`, ...) was reporting a bogus
     `SYNTAX ERROR` on correctly-formed input. Only `-0` avoided it,
     which is almost certainly why real testing never caught it.
     Fixed by clearing carry before returning, same as every other
     successful exit in the evaluator.
  3. A re-entrancy bug in `MOD(x,y)`'s own two-argument parsing,
     caught by testing `MOD(ABS(X),3)` — a function call nested
     inside another function's own argument. `FUNC_CALL_ID`/
     `FUNC_CALL_ARGC` are shared scratch, set every time *any*
     function name is matched; the recursive `BASIC_EVAL_EXPR` call
     parsing `MOD`'s first argument reaches `ABS(X)`, which
     overwrites both sysvars with *its own* values before `MOD`'s own
     `.do_function_call` ever reads `FUNC_CALL_ARGC` back — so
     `MOD`'s ARGC=2 silently became ABS's ARGC=1, and the following
     `,` was rejected as a syntax error. Same root-cause family as the
     `DETOK_BUF` collision bug in `EDIT` (see `BASIC_DO_EDIT`'s own
     header) — shared mutable scratch clobbered by a nested call.
     Fixed by snapshotting `FUNC_CALL_ID`/`FUNC_CALL_ARGC` into `BC`
     and pushing that onto the real stack immediately after the
     match, before any recursive argument-parsing call gets a chance
     to touch the shared sysvars — the same "a value that must
     survive a destructive call" reasoning this project applies
     everywhere else, just via the stack instead of a dedicated
     sysvar, since this needs to survive arbitrary recursion depth
     rather than one specific call site.

  Bugs 1 and 2 are confirmed fixed on real hardware/Fuse (via the
  `tools/preload_gen.py`-generated harnesses — see "Static checks"
  near the top of this document). Bug 3 also confirmed fixed on real
  hardware (`test_preload_testmod.asm`) — that same session also hit a
  real JR-range assembler error as this dispatch chain grew (`jr
  c,.do_number` +152 out of range; fixed by converting to `jp`, plus
  two more nearby jumps proactively converted after a byte-distance
  check — sjasmplus is the only real ground truth for this, neither
  `check_asm.py` nor `tools/z80sim` check it).

  Added since: `SQR(x)` and `DIV(x,y)` — the same simulator
  verification as everything above (26 end-to-end cases including
  every function nested inside every other), plus `test_preload_
  testsqrdiv.asm` generated for real-hardware testing — **not yet
  confirmed on real hardware** — and `INT(x)` (a true no-op in this
  pure-integer BASIC — the argument is already its own `INT()`, so
  `.call_int` in `BASIC_EVAL_PRIMARY`'s dispatch does nothing at all;
  kept as its own table entry purely for SuperBASIC-syntax
  compatibility) and `RND(x)` (via the new `MATH_RND16`, see
  `kernel/math` above — this project's first function whose result
  genuinely varies from call to call, and the first whose seeding step
  can't be verified by simulation at all, only its deterministic
  core). `INT`/`RND` went through the same simulator verification (41
  end-to-end cases, including `RND(x)` across 25 `x`/seed
  combinations, each checked only for staying in range rather than an
  exact value) — **also not yet run on real hardware.**

  **"Function-result float" (2026-08-22) — `SQR(x)` upgraded, `SIN(x)`
  added, this dialect's first transcendental function.** `SQR`'s old
  body (bare `MATH_SQRT16`) returned `floor(sqrt(n))` — genuinely wrong
  for almost every input (`SQR(2)` = `1`, not an approximation of
  `1.4142`), the concrete motivating case for wiring the calculator
  engine (`rom/exrom_calc.asm`) into `basic/` at all, beyond division's
  own truncated-either-way integer result. Design, deliberately
  minimal given Home ROM's own tight budget at the time (~1.3KB free
  after this landed): every OTHER keyword — variables, literals,
  comparisons, `FOR`/`NEXT`, every other function — stays plain 16-bit
  int, so none of BASIC's numeric model changed. `SQR`/`SIN` still
  return a truncated int through the normal `HL`/`DE` composition
  pipeline (`x = SQR(2)+1` still adds `1` to a truncated `1`), but each
  also computes the TRUE float result and stashes it in `FUNC_RESULT_
  FLOAT` (packed float, `include/sysvars.inc`) plus a `FUNC_RESULT_
  FLOAT_NEGATIVE` sign flag (kept separate since both routines' own
  magnitudes are always non-negative by construction — see each
  routine's own header), setting `FUNC_RESULT_IS_FLOAT` = 1.
  `BASIC_STMT_PRINT` checks that flag after evaluating its argument
  and, if set, prints `FUNC_RESULT_FLOAT` via the new `BASIC_FLOAT_TO_
  STRING` (4 truncated fractional digits, reusing `BASIC_NUM_TO_
  STRING` for the integer part) instead of the plain int. The flag is
  cleared at every `+`/`-`/`*`/`/` combine step in `BASIC_EVAL_EXPR`/
  `BASIC_EVAL_TERM` and at `BASIC_EVAL_FACTOR`'s unary minus, and
  unconditionally before every function's own dispatch (one shared
  clear point, so a float flag left over from an ARGUMENT's own nested
  call — `MOD(SQR(2),3)` — doesn't leak into a genuinely-integer
  result) — so `PRINT SQR(2)` shows `1.4142` but `PRINT SQR(2)+1`
  falls back to a plain truncated `2`, same "only a truly bare call"
  contract SIN's own reference-angle sign tracking depends on.

  New EXROM primitives (rom/exrom_calc.asm), both boundary converters
  in the same family as `CALC_INT_TO_FP`/`CALC_FP_TO_INT` (not
  `CALC_TABLE` literals — nothing in the RST $28 literal stream needs
  either): **`CALC_PUSH_PI`** (pushes the hand-encoded constant
  `PI_CONST`, `$82 $49 $0F $DA $A2` — verified against this project's
  own documented pack algorithm in Python, and happens to match the
  real Sinclair ROM's own well-known PI bytes, a happy confirmation not
  a requirement) and the generic **`CALC_PUSH_FP_RAW`** (copies any
  already-packed 5-byte float from a given pointer onto `CALC_STACK`
  verbatim — used both by `CALC_PUSH_PI` internally and, via its own
  Home wrapper, to feed `FUNC_RESULT_FLOAT` back into the calculator
  for printing). Two new fixed EXROM entry stubs, `$C036`/`$C03C` (see
  `rom/exrom_checker.asm`'s own stub-table header). `BASIC_SQR_FLOAT`
  refines `MATH_SQRT16`'s int result with 4 Newton-Raphson iterations
  in float space (`x_{k+1}=(x_k+n/x_k)/2`) — Python-checked across
  `n=1..49999`: 3 iterations left a worst case (`n=3`) off in the 4th
  displayed digit, 4 iterations brought the worst case to ~2e-9, safely
  below what 4 digits can show. `BASIC_SIN_FLOAT` takes **degrees, not
  radians** (deliberate: this dialect has no float literal syntax at
  all, so an integer number of radians would almost never land near a
  recognizable angle — `SIN(90)` = `1.0000` is far more useful than
  `SIN(90 radians)`), reduces to a `[0,90]` reference angle (`sin(x+
  180)=-sin(x)`, `sin(180-x)=sin(x)`, sign tracked in `FUNC_RESULT_
  FLOAT_NEGATIVE`) and evaluates a 5-term Maclaurin series (`x - x^3/6
  + x^5/120 - x^7/5040 + x^9/362880`, computed via the sign-free
  recurrence `power_k = power_{k-1} * x^2 / D_k` with `D_k=6,20,42,72`
  — avoids ever needing `9! = 362880`, which doesn't fit a 16-bit int)
  — Python-verified across every integer degree in `[-720,720]`, worst
  case ~3.5e-6 (4 terms alone left `SIN(90)` displaying `0.9998` instead
  of the exact `1.0000` — the very first thing anyone would try — so a
  5th term was added specifically to get that case right).

  **Two real bugs caught by `rom/test_sqr_sin_visual.asm`** (a
  from-scratch visual smoke test — calls both routines directly with
  known arguments and prints each result so the digits can be read by
  eye/screenshot, since a byte-exact expected-value table would need
  replicating this algorithm's own 32-bit-mantissa rounding path in
  Python first, the exact mistake `rom/test_calc_smoke_division.asm`
  already caught once): `SIN`'s odd/even term-sign selection was
  inverted — the loop's `DJNZ` counter counts DOWN (4,3,2,1 across
  passes 1,2,3,4), so checking "is the counter odd" picks the OPPOSITE
  parity from "is this pass number odd," and every term past the first
  landed with the wrong sign (`SIN(90)` showed `2.1415`, not `1.0000`).
  And `SQR`'s `n<=0` shortcut zeroed only `FUNC_RESULT_FLOAT`'s byte0
  (the packed format's small-int-form MARKER) without also zeroing the
  value bytes that marker's own meaning still depends on — `SQR(0)`
  and `SQR(-5)` both displayed whatever a PREVIOUS call's result had
  left in those bytes. Fixed by routing the zero case through
  `CALC_INT_TO_FP_HOME(0)`, the same boundary converter every genuine
  int constant elsewhere in this file already goes through, rather than
  hand-encoding the zero record. Both fixes confirmed via the same
  harness; also confirmed end to end through the REAL `BASIC_STMT_
  PRINT` statement (not just the two routines directly) with `PRINT
  SQR(2)` → `1.4142`, `PRINT SIN(30)` → `0.4999`, and `PRINT
  SIN(45)+1` → `1` (confirming composition really does fall back to a
  plain int) — **all hardware/Fuse-confirmed.**

  Every other existing keyword was reviewed against the same "should
  this be float?" question and left alone, deliberately: `ABS`/`SGN`/
  `INT` are exact by definition regardless of numeric type; `MOD`/`DIV`
  are genuinely integer operations (floor division/remainder, not
  approximations of anything); `RND`/`POINT` already return small exact
  integers with no fractional meaning. `SQR` was the one existing
  keyword whose *integer* answer was actually wrong most of the time —
  the concrete case this whole feature exists for. `COS`/`TAN`/`LN`/
  `EXP`/etc. are natural follow-ups reusing the same `PI_CONST`/
  calculator infrastructure, not yet implemented.


- **`BASIC_TOKENIZE_LINE`** — converts `EDIT_LINE_BUF`'s raw text into
  `kernel/memory`'s length-prefixed statement format. No keyword
  compression yet — plain text, matched by string comparison at run
  time (simpler to get right first).
- **`BASIC_COMMAND_LOOP`** — a genuine loop (`REPL`-style). Ties
  `EDITOR_ENTER`, the tokenizer, and `MEM_LINE_STORE` together, kept
  out of `kernel/editor` itself to preserve one-directional layering.
  **`RUN` is a real immediate command**: typed alone (trailing spaces
  OK), it executes the currently stored program instead of being
  tokenized and saved — checked explicitly so `RUNAWAY` or similar
  can't be mistaken for `RUN` alone. **Now supports real navigation**:
  `CUR_EDIT_POS`/`CUR_EDIT_INDEX` track which statement is being
  edited — an existing one (moved into via `UP`/`DOWN`) or the
  sentinel (`$FFFF`) meaning "the new, uncommitted line at the end".
  Committing an existing line's edit replaces it in place
  (`MEM_LINE_STORE`'s differently-sized-replacement path, already
  tested) and advances to the next line — literally by calling
  `BASIC_HANDLE_NAV` with `EDIR_DOWN`, reusing the same move logic
  real navigation uses rather than duplicating it. A blank ENTER is a
  no-op. **`NEW` is a second real immediate command**, same
  prefix-plus-trailing-check shape as `RUN`: clears the program
  (`MEM_INIT`), zeroes all 26 variables (`MEM_FILL_ZERO` over
  `VAR_TABLE`), and resets edit/view state back to the exact same
  fresh values `BASIC_COMMAND_LOOP`'s own one-time cold-boot setup
  uses, then `GFX_CLS` + `BASIC_RESET_ROW_SHADOW` so the redraw shadow
  doesn't think the just-cleared screen still matches the old program.
- **`BASIC_HANDLE_NAV`** — `kernel/editor`'s new `EDITOR_NAV_HOOK`
  target (same optional-callback pattern as `EDITOR_REDRAW_HOOK`, so
  `kernel/editor` still never needs to know BASIC or statements
  exist). Moves `CUR_EDIT_INDEX` up or down by one, discards any
  uncommitted changes to whatever was being edited before (no undo in
  this project, so silently discarding on navigation is the simplest
  honest behavior), and adjusts `VIEW_TOP_INDEX` so the target stays
  within the visible 24-row window. "Scrolling" is just changing that
  index — the existing full-redraw-every-keypress approach handles the
  rest, no separate hardware-scroll primitive needed.
  `BASIC_COUNT_STATEMENTS` and `BASIC_FIND_STATEMENT_AT_INDEX` support
  it (both hand-traced against edge cases: empty program, single-
  statement out-of-range index).
- **`BASIC_LOAD_EDIT_LINE`** — populates `EDIT_LINE_BUF` from
  `CUR_EDIT_POS` (empty for the sentinel, detokenized existing text
  otherwise). Shared by `BASIC_COMMAND_LOOP` (every loop iteration,
  since `EDITOR_INIT` wipes `EDIT_LINE_BUF` each time) and
  `BASIC_HANDLE_NAV` (after moving to a different statement) — one
  implementation, not duplicated.
- **Variables** — 26 single-letter (`A`-`Z`, case-insensitive), signed
  16-bit integers, in `VAR_TABLE`. `BASIC_TRY_ASSIGNMENT` recognizes
  `<variable> = <number>` (literal only, no expressions yet).
- **`BASIC_PARSE_NUMBER`** — parses an optionally-signed decimal
  integer, hand-traced digit-by-digit against concrete examples (`"53"`,
  `"-7"`).
- **`DIV10`** / **`BASIC_NUM_TO_STRING`** — Z80 has no hardware divide,
  so printing a number needed a real division routine. The 16-iteration
  shift-and-subtract algorithm was verified **numerically** (Python
  simulation against 2008 test values including edge cases) before any
  assembly was written — same discipline as this project's other
  tricky arithmetic (the screen address formula, the ink/paper bit-
  swap). `BASIC_NUM_TO_STRING` builds the decimal string backward
  (division produces least-significant digit first) and was separately
  hand-traced for `53`, `-7`, and `0` (the last one specifically to
  confirm it prints `"0"`, not an empty string).
- **`BASIC_STMT_PRINT`** — now handles a variable reference (`PRINT x`)
  as well as a string literal, in addition to the original scope.
- **`CLS`**, **`REM`**, **`BORDER <n>`** — three new statements, the
  first batch built directly off `docs/basic_language_reference.md`'s
  "Deliberately not added" gap list rather than the earlier IF/error-
  handling work. `BASIC_STMT_CLS` calls `GFX_CLS` and resets
  `BASIC_OUTPUT_ROW` to 0, so output after a mid-program `CLS` starts
  from the top rather than wherever `PRINT`/`INPUT` had scrolled to.
  `BASIC_STMT_REM` is a pure no-op — the dispatcher's own
  `BASIC_MATCH_KEYWORD_BOUNDARY` call already advances past `REM` and
  its boundary character before this is ever reached, so nothing
  further needs parsing. `BASIC_STMT_BORDER` evaluates its argument
  through the same `BASIC_EVAL_EXPR` every other value-taking statement
  uses, then hands the low byte to the new `GFX_SET_BORDER` (see
  kernel/graphics above). All three are wired into
  `BASIC_DETECT_KEYWORD_PREFIX`/`BASIC_UPPERCASE_KEYWORD_PREFIX` too,
  so they bold/normalize live while typing — the two-places-not-one
  gap flagged after the IF/ELSEIF bolding bug (see below) was checked
  against directly this time, not rediscovered.
- **`BASIC_ADVANCE_OUTPUT_ROW`** — a real bug found via a screenshot
  showing corrupted, repeating output during a GOTO-driven infinite
  `PRINT` loop: both `BASIC_STMT_PRINT` and `BASIC_STMT_INPUT` used to
  increment `BASIC_OUTPUT_ROW` with no bounds check at all, each with
  its own separate copy of the same logic (one even had a `TODO`
  comment flagging the gap, unfixed until it actually bit). Once
  output reached row 24, `GFX_PUTCHAR`/`GFX_PRINT_STRING` read one
  entry past `ROW_BASE_TABLE`'s 24 entries into whatever memory
  follows it (`FONT_TABLE`), computing a garbage screen address —
  every print after that corrupted whatever it landed on rather than
  crashing outright, which is why the symptom looked like scattered
  garbled columns and stale values rather than an obvious hang. Fixed
  with a single shared routine (replacing both duplicated copies), now
  backed by the real 24-row output scroll primitive.
- **`BASIC_STMT_INPUT`** — moved whole to EXROM on 2026-08-27 and
  extended to accept either a numeric scalar (`INPUT A`) or a string
  scalar (`INPUT A$`, up to 31 printable characters). Numeric input is
  now explicitly bounded to its seven-byte payload buffer rather than
  being able to overwrite the following sysvars. No backspace/delete
  support yet — `DELETE` is ignored like any other unrecognized key.
  Five initially separate Home callbacks were consolidated behind one
  selector gateway, saving four fixed jump-table slots.
- **`BASIC_RUN`** / **`BASIC_EXEC_STATEMENT`** — walks the program via
  `MEM_LINE_FIRST`/`MEM_LINE_NEXT`, now recognizing `PRINT`, `INPUT`,
  assignment, and `END`/`STOP` (still treated identically — see that
  routine's own comment on why that's deliberate). Now genuinely useful
  as a multi-statement program runner, not just a single-statement
  executor — it always could walk multiple statements, it just never
  had more than one to work with before append-only editing existed.
- **Case-insensitive keyword matching** (`BASIC_MATCH_KEYWORD`,
  `BASIC_TO_UPPER`) — deliberate, given `kernel/io`'s lowercase-default
  typing.
- **Keyword auto-uppercase + bold highlighting, at COMMIT time only**
  — a design choice made deliberately, not an oversight: the line
  currently being typed renders plain (no highlighting) via
  `BASIC_REDRAW_PROGRAM`; normalization (`BASIC_UPPERCASE_KEYWORD_PREFIX`,
  mutating) happens once, in `BASIC_COMMAND_LOOP`, right when ENTER
  commits the line — the same checkpoint where future syntax
  validation would naturally live, rather than trying to validate or
  highlight text that's still being actively typed. Once committed, a
  line displays in its settled bold/uppercase form via
  `BASIC_PRINT_LINE_HIGHLIGHTED` (read-only — `BASIC_DETECT_KEYWORD_PREFIX`
  detects without mutating) every time the multi-line view redraws it.
  Both the mutating and non-mutating checks require a real word
  boundary (space, `=`, or end of line) after the keyword match, so
  `printer` is never mistaken for `print` — same discipline already
  applied to `RUN` vs `RUNAWAY`.
- **This is a genuinely separate keyword list from `BASIC_EXEC_
  STATEMENT_CONTENT`'s dispatch table** — a real gap found and fixed
  after IF/ELSEIF/ELSE/END IF were added: the highlight/normalize path
  only recognized the ORIGINAL keyword set (PRINT, END, STOP, INPUT,
  GOTO, RUN) and had never been extended, so IF/ELSEIF/ELSE/END IF
  typed into a program neither bolded nor got case-normalized on
  commit — purely cosmetic (execution itself stayed correct regardless,
  since `BASIC_MATCH_KEYWORD` is independently case-insensitive), but
  inconsistent with every other keyword's behavior. Fixed by extending
  both `BASIC_DETECT_KEYWORD_PREFIX` and `BASIC_UPPERCASE_KEYWORD_
  PREFIX` with entries for `IF`/`ELSEIF`/`ELSE` (leading-keyword only,
  matching how every existing entry here works — `THEN`, like a
  `PRINT` expression or a `GOTO` target label, is mid-statement and
  deliberately NOT specially highlighted) plus a new compound-keyword
  pair, `BASIC_TRY_DETECT_ENDIF`/`BASIC_UPPERCASE_ENDIF`, for "END IF"
  specifically — needed because this file's existing single-keyword
  helpers (`BASIC_TRY_DETECT_ONE`, and `BASIC_UPPERCASE_KEYWORD_
  PREFIX`'s own `.try_upper`) can only ever match ONE contiguous
  reference keyword; matching bare `END` against "END IF" text would
  only bold/uppercase "END" and silently leave "IF" untouched, the
  exact same class of gap `BASIC_MATCH_ENDIF` already exists to close
  on the execution side (see "IF/ELSEIF/ELSE/END IF" above) — checked
  BEFORE bare `END` in both routines for the same reason.
- **This "two places, not one" gap was later closed structurally.**
  `BASIC_DETECT_KEYWORD_PREFIX` and `BASIC_UPPERCASE_KEYWORD_PREFIX`
  no longer each hold their own hardcoded keyword list — both now walk
  one shared `KEYWORD_HILITE_TABLE` (a flat array of pointers to `KW_`
  reference strings, terminated by a 0 word), via `IX`. Adding a
  keyword to bold/uppercase highlighting is now one new row in that
  table; both consumers pick it up automatically, so this specific bug
  class (one list updated, the other forgotten) can't recur here.
  `BASIC_TRY_DETECT_ENDIF`/`BASIC_UPPERCASE_ENDIF` are unaffected —
  "END IF" stays a dedicated pre-check before either loop starts,
  since it's a compound two-word keyword the flat table can't
  represent. Verified: the table's 23 entries match the two old
  hardcoded lists exactly, same order; `tools/check_asm.py` clean
  across the whole codebase after the change (only the pre-existing
  `BASIC_EVAL_RHS_AND_COMPARE` `[REVIEW]` flag, unrelated). **Not yet
  assembled or tested by the user** — no sjasmplus in this session, so
  this rests on hand-tracing the stack/HL-restoration discipline
  (documented in both routines' own headers) rather than a real run.
  This does NOT extend to `BASIC_EXEC_STATEMENT_CONTENT` or
  `BASIC_CHECK_STATEMENT_CONTENT` — those still have their own
  separate per-keyword dispatch, since each keyword's validation logic
  genuinely differs (some take an expression, some an identifier,
  IF/ELSEIF have unique multi-part grammar) in a way a flat "present
  or not" table can't capture. Unifying those two as well would need
  each inline `.check_*` block split into its own named routine first
  — a larger, separate change, not done here.
- **`BASIC_REDRAW_PROGRAM`** — the current `EDITOR_REDRAW_HOOK` target.
  Starts rendering from `VIEW_TOP_INDEX` (not always the first
  statement — that's how scrolling works), one statement per row,
  detokenizing each into `DETOK_BUF` (trivial for this project's
  tokenizer — no keyword compression) and rendering with highlighting
  via `BASIC_PRINT_LINE_HIGHLIGHTED` — EXCEPT whichever statement's
  position matches `CUR_EDIT_POS`, which renders plain from
  `EDIT_LINE_BUF` instead, wherever it happens to fall in the visible
  window (not always last, now that you can navigate into any existing
  line). This is what `basic/` uses `kernel/editor`'s
  `EDITOR_REDRAW_HOOK` for. Also relies on `kernel/graphics`'s
  `GFX_PUTCHAR_BOLD` (synthesizes bold by ORing each scanline with
  itself shifted right — verified numerically against representative
  font bytes before writing the assembly). **The program view now only
  uses rows 0-22** (23 rows, not 24) — row 23 is reserved for the
  status line below, and the scroll-window math in `BASIC_HANDLE_NAV`
  was updated to match (23-row window, landing row 22 when scrolling).
- **`BASIC_DRAW_STATUS_LINE`** — renders row 23 in **static** inverse
  video (`kernel/graphics`'s `GFX_INVERT_ATTR_STATIC`, not
  `GFX_INVERT_ATTR` — the latter is built for the blinking cursor and
  was used here by mistake at first, making the whole status bar blink
  too; see the "Bugs caught" note in `kernel/graphics`'s section),
  showing `NEW LINE` (on the sentinel) or `LINE n/m` (1-based index of
  the statement being edited, out of how many exist). Requested
  directly, from a "what would help while editing" suggestion. Builds
  the combined text piece by piece in `STATUS_BUF` via `.append_str`,
  tracking the write position in memory (`STATUS_WRITE_PTR`) rather
  than a register — `BASIC_NUM_TO_STRING` destroys `DE` on every call,
  so nothing spanning two conversions can live in a register here.
  Disappears during `RUN` for free: `BASIC_RUN` does its own `GFX_CLS`
  and never calls this routine at all, since it's a completely separate
  render path — nothing needed to explicitly hide it. Deliberately
  doesn't show free RAM yet: `BASIC_NUM_TO_STRING` is signed, and free
  RAM (`PROG_AREA_MAX - PROG_END`) would very likely exceed the signed
  range and display as a negative number — needs its own unsigned
  conversion before it's added, not folded into this pass.

  **Normal-status work cache (2026-08-27):** a deterministic path audit
  found that every cursor-only redraw rebuilt an unchanged `LINE n/m` by
  walking the complete statement list and performing two decimal conversions;
  only the final screen-text comparison avoided the physical redraw. The
  normal line path now recognizes an already displayed `LINE` status and the
  same `CUR_EDIT_INDEX`, returning before that work. It reuses
  `STATUS_TOTAL_TMP` as the between-redraw index key, costs no RAM, and still
  falls through to the existing final string comparison on every miss.
  Structural changes invalidate `LAST_STATUS_TEXT`, while append advances the
  index, so program-size changes cannot produce a false hit. Measured ROM cost:
  31 Home bytes (138 -> 107 free). Full 63-case Fuse suite remained green.

- **Cursor-only redraw fast path (2026-08-27):** LEFT/RIGHT previously called
  the same complete redraw hook as a text edit. A path audit showed that each
  cursor key therefore performed scroll-fit calculation, a visible-program
  walk, settled-row detokenization/shadow checks, active-line clear/reprint,
  wrap recomputation, cursor drawing, and status evaluation even though only
  the cursor offset changed. The canonical EXROM editor now maps the old
  cursor through the already-current wrap table, restores that one attribute
  cell directly (including clearing FLASH), moves the offset, maps the new
  cell, and draws the cursor there. Text edits and vertical/structural
  navigation still use the full redraw path. Cost: 42 EXROM bytes, no Home or
  RAM bytes; measured margin is Home 107 / EXROM 422 bytes free. Static and
  build checks pass, the full 63-case Fuse suite remains green, and direct
  LEFT/RIGHT movement across a wrapped line was manually user-confirmed on
  2026-08-27 with no stale cursor, wrapping, or redraw problem observed.

### Explicitly not implemented yet

`REPeat`/`SELect`/`DEFine PROCedure`/`FuNction`/`WHEN ERRor`, string
arrays, multidimensional arrays, and the remaining deliberately deferred
items in `docs/basic_language_reference.md`. `GOSUB`/`RETURN`, `FOR`/`NEXT`,
multi-statement `:` lines, numeric arrays, and scalar string variables are
implemented.

**Runtime error reporting exists now**, split into two deliberately
separate steps: detecting a problem (`BASIC_SET_PENDING_ERROR`,
records a message in `PENDING_ERROR_MSG` — "first error wins," an
outer, more generic failure never overwrites a more specific one
already recorded deeper in the call chain) and displaying it
(`BASIC_REPORT_ERROR`, called from exactly one place — `BASIC_RUN`'s
loop, once, after a statement returns carry set and
`PENDING_ERROR_MSG` is nonzero — rather than from each of the four
individual failure points directly, which is how the first version of
this was built). `BASIC_RUN`'s own carry-set-stops-the-loop mechanism
is unchanged (`END`/`STOP` still work exactly as before, no error
message shown since nothing sets `PENDING_ERROR_MSG` for those);
what's new is that detection and display can now happen at different
times, by different callers.

This split exists specifically so a future whole-program static check
pass can reuse the exact same detection logic — walking every
statement and recording every problem it finds via
`BASIC_SET_PENDING_ERROR`-style calls — without displaying anything or
halting on the first one, which the original design (display
immediately, inline, at the point of failure) couldn't support at all.
Real execution's observable behavior is unchanged by this
restructuring — same messages, same statement shown, same halt
behavior — confirmed by re-tracing both the plain-stop and genuine-
error paths through the new code before trusting it.

`BASIC_REPORT_ERROR` shows a message via the row-23 status line
(`BASIC_PRINT_STATUS_TEXT` — see "Unified runtime error display" below
for the 2026-08-22 rewrite that moved it off its original row-0/row-1
full-screen design). `CUR_EXEC_STMT` (set by `BASIC_RUN` at the top of
every loop iteration) is what lets it show the right statement
regardless of how deep in the call chain the failure was discovered —
`GOTO`'s label lookup and the expression evaluator buried inside
`PRINT`/assignment don't otherwise have any way to know which top-level
statement they're being called on behalf of.

Three messages so far: `SYNTAX ERROR` (an unrecognized statement, a
malformed expression in `PRINT` or assignment, or `GOTO` with no label
name at all), `LABEL NOT FOUND` (`GOTO` to a name that doesn't exist),
and `DIVISION BY ZERO` (checked directly in the expression evaluator's
divide case, before ever calling `kernel/math`'s
`MATH_DIVIDE16` — that routine's own safe default is to silently
return `0` for a zero divisor, appropriate for a generic kernel
routine with no caller context, but `basic/` can and does better with
an actual error here). Not a larger taxonomy beyond these three yet —
each was added for a concrete case the codebase already had a gap for,
not invented ahead of one.

**A real bug shipped in the first version of this and was caught from
a screenshot on first use**: `BASIC_REPORT_ERROR` displayed `GOTO
NOWHERE` correctly on row 1 (proving `CUR_EXEC_STMT`'s detokenizing was
fine) but showed a single garbage character instead of `LABEL NOT
FOUND` on row 0. Cause: the caller sets `HL` to the message pointer
before calling this routine, but the routine's own first action was
`call GFX_CLS` — which destroys `HL`, per its own documented contract
— before ever using it, so `GFX_PRINT_STRING` printed whatever `GFX_CLS`
happened to leave in `HL` instead of the intended message. The exact
register-survival mistake this project has hit many times before (see
the "Recurring bug patterns" note in this project's own working
memory), made again here despite this being the very routine meant to
help catch that class of thing elsewhere. Fixed by stashing the
message pointer into memory (`ERR_MSG_PTR`) before calling `GFX_CLS`,
reloading it right before it's actually needed — the row-1 detokenize
step was never affected, since it reads `CUR_EXEC_STMT` fresh from
memory rather than depending on the caller's `HL` surviving anything.

**A second, unrelated real bug surfaced from the same test**: after
that fix, the user listed the program afterward and noticed `GOTO
nowhere` had permanently become `GOTO NOWHERE` in the STORED PROGRAM,
not just on the error display. Cause: `BASIC_PARSE_IDENTIFIER`
originally uppercased the identifier IN PLACE in the source text
(needed for case-insensitive label matching), which meant every time a
`GOTO` executed, it silently rewrote its own label reference in
storage — inconsistent with how this project normalizes everything
else (keywords only get uppercased once, at commit time, never as a
side effect of running). Fixed by having it copy an uppercased version
into `DETOK_BUF` (reused as scratch space — already 128 bytes, and
never in use at the same moment identifier parsing happens) instead of
writing back to the source at all; `MEM_LABEL_ADD`/`LOOKUP` only care
about the bytes at the `HL` they're given, not where those bytes
physically live, so this required no changes to any of the three
callers. A dedicated 32-byte buffer was tried first and found to
collide with `PROG_AREA_START` — only 14 bytes were actually free at
that point in the sysvar range, caught by a full systematic overlap
check across every sysvar before trusting the fix.

This surfaced a real design question worth being explicit about:
`BASIC_EXEC_STATEMENT`'s "unrecognized statement" fallback used to
silently no-op for EVERYTHING that didn't match a keyword or
assignment — including every label definition, since a label like
`loop:` doesn't match any of those either. Making that fallback report
an error instead would have broken every label. Fixed with
`BASIC_IS_LABEL_DEFINITION` (the same identifier-then-`:`-then-end-of-
statement pattern `BASIC_SCAN_LABELS` already uses to build the table,
kept as its own small check rather than refactored to share code with
that already-working routine): checked before reporting an error, so
a legitimate label keeps no-opping exactly as before, and only
genuine garbage gets reported.

**Labels and `GOTO` exist now.** A label definition is a statement
that's ENTIRELY a bare identifier followed by `:` — `loop:`, nothing
else on that line. `GOTO <label>` jumps there; both label names and
`GOTO` references are case-insensitive (`BASIC_PARSE_IDENTIFIER`
copies an uppercased version into scratch space as it scans — never
mutating the source itself, see the bug entry above for why —
matching the same case-insensitive convention as keywords).
`BASIC_SCAN_LABELS` rebuilds the WHOLE label table fresh at the start
of every `RUN` — not maintained incrementally as the program is
edited. Deliberate: labels can appear anywhere, and the editor already
supports inserting/deleting/replacing any line, so keeping positions
correct incrementally through arbitrary edits would be real
synchronization complexity for a program small enough that a full
rescan is imperceptible; also means forward references (`GOTO`
targeting a label defined later in the program) work correctly, since
the complete table exists before any statement executes. Uses the new
`MEM_LABEL_TABLE_CLEAR` (extracted out of `MEM_INIT`, which still calls
it) rather than full `MEM_INIT`, so only the label table resets, not
the program itself.

A label's recorded position is the label statement's OWN position, not
the statement after it — deliberately, so `BASIC_EXEC_STATEMENT`'s
existing "unrecognized statement, silently skip" fallback doubles as
the label's own no-op execution. `GOTO` jumps there, that statement
no-ops, `BASIC_RUN`'s loop naturally continues to whatever follows —
no new execution path needed for labels at all. `BASIC_RUN` itself
gained a `GOTO_TARGET` check after every statement: if a `GOTO` fired
during that statement, jump there instead of advancing sequentially
via `MEM_LINE_NEXT`.

**A whole-program static check pass now runs before every `RUN`.**
`BASIC_CHECK_PROGRAM` walks every statement once — unlike real
execution, it never stops early and never follows a `GOTO`; it checks
every statement in program order regardless of whether execution would
ever actually reach it. If it finds any problems, `BASIC_RUN` simply
returns without running anything — `CHECK_ERROR_COUNT` is already set,
and `BASIC_DRAW_STATUS_LINE` picks it up on the very next redraw, back
in the normal editor view, showing `N ERRORS FOUND` (or the
grammatically-correct singular `1 ERROR FOUND`) in place of the usual
`LINE n/m`. A clean program falls through to real execution exactly as
before — this was confirmed by hand-tracing both outcomes against the
final code before trusting it, given how much of `BASIC_RUN`'s
already-tested logic this touches.

**This replaced an earlier version that used `BASIC_REPORT_ERROR`'s
full-screen display instead** — changed after direct feedback, and for
good reason: a full-screen takeover blocks the rest of the program
from view, which defeats the whole point once red-highlighted error
lines and `SYMBOL SHIFT+A`/`SYMBOL SHIFT+S` navigation exist (both
still planned) — browsing between multiple problems requires seeing the
whole program and the current error status at the same time, which a
full-screen message can never support. `BASIC_REPORT_ERROR` itself
carried the same full-screen design for runtime errors until 2026-08-22
(see "Unified runtime error display" below) — the two paths' displays
started out genuinely different, not just described inconsistently.
The message stays visible while
browsing (`CHECK_ERROR_COUNT` isn't touched by navigation) and only
clears on the next successful commit (`BASIC_COMMAND_LOOP` resets it
to `0` right after tokenizing, before either commit branch — a fresh
edit means the previous check result is no longer trustworthy).
`BASIC_COMMAND_LOOP` also initializes it to `0` at cold start, and
skips the usual post-`RUN` "pause for a keypress" step specifically
when the check failed, since `BASIC_RUN` returned immediately without
displaying anything — nothing to pause and read, and waiting on a
blank screen for no reason would be a regression, not padding.

This exists specifically because the error-detection/display split
described above was built for it: `BASIC_CHECK_STATEMENT` mirrors
`BASIC_EXEC_STATEMENT`'s own dispatch structure closely (same keyword
checks, same order) and reuses the exact same validation primitives —
`BASIC_MATCH_KEYWORD_BOUNDARY`, `BASIC_EVAL_EXPR`,
`BASIC_PARSE_IDENTIFIER`, `MEM_LABEL_LOOKUP`,
`BASIC_IS_LABEL_DEFINITION`, `BASIC_SET_PENDING_ERROR` — every one of
which is already side-effect-free by nature. The only genuinely new
code is stopping short of each statement type's side-effecting final
step: `BASIC_CHECK_ASSIGNMENT` mirrors `BASIC_TRY_ASSIGNMENT`'s
recognition logic but never writes to a variable;
`BASIC_STMT_PRINT`/`GOTO`'s checks are reused as-is but their display/
jump steps are simply never reached, since `.check_print`/`.check_goto`
stop after validating; `INPUT`'s check just confirms a valid variable
letter follows, without ever waiting for a keypress — a check pass
that blocked on keyboard input would defeat the entire point of being
passive. `PENDING_ERROR_MSG` is reset before EACH statement checked,
not once for the whole pass, since the check pass needs a fresh answer
to "what went wrong here" for every single statement, not just the
first one found across the whole program — `CHECK_ERROR_COUNT` and
`CHECK_FIRST_ERROR_STMT` are what accumulate across the whole scan.

**Not exhaustive, deliberately.** Most things are genuinely checkable
without running anything — an unrecognized statement, a malformed
expression, a `GOTO` target that doesn't exist. But something like
`PRINT x/y` can't be statically flagged as division by zero unless `y`
happens to be a literal `0` — a static pass has no way to know what a
variable will hold at any given moment without actually running the
program. The existing per-statement runtime check (inside the
expression evaluator's own divide case) still catches that when real
execution reaches it; the static pass simply can't promise to catch
everything a full run eventually would.

**Red-highlighted error lines exist now, moved to the status bar
instead of a full-screen display first** (see "First slice" note
below — this and that redesign are the same feature, built in stages).
`BASIC_CHECK_PROGRAM` now populates `CHECK_ERROR_LIST` (up to 16
positions, not just the first) alongside `CHECK_ERROR_COUNT`.
`BASIC_REDRAW_PROGRAM` checks each settled statement it renders
against that list via `BASIC_IS_ERROR_STATEMENT`, and — if flagged —
colors that row's ink red (`GFX_SET_ATTR`, a new, deliberately general
primitive: sets a cell's attribute outright, unlike
`GFX_INVERT_ATTR`/`STATIC`, which swap relative to whatever's already
there) after the normal highlighted print completes, not instead of
it. Recognized keywords stay bold within the red row — bold lives
entirely in the bitmap/glyph shape (`GFX_PUTCHAR_BOLD`), color is a
completely separate attribute byte, so there's no interaction between
the two to worry about.

16 is a deliberate cap on the list, not a discovered limit — a
hobbyist BASIC program with more than 16 simultaneous syntax errors is
an extreme edge case. Entries beyond the 16th still count toward
`CHECK_ERROR_COUNT` (so `"N ERRORS FOUND"` in the status bar stays
accurate) but won't get individually highlighted.

**A real, confirmed bug, found from screenshots after real testing:
`HL` (the statement position) was never saved across the red-coloring
loop.** `GFX_SET_ATTR` destroys `HL` per its own documented contract,
and the loop calls it 32 times (once per column) — so by the time
`.next_statement`'s `MEM_LINE_NEXT` needed `HL` to find the next
statement, it held whatever garbage the last `GFX_SET_ATTR` call left
behind instead. Symptom: the render stopped after the first flagged
line entirely (the cursor landing one row too early, where the second
statement should have rendered), and coloring became inconsistent
across separate redraws — a different statement showing red each
time, depending on what garbage `HL` happened to end up holding.
Exactly this project's own recurring register-survival mistake (see
the "Recurring bug patterns" note in this project's own working
memory), made again in code written after that exact lesson was
already documented. Fixed by saving `HL` before the color-check
section and restoring it right before `MEM_LINE_NEXT` actually needs
it — both the flagged and unflagged paths converge on the same
restore point, so this is one save/restore covering both branches, not
two.

**A real, cascading space problem, fixed by moving a boundary rather
than shrinking the feature.** The error list needs real room — 16
entries × 2 bytes, plus a small search scratch variable — but the
sysvar range had only 8 bytes free before `PROG_AREA_START` at the
time. Rather than cut the list down to something that would fit,
`PROG_AREA_START` itself was moved later (`$6000` → `$6030`), verified
safe first via `grep`: every reference to that boundary anywhere in
the codebase (48 of them) uses the symbolic constant, never a
hardcoded `$6000`, so nothing else needed to change. A full systematic
sysvar overlap check confirmed the final layout was clean before
trusting it, given how close an earlier near-miss on this exact kind
of check had come.

`BASIC_IS_ERROR_STATEMENT`'s linear search was verified via a Python
simulation of the exact planned search loop (found, not-found, empty-
list, and single-entry cases) before writing it in Z80 — same
discipline as this project's other tricky logic.

**`SYMBOL SHIFT+A`/`SYMBOL SHIFT+S` error navigation exists now.**
`A` jumps to the next flagged statement, `S` to the previous, wrapping
around at either end. Row 1 of `SYMBOL SHIFT`'s table (`A`-`G`) gives
keyword tokens on real hardware and was otherwise deliberately left
unmapped in this project — genuinely free real estate, detected the
same early-check way `CAPS SHIFT+ENTER` already is, before the generic
masked-scan mechanism (see `kernel/io`'s own header for why that row
is unmapped elsewhere). Two new pseudo-directions,
`EDIR_NEXT_ERROR`/`EDIR_PREV_ERROR`, route through `kernel/editor`'s
existing `EDITOR_NAV_HOOK` mechanism exactly the way
`EDIR_INSERT_LINE`/`DELETE_LINE` already do — no new dispatch pattern
invented, just two more cases through the same one.

`BASIC_FIND_NEXT_ERROR`/`BASIC_FIND_PREV_ERROR` search
`CHECK_ERROR_LIST`, which is already in ascending program order (the
check pass appends each error as it walks the program sequentially) —
"next" is the smallest entry strictly greater than `CUR_EDIT_POS`,
"previous" the largest strictly less, each wrapping to the opposite
end when nothing qualifies. Landing on the sentinel and pressing
`SYMBOL SHIFT+A` naturally wraps to the first error without any
special-casing: the sentinel position ($FFFF) is greater than every
real statement position, so nothing in the list is ever "greater than"
it, which falls straight through to the wrap case on its own.
`BASIC_FIND_INDEX_OF_POSITION` (the reverse of
`BASIC_FIND_STATEMENT_AT_INDEX`) converts the found position back into
the index the existing load/scroll logic in `BASIC_HANDLE_NAV` needs —
all three search-and-convert routines were hand-traced against
concrete 2-entry cases (direct match and wrap-around) before being
trusted, then wired to reuse `BASIC_HANDLE_NAV`'s existing `.loaded`
tail rather than duplicating any of its load-or-scroll logic.

**The status bar shows each flagged line's specific message now**,
not just the overall count. `BASIC_DRAW_STATUS_LINE` checks whether
`CUR_EDIT_POS` is currently one of the flagged positions (via
`BASIC_IS_ERROR_STATEMENT`, the same routine the red-highlighting
logic already uses) and, if so, re-runs `BASIC_CHECK_STATEMENT` on
just that one statement to recover its specific message (`SYNTAX
ERROR`, `LABEL NOT FOUND`, etc.), falling back to the generic `N
ERRORS FOUND` otherwise. Deliberately recomputed on demand rather than
stored alongside every entry in `CHECK_ERROR_LIST` — that would have
meant doubling every entry's size (position + message pointer) purely
to cache something `BASIC_CHECK_STATEMENT` already computes for free,
since it's fully side-effect-free by design and safe to call
repeatedly. Hand-traced against all four reachable cases (cursor on
`GOTO nowhere`, on `qqq`, on the sentinel, and — for completeness — on
a valid, unflagged line) before trusting it.

**Still open, discussed directly with the user**: running this same
check automatically on every commit (`ENTER`), not just at `RUN` —
reusing this exact same `BASIC_CHECK_PROGRAM`/`BASIC_CHECK_STATEMENT`
pair rather than building a second, separate checker for that.

**A real, severe bug that invalidated an entire round of testing**:
`sjasmplus` refused to assemble at all — `Label not found:
BASIC_HANDLE_NAV.do_next_error` and two similar errors. Cause:
`BLANK_STATEMENT` (used by `EDIR_INSERT_LINE`'s handler, well before
any of the error-navigation code) was a GLOBAL label — no leading dot
— sitting in the middle of what was meant to be one continuous local
scope for `BASIC_HANDLE_NAV`. `sjasmplus` scopes local labels to the
nearest PRECEDING global label, so every local label defined after it
(`.do_next_error`, `.do_prev_error`, `.goto_error_position`, and
more) silently belonged to `BLANK_STATEMENT`'s scope instead of
`BASIC_HANDLE_NAV`'s — with no warning at the point of the mistake,
only once something tried to reference them from
`BASIC_HANDLE_NAV`'s own scope and genuinely couldn't find them.

The real cost: this meant every single test of `SYMBOL SHIFT+A`/`S`
error navigation — including an extended debugging session chasing
what looked like a runtime bug (the program appearing to vanish,
cursor landing in the wrong place) — was run against a stale binary
that had never actually built with this code in it at all. Several
rounds of careful hand-tracing, a temporary key-reassignment
diagnostic, and a border-color instrumentation build all correctly
found nothing wrong with the logic itself, because the logic being
investigated was never the logic that was running. Fixed by making
`BLANK_STATEMENT` local (`.blank_statement`) — it was only ever
referenced from within `BASIC_HANDLE_NAV` to begin with, so nothing
outside needed to change. Verified with a purpose-built scope checker
(walks every `jr`/`jp`/`call` reference to a local label and confirms
it resolves within its own enclosing global scope) run across all
three files touched this session (`basic.asm`, `editor.asm`,
`io.asm`) — zero other instances found.

The lesson generalized: any bare (non-dotted) label — even pure data,
like this one — silently ends local-label scoping for everything
after it in the same file, whether or not that was the intent. Worth
double-checking after future large insertions into an existing
routine's local scope, and worth treating "assembles cleanly" as a
prerequisite that gets re-verified, not assumed, whenever a debugging
session runs long enough that a rebuild step could plausibly have been
skipped along the way.

**A second real bug, found once the build actually assembled and ran
for the first time**: `BASIC_FIND_INDEX_OF_POSITION` returned garbage
instead of the correct index — confirmed via a diagnostic build
printing the actual values on screen (a correctly-found position,
$603F, going in; 24646/$6046 — nowhere near a valid index — coming
back out). Cause: `MEM_LINE_NEXT` destroys `DE` per its own documented
contract — this project's own previously-documented, recurring
register-survival lesson (see "Recurring bug patterns" in this
project's own working memory) — but the loop restored `DE` (the index
counter) from the stack *before* calling `MEM_LINE_NEXT`, not *after*,
so the call clobbered the counter and the following `inc de`
incremented garbage instead of the real count. An earlier hand-trace
of this exact routine had incorrectly assumed `DE` survived the call
without ever checking `MEM_LINE_NEXT`'s own destroys-list against it —
several rounds of re-tracing all repeated the same unstated
assumption, which is exactly why a diagnostic showing the real,
concrete values was what actually found it, not more code reading.
Fixed by pushing `DE` again immediately before the call and popping it
back immediately after — the same protection `HL` already had in this
routine, and the same pattern `BASIC_REDRAW_PROGRAM`'s own
`.skip_to_view_top` loop already uses correctly nearby, confirmed by a
systematic check of every other `MEM_LINE_FIRST`/`NEXT` call site in
`basic.asm` (14 in total) before trusting this was the only instance.

**A real, pre-existing bug found and fixed while building this**:
`BASIC_MATCH_KEYWORD` has no boundary check at all — it reports
success as soon as a reference keyword's letters match, regardless of
what follows. `"PRINTER"` typed as a statement matched `KW_PRINT` (5
letters), leaving `"ER"` as `PRINT`'s argument — which happened to
parse as a harmless-looking `PRINT E` (a valid single-letter variable),
silently ignoring the trailing `R`, rather than being rejected as
unrecognized. This existed before labels, but labels made it far more
likely to actually matter: a label named `goto` (as `goto:`) would be
caught by the `GOTO` dispatch itself, since user-chosen multi-character
names collide with keyword prefixes far more easily than anything that
existed in this language before. Fixed with a new
`BASIC_MATCH_KEYWORD_BOUNDARY` (requires `$0D` or space right after
the matched letters — the tokenized/executed-statement equivalent of
`BASIC_TRY_DETECT_ONE`'s own boundary check, which operates on
null-terminated `EDIT_LINE_BUF` instead and was already safe), wired
into all five of `BASIC_EXEC_STATEMENT`'s keyword checks, not just the
new `GOTO` one.

**Arithmetic expressions exist now** — `BASIC_EVAL_EXPR` and its three
supporting levels (`BASIC_EVAL_TERM`/`FACTOR`/`PRIMARY`), a classic
recursive-descent, precedence-climbing evaluator:
```
expression := term (('+'|'-') term)*
term       := factor (('*'|'/') factor)*
factor     := ['-'] primary
primary    := NUMBER | VARIABLE | '(' expression ')'
```
`BASIC_EVAL_EXPR` is a drop-in replacement for `BASIC_PARSE_NUMBER`
wherever a value needs parsing — same `HL`-in/`HL`-out/`DE`-out/
carry-on-fail contract, just understanding the whole grammar above
instead of a bare literal. Wired into both `BASIC_TRY_ASSIGNMENT`
(`x = y + 1`, `x = 2*(3+4)`, not just a literal anymore) and
`BASIC_STMT_PRINT` (`PRINT x+1` now works the same way `PRINT x`
always did — a bare variable is just a primary with no operators, so
the old narrower "single variable only" case is naturally subsumed
rather than kept as a separate path). Multiplication and division use
`kernel/math`'s `MATH_MULTIPLY16`/`MATH_DIVIDE16` (see that module's
own section).

Internally, `EXPR_PARSE_PTR` (memory, not a register) tracks the
current parse position, deliberately shared across recursion levels —
a parenthesized sub-expression recursively calls `BASIC_EVAL_EXPR`
again, and that inner call needs to advance the SAME ongoing position
so the outer call sees where it left off when it returns. `HL` isn't
used as the working parse pointer the way `BASIC_PARSE_NUMBER` does,
because `HL` is needed as a genuine value register during arithmetic
(both operands of `+`/`-` pass through it) — fighting over `HL`
between "current parse position" and "operand being computed" across
recursive calls is exactly the kind of register-survival bug this
project has been bitten by more than once already (see the multiple
`DE`-clobbering entries in the navigation work above). Hand-traced
against `"3+4*2"` end to end before being trusted — confirms `*`
correctly binds tighter than `+`, giving `11`, not the wrong
left-to-right `14`.

**Navigation, deletion, and insertion all exist now** (see
`BASIC_HANDLE_NAV` above) — `UP`/`DOWN` move between existing lines,
editing and committing a change replaces that line in place, `DELETE`
on an already-empty existing line removes it outright, `CAPS SHIFT+ENTER`
inserts a blank line before the one being edited, and the view scrolls
once the program exceeds 23 lines (row 23 is reserved for the status
line). This is also the largest, most interdependent set of changes
made to `basic/basic.asm` in this project so far — flagged as
genuinely higher risk of a bug surfacing in testing than the smaller,
individually-verified pieces around it, not implied to be equally
solid just because it's written down.

- **`MEM_LINE_INSERT`** (`kernel/memory`) — the primitive that made
  mid-program insertion possible. `MEM_LINE_STORE` always treats its
  target position as "the old statement to replace," which isn't what
  inserting *without* removing anything needs; this new routine is
  built on the already-tested `MEM_SHIFT_UP` instead, computing how
  much of the program needs to shift later and copying the new
  statement into the gap that opens up. Hand-traced against a concrete
  3-statement scenario, and has its own regression test
  (`TEST_MEM_LINE_INSERT` in `rom/test_memory.asm`) verifying the full
  resulting byte layout, not just `PROG_END`.
- **`KEY_INSERT_LINE`** (`CAPS SHIFT+ENTER`) — a project-specific combo.
  Unlike the digit-row combos elsewhere in `kernel/io` (which DO have
  documented real-hardware meanings this project deliberately doesn't
  implement — EDIT, GRAPHICS, etc.), this specific combination hasn't
  been independently verified against real hardware docs either way;
  not claimed to be confirmed unused, just that this project isn't
  trying to replicate original hardware behavior for it regardless.
  Originally `CAPS SHIFT+9`, changed after direct feedback — swapping
  it was a small, contained change (just the row/bit checked in
  `kernel/io`), confirming the layering is working as intended: the
  key binding itself was never baked into `basic/`'s logic. Routed
  through `kernel/editor`'s existing `EDITOR_NAV_HOOK` mechanism via
  two new pseudo-directions (`EDIR_DELETE_LINE`, `EDIR_INSERT_LINE`)
  that — unlike `EDIR_UP`/`EDIR_DOWN`, which `EDITOR_MOVE_CURSOR`
  genuinely implements — have no built-in kernel/editor meaning at all
  and simply no-op if no hook is set.
- **Delete-on-empty** — no new key needed. `EDITOR_LOOP` checks whether
  `EDIT_LINE_BUF` is already empty before calling `EDITOR_BACKSPACE`;
  if so, it routes `EDIR_DELETE_LINE` through the hook instead (there's
  nothing left to backspace character-by-character anyway). `basic/`'s
  handler is a no-op if you're on the new-line sentinel — only a real
  existing line can be deleted this way.
- **`KEY_DELETE_LINE`** (`CAPS SHIFT+1`) — a second, more direct route
  to the exact same `EDIR_DELETE_LINE` hook, added so deleting a line
  doesn't require emptying it first. Real hardware gives this combo
  EDIT, not implemented here — repurposed the same way
  `KEY_INSERT_LINE` above is. `kernel/io` detects it alongside the
  other digit-row combos (`kernel/io/io.asm`'s `IO_READ_KEY`);
  `kernel/editor`'s `EDITOR_LOOP` dispatches it straight to
  `EDIR_DELETE_LINE` with no buffer check, unlike the delete-on-empty
  path above. `basic/`'s `BASIC_HANDLE_NAV` needed no changes at all —
  `.do_delete_line` already operates on `CUR_EDIT_POS` directly and
  has never cared what triggered it.
- Both new handlers in `BASIC_HANDLE_NAV` reuse its existing
  `.existing_line`/`.loaded` tail (finding/loading the resulting
  target and adjusting scroll) rather than duplicating that logic —
  delete just needs `CUR_EDIT_INDEX` to land on whatever now occupies
  that index (or the sentinel, if the last statement was removed);
  insert needs `CUR_EDIT_POS`/`CUR_EDIT_INDEX` to point at the new
  blank line, which are already correct without recomputation, since
  that's exactly where the insert happened.

### Unified runtime error display (2026-08-22)

`BASIC_REPORT_ERROR` (runtime errors — `DIVISION BY ZERO`, `LABEL NOT
FOUND`, `RETURN WITHOUT GOSUB`, `SUBSCRIPT OUT OF RANGE`, etc., plus
`BREAK`) used to own its display outright: `GFX_CLS`, the message on
row 0 in static inverse video, the failing statement's detokenized
text on row 1 below it. Check-time errors moved off that same design
onto the status bar back when red-highlighted error lines were built
(see the note above — "changed after direct feedback... a full-screen
takeover blocks the rest of the program from view"), but runtime
errors were deliberately left on the old design at the time, since a
check-time error always happens with the editor's own listing already
on screen (row 23 is reserved there specifically), while a runtime
error can happen with *anything* on screen — mid-`PRINT` output, a
half-drawn graphic, any cursor position — and there was no established
"safe" content-preserving display for that case yet.

Reconsidered and changed after a direct discussion with the user: a
runtime error's own full-screen wipe was actually throwing away
exactly the context most useful for debugging — whatever the program
had already printed right up to the point it failed. The fix reuses
`BASIC_DRAW_STATUS_LINE`'s own row-23 rendering rather than
reinventing it: that routine's previously-internal `.print_status`
tail (clear only row 23's bitmap, print, set the inverted attribute,
draw the branding swatch — all without touching rows 0-22) was
promoted to a real global entry point, `BASIC_PRINT_STATUS_TEXT` (In:
`HL` = message). `BASIC_REPORT_ERROR` now builds `"<message> IN:
<statement>"` into `STATUS_BUF` via `BASIC_APPEND_STR` and hands it to
that routine directly — no `GFX_CLS` at all.

**A real, latent overflow risk found while making this change, fixed
before it could ever actually happen.** `BASIC_APPEND_STR` had no
length cap — every caller before this (a handful of digits, short
fixed text for "LINE n/m"/"N ERRORS FOUND") happened to stay far under
`STATUS_BUF`'s real 32-byte size, so nothing before now could have
triggered a real overrun. A detokenized program statement is neither
short nor bounded — an unluckily long one would have walked straight
past `STATUS_BUF`, into `STATUS_WRITE_PTR`, and into whatever sysvar
sits after it. Fixed by giving `BASIC_APPEND_STR` a real budget:
capped at `STATUS_BUF + 28` (leaving the branding swatch's own
reserved columns 29-31 alone), computed once per call via `SBC
HL,DE` against the current write position, silently truncating rather
than erroring — matching this project's own established "truncate,
don't error" precedent for an over-length destination (`BASIC_EVAL_
STR_PRIMARY`'s literal-copy path uses the same idea).

Verified live in the emulator with a genuinely runtime-only error
(`RETURN` with no matching `GOSUB` — the checker has no call-stack
state, so this can't be caught statically, unlike most of the
three-message list `BASIC_REPORT_ERROR` started with): `PRINT
"BEFORE"` followed by a bare `RETURN` produced `RETURN WITHOUT GOSUB
IN: RET` on row 23, inverted, with the branding swatch intact — and
`BEFORE`'s own output stayed visible in the top-left corner,
confirming no screen clear happened. (`RETURN` detokenizes as `RET`
here — a pre-existing detokenizer abbreviation, unrelated to this
change.)

**A related, separate finding surfaced while building a first test
case for this, not yet acted on — flagged for discussion rather than
fixed here.** The "a static pass can't flag `PRINT x/y` as division by
zero unless `y` is a literal `0`" claim earlier in this doc describes
the *intended* limitation, but the real checker can still produce a
false-positive `DIVISION BY ZERO` at check time for code that would
run fine: `BASIC_CHECK_ASSIGNMENT` mirrors `BASIC_TRY_ASSIGNMENT`'s
recognition logic but never writes the result, yet still calls the
same `BASIC_EVAL_EXPR` real execution uses to validate an RHS
expression's grammar — and that routine actually computes the value,
divide included, using whatever's currently in `VAR_TABLE` (cold-boot
zero for anything not yet assigned in THIS check pass, since earlier
statements' own assignments were validated but never committed). A
program that assigns `Y` before ever computing `X/Y` fails the static
check anyway, purely because the check pass evaluates statements
without their preceding writes actually landing. Confirmed directly:
`X=1: Y=0: Z=X/Y` failed the whole-program check (border showed
yellow, this project's own "check failed" signal) even though the
same program runs to completion at `RUN` time with no error at all if
`Y` is later reassigned to something nonzero before the divide — the
check pass and real execution can disagree. Root cause is the same
"checker executes expressions for real" class this project has hit
before, not something newly introduced here.

### Bugs caught before shipping (worth recording)

- **`BASIC_COMMAND_LOOP` called `EDITOR_INIT` only once**, implicitly
  via the test file's `COLD_START`, not on every loop iteration.
  `EDITOR_INIT` is what resets `EDIT_LINE_BUF` and the cursor to
  empty — without calling it again before each new `EDITOR_ENTER`
  session, every command after the first one started with the
  *previous* line's content still sitting in the buffer. The visible
  symptom was confusing: after typing `x=5` and pressing ENTER, the
  screen kept showing `x=5` unchanged, making it look like ENTER
  wasn't registering at all — even though ENTER, storage, and `RUN`
  detection were all working correctly underneath. Diagnosed via a
  screenshot showing the exact same screen before and after an ENTER
  press. Fixed by moving `EDITOR_INIT` into `BASIC_COMMAND_LOOP`
  itself, called at the top of every loop iteration — matching the
  pattern already used for `GFX_CLS` in `BASIC_RUN` (a routine owning
  its own reset rather than trusting a caller to remember it).
- **`BASIC_TRY_ASSIGNMENT` relied on register `C` surviving a call to
  `BASIC_PARSE_NUMBER`**, which uses `C` as its own internal digit-
  count register — documented in `BASIC_PARSE_NUMBER`'s own `Destroys:
  AF, BC, DE, HL` line, which the caller simply didn't check against.
  The exact same category of bug as `GFX_PUTCHAR`'s row-clobbering
  fix above, in a different module: `x=5` was writing `5` into
  whatever garbage address `BASIC_VAR_ADDR` computed from the leftover
  digit count, never into `X`'s real slot — silent, no crash, only
  visible once `PRINT x` read back nothing sensible. `BASIC_STMT_INPUT`
  had already solved this correctly for its own variable letter by
  stashing it in memory (`CUR_VAR_LETTER`, then named `INPUT_VAR`)
  instead of a register; `BASIC_TRY_ASSIGNMENT` just hadn't followed
  the same pattern. Fixed by switching it to the same memory-backed
  approach and renaming the sysvar to reflect it now being shared by
  both.
- **The actual root cause of "PRINT x shows nothing" wasn't either bug
  above** — both were real and worth fixing, but a diagnostic
  (`rom/test_basic_debug.asm`, showing `VAR_TABLE`'s raw value
  independent of `PRINT`) proved storage and display were *both*
  already correct after the `BASIC_TRY_ASSIGNMENT` fix. The real issue:
  `BASIC_COMMAND_LOOP` looped straight back into `EDITOR_INIT`/
  `EDITOR_ENTER` immediately after `RUN` returned, and `EDITOR_ENTER`'s
  first action is `GFX_CLS` — wiping whatever `RUN` had just displayed
  before there was any real chance to read it. `PRINT x` had likely
  been working correctly since the very first fix; the output was just
  never on screen long enough to see, which looked identical to "not
  working" from the outside. This had actually been flagged as a
  "known UX rough edge" in this doc *before* being identified as the
  actual root cause — a good reminder that a documented limitation can
  still be the real bug hiding behind a more dramatic-looking symptom.
  Fixed with `BASIC_WAIT_FOR_KEY`, a press-any-key pause after `RUN`
  before the loop continues.
- **`BASIC_WAIT_FOR_KEY` itself had a real bug of its own (2026-08-21,
  user-reported)**: a program consisting of nothing but a single
  `PRINT` statement appeared not to run at all — `RUN` looked like it
  just silently returned to the program listing, with no visible
  output — but the exact same `PRINT` as the middle statement of a
  `FOR`/`NEXT` loop worked fine. Diagnosed with two fully-automated
  boot-time harnesses (no keypresses needed) rather than by eye:
  `rom/test_print_repro_debug.asm` proved `BASIC_CHECK_STATEMENT_EXROM`
  and `BASIC_RUN` both worked correctly end to end on a hand-encoded
  program (checker passed, `BASIC_OUTPUT_ROW` genuinely advanced,
  meaning `PRINT` really did execute); `rom/
  test_print_repro_interactive.asm` then replicated
  `BASIC_COMMAND_LOOP`'s exact real commit sequence
  (`BASIC_UPPERCASE_KEYWORD_PREFIX` → `BASIC_TOKENIZE_LINE` →
  `MEM_LINE_STORE` → `BASIC_FULL_CHECK_EXROM`) starting from a genuinely
  fresh `MEM_INIT`'d program and confirmed the exact same stored bytes
  and same successful outcome — ruling out the checker, `BASIC_RUN`,
  and the commit path as the cause. That left only the one thing
  neither automated harness could reproduce: real keyboard timing.
  `BASIC_WAIT_FOR_KEY`'s old body went straight to waiting for "any key
  down, then released," with no check that the down-key was a *new*
  press — so the same ENTER keystroke that had just committed `RUN`
  (still physically held down the instant `BASIC_RUN` returns for a
  statement that executes in a fraction of a millisecond, far faster
  than a human can release a key) satisfied the wait immediately, and
  returning that key's own natural release a moment later cleared the
  screen before there was any real chance to read the output. A
  `FOR`/`NEXT` loop simply takes long enough to execute that ENTER is
  already released by the time `BASIC_RUN` returns, so the old code
  happened to work correctly in that case, masking the bug rather than
  avoiding it — the same "documented limitation actually IS the real
  bug" shape as the `BASIC_WAIT_FOR_KEY` bullet just above it. Fixed by
  adding a `.flush` step at the very start that waits for no key to be
  down at all before watching for a genuinely new press-then-release
  cycle. User-confirmed working after the fix.
- **`BASIC_REDRAW_PROGRAM`'s row counter lived in register `B`**,
  clobbered by both `BASIC_PRINT_LINE_HIGHLIGHTED` and `MEM_LINE_NEXT`
  before the loop's own `inc b` ran — the same category of bug as the
  two above, a third time in the same file. Found via a screenshot
  showing a second committed statement's row overlapping the actively-
  typed line after normalizing. Fixed by moving the counter
  (`PROGRAM_ROW`) into memory, reloaded fresh each time it's needed,
  same pattern `BASIC_PRINT_LINE_HIGHLIGHTED`'s own `HILITE_ROW` already
  used for exactly this reason.
- **A community-suggested "streamlined" rewrite of `MEM_LABEL_ADD`'s
  size check inverted the comparison** — verified by tracing concrete
  numbers before accepting it, not adopted. The suggested version
  computed `MAXLEN - projected` then added a `ccf` to flip the carry;
  tracing showed this returns early (as if failed) when an entry
  genuinely fits, and falls through to write past the table boundary
  (real memory corruption) when an entry doesn't fit — backwards in
  both directions. The existing code (`projected - MAXLEN`, checking
  carry directly, no flip needed) was already correct and unchanged.
- **The navigation code's fourth instance of the same register-
  survival category, and the widest-reaching one yet**:
  `BASIC_REDRAW_PROGRAM` loaded `DE = (VIEW_TOP_INDEX)` *before*
  calling `MEM_LINE_FIRST` — but `MEM_LINE_FIRST` sets `DE =
  PROG_AREA_START` internally and never restores it, silently
  overwriting the intended value. For a single-statement program this
  coincidentally still terminated the walk loop, but with `HL = 0` —
  making the redraw believe there was nothing to render at all, even
  though storage was completely correct (confirmed via a diagnostic
  overlay showing `PROG_END`, `CUR_EDIT_INDEX`, etc. were all exactly
  right). Checking further, `MEM_LINE_NEXT` destroys `DE` too — which
  meant `BASIC_COUNT_STATEMENTS` and `BASIC_FIND_STATEMENT_AT_INDEX`
  (used by every single navigation move) had the same root cause in a
  worse form, since `DE` couldn't survive *either* call in those
  routines, not just the first one. All three fixed by moving the
  relevant counter into memory (`COUNT_TMP`, `FIND_REMAINING`) and
  reloading it fresh after each call, rather than trusting a register
  to survive — the same lesson this project keeps re-learning, just
  now confirmed to apply to `kernel/memory`'s iterator specifically,
  not only `kernel/graphics`/`basic/`'s own routines.

### Screen-flicker fix

`BASIC_REDRAW_PROGRAM` used to start with an unconditional `GFX_CLS`
followed by a complete re-render of every visible line — on every
single keystroke, navigation press, or commit, even a single-character
edit. That full-screen wipe-and-redraw was the actual source of
visible flicker, not anything about *how* the editor and display code
were organized (a "display subsystem" was discussed and explicitly
set aside for this reason — see the project's own working memory for
that discussion).

The fix tracks what was actually shown at each of the 24 rows as of
the last redraw — which statement position, and whether it was error-
flagged — in a new shadow state (`ROW_SHADOW_POS`/`ROW_SHADOW_FLAGS`,
`include/sysvars.inc`; `PROG_AREA_START` moved again, `$6030` →
`$6090`, to fit the 73 bytes needed — re-verified safe the same way as
every previous move, via a full codebase grep confirming the boundary
is always used symbolically). `BASIC_ROW_SHADOW_MATCHES` and
`BASIC_UPDATE_ROW_SHADOW` compare and record that state; both verified
against a Python simulation of the exact match/update logic (initial-
state mismatch, flags-only mismatch, position-only mismatch, and the
case a program going from valid to error-flagged actually produces —
same position, different flags) before being written in Z80.

A settled row whose (position, flags) hasn't changed is skipped
entirely now — no clear, no redraw, since it must still look exactly
the same. A row that has changed gets cleared individually
(`GFX_CLEAR_ROW`, new — clears one row's bitmap and attribute without
touching any other row, built on `GFX_PUTCHAR`/`GFX_SET_ATTR` rather
than reimplementing the Spectrum-family interleaved screen addressing
from scratch) before being redrawn. The actively-edited line and the
new/uncommitted sentinel line always redraw regardless of shadow
state — their content can change on every keystroke, so there's
nothing useful to diff against — and get a deliberate sentinel flags
value (`2`, which a real settled-line comparison never stores, since
it only ever holds `0` or `1`) written to their shadow entry, so a
mismatch — and a correct redraw — is guaranteed the moment either one
becomes a settled row later.

If the program just got shorter (a statement was deleted), rows that
had content in the previous redraw but aren't reached by this one need
explicit clearing — nothing else would ever touch them, since the main
render loop simply stops once it runs out of statements.
`LAST_RENDERED_ROWS` tracks how many rows were used last time, and a
cleanup pass at `.render_done` clears the difference; verified via a
Python simulation of the clearing loop (single-row and multi-row
shrink cases, plus the two no-op cases where the count stayed the same
or grew) before being written in Z80.

A real, self-caught near-miss during this work: an early version of
the sysvar layout used a "backward from `PROG_AREA_START`" expression
for two of the new entries, which would have silently overlapped the
one placed first — caught by this project's own established "always
run a full programmatic overlap check before trusting a new layout"
process, before it ever reached the assembler.

**Two real, confirmed bugs found from the user's very first test — a
screenshot of a black screen with just one gray bar at the top on cold
boot.** Removing the per-redraw `GFX_CLS` meant nothing ever
established the normal background color for rows that the render loop
never actually touches — which, at cold boot with an empty program, is
almost the entire screen (only the sentinel line's own row gets
drawn). The leftover-rows cleanup above only ever handles "this row
previously had content and doesn't anymore" — it was never designed
for "this row has never been touched by anything at all," which is
exactly cold boot's own starting condition. Fixed with a single
`GFX_CLS`, run exactly once, in `BASIC_COMMAND_LOOP`'s own one-time
setup, establishing a known-clean starting state before the first
diff-based redraw ever runs.

The same root cause turned out to have a second instance: `BASIC_RUN`
also calls `GFX_CLS` unconditionally, for its own program output — but
never told the shadow state that had happened. Returning to the editor
view afterward, `BASIC_REDRAW_PROGRAM` would see shadow entries that
still matched what was showing *before* that `GFX_CLS`, and
incorrectly skip redrawing rows `RUN`'s own clear had just wiped
blank. Both cases share the same underlying problem — something
outside the diff-aware redraw path wiping the screen without telling
the shadow state — so both share the same fix:
`BASIC_RESET_ROW_SHADOW` (extracted from what was originally inline
code in `BASIC_COMMAND_LOOP`, since local labels can't be called
across routines and `BASIC_RUN` needed the exact same reset) is now
called right after both `GFX_CLS` sites, so the next redraw always
correctly treats every row as changed.

### HELP command

`HELP`, typed at the command line, is recognized in `BASIC_COMMAND_LOOP`
the same way `RUN` is — a prefix match against a keyword string
(`KW_HELP`) followed by a trailing check, rather than a tokenizer
keyword. Unlike `RUN`, the rest of the line is kept as plain text (the
topic name) instead of being rejected outright when something follows.

`HELP` alone lists the available topics. `HELP <name>` (case-
insensitive, matched via the same `BASIC_MATCH_KEYWORD` routine used
for command prefixes, plus a trailing-null check to reject a bare
prefix match such as `HELP EDITORX`) shows that topic's screen; an
unrecognized name falls back to the topic list rather than a separate
error path.

Topics live in `HELP_TOPIC_TABLE` (`basic/basic.asm`) — a small,
static `{name pointer, text pointer}` table ended by a `0` name
pointer, walked in `BASIC_SHOW_HELP`. Adding a topic later means one
new table row plus its text; no tokenizer or dispatch changes needed.
Each topic's text is itself a table of line-string pointers (one per
screen row) ended by a `0` pointer, printed by a small generic loop —
this is what lets a topic have any number of lines without
`BASIC_SHOW_HELP` needing to know the count in advance. Every line is
kept under `GFX_COLS` (32) and restricted to glyphs the font actually
has (no `<`/`>` — see `kernel/graphics`'s punctuation table; `HELP
(TOPIC NAME)` uses parentheses instead).

Display uses the same full-screen-takeover pattern `BASIC_REPORT_ERROR`
used to (that routine moved to the row-23 status line 2026-08-22 — see
"Unified runtime error display" above — but a HELP screen genuinely
needs the whole screen for its own multi-line content, so it keeps its
own separate `GFX_CLS`, unaffected by that change): `GFX_CLS`, print
the static text, `BASIC_WAIT_FOR_KEY`, then
`BASIC_RESET_ROW_SHADOW` before returning — that last call is required
here for the same reason it's required after `RUN`'s own `GFX_CLS`
(see the screen-flicker fix above): without it, the next redraw would
see stale shadow entries claiming rows still show what they did before
this screen's `GFX_CLS` wiped them.

Two scratch sysvars support this (`include/sysvars.inc`, in the 9-byte
margin `LAST_STATUS_TEXT` left before `PROG_AREA_START` — no boundary
move needed): `HELP_PTR` (2 bytes), reused across two non-overlapping
steps — first holding the typed topic text across the table walk,
then the matched topic's line-table pointer across `GFX_CLS` (the
exact same destroys-HL mistake `BASIC_REPORT_ERROR` made once,
documented on `ERR_MSG_PTR`) — and `HELP_ROW` (1 byte), the current
row while the line-printing loop runs, kept in memory since
`GFX_PRINT_STRING` destroys `BC`.

**A real, general leftover-rows bug found from the user's first test of
this feature.** A screenshot showed rows 3-13 of the editor view still
showing the tail of the previous `HELP EDITOR` screen after pressing a
key to return — the committed program (`x=5`, `PRINT x`) and the
active line rendered correctly on rows 0-2, but nothing below that got
cleared. Root cause: `BASIC_RESET_ROW_SHADOW` set `LAST_RENDERED_ROWS`
to 0, and `BASIC_REDRAW_PROGRAM`'s leftover-rows cleanup only clears
rows from the current row count up through `LAST_RENDERED_ROWS - 1` —
with that at 0, the cleanup pass never runs at all. Setting it to 0
was only ever safe when whatever called the reset also cleared the
*entire* screen and drew nothing else on top — true for `BASIC_RUN`'s
`GFX_CLS` only by coincidence in the cases tested so far (its own
program output happened to use as many or more rows than the listing
that followed), but false in general, and definitely false for
`BASIC_SHOW_HELP`, whose whole point is printing real content — up to
14 rows for the EDITOR topic — after its own `GFX_CLS`. Fixed by
setting `LAST_RENDERED_ROWS` to 23 (the full program-display area;
row 23 is always handled separately) instead of 0, so the next
redraw's cleanup pass always clears everything from wherever the new
content stops through row 22, regardless of how many rows the prior
full-screen paint actually used. This closes the same latent bug for
`BASIC_RUN`'s own case too, even though it hadn't visibly surfaced
there yet.

Not yet retested by the user — this is the newest, untested piece in
the project.

### HELP topic expansion, built then reverted the same day (2026-08-23)

Two new topics (`HELP STRING`, `HELP MATH`) plus a `HELP TOPICS` list
screen were built in `HELP_TOPIC_TABLE` (`rom/exrom_help.asm`)
alongside the existing `EDITOR` topic, grouping keywords/functions by
type per the user's own request — confirmed working live in the
emulator (measured EXROM cost: 301 -> 51 bytes free). The user then
asked for HELP to go back to being a single screen: "get rid of the
new help screens and the main help screen - when you type help take
you to the exiting editor help screen." Reverted the same session,
before the multi-topic version had been used for anything else.

`BASIC_SHOW_HELP` (`rom/exrom_help.asm`) is back to the simplest
possible shape: it ignores whatever text (if any) follows the word
HELP and always shows `HELP_TEXT_EDITOR` directly — no topic table, no
`BASIC_MATCH_KEYWORD` lookup, no topic-list fallback. This is actually
simpler than the ORIGINAL single-topic version too (that one still
kept a one-entry `HELP_TOPIC_TABLE` and did a real keyword-match walk
against it before falling back to a topic list) — with only one
possible destination, ever, none of that machinery has a job to do
anymore. Net effect: EXROM ended up with MORE free space after this
revert (449 bytes) than either the original single-topic version (301)
or the reverted multi-topic version (51), since real matching logic
was removed, not just added text.

`tools/check_docs.py`'s HELP-topic-coverage check (`check_help_topics_
documented`) now treats "no `HELP_TOPIC_TABLE` found" as the expected,
N/A case rather than a staleness error — there's no longer a table
for docs to drift out of sync with.

### Multi-keyword bold highlighting (2026-08-23)

`KEYWORD_HILITE_TABLE`-driven bolding used to only ever look at a
line's very first word — `BASIC_DETECT_KEYWORD_PREFIX` set one
`(0, length)` span and the print loop bolded up to that length, full
stop. That's why `INK 7:PAPER 5` only bolded `INK`, and why `THEN` was
deliberately excluded from the table at all (it's never a statement's
first word, so the old mechanism could never have bolded it). The
user asked for this directly: "when there is a ink 7:paper 5... both
ink and paper should be bolded, or in an if then statement both if
and then should be bolded."

**New shape**: `HILITE_KW_COUNT`/`HILITE_KW_START`/`HILITE_KW_SPANLEN`
(`include/sysvars.inc`, `HILITE_KW_MAX_SPANS` = 4) replace the single
`HILITE_KW_LEN`-driven bold check with up to 4 `(start, length)` spans
per line. `HILITE_KW_LEN` itself is untouched — it's still exactly
what `BASIC_TRY_DETECT_ONE`/`BASIC_TRY_DETECT_ENDIF` set as their own
single-match-length output, now just consumed differently by its one
remaining caller.

**`BASIC_DETECT_KEYWORD_PREFIX`** (the print path's own entry point,
called once per settled line per redraw) now walks the whole line one
colon-separated segment at a time: skip leading spaces, try a keyword
match at that exact position, scan to the next unquoted `:` (or the
line's own NUL terminator, honoring REM and quoted strings — see
below), repeat.

**Known gap, confirmed by the user directly (2026-08-23), corrected
here after this doc first overclaimed the opposite**: `THEN` does NOT
bold in `IF x THEN y`. `KW_THEN` was added to `KEYWORD_HILITE_TABLE`
on the mistaken assumption that the new segment scan would reach it —
it doesn't. `IF x THEN y` is a single colon-segment (no `:` in it at
all), and the scan only tries ONE match per segment, at its own start:
it bolds `IF`, then scans forward looking for the next `:`, finds
none, and stops — `THEN`, a second word inside that same segment, is
never attempted at all. `KW_THEN` is consequently dead weight in the
table right now (THEN is never legitimately a segment's own leading
word, so it can never match). This was always the real tradeoff of
picking the cheaper colon-segment-only design over the fuller "any
keyword, anywhere in the line" scanner — that fuller version was
explicitly scoped and declined earlier the same session specifically
because of its larger EXROM cost (see the design discussion above this
section) — not a bug introduced by building the cheaper version, just
a real limitation of it. Catching `THEN` specifically, without building
the full general scanner, would need a small IF-THEN-specific
extension to the segment scan (try one more match right after IF's
own, within the same segment) — not attempted: EXROM had only ~19
bytes free by the time this gap was confirmed, nowhere near enough
room without shrinking something else first. `KW_TO`/`KW_STEP` stay
out of the table entirely, for the same original reason `KW_THEN` once
did (see that table's own header).

**`BASIC_FIND_DISPLAY_STMT_BOUNDARY`** is a new sibling to the
existing `BASIC_FIND_STATEMENT_BOUNDARY` (the colon-splitter the
EXECUTION side already used) — same quote-aware, REM-aware scanning
logic, but for the highlighter's own NUL-terminated display buffers
(`EDIT_LINE_BUF`/`DETOK_BUF`) instead of stored, `$0D`-terminated
statement text. Written as a separate routine rather than
parameterizing the original: that one's own REM pre-check
(`BASIC_MATCH_KEYWORD_BOUNDARY`) is itself hardwired to `$0D` too, and
touching either risked the execution path this project already relies
on everywhere, for a routine small enough that duplicating it was
clearly the lower-risk move.

**The print loop's own bold check** (`BASIC_PRINT_LINE_WRAPPED_COMMON`)
changed from one `cp` against `HILITE_KW_LEN` to a call to
`BASIC_KW_OFFSET_BOLD`, a small new helper that scans the (≤4)
recorded spans for one containing the current character's absolute
offset. Deliberately kept Home-resident and lightweight (preserves
`BC`/`DE`/`HL` itself so the hot per-character loop calling it doesn't
need to) — this runs once per CHARACTER, not once per line, so it's a
genuinely hot path unlike everything else this feature touches.

**Real, measured Home ROM budget problem, found and fixed the same
session, in two passes**: the plain Home-resident version of this
feature cost ~159 bytes, leaving the interactive build only 40 bytes
free — enough for `rom/test_basic.asm` itself to still assemble, but
NOT enough for `tools/preload_gen.py`'s own harness overhead alongside
it, confirmed by a real build failure (`Negative BLOCK moves PC
backwards`, a 21-byte overflow) rather than guessed from the raw
free-byte count alone.

First pass: moved `BASIC_DETECT_KEYWORD_PREFIX`'s segment-loop and
`BASIC_FIND_DISPLAY_STMT_BOUNDARY` to EXROM (`rom/exrom_highlight.asm`,
entry stub `$C090`), but kept the actual `KEYWORD_HILITE_TABLE` WALK
Home-resident — EXROM is a separate compilation unit with no way to
reference that table as a compile-time label (`Label not found:
KEYWORD_HILITE_TABLE`, the exact trap `CALC_EXIT_TRAMPOLINE`'s own
KTAB entry comment already documents), so the first draft called back
into a new Home routine (`BASIC_TRY_MATCH_KEYWORD_HERE`) once per line
segment instead. This raised Home's margin to 112 bytes free — enough
for `rom/test_basic.asm` and small preload programs, but a live rerun
of the FULL `tests/` suite still showed 6 real failures (`cf2`, `cf4`,
`cf6`, `cf7`, `io3`, `arr5` — overflows of 33-42 bytes each, confirmed
via the same real-build-warning method, not guessed from the boundary
tests alone).

Second pass: moved the table walk itself to EXROM too, replacing the
compile-time label reference with a RUNTIME one — `BASIC_DETECT_
KEYWORD_PREFIX` (the Home-side wrapper) now stashes `KEYWORD_HILITE_
TABLE`'s real address into a new sysvar, `HILITE_TABLE_PTR`, on every
call, right before paging in; the EXROM-side walk reads that instead
of a label. `BASIC_TRY_MATCH_KEYWORD_HERE` was deleted outright (its
whole reason for existing was gone), and its KTAB entry was swapped
back to `BASIC_TRY_DETECT_ENDIF` (needed directly by the table walk,
now EXROM-side again) alongside the already-added `BASIC_TRY_DETECT_
ONE` (needed both there and by `BASIC_FIND_DISPLAY_STMT_BOUNDARY`'s
own REM check) — `BASIC_SKIP_SPACES` already had an entry from an
earlier migration. `KTAB_COUNT` 42 -> 44, `KTAB_MAGIC` 12 -> 13 (both
set once, unchanged by the second pass — it only swapped which two
routines occupy the two new slots).

The only Home-resident piece of this whole feature now is the small,
genuinely hot `BASIC_KW_OFFSET_BOLD` helper (called once per
CHARACTER, not once per line, unlike everything else here) plus the
thin wrapper itself.

**Measured final cost**: Home 199 -> 179 bytes free, EXROM 449 -> 285
bytes free (both from the assembler's own listing, not estimated) —
`PROG_AREA_START` moved from `$B75E` to `$B769` (11 bytes, for the new
`HILITE_KW_*`/`HILITE_TABLE_PTR` sysvars) alongside this. Re-confirmed
every previously-overflowing preload harness (`cf2`/`cf4`/`cf6`/`cf7`/
`io3`/`arr5`) now builds with 0 warnings.

**Real bug found and fixed the same day: nothing bolded at all,
despite the feature otherwise working correctly (2026-08-23, user-
reported)**. After the second EXROM migration pass above, EVERY
keyword — including plain single-word cases like `PRINT`/`BORDER`
that had bolded correctly before this feature's own EXROM move — quit
bolding entirely. Commit-time uppercasing (`BASIC_UPPERCASE_KEYWORD_
PREFIX`, unaffected by this migration, still Home-resident and table-
driven the old way) kept working, which is what pointed straight at
the redraw-time table walk rather than `KEYWORD_HILITE_TABLE` itself
or the general detection logic. Root cause: loading `IX` from
`HILITE_TABLE_PTR` was written as `ld hl,(HILITE_TABLE_PTR) / push hl
/ pop ix`, in the mistaken belief that `LD IX,(nn)` isn't a real Z80
instruction (it is — confirmed directly against sjasmplus). That
HL-relay sequence clobbered `HL`, which at that exact point still held
the live TEXT SCAN POSITION that `KTAB_BASIC_TRY_DETECT_ONE` needed as
its own input moments later — so every table-walk attempt ran against
whatever garbage `HILITE_TABLE_PTR`'s own address's contents looked
like as "text" instead of the real line, and consequently never
matched anything, for any keyword, on any line. Fixed by using `LD
IX,(nn)` directly, which loads from memory with no `HL` involvement at
all.

The regression suite (`tests/`, all 38 files, `--autorun`-only) never
had a chance to catch this: those tests skip the interactive editor's
redraw path entirely and go straight to `BASIC_RUN`, so a highlighting-
only bug is invisible to them regardless of how thoroughly they're
re-run — this bug was only found by a human actually looking at
rendered text in the live emulator. Re-verified live afterward:
`PRINT`/`BORDER` (plain single-keyword lines) both bold correctly
again, confirmed unambiguous by direct visual comparison against
adjacent non-bold text.

**A second, separate, genuinely-confirmed gap, NOT a bug** (see the
"Known gap" note above, in this same section): `THEN` inside `IF x
THEN y` does not bold, and per this design's own segment-start-only
scan, structurally cannot without a further, not-yet-built extension —
this was true from the moment the feature shipped and was mistakenly
described as working in this doc's own first draft; see that note for
the full explanation and why it wasn't fixed alongside the redraw bug
above (EXROM margin, ~19 bytes free at the time).

Full `tests/` regression suite (38 files) re-run after the IX/(nn) fix
and confirmed all green — this bug's own blast radius was contained to
settled-line rendering, no overlap with execution or checking, matching
the earlier passes' own experience, but re-confirmed rather than
assumed given how wrong the "budget looks fine" assumption from the
first EXROM pass turned out to be.

### Sprite improvements: more slots, MOVE, HIT() (2026-08-23)

Three additions to `SPRITE GRAB`/`SHOW`/`HIDE` (`rom/exrom_sprite.asm`),
picked as the cheapest genuinely useful improvements available given
EXROM's own tight remaining margin — see the earlier "what improvements
can be made... given the limited space" discussion this session for
the survey that led here.

**`SPRITE_SLOT_MAX` 4 -> 8** (`include/sysvars.inc`) — essentially free
in ROM terms: the slot-offset math (`BASIC_SPRITE_ADD_SLOT_OFFSET`) is
a `djnz` loop bounded by the slot count at runtime, not unrolled
per-slot code, so doubling the count costs zero ROM bytes. The real
cost is RAM: every `SPRITE_SLOT_*` per-slot array/buffer doubled in
place, a cumulative +1176 bytes cascading through `SPRITE_ARG_SLOT`
and every sysvar after it in the file (54 address lines shifted by a
script, not by hand, given the size — verified against the two
addresses that bound the shift, `SPRITE_ARG_SLOT` and `PROG_AREA_
START`, both landing exactly where hand computation predicted before
trusting the script's other 52 lines). `PROG_AREA_START` moved `$B769`
-> `$BC01`: a real, deliberate trade against user program space, which
shrank from 2199 bytes (`$C000-$B769`) to 1023 bytes (`$C000-$BC01`)
for this alone — worth knowing if a program ever runs into `OUT OF
MEMORY`/similar with a long listing.

**`SPRITE MOVE <slot>,<row>,<col>`** — repositions an already-`SHOWN`
sprite in one statement (restore the background at the OLD position,
capture+draw at the new one, using the slot's own tracked row/col/w/h)
instead of the previous `HIDE` then `SHOW` two-statement dance. Refuses
`SPRITE NOT SHOWN` if the slot isn't currently shown, same rule `HIDE`
already used. Checker grammar: identical 3-argument shape to `SHOW`
(`.check_sprite_3args`, `rom/exrom_checker.asm`).

Cost discipline was real here: the first draft of `MOVE`, written by
mostly duplicating `SHOW`'s and `HIDE`'s own bodies inline, measured at
EXROM 282 -> 12 bytes free — confirmed by a real build, not estimated,
and nowhere near enough margin to also fit `HIT()` afterward. Refactored
into three shared helpers before building `HIT()` at all:
`BASIC_SPRITE_LOAD_WH` (slot's own w/h from its last `GRAB`, used by
both `SHOW` and `MOVE`), `BASIC_SPRITE_LOAD_OLD_POS` (slot's current
row/col/w/h, used by both `HIDE` and `MOVE`), `BASIC_SPRITE_RESTORE_BG`
(the "erase" step, `HIDE`+`MOVE`), and `BASIC_SPRITE_CAPTURE_AND_SHOW`
(the "put it here" step, `SHOW`+`MOVE`) — `SHOW`/`HIDE` themselves were
rewritten to call these too, not just `MOVE`, so the duplication removed
is real, not just avoided going forward. This raised the margin back to
184 bytes free before `HIT()` was even started.

**`HIT(slot1,slot2)`** — a numeric function (`FUNCTION_TABLE` entry,
`FUNC_ID_HIT`, ordinary 2-numeric-argument shape like `MOD`/`DIV`/
`POINT`), `1` if both slots are currently `SHOWN` and their rectangles
overlap, `0` otherwise — including for an invalid/out-of-range slot
number, treated as "not shown" rather than a runtime error (same
graceful-clamp precedent `POINT`'s own Y-clamp uses), since a collision
check is exactly the kind of thing a game loop calls every frame and
shouldn't need its own bounds check first. Standard 4-comparison
rectangle-overlap test, reusing `BASIC_SPRITE_SLOT_FLAG_ADDR` directly
(no cross-compilation-unit addressing problem here, unlike the keyword-
highlighting table above — this routine lives in the SAME file as that
helper already). No `BASIC_CHECK_ONLY` guard needed, unlike `STICK`'s
own function: `HIT()`'s body only ever reads sprite state, never
mutates anything BASIC-visible, so it's safe to run for real even
during a whole-program check pass.

Takes its two slot numbers in `HL`/`DE`, not `A` — deliberately, having
just fixed two real bugs THIS SAME SESSION caused by routing a real `A`
argument through an EXROM entry stub whose own magic-check preamble
clobbers `A` (see `EDITOR_WRAP_OFFSET_TO_ROWCOL`'s own header, `rom/
exrom_editor.asm`) — `HL`/`DE` survive that trampoline untouched, so
this was designed to avoid the bug class outright rather than needing
a third fix for it later.

**Measured final cost** (after the `SHOW`/`HIDE`/`MOVE` refactor, with
`HIT()` included): Home 179 -> 147 bytes free, EXROM 184 -> 19 bytes
free. EXROM margin is real but thin — worth measuring again before
adding anything else there.

**Verified live via real execution** (2026-08-23, after an initial
attempt at interactive-typing verification proved unreliable — see the
"editor typing" bug/fix sections above for exactly how unreliable, and
the user's own request to stop driving the editor that way — switched
to `tools/preload_gen.py` instead, which encodes a program directly
into ROM storage with no keyboard involved, `--autorun` executes it
for real via `BASIC_RUN`). Home's own 147-byte margin only fits a
preload program of roughly 110 encoded bytes or fewer, so this was
several small programs rather than one combined test (a single 6-
statement GRAB+GRAB+SHOW+SHOW+MOVE+check program measured at 136
bytes, over budget by 26 — confirmed by a real build overflow, not
guessed):
- Slot 7 (only reachable with the doubled slot count): `GRAB`/`SHOW`/
  `HIDE` all executed with no error — green border (the "still 4,
  never overridden to 2" verdict convention).
- `HIT(0,1)` correctly returns `0` when slot 1 has never been
  `GRAB`bed/`SHOW`n at all (the graceful-invalid-input path).
- `HIT(0,1)` correctly returns `1` when both slots are shown at the
  identical position (`BORDER (HIT(0,1))*2+2` evaluated to `4`,
  proving the real returned value, not just "no error").
- `SPRITE MOVE` (`GRAB`->`SHOW`->`MOVE`->`HIDE`) executed with no
  error and left the screen clean afterward (no leftover sprite
  pixels — confirming `HIDE` correctly restored the background at the
  NEW position `MOVE` left it at, not the original one).
- Each result cross-checked against a full screenshot, not just the
  border pixel — a runtime error goes to the status line, not the
  border, so border-only checking could have missed one.

**Residual gap, not yet verified**: `MOVE` actually changing what
`HIT()` reports — i.e. that after `MOVE`, two previously-overlapping
slots correctly stop colliding — has NOT been directly exercised as a
single combined test; that specific 6-statement program is exactly the
one that overflowed the budget above, and no smaller equivalent was
found. Indirect confidence is reasonably high (`MOVE`'s own code calls
`BASIC_SPRITE_CAPTURE_AND_SHOW`, which explicitly updates `SPRITE_
SLOT_ROW`/`COL` to the new position, and `HIT()` reads those same two
sysvars directly for its own overlap math — both pieces independently
confirmed working above), but this is inference from reading the code,
not a direct empirical result, and should be called out as such rather
than folded into "verified live" above it.

### IF/ELSEIF/ELSE/END IF

The first piece of `docs/basic_language_reference.md`'s structured
control flow to actually get built. Full design and current status is
documented in that file's own "Structured control flow" section — this
entry covers the implementation mechanics.

**Grammar recap**: block form `IF <cond> THEN` / body /
`[ELSEIF <cond> THEN ...]*` / `[ELSE ...]` / `END IF`, nestable; plus a
single-line short form `IF <cond> THEN <stmt>` with no `END IF`.
Conditions support `= <> < > <= >=` and `AND`/`OR`/`NOT` (no short-
circuiting — both sides of `AND`/`OR` always evaluate).

**Execution mechanism — no explicit block stack needed.** IF/ELSEIF/
ELSE/END IF reuses `GOTO_TARGET`, the exact same "set a pending jump,
`BASIC_RUN`'s loop honors it after the statement returns" mechanism
`GOTO` already established:

- A **true** IF/ELSEIF condition means literally nothing extra: the
  statement handler just returns, and `BASIC_RUN`'s loop naturally
  continues into the body's own statements one at a time, exactly like
  any other sequential code — nested IFs inside "just work" via plain
  recursion into the same dispatcher.
- A **false** condition triggers `BASIC_RESOLVE_IF_CHAIN`, which scans
  forward (tracking nested IF/END IF depth via the shared
  `BASIC_IF_SCAN_STEP` classifier) looking for THIS block's own
  `ELSEIF`/`ELSE`/`END IF` at depth 0. A depth-0 `ELSEIF` found along
  the way has its OWN condition evaluated right there, inline, during
  the scan — true means "this is the branch to take," false means
  "keep scanning past it." This is what keeps `ELSEIF`'s own top-level
  statement handler completely unambiguous (see next point).
- `ELSE`/`ELSEIF`, when directly DISPATCHED as a statement (as opposed
  to being found and evaluated during the scan above), can only ever
  be reached one way: ordinary fallthrough after a taken branch's body
  just finished. So `BASIC_STMT_ELSE_OR_ELSEIF` (shared — both mean
  exactly the same thing here) always does exactly one thing: skip
  forward (`BASIC_SKIP_TO_ENDIF`, depth-tracked the same way) straight
  to the chain's own `END IF`, discarding every remaining sibling
  branch. The key design move that avoids the classic ambiguity ("was
  I reached by landing here on a false condition, or by falling
  through a true one?") is that a false-condition scan never lands
  execution exactly ON an `ELSE` line — it resolves straight to the
  statement AFTER it (the start of that branch's actual body).
- `END IF` is a pure no-op wherever it's reached from.

**`END IF` vs. bare `END`**: bare `END` already means "stop the
program," and its own boundary check (a space counts as valid) would
otherwise wrongly match the "END" of "END IF" and silently ignore the
trailing " IF". `BASIC_MATCH_ENDIF` (checked before the bare-`END`
check everywhere it matters — execution dispatch, the static checker,
and the block scanner) handles the compound keyword correctly; as a
harmless side effect of how it tolerates zero spaces, `ENDIF` (one
word) also works, though that's not a deliberate second spelling.

**Condition evaluation** (`BASIC_EVAL_CONDITION` / `_OR` / `_AND` /
`_NOT` / `_COMPARISON`) sits directly on top of the existing arithmetic
evaluator (`BASIC_EVAL_EXPR`), same precedence-climbing shape, sharing
`EXPR_PARSE_PTR` the same way the arithmetic levels already do.
Relational comparisons use the new `MATH_COMPARE16` (kernel/math — see
that section above). A real bug caught during design, before any
testing: `BASIC_EVAL_EXPR`'s established contract returns the current
parse position in HL as well as `EXPR_PARSE_PTR`, but several return
paths deep in the new condition chain only kept `EXPR_PARSE_PTR`
accurate, not the bare HL register — callers (`BASIC_STMT_IF`,
`BASIC_RESOLVE_IF_CHAIN`'s own `ELSEIF` check) need HL directly right
after, to keep parsing `THEN`. Fixed at the single funnel point
(`BASIC_EVAL_CONDITION`'s own return) rather than auditing every
deeper return statement individually.

**New sysvars**: `IF_SCAN_POS` (2 bytes), `IF_SCAN_DEPTH` (1 byte),
`IF_TEMP_RESULT` (1 byte) — fit in the 6-byte gap `HELP_ROW` left
before `PROG_AREA_START`, verified via the project's own sysvar-
overlap check; no boundary move needed this time.

**The real bug, and this feature's actual debugging arc.** Every hand
trace done before the user ever got a chance to test this — including
several extremely literal, register-by-register re-traces, and a full
byte-for-byte audit of the real assembled `.lst` output covering
every routine in the chain from `BASIC_RUN`'s entry down through
`MATH_COMPARE16` — found nothing wrong. The actual bug was a stack-
ordering mistake in `BASIC_EVAL_RHS_AND_COMPARE` (the shared tail
every relational operator funnels through): `BASIC_EVAL_COMPARISON`
pushes the left operand's value before calling this routine, and the
routine's own naive `pop hl` assumed that value would be sitting on
top of the stack. It isn't — the `call` that invokes the routine
pushes ITS OWN return address first, so the real stack order was
`[my own return address, the caller's saved value, ...]`. The `pop`
was silently consuming the return address instead, corrupting it
permanently; the routine's own later `ret` then popped the *data
value* (e.g. a variable's actual contents) and jumped into whatever
address that value happened to be — a genuine wild jump, landing at
`$0000` in the traced case, which re-runs `COLD_START` and wipes the
program via `MEM_INIT`. This is exactly the "program vanishes,
resets to a blank NEW LINE" symptom the user kept hitting, and it
explains every earlier observation cleanly in hindsight: it fired for
every relational operator (`=`, `<`, `>`, ...) identically, regardless
of operand value or the `IF`'s position in the program, because all
of them funnel through this one shared routine — while `PRINT`, which
never reaches it, was unaffected the entire time.

This was NOT found by more static reasoning — repeated re-reads of
the exact same code kept insisting it was correct. It was found by
single-stepping the real build in Fuse's own built-in debugger
(`Machine → Debugger...` on GTK+, or `F1` → `Machine` → `Debugger...`
on the SDL widget UI), watching the actual `PC` and `SP` register
values update instruction by instruction, and catching the exact
moment `PC` jumped to `$0000` right after this routine's own `ret`.
Once caught live, the cause was obvious in a way no amount of
re-reading the source had made it. Worth remembering as this
project's now-clearest example of the established "when hand-tracing
keeps insisting code is correct but a real symptom persists, get a
diagnostic showing real values" lesson — in this case, a genuine
hardware/emulator single-step trace rather than a border-color or
on-screen-print diagnostic, since the earlier link-in-the-chain
bisection (deliberate `jr $` halts with distinct border colors, moved
progressively closer to the failure across many rounds) had narrowed
the search space enormously but couldn't pinpoint the exact
instruction on its own.

The fix: lift the routine's own return address off the stack first
(into `BC`), retrieve the actual left value now correctly on top,
then push the return address back before doing anything else — the
classic "swap the top two stack items" pattern — in both the success
and failure exit paths. `BASIC_EVAL_OR`/`_AND`'s own push/pop pairs
were re-examined and confirmed NOT to share this bug: they push and
pop their own saved values within their own function bodies, with
only self-balanced calls (which push and pop their own return address
in a matched pair) happening in between — the bug specifically
requires popping a value that a DIFFERENT, calling function pushed,
which only `BASIC_EVAL_RHS_AND_COMPARE` did.

Duplicate-label sweep and sysvar-overlap check both re-run clean after
the fix. **User-confirmed working**: `IF x > 3 THEN / PRINT x / END IF`
printed `5` and returned cleanly, no crash.

`tools/check_asm.py` (see "Static checks" above) was built directly out
of this debugging session, specifically to catch this class of bug
proactively next time — its stack-ordering fingerprint check flags any
routine that pops something before pushing anything of its own, which
is exactly this bug's shape. The fixed `BASIC_EVAL_RHS_AND_COMPARE`
now carries the checker's explicit `allow-early-pop` audit marker: its
return-address/left-value swap has been traced on both exits, while any
new, unreviewed early-pop pattern will still be reported.

### INK / PAPER / FLASH / INVERSE / OVER

Five new statements, same shape as `BORDER <n>` — `BASIC_STMT_INK`/
`_PAPER`/`_FLASH`/`_INVERSE`/`_OVER` each evaluate one expression via
`BASIC_EVAL_EXPR` and store the low byte into a new `CURRENT_INK`/
`CURRENT_PAPER`/`CURRENT_FLASH`/`CURRENT_INVERSE`/`CURRENT_OVER`
sysvar (see `include/sysvars.inc`'s own comments — `INK`/`PAPER` mask
to 0-7, `FLASH`/`INVERSE`/`OVER` mask to 0/1). All five wired into
`BASIC_EXEC_STATEMENT_CONTENT`, `BASIC_CHECK_STATEMENT_CONTENT`, and
both live-bolding tables (`BASIC_DETECT_KEYWORD_PREFIX`/
`BASIC_UPPERCASE_KEYWORD_PREFIX`) — checked explicitly against the
"two places not one" gap the IF/ELSEIF bolding bug caught, same as
`CLS`/`REM`/`BORDER` before them.

Unlike `BORDER`, these aren't just a hardware-port write — INK/PAPER/
FLASH/INVERSE need to actually change what `PRINT` draws. New
`BASIC_COMPUTE_PRINT_ATTR` builds the Spectrum-style attribute byte
(bit 7 FLASH, bits 5-3 PAPER, bits 2-0 INK) from the four sysvars each
time `PRINT` runs, swapping ink/paper at read time if `INVERSE` is set
(rather than folding the swap into `CURRENT_INK`/`CURRENT_PAPER`
themselves, so the underlying values survive `INVERSE` being turned
back off later). Both of `BASIC_STMT_PRINT`'s output paths (the
numeric-expression path and the string-literal path) now call this
before printing and pass the result to new `kernel/graphics` routine
`GFX_PRINT_STRING_ATTR` (see that section above) instead of the plain
`GFX_PRINT_STRING` — computed before row/column setup in both paths,
since `BASIC_COMPUTE_PRINT_ATTR` destroys `BC`, and carried across the
intervening call via a `push af`/`pop af` pair rather than a bare
register, same "value must survive a call" reasoning as everywhere
else in this project.

`OVER <n>` was initially stored but not applied to text. It is now complete:
`GFX_PUTCHAR_OVER` XORs each glyph scanline with the destination bitmap and
`GFX_PRINT_STRING_ATTR` selects it when `CURRENT_OVER` is set. Ordinary
editor/help/status text continues through opaque `GFX_PUTCHAR`, so BASIC's
graphics state cannot leak into interface rendering. `tests/gfx8.txt`
verifies a normal `A` bitmap byte and then confirms that printing the same
glyph at the same position under `OVER 1` restores that byte to zero.

`CURRENT_INK`/`CURRENT_PAPER`/`CURRENT_FLASH`/`CURRENT_INVERSE`/
`CURRENT_OVER` are reset to defaults (INK 0, PAPER 7, everything else
0) by new `BASIC_RESET_TEXT_ATTR`, called from the same two "start
fresh" moments as `BORDER_DEFAULT`'s own reset (cold boot and `NEW`) —
without this, a prior program's attribute state would leak into a
fresh session, the text equivalent of the `BORDER` leak bug fixed
earlier.

Only 2 bytes were free in the sysvar gap before `PROG_AREA_START`
($608E-$608F) — not enough for the 5 new 1-byte sysvars needed, so
`PROG_AREA_START` moved again, from `$6090` to `$6098` (5 bytes used,
5 bytes margin left). Re-verified via grep that every reference to the
boundary anywhere in the codebase still uses the symbolic constant.

`tools/check_asm.py` re-run clean across every touched file (only the
same pre-existing, already-explained `BASIC_EVAL_RHS_AND_COMPARE`
`[REVIEW]` flag).

**REAL BUG FOUND AND FIXED (via user testing + a memory dump, not
static analysis): every `PRINT` wrote attribute `$00` (black ink,
black paper) regardless of what `INK`/`PAPER`/etc. actually said.**
Symptom: `PRINT "hello"` rendered as a solid black rectangle — no
letter shapes visible at all — identically whether `INK`/`PAPER` were
left at defaults or explicitly set to different colours. Static
analysis of `BASIC_STMT_PRINT`, `BASIC_COMPUTE_PRINT_ATTR`, and
`GFX_PRINT_STRING_ATTR` all checked out correct on paper (confirmed
via a Python symbolic execution of the exact register sequence, and
confirmed `CURRENT_INK`/`CURRENT_PAPER` themselves held the right
values). What actually found it: the user saved a raw 64K memory dump
from Fuse (`File > Save Binary Data`) after a broken run, which showed
the *font bitmap* for "hello" was completely correct — real letter
shapes — while the *attribute bytes* at those 5 screen cells were
`$00`, against a background of `$38` everywhere else (proving
`GFX_CLS`'s own fill was fine, and only `PRINT`'s own attribute write
was wrong).

Root cause: `GFX_PRINT_STRING_ATTR`'s cross-call scratch value (the
attribute byte, carried across its own `GFX_PUTCHAR`/`GFX_SET_ATTR`
calls per character) was originally a `DB 0` byte embedded directly in
`kernel/graphics/graphics.asm`'s own code — a "self-modifying ROM"
pattern. This entire codebase assembles into ROM, not RAM, so
`ld (.attr_scratch), a` was a silent no-op at runtime (you cannot
write to ROM), meaning the byte always read back its compile-time
initial value (`0`) no matter what was "written" to it moments
earlier — explaining why the bug was identical regardless of what
`INK`/`PAPER` were actually set to. A category error, not a register-
flow mistake: this is the first place in the project that needed
cross-call scratch storage from *within `kernel/graphics` itself*
rather than `basic/` (which already always uses real `sysvars.inc`
RAM), so the "value must survive a call -> use memory" lesson had
never been tested against "...but which memory" before.

Fix: moved the scratch byte to a real RAM sysvar, `PRINT_ATTR_SCRATCH`
(`include/sysvars.inc`, `$6094`, fit the existing margin — 3 bytes
still free before `PROG_AREA_START`), and added `sysvars.inc` to
`kernel/graphics/graphics.asm`'s own includes (it previously only
needed `hardware.inc`). Swept the whole codebase for any other
`ld (.label), a`-style write to a local code label — none found; this
was an isolated mistake in the one routine that introduced the
pattern this session. Documented directly in `GFX_PRINT_STRING_ATTR`'s
own header as a standing warning against reintroducing this class of
bug. Re-verified sysvar overlap and ran `tools/check_asm.py` across
the whole codebase again after the fix — clean. **User rebuilt and
retested: all previous tests passed, confirming the fix works.**
`INK`/`PAPER`/`FLASH`/`INVERSE` are now genuinely confirmed working
end-to-end (real hardware/Fuse, not just hand-traced) — colors
actually apply to printed text as expected. `OVER` remains honestly
stubbed: stored/validated, no visual effect yet (see its own note
above).

### AT / TAB

Two new statements adding cursor positioning. New sysvar
`BASIC_OUTPUT_COL` (`$6093`, fit the 5-byte margin the previous
`PROG_AREA_START` move left, no further boundary move needed — 4
bytes still free, `$6094`-`$6097`) is the column companion to the
existing `BASIC_OUTPUT_ROW`.

`BASIC_STMT_AT` parses `AT <row-expr>,<col-expr>` — first real use of
comma-separated dual-argument parsing in this project. Row is CLAMPED
into 0-23 rather than masked: 24 isn't a power of 2, so a bitmask
can't cleanly bound it the way `BORDER`'s `AND $07` or `AT`'s own
column half (`AND $1F`, since `GFX_COLS` is 32) do — an out-of-range
row silently pins to the last valid row instead of reporting an
error, same "keep it within valid hardware range" precedent as
`BORDER`. Documented as an honest simplification rather than a
correct one: the clamp compares an UNSIGNED byte against 24, so a
negative row expression (e.g. `AT -1,5`) also lands on 23 (the low
byte of `-1` is `$FF`, read as "too high") rather than 0 — flagged
directly in `BASIC_STMT_AT`'s own header rather than silently
shipped. `BASIC_STMT_TAB` parses one expression and sets
`BASIC_OUTPUT_COL` only, leaving the row untouched.

Both hook into `kernel/graphics`'s existing cursor addressing
indirectly, through the sysvars `BASIC_STMT_PRINT` already reads
(`BASIC_OUTPUT_ROW`) plus the new `BASIC_OUTPUT_COL` — no new
`kernel/graphics` code was needed, since `GFX_PUTCHAR`/
`GFX_PRINT_STRING_ATTR` already take row/column as parameters; only
where `basic/` sources those two values needed to change (previously
row came from `BASIC_OUTPUT_ROW` and column was hardcoded 0).

**Positioning is deliberately one-`PRINT`-lifetime, not a persistent
mode** — matching classic Sinclair BASIC's own `AT`/`TAB` behavior.
`BASIC_ADVANCE_OUTPUT_ROW` (already called at the end of every `PRINT`
statement) now also resets `BASIC_OUTPUT_COL` to 0, so an earlier
`AT`/`TAB` only affects the single `PRINT` immediately following it;
the next line starts back at the left margin unless positioned again.
`BASIC_STMT_CLS` and `BASIC_RUN`'s own startup both reset
`BASIC_OUTPUT_COL` to 0 alongside their existing `BASIC_OUTPUT_ROW`
reset, for the same "don't leak stale state across a CLS or a fresh
RUN" reasoning already established for `BASIC_OUTPUT_ROW` itself.

Wired into the same four places as every other statement in this
project (`BASIC_EXEC_STATEMENT_CONTENT`, `BASIC_CHECK_STATEMENT_CONTENT`,
both live-bolding tables) — `AT`'s check-pass handler
(`.check_at`) reuses the shared `.syntax_fail`/`.ok` local labels the
IF feature already established within `BASIC_CHECK_STATEMENT_CONTENT`'s
scope, rather than duplicating the inline error-report code every
other `.check_*` handler repeats — `TAB` reuses the existing
`.check_attr_expr` single-expression check unchanged, since its
syntax (one expression, nothing further) is identical to `INK`/
`PAPER`/etc.

Hand-traced `AT 5,10`, `AT 5 , 10` (spaces around the comma —
`BASIC_EVAL_EXPR`'s own leading-space-skip at `BASIC_EVAL_PRIMARY`'s
entry handles the space before `10`; a manual `BASIC_SKIP_SPACES`
before the comma check handles the space before it), `AT 5` (missing
comma — correctly falls through to `SYNTAX ERROR`), `AT 30,5` (out-of-
range row — clamps to 23), and `AT -1,5` (negative row — see the
documented clamp limitation above). `tools/check_asm.py` re-run clean
across the whole codebase after this feature too (same single
pre-existing flag). Sysvar-overlap re-verified numerically (all 13
sysvars in the `$6065`-`$6098` region, no overlaps, 4 bytes margin).
**Not specifically retested by the user yet** — but shares
`BASIC_STMT_PRINT`'s output path with `INK`/`PAPER`/`FLASH`/`INVERSE`
(now confirmed fixed and working, see that section above), so the
positioning logic itself (row/column sourced from `BASIC_OUTPUT_ROW`/
`BASIC_OUTPUT_COL` rather than hardcoded 0) should be unaffected by
that bug or its fix. Worth a dedicated test pass regardless, rather
than assuming.

### LIST / EDIT / DELETE

Three new immediate commands (typed and committed like `RUN`/`NEW`/
`HELP`, not program statements — they only make sense as editor-level
operations on the stored program, never as something a running
program does to itself), wired into `BASIC_COMMAND_LOOP`'s own
dispatch chain rather than `BASIC_EXEC_STATEMENT_CONTENT`.

New shared helper `BASIC_GOTO_EDIT_INDEX` (In: `DE` = target 0-based
statement index) jumps the edit cursor to a specific statement,
loading it and parking it at the TOP of the screen — used by both
`LIST` (target always `0`) and `BASIC_DO_EDIT`. Out-of-range targets
clamp to the sentinel rather than erroring; callers that need a
stricter "does this actually exist" check do that themselves first.

`BASIC_DO_EDIT` parses a label name (`BASIC_PARSE_IDENTIFIER`, the
same routine `GOTO` uses), rebuilds the label table first
(`BASIC_SCAN_LABELS` — unlike `GOTO`, which only ever runs during
`RUN` and so can rely on that already having happened, `EDIT` can be
typed before the program's ever been run at all), looks the label up
(`MEM_LABEL_LOOKUP` — position, not index), converts that to an index
(`BASIC_FIND_INDEX_OF_POSITION`, already built for the error-
navigation feature), then calls `BASIC_GOTO_EDIT_INDEX`. Three
already-existing pieces stitched together; no new lookup mechanism.

**REAL BUG FOUND AND FIXED (user-reported): every `EDIT <label>` did
nothing — the typed line just sat there, and running the program
showed it as a stored (invalid) line, `SYNTAX ERROR` and all.** Root
cause: `BASIC_PARSE_IDENTIFIER` always writes its result into
`DETOK_BUF`, a single scratch buffer shared across `basic/` — not
something private to any one call. The original code protected the
*pointer* to `DETOK_BUF` across the `BASIC_SCAN_LABELS` call (`push
hl`/`push bc` ... `pop bc`/`pop hl`), which does nothing to protect
the buffer's *contents*: `BASIC_SCAN_LABELS` walks the whole program
and calls `BASIC_PARSE_IDENTIFIER` again internally, once per
statement, overwriting `DETOK_BUF` with whatever the *last* statement
in the program happens to contain. By the time the lookup ran,
`DETOK_BUF` no longer held the label name at all — the lookup always
failed. Confirmed via a small Python simulation of both the old and
fixed logic against a 3-statement program before trusting the Z80
rewrite (buggy version returns "not found"; fixed version correctly
returns the label's index).

Fixed by copying the parsed name out to its own dedicated buffer
(`EDIT_LABEL_COPY`, new sysvar, 32 bytes — same convention as
`PRINT_BUF`) immediately after parsing, *before* ever calling
`BASIC_SCAN_LABELS`. Since `BASIC_PARSE_IDENTIFIER` has no built-in
length limit, the copy is capped at 31 characters (silently
truncated beyond that — same already-accepted tradeoff `PRINT_BUF`
itself has for long string literals); `MEM_LABEL_LOOKUP` is given the
*clamped* length to match, not the original, since that's the true
length of what's actually stored in the copy buffer.

`BASIC_DO_DELETE` parses `<start>,<end>` (originally 0-based statement
indices, matching `CUR_EDIT_INDEX`'s own internal scheme — since
changed, see the real bug writeup further down), same
expression-and-comma shape as `BASIC_STMT_AT`'s row/col pair. Both
parsed indices are stashed in new sysvars `DELETE_START`/`DELETE_END`
rather than threaded through registers or the stack — juggling two
16-bit values by hand across the several destructive calls in between
(`BASIC_EVAL_EXPR` twice, `BASIC_COUNT_STATEMENTS`,
`BASIC_FIND_STATEMENT_AT_INDEX` twice) was tried first and produced a
genuinely broken first draft (lost track of which value was where);
rewritten cleanly with real RAM scratch instead, same "value must
survive a call -> use memory" lesson this project has hit many times,
just for two values here. Validated numerically in Python against 9
edge cases (empty program, single-statement range via `start==end`,
reversed range, whole-program range, off-by-one at both ends) before
trusting the Z80 — all matched. Deliberately conservative: ANY
problem (malformed expression, missing comma, trailing text, `start >
end`, either index out of range) leaves the program completely
unchanged and falls through to the same "tokenize as ordinary program
text" fallback every malformed immediate command already has (`RUN`/
`NEW`/`HELP`'s own trailing-check failures do the same) — surfacing
as `SYNTAX ERROR` on the next `RUN` rather than needing a new
"immediate command failed" display (there's no `CUR_EXEC_STMT` to
show for something typed outside `RUN` — see `BASIC_REPORT_ERROR`'s
own contract).

Real deletion goes through the existing `EDITOR_BLOCK_DELETE` (both
indices converted to positions via `BASIC_FIND_STATEMENT_AT_INDEX`
first) — inheriting that routine's own already-honest documented gap
(no check yet for a `GOTO`/`GOSUB` reference into the deleted range;
explicitly flagged as unimplemented in its own header, not silently
new here).

Deliberately does NOT reuse `BASIC_GOTO_EDIT_INDEX` for repositioning
after a delete — that routine always parks its target at the TOP of
the screen (right for `LIST`/`EDIT`, "jump there and show me"
commands), but deleting a few lines from the middle of a long program
shouldn't yank the view away from roughly where the user was looking.
Instead `BASIC_DO_DELETE` duplicates `BASIC_HANDLE_NAV`'s own small
minimal-scroll formula (scroll up only if the target moved above the
view, scroll down only enough to keep it on the last visible row
otherwise) — matching this project's established preference for
duplicating a short, already-verified formula over refactoring a
heavily-tested routine to share it. Always lands `CUR_EDIT_POS` back
on the sentinel afterward (append-ready) — a range delete has no
single obviously-correct statement to land on the way a single-line
delete does, and real Sinclair BASIC's own `DELETE` similarly returns
you to immediate-command mode rather than into the middle of the
program.

**`MERGE` was NOT implemented.** It fundamentally depends on `LOAD`
(reading a saved program into memory to merge), and this ROM has no
tape/storage I/O at all yet — no `KW_LOAD`, nothing in `kernel/io` for
it. Rather than ship a `MERGE` that doesn't actually merge anything,
this is flagged as genuinely blocked pending `LOAD` existing first,
consistent with this project's practice of documenting real gaps
rather than faking coverage.

New sysvars `DELETE_START`/`DELETE_END` (4 bytes) needed
`PROG_AREA_START` to move again, from `$6098` to `$60A0` (7 bytes
margin left), and `EDIT_LABEL_COPY` (32 bytes, added for the bug fix
above) moved it again to `$60C8` (8 bytes margin). Re-verified via
grep that every reference to the boundary still uses the symbolic
constant, and numerically re-checked the full `$6087`-`$60C8` sysvar
region for overlaps — none.

All three wired into both live-bolding tables
(`BASIC_DETECT_KEYWORD_PREFIX`/`BASIC_UPPERCASE_KEYWORD_PREFIX`) —
checked explicitly against the "two places not one" gap the IF/ELSEIF
bolding bug caught. Side note, not fixed (out of scope for this
session): `HELP` itself was never added to either bolding table — a
pre-existing gap from before this work, purely cosmetic (execution
itself is unaffected, same as the original IF/ELSEIF bolding gap
before it was fixed), left as a flagged TODO rather than silently
carried forward unremarked.

`tools/check_asm.py` re-run clean across the whole codebase (only the
same single pre-existing, already-explained flag).

**SECOND REAL BUG FOUND AND FIXED IN `EDIT <label>` (user-reported,
found after a genuinely clean, error-free build still failed the same
way): a register-survival mistake, not a buffer-contents one this
time.** After the `DETOK_BUF` fix above, a real memory dump (`File >
Save Binary Data`) showed the underlying DATA was completely correct
— `EDIT_LABEL_COPY` held `"LOOP"`, and the label table itself
correctly held `"LOOP"` → the right position — yet the lookup still
failed. Hand-tracing `MEM_LABEL_FIND` against those exact dumped
bytes confirmed the comparison logic itself was sound, which meant
the failure had to be in a REGISTER value at call time, not memory
content. Root cause: `BASIC_SCAN_LABELS` destroys `BC` too (documented
in its own header, same as `AF`/`DE`/`HL`) — the label's length,
restored into `B` right before calling it, was never actually
protected across that specific call, so `MEM_LABEL_LOOKUP` received a
garbage length instead of the real one and never matched anything,
regardless of how correct the buffer and table both were. A second,
distinct instance of the same underlying category of mistake as the
`DETOK_BUF` bug — fixing one shared resource a call destroys doesn't
fix another one the *same* call also destroys. Fixed with a second
`push bc`/`pop bc` specifically bracketing the `BASIC_SCAN_LABELS`
call. Verified via a small Python simulation modeling the register
clobbering explicitly this time (not just buffer contents) — the
buggy version hands the lookup a garbage length (`0xFF` in the
simulation), the fixed version correctly hands it `4`.

Re-audited `BASIC_DO_DELETE` and `BASIC_GOTO_EDIT_INDEX` for the same
class of mistake (a register assumed to survive a call that actually
destroys it) — both clean: every value in either routine is either
freshly reloaded from memory immediately before use, or explicitly
protected with its own `push`/`pop` bracketing the exact call that
could clobber it. No comparable bug found in either.

**REAL BUILD-BREAKING BUG FOUND (user-reported): `sjasmplus` reported
three "[JR] Target out of range" errors in `BASIC_DO_DELETE`
(`jr c/nz, .fail` at what the user's build reported as lines 863, 869,
873).** This explains why `DELETE` looked broken during testing —
the assembly genuinely failed (3 errors, no output produced), so Fuse
was almost certainly still running an OLDER binary from before this
routine existed, not the code being reviewed here at all. This
project's #2 recurring lesson (`JR`'s -126/+129 byte reach gets hit
as files grow) finally landed on a real build, not just a
theoretical risk noted in passing. Fixed by converting every
`jr <cond>, .fail`/`.fail_pop` in `BASIC_DO_DELETE` to `jp` (not just
the three the assembler happened to flag — the whole routine's
distance to `.fail` is large enough that leaving any of them as `jr`
is fragile against the routine growing even slightly in the future).
`BASIC_DO_EDIT`'s own `.fail` jumps were checked too (shorter routine,
`.fail` much closer) and left as `jr` — the user's assembler output
would have flagged those too if they were actually out of range,
since `sjasmplus` reports every such error in one pass, not just the
first.

**REAL BUG FOUND AND FIXED IN `DELETE`, once the build was clean
enough to actually test it: a wrong terminator byte, not a register
or logic mistake this time.** After the JR-range fix, the user
retested `DELETE 1,1` on a genuinely fresh build — still fell through
to being stored as text. A memory dump showed `DELETE_START`/
`DELETE_END` had already been parsed correctly (both genuinely `1`)
before the failure — ruling out the parsing itself, same diagnostic
approach as the `EDIT` bugs above. Root cause: the final "require
nothing else follows the second number" check compared the next byte
against `$0D` (carriage return) — copied directly from
`BASIC_STMT_AT`'s own end-of-statement check. But `BASIC_STMT_AT`
reads already-tokenized PROGRAM text, which genuinely ends in `$0D`;
`BASIC_DO_DELETE` instead reads straight out of `EDIT_LINE_BUF` (the
just-typed text, before it's ever tokenized), which is NULL-
terminated. The check was comparing the buffer's real terminator
(`$00`) against the wrong byte (`$0D`) and failing on every input,
including perfectly valid ones like `1,1`. Fixed by changing the
check from `cp $0D` to `or a` (zero-test) — verified numerically in
Python that the fixed check correctly recognizes end-of-input where
the old one never could.

Three real bugs found across this one feature, each a different
category: a shared-buffer content collision (`EDIT`'s `DETOK_BUF`
issue), a shared-register survival mistake (`EDIT`'s `BC`-across-
`BASIC_SCAN_LABELS` issue), and a wrong-terminator-convention mistake
copied from a different context (`DELETE`'s `$0D`-vs-`$00` issue) —
none of which static analysis alone caught; all three were found only
once real test data (a screenshot, then two separate memory dumps)
was available to check the code's actual behavior against.

**User-confirmed: `EDIT <label>` now works correctly end-to-end.**
`DELETE`'s `$0D`-vs-`$00` fix was correct — a follow-up memory dump
confirmed the underlying program data was already exactly right
(`DELETE 1,1` genuinely removed the right statement) — but surfaced a
**fourth bug, a different kind again: a stale redraw, not a logic or
data problem.** The screen kept showing the just-deleted line's old
text at its row (and the row below it) even though the real program
had already shrunk correctly underneath — until the user typed `LIST`
immediately afterward, which forced a fresh redraw and revealed the
program was actually correct all along. Root cause: unlike `NEW`/
`RUN`/`HELP`, which all call `BASIC_RESET_ROW_SHADOW` after their own
structural changes to the program, `BASIC_DO_DELETE` never did — the
row-shadow diffing that skips redrawing unchanged rows was never told
a structural change had happened, so it kept trusting stale
`(position, flags)` shadow state against rows whose actual content
had shifted. The existing single-line delete (CAPS SHIFT+1) never hit
this because it only ever removes exactly the current statement — a
narrower, already-proven shift pattern the diffing handles correctly
on its own; an arbitrary multi-statement range delete is a bigger
structural change, the same "just did something big — force a full
redraw" case `NEW` already established the precedent for. Fixed with
one `call BASIC_RESET_ROW_SHADOW`, matching that existing precedent
exactly. `LIST`/`EDIT` were checked for the same gap and don't need
it — they only ever move which position is shown where (view
scrolling), never change the program's actual structure, so there's
no stale shadow state for them to leave behind in the first place.

Four real bugs found across this one feature now, each genuinely
different: a shared-buffer content collision, a shared-register
survival mistake, a wrong-terminator-convention copy-paste, and a
missing redraw-invalidation call — none caught by static analysis,
every one found only because the user tested it, reported exactly
what they saw, and (for the last two) shared a memory dump so the
code's actual behavior could be checked against real data instead of
guessed at.

**DELETE's numbering changed from 0-based to 1-based (user-reported:
"DELETE 1,1" was deleting the SECOND line, exactly as 0-based
indexing would — working as originally designed, but not how anyone
reading a listing top to bottom would expect).** Not a bug in the
sense of incorrect code — the 0-based design was deliberate and
matched `CUR_EDIT_INDEX`'s own internal scheme exactly — but a design
choice that didn't match user intuition, worth changing outright
rather than just documenting more prominently. Fixed narrowly: only
`BASIC_DO_DELETE`'s own parsed input is translated (each number is
checked for zero — typing `DELETE 0,2` is now rejected, since there's
no "line 0" once counting starts at 1 — then decremented once to
convert to the internal 0-based index before anything else in the
routine uses it). Deliberately did NOT touch `CUR_EDIT_INDEX`,
`BASIC_GOTO_EDIT_INDEX`, `BASIC_FIND_STATEMENT_AT_INDEX`, or anything
`LIST`/`EDIT` rely on — those stay 0-based internally exactly as
before, avoiding an off-by-one risk rippling through navigation code
that already depends on that convention working correctly. Re-
verified the full validation chain numerically in Python against 8
cases (first line, last line, whole-program range, a typed `0`,
reversed range, out-of-range end, single-line delete via matching
1-based numbers) — all matched. **User-confirmed working.**

**A rejected `DELETE` now shows "INVALID RANGE" in the status bar
(user-requested: silently falling through and storing the text, only
surfacing as `SYNTAX ERROR` on the next `RUN`, wasn't enough
feedback).** New sysvar `DELETE_INVALID_FLAG` (1 byte, `$60C0`, fit
the existing margin — no `PROG_AREA_START` move needed, 7 bytes still
free) is set by the `DELETE` dispatch the moment `BASIC_DO_DELETE`
returns carry (rejected) — but only from that specific path, not from
the earlier boundary checks (a bare `DELETE`, or something like
`DELETED` that merely starts with the same letters, which aren't real
attempts at the command at all). `BASIC_DRAW_STATUS_LINE` checks this
flag FIRST, ahead of even `CHECK_ERROR_COUNT`'s existing "N ERRORS
FOUND" display, and — critically — **clears it in the same
instruction sequence that reads it**, so the message shows for
exactly one redraw (the first one after the rejection) rather than
persisting the way `CHECK_ERROR_COUNT` deliberately does. That's a
deliberate difference from the existing error-count mechanism: there
the underlying problem (a bad program) is still there until fixed, so
staying visible while browsing makes sense; here the rejected text is
already gone the moment the message appears, so there's nothing left
to keep warning about — a sticky message would be actively
misleading. Also reset to 0 at cold boot, same "avoid a spurious
message from RAM garbage" reasoning `CHECK_ERROR_COUNT`'s own reset
already established — not reset separately by `NEW`, since the flag
is self-clearing on the very next redraw regardless of what triggers
it, so by the time any subsequent command could run, it's already
consumed.

### Immediate commands executing while editing an existing line

**REAL BUG FOUND AND FIXED (user-reported, confirmed via memory
dump): every immediate command (`RUN`/`NEW`/`HELP`/`LIST`/`EDIT`/
`DELETE`) was checked for unconditionally, regardless of whether
`CUR_EDIT_POS` was the sentinel (composing a genuinely new line) or
an EXISTING statement being edited.** Symptom: navigate to an
existing line, edit its text to read something like `DELETE 3,3`, and
pressing ENTER *executed* it as a command instead of committing the
edit — the original stored text was never replaced at all. Proven via
a memory dump: `PROG_END` still marked the exact same statement count
as before the edit, and the original text (`DELETE 3,1` from an
earlier test) was still sitting there byte-for-byte unchanged in the
program area, while `DELETE_START`/`DELETE_END` showed the *new*
`3,3` had been genuinely parsed. (What exactly the parsed `DELETE
3,3` then did — the target statement was still present afterward, not
deleted — remains not fully reconstructed; may reflect
`DELETE_START`/`DELETE_END` being stale from an earlier test rather
than this specific attempt. Left honestly unresolved rather than
guessed at, since it doesn't change what the actual fix needed to be.)

This wasn't a bug specific to `DELETE` — the exact same unconditional
check applied to all six immediate commands, all along, including
`RUN`/`NEW`/`HELP` from before this session. Fixed with a single
guard, added once, ahead of the whole dispatch chain, rather than
duplicating a sentinel check into every individual command: right
after the existing "blank ENTER is a no-op" check, `CUR_EDIT_POS` is
tested via `BASIC_IS_SENTINEL` (the same routine and calling
convention already used moments earlier in this same routine, for
deciding `EDITOR_ENTER`'s own starting position) — if it's NOT the
sentinel, execution jumps straight past every command check to the
normal tokenize-and-commit fallback. Uses `JP` rather than `JR`: the
guard needs to clear the entire `RUN`/`NEW`/`HELP`/`LIST`/`EDIT`/
`DELETE` chain below it, well beyond `JR`'s own ±129 byte reach — this
project's #2 recurring lesson, applied proactively this time rather
than found by a build error.

No regression risk for the common case (fixing a typo in an existing
line that doesn't happen to read like a command) — that already
routed to the same tokenize-and-commit fallback regardless, since it
never matched any command keyword in the first place; this guard just
makes that routing explicit and guaranteed rather than incidental.
The practical implication going forward: a program line is always
just data once it exists — editing it in place can never trigger
execution, no matter what the edited text happens to read. To
actually run an immediate command, it must be typed fresh on the
sentinel (append) line, never edited into an existing one.

**User then asked to confirm this decision** — accepted "a saved line
is always just text" as the intended behavior, rather than reopening
the ambiguity by letting an edited-back-to-valid rejected command
re-execute.

### Rejected commands: auto-removed once the cursor moves on

User-requested follow-up to the "INVALID RANGE" status message above:
rather than the rejected text becoming a *permanent* stored line
(discoverable only as a `SYNTAX ERROR` on the next `RUN`, or by
manually deleting it), it should stay visible just long enough for the
user to read the error, then be silently removed once they navigate
away — never becoming a real part of the saved program at all.

New sysvar `PENDING_DELETE_POS` (2 bytes, `$60C1`, fit the existing
margin) holds the position of a rejected command's text, or `$FFFF`
("nothing pending" — the same sentinel convention `BASIC_IS_SENTINEL`
already uses for `CUR_EDIT_POS`). Set in `.not_delete`'s own "appending
a new statement" branch, at the exact moment `PROG_END` (the position
about to receive the new text) is known and `DELETE_INVALID_FLAG` is
still `1` — that flag is only read-and-cleared by
`BASIC_DRAW_STATUS_LINE`, which hasn't run yet at this point in the
same command's own dispatch, so it's still a reliable "this fallthrough
came from a rejected command, not ordinary program text" signal here.

Consumed by a new guard prepended to `BASIC_HANDLE_NAV`'s very entry —
runs before any of that routine's existing logic, for every kind of
navigation it handles (`UP`/`DOWN`/delete-line/insert-line/error-nav
alike), matching the user's own framing ("if the cursor moves"). If
something is pending: deletes that single statement
(`MEM_LINE_DELETE_RANGE`, `HL`=`DE`=the same position — same one-
statement-range convention `EDITOR_BLOCK_DELETE`/`.do_delete_line`
already use), decrements `CUR_EDIT_INDEX` by one (the removed line was
always the last one, only ever appended right at `PROG_END`, so the
sentinel invariant `CUR_EDIT_INDEX == total` holds without needing to
recompute the count — verified numerically in Python), resets
`PENDING_DELETE_POS` to `$FFFF`, and calls `BASIC_RESET_ROW_SHADOW`
(same "structural change — force a fresh redraw" reasoning as
`DELETE`'s own earlier fix) — THEN falls through into the existing,
completely unmodified `BASIC_HANDLE_NAV` logic below, which processes
whatever navigation was actually requested against the now-cleaned-up
program. Deliberately implemented as a prepended guard rather than
touching any of that routine's existing tested logic, matching this
project's established caution around its most heavily-tested routine.

Also reset to `$FFFF` at cold boot, same "avoid RAM garbage looking
like a real position" reasoning `CHECK_ERROR_COUNT`'s and
`DELETE_INVALID_FLAG`'s own resets already established.

**Known scope limit, stated directly rather than silently narrowed:**
only triggers on explicit navigation (`UP`/`DOWN`/etc, via
`BASIC_HANDLE_NAV`) — matches the user's own literal request. Typing
and committing a further new line WITHOUT navigating away first (valid
or invalid) does not trigger cleanup; the previously-rejected line
stays pending until an actual navigation happens. Similarly, pressing
`RUN` directly (without navigating first) does not trigger cleanup
either — the pending line is still present at that point and will
correctly show as its own `SYNTAX ERROR`, the same fallback behavior
as before this feature existed.

### Statement separator (`:`)

Lets multiple statements share one program line — the last item from
the user's original three-item feature list for this session.

**Design decision made before writing any code, and the single most
important one for this feature's safety:** rather than teach every
individual statement handler (`BASIC_STMT_PRINT` and roughly two dozen
others) to track and report where it stopped parsing — the only way
to support `:` if each handler dispatches directly against the real
program text — a line is pre-split into colon-separated segments,
each one copied into a scratch buffer with a synthetic `$0D`
terminator, and fed to the existing, completely unmodified
`BASIC_EXEC_STATEMENT_CONTENT`/`BASIC_CHECK_STATEMENT_CONTENT` as if
it were its own standalone statement. Zero changes needed to any
individual statement handler — none of them can tell the difference
between a real whole-line statement and one synthetic segment of a
longer line.

**Labels required a specific, deliberate scope decision.** A label
definition (`loop:`) already existed before this feature, and
`BASIC_IS_LABEL_DEFINITION`'s own contract requires the *entire
statement* to be nothing but `identifier:` — nothing else on the
line. Rather than extend that (which would also require updating
`BASIC_SCAN_LABELS`, the label table builder, carefully) to allow
`loop: PRINT 1`, the colon-splitter checks "is this whole line
already a label definition?" via that existing, completely unmodified
routine FIRST — if so, the line is dispatched whole and unsplit,
exactly as before this feature existed, and the colon-splitting code
below is never reached at all for it. This means labels/`GOTO` carry
**zero risk** from this feature — verified by construction, not just
by testing, since the label-recognition code path is literally
untouched. The tradeoff, stated directly rather than glossed over: a
label cannot share a line with other statements. `loop: PRINT 1` is a
`SYNTAX ERROR` — `loop` alone fails `BASIC_IS_LABEL_DEFINITION`'s own
end-of-statement requirement (something follows the colon), and isn't
a recognized keyword or assignment either, so it's reported as
genuinely invalid rather than silently misinterpreted as a label.

**`BASIC_FIND_STATEMENT_BOUNDARY`** scans forward from a segment's
start for the next unquoted `:` or the line's real `$0D`. Two things
it must get right, both verified in Python (a faithful line-splitter
matching this exact control flow) against 7 cases before any Z80 was
written:
- A `:` inside a quoted string is just text (`PRINT "a:b"` must print
  `a:b`, not stop after `a`) — tracked via `BOUNDARY_IN_STRING`, a
  simple toggle on every `"` seen, matching how this project
  recognizes string literals everywhere else (no escape-sequence
  support, so a bare toggle suffices).
- `REM` is a special case, checked FIRST via the exact same
  `BASIC_MATCH_KEYWORD_BOUNDARY` every other keyword dispatch already
  uses — so this recognizes `REM` as a comment under precisely the
  same conditions `BASIC_STMT_REM`'s own dispatch would. Once
  recognized, the whole rest of the line is comment text, colons
  included, matching classic BASIC.

**`BASIC_EXEC_MULTI_STATEMENT`/`BASIC_CHECK_MULTI_STATEMENT`** are the
execution and check-pass wrappers — deliberately separate, duplicated
routines (differing only in which `_CONTENT` routine they call) rather
than one shared routine behind an indirect call, matching this
project's established preference (`BASIC_HANDLE_NAV`/`DELETE`'s own
scroll-formula duplication) for keeping each version simple and
independently traceable over saving a couple dozen lines. Both:
loop over segments via `BASIC_FIND_STATEMENT_BOUNDARY`; silently skip
EMPTY segments (a double colon, or a trailing colon with nothing
after — dispatching an empty string would report `SYNTAX ERROR` for
what real BASIC treats as a harmless no-op); copy each non-empty
segment into `MULTI_STMT_BUF` (128 bytes, sized to `EDIT_LINE_BUF_LEN`
— a segment can never exceed what a person could type on one line in
the first place) using a position-based compare against
`MULTI_SEG_END` (not a content-based scan, since the boundary
character itself was already correctly determined respecting quotes —
re-scanning for it naively during the copy would NOT respect quotes a
second time); dispatch; propagate a stop/failure immediately. Verified
against a second, fuller Python simulation of the whole loop
(including empty-segment skipping and a mid-line `STOP` correctly
preventing any further segment from running) before writing the Z80,
then re-verified the actual written instructions against a third,
register-level simulation of the copy loop specifically (the most
error-prone part — comparing 16-bit addresses via `H`/`L` vs `B`/`C`)
using concrete byte offsets, not just the higher-level model.

**Wiring:** `BASIC_EXEC_STATEMENT`/`BASIC_CHECK_STATEMENT` (the two
call sites `BASIC_RUN`/`BASIC_CHECK_PROGRAM` already use for every
top-level statement) now hand off to the new multi-statement wrappers
instead of the `_CONTENT` routines directly — no other change needed
at either call site. `BASIC_STMT_IF`'s single-line `THEN` form (both
its exec and check dispatch) was ALSO switched to the new wrappers —
a deliberate bonus this enables for free: `IF x THEN a=1: b=2` now
runs both statements, not just the first, since IF's own trailing
text is just more of the same statement's content, no different in
kind from a top-level line's own text.

New sysvars (134 bytes, dominated by `MULTI_STMT_BUF`'s own 128) —
`BOUNDARY_IN_STRING`, `MULTI_SEG_START`, `MULTI_SEG_END`,
`MULTI_SEG_BOUNDARY_CHAR`, `MULTI_STMT_BUF` — needed `PROG_AREA_START`
to move again, from `$60C8` to `$6150` (7 bytes margin). Re-verified
via grep that every reference to the boundary still uses the symbolic
constant, and numerically re-checked the full sysvar region for
overlaps — none.

Checked every new routine individually for `JR`-range risk (this
project's #2 recurring lesson, hit for real once already this
session) — all three are compact with exclusively local, nearby jump
targets; none needed converting to `JP`, but every jump to a routine
elsewhere in the file already correctly uses `JP`, not `JR`.

**Known, stated limitations, not oversights:**
- A label cannot share a line with other statements (see above).
- Live keyword bolding while typing only checks the very start of a
  line — in `PRINT 1: GOTO loop`, only `PRINT` renders bold, not
  `GOTO` after the colon. Purely cosmetic; execution is completely
  unaffected. Not extended to check after every colon boundary, since
  that's additional scope (tracking multiple bold spans per line,
  changing `BASIC_PRINT_LINE_HIGHLIGHTED`'s render loop) beyond what
  was asked for.

`tools/check_asm.py` re-run clean across the whole codebase (only the
same single pre-existing, already-explained flag). **Not yet assembled
or tested — no sjasmplus in this session.**


### PEEK/POKE/FREE/USR/PAUSE (2026-08-22)

Five raw-primitive keywords, all reusing existing infrastructure rather
than adding new grammar shapes: `PEEK(addr)` and `USR(addr)` slot into
`FUNCTION_TABLE`/`BASIC_EVAL_PRIMARY`'s existing one-argument dispatch
chain (same shape as `ABS`/`SQR`); `FREE()` is that same chain's first
**zero**-argument entry (`BASIC_EVAL_PRIMARY`'s `.do_function_call`
used to call `BASIC_EVAL_EXPR` unconditionally before checking `argc`,
which can't parse "nothing" — a `.zero_arg` branch, taken when
`FUNC_CALL_ARGC` is 0, checks for the closing `)` directly instead);
`POKE addr,value` and `PAUSE n` are ordinary statements using the same
`BASIC_EVAL_EXPR`/`BASIC_EXPECT_COMMA_EXPR`/`BASIC_EXPECT_STATEMENT_END`
building blocks `AT`/`BORDER` already use.

`PEEK`/`POKE`/`USR` read/write memory or jump to an address the BASIC
program supplies at runtime — deliberately **not** routed through a
`kernel/` API, unlike everything else `basic/` touches. The project's
"nothing outside `kernel/` touches hardware ports or system-variable
addresses directly" rule is about not duplicating or bypassing
kernel-owned, *named* hardware/sysvar state; an arbitrary caller-
supplied address has no such owner to bypass — the same reasoning real
Sinclair BASIC's own PEEK/POKE/USR implementation follows. `FREE()`
and `PAUSE`, by contrast, DO go through `kernel/`: `FREE()` calls the
new `kernel/memory` routine `MEM_FREE_BYTES` (`PROG_AREA_MAX -
PROG_END`), and `PAUSE <n>` calls the new `kernel/interrupt` routine
`INT_GET_FRAMES` (reads `FRAMES`, kernel/interrupt's real-time tick
counter) in a busy-wait loop, falling back to a blocking `IO_READ_KEY`
for `PAUSE 0` (wait for any keypress) — both are genuinely kernel-owned
state, not arbitrary addresses.

**A real bug found via a real hardware/emulator test, not by
inspection**: the whole-program checker (`BASIC_FULL_CHECK_EXROM`/
`BASIC_CHECK_STATEMENT_EXROM`, `rom/exrom_checker.asm`) validates a
statement's grammar by actually running `BASIC_EVAL_EXPR` on it — every
existing built-in function is side-effect-free by nature, so this was
always safe. `USR` genuinely isn't: an unguarded `USR(addr)` reached
during a check pass (RUN's own pre-flight check, or — since `BASIC_
CHECK_STATEMENT_EXROM` is also the live-typing hot path — merely
*typing* a line containing `USR(...)`, before RUN is ever pressed)
would really jump to whatever `addr` evaluates to. For a variable
that hasn't been assigned yet, that's `0` — this ROM's own `RST_00`
vector (`di` / `jp COLD_START`) — restarting the entire machine from
inside the checker's own call chain. This produced a genuine infinite
reboot loop, caught by a throwaway `BASIC_RUN`-calling preload harness
(a black/yellow-bordered screen that never reached a diagnostic border
write placed right after the `BASIC_RUN` call — see the project's own
working-memory notes on this exact harness pattern, preferred here over
simulated keystrokes since those are unreliable in this environment).
Bisecting each new keyword individually (PAUSE alone, POKE/PEEK alone,
FREE alone, USR alone) isolated it to USR specifically; the other four
all passed clean on the first real run.

Fixed with `BASIC_CHECK_ONLY` (`include/sysvars.inc`, 1 byte — moved
`PROG_AREA_START` by 1 byte to make room, this project's usual "no free
gap, bump the boundary" move): set to nonzero by both EXROM checker
wrapper routines around their own page-in/call/page-out (never during
real execution), checked by `BASIC_EVAL_PRIMARY`'s `USR` dispatch case,
which skips the real jump and returns a harmless `0` whenever a check
— not a real run — is in progress. Confirmed fixed by re-running the
same isolated USR test after the fix (green border) and the full
combined 5-feature test end-to-end (green border).

### RANDOMISE / PI / RAD / DEG (2026-08-22)

`RANDOMISE <n>` is a statement (`BASIC_STMT_RANDOMISE`), not a
function — this dialect's first "explicit reseeding" construct, so it
needed `BASIC_EXEC_STATEMENT_CONTENT`'s grammar rather than the
function-call mechanism. `n=0` calls the new `kernel/math` routine
`MATH_RND_SEED` with `HL=0`, which resets `RND_STATE` back to `MATH_
RND16`'s own "never seeded" sentinel (the cold-boot zero value) — the
very next `RND()` reseeds from the Z80 `R` register exactly as a cold
boot would, deliberately reusing that existing special case rather
than inventing a second "unseeded" convention. `n<>0` becomes the new
deterministic seed directly.

`PI()` is the second zero-argument built-in (after `FREE()`), reusing
`BASIC_SIN_FLOAT`'s own `CALC_PUSH_PI_HOME` (already built for SIN's
degrees->radians step) and the exact `duplicate / peek-into-FUNC_
RESULT_FLOAT / truncate` tail `BASIC_SQR_FLOAT`/`BASIC_SIN_FLOAT` use.
`RAD(x)`/`DEG(x)` factor SIN's own degrees->radians multiply/divide
pair (`x*pi/180`, and its inverse `x*180/pi`) out into their own
callable values — `BASIC_EXTRACT_SIGN` (sign extracted in the integer
domain first, same as SQR/SIN's own convention — the calculator-engine
math below only ever sees a non-negative magnitude) and `BASIC_
FINISH_FLOAT_RESULT` (the shared duplicate/peek/truncate tail) are new
shared routines both call, rather than duplicating BASIC_SQR_FLOAT's
inline sequence a third and fourth time.

### PI/RAD/DEG and a real EXROM-paging reentrancy bug (2026-08-22)

Building PI/RAD/DEG surfaced two real bugs via real emulator testing —
neither one actually in PI/RAD/DEG's own math.

**Bug 1 (testing-tool gap, not a product bug)**: `tools/preload_gen.
py`'s `HARNESS_TEMPLATE` defined `RST_00` and `RST_38` but never
`RST_28` (the calculator engine's entry point — see `rom/test_basic.
asm`'s own `RST_28: jp CALC_ENTRY_TRAMPOLINE`, which the template never
mirrored). Any harness generated by the tool before this fix left
`$0028` filled by the preceding `DS ... $FF` padding — `$FF` happens to
be the opcode for `RST $38`, so any `rst $28` in a preloaded program
silently jumped into the keyboard-ISR entry point instead of the
calculator engine. This looked exactly like an infinite hang (a
throwaway `PRINT "START" : A = SIN(30)` harness never even printed
`"START"` — proof the whole-program *check* pass, which runs before
any real execution, never completed) and was the first, wrong
hypothesis chased before the real cause was found. Fixed by adding the
matching `RST_28` stub to the template, copied verbatim from `rom/
test_basic.asm`.

**Bug 2 (real, pre-existing product bug, confirmed by a controlled A/B
test after fixing Bug 1)**: with `RST_28` now wired correctly, the SAME
`PRINT "START" : A = SIN(30)` harness *still* hung. Root cause: the
whole-program/live-typing checker (`BASIC_FULL_CHECK_EXROM`/`BASIC_
CHECK_STATEMENT_EXROM`) pages EXROM in, then runs its own EXROM-
resident validation code, which calls back into Home (`KTAB_BASIC_
EVAL_EXPR`) to validate an expression — and if that expression touches
the calculator engine via a `CALC_*_HOME` wrapper (`CALC_PUSH_PI_HOME`,
used by both `SIN` and the new `PI`/`RAD`/`DEG`), that wrapper does its
OWN inner `BANK_PAGE_EXROM_IN`/`_OUT` round trip. The inner page-*OUT*
unmapped chunk 6 back to Home while the OUTER checker call was still
logically "inside" EXROM-resident code (its own return address, from
`call KTAB_BASIC_EVAL_EXPR`, points into `$C0xx`) — so when that outer
call eventually returned, it jumped into whatever Home now has mapped
at `$C0xx` instead of the real EXROM checker code. This is a genuinely
**pre-existing** bug that already affected `SIN()`, just never
triggered before now: `SIN`'s own prior testing (`rom/test_sqr_sin_
visual.asm`) called `BASIC_SIN_FLOAT` directly as a routine, with known
register inputs, entirely bypassing the checker.

Confirmed via a real controlled experiment, not just code review: with
`RST_28` fixed but the paging fix temporarily reverted (a one-line
`jr` bypassing the nesting guard, restored immediately after), the
exact same `SIN(30)` harness hung again — proving the paging bug is
real and load-bearing, not just a defensive theoretical fix.

Fixed with `BANK_EXROM_DEPTH` (`include/sysvars.inc` — moved `PROG_
AREA_START` by 1 byte again, same "no free gap, bump the boundary"
move as `BASIC_CHECK_ONLY` above): a 1-byte nesting counter kernel/
bank's own `BANK_PAGE_EXROM_IN`/`_OUT` now check. `IN` only does the
real port write on the 0->1 depth transition; `OUT` only does the real
port write when the counter decrements back to 0. A nested call (from
inside an already-paged-in EXROM call chain) just adjusts the counter
and leaves chunk 6 mapped exactly as the outer caller left it. The
single, non-nested case every caller before this had — page in, do one
thing, page out — is completely unchanged in behavior. This fixes the
hazard for every current caller (`SIN`, `PI`, `RAD`, `DEG`) and every
future one, not just these three functions.

Confirmed fixed: the isolated `SIN(30)` checkpoint test (green border,
both `"START"` and the post-assignment checkpoint print correctly),
the full combined `RANDOMISE`+`PI`+`RAD`+`DEG` test (green border, and
the three printed values — `3.1415`, `1.5707`, `57.2957` — read
directly off a screenshot and matched against independently hand-
computed expected values), and a regression re-run of the previous
`PEEK`/`POKE`/`FREE`/`USR`/`PAUSE` combined test (still green — the
`kernel/bank`/sysvars changes here are foundational enough to be worth
re-checking, not because anything specifically pointed at them).

### ROM-size audit: BASIC_FORMAT_STORAGE_STATUS moved to EXROM (2026-08-22)

A code review specifically looking for Home-ROM shrink/reorganize
opportunities (Home was down to 813 bytes free vs. EXROM's ~2900)
picked `BASIC_FORMAT_STORAGE_STATUS` as the clearest candidate: 201
bytes of code plus its own dozen `MSG_*` message strings, genuinely
cold path (only ever called while `STORAGE_OP_STATE` is nonzero — i.e.
during or just after an actual SAVE/LOAD, confirmed by reading BASIC_
DRAW_STATUS_LINE's own dispatch, which gates every call to it behind
that check), only two Home callbacks needed (`BASIC_APPEND_STR`,
`BASIC_NUM_TO_STRING`), and the rest of the storage subsystem already
lives in EXROM (`rom/exrom_storage.asm`) — this was just an odd one
left behind.

Moved verbatim (body + all twelve message strings, each confirmed
used ONLY by this routine before moving them) into `rom/exrom_
storage.asm`, as new original content there — unlike the rest of that
file, which is a wholesale `INCLUDE "kernel/storage/storage.asm"`, not
a copy. New fixed entry stub `EXROM_ENTRY_FORMAT_STORAGE_STATUS` at
`$C042` (the twelfth, `rom/exrom_checker.asm`'s entry-stub block —
widened from eleven). Two new `KTAB_LIST` entries (`KTAB_BASIC_
APPEND_STR`, `KTAB_BASIC_NUM_TO_STRING`, `include/exrom_jumptable.
inc`, `KTAB_MAGIC` bumped 5->6) for the routine's own two Home
callbacks. Home-side thin wrapper `BASIC_FORMAT_STORAGE_STATUS_EXROM`
(`basic/basic.asm`, alongside the other `_EXROM` wrappers) replaces
the original body; both of `BASIC_DRAW_STATUS_LINE`'s own call sites
updated to call it.

**Real reentrancy consideration, not just theoretical**: this routine
is reached two ways — a one-shot completion message (`BASIC_DRAW_
STATUS_LINE`, called normally, EXROM not yet paged in) AND, via
`STORAGE_PROGRESS_HOOK` pointing at `BASIC_DRAW_STATUS_LINE`, called
*repeatedly mid-transfer* from inside `STORAGE_SAVE`/`STORAGE_LOAD`
themselves — which are ALSO EXROM-resident and already have EXROM
paged in for their entire (multi-block, DI-protected) run. That's
exactly the nested-paging pattern `BANK_EXROM_DEPTH` (see kernel/bank
section below, and the PI/RAD/DEG writeup above) was built to make
safe — this move would have reintroduced the same class of bug
without that fix already in place. Confirmed working, not just
reasoned through: a real `SAVE "T"` run end-to-end in the emulator
(via a throwaway harness calling `BASIC_DO_SAVE` directly, since SAVE/
LOAD are immediate-only commands, not usable inside a RUN'd program)
completed without hanging and the status bar correctly showed
`SAVED` afterward — the whole multi-block transfer's own repeated
nested calls into this now-EXROM-resident routine worked throughout.

Net result: Home 15571 -> 15268 bytes used (**303 bytes reclaimed**,
813 -> 1116 free); EXROM 5289 -> 5607 bytes used (2903 -> 2585 free).
Full regression re-run (`PEEK`/`POKE`/`FREE`/`USR`/`PAUSE`/
`RANDOMISE`/`PI`/`RAD`/`DEG` combined) still green after this move.

Audit also flagged, but explicitly did NOT move (see the audit's own
reasoning, kept here for future reference so it isn't re-litigated
from scratch): `BASIC_STMT_SPRITE_SHOW`/`_HIDE`/`_GRAB` (~450B, likely
good but needs its own Home-callback trace confirmed first); `SIN`/
`SQR`/`RND`/`SQRT` (~513B, real risk — these use the `RST $28` literal-
op-stream convention, where the return address IS the op-stream
pointer, and moving them to EXROM is a materially different, riskier
change than moving an ordinary called routine); `GFX_LINE`/`CPLOT`/
`CIRCLE`/`FILL` (~830B, bad fit — these run during a user's own
PLOT/LINE program, so paging cost would hit every graphics call, not
just a rare cold-path operation); the keyboard ISR routines (~360B,
bad fit — chunk 6 was deliberately chosen for being architecturally
distant from interrupt state); and the interactive editor/redraw hot
path (~1876B — `BASIC_REDRAW_PROGRAM` is literally the "full-redraw-
every-keypress" code, never a candidate).

### Bare GOSUB / RETURN / CALL (2026-08-22)

The user's own wishlist explicitly asked for a *simplified* "stored
procedures" mechanism reusing existing structures — no `LOCal`
variables, no parameter binding, no per-procedure label scoping (all
of which `docs/basic_language_reference.md`'s `DEFine PROCedure`
design already specs but this deliberately does not build). Landed as
two pieces:

- **`GOSUB <label>` / `RETurn`**: new `GOSUB_STACK` sysvar
  (`include/sysvars.inc`) — same shape as the existing `FOR_STACK`
  precedent (fixed array + depth counter), just a 2-byte return
  position per entry instead of FOR's fuller 7-byte loop record;
  `GOSUB_STACK_MAX EQU 8`, matching `FOR_STACK_MAX`'s own "generous but
  bounded" sizing rather than being separately justified. `BASIC_STMT_
  GOSUB` reuses `GOTO`'s exact `MEM_LABEL_LOOKUP` target resolution,
  then pushes a return position computed via `MEM_LINE_NEXT` on `CUR_
  EXEC_STMT` (the SAME computation `BASIC_RUN`'s own main loop would
  do if no jump had happened — see `BASIC_STMT_GOSUB`'s own header for
  why `CUR_EXEC_STMT`, not some other position, is the right value)
  before setting `GOTO_TARGET`, same mechanism `GOTO` already uses.
  `BASIC_STMT_RETURN` pops `GOSUB_STACK` back into `GOTO_TARGET`, with
  a `RETURN WITHOUT GOSUB` error (same shape as the existing `NEXT
  WITHOUT FOR`) on an empty stack.
- **`CALL <label>`**: per the user's own explicit choice among three
  presented options (bare-GOSUB-with-no-new-keyword; a `CALL` alias;
  a real `DEFPROC`/`END DEFPROC` block needing its own skip-to-END
  mechanism) — a second keyword routed to the identical `BASIC_STMT_
  GOSUB` handler. Near-free (~15-20 bytes) once GOSUB/RETURN already
  exist. **This repurposes `CALL` away from this doc's own earlier,
  never-implemented "invoke a named kernel routine" design** — see
  `docs/basic_language_reference.md`'s own "CALL" section for the full
  resolution of that conflict.

**A real edge case, reasoned through and guarded before it could ever
be hit**: `BASIC_GOSUB_PUSH_RETURN`'s return position can legitimately
be `0` — `MEM_LINE_NEXT` returns `0` when `GOSUB` is the program's own
last statement, meaning "there is nothing after this to resume at." But
`0` is ALSO `BASIC_RUN`'s own sentinel for "no jump pending" (see that
routine's own `.loop`). Writing `0` into `GOTO_TARGET` unguarded would
NOT stop the program the way it should — `BASIC_RUN` would silently
treat it as "no jump fired" and fall through to whatever text happens
to sit right after the `RETurn` statement itself in the program's own
storage order, not the caller's actual intent. `BASIC_STMT_RETURN`
guards this explicitly: a popped return position of exactly `0` uses
the same "stop, no error" contract `END`/`STOP` already have (carry
set, `PENDING_ERROR_MSG` left at `0`) instead of ever writing `0` into
`GOTO_TARGET`.

**Real bugs found via testing — none of them in GOSUB/RETURN/CALL
itself**, worth recording since they cost real debugging time and the
lessons generalize:

1. A misleading direct-repeated-call diagnostic: calling `BASIC_CHECK_
   STATEMENT_EXROM` in a hand-rolled loop, once per statement, to
   bisect which statement a whole-program check failure came from,
   produced a consistent, wrong-looking "10010" pattern — even for
   plain `GOTO`, proven solid throughout this entire project. The real
   whole-program check (`BASIC_RUN` → `BASIC_FULL_CHECK_EXROM`, the
   trusted, normal path) never showed this pattern for the same
   program. Calling a per-statement recheck routine directly, in a
   loop, OUTSIDE its one normal caller (`BASIC_CHECK_PROGRAM`'s own
   internal walk) is not a safe substitute for it — some state that
   caller's own loop maintains isn't reproduced by calling the same
   routine standalone, repeatedly. Lesson: prefer the real, proven
   call path over a hand-rolled one when bisecting, even if the real
   path gives coarser (pass/fail-only) information.
2. **The actual root cause, found once bisection moved to real,
   independently-authored test programs instead of a suspect diagnostic
   loop**: labels named `sub1`, `sub2`, `afterSub1`, etc. — i.e. every
   label the original combined test used — all contain a digit.
   `BASIC_PARSE_IDENTIFIER` only accepts letters; it silently stops at
   the first digit rather than erroring, so `sub1:` parses as the
   identifier `SUB` (3 letters) with a stray `1` left over, which then
   fails both the label-definition check and `GOTO`/`GOSUB`'s own
   grammar check — a genuine, pre-existing, previously-undocumented
   language constraint (not a GOSUB/RETURN bug at all), confirmed by
   swapping in a digit-free label name (`randok`, already known-good
   from the RANDOMISE/PI/RAD/DEG session) and watching the identical
   test structure pass cleanly. See `docs/basic_language_reference.md`'s
   own "Labels" section for the now-documented constraint.
3. A stale Fuse "Exit Fuse? Yes/No" confirmation dialog, left over from
   an earlier `pkill` in this same debugging session, was screenshotted
   and misread as real program output more than once before being
   caught — even after `pkill -9` (previously documented as reliable).
   Lesson reinforced, not new: always verify `ps aux` shows exactly one
   `fuse --machine` process AND `xwininfo` shows exactly one Fuse
   window immediately before trusting a screenshot, every time, not
   just after a suspicious result.

Confirmed working end-to-end after both fixes: basic `GOSUB`/`RETurn`
flow, `CALL` as an alias, nested `GOSUB` (a `GOSUB` target itself
calling `GOSUB`), the `RETURN WITHOUT GOSUB` error (correct message,
real error display), the return-position-`0` edge case (clean stop, no
hang, no false error), and a full regression combining all twelve
keywords implemented this session (`PEEK`/`POKE`/`FREE`/`USR`/`PAUSE`/
`RANDOMISE`/`PI`/`RAD`/`DEG`/`GOSUB`/`RETURN`/`CALL`) — all still
green. Home ROM: 15268 -> 15499 bytes used (231 bytes for GOSUB/
RETURN/CALL combined, 885 free remaining).

### INKEY$ (2026-08-22)

Implemented as a plain zero-argument, integer-returning function
(`INKEY$()`, matching `FREE()`/`PI()`'s own zero-arg convention) rather
than real classic BASIC's string-returning form — see `docs/basic_
language_reference.md`'s own Input section for the full scope-
reduction reasoning (no string-literal-in-expression parsing exists
yet to support `IF INKEY$="Q" THEN...`, and building one just for this
would likely be thrown away once real strings land).

New `kernel/io` routine `IO_READ_KEY_NONBLOCK` — same "thin consumer
of `KBD_ISR_TICK`'s latched state" shape as the existing `IO_READ_KEY`,
just without its `.wait_hit` loop: reads `KBD_KEYHIT` once, returns
immediately either way. Backed by state that's already hardware-
confirmed (the real-time keyboard ISR), so the only new risk surface
is the read-and-clear logic itself, not the underlying key detection.

Confirmed in the emulator: `A = INKEY$()` with no key pressed (the
only headlessly-testable case — live keypress injection is unreliable
in this sandbox per this project's own testing notes) correctly
returns and prints `0`, with the whole-program checker accepting the
new function cleanly. No new EXROM/checker wiring needed — same as
every other Home-only function this session (`PEEK`/`FREE`/`USR`/`PI`/
`RAD`/`DEG`), the checker validates it transitively through `KTAB_
BASIC_EVAL_EXPR`.

### BEEP / SOUND (2026-08-22)

Both statements share the same `<expr>,<expr>` comma grammar as
`PLOT`/`AT` — parsed via `BASIC_EXPECT_COMMA_EXPR`, the established
shared helper, no new parsing primitive needed.

**`BEEP <duration>,<pitch>`** — `BASIC_STMT_BEEP` just marshals the two
parsed values into `BC`/`DE` and calls `kernel/sound`'s `SOUND_BEEP`
directly (Home-resident; see that module's own section above for the
hardware mechanism and the deliberate scope reduction from the real
musical-note command).

**`SOUND <register>,<data>`** — the *authentic* real-hardware command,
confirmed from the ROM disassembly's own `SOUND` routine (`M2127`):
register written to port `$F5`, data to port `$F6`, register validated
1-16 (0 and 17+ both rejected). Unlike `BEEP`, `SOUND`'s real body
(`SOUND_EXROM`) lives in EXROM (`rom/exrom_sound.asm`) rather than
`kernel/sound` — pushed there purely for Home ROM budget, which was
already down to ~670 bytes free by the time this landed. `BASIC_STMT_
SOUND` calls a thin `BASIC_SOUND_EXROM` wrapper (`basic/basic.asm`,
same page-in/call-fixed-address/page-out shape as `BASIC_SAVE_EXROM`)
targeting a 13th fixed entry stub at `$C048` (`rom/exrom_checker.asm`
— `EXROM_VERIFY_KTAB_MAGIC`'s own body shifted from `$C048` to `$C04E`
to make room). The register-range check happens entirely at runtime,
not in the static checker — same "grammar only, not values" split
`MODE`'s own range check and `DIVISION BY ZERO` already established;
the checker's `SOUND` entry just reuses `PLOT`/`AT`'s existing grammar
check.

**A real cross-boundary bug avoided, not just fixed**: the first draft
had `SOUND_EXROM` call `KTAB_BASIC_SET_PENDING_ERROR` directly with an
EXROM-resident message pointer on the invalid-register path — looked
identical to the checker's own `KTAB_BASIC_SET_PENDING_ERROR` calls
elsewhere in `rom/exrom_checker.asm`, but those are safe only because
they're read back *while still paged in*, within the same statement
check. A RUNTIME error's message can be (and typically is) displayed
well after `BASIC_SOUND_EXROM` has already paged EXROM back out —
dereferencing that same pointer at that point would read whatever
chunk 6 actually holds once unpaged, not the intended text. Caught by
checking `BASIC_DO_LOAD`'s own established pattern first (`MSG_LOAD_
FAILED` is Home-resident, set by Home *after* `BASIC_LOAD_EXROM`
returns, keyed only off a carry flag) before writing any code — fixed
by having `SOUND_EXROM` return carry-only, with `MSG_INVALID_SOUND_
REGISTER` living Home-side in `basic/basic.asm` instead.

**Verified in the emulator** (`rom/test_sound.asm`/`test_sound2.asm`,
throwaway preload harnesses): `SOUND 8,15` (valid) followed by `SOUND
1,120` (valid) runs to completion — green border. `SOUND 8,15`
followed by `SOUND 0,120` (invalid register) halts with `INVALID SOUND
REGISTER` displayed on screen, screenshot-confirmed pixel-exact against
the real Sinclair-style error-report format this project already uses
for every other runtime error — and does NOT reach the following
`BORDER 4`, confirming the carry-preserving page-out actually works
end to end, not just that the port writes happen.

### String scalars — Phase 3, part 1 (2026-08-22)

The first slice of the Strings/Arrays roadmap item — assignment,
`PRINT`, and `=`/`<>` comparison for `A$`-`Z$` — built in priority
order (foundational first) specifically so real measured ROM cost
could gate what comes next, rather than committing to concatenation
and arrays up front against an estimate. **Real cost: ~364 bytes of
Home ROM**, dropping free Home space from 573 to 209 bytes — far more
than any single feature this project has built so far, confirming the
plan's own prediction that Phase 3 wouldn't fit the remaining budget
whole. Concatenation and both array types (`DIM name(n)`/`DIM
name$(n)`) remain in scope but are not yet built; see this session's
own status report to the user for the real number this gates against.

**Storage**: `STR_TABLE` (`include/sysvars.inc`) mirrors `VAR_TABLE`'s
own shape — 26 fixed slots, indexed by letter — but each slot is 32
bytes (1 length byte + 31 content bytes) instead of 2. `BASIC_STR_ADDR`
mirrors `BASIC_VAR_ADDR` exactly, five doublings (x32) instead of one
(x2). Two shared scratch buffers, same 32-byte shape, reused across
features that never run concurrently within one statement (assignment
RHS and comparison's left operand share `STR_EXPR_SCRATCH`; comparison
needs a second, live buffer for its right operand — `STR_CMP_RIGHT` —
since both sides must be held at once to compare them).

**New shared primitives** (all in `basic/basic.asm`):
- `BASIC_DETECT_STRVAR` — checks whether the text at `HL` is a letter
  immediately followed by `$`; same "carry set, HL unchanged" contract
  as every other `BASIC_TRY_*` probe, so callers can freely try it and
  fall through to a different interpretation.
- `BASIC_EVAL_STR_PRIMARY` — parses one string primary (a quoted
  literal or a bare `X$` reference) into a caller-supplied buffer.
  Deliberately not a full string-expression grammar yet — no `+` — see
  this section's own concatenation note below.
- `BASIC_TRY_STR_ASSIGNMENT` / `BASIC_CHECK_STR_ASSIGNMENT` — the
  execute-time and check-time halves, mirroring `BASIC_TRY_ASSIGNMENT`/
  `BASIC_CHECK_ASSIGNMENT`'s own shapes exactly, tried first in both
  dispatch chains (a numeric assignment attempt on `"X$ = ..."` already
  fails harmlessly on its own — the `$` isn't `=` or a space — so
  trying the string path first costs nothing on ordinary numeric
  assignments).
- `BASIC_STMT_PRINT` gained a `.print_strvar` branch, reusing
  `.print_string`'s own null-terminate-and-print tail verbatim rather
  than duplicating it.
- `BASIC_EVAL_COMPARISON` gained a `.string_path`, reached via a
  non-destructive peek (quote, or letter-then-`$`) before it commits to
  the numeric `BASIC_EVAL_EXPR` path — `OR`/`AND`/`NOT` above it in the
  precedence chain needed zero changes, since they're already agnostic
  to how the 0/1 truthy value beneath them was produced. `BASIC_STR_
  RHS_AND_COMPARE` is the string counterpart to `BASIC_EVAL_RHS_AND_
  COMPARE`, but a plain `CALL`/`RET` — none of that routine's own
  stack-reordering trick is needed, since the left string lives in
  memory (`STR_EXPR_SCRATCH`), not pushed on the stack.
- IF's own checker validation needed **zero new EXROM code** — it
  already reaches `BASIC_EVAL_COMPARISON` transitively through the
  existing `KTAB_BASIC_EVAL_CONDITION` entry, so the string path above
  is checker-covered automatically. `PRINT`'s and assignment's checker
  paths each needed one new branch (`.check_print`'s own `KTAB_BASIC_
  DETECT_STRVAR` check; `BASIC_CHECK_STR_ASSIGNMENT`), plus two new
  KTAB entries (`KTAB_BASIC_DETECT_STRVAR`, `KTAB_BASIC_EVAL_STR_
  PRIMARY` — `KTAB_COUNT` 28→30, `KTAB_MAGIC` 6→7).

**Two real bugs caught before either ever reached the emulator, worth
recording**:
1. `BASIC_EVAL_STR_PRIMARY` didn't skip leading spaces at its own
   entry — the numeric `BASIC_EVAL_EXPR` already tolerates a leading
   space internally, but this routine didn't, and not every call site
   skips spaces itself first. `IF A$ = "HI" THEN` failed the checker
   outright: the space right after `=` reached `BASIC_EVAL_STR_
   PRIMARY` as an unrecognized primary. Fixed by having the routine
   skip spaces at its own entry, matching the numeric path's own
   tolerance rather than trusting every caller to remember.
2. **The real one, caught only by bisecting a live symptom**:
   `BASIC_STR_ADDR` was documented as `Destroys: AF, HL`, copied
   straight from `BASIC_VAR_ADDR`'s own contract — but unlike that
   routine, it also loads `DE` (the `STR_TABLE` base) as part of its
   own address math, and the documented list was simply wrong.
   `BASIC_EVAL_STR_PRIMARY`'s `.var_ref` case relies on `DE` surviving
   as its own destination-buffer pointer across that call — with the
   wrong contract, `DE` silently became `STR_TABLE`'s own address, and
   copying a variable's content wrote the copied bytes straight into
   `STR_TABLE` itself rather than the intended scratch buffer,
   corrupting whichever slot the write landed on. Symptom: `A$ = "HI"`
   followed by so much as one `IF A$ = B$ THEN` comparison left `A$`
   silently blank on every subsequent `PRINT A$` — a real end-to-end
   test (`rom/test_str7.asm`, bisected down from a larger combined
   test the same way this project's GOSUB debugging session already
   established as the reliable method) caught it; static review of
   the routine in isolation had not. Same "the callee's documented
   Destroys list must be RIGHT, not just trusted" lesson this project
   has now hit three separate times (`GFX_PUTCHAR`/`B`, `CUR_VAR_
   LETTER`/`C`, now this) — fixed both the header (now correctly says
   `AF, DE, HL`) and the one caller that needed `DE` protected across
   the call (`push de` / `call BASIC_STR_ADDR` / `pop de`).

**Verified in the emulator** (`rom/test_str2.asm` through `test_str7.
asm`, throwaway preload harnesses, bisected the same way the bug above
was found): assignment from a literal and from another variable;
`PRINT` of a string variable; `=` and `<>` comparison against both a
literal and another variable, in both directions (true and false
outcomes); and a numeric-only regression program (`test_regr3.asm`)
confirming the new peek logic in `BASIC_EVAL_COMPARISON`/`BASIC_STMT_
PRINT` doesn't disturb ordinary numeric variables, `=`, or `>`.

### String concatenation — Phase 3, part 2 (2026-08-22)

`A$ + B$` (and longer `+`-chains), on top of the string scalars above.
**Real cost: ~50 bytes of Home ROM**, dropping free Home space from 209
to **159 bytes** — within the ~40-60 byte estimate made once string
scalars' own real cost was known, and the last thing likely to still
fit before arrays (both `DIM name(n)` and `DIM name$(n)`) become a real
question against whatever budget is left afterward.

**Design**: `BASIC_EVAL_STR_PRIMARY` gained a third input, `C` = max
bytes to write (every existing call site now passes `C=31`, preserving
its exact prior single-primary behavior) — both its literal-truncation
check and a new clamp on the variable-reference copy length now bound
against `C` instead of a hardcoded `31`. `BASIC_EVAL_STR_EXPR` is a
thin wrapper on top: parses one primary, then loops on `+` (each
subsequent primary's `BASIC_EVAL_STR_PRIMARY` call writes directly
after the previous one's output — concatenation itself is free, DE is
already positioned there), tracking a running total and passing `31 -
running_total` as `C` on each further call. A term reached once the
31-byte budget is already exhausted still parses grammatically but
contributes zero bytes, matching the existing "truncate, don't error"
precedent rather than introducing a new error class. The three
existing runtime call sites (`BASIC_EVAL_COMPARISON`'s string path,
`BASIC_STR_RHS_AND_COMPARE`, `BASIC_TRY_STR_ASSIGNMENT`) now call
`BASIC_EVAL_STR_EXPR` instead of `BASIC_EVAL_STR_PRIMARY` directly.

**Checker wiring cost: zero new bytes.** `BASIC_CHECK_STR_ASSIGNMENT`
(`rom/exrom_checker.asm`) already called `KTAB_BASIC_EVAL_STR_PRIMARY`
— retargeting that same jump-table slot at `BASIC_EVAL_STR_EXPR`
instead (renamed to `KTAB_BASIC_EVAL_STR_EXPR` for clarity) gives
assignment's checker path `+`-chain validation for free, no `KTAB_
COUNT`/`KTAB_MAGIC` bump needed since it's the same slot, just a
different target. `IF`'s own checker path needed no change at all —
same reasoning as string scalars' own writeup above: it reaches
`BASIC_EVAL_COMPARISON` transitively through the existing `KTAB_
BASIC_EVAL_CONDITION` entry, and everything beneath that point is a
plain Home-to-Home call, no further EXROM boundary to cross.

**Verified in the emulator** (`rom/test_concat.asm`/`test_concat2.
asm`): `A$="HI"` then `B$=A$+"!"` then `IF B$="HI!"` — true case
(green border) and a deliberately-mismatched false case (`A$+"?"`
compared against `"HI!"` — stays red, confirming this isn't a
comparison that just always returns true). `rom/test_regr4.asm`
confirms a plain numeric `IF A+B=7` still works, unaffected by any of
the string-path changes.

### ROM-size audit: SPRITE moved to EXROM (2026-08-22)

With Home ROM down to 159 bytes free after string concatenation, and
array support (both `DIM name(n)` and `DIM name$(n)`) still ahead
needing at least some Home-resident parsing glue, a second shrink pass
(same method as `BASIC_FORMAT_STORAGE_STATUS`'s own move above) went
looking for the next candidate. A size audit across `basic/basic.asm`
(computing byte size per global label from the assembler's own listing
— address deltas between consecutive labels, not guessed) ranked
`SPRITE GRAB`/`SHOW`/`HIDE` and their shared helpers as the best
combined candidate: **587 bytes total**, genuinely cold (only exercised
by a program that actually uses `SPRITE`, unlike `PRINT`/the statement
dispatch table/expression evaluation — all far bigger individually but
far too hot-path to page in and out of EXROM per statement), and
already almost entirely self-contained: every shared Home primitive it
needed (`BASIC_SKIP_SPACES`, `BASIC_MATCH_KEYWORD_BOUNDARY`, `BASIC_
EVAL_EXPR`, `BASIC_EXPECT_COMMA_EXPR`/`STATEMENT_END`, `BASIC_SET_
PENDING_ERROR`) was already in `KTAB_LIST` for other reasons — only
`GFX_SPRITE_CAPTURE`/`GFX_SPRITE_DRAW` (`kernel/graphics`) needed new
entries (`KTAB_COUNT` 30->32, `KTAB_MAGIC` 7->8). The checker's own
SPRITE validation (`rom/exrom_checker.asm`'s `.check_sprite`) was
already fully independent of this runtime code — grammar-only
(argument count/shape), not range/state — so this move needed zero
checker-side changes.

Moved verbatim (the whole family: `BASIC_STMT_SPRITE`'s own GRAB/SHOW/
HIDE dispatch, `BASIC_SPRITE_PARSE_SLOT`, the slot/buffer-address
helpers, the row/col/w/h range checks, and all six `MSG_SPRITE_*`
strings) into new `rom/exrom_sprite.asm`. `BASIC_RAISE_SYNTAX_ERROR`
(a bare `jp` target used twice in this block, not a KTAB-style `call`)
has no jump-table entry of its own and wasn't worth adding one for just
two call sites — duplicated locally as `SPRITE_RAISE_SYNTAX_ERROR`
instead. New fixed entry stub `EXROM_ENTRY_SPRITE` at `$C054` (the
fourteenth, `rom/exrom_checker.asm`'s entry-stub block). Home-side thin
wrapper `BASIC_SPRITE_EXROM` (`basic/basic.asm`) replaces the original
body; `BASIC_EXEC_STATEMENT_CONTENT`'s `.do_sprite` now calls it.

**Real result: +688 bytes Home ROM free** (159 -> **847 bytes**) at a
cost of ~720 bytes EXROM (2408 -> 1691 bytes free, still ample) — by
far the largest single shrink this project has done, confirming a
whole self-contained cold-path *feature* (not just one routine) was
the right thing to look for once the easy single-routine candidates
(`BASIC_FORMAT_STORAGE_STATUS`) were used up.

**Verified in the emulator** (`rom/test_sprite2.asm`): `SPRITE GRAB
0,1,1,2,2` / `SPRITE SHOW 0,5,5` / `SPRITE HIDE 0` in sequence, green
border — confirms the migration didn't break GRAB, SHOW, or HIDE, not
just that it assembles.

### Numeric arrays — Phase 3, part 4 (2026-08-22)

`DIM name(n)` and `name(i)` as both a read primary and an assignment
target — the "option 2" memory model from the design discussion: a
DYNAMIC region, not a fixed per-letter table like `VAR_TABLE`/
`STR_TABLE`. DIM'd arrays are appended right after program text
(`PROG_END`) and grow toward `PROG_AREA_MAX`, reset (`ARRAYS_END :=
PROG_END`) at the start of every `RUN` and at cold boot — array
capacity is limited only by whatever RAM the current program isn't
using, not a fixed slot count, and the reset makes it safe for the
editor to freely overwrite stale array bytes left by a prior run
without ever needing to relocate them (`MEM_LINE_INSERT`'s own space
check already just compares against the fixed `PROG_AREA_MAX` ceiling,
oblivious to whatever's sitting above `PROG_END`). 0-based indexing and
"can't re-`DIM` a name this run" are both deliberate simplifications,
not real-Sinclair-BASIC fidelity (which is 1-based and would need a
real reallocator to support clean re-DIMing).

**Record format**, deliberately including a `kind` byte even though
only one kind (numeric) exists yet: `[kind:1][name:1][count:2]
[data...]`. Designed this way specifically so a future string-array
kind — or, further out, unifying scalars into this same region, the
"option 3" path from the design discussion — can reuse `BASIC_ARRAY_
FIND`'s scan-by-name shape rather than needing an incompatible second
lookup mechanism. `BASIC_ARRAY_FIND` is a linear scan (not `VAR_TABLE`/
`STR_TABLE`'s O(1) address math — unavoidable once records are
variable-length, but cheap in practice at the handful of arrays any
real program actually declares).

**New pieces**: `BASIC_STMT_DIM` (parses `letter(size)`, validates
size>=1 and "not already DIM'd," checks the record fits before
`PROG_AREA_MAX`, zero-initializes); `.do_array_read` in `BASIC_EVAL_
PRIMARY` (array-index read, `BASIC_CHECK_ONLY`-guarded exactly like
`USR` — see below); `BASIC_TRY_ARRAY_ASSIGNMENT` (array-index write,
tried before the plain scalar assignment in the dispatch tail, same
reasoning `BASIC_TRY_STR_ASSIGNMENT` already established); `BASIC_
CHECK_ARRAY_ASSIGNMENT` (EXROM, grammar-only mirror, same "check pass
must not mutate real state" reasoning `BASIC_CHECK_STR_ASSIGNMENT`
already gives — doesn't call `BASIC_ARRAY_FIND` at all, since an array
referenced during a static whole-program pre-pass may not be DIM'd yet:
`DIM` is just another statement, not necessarily executed before the
one referencing it is checked). `MEM_FREE_BYTES` now subtracts
`ARRAYS_END` instead of `PROG_END`, so `FREE()` correctly reflects
array usage once any exist, with no branch needed either way (`ARRAYS_
END` tracks `PROG_END` exactly whenever nothing's been DIM'd).

**A real bug found and fixed, the dominant cost of this slice**:
the first draft stashed the array's own letter in `CUR_VAR_LETTER` —
the SAME shared scratch byte `BASIC_TRY_ASSIGNMENT`/`BASIC_STMT_DIM`
already use for their own "letter being assigned" bookkeeping.
Concretely: `B = A(0)` silently stored into **A's own `VAR_TABLE`
slot**, not B's — `BASIC_TRY_ASSIGNMENT` stashes `'B'` in `CUR_VAR_
LETTER`, then evaluating the RHS `A(0)` recurses into `.do_array_read`,
which overwrites the same byte with `'A'` before the OUTER assignment
ever reads it back to compute where to store the result. Exactly the
same "shared mutable scratch clobbered by a nested call" bug class as
the `FUNC_CALL_ID`/`ARGC` bug in `.do_function_call` (`MOD(ABS(X),3)`)
and the `DETOK_BUF` collision in `EDIT` — this project's third time
hitting this exact class, this time self-inflicted rather than
inherited. Caught by hand-tracing `B = A(0)` printing `0` instead of
`10` (isolated from the `+`-chain case that surfaced it first, `B =
A(0) + A(3)` printing `0` instead of `30`), not by static review.
Fixed by pushing the letter onto the real Z80 stack instead, in all
three routines that need it to survive a recursive `BASIC_EVAL_EXPR`
call — stack pushes naturally nest correctly no matter how deep that
recursion goes (confirmed against a genuinely nested case, `A(B(0)) =
99`), unlike one shared memory byte. `BASIC_STMT_DIM` only needed the
fix around its own size expression specifically (nothing after that
recurses again), so it was safe to keep using `CUR_VAR_LETTER` for the
rest of its body once the size is safely parsed and stashed.

**Verified in the emulator** (`rom/test_arr1.asm` through `test_arr8.
asm`, bisected the same way the bug above was found): `A(0)=10`/
`A(3)=20` read back correctly individually (`PRINT A(i)`) and combined
(`B = A(0) + A(3)` -> 30, both directly and via a plain `IF`/`BORDER`
check); a genuinely nested case (`A(B(0)) = 99` -> `PRINT A(1)` shows
99); all three runtime errors (`SUBSCRIPT OUT OF RANGE`, `ARRAY NOT
DIMENSIONED`, `ARRAY ALREADY DIMENSIONED`), screenshot-confirmed
against this project's standard error-report format; and a full
regression (`test_regr5.asm`) confirming plain numeric arithmetic and
string scalars/concatenation are unaffected.

**Cost**: ~551 bytes Home ROM (847 -> 290 bytes free — the largest
single language-feature cost of Phase 3, larger than the earlier
471-byte estimate mostly because of the stack-based letter fix above),
~114 bytes EXROM (1691 -> 1577 free). This was the numeric-array cost at
the time; string arrays were subsequently added as kind-3 records with
fixed 32-byte length-prefixed elements.

### DIMN(name) (2026-08-22)

Returns an array's declared size — `DIMN(A)` after `DIM A(5)` returns
`5`, while `DIMN(A$)` queries a string array. Lets a procedure loop over
an array without hardcoding its size,
e.g. `FOR i = 0 TO DIMN(A)-1`. Shares `FUNCTION_TABLE`'s dispatch shape
via a new sentinel, `ARGC_ARRAYNAME` (101, one higher than the existing
`ARGC_STR1` sentinel LEN/CODE/VAL use) — needed because `DIMN`'s own
argument is a bare array-name **letter**, never evaluated as an
expression the way every real numeric function argument is (a plain
`DIMN(A)` would otherwise misread `A` as a scalar-variable read).
EXROM-resident from the start (`rom/exrom_arrays.asm`, `ARRAY_EXROM_
DIMN`) — small and cold enough (typically evaluated once per loop
setup, not once per iteration, since a `FOR` loop's own `TO` bound is
evaluated at entry) that Home ROM budget never favored bringing it
Home the way `BASIC_ARRAY_FIND`/read/write stayed there.

**A real bug found and fixed, caught by the SAME whole-program static
check `.do_array_read`'s own `BASIC_CHECK_ONLY` guard exists for**:
the first draft had no check-mode guard at all — `DIMN(A)` called the
real `BASIC_ARRAY_FIND` lookup unconditionally, including during the
static check pass, where `A` may genuinely not be `DIM`'d yet (`DIM` is
just another statement, not necessarily executed before the one
referencing it is checked — the exact same reasoning `BASIC_CHECK_
ARRAY_ASSIGNMENT`'s own header already documents). A program using
`DIMN` correctly at runtime failed its own whole-program check with a
spurious `ARRAY NOT DIMENSIONED`, screenshot-confirmed as yellow
(check-failed) instead of the real program's own green verdict. Fixed
by adding the identical guard: parse and validate grammar unconditionally
(the letter, the closing paren — these don't touch array state), but
skip the real `BASIC_ARRAY_FIND` call and return a harmless `0` when
`BASIC_CHECK_ONLY` is set, exactly like every other array-referencing
check-mode path in this codebase already does.

### Multi-dimensional arrays (archived, 2026-08-22)

Built in full the same day as `DIMN` above — `DIM name(rows,cols)`,
2D-aware array read/write, and a two-argument `DIMN(name,dim)` — then
**archived** (removed from the active codebase, not deleted from
history) once its real Home ROM cost was actually measured rather than
estimated. Recorded here so the design doesn't have to be re-derived
if this is ever worth reviving.

**Record format**: kind byte genuinely two-way — kind 0 (1D, the
still-active format above) is `[0][name][count:2][data]`; kind 1 (2D)
was `[1][name][rows:2][cols:2][data]`, data being `rows*cols*2` bytes
either way (every element still a plain 2-byte signed integer).
`BASIC_ARRAY_FIND`'s own Out contract changed to accommodate a
variable-length header: `A` = kind, `HL` = pointer to the record's
*first size field* (not the data start) — every caller already had to
branch on kind to know how many subscripts/DIM sizes it was dealing
with, so reading count/rows/cols/data-start as fixed offsets off that
one pointer cost nothing extra there (1D: count at `HL`, data at
`HL+2`; 2D: rows at `HL`, cols at `HL+2`, data at `HL+4`).

**New/changed pieces**: `BASIC_ARRAY_PARSE_SUBSCRIPTS` (new, shared
by read and write — parses one-or-two comma-separated index
expressions and the closing `)`, deliberately not yet knowing the
array's real dimensionality, which is a runtime-only question exactly
like existence/bounds already were); `BASIC_ARRAY_ELEMENT_ADDR` (new,
also shared — validates the parsed subscript *count* against the
array's real (looked-up) dimensionality via a new `ARGC`-style check,
then bounds-checks and computes the element address, branching on
`kind` for the 2D case's `row*cols+col` address math via
`MATH_MULTIPLY16`); a new error class, folded into the existing
`SUBSCRIPT OUT OF RANGE` message rather than getting a dedicated
string (a 1D array read/written with 2 indices, or a 2D one with 1, is
close enough to the same idea); `DIM`'s own grammar gained an optional
`,<size2>` — a comma after the first size expression switches the
whole DIM to 2D, with `0` doing double duty as "this DIM is 1D" sentinel
for the (otherwise never legitimately zero) second-dimension scratch
field.

**The EXROM/Home tug-of-war** (worth recording since it's the actual
reason this got archived, not a correctness problem): the read/write
rewrite above was a net Home ROM *win* on its own (shared helpers
beat the old duplicated 1D-only logic), but `DIM`'s own 2D-aware body
alone pushed Home ROM well over budget. It was moved to EXROM
(matching the established "cold statement, move it whole" pattern);
that overflowed EXROM's own cap instead, by a similar margin, since
DIM+DIMN together needed more room than EXROM had free at the time.
Real, measured numbers, not estimates: with 2D DIM Home-resident,
Home ROM was over budget by ~26 bytes even after real optimization
effort (three separate rounds — reusing a shared header-size/kind
computation instead of recomputing it after a destructive subtraction,
folding a whole duplicate error message into an existing one, removing
now-redundant helper `CALL`/`RET` pairs); with it EXROM-resident
instead, EXROM was over by ~69 bytes. Home's own deficit was smaller,
so 2D DIM landed back Home-resident briefly — before being archived
outright once weighed against what it was actually buying: in an
integer-only dialect, a 2D array is mostly array-of-arrays territory a
1D array plus a bit of index arithmetic already covers, and the
judgment call was that 2D didn't clear the bar over that, at the
measured cost. `DIMN` alone survived, simplified back to a single
argument (see above) — genuinely useful and cheap on its own without
`DIM` needing to move alongside it.

**Fully built and verified before archival** — not a prototype cut for
being broken: `DIM A(3,4)`, 2D read/write with correct `row*cols+col`
addressing, bounds-checking on both indices independently, `DIMN(A,1)`/
`DIMN(A,2)` returning rows/cols respectively, and the subscript-count
mismatch error all worked correctly in the real emulator before the
scope decision was made. `check_asm.py` was clean throughout (no stack-
discipline fingerprints introduced). The snapshot this section
describes is not preserved as dead code in the tree — reviving it
means re-deriving the record format and the read/write rewrite above,
using this section as the map, not resurrecting a commented-out branch.

### STICK() (2026-08-22)

`STICK(device)` — a real Sinclair BASIC function, confirmed from the
ROM disassembly's own `STICK`/`READ-STICK`/`TEST-STICK-ARG` routines:
reads the AY-3-8912's I/O port A (register 14 — `PORT_AY_REG`/`PORT_
AY_DATA`, the same two ports `SOUND` already writes to, this project's
first time *reading* from the chip). `device` must be 1 or 2 (two
joystick ports); out of range raises `INVALID ARGUMENT` — the real
ROM's own `REPORT-A` text. New `kernel/io`'s `STICK_READ` does the real
port work: select register 14, read it back, complement (active-low ->
active-high), then branch on device via `DJNZ` exactly like the real
`READ-STICK` does. The bit-decode asymmetry is a confirmed hardware
fact, not a design choice: device 1 gets a full 4-bit direction nibble
(`AND $0F`, with an "all four bits set" edge case forced to 0, matching
the real ROM's own `CP $0F` check); device 2 only gets a single bit
(`RLCA` + `AND $01`).

**Not verifiable by simulated input**: this sandbox has no way to
inject joystick presses into Fuse (same class of limitation as `BEEP`'s
pitch/duration) — what's verified is the plumbing (grammar accepted,
the port read completes without hanging, a value comes back, the
range-check error fires correctly), not that a specific stick movement
produces a specific returned value.

**A real false-positive bug found and fixed, not just the plumbing**:
the first draft validated `device` unconditionally, with no `BASIC_
CHECK_ONLY` guard. Since this routine (via `BASIC_EVAL_EXPR`'s own call
chain) is also what the whole-program checker uses to validate
expression grammar, a **variable** argument broke it: `N = 1: PRINT
STICK(N)` was rejected outright at check-time, because check-time
assignment is deliberately non-mutating (`BASIC_CHECK_ASSIGNMENT`'s own
header) — `N` reads whatever stale value its `VAR_TABLE` slot already
held, not the `1` the program actually assigns once it really runs.
Unlike `USR`/array-reads, this wasn't a crash risk, just a program that
would have run perfectly rejected outright — but the fix is identical:
skip real validation when `BASIC_CHECK_ONLY` is set, matching this
project's established guard exactly. One side effect, correctly
accepted rather than fought: a **literal** out-of-range call like
`STICK(3)` no longer gets caught early at check-time either (previously
it incidentally was, the same way a literal `DIVISION BY ZERO` gets
caught early) — it now surfaces at real runtime instead, verified
screenshot-confirmed against this project's standard error-report
format. Trading that early-catch nicety for correctness on the much
more common variable-argument case is the right call.

**Verified in the emulator** (`rom/test_stick1.asm` through
`test_stick4.asm`): `STICK(1)`/`STICK(2)` both execute and return a
value without hanging (0, consistent with "no joystick connected");
`STICK(3)` correctly raises `INVALID ARGUMENT` — at real runtime, not
check-time, confirmed by checking `CHECK_ERROR_COUNT` explicitly before
and after the guard fix; `N = 1: PRINT STICK(N)` now runs to completion
instead of being incorrectly rejected by the checker.

### String functions — Phase 3, part 5 (2026-08-22)

Eight string-returning functions (`CHR$`, `STR$`, `UPPER$`, `LOWER$`,
`LEFT$`, `RIGHT$`, `INKEY$` — upgraded from the plain-integer version,
see that section above), plus three number-returning functions that
take a string argument (`LEN`, `CODE`, `VAL`). All EXROM-resident
transform logic (`rom/exrom_strfuncs.asm`, reached through a single
shared entry point dispatching on `STR_FUNC_CALL_ID` — the same
pattern `SOUND_EXROM`/`BASIC_STMT_SPRITE` already established, cheaper
than a stub per function). Home-side argument-parsing glue is grouped
by shape (one numeric arg / one string arg / string+numeric / zero
args) for the same space reason. `LEN`/`CODE` stayed Home-resident —
trivial enough (read a length byte, or the first content byte) that an
EXROM round trip would cost more than the routine itself; `VAL` calls
through EXROM like the string-returning functions, dispatching on a
*different* ID space (`STRFUNC_ID_VAL`, distinct from the numeric
`FUNCTION_TABLE`'s own `FUNC_ID_VAL`, since the two tables serve
different callers — see `STRING_FUNCTION_TABLE`'s own comment in
`basic/basic.asm`).

**`FILL$` and `INSTR` dropped (2026-08-22)**, mid-implementation, once
Home ROM was measured 509 bytes over its 16K cap even after every
transform moved to EXROM. Dropping both — `INSTR` especially, whose
own two-simultaneous-string-buffer argument parsing was a large
dedicated Home-side block — reclaimed 113 bytes; the remaining 396
came from migrating `kernel/editor` to EXROM whole (see below). Their
EXROM bodies, Home dispatch entries, and dedicated `STRFN_*` named
scratch (`include/sysvars.inc`) were all removed cleanly, not just
disabled — nothing references them any more, and `STR_FUNC_POOL`'s own
4-slot sizing (kept as-is) is now justified purely by nested calls
like `UPPER$(LEFT$(A$,3))` rather than `INSTR`'s original two-buffer
need.

**A real bug caught before shipping, same family as this project's own
`FUNC_CALL_ID`/`CUR_VAR_LETTER` fixes**: the first draft stashed the
caller's destination buffer and budget — and each argument shape's own
acquired `STR_FUNC_POOL` buffer address — in shared sysvars before
parsing the argument(s). A string-function call nested inside another
one's own argument (`UPPER$(LEFT$(A$,3))`) recurses back through the
exact same dispatch and clobbers those shared cells before the outer
call ever reads them back. Fixed by moving all of it onto the real
Z80 stack instead (pushed once at entry, popped back immediately
before the final EXROM call), which nests correctly at any depth for
free.

**Two further real bugs, both caught only by live emulator testing** —
static review and hand-tracing missed both, matching this project's
own established "replaying the actual instructions catches what
reasoning about them doesn't" lesson:

1. `BASIC_PARSE_STR_ARG_TO_POOL` (the routine factored out to share
   the duplicated "acquire a pool slot, parse the argument into it"
   sequence across all four argument shapes) called `STR_FUNC_POOL_
   ACQUIRE` — which clobbers `HL` with the acquired buffer's address —
   and then called `BASIC_EVAL_STR_EXPR` *without reloading `HL`* with
   the actual text to parse first. The original, pre-extraction code
   had exactly this reload; it was dropped by accident during the
   extraction and nothing caught it until a real string-function call
   with any argument at all (literal or variable) was actually
   exercised — `PRINT UPPER$("hello")` fed the buffer's own address to
   the parser as if it were source text.
2. Once (1) was fixed, `PRINT UPPER$(A$)` still failed the whole-
   program check. `BASIC_EVAL_STR_EXPR`/`BASIC_EVAL_STR_PRIMARY` only
   ever advance the `HL` *register* on return — they never write the
   advanced position back into `EXPR_PARSE_PTR` themselves (every
   existing caller either used `HL` directly right afterward, or
   happened not to clobber it first). `BASIC_PARSE_STR_ARG_TO_POOL`'s
   own very next instruction after the parse call, `pop hl` (retrieving
   the buffer address), silently discarded that advanced `HL` before
   this routine's own documented "`EXPR_PARSE_PTR` = position just past
   the parsed expression" contract was ever actually honored. Every
   caller's own subsequent `")"`/`","` check then read the *stale*
   pre-argument position — e.g. seeing the argument's own opening quote
   where it expected a closing paren. Fixed by saving `HL` into
   `EXPR_PARSE_PTR` immediately after the parse call succeeds, before
   anything else gets a chance to clobber the register.

Debugging method for both: per-branch border-color instrumentation
(`out (PORT_ULA),a` at each failure point, distinct colors, an
infinite `jr` loop right after so the color is a stable signal, not a
one-frame flicker) bisected across several isolated single-statement
test programs — `PRINT UPPER$("hello")` alone, `PRINT UPPER$(A$)`
alone, `IF UPPER$(A$) = "..." THEN ...` alone — narrowing from "the
checker rejects the whole program" down to the exact instruction. One
real false-alarm along the way, worth remembering for future
debugging: a content-mismatch diagnostic fired even after both real
bugs were fixed, because the checker evaluates `IF` conditions **for
real** (`BASIC_CHECK_STATEMENT_CONTENT`'s `.check_if` calls `BASIC_
EVAL_CONDITION` unconditionally) while `A$` genuinely isn't assigned
yet during checking (`BASIC_CHECK_STR_ASSIGNMENT` deliberately discards
its own result — "check pass must not mutate real state") — gating the
diagnostic on `BASIC_CHECK_ONLY` cleared it immediately, confirming it
was a check-pass artifact, not a third bug.

**A third, smaller real bug**: `rom/exrom_checker.asm`'s own `.check_
print` (the whole-program checker's `PRINT`-statement grammar
validator) never learned about string-function-call syntax at all when
this feature first landed — it only recognized a quoted literal or a
bare string variable before falling to the numeric expression path, so
`PRINT UPPER$(A$)` failed the whole-program check with a plain `SYNTAX
ERROR` despite executing correctly once reached. Fixed by adding the
same `BASIC_TRY_EVAL_STR_FUNCTION` / `BASIC_EVAL_STR_FUNCTION_CALL`
probe real execution's own `BASIC_STMT_PRINT` already had, writing into
`STR_EXPR_SCRATCH` (the same "safe to overwrite during a check pass"
buffer `BASIC_CHECK_STR_ASSIGNMENT` already used). `IF`'s own string
comparison needed no equivalent fix — it already reaches the real,
already-fixed `BASIC_EVAL_COMPARISON` transitively through the
existing `KTAB_BASIC_EVAL_CONDITION` entry, so fixing `BASIC_EVAL_
COMPARISON` itself (see below) was sufficient.

**A fourth bug, in the peek logic itself**: `BASIC_EVAL_COMPARISON`'s
own string-vs-numeric peek (added new for this feature) needed to
recognize a string-function-call name, not just a quoted literal or a
bare `letter$` variable, before committing to the numeric path.
Turned out to be a non-issue once traced through carefully — the
existing "letter, but next char isn't `$`" fall-through already lands
on the new `.maybe_str_func` check with no extra jump needed, since
every string function name is 2+ letters before its own `$` and none
of them collide with the bare-variable shape — but this was
specifically re-verified (not assumed) given how easy it would have
been to get wrong.

**Verified in the emulator**, end to end, after all four fixes:
`UPPER$`/`LOWER$`/`LEFT$`/`RIGHT$`/`CHR$`/`STR$`/`LEN`/`VAL` on both
literals and variables; a genuinely nested call
(`UPPER$(LEFT$(A$,5))`); `PRINT` of a function-call result directly;
`IF <string-function-call> = "literal" THEN ...` and `IF LEN(...) = n
THEN ...`; numeric arrays and `SOUND`/`BEEP` alongside all of the
above in one combined program, confirming no regression from either
this feature or the `kernel/editor` migration below (they share the
same EXROM image, jump table, and Home-side wrapper convention).

Final measured budget after both this feature and the `kernel/editor`
migration: **Home 245 bytes free / EXROM 398 bytes free** (from the
assembler's own listing, not estimated) — comfortably positive, versus
509 bytes negative partway through, before the editor migration closed
the gap.

### kernel/editor moved to EXROM (2026-08-22)

A ROM-shrink migration, same shape as the checker/`SAVE`/`LOAD`/`HELP`/
calculator/`SOUND`/`SPRITE`/string-functions moves before it, but
larger: the *whole* full-screen editor module (`kernel/editor/
editor.asm`, 711 bytes) moved to `rom/exrom_editor.asm`, needed because
the string-functions feature alone still left Home ROM hundreds of
bytes over budget even after dropping `FILL$`/`INSTR` and sharing
duplicated argument-parsing code.

**Why this one specifically, out of everything still Home-resident**:
surveyed first (real byte counts from the assembler's own listing, not
guessed) — `basic/basic.asm` itself dwarfs every kernel module
(10,848 bytes vs. `kernel/graphics.asm`'s 2,890, the next largest), and
the graphics statement handlers (`PLOT`/`LINE`/`BLOCK`/`CIRCLE`/etc.)
were both too small combined (~373 bytes, not enough alone) and too
risky (they'd need ~10 new `KTAB` entries for shared Home helpers like
`BASIC_EVAL_EXPR` they don't currently route through EXROM, plus
`PLOT` specifically risked real per-pixel repaging overhead in a tight
drawing loop). `kernel/editor` was large enough alone (711 bytes,
closing the whole remaining 396-byte gap) and, once actually traced
through, had no such hot-loop risk — see below.

**Seven entry points** basic/ calls from Home got fixed EXROM stubs
(`rom/exrom_checker.asm`, `$C060`-`$C089`): `EDITOR_INIT`, `EDITOR_
ENTER`, `EDITOR_WRAP_CALC`, `EDITOR_WRAP_TABLE_ADDR`, `EDITOR_WRAP_
OFFSET_TO_ROWCOL`, `EDITOR_WRAP_ROWCOL_TO_OFFSET`, `EDITOR_BLOCK_
DELETE` — each with its own thin `BASIC_EDITOR_*_EXROM` Home-side
wrapper (`basic/basic.asm`, same "page in / call the fixed entry /
page out" shape as every wrapper before it). `EDITOR_EXIT`/`INSERT_
CHAR`/`DELETE_CHAR`/`BACKSPACE`/`MOVE_CURSOR`/`SEARCH` got no stub —
they're never called from `basic/` directly, only internally from
within `EDITOR_ENTER`'s own loop, matching every prior migration's
"only externally-reached entries get a stub" rule. Six new `KTAB`
entries cover the editor's own external calls back into Home:
`GFX_INVERT_ATTR`, `IO_READ_KEY`, `MEM_FILL_ZERO`, `MEM_SHIFT_UP`,
`MEM_SHIFT_DOWN`, `MEM_LINE_DELETE_RANGE` (`GFX_CLS`/`GFX_PRINT_
STRING` were already in the table for other reasons).

**Paging design, reasoned through before implementing, then confirmed
live**: `EDITOR_ENTER` runs the *entire* interactive editing session —
every keystroke — through its own internal `EDITOR_LOOP` before ever
returning to Home; `BASIC_EDITOR_ENTER_EXROM` therefore pages EXROM in
once and leaves it paged in for the whole session, rather than
per-keystroke. This is safe specifically because: (a) `EDITOR_NAV_
HOOK`/`EDITOR_REDRAW_HOOK` (set by `basic/` to its own Home routines,
for keyword-highlighted redraw and multi-line cursor navigation) are
invoked via a bare `jp (hl)` straight into Home, which works regardless
of chunk 6's paging state since Home ROM ($0000-$3FFF) is always
mapped there independent of what's paged into chunk 6 ($C000-$DFFF);
(b) if a Home-side hook itself needs to call back into EXROM (e.g. the
redraw hook re-running `EDITOR_WRAP_CALC` once per visible program
line during a multi-line redraw), `BANK_EXROM_DEPTH` (`kernel/bank/
bank.asm`, already nesting-safe) makes that a cheap counter bump, not
a real second port write; (c) nothing this project's sysvars use lives
in chunk 6, so keeping it paged to EXROM for a potentially minutes-long
editing session doesn't disturb anything else.

**Single editor source established 2026-08-27**: the original migration
left `kernel/editor/editor.asm` and `rom/exrom_editor.asm` as two manually
maintained copies. They had already drifted, meaning the standalone editor
test could exercise older logic than production. `rom/exrom_editor.asm` is
now canonical. `kernel/editor/editor.asm` is a small compatibility adapter
that aliases the production body's eight `KTAB_*` external-call names to
their direct Home routines, then includes that same body. Existing Home-only
test harnesses therefore keep building, but production and test editor logic
can no longer diverge. A future new external dependency also fails the
standalone build until its alias is deliberately added, providing the
automated tripwire the original migration lacked.

**Verified in the emulator, interactively** (synthetic X11 keystrokes
via `python-xlib`'s XTest extension, sent to the real Fuse window —
`d.keysym_to_keycode`/`xtest.fake_input`, window focus set explicitly
first): booting `rom/test_basic.asm` + `exrom.bin` normally (no preload
harness) reached the live "NEW LINE" edit status bar correctly
(`EDITOR_INIT`/`EDITOR_ENTER` running from EXROM); typing `print`
appeared character-by-character and redrew correctly (`EDITOR_INSERT_
CHAR`/`EDITOR_REDRAW_SCREEN`, including the cursor's own inverse-video
block, all now EXROM-resident); pressing ENTER correctly committed it
as a permanent program line and returned to a fresh "NEW LINE" state
(`EDITOR_EXIT`'s own commit path). No hang, crash, or display
corruption across sustained interactive use — the main risk this
migration's own paging design was reasoned through for.

**This original verification was wrong — see the real bug below.**
"typing `print` appeared character-by-character" did not actually hold
up; the earlier check evidently didn't catch it (most likely a
screenshot taken after too few keystrokes, or before the second
character's own redraw had happened, made the active line look
correct when it wasn't). Left in place above, unedited, as a record of
what was believed at the time — corrected here instead of rewritten
away.

### Real bug: only the first character of the active line ever
### rendered, though the full typed text was always stored correctly
### (2026-08-23, user-reported)

**Symptom**: typing on a fresh/active line — either a brand-new
uncommitted line or an existing one being re-edited — only ever showed
the FIRST character on screen; every character after it was invisible
(rendered as blank space), no matter how many more were typed. The
cursor's own inverse-video block still tracked the TRUE typed length
correctly (e.g. landing 4 cells to the right after 4 real keystrokes),
and pressing ENTER always committed/dispatched the FULL typed text
correctly (e.g. `HELP` still opened the HELP screen) — only the
glyphs themselves failed to draw. This made the editor look almost
unusable while actually being logically sound underneath, which is why
it survived this far without being caught by the test suite (`tests/`
never drives real keystrokes — see `tests/README.md` — and the
"verified... typing `print`" note above turned out to be a bad manual
check, not a real one).

**Root cause**: every EXROM entry stub's own preamble
(`EXROM_VERIFY_KTAB_MAGIC`, `rom/exrom_checker.asm`) loads the magic
byte into `A` before comparing it against `KTAB_MAGIC` — unconditionally
clobbering whatever a caller had put in `A` as a real argument, before
the real routine ever runs. `BASIC_EDITOR_WRAP_TABLE_ADDR_EXROM`
(`basic/basic.asm`, the Home-side wrapper for `EDITOR_WRAP_TABLE_ADDR`,
listed as one of the seven entry points above) is the one place this
project ever routed a routine through the standard trampoline
(`BANK_PAGE_EXROM_IN` — which also uses `A` internally — then the
magic-checked entry stub) that genuinely needed `A` as a real input
(the wrap-table row index), not just `HL` (the table base) — every
other EXROM call in the project only ever needs `HL`/`DE`/`BC` across
this boundary, so this exact class of bug had no earlier chance to
surface. The practical effect: `BASIC_PRINT_LINE_WRAPPED_COMMON`'s own
print loop (used for the active/uncommitted line, always rendered
plain/unhighlighted) read `EDIT_WRAP_LEN[KTAB_MAGIC's own byte value]`
instead of `EDIT_WRAP_LEN[0]` — some unrelated fixed byte instead of
the row's real content length — so the loop's own `col < row_len` exit
check tripped almost immediately, after drawing only one character.
The cursor's own positioning was unaffected because it's computed by
`EDITOR_WRAP_OFFSET_TO_ROWCOL`, which calls `EDITOR_WRAP_TABLE_ADDR`
*internally*, EXROM-resident-to-EXROM-resident, via a bare `call` —
no trampoline, no clobbered `A` — which is exactly why the cursor
always landed in the right place while the glyphs behind it didn't
render: two different code paths computing the same kind of address,
only one of which went through the broken trampoline.

**Found via**: real-emulator border-color instrumentation, this
project's own established method (see `README.md`'s "Debugging
method" note on the string-functions bug) — one probe placed right
after `EDITOR_WRAP_CALC` populates the wrap tables (showed the correct
length), a second placed right after the print loop's own read of
`EDIT_WRAP_LEN` via the trampoline (showed a wrong, fixed value) —
bisecting the discrepancy down to the trampoline call in between in
two steps.

**Fix**: the two `BASIC_EDITOR_WRAP_TABLE_ADDR_EXROM` call sites
(`BASIC_PRINT_LINE_WRAPPED_COMMON`) now inline the 4-instruction
`HL = table_base + index` computation directly instead of routing it
through EXROM at all — it never needed to leave Home in the first
place, since `EDIT_WRAP_START`/`EDIT_WRAP_LEN` are ordinary Home RAM,
readable regardless of chunk 6's paging state. The now-unused
`BASIC_EDITOR_WRAP_TABLE_ADDR_EXROM` wrapper was removed; its `$C072`
EXROM entry stub (`rom/exrom_checker.asm`) was deliberately left in
place unused rather than removed, to avoid renumbering every fixed
entry address after it for a 6-byte EXROM saving. Net Home ROM cost:
slightly negative (inlining is smaller than the trampoline call it
replaced) — measured 194 -> 199 bytes free.

**Re-verified live** (same X11-keystroke method as the original,
now-corrected check above): typing multi-character text on both a
fresh new line and a re-edited existing line renders every character
correctly, including past a 32-column word-wrap boundary; the full
regression suite (`tests/` — all 38 files) still passes green with no
change afterward, confirming no regression. Separately re-confirmed
UP/DOWN navigation, character-level backspace (`CAPS SHIFT+0`),
whole-line delete (`CAPS SHIFT+1`), insert-line (`CAPS SHIFT+ENTER`),
and keyword highlighting on committed lines all still work correctly —
none of them touch the routine this bug was in.

### Real bug: cursor position on wrapped lines stuck at a fixed
### column, not the true typing position (2026-08-23, user-reported)

The same bug CLASS as the one directly above, found separately by the
user a short time later: "flashing cursor in editor on long lines is
not matching typing cursor - always appears to be the same place
position column 13." Every EXROM entry stub's magic-check preamble
(`EXROM_VERIFY_KTAB_MAGIC`) clobbers `A` before the real routine runs —
`EDITOR_WRAP_OFFSET_TO_ROWCOL`'s own entry stub
(`EXROM_ENTRY_EDITOR_WRAP_OFFSET_TO_ROWCOL`, `$C078`) is a second place
in the project that needed `A` as a real argument (the cursor's buffer
offset) across that same broken trampoline shape — the first being
`EDITOR_WRAP_TABLE_ADDR` above. All three of that routine's Home-side
callers (two in `BASIC_HANDLE_NAV`'s wrapped-row Up/Down logic, one in
`BASIC_REDRAW_PROGRAM`'s own cursor-draw step) load `A` from
`EDIT_BUF_OFFSET` immediately before calling in, so every call actually
ran against the same fixed garbage byte (the entry stub's own
`KTAB_MAGIC` value) instead of the real cursor position — a CONSTANT
wrong offset produces a CONSTANT wrong (row, column), matching "always
the same place" exactly.

Audited every other EXROM entry stub's own documented `In:` contract
(`rom/exrom_checker.asm`) for this same pattern once this one was
found, to make sure no third instance was still lurking — every other
entry either takes no register input, or takes it in `HL`/`DE`/`BC`
(all of which the trampoline genuinely does preserve; only `A` is
destroyed by `BANK_PAGE_EXROM_IN` and the magic-check). None found.

**Fix**: rather than growing the entry stub itself (which would have
meant shifting the `ORG` for every fixed stub after it — see rom/
exrom_checker.asm's own header for why every stub is a fixed 6 bytes),
`EDITOR_WRAP_OFFSET_TO_ROWCOL` (`rom/exrom_editor.asm`) now reads
`EDIT_BUF_OFFSET` directly from memory as its own first instruction,
instead of trusting `A` to have survived the trampoline. This changes
nothing about what value is actually used — every real caller already
loaded `A` from that exact sysvar immediately before calling in — only
where it's read from. No sysvar/KTAB changes needed, unlike the
`EDITOR_WRAP_TABLE_ADDR` fix above.

**Verified live**: typed a line long enough to word-wrap onto a second
row (`PRINT 1 2 3 ... 16`, wrapping after "11"); the cursor block
correctly landed right after "16" on the second row, and continued
tracking correctly as more text was typed past that point (screenshot-
confirmed at each step). Full `tests/` regression suite (38 files)
re-confirmed green afterward.

### Automated editor/typing regression test (2026-08-23)

Both bugs directly above were found via live X11-synthetic-keystroke
testing, then confirmed fixed the same way — but that method needs a
human-equivalent keyboard driver and was explicitly retired mid-session
("can you not load up programs anymore via python?"), and neither
`rom/test_editor.asm` (interactive, assembles the canonical editor body
through `kernel/editor/editor.asm`'s direct-call compatibility adapter —
no trampoline/register-survival risk, so it structurally can't exercise
the boundary either bug lived in) nor a same-file unit test of
`rom/exrom_editor.asm` in isolation would ever cross the real Home<->EXROM
boundary these bugs were actually in. `rom/test_editor_auto.asm` closes
that gap: a
non-interactive harness that replaces `RST_38`'s target with a small
injector writing `KBD_LASTK`/`KBD_KEYHIT` from a fixed key queue
instead of a real matrix scan (same single-writer contract
`kernel/interrupt`'s real `KBD_ISR_TICK` already relies on — see that
sysvar's own comment in `include/sysvars.inc` — just substituted whole,
not raced against), then calls the real, unmodified
`BASIC_COMMAND_LOOP` and lets `EDITOR_ENTER`/`EDITOR_LOOP`
(`rom/exrom_editor.asm`) run genuinely unmodified against the real,
shipped `exrom.bin`, through the real KTAB boundary.

One test case exists so far: 33 no-space characters (forces
`EDITOR_WRAP_CALC`'s hard-break path), checked against (1) the typed
buffer content and (2) `EDITOR_WRAP_OFFSET_TO_ROWCOL`'s real
production call path returning the hand-computed correct row/column —
a direct regression check on the exact routine the column-13 bug lived
in. The key queue deliberately omits `KEY_ENTER`: committing the line
would let `BASIC_COMMAND_LOOP` race ahead and re-zero the edit buffer
before verification (which runs from inside the injector itself, once
the queue drains and the last key is consumed) ever read it; parking
mid-edit avoids that race, and doubles as the test's own natural halt
state. Verified in both directions before trusting it — the real
checks show green, a deliberately-wrong expected value (reverted
immediately) shows red — confirming genuine pass/fail discrimination,
not a harness that always reports green. See `README.md`'s own
"Automated (non-interactive) editor/typing regression test" section
for the build/run commands and the full technique writeup; extending
this to INSERT/DELETE/BACKSPACE/navigation/multi-line scenarios is
future work, using the same technique with different queued key
sequences.

### Testing

`rom/test_basic.asm` is the ongoing full-pipeline integration test —
typing, tokenizing, storing, iterating, executing, displaying output,
and now real navigation between lines. Interactive, `REPL`-style: type
a statement, ENTER, type `RUN`, ENTER, repeat — or press `UP` to edit
a previous line. See the test file's own header for worked examples.

## Still to document
- kernel/interrupt (not yet written)

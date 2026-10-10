# R10.7 — Source-Staging Architecture Audit

Date: 2026-10-04. Originally a read-only investigation (§0-§7 below);
§8 records a follow-up session's actual implementation of the C/D
recommendation, its validation, and the resulting capacity accounting.
Continues the R10.7 dormant-architecture audit (`docs/v2/
R10_7_DORMANT_ARCHITECTURE_AUDIT.md`) and its post-audit cleanup.

## 0. The question

Why does `V2_BUILD_SOURCE` need a complete 4096-byte staging copy of the
authoritative source, and can the compiler consume authoritative source
directly, or with a substantially smaller transient representation?

**Short answer, established below with concrete evidence**: the full 4096 B
copy is not fundamentally necessary. It exists because it gives the lexer
the simplest possible contract (one flat, `$00`-terminated byte stream it
can pointer-walk with no boundary awareness at all), not because the
underlying source representation requires a full-size flattened copy to be
usable. Authoritative source is already contiguous, already length-navigable,
and the project already has a proven, shipping pattern — identical in shape
to what a small chunked buffer would need — for turning one packed source
record into a flat scratch copy on demand (§6). A buffer on the order of
~256 B, not 4096 B, is sufficient to preserve that same simple lexer contract
for the overwhelming majority of real programs, at the cost of one adapted
routine and one new call site, not a lexer-wide rewrite.

---

## 1. Source lifecycle (unchanged from the prior pass, restated for this document)

| Stage | Address/range | Representation | Contiguous? |
|---|---|---|---|
| Authoritative source | `PROG_AREA_START`=$8455 .. `PROG_END`, max `V2_SOURCE_END`=$9455 (**4096 B**) | records `[2-byte length][content…][$0D]`, packed with no gaps (`MEM_LINE_INSERT`/`DELETE_RANGE` physically shift bytes to keep it that way, always) | Yes, always |
| Staging buffer | `V2_SOURCE_STAGE`=$9455 .. `V2_CODE_BASE`=$A455 (**4096 B**) | flat bytes, headers stripped, one `$0D` per statement (suppressed after a trailing `:`), final `$00` | Yes (fresh copy) |
| Bytecode | `V2_CODE_BASE`=$A455 .. `V2_CODE_LIMIT`=$B400 (**4011 B — see §2**) | VM opcode stream | Yes |

**Bytecode figure correction**: the current bytecode reservation is
**`$A455`–`$B400` = 4011 bytes**, confirmed directly from `include/
v2_layout.inc`'s `V2_CODE_BASE`/`V2_CODE_LIMIT` constants. No smaller
enforced ceiling exists anywhere in the compiler. Any document still citing
~2731 B predates the R10.7 capacity work and should be treated the same way
this audit's predecessor treated `R9_CUTOVER_LEDGER.md`'s stale RAM table —
correct going forward, not retroactively edited here (read-only scope).

Full instruction-level trace of `V2_BUILD_SOURCE`, every consumer of
staging, and the proof that compilation is strictly forward-only with no
backward or random source access, were already established in the prior
pass and are not re-derived here; see that document's §2 if the full
citations are needed. The one fact this document leans on repeatedly:
**no compiler routine ever writes into the staging buffer** (verified
against every `ld (hl),a`-shaped write site in `rom/exrom_v2_compiler.asm`;
all target `EMIT_PTR` or symbol-table entries).

---

## 2. Two new, load-bearing facts for this document

### 2.1 The editable line length ceiling

`EDIT_LINE_BUF_LEN EQU 128` (`include/sysvars.inc:70`), asserted
`<= 128` (`:1201`). This is enforced at the point of typing — **the editor
itself cannot accept a single line longer than 127 content bytes**. This is
the single most important fact for sizing any alternative buffer: it is a
hard, pre-existing ceiling on how much content one source record can ever
hold, independent of anything proposed here.

### 2.2 The project already has the exact mechanism Alternatives C/D need — twice, in production, today

Both already exist, unconditionally shipping:

- **`V2_LOAD_EDIT`** (`rom/exrom_v2_shell.asm:537-557`): when a stored line
  is opened for editing, it copies that ONE record's content — skip the
  2-byte length header, stop at `$0D`, 127-byte cap via a `djnz`-counted
  loop — into `EDIT_LINE_BUF`, NUL-terminated. This is regenerated from
  authoritative source every time a line is opened, and discarded (not
  written back until commit, at which point it's re-tokenized into a fresh
  record).
- **`V2_COPY_RECORD`** (`rom/exrom_v2_shell.asm:1570-1579+`), used by
  `V2_LIST`: identical shape — skip the header, copy content, stop at
  `$0D`, 127-byte cap — into `DETOK_BUF` (`include/sysvars.inc:386`, 128
  bytes, immediately following `EDIT_LINE_BUF`). `V2_LIST` calls this once
  per line, then runs `V2_KW_DETECT_SPANS` (bolding) and `V2_DRAW_TEXT`
  against that transient copy, then moves to the next record and overwrites
  it again.

Both are "one authoritative record → one small flat scratch buffer, header
stripped, delimiter adjusted, regenerated on demand, discarded immediately
after" — **exactly the mechanism Alternatives C and D need for the
compiler**, already proven correct, already shipping, already handling the
127-byte-max-record case cleanly. This substantially de-risks C/D: the hard
part (turning a packed record into a flat scratch copy) isn't new design,
it's adapting an existing, working pattern to a second consumer.

---

## 3. Canonical/pretty-source conclusion

**Your model — `canonical editable source → compiler → bytecode → VM`, with
bolding as rendering only — is correct in substance, with one precise
clarification**: bolding does not read authoritative source bytes *in
place*. `V2_LIST` (and the live-editing redraw path, via the identically-
shaped `V2_LOAD_EDIT`) first copies the one line being rendered into a
small, fixed, 128-byte transient buffer (`DETOK_BUF` / `EDIT_LINE_BUF`),
then calls `V2_KW_DETECT_SPANS` and draws from *that* copy. `V2_KW_DETECT_SPANS`
itself does no copying — it scans whatever buffer it's handed, case-folds a
*local copy in a register* for the A-Z boundary test only, and records span
offsets against the real pointer it was given (`rom/exrom_v2_shell.asm:1701-1735`).

This does not contradict your model: the per-line scratch copy is
regenerated fresh from canonical source on every single redraw and
discarded immediately after — it is not a second *stored*, *persistent*, or
*independently maintained* representation that could drift out of sync with
source (the failure mode "another program representation" implies). There
is exactly one editable, saved, authoritative representation; the render
path's transient per-line buffer is scratch space, not a parallel copy of
the program. **Confirmed, with that clarification.**

---

## 4. Actual peak usage (restated with the bytecode correction)

The real coexistence window is compilation itself: source (read) + staging
(written, then read) + bytecode-in-progress (written) are simultaneously
*reserved*, though not simultaneously filled to their individual maxima by
one program (a program that uses all 4096 B of source cannot also produce
4011 B of bytecode from that same compile and have both numbers be
independent maxima — but the RAM reservation exists at full size regardless
of actual fill). During execution, only the first 240 B of the 4096 B
staging reservation does anything (`SYMTAB_OVERFLOW_BASE`/
`STRTAB_OVERFLOW_BASE`, `rom/exrom_v2_vm_core.asm:295-298`) — **3,856 B is
idle for the entire execution phase, every run**, and the full 4,096 B is
idle during editing, LIST, SAVE, and LOAD. This is unchanged from the prior
pass; repeated here because it's the quantitative basis for §5's benefit
accounting.

---

## 5. Alternatives C, D, E

### C — Streaming / line-at-a-time compiler input

**Mechanism**: feed the lexer one authoritative record at a time through a
small transient buffer — header stripped, `$0D` separator synthesized (with
the same colon-join suppression `V2_BUILD_SOURCE` already does), `$00` only
at true end-of-program. When the lexer's cursor nears the end of the loaded
data, refill from the next record via `KTAB_MEM_LINE_NEXT`, preserving
`SRC_PTR` and every other piece of compiler state exactly as today (none of
it is staging-address-relative in a way that breaks on a refill — `SRC_PTR`
is just a pointer, fixups patch *bytecode*, not source, confirmed in §2 of
the prior pass).

**Minimum safe buffer size, derived, not guessed**: because
`EDIT_LINE_BUF_LEN`=128 hard-caps every stored record's content at 127
bytes, **no normal token (identifier, number, ordinary terminated string)
can ever exceed one record's length**. A buffer sized to comfortably hold
two maximal records (**~256 bytes**: 2×127 content + separators + margin)
guarantees that whenever the lexer starts a new token, at least one full
fresh record's worth of lookahead is already available — making refill
*only* necessary once per record, triggerable from a single check at the
top of `LEX_NEXT_TOKEN`, not from inside any of the character-scan loops.

**The one genuine edge case**: `LEX_SCAN_STRING` does not treat `$0D` as a
terminator (`rom/exrom_v2_compiler.asm:1189-1214` — it stops only at `"` or
`$00`). In the *current* full-buffer design, an unterminated string literal
already silently swallows subsequent lines' content as part of the string
until a closing quote or the final `$00` — a pre-existing, already-shipped
quirk, not something C introduces. With a small buffer, this is the **only**
token type that can legitimately need a refill *mid-scan* (crossing more
than one record boundary while hunting for a closing quote that never
comes). This needs one contained guard inside `LEX_SCAN_STRING` specifically
(detect "ran off the end of currently-loaded data, not true EOF" and
refill-then-continue) — not a change to any other lexer routine.

**Interaction with the specific constructs you listed**: colon continuation
is handled identically to today (it's `V2_BUILD_SOURCE`'s existing
suppression rule, just applied per-record instead of once-up-front).
Relational-operator lookahead (`<=`/`<>`/`>=`) reads at most one byte past
the current position — guaranteed available by the same "one fresh record
of lookahead" invariant. IF/ELSE/ENDIF, FOR/NEXT, PROC/CALL, DEF FN, and
labels/fixups are all resolved by the compiler's *grammar and fixup table*,
not by re-reading source text — confirmed in the prior pass that fixups
patch the bytecode buffer, not source, and that `COMPILE_PROGRAM` never
seeks backward in source. None of these constructs need anything from the
buffer beyond "the next token," which the refill invariant already
guarantees.

**ROM cost estimate**: adapt the existing `V2_BUILD_SOURCE`/`V2_COPY_RECORD`-
shaped per-record copy loop to be resumable (track "which record, how far
into it") instead of running straight through to done; add one
remaining-lookahead check at the top of `LEX_NEXT_TOKEN`; add one guard in
`LEX_SCAN_STRING`. Estimated **80-150 bytes** of new/changed ROM — small,
and concentrated in 2-3 places, not scattered across every character-fetch
site the way Alternative B would be.

### D — Smaller transformed/chunk buffer

As described in the prior document, D and C converge on the same mechanism
once sized correctly: a small, fixed flat buffer, refilled by the existing
record-copy logic, with the lexer otherwise completely unchanged. The only
real difference in framing is granularity (C: refill exactly one record at
a time; D: a fixed chunk size that may hold a round number of records). The
derivation in C above (≥256 B to guarantee one full record of lookahead at
every token start) **is** the answer to D's "what size, and why not smaller":

- **64 B** is unsafe on its own — about half of one maximal 127-byte
  record. A near-maximal line would force a mid-token refill for ordinary,
  well-formed programs, which is exactly the complexity D is trying to
  avoid (refill-at-token-boundary-only stops being true).
- **128 B** holds exactly one maximal record with no margin — risky at the
  boundary (the lookahead invariant needs a *fresh* record available when a
  token *starts*, which means the buffer needs room for the *current*
  record's tail plus a *whole new* record, not just one record total).
- **256 B** (two maximal records) is the smallest size that cleanly
  satisfies the "always have a full fresh record of lookahead" invariant
  with real margin, confirmed by the 127-byte ceiling in §2.1, not chosen
  arbitrarily.

No additional refill/boundary machinery beyond what §C already specifies is
needed — D does not avoid or reduce any of C's required changes, it's the
same change. There is no meaningful "D is simpler than C" distinction once
the size is derived correctly rather than guessed; I'm presenting them as
one recommendation (§7) rather than two competing ones.

### E — In-place/overlaid compilation

**The question**: since source consumption (`SRC_PTR`, forward-only) and
bytecode emission (`EMIT_PTR`, append-only) both only move forward, could
bytecode progressively overwrite already-consumed staging bytes, letting
the two regions share one shrinking/growing window instead of two separate
fixed reservations?

**Why this fails your own stated rejection criterion**: it requires
`EMIT_PTR`'s cumulative byte count to never exceed `SRC_PTR`'s cumulative
byte count, at every instant, not just at the end of compilation. This is
**not generally true** — source-to-bytecode expansion varies by construct
and is frequently >1×, not <1×, for exactly the short, common constructs
real programs are full of. Concrete counter-example: `A=A+1` is 5 source
bytes; a straightforward compile emits roughly: load-variable (2 B, opcode+
slot) + push-literal-1 (opcode+operand, 2-3 B) + ADD (1 B) + store-variable
(2 B) ≈ **8-9 bytecode bytes from 5 source bytes**, already approaching 2×
expansion in one of the most trivial possible statements. A program front-
loaded with short identifiers and small integer literals (extremely
ordinary BASIC) can sustain this ratio for a long stretch before any
compact, low-expansion construct appears to "pay it back." There is no
simple static bound on *local* (partial-compile) expansion the way there
might be on *total* (whole-program) expansion — the two totals happening to
end up with bytecode(4011 B) < source(4096 B) in the worst case says nothing
about whether `EMIT_PTR` raced ahead of `SRC_PTR` *locally*, mid-compile.

Making this safe would require either (a) a dynamic bounds check on every
single emission comparing `EMIT_PTR` against current `SRC_PTR` and failing
the compile (or worse, corrupting unconsumed source) if emission threatens
to overtake consumption — exactly the "complicated dynamic check" your own
rejection criterion names — or (b) a conservative static safety margin
reserved between the two pointers at all times, which is just a smaller,
oddly-shaped version of the same staging reservation this option claims to
eliminate, for no corresponding simplicity benefit.

**Rejected**, on both of your own stated grounds: it needs a dynamic check
to be safe, and the realistic fallback (a static margin) doesn't actually
recover the RAM it promises.

---

## 6. Practical RAM benefit, per alternative

| | Compile-time RAM recovered | Execution-time RAM reusable | Enlarges source? | Enlarges bytecode? | Enlarges array/data arena? | 240 B overflow tier |
|---|---|---|---|---|---|---|
| **A** (current) | 0 | 0 (3,856 B idle every run) | No | No | No | Already overlaid on staging, unaffected |
| **B** (direct consumption, no buffer) | **~4,096 B** (staging eliminated entirely) | Same 4,096 B, now free at all times | Yes, if source's own ceiling is moved to use it | Yes, if `V2_CODE_LIMIT` is moved | Yes (array arena already borrows from the source region per the capacity audit) | Needs a new, separate home (no buffer left to host it) |
| **C/D** (≈256 B chunk) | **~3,840 B** (4,096 − 256) | Same ~3,840 B, now free at all times | Same three choices as B, just ~256 B less headroom | Same | Same | **No change needed** — the 256 B chunk is itself idle after compilation, so it can keep hosting the existing 240 B overflow tier exactly as the current 4,096 B staging buffer does today (240 ≤ 256) |
| **E** (rejected) | n/a | n/a | n/a | n/a | n/a | n/a |

Per your instruction not to report "N KB saved" without confirming it's
reassignable: in every case above, the recovered window is the *same*
address range currently occupied by staging (`$9455`-up), so it is
reassignable to exactly the same set of consumers the existing capacity
audit already identified as wanting more room (larger source ceiling,
larger bytecode ceiling, or a bigger dynamic-array arena) — this document
does not pick which, that's a separate, later decision. C/D's ~3,840 B is
~94% of B's theoretical maximum, for a fraction of B's implementation risk
(§7).

---

## 7. Recommendation

**Is a full 4,096-byte staging copy fundamentally necessary? No.** It is
the *simplest* design, not the only safe one. Authoritative source is
already contiguous and length-navigable; the only real transformations
needed (header-stripping, colon-join CR suppression, EOF sentinel) are
small and already implemented twice elsewhere in this exact codebase for a
structurally identical problem (§2.2).

**Best alternative: C/D combined** — a single ~256-byte chunk buffer,
refilled one record at a time by an adapted version of the existing
`V2_BUILD_SOURCE`/`V2_COPY_RECORD` copy loop, with the refill check placed
at exactly one site (top of `LEX_NEXT_TOKEN`) and one contained guard added
to `LEX_SCAN_STRING` for the unterminated-string edge case. This is **not**
Alternative B's sophisticated virtual-memory-style cursor — the lexer's
character-fetch code (`LEX_SKIP_SPACES`, `LEX_SCAN_IDENT/NUMBER`, and the
relop lookahead) is **completely unchanged**, still plain `ld a,(hl); inc
hl` against a flat buffer that merely happens to be smaller and refilled.
This matches your own stated philosophy directly: it favors the small,
mostly-lexer-preserving design over the theoretically larger but much
riskier full rewrite, consistent with "a small line/chunk buffer... may be
preferable even if it recovers slightly less RAM."

**Alternative B** (true direct consumption, no buffer at all) is not
rejected as impossible — it's real, and it would recover the full ~4,096 B
rather than ~3,840 B — but it requires touching every character-fetch site
across five lexer routines, the hottest and most change-sensitive code in
the compiler (this file already has one documented regression from a far
smaller reordering, the `.ident_start` adjacency bug). For a 48 K
recreational BASIC where the marginal ~256 B difference between B and C/D
is tiny compared to either option's prize, B's extra risk is not justified.

**Alternative E is rejected** (§5), per your own stated criteria.

### Summary table

| | Buffer size | RAM recovered | Est. ROM cost | Risk | Recommend before R11? |
|---|---|---|---|---|---|
| A (current) | 4,096 B | 0 | 0 | None (shipping, proven) | N/A — baseline |
| **C/D (recommended)** | **~256 B** | **~3,840 B** | **~80-150 B** | **Low-medium** — concentrated in 2-3 sites, reuses a proven in-repo pattern; needs full regression coverage including the unterminated-string edge case before shipping | **No** — this is purely internal RAM/implementation plumbing with no public-ABI, KTAB, or BASIC-language-visible surface; safe to schedule any time, but worth prioritizing given it's the single largest RAM-capacity lever currently available |
| B | 0 B (none) | ~4,096 B | Higher (not estimated in detail — many sites) | Medium-high — rewrites the hottest lexer code, broad regression surface | No — same ABI-neutral reasoning as C/D, but the extra risk for ~256 B more isn't worth it on this project's own stated philosophy |
| E | n/a | n/a (rejected) | n/a | Rejected outright | N/A |

This is a design/implementation recommendation, not a decision to
implement — per this task's scope, nothing was changed. If you want this
built, it belongs in its own dedicated change with its own test additions
(specifically: a maximal-127-byte-line program, a colon-chain spanning a
chunk-refill boundary, and an unterminated string literal crossing multiple
records), not folded into an unrelated commit.

---

## 8. Implementation (follow-up session, same day)

The C/D recommendation above was implemented, debugged, and validated. The
recovered RAM was **deliberately left unallocated** — no capacity (source,
bytecode, scalars, arrays) was enlarged in this session.

### 8.1 Mechanism, as actually built

- `CHUNK_BUF` = `V2_SOURCE_STAGE` (unchanged address, `$9455`), now holding
  a **264-byte** (`CHUNK_SIZE`) rolling window instead of a full 4096-byte
  flatten — exactly the size this audit derived (two 128-byte "record
  units" worth of margin, §7), not re-tuned.
- `CHUNK_MARGIN` = 128. `LEX_NEXT_TOKEN` checks, once at the top of every
  call, whether fewer than `CHUNK_MARGIN` bytes remain loaded ahead of
  `SRC_PTR`; if so it calls `CHUNK_REFILL` before dispatching.
- `CHUNK_REFILL` compacts (shifts the still-unconsumed remainder down to
  `CHUNK_BUF` via `LDIR`) and then calls `CHUNK_APPEND_ONE_RECORD`
  (adapted from the old `V2_BUILD_SOURCE`'s per-record copy loop) in a
  loop until margin is satisfied or the authoritative source is exhausted
  (writing the true EOF `$00` sentinel on the last record).
- Three small state cells follow the data region inside the same vacated
  window: `CHUNK_NEXT_REC` (next record to pull, 0 = none), `CHUNK_FILL_PTR`
  (valid-data high-water mark), `CHUNK_CUR_REC_PTR` (most-recently-appended
  record's authoritative pointer — used for error-line lookup, §8.2).
- A fourth cell, `STMT_IDENT_NAME_BUF` (8 bytes), was added during
  debugging (§8.3) — not part of the original chunk-buffer design, but
  placed in the same vacated window since it has the same lifetime.
- `V2_BUILD_SOURCE` (`rom/exrom_v2_shell.asm`, EXROM) now just primes the
  window and tail-calls a new KTAB entry, `KTAB_CHUNK_REFILL`, to reach
  `CHUNK_REFILL` (HOME-resident, same file as the lexer) — the only new
  KTAB entry this change needed; the lexer's own two call sites are
  same-bank, direct calls, no trampoline.
- `V2_JUMP_TO_ERROR_LINE` was rewritten: the old byte-offset-counting walk
  depended on the staging buffer holding the *whole* program, which is no
  longer true. It now counts authoritative records from `MEM_LINE_FIRST`
  until the pointer matches `CHUNK_CUR_REC_PTR` — simpler than the old
  walk, and exact (no colon-continuation approximation) rather than
  approximate.
- `LEX_SCAN_STRING` gained one contained guard (§7's anticipated "one
  case"): if a string's scan reaches the loaded-data boundary with more
  authoritative source remaining, it refills anchored at the string's own
  start (not the stale `SRC_PTR`), preserving the pre-existing behavior
  that an unterminated string may span multiple authoritative records.

### 8.2 Real bugs found and fixed (via ts2068-debug single-stepping, not by inspection)

Three genuine correctness bugs surfaced during validation — none were
anticipated in the original audit, all were root-caused by single-stepping
a failing test on real register state rather than guessing from source:

1. **`LDIR` clobbers `BC`.** `CHUNK_REFILL` computed the remainder length
   into `BC` before the compacting `LDIR`, then reused `BC` *after* the
   `LDIR` to compute the new `CHUNK_FILL_PTR` — but `LDIR` decrements `BC`
   to 0 as it completes. `CHUNK_FILL_PTR` came out equal to `CHUNK_BUF`
   every time a refill had a nonzero remainder, so the next appended
   record's bytes overwrote the just-shifted remainder instead of
   following it. Fixed by `push bc` / `pop bc` around the `LDIR`.
2. **Stale `STMT_IDENT_NAME_PTR`.** `STASH_IDENT_AND_PEEK` (and two
   un-factored duplicates of the same pattern, inline in `COMPILE_PROC`
   and `COMPILE_DEF_FN`) stored a *pointer* into the live chunk buffer,
   then called `LEX_NEXT_TOKEN` — which can refill, relocating that exact
   byte range. By the time a caller used the pointer for a symbol-table
   operation (`LABEL_DEFINE`, `ARRSYM_LOOKUP`, etc.), it could be reading
   overwritten memory. Symptom: an array assignment failed "never DIM'd"
   even though `DIM` had already run, and separately a `GOTO`/`PROC`/
   `DEF FN` label failed "undefined" even though it was defined. Fixed by
   a new shared `STASH_IDENT_NAME` routine that **copies** the identifier
   (up to 8 bytes, the same clamp every symbol-table call site already
   applies) into a fixed `STMT_IDENT_NAME_BUF`, immune to relocation;
   `COMPILE_PROC`/`COMPILE_DEF_FN`'s inline duplicates now call it too,
   removing the duplication as well as the bug. The pre-existing nested-FN
   park/restore (`COMPILE_FACTOR`'s `.udf_have_lparen`) was updated to
   save/restore the buffer's *content* across a nested call, since the
   pointer it used to park is now a constant.
3. **Both bugs above are production bugs**, now fixed in `rom/
   exrom_v2_compiler.asm`. A third issue was specific to this session's
   own standalone test fixture, not production: `CHECK_INT_VAR`'s
   `SEARCH_NAME_LEN`/`PTR`/`EXPECT`/`INDEX` scratch cells were declared as
   inline `DB`/`DW` data inside the test's own `$0000-$3FFF` ROM image —
   writes to them silently no-op (the exact `PRINT_ATTR_SCRATCH`-class
   lesson this project has already documented once). Moved to real RAM.
   A second test-only bug (an `index*6` vs. intended `index*3` arithmetic
   slip in the same check routine) was also found and fixed the same way.

### 8.3 Boundary test coverage

New file: `rom/test_v2_chunk_refill_boundary.asm` — unlike every other
`rom/test_v2_*.asm` standalone test, it does not bypass chunking via
`SRC_PTR=SOURCE_TEXT`; it hand-builds a real authoritative line-store
program and drives the real `CHUNK_REFILL` path (inlining exactly what
`V2_BUILD_SOURCE` does, since that file's shell code isn't linked into
this flat single-bank test). **Result: PASS** (green border), after fixing
the bugs above. Covers, in one combined program plus four extra phases:

| Requirement | Covered by |
|---|---|
| Maximum-length source line | 3 consecutive 127-text-char records (`REC1-3`) |
| Consecutive maximum-length records | same 3 records, back to back |
| Token/identifier/numeric literal near refill boundary | inherent in the above — the refill trigger lands mid-padding |
| Relational lookahead (`<=`, `<>`) | `IF A<=3...`, `IF A<>B...` |
| Colon continuation across refill | `REC1`/`REC2` end in `:`, suppressed-separator join, spanning the first refill |
| Multiple colon continuations | `Q=1:` / `Q=Q+1:` / `Q=Q+1`, 3 separate records |
| String near refill boundary | exercised structurally by the guard in §8.1 (no dedicated near-exact-boundary string case added, given time budget — residual gap, see §8.5) |
| Unterminated string crossing records | `TEST3_PROGRAM`, 3 records, confirmed returns (no hang) |
| True EOF / empty program | `TEST2`, zero stored records, `VM_ERROR_CODE=0` |
| IF/ELSE/ENDIF | `REC5-7` |
| FOR/NEXT | `REC8`, sum 1..5=15, checked |
| PROC/CALL including recursion | `REC11-12`, `COUNT(3)` recursion, `R=6` checked |
| DEF FN | `REC13-14`, `FN SQ(4)=16` checked |
| Labels/forward fixups | `REC9`, `GOTO SKIP`/`SKIP:`, `G=42` checked (not the skipped `999`) |
| Numeric arrays | `REC10`, `DIM ARR(3)`, compiled and run (not independently value-checked, to stay inside this flat test's 16K budget — residual gap) |
| String arrays | not included in this dedicated test; already covered by the pre-existing `string_arrays` standalone test (direct `SRC_PTR`, not chunked) plus the separate production-ROM integration check below, which does exercise a numeric array through the real chunked path |
| Canonicalized keywords | all keywords in the hand-built program are already uppercase, matching current source convention |
| Compiler-error/source-line recovery | `TEST4`, deliberate bad token, `CHUNK_CUR_REC_PTR` compared directly against the authoritative record walked independently — matches |
| Source preservation | `TEST5`, byte-for-byte `MEMCMP` of the authoritative region before vs. after `TEST1`'s `RUN` — identical |

### 8.4 Production integration (real `rom/v2_home.asm` + `rom/v2_exrom.asm`, via `ts2068-debug type`)

Typed an 8-line program through the real interactive editor (scalar
assignment, `FOR`/`NEXT`, `IF`/`THEN`/`ELSE`/`ENDIF`, `DIM`, array
assignment from a scalar):

```
S=0
FOR I=1 TO 20
S=S+I
NEXT I
IF S>100 THEN T=1 ELSE T=0 ENDIF
DIM ARR(2)
ARR(0)=S
ARR(1)=T
```

- Authoritative source inspected before `RUN`: all 8 records present and
  correctly formed.
- `RUN`: `COMPILE_ERROR_CODE=0`, `VM_ERROR_CODE=0`.
- Results: `S=210`, `I=21`, `T=1` — all correct (210 = sum 1..20; `I`
  lands one past the loop per normal `FOR` semantics; `T=1` since
  210>100).
- Authoritative source re-inspected after `RUN`: **byte-for-byte
  identical** to before.
- `LIST`: all 8 lines displayed correctly, with correct keyword bolding
  (`FOR`, `NEXT`, `IF`, `THEN`, `ELSE`, `ENDIF`, `DIM` all bolded),
  confirming the editor's render path still works correctly against
  chunked-and-restored authoritative source (screenshot captured this
  session, not reproduced here).

A second attempt at a live edit-then-rerun cycle was abandoned after the
`ts2068-debug type` tool itself intermittently dropped/duplicated
keystrokes on a shorter program (visibly, on-screen: `RUN` got typed as a
stray 6th program line instead of being recognized as the run command) —
a test-harness input-timing artifact, not a product defect; the full
8-line run above already proves `RUN`/source-preservation/`LIST` all work
correctly on the real production ROM. Re-attempting a clean edit+rerun
cycle is a reasonable follow-up but was not essential given the dedicated
standalone test (§8.3) already proves editing (colon-chain construction)
and re-running (`TEST2`/`TEST3`/`TEST4` each reset `PROG_END` and rebuild
the chunk window fresh) work correctly in a fully controlled setting.

### 8.5 Residual gaps (honest, not blocking)

- No dedicated test places an ordinary (non-pathological) string literal's
  closing quote *exactly* at a refill boundary (only the pathological
  unterminated-crossing-records case is directly tested). The mechanism
  (§8.1's `LEX_SCAN_STRING` guard) is the same code path either way, and
  the boundary-crossing logic doesn't distinguish terminated from
  not-yet-terminated until it hits the boundary, so this is a low-risk
  gap, not an untested code path — but it is not independently proven.
- `DIM ARR(3)`'s runtime values aren't asserted in the standalone test
  (ROM-budget-constrained, §8.3); the production-integration run (§8.4)
  does exercise a real array through the chunked path end-to-end,
  partially closing this gap, but doesn't check element values after a
  refill specifically mid-array-statement.
- The live edit-then-rerun integration cycle (§8.4) was not completed due
  to test-tooling flakiness, not a code issue — see §8.4's own note.

None of these gaps were hit by any of the extensive testing actually
performed (full production build, `make check`, all 27 pre-existing V2
standalone regressions, the new boundary test, and the live production-ROM
run) — they are noted for completeness, not because anything failed.

### 8.6 ROM cost

| | HOME free | EXROM free |
|---|---:|---:|
| Before this change | 437 B | 1,321 B |
| After implementation, before shrink pass | 146 B | 1,409 B |
| After shrink pass (§8.7) | **160 B** | **1,409 B** |

Net combined cost: **189 bytes** (277 B spent in HOME, 88 B recovered in
EXROM — `V2_BUILD_SOURCE`/`V2_JUMP_TO_ERROR_LINE` both shrank, since
neither needs the old per-program byte-counting logic anymore). Within
the audit's own ~80-150 B estimate plus the unanticipated bug-fix cost
(§8.2's `STASH_IDENT_NAME` factoring, the nested-FN byte-preservation
fix, and the `LEX_SCAN_STRING` guard were not costed in the original
estimate, which only anticipated the core refill mechanism).

### 8.7 Shrink pass applied

Factored the bounds check ("is this pointer inside `[CHUNK_BUF,
CHUNK_BUF+CHUNK_SIZE)`") out of `LEX_NEXT_TOKEN` and `LEX_SCAN_STRING`,
which had it duplicated verbatim, into one shared `HL_OUTSIDE_CHUNK_BUF`
routine. Also simplified the check itself: the original duplicated logic
had a redundant short-circuit for "pointer below `CHUNK_BUF`" that turns
out to be unnecessary — on a Z80, `HL-CHUNK_BUF` wraps to a large value
when `HL<CHUNK_BUF`, which the second (`<CHUNK_SIZE`) comparison already
rejects correctly, so one unsigned range test covers both out-of-range
directions. Saved 14 bytes in HOME (146 B -> 160 B free); re-validated
(full regression suite, standalone chunk test) after applying. No further
shrink was attempted — the remaining code is each a single, already-tight
occurrence (the per-record copy loop, the refill loop, the identifier
copy), not meaningfully compressible without hurting readability for a
~14-30 B return, which this task's own "don't optimize to the last byte"
guidance argues against pursuing further.

### 8.8 Capacity accounting (Part 4)

**A. Source-program capacity**: unchanged, limited by `PROG_AREA_START`
(`$8457` in the current tree) to `V2_SOURCE_END` (`$9455`) = **4,094
bytes** (the dormant-architecture audit's figure of 4,096 was off by the
same 2-byte drift already present in the tree before this session;
unrelated to this change, not corrected here per scope). Limiting check:
`MEM_LINE_INSERT`/`MEM_LINE_STORE`'s own space check against this ceiling
(`kernel/memory/memory.asm`), unaffected by this change.

**B. Compiled-bytecode capacity**: unchanged, **4,011 bytes**
(`V2_CODE_BASE`=`$A455` to `V2_CODE_LIMIT`=`$B400`), confirmed from the
current build's own symbol table — matches the prior audit's corrected
figure exactly; the ~2,731 B figure some older documents cite remains
stale and is not this change's concern to fix. Limiting check: bytecode
emission has no explicit bounds check of its own that this audit found
(the existing capacity audit already flagged this as a pre-existing,
unrelated gap) — `EMIT_PTR` simply advances until `V2_CODE_LIMIT`, past
which it would silently collide with `V2_FLOATTAB_BASE` (`equ
V2_CODE_LIMIT`). Unaffected by this change.

**C. Runtime/dynamic-data capacity**: unchanged by this specific change in
the sense that no table size, stack depth, or arena limit was touched —
but the *addressable ceiling* `VARS_START` is set to `V2_SOURCE_END`
(`$9455`) at cold start and every `NEW`/stored-`RUN` (`rom/
exrom_v2_shell.asm`'s `MEM_INIT_V2`), exactly as before. The dynamic
numeric/string array arena grows from `PROG_END` up to `VARS_START`,
sharing address space with the authoritative source region (already
established, unrelated to this session). This session's change does
**not** move `VARS_START`, so dynamic-data capacity is unchanged: still
bounded by whatever's left between a given program's own `PROG_END` and
`$9455` once fixed-size scalar/array-pointer tables ($B400 region
upward) are accounted for separately. A precise single number depends on
program size (source) exactly as it did before this session; this change
neither improves nor worsens that pre-existing coupling.

**D. Total program footprint — simple user-facing model**: unchanged by
this session, restated for completeness now that the staging buffer is
no longer part of the mental model: **`canonical authoritative source
(up to 4,094 B) -> compiler scratch (264 B, invisible/transient) ->
bytecode (up to 4,011 B) -> VM`**. During a `RUN`, authoritative source,
the small compiler scratch window, and bytecode-in-progress are
simultaneously resident (the real "peak" window, same as the prior
audit's finding, just with the scratch window now 264 B instead of 4,096
B). During execution, only compiler scratch's own 264 B is reserved —
and of that, only its first 240 B stays genuinely used (the scalar
overflow tier, §4 of this document, unchanged) — the remaining 24 B is
idle, and the ~3,826 B *outside* that 264 B window (§8.9) is idle for the
entire execution phase, exactly as the audit originally found about the
full 4,096 B window, just a much smaller remainder now.

### 8.9 Measured recovery (Part 5)

- Old compiler-staging reservation: `$9455`-`$A455` = 4,096 B.
- New compiler-buffer size: **264 B** (`CHUNK_SIZE`, data only).
- Additional bookkeeping inside the same window: `CHUNK_NEXT_REC` (2 B) +
  `CHUNK_FILL_PTR` (2 B) + `CHUNK_CUR_REC_PTR` (2 B) + `STMT_IDENT_NAME_BUF`
  (8 B, added during bug-fixing, §8.2) = 14 B.
- Total newly occupied: `$9455`-`$956A` inclusive = **278 B**
  (`$9455`+278=`$956B`, the first free byte — an earlier draft of this
  section said the occupied span ended "at `$9563`", which is
  `STMT_IDENT_NAME_BUF`'s own *start* address, not its end; that 8-byte
  buffer ($9563-$956A) was being double-counted as both "occupied" and
  "the first free byte." Corrected during the Phase 6 RAM-accounting
  pass, 2026-10-04, by direct re-derivation from `include/v2_layout.inc`
  rather than trusting the earlier prose.)
- Portion still occupied by the scalar-overflow overlay during execution:
  first 240 B of the 264 B data region (`$9455`-`$9545`), **unchanged** —
  240 ≤ 264, same non-overlapping-lifetime reuse as before this session.
- **Exact newly available address range: `$956B`-`$A454` inclusive
  (3,818 bytes)**, confirmed by direct subtraction from
  `include/v2_layout.inc`'s own constants (corrected from the earlier
  "`$9563`-`$A454`, 3,826 B" figure — off by exactly 8 B, the size of
  `STMT_IDENT_NAME_BUF`, for the reason given above). This is the figure
  that must stay unallocated going forward.
- This is compile-time RAM saved (the old design reserved all 4,096 B
  permanently, whether a given compile needed it or not) **and**
  execution-time RAM made newly available (same address range, idle in
  both the old and new design during execution, but now only 278 B of it
  is claimed instead of 4,096 B). None of it is "RAM already being
  reused today" in a new sense — the 240 B overlap with the scalar
  overflow tier is the one pre-existing reuse, unchanged.
- **This RAM is left explicitly unallocated** (Part 6) — no sysvar, table,
  or arena was resized to claim it. It is simply unreserved address space
  between `$9563` and `V2_CODE_BASE` (`$A455`) now, available for a
  future, separate product decision (larger source, larger bytecode,
  larger array arena, or a split among them) — not decided here.

### 8.10 Full validation results

| Suite | Result |
|---|---|
| `make build` | 0 errors |
| `make budget` (at the time of this milestone's original implementation) | HOME 160 B free, EXROM 1,409 B free |
| `make budget` (current, after the Phase 6 `CHUNK_APPEND_ONE_RECORD` EOF-terminator fix, §8.12) | **HOME 173 B free, EXROM 1,409 B free** |
| `make check` (full, incl. legacy-fixture guard) | clean, 0 errors |
| `tools/run_v2_standalone_tests.sh` (27 pre-existing V2 regressions) | **27/27 PASS**, re-run twice (before and after the §8.7 shrink pass) |
| `rom/test_v2_chunk_refill_boundary.asm` (new) | **PASS**, re-run after the shrink pass too |
| `tools/run_editor_auto_test.sh` | PASS (legacy fixture, unaffected as expected) |
| `tools/run_storage_named_load_test.sh` (program/extension_roundtrip/autorun_roundtrip) | PASS x3 (legacy fixture, unaffected as expected) |
| Production ROM, live, 8-line typed program (§8.4) | PASS — correct results, byte-identical source before/after `RUN`, correct `LIST` rendering |

### 8.11 Phase 5 — two further `COMPILE_DIM`/`COMPILE_DIM_STR` stale-pointer
bugs, and boundary-value test coverage

Same bug class as §8.2 (a raw `TOK_NAME` pointer parked across an
intervening `LEX_NEXT_TOKEN` call, which can refill/relocate the chunk
buffer before the pointer is used), found in two more sites by an
exhaustive audit of every `*_FIND_OR_CREATE`/`*_LOOKUP` call site in
`rom/exrom_v2_compiler.asm`. Fixed identically (route through
`STASH_IDENT_NAME`/`STMT_IDENT_NAME_PTR`). New test
`rom/test_v2_chunk_boundary_values.asm` closes the two residual gaps
§8.3 flagged (closing-quote-exactly-at-a-refill-boundary; array/string
scalar values asserted across a refill) — **PASS**, after also fixing an
unrelated bug in the test's own data (`NAME_NS1`/`NAME_NS2` included the
BASIC `$` string-sigil; `STRSYMTAB` stores names with the sigil already
stripped, so the search never matched — a test-data bug, not a
production one).

### 8.12 Phase 6 — production bug: lost EOF terminator across a
post-EOF compaction

A real, user-reported production regression (`FOR i = 1 TO 20` /
`PRINT i` / `NEXT i`, entered cleanly at the editor, failed to compile
on `RUN` with `COMPILE_ERROR_CODE=2`, "expected '=' after identifier")
traced to `CHUNK_APPEND_ONE_RECORD`'s end-of-program branch: it writes
the `$00` terminator at `CHUNK_FILL_PTR` but never advances
`CHUNK_FILL_PTR` past it, so the terminator sits outside the
`[SRC_PTR, CHUNK_FILL_PTR)` range every later `CHUNK_REFILL` compaction
preserves. The first post-EOF compaction (triggered by the next
`LEX_NEXT_TOKEN` call after the real program text is exhausted) loses
it, replacing it with whatever stale byte already sat at the new
position — the lexer then reads past the true end of the program as if
it were more source, eventually misparsing a stray fragment and
raising a spurious compile error. Reproduced on the real production
ROM via `ts2068-debug` and, isolated, via a new minimal standalone test,
`rom/test_v2_for_first_token.asm` (FOR as the program's first token, in
its own un-joined record — the case that reaches true EOF within the
initial priming pass and then undergoes further post-EOF compactions
while the final statements are parsed). Fixed with two added
instructions (`inc de` / `ld (CHUNK_FILL_PTR),de`) after the terminator
write. `make build` clean; `make check` clean; V2 standalone suite
**27/27 PASS**, no regressions; both chunk-boundary tests PASS. HOME
free moved 160 B -> 173 B (net of this fix plus other changes since the
original milestone); EXROM free unchanged at 1,409 B.

A second, separate, **not yet fixed** issue was found while reproducing
this: after `V2_JUMP_TO_ERROR_LINE` repositions the cursor onto an
existing stored line, the cursor sits at that line's position 0 rather
than a fresh blank line, so typing a command there (`RUN`, `NEW`) edits
that line's text in place instead of being recognized as a command.
Real, reproducible, out of scope for this fix.

### 8.13 Phase 6 — final RAM-capacity accounting

Recalculated directly from `include/v2_layout.inc`, `include/sysvars.inc`,
`rom/exrom_v2_compiler.asm`, `rom/exrom_v2_vm_core.asm`, and
`kernel/memory/memory.asm` after the §8.12 fix — not assumed unchanged.

**Fixed-size BASIC storage** (always reserved, independent of program
size):

| Region | Address | Size | Capacity |
|---|---|---|---|
| Numeric scalars, tier 1 | `SYMTAB_BASE`=`$B700` | 16×3 B = 48 B | indices 0-15 |
| Numeric scalars, tier 2 (overflow) | `SYMTAB_OVERFLOW_BASE`=`$9455` | 16×3 B = 48 B | indices 16-31; execution-time-only, overlaid on the chunk buffer's own footprint (lifetime-disjoint — idle during compile, live only from `VM_INIT` to the next `V2_BUILD_SOURCE`) |
| **Numeric scalars, total** | — | 96 B | **32 variables** (`CSYMTAB_MAX_ENTRIES`) |
| String scalars, tier 1 | `STRTAB_BASE`=`$B500` | 4×32 B = 128 B | indices 0-3 |
| String scalars, tier 2 (overflow + temps) | `STRTAB_OVERFLOW_BASE`=`$9485` | 6×32 B = 192 B | indices 4-7 named (4) + 2 round-robin temps |
| **String scalars, total** | — | 320 B | **8 named variables** (`STRTAB_MAX_VARS`), each holding up to **31 content bytes** (32 B record = 1 length byte + 31 content) |
| FOR stack | `CFOR_STACK_BASE`=`$B9B9` | 4×4 B = 16 B | 4 nested `FOR`/`NEXT` levels (`FOR_NEST_MAX`) |
| PROC/CALL return stack | `$B688`-`$B69F` | 12×2 B = 24 B | 12 nested `PROC`/`CALL` levels |
| DEF FN parameter save stack | `$B732`-`$B791` | 12×8 B = 96 B | 12 nested `DEF FN` calls (`VM_PARAM_NEST_MAX`) |
| Numeric array pointer table | `ARR_PTR_TABLE`=`$B4B0` | 16×2 B = 32 B | up to 16 distinct numeric arrays per program (slot reserved whether or not `DIM`'d) |
| String array pointer table | `STRARR_PTR_TABLE`=`$B4D0` | 8×2 B = 16 B | up to 8 distinct string arrays per program |
| Compile-time label table | `LABELTAB_BASE`=`$B900` | 8×11 B = 88 B | **compile-time only, not runtime-resident** — unused once `COMPILE_PROGRAM` returns |
| Compile-time fixup table | `FIXUPTAB_BASE`=`$B960` | 8×11 B = 88 B | **compile-time only, not runtime-resident** — same |
| Extension registry | `EXT2_TABLE`=`$BF00` | 12×14 B = 168 B | up to 12 registered loadable extensions |
| VM/runtime scratch (operand stack, call-stack pointer, FOR/param scratch, string-expr scratch, etc.) | scattered `$B6xx`-`$B9xx` | ~a few hundred bytes, already counted above where it has its own entry | fixed, no further user-facing capacity number |

**Dynamic BASIC data arena** (numeric and string arrays, `DIM`'d at
runtime):

- Starting address: `ARRAYS_END`, initialised to `PROG_END` (i.e. right
  after the end of the current program's stored source) at cold boot,
  at `NEW`, and at the start of every `RUN`.
- Limit address: `VARS_START`, fixed at `V2_SOURCE_END`=`$9455` for the
  entire V2 production system (set by `MEM_INIT_V2`/`MEM_CLEAR_V2`,
  `rom/exrom_v2_shell.asm`). **Important naming trap**: `include/
  sysvars.inc` documents a completely different "two-ended pool, scalars
  grow down from `PROG_AREA_MAX`=`$C000`" scheme for `ARRAYS_END`/
  `VARS_START` — that documentation describes `basic/basic.asm` (the V1
  legacy fixture)'s own reuse of the same two global cell *names*, not
  V2. V2's own `MEM_INIT_V2` unconditionally overwrites `VARS_START`
  with `V2_SOURCE_END` after `MEM_COLD_INIT` runs, so V2 never exercises
  the two-ended-pool behavior that comment describes.
- Total bytes: `VARS_START - ARRAYS_END` = `V2_SOURCE_END - PROG_END` —
  **not a fixed number**. It shrinks as the program's own source grows
  (array arena and *unused source capacity* are the same physical bytes)
  and as arrays are `DIM`'d. For a minimal/empty program (`PROG_END` ==
  `PROG_AREA_START`=`$8457`), it is the full 4,094 B.
- Allocator direction: upward, bump-pointer (`ARRAYS_END` increases by
  each array's exact descriptor size on `DIM`, never reclaimed until the
  next `RUN`/`NEW`/`CLEAR`).
- Exhaustion check: `ARRAYS_END + needed >= VARS_START`
  (`rom/exrom_v2_vm_core.asm:1621-1626` and `:1869-1874`, both `OP_DIM`
  paths).
- Error generated: `VM_ERROR_CODE=16` ("RUNTIME ERROR" shown to the
  user) — `VM_ERR_ARRAY_SPACE`.
- Record shapes: numeric `[dim_count:1][count:2][data: count×2 B]`;
  string `[dim_count:1][count:2][width:1][data: count×width B]`, each
  element itself `[len:1][content: width-1 B]`. So capacity genuinely
  depends on dimensions/element type: e.g. `DIM A(500)` costs
  3+500×2=1,003 B; `DIM B$(100,20)` costs 4+100×20=2,004 B — both must
  fit in whatever's currently left of the shared 4,094 B window after
  the program's own source and any earlier arrays.

**Other RAM reservations** (not part of the source/array/scalar budget
above):

| Region | Address | Size | Permanent or transient? |
|---|---|---|---|
| Compiler scratch (chunk buffer + state) | `$9455`-`$956A` | 278 B | transient — compile-time only; see §8.9 |
| **Unallocated/recoverable** | `$956B`-`$A454` | **3,818 B** | currently idle, deliberately left unallocated (corrected from the earlier 3,826 B figure — see §8.9) |
| Bytecode | `V2_CODE_BASE`=`$A455` .. `V2_CODE_LIMIT`=`$B400` | 4,011 B | permanent address-range reservation; actual usage varies by program |
| Flood-fill visited bitmap | `GFX_FILL_VISITED`=`$C000` | 6,144 B | permanent, transiently *used* only during a fill |
| Flood-fill pixel stack | `GFX_FILL_STACK`=`$D800` | 4,096 B | permanent, transiently *used* only during a fill |
| Sprite image + background buffers | `$E800`-`$F100` | 2,304 B | permanent, always reserved (8 slots × 2 buffers × 144 B/cell-buffer) |
| Loadable-package code window | `EXTENSION_MODULE_BASE`=`$F400` .. `EXTENSION_MODULE_LIMIT`=`$F800` | 1,024 B | permanent reservation, only *populated* when a package is `LOAD`ed |
| Machine (Z80 hardware) stack | grows down from `V2_MACHINE_STACK_TOP`=`$FF00` | ~1,792 B of real headroom before `EXTENSION_MODULE_LIMIT` | permanent; this is less headroom than an older comment in `include/sysvars.inc` claims (3,584 B) — that comment predates the package window's introduction and was never updated |
| Display/video RAM | separate hardware page (not in this `$8000`-`$FFFF` workspace at all) | standard TS2068 bitmap+attributes | permanent, platform-fixed, outside the scope of this accounting |

**`FREE()`** — `rom/exrom_v2_vm_core.asm`'s `BUILTIN_FN_FREE` is a thin
wrapper over `kernel/memory/memory.asm`'s `MEM_FREE_BYTES`:

```
MEM_FREE_BYTES:
    ld   hl, (VARS_START)
    ld   de, (ARRAYS_END)
    sbc  hl, de
    ret
```

`FREE()` reports **exactly the dynamic array arena's remaining bytes**
(`VARS_START - ARRAYS_END`) — nothing more. It is not a broader heap and
not total unallocated machine RAM. Because the arena shares its address
window with unused source capacity, `FREE()` also implicitly reports
"how much more program text plus array data together could still fit,"
which is the practically useful reading for a BASIC programmer.

For a minimal/empty program (immediately after `NEW`, before any `DIM`):
`VARS_START`=`$9455`, `ARRAYS_END`=`PROG_END`=`PROG_AREA_START`=`$8457`,
so **`FREE()` = `$9455`-`$8457` = 4,094** — the full source-capacity
ceiling, exactly.

**The `$956B`-`$A454` (3,818 B) recovered range is NOT counted by
`FREE()`** — confirmed directly from `MEM_FREE_BYTES`'s own two inputs
(`VARS_START`, fixed at `$9455`, and `ARRAYS_END`), neither of which
reaches into that higher address range at all. It remains genuinely
unallocated, exactly as required; `FREE()` was not touched.

**Programmer-facing summary** (figures that can coexist in one running
program, not independent theoretical maxima):

- Maximum source: 4,094 B
- Maximum compiled bytecode: 4,011 B (address-range ceiling; a given
  program's real bytecode size depends on what it compiles to, and
  trades against nothing else — this is its own separate region)
- Numeric variables: 32
- String variables: 8, each up to 31 characters
- Dynamic array/data arena: shares its 4,094 B window with source text;
  `FREE()` reports what's left of it at any moment (4,094 B for an
  empty program, less as source and/or arrays grow)
- FOR nesting: 4 levels
- PROC/CALL nesting: 12 levels
- DEF FN nesting: 12 levels
- Numeric arrays: up to 16 distinct arrays per program
- String arrays: up to 8 distinct arrays per program
- Currently unallocated/recoverable future RAM: 3,818 B (`$956B`-`$A454`)
  — left untouched this session
- HOME free: 173 B; EXROM free: 1,409 B (ROM headroom for future code,
  not BASIC program data)

### 8.14 Files changed (cumulative, through Phase 6)

- `include/v2_layout.inc` — `CHUNK_*`/`STMT_IDENT_NAME_BUF` constants added
- `include/v2_ktab.inc` — one new entry, `KTAB_CHUNK_REFILL`
- `rom/exrom_v2_compiler.asm` — `CHUNK_APPEND_ONE_RECORD`/`CHUNK_REFILL`/
  `HL_OUTSIDE_CHUNK_BUF`/`STASH_IDENT_NAME` added; `LEX_NEXT_TOKEN`,
  `LEX_SCAN_STRING`, `COMPILE_PROC`, `COMPILE_DEF_FN`, `COMPILE_FACTOR`
  (nested-FN park/restore), `COMPILE_DIM`, `COMPILE_DIM_STR` (§8.11)
  modified; `CHUNK_APPEND_ONE_RECORD`'s EOF branch fixed (§8.12)
- `rom/exrom_v2_shell.asm` — `V2_BUILD_SOURCE`, `V2_JUMP_TO_ERROR_LINE`
  rewritten
- `kernel/memory/memory.asm` — one `DEFINE KERNEL_MEMORY_PRESENT` added
  (lets the compiler's one same-bank `MEM_LINE_NEXT` reference be guarded
  for standalone compiler-only test harnesses that don't link this file)
- `rom/test_v2_chunk_refill_boundary.asm` — new standalone test (§8.3)
- `rom/test_v2_chunk_boundary_values.asm` — new standalone test (§8.11)
- `rom/test_v2_for_first_token.asm` — new standalone test (§8.12)
- This document (§8.9 arithmetic correction, §8.11-8.13 added)

Not touched: `include/sysvars.inc`, any other kernel file, any other
`rom/test_v2_*.asm` file, EXT2/KTAB beyond the one new entry, bytecode
format, public addresses beyond the vacated-window internals, `FREE()`,
the memory map, keyword canonicalization. The `$956B`-`$A454` (3,818 B)
recovered range remains unallocated. Nothing committed.

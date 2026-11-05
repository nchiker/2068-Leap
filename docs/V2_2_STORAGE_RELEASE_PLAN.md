# 2068-Leap V2 v2.2 — Storage Release: plan and brief for the managing agent

Status: **proposed, not started** (written 2026-11-05 against `backport/leapc` at `b30ca0c`,
HOME 313 / EXROM 111 bytes free, `make budget`). Nothing in this plan is implemented. The
release is the owner's decision at each gate below.

Trigger: a GitHub experience report (Pro/File +5 port, tested on v2.1.1-emu.1). The reporter
ported an 8 KB BASIC + 2 KB machine-code card-file database to 67 lines of Leap BASIC (3887 of
4011 bytecode bytes) and hit the data ceiling: about 1.9 KB of file against the original's 27 KB.
Every recommendation below was checked against the source before this plan was written; the
file:line references are the places to start, not a substitute for reading the routine.

## 0. How this plan is to be run

This document is the brief for a **managing agent** (a lower-cost model, Sonnet class). The rules:

1. **Delegate routine work to cheaper subagents** (Haiku or Sonnet): every test run (`make test`,
   `make check`, `tools/run_v2_prod_tests.sh`, the qualification corpus), grep surveys,
   reference counting, `make budget`, and first drafts of documentation and of the GitHub reply.
   Give each subagent the exact command, the tree, and what to report (PASS/FAIL counts and the
   full text of each failure). Keep design decisions, code review and verdicts in the managing
   agent. When a design question is not answered by this plan, stop and ask the owner rather than
   guess.
2. **Branch discipline.** Branch from `v2-development` (the main branch): `release/v2.2-storage`.
   One commit per item, with the measured HOME/EXROM delta in the commit message. Never push,
   tag or merge without the owner's word. The pre-push hook fails from git worktrees; push from
   the main checkout.
3. **Tests.** `make test` is headless (no Fuse); do not rebuild while it runs. Runtime
   investigation uses the `2068-debug` skill (ts2068-debug on ZEsarUX), not guesswork from
   listings. Tape work is checked with `tools/qual` (`qtapetol`, `qmicsave`) and
   `tools/v2_saveall_checks.py`.
4. **ROM space is weighted spending** (owner rule): there is no free-space floor, but keep an
   emergency reserve of 64 bytes HOME and 32 bytes EXROM; every item records its measured cost.
5. **Ledger.** Append an outcome section to this file per item (what was built, bytes, tests,
   what was left out), as `docs/V2_LEAPC_BACKPORT_PLAN.md` does. Release documents follow
   `docs/V2_1_RELEASE_STATUS.md` as the template.

Owner gates: **G1** the segment-2 range (section 2.1); **G2** where the EXROM bytes for `CODE`
come from (section 2.3); **G3** integration and the release designation.

## 1. Recommendation

A **v2.2 storage maintenance release** with, in this order:

| # | Item | Expected gain | Est. ROM cost | ABI |
|---|---|---|---|---|
| A | Array Store fixes: replace without double room; `ARRAY STORE FULL` instead of `LOAD FAILED` | correctness; the reporter's "I thought the tape was bad" | ~40-50 B EXROM | none |
| B | Lever 2: multi-block `SAVE ... ALL` (segment 2 sent from its own address) | the partition rule goes away | ~80-120 B HOME+EXROM, tape minor version bump | none |
| C | Lever 1: segment 2 moved to `$5B00-$77FF` (7424 B, was 2048) | 3.6x the array / Array Store space; the port's file 1.9 KB -> ~7 KB | ~20-40 B HOME (MODE 1 interlock), rest is EQU changes | none |
| D | Lever 3: `SAVE "n" CODE start,len` / `LOAD "n" CODE [start]` | raw memory save; `$7800-$7FFF` and any user range | ~120-180 B EXROM (**exceeds the 111 free: gate G2**) | none |
| E | Documentation: store replacement, memory map, error 70 note, the new commands | | 0 | |

Deferred to the V3 gate (`V2_LEAPC_BACKPORT_PLAN.md` phase 7), and to be said so in the GitHub
reply: tokenised or relocated program text, a larger bytecode area (floating pool/code boundary),
`LOAD ... ARRAY` as a program statement, the chunk-6 array segment. Optional if HOME space allows
after A-D, owner decision: one-line `IF c THEN stmt` (section 4).

Why this order: A is a small, self-contained defect fix and warms up the tape code; B must land
before C or the bigger segment makes `SAVE ... ALL` refuse sooner; D is the most expensive and
depends on gate G2.

## 2. The items

### 2.0 Facts the design rests on (verified 2026-11-05)

* **RAM map.** Screen `$4000-$5AFF`. `$5B00-$7FFF` (9472 B) is untouched by the V2 ROM and
  every package except MODE 1, whose attribute file is `$6000-$77FF` (`SECOND_DISPLAY_ADDR`,
  `include/hardware.inc:74`; written only by `kernel/graphics/graphics.asm:1097-1101` and
  `:1189-1192` inside `GFX_SET_MODE` at `:1152`, which the MODE package calls at
  `rom/ext_mode_module.asm:71`). Neither cold start (`kernel/memory/memory.asm:73-85`) nor NEW
  clears it. The manual's memory map (`docs/manual/07_appendices.md:339-373`) promises
  `$5B00-$5FFF` and `$7800-$7FFF` to users for machine code. Program pool `$825A-$A654` (9211),
  bytecode `$A655-$B5FF` (4011), fixed cells `$B600-$BFFF`, EXROM window `$C000-$DFFF`, segment 2
  `$E000-$E7FF`, sprite buffers `$E800-$F0FF`, package window `$F400-$F7FF`, stack from `$FF00`.
  This RAM chip (`$4000-$7FFF`) is contended by the ULA: expect array access there 15-23 % slower
  (Leap-C measurement quoted in the back-port plan item 7.4), nothing else slower.
* **Segment 2** is `ARR2_BASE`/`ARR2_LIMIT` in `include/v2_layout.inc` (about lines 100-108, with
  `ASSERT GFX_FILL_STACK_END <= ARR2_BASE` and `ASSERT ARR2_LIMIT <= SPRITE_SLOT_IMG_BUF` at
  `:141-142`). Consumers: `VM_ARENA_FIT` (`rom/exrom_v2_vm_core.asm:1920-1945`, pool first, then
  segment 2 by swapping `ARRAYS_END`/`ARR2_END`), `FREE(1)` (`:5422`), the Array Store
  (`rom/exrom_v2_arrstore.asm`: `ARR_FIND`, `ARR_VALIDATE` with its `count < 2048` check, the
  loader room check at `:362`), `SA_K_ARR2_LIM` in `rom/v2_saveall.asm`, and the tools
  `tools/check_ram_layout.py`, `tools/v2_prod_arrays.py`, `tools/v2_production_checks.py`,
  `tools/v2_saveall_checks.py`. Element access (`OP_ARR_LOAD` `:1571`, `OP_ARR_STORE` `:1594`,
  string forms `:1741`, `:1793`) uses absolute descriptor addresses: no change for a moved segment.
* **Tape layer** (`kernel/storage/storage.asm`, included in the EXROM; block I/O in
  `kernel/storage/tapeblock.asm`). `STORAGE_SAVE` (`:94`): HL/B = name, IX = data, DE = length,
  type byte from `STORAGE_REQUEST_TYPE`; sends one header (17 B: type, name[10], length,
  version word, proglen; `:19-24`) and one data block. `STORAGE_LOAD` (`:241`): IX = destination,
  HL/B = name (B = 0 wildcard), DE = maximum length; returns CF clear with DE = length, or CF set
  with A = 0 (nothing written), `$FF` (`STORAGE_LOAD_DATA_TOUCHED`), `$FE`
  (`STORAGE_LOAD_BAD_VERSION`); B nonzero = SPACE held. A header longer than DE fails at
  `:379-388` with A = 0, the same code as "no tape". Header types (`include/sysvars.inc:1153-1155`):
  0 program, 4 extension, 8 array; no CODE type exists.
* **Array loader** `V2_LOAD_ARRAY` (`rom/exrom_v2_arrstore.asm`, from about `:340`; `.failed`
  `:460-468`): clears live arrays, builds the new entry **after** `PAS_END`, receives the body
  there, validates, and only then removes a same-name entry by moving the store tail down. So a
  replacement needs room for both copies, and an oversize block shows `LOAD FAILED`.
* **Shell** (`rom/exrom_v2_shell.asm`): `V2_DISPATCH` `:886`, SAVE `:915`, LOAD `:932`, VERIFY
  `:949`; `V2_PARSE_NAME` `:1069-1135` with the qualifier tail at `:1101` (EXT, ALL = `$80`,
  ARRAY via `V2_SCAN_ARRAY_NAME` `:1145`); keywords `:2451-2453`. **There is no number parser in
  the shell**; the HOME float parser `NUM_PARSE_CALC` (`rom/exrom_v2_vm_core.asm:3464`) is not in
  the cross-bank table (`tools/write_v2_crossbank.py`). `V2_SAVE_ARRAY` `:1265-1327` with its
  `.send` tail `:1318` is the model for a CODE save.
* **SAVE ... ALL** (`docs/V2_SAVE_ALL_FORMAT.md`): `SA_BUILD` (shell `:782-807`) moves the W span
  down so the image is contiguous, copies segment 2 and the cells after it, `SA_SEAL`
  (`rom/v2_saveall.asm:51-67`) appends the identity CRC and the block CRC (software,
  `rom/v2_saveall_crc.asm`), the shell sends one block from `PROG_AREA_START` (`:1236-1245`),
  `SA_UNBUILD` (`v2_saveall.asm:72-89`) restores from `V2_SHOW_MESSAGE` (`:2429`). `SA_RESTORE`
  does the LOAD checks (steps 1-8 in the format doc). VERIFY uses the same build (`:1341`).
  13 cases in `tools/v2_saveall_checks.py`. The format minor version is `V2_FORMAT_MINOR`.
* **Compiler** does not know SAVE/LOAD/VERIFY (not in `KEYWORD_TABLE`,
  `rom/exrom_v2_compiler.asm:1283`); a stored line starting with them is a shell command. The
  compiler and VM core are HOME code; shell, storage, arrstore, calc are EXROM.

### 2.1 Item C — segment 2 to `$5B00-$77FF` (lever 1) — gate G1

**Recommended range:** `ARR2_BASE = $5B00`, `ARR2_LIMIT = $7800` (7424 B). Keeps the manual's
`$7800-$7FFF` for user machine code; takes `$5B00-$5FFF`, which the manual also promised
(the owner may prefer `$6000-$7800`, 6144 B, to keep both promises: gate G1). `$E000-$E7FF`
becomes idle (do not reuse it in this release).

Design:

1. Change the two EQUs and the two ASSERTs in `include/v2_layout.inc`; add
   `ASSERT ARR2_LIMIT <= $7800` and a note on MODE 1.
2. **MODE 1 interlock** (HOME, `GFX_SET_MODE`): entering mode 1 while `ARR2_END > $6000` (or
   `PAS_END > $6000` at the prompt) is refused with a runtime error (choose a free code; list it
   in the manual's error appendix). While `GFX_MODE` is 1, `VM_ARENA_FIT` and the array loader's
   room check must use `$6000` as the effective limit, so arrays can never grow under the
   attribute file. Check whether `GFX_MODE` survives NEW; if it does, the interlock must hold
   across NEW too.
3. `ARR_VALIDATE`: the `count < 2048` guard (`cp 8` on the high byte) becomes the real limit
   (`count*width` and `3 + 2*count` must fit `ARR2_LIMIT - ARR2_BASE`); the loader room check is
   already a byte count.
4. `FREE(1)`, `SA_K_ARR2_LIM`, the layout checker and the four tools: update the constants and
   expected values; `tools/v2_prod_arrays.py` has the segment-2 cases.
5. Tape receive into contended RAM: run `qtapetol` with an array destination (the loader writes
   into `$5B00+` now) and `qmicsave` for a saved array; the stock ROM loads into this chip
   (screens) so no failure is expected, but it must be measured.
6. Speed: measure an array loop in segment 2 before and after (`benchmark-z80` skill) and record
   the figure for the manual's speed table.

Tests: full `make test`; `tools/v2_prod_arrays.py`; the qualification corpus; a new case that
DIMs a 7 KB string array, saves it with `SAVE ... ARRAY`, NEWs, loads it, and reads it back; a
case that refuses MODE 1 with the segment in use and allows it when not.

Manual: memory map (`07_appendices.md:339-373`), concepts *Memory* and *Arrays*
(`04_concepts.md`), `FREE(1)`, the MODE 1 note, `V2_LANGUAGE_REFERENCE.md:169-172`.

### 2.2 Item B — multi-block `SAVE ... ALL` (lever 2)

Today the rule "bytecode + segment 2 + 53 <= code area + free pool" exists only because the whole
image must be one contiguous block. Design:

1. The ALL tape becomes header + data block 1 (program, symbol table/arena, the W span moved
   down, the 49 session cells, then the tail) + **data block 2 = segment 2 sent straight from
   `ARR2_BASE`** (`PAS_END`/`ARR2_END` as today's S span), with no copy. The tail carries the
   identity CRC, the CRC of block 1 and a **CRC of block 2** (tail grows from 53 to 55 bytes).
   The partition rule becomes "bytecode + 55 <= code area + free pool", which always holds in
   practice; keep the check.
2. `V2_FORMAT_MINOR` 1 -> 2. This ROM still loads minor-1 tapes (single block); older ROMs refuse
   minor-2 tapes, as the version rule already says.
3. LOAD: receive block 1 as now and run checks 1-7 of the format doc, then receive block 2
   directly into segment 2 (the store is being replaced anyway) and check its CRC; on failure
   empty the store (`PAS_END = ARR2_BASE`) and report `NO VARIABLES` with the program kept, as the
   existing failure classes do. A block-2 length that does not fit `ARR2_LIMIT` is refused before
   receiving.
4. VERIFY compares both blocks. SPACE between the blocks: `ABORTED`, span restored
   (`SA_BUILT` path unchanged).
5. Update `docs/V2_SAVE_ALL_FORMAT.md` (block table, checks, the limit paragraph), the defect
   register entry RC-O2 (close it), and `tools/v2_saveall_checks.py` (its Python `crc16` and the
   13 cases; add: minor-1 tape still loads, big store + full bytecode saves, block-2 CRC damage,
   SPACE between blocks).

Order note: do B before C so that the big-segment tests run on the new format.

### 2.3 Item D — `SAVE`/`LOAD`/`VERIFY ... CODE` (lever 3) — gate G2

Syntax, as stock 2068 BASIC: `SAVE "name" CODE start,length`, `LOAD "name" CODE` (to the saved
address) or `LOAD "name" CODE start`, `VERIFY "name" CODE`. Design:

1. New header type (use 3 to mirror stock; the header is still Leap's own with the version word,
   so the tape is not stock-compatible, say so in the manual). `STORAGE_LOAD` only accepts a header
   whose type matches the request, so a CODE tape cannot be loaded as a program by mistake.
2. The saved start address goes in the header's proglen field (free for type 3); length is the
   data length.
3. Shell: a **decimal integer parser** (digits only, 0-65535, about 25-35 bytes) in
   `V2_PARSE_NAME`'s tail for `CODE n,m`; refuse start + length > 65536; both commands then call
   `STORAGE_SAVE`/`STORAGE_LOAD` with IX/DE from the parsed numbers, exactly as `V2_SAVE_ARRAY`'s
   `.send` does. No range policing beyond that (stock does none); the manual says which ranges are
   safe (`$7800-$7FFF`; `$5B00-$5FFF` if the owner keeps it; `$6000-$77FF` only if neither
   MODE 1 nor segment 2 uses it).
4. `LOAD ... CODE` ends the session like every LOAD (variables are gone), but does not touch the
   program, the Array Store or packages.
5. Messages: `SAVED`, `LOADED`, `VERIFIED`, `VERIFY FAILED`, `LOAD FAILED`, `ABORTED`, `BAD TAPE
   VERSION` as today; a CODE block longer than the room given on LOAD = `LOAD FAILED` (the manual
   already defines it as "does not fit").

**EXROM budget (gate G2).** Estimate 120-180 bytes against 111 free. Candidates to pay for it, in
the order the budget document lists them (`docs/V2_ROM_RAM_BUDGET.md`, last table): drop VERIFY
of ALL tapes (+~12 EXROM, loses a feature), a measured shrink pass over the shell and editor
(z80-shrink lanes, `~/z80-skills`), or moving a cold shell routine to HOME through a cross-bank
slot (HOME has 313 free). Measure the real cost on the branch first, then put the options to the
owner with numbers.

Tests: `qmicsave` capture of a CODE save (byte-exact), round trip through NEW and a RAM wipe,
`VERIFY` pass and fail, `qtapetol` on a CODE block, a CODE tape offered to `LOAD "n"` (must be
skipped), the Pro/File port itself if the reporter supplies it (ask in the reply).

### 2.4 Item A — Array Store fixes

1. **Replacement without double room.** In `V2_LOAD_ARRAY`, after `V2_CLEAR_ARRAYS` the pool
   from `PROG_END` to `V2_CODE_LIMIT` is free (no session survives a LOAD). Compute the room
   **before** anything changes: `room = ARR2_LIMIT - (PAS_END - old_entry_len) - 4 - namelen`
   (old length 0 if the name is not in the store), pass `min(room, pool room)` as DE to
   `STORAGE_LOAD`, receive the body into the pool, validate (`ARR_VALIDATE`), then remove the old
   entry (today's tail move) and copy the new entry to `PAS_END`. Nothing in the store changes on
   any failure. Same-size replacement of a store-filling array then works.
2. **Distinct failure code.** In `STORAGE_LOAD`'s length check (`storage.asm:379-388`) return a
   new code (e.g. A = `$FD`, `STORAGE_LOAD_TOO_LONG`, nothing written) and map it in
   `V2_LOAD_ARRAY.failed` to `ARRAY STORE FULL`. Optionally map it in the program loader to the
   existing `PROGRAM FULL` message (0 new bytes of text). Document both.
3. Manual: in `04_concepts.md` (Arrays and tape, near lines 9 and 46-62) and `03_keywords.md`
   (`LOAD`, line 1492 area): loading a name already in the store replaces it; the new array only
   has to fit on its own; `ARRAY STORE FULL` when it does not; only NEW empties the store (already
   stated). Error appendix: `LOAD FAILED` no longer means "does not fit" for arrays.

Tests: new cases in `tools/v2_prod_arrays.py`: replace same name same size at a full store,
replace with a larger array that fits, oversize array -> `ARRAY STORE FULL` with the store
unchanged, damaged tape -> `LOAD FAILED` unchanged.

### 2.5 Item E — documentation

* Manual sections above, plus the `Converting old programs` note: string literals longer than 31
  characters are compile error 70 (already in Appendix A `07_appendices.md:96`; add the note where
  porters look: the Strings concept and the compatibility list in
  `V2_LANGUAGE_REFERENCE.md:19, 189`).
* `V2_LANGUAGE_REFERENCE.md` command table (`:105-108`): the CODE forms, the new ALL format line.
* `docs/V2_DEFECT_REGISTER.md`: RC-O2 closed by B; a new entry for the `LOAD FAILED` ambiguity
  closed by A.
* Release record `docs/V2_2_RELEASE_STATUS.md` from the v2.1 template; `include/v2_version.inc`;
  `tools/make_rc_assets.py` designation; NOTICE unchanged.
* Documentation drafts: a Sonnet subagent drafts from the facts here; the managing agent reviews
  against the code before committing.

## 3. Test and qualification summary

| Stage | What | Who runs it |
|---|---|---|
| per item | `make test` (headless), `tools/run_v2_prod_tests.sh`, the item's new cases | Haiku/Sonnet subagent, results evaluated by the managing agent |
| B, D | `tools/v2_saveall_checks.py`, `qtapetol`, `qmicsave` | subagent |
| C | `tools/v2_prod_arrays.py`, qualification corpus (`tools/qual`, 667 cases), MODE 1 interlock cases, speed figure | subagent; the managing agent reads the speed figure |
| release | full qualification as in `V2_1_RELEASE_STATUS.md` section 2, `make doc-examples`, `make check` (provenance) | subagent |
| hardware | `V2_HARDWARE_CHECKLIST.md` gets a section: CODE round trip, two-block ALL, loads into `$5B00+` on a real machine (NOT TESTED, as before) | owner |

## 4. Optional, if HOME space allows after A-D (owner decision)

**One-line `IF c THEN stmt`.** Today error 9. The lexer already flags a line end
(`LEX_NEWLINE_PENDING`, used by the label check at `rom/exrom_v2_compiler.asm:4137`). Rule: if the
token after THEN is not a line end, the body runs to the end of the line and the line end acts
as ENDIF (ELSE allowed on the same line). Cost study estimate 40-60 bytes HOME. It restores a V1
form. Compatibility break: a block IF whose first body statement sits on the THEN line and whose
ENDIF is on a later line would stop compiling; the repo's V2 corpus has none, and
`tools/qual/corpus.py:451` (`if.single_line`, expects error 9) flips to a pass. Must be stated
in the release notes if done.

## 5. The GitHub reply

The managing agent drafts the reply (via a subagent, then reviews it) and **leaves it for the
owner to post**; nothing is posted by an agent. Content: thanks and an acknowledgement that the
documented limits behaved as documented; what v2.2 will do for each of the five recommendations
(CODE: yes; ALL partition rule: yes, by a second block; SAVE/LOAD as statements: CODE and SAVE
ARRAY forms considered later, LOAD ARRAY cannot run mid-program because it discards the live
arrays; `LOAD FAILED` on a full store: a defect, fixed, with replacement no longer needing double
room; more room: segment 2 grows from 2 KB to about 7 KB, program text and the bytecode area stay
as they are until a V3); the two small things (one-line IF noted as a candidate with the
compatibility caveat; error 70 is in Appendix A and a note goes where porters look); and a
request for the source and build script as a qualification test case. No dates. Plain prose in
the owner's voice, no headings needed, under 400 words.

## 6. Ledger (append per item)

_(empty)_

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

### Baseline (2026-11-05, `release/v2.2-storage` at `7c5505b`, tree = `v2-development` `4891681`; all [M])

- `make budget`: **HOME 403 free, EXROM 111 free** (the plan's HOME 313 was measured on `backport/leapc`; v2.1.1
  returned 90 B to HOME). Pool `$825A-$A654` 9211, bytecode `$A655-$B5FF` 4011.
- `make test` (headless, 2,350 s wall, exit 0): all PASS. smoke 9/9, standalone 40/40, prod-regress 127,
  prod-arrays 101, known-defects 15, saveall 13, qmicsave 0 failures, lifecycle 23, qvmedge 221/221,
  qual **670 PASS + 1 XFAIL + 2 N/A**, maint-qual ay_beep 59, cbeep 27, di_wait 14, cbeep_tape 3.
- Plan line references into `kernel/graphics/graphics.asm` and `rom/exrom_v2_vm_core.asm` predate v2.1.1 and
  may have moved; re-read before using them in item C.

### Item A design note (2026-11-05, before any code)

Read: `V2_LOAD_ARRAY` and `ARR_VALIDATE` (`rom/exrom_v2_arrstore.asm`), `STORAGE_LOAD` (`kernel/storage/storage.asm`),
`V2_CLEAR_ARRAYS`, `SYM_RESET`, `V2_LOAD`'s failure classes, `docs/V2_SESSION_VARIABLES.md`.

**Today.** The new entry is built at `PAS_END` and the body is received there, so `DE` (max length) =
`ARR2_LIMIT - descriptor address`: a replacement needs room for both copies. A header longer than `DE` is
`.total_failure` (A = 0), the same code as "no tape", so the shell says `LOAD FAILED`. The old entry is removed
afterwards by one `ldir` that also slides the new entry down.

**Premise check (the plan's "the pool is free").** `V2_LOAD_ARRAY` starts with `V2_CLEAR_ARRAYS`, which calls
`SYM_RESET` (clears `SESS_VALID`: `LOAD ... ARRAY` ends the session, `V2_SESSION_VARIABLES.md` table) and drops
`ARRAYS_END` to just past the empty symbol table. Everything from there to `V2_CODE_LIMIT` is dead, and
`V2_LOAD` already receives program blocks over that range. Confirmed.

**New room calculation.** Stage the entry in the dead pool at `ARRAYS_END` (not at `PROG_END`: `SYM_RESET`
wrote the table terminator there, and `SAVE ... ARRAY` reads the table afterwards). Entry image = `[len:2][kind][namelen][name][descriptor]`,
the key name copied in before `STORAGE_LOAD` as today. Before anything changes:

    EL   = length of the same-name entry (ARR_FIND), 0 if none
    room = ARR2_LIMIT + EL - PAS_END - (namelen + 4)         ; descriptor bytes that fit after replacement
    room < 0  ->  ARRAY STORE FULL, nothing touched
    DE   = room, IX = staged descriptor

Receive into the pool, `ARR_VALIDATE` (it reads `ASV_DESC`, now in the pool), set the entry's length field,
then commit: (1) find the old entry again (the staged name is the key); if present, `ldir` the store tail down
over it, **guarding a zero count** (the old entry was last: `ldir` with BC = 0 would copy 64 KB; today's code
never hit it because the new entry rode along in the move); (2) `PAS_END := PAS_END - EL`, copy the staged entry
there, `PAS_END` := the end of the copy. The store is not written on any failure path; same-size replacement of
a store-filling array now fits (`room = descriptor of the old entry`).

**Pool limit.** The pool room is `V2_CODE_LIMIT - descriptor address` >= about 3.9 KB for any program the
shell accepts (`V2_SOURCE_END` = `$A655`, name <= 31 B). With the 2048-byte segment the store room is always the
smaller, so the plan's `min(room, pool room)` is not needed and is replaced by a build `ASSERT` that fails if a
layout change (item C) makes the segment larger than that pool room. **For gate G1:** at 7424 B the pool room
would bind, so a 7 KB array could load only while the program text is under about 6.6 KB, unless C adds the
`min` (about 7 B) or receives straight into the store when there is room.

**New return code.** `STORAGE_LOAD_TOO_LONG EQU $FD` (nothing written). The length check at `.name_ok`
(`storage.asm`, "header length > max") loads it and joins `.abort_check` (which keeps A and computes the SPACE
flag in B), 2 B. Callers: `V2_LOAD_ARRAY` maps it to `ARRAY STORE FULL`; `V2_LOAD` and `V2_VERIFY` already treat any
code other than `$FF`/`$FE` as a clean failure, so they behave exactly as before for `$FD` (program: `LOAD FAILED`;
VERIFY: `VERIFY FAILED`). The optional `PROGRAM FULL` mapping in the program loader is **left out**: it needs a
VERIFY-mode guard and bytes for a case the report did not hit.

### Item A outcome (2026-11-05; on `release/v2.2-storage` off `v2-development` `4891681`; all [M])

- **What:** `LOAD "n" ARRAY a` no longer needs room for the old and the new copy together, and an array longer
  than the room is `ARRAY STORE FULL`, not `LOAD FAILED`. Design as in the note above, built as written.
  - `kernel/storage/storage.asm`: new return code `STORAGE_LOAD_TOO_LONG` (`$FD`, nothing written) for a header
    longer than the caller's DE; it joins `.abort_check`, so B still reports SPACE.
  - `rom/exrom_v2_arrstore.asm` `V2_LOAD_ARRAY`: the entry is staged at `ARRAYS_END` in the pool; the room is
    `ARR2_LIMIT + EL - PAS_END - (namelen + 4)`, computed before anything changes; the old entry is removed and
    the staged entry copied only after `ARR_VALIDATE`; the move is skipped when the old entry was the last
    (a count of 0 would make `LDIR` copy 64 KB). A local `.find` serves both lookups. A build `ASSERT` ties the
    staging room to the segment size (fails if item C makes the segment larger than the pool room).
  - `V2_LOAD` and `V2_VERIFY` are untouched: they treat `$FD` as the clean failure they already know.
- **Bytes** (`make budget`, `4891681` -> working tree): **HOME 403 -> 403 (0); EXROM 111 -> 89 free (-22):**
  storage 2, loader 20 (the loader got shorter than the estimate of 40-50 because the new code replaces
  the old removal logic). Above the 32 B EXROM reserve by 57. RAM 0.
- **Tests** (on the working tree, headless): `make test` exit 0, 1,889 s: smoke 9/9, standalone 40/40,
  prod-regress 127, **prod-arrays 105** (was 101), known-defects 15, saveall 13, qmicsave 0 failures,
  lifecycle 23, qvmedge 221/221, qual **670 PASS + 1 XFAIL + 2 N/A** (unchanged), maint-qual all;
  `check_docs`, `check_storage_contract`, `check_package_abi` pass. `make doc-examples` 327/327.
  - New cases in `tools/v2_prod_arrays.py`: `arr-store-replace-full` (same-size replace in an exactly full
    store; replaces the old `arr-store-replace-peak`, which asserted the defect), `arr-replace-larger-fits`
    (first and last position), `arr-store-full-oversize` (replace, add, 3000 elements: `STORE_FULL`, store
    unchanged), `arr-replace-full-damaged` (bad checksum `LOAD FAILED`, malformed `BAD ARRAY TAPE`, store
    intact), `arr-load-near-full-program` (85-line program, text and the symbol-table terminator survive).
    `arr-store-full-body` and `arr-store-exact-fit` now require `STORE_FULL` (they accepted either message).
  - **Test finding:** three existing cases (`arr-store-full-header`, `-name31`, `-body`) hung the emulated machine
    (a 1,000-3,400 s timeout each) because they poked `PAS_END` over a store of zeros. A zero entry length never
    advances `ARR_NEXT`, so `ARR_FIND` loops; the old loader never looked the key up before receiving, the
    new one does. The ROM never writes such a store, so the cases were fixed (`filler()` builds a walkable
    entry), not the loader. Noted for item B/C tests: hand-built stores must be well-formed.
- **Manual** (Sonnet draft, reviewed against the code): `03_keywords.md` (LOAD table and results line),
  `04_concepts.md` (replacement sentence; message table; store unchanged on failure), `07_appendices.md`
  (Appendix A: `LOAD FAILED`, `ARRAY STORE FULL`). Items left to E: the defect-register entry for the
  `LOAD FAILED` ambiguity, the release record, `V2_LANGUAGE_REFERENCE.md` needed no change.
- **Left out:** the optional `PROGRAM FULL` mapping in the program loader (a too-long program tape still says
  `LOAD FAILED`; it needs a VERIFY-mode guard and bytes); the `min(room, pool room)` (replaced by the ASSERT; see
  the pool-limit paragraph and gate G1); a hardware test (not possible here).

### Open questions for the owner (2026-11-05, after item A; nothing built for B yet)

**B: timing between the two blocks on a real tape (not answered by section 2.2).** The plan's LOAD order is
block 1, then checks 1-7, then receive block 2. Those checks include the block CRC and the identity CRC
(about 2.4 s alone, `V2_HARDWARE_CHECKLIST.md` 3.3), roughly 3-4 s in all. The receiver waits at most 8.6 s for a
pilot (`TR_TICKS`), but a data block's pilot lasts about 1.8 s, so on a cassette block 2's pilot would be over
before the receiver listens. VERIFY and SAVE have no such window (their CRCs are computed before any tape I/O).
Options (recommendation first):

1. **A long silent gap between the blocks on SAVE** (about 4.5 s, so the checks finish inside it and the
   receiver's 8.6 s budget catches the pilot). Keeps the plan's order and the current failure semantics (a
   foreign-ROM tape keeps the Array Store). Costs about 4.5 s of tape per ALL save; the number is a hardware
   figure, tuned only in emulation until the checklist is run.
2. **Receive block 2 straight after block 1, before any check**, into segment 2 (its length read from the
   unchecked cells, bounded by `ARR2_LIMIT - ARR2_BASE`). No gap, but the Array Store is overwritten before
   the checks: every failure after that point (other ROM, damaged tape) empties the store, where today it is kept.
3. **Check only block 1's CRC before block 2, the identity CRC after it**: shorter window (about 1 s, still
   more than a pilot-free gap of a few hundred ms), and a foreign-ROM tape empties the store as in 2.

**G1 (needed before item C) and a finding for it.** Item A stages an array in the pool above the program, so
the largest array a `LOAD ... ARRAY` can take is `V2_CODE_LIMIT - (end of the program text)`. At 7424 B the
segment is larger than the pool room for a program over about 6.6 KB. Options: accept it and document; add
`min(store room, pool room)` to the loader (about 7 B EXROM; a big array then reports `ARRAY STORE FULL` for a
large program); or receive straight into the store when the name is new or there is room (more code). Range
(`$5B00-$7800` as recommended, or `$6000-$7800`): the owner's choice.

### Item B outcome (2026-11-05; owner decision on the open question: option 1, the silent gap; all [M])

- **What:** `SAVE "n" ALL` is now a header, block 1 (program + session, **no segment 2**) and block 2 = segment 2
  sent straight from `ARR2_BASE`, after a silent gap of about 4.5 s. The old partition rule (bytecode + segment 2 +
  53 <= code area + free pool) is gone; the rule is now bytecode + 55 <= code area + free pool.
  - Tail of block 1 (55 B): the 49 session cells, the **segment-2 CRC**, the identity CRC, the block-1 CRC. The
    identity CRC stays next to the block CRC, so `SA_RESTORE` reads it where it always did.
  - `V2_FORMAT_MINOR` 1 -> 2 (`include/v2_package_abi.inc`).
  - HOME (`rom/v2_saveall.asm`): `SA_TAIL` 55; `SA_SIZES` returns W only; `SA_SEAL` adds the segment-2 CRC;
    new `SA_GAP` (4650 passes of 3,389 T, SPACE tested every pass, interrupts off), `SA_FINISH` (block 2's CRC, then
    the span moves up and the session installs; any failure empties the store), `SA_S_SETUP` and `SA_IS_ALL`
    (small leaf helpers kept in HOME so EXROM stays smaller); `SA_COPY` removed; `SA_RESTORE` now stops after the
    pointer checks and returns 0 meaning "block 1 good, block 2 pending". The three header constants HOME needs are
    `SA_FLAG_DATA`, `SA_HDR_LEN_OFF`, `SA_HDR_PROGLEN_OFF` in `include/v2_layout.inc`, ASSERTed equal to the
    storage layer's in the shell. Cross-bank export list updated (`tools/write_v2_crossbank.py`).
  - EXROM (`rom/exrom_v2_shell.asm`): `SA_BUILD` no longer copies segment 2; `SA_SEND_S` (status back to SAVING, the gap,
    block 2); `V2_RECV_S` (receive or verify block 2; B = SPACE held); V2_SAVE sends block 2 when `SA_BUILT`; V2_LOAD
    receives it after `SA_RESTORE` and calls `SA_FINISH`; `.verified` compares block 2 for an ALL tape.
- **Failure semantics.** Before block 2 is read nothing changes: a tape from another ROM, or any failed check of
  block 1, **keeps the Array Store** (as before). Any failure of block 2 (no pilot within 8.6 s, SPACE, a dropout, the
  transport checksum, the segment-2 CRC) happens after segment 2 was written, so it also **empties the store**
  (`PAS_END = ARR2_BASE`); the report is `NO VARIABLES` with the program kept. VERIFY: a missing, damaged or different
  block 2 is `VERIFY FAILED` (SPACE: `ABORTED`).
- **Departures from the plan, stated.** (1) The plan's "this ROM still loads minor-1 tapes (single block)" needs no
  code: a minor-1 ALL tape was written by another ROM build, so its identity CRC cannot match; it loads its program and
  says `NO VARIABLES` (test `sa-minor-rules`), its layout is never interpreted. (2) `V2_FORMAT_MINOR` 2 means older (v2.1.x)
  ROMs refuse **every** tape this ROM writes, plain program tapes included, because the version word is shared. The
  identity CRC already protects an older ROM from misreading an ALL tape, so the bump is not needed for safety;
  **for G3**: keeping minor 1 for plain tapes would keep v2.2-saved programs loadable on v2.1.x (cost: a few bytes
  in `STORAGE_VERSION_WORD`).
- **Bytes** (`make budget`, working tree after A -> after B): **HOME 403 -> 325 free (-78)**, **EXROM 89 -> 32 free (-57)**.
  HOME: `SA_FINISH` ~42, `SA_GAP` 22, `SA_SEAL` +~12, `SA_S_SETUP`+`SA_IS_ALL` ~26, `SA_COPY` -7, `SA_SIZES` -2, `SA_RESTORE` tail
  -~10. EXROM: `SA_SEND_S` ~21, `V2_RECV_S` ~16, glue ~28, `SA_BUILD` -10. EXROM is exactly at its 32 B reserve (above the
  plan's estimate of 80-120 B for HOME+EXROM: measured 135). Not hardware-measured.
- **Tests** (`make test`, headless, 3,185 s, exit 0): smoke 9/9, standalone 40/40, prod-regress 127, prod-arrays 105,
  known-defects 15, **saveall 23** (was 13), **qmicsave 0 failures** (5 checks: program, package, **all**, program playback,
  **all playback**), lifecycle 23, qvmedge 221/221, qual 670 PASS + 1 XFAIL + 2 N/A (unchanged), maint-qual all;
  `check_docs`, `check_storage_contract`, `check_package_abi` pass.
  - New saveall cases: `sa-two-blocks` (block 2 = memory, CRCs, header, minor 2), `sa-gap` (4.5 s, measured in
    T-states), `sa-gap-space` (ABORTED, block 2 not sent), `sa-big-store` (replaces `sa-no-room`: the old OUT OF MEMORY
    program now saves and loads), `sa-minor-rules`, `sa-other-rom-keeps-store`, `sa-block2-crc`, `sa-block2-parity`,
    `sa-block2-missing`, `sa-verify-block2` (damaged, missing), `sa-verify-block2-ok`. The 12 older cases pass unchanged
    except for the tail size and the tape builder (three blocks).
  - `qmicsave`: the real sender's MIC edges for `SAVE ... ALL` decode to header + two data blocks, pilots 8,063 / 3,222 /
    3,222, every pulse within the stock widths, the gap between block 1 and block 2 inside 4.3-4.7 s; the captured signal
    played back into the real `LOAD` restores the program, i.e. block 2 is found after the real gap and the checks.
- **Finding (doc examples).** `make doc-examples` first failed 4 of 327: the four `SAVE ... ALL` / `power on` / `LOAD`
  examples said `NO VARIABLES`. The runner (`tools/qual/manual_tapes.py`) replays the captured blocks with its default
  short silence, so block 2 was no longer there when LOAD finished checking block 1. The same failure is what a tape
  without the 4.5 s gap would do on hardware. The runner now inserts the gap before block 2 (327/327). Anything else that
  replays a captured ALL save must do the same.
- **Left out:** a case with block 1 alone too big (`OUT OF MEMORY` still exists but needs a nearly full bytecode area and
  pool at once; the old test relied on segment 2 to reach it); a hardware run (the gap length is a hardware figure:
  `V2_HARDWARE_CHECKLIST.md` gets the section in item E); the defect-register entry RC-O2 and the release record (item E).

### Shrink pass over A and B (2026-11-05; owner asked for a review by a larger agent; Opus, read-only; all [M])

Reviewer: an Opus subagent, briefed with the files, the call conventions to keep and no hypothesis; I checked the
register and flag claims of each change I took against the code and measured the result.

- **Applied** (`make budget`: HOME 325 -> 325, **EXROM 32 -> 120 free, 88 B**):
  - item A loader: `V2_LOAD_ARRAY` 239 -> about 194 B. `.find` returns X = `PAS_END - EL` (where the entry goes), the
    room and the move use X, the staged entry's kind and name length are read back from the staging area, NL is kept on
    the stack, `.failed` classifies by `inc a`; three ASSERTs pin what it relies on (IS_STR follows the name length; the
    low byte of `ARR2_LIMIT - 4` is at least 31; the two failure codes);
  - `STORAGE_LOAD` length check: `max - len` with one `jr c` (24 -> 14 B; it also keeps DE = the header's length);
  - item B: `SA_GAP` falls into `SA_S_SETUP`, which complements the carry (so `call c,STORAGE_SEND_BLOCK` and `call c,V2_RECV_S`
    need no extra tests; LOAD enters `V2_RECV_S` with carry clear, VERIFY with carry set); `SA_SEND_S` is gone (its three
    steps are inline in `V2_SAVE`); `SA_RESTORE` returns NZ for every result but 0 and sets `PROG_END` itself (BC =
    `PROG_AREA_START`), `.with_state` shrinks to a call; `V2_LOAD` uses `SA_IS_ALL`; `.invalid_package` reuses `.failed`
    (same message, same registry clear), which also lets `jp c,.failed` become `jr c`.
  - Test edit: `sa-gap-space` looks for `in a,($FE) / rra / ret nc` in `SA_GAP`. The gap is 2 T shorter a pass: measured 4.50 s
    (15,734,347 T), still inside the 4.3-4.7 s windows of `sa-gap` and `qmicsave`.
- **Tests on the shrunk ROM:** `make test` exit 0 (1,867 s): prod-regress 127, prod-arrays 105, known-defects 15,
  saveall 23, qmicsave 0 failures (5 checks), lifecycle 23, qvmedge 221/221, qual 670 PASS + 1 XFAIL + 2 N/A, maint-qual all;
  `make doc-examples` 327/327. (An earlier run stopped at `sa-gap-space`: my patch script had aborted before updating that
  test; a test-side miss, the ROM was right.)
- **Not applied, offered for gate G2** (older shell code next to the new code, outside A and B; sizes are the reviewer's
  hand counts, EXROM bytes): `V2_SAVE` `.program` dead reloads of the name and a shorter length computation -11;
  `.all` jumping to a new label on `.program`'s `ld ix,PROG_AREA_START` -4; an entry that loads the name pointer and length and
  falls into `V2_PAD_NAME` -4 (saves 7 in the array loader, 4 in `V2_LOAD`); `SA_SEAL` returning the length in DE -2 (HOME -1).
  About **21 B EXROM** in all, each testable by the existing suites.
- **Not applied, by choice** (HOME has room, so risk outweighs bytes): a shared CRC-of-segment-2 helper in the old KTAB hole
  (HOME -7), `SA_FINISH` jumping to `.set_pas` / tail-calling `VM_INIT_REGS` (HOME -6, the latter relies on the callee's
  flags), `SA_SIZES` using `sub` (HOME -1). Also not taken: moving `V2_RECV_S`'s SPACE test into HOME (EXROM -5, HOME +10; it
  hides the test hook `press_space` uses).
- **Running totals** (free bytes): after A HOME 403 / EXROM 89; after B and the shrink **HOME 325 / EXROM 120**.

### Shrink pass 2 (2026-11-05; owner: "also do the older save code and the small HOME edits"; Opus implemented, I reviewed the diff; all [M])

Commit `fe4342c`. Applied, in the reviewer's numbering: **C1** `V2_SAVE .program` without the dead reloads of the name and a shorter
length computation (-11 EXROM); **C2** `.all` joins a new label `.prog_ix` on `.program`'s `ld ix,PROG_AREA_START` (-4); **C3** `SA_SEAL`
returns the block length in DE (EXROM -2, HOME -1); **C4** entry `V2_PAD_NAME_V` (loads the parsed name) used by `V2_LOAD` and
`V2_LOAD_ARRAY` (-4); **H2** `SA_CRC_S` (CRC of segment 2) in the old KTAB hole, 7 of its 12 free bytes (HOME -14); **H3** `SA_FINISH.empty`
shares `SA_RESTORE.set_pas` (HOME -4); **H4** `SA_FINISH` ends `jp VM_INIT_REGS`, which returns A = 0 because it ends with `xor a` and only
stores (documented in a comment; HOME -2); **H5** `SA_SIZES` subtracts the base's high byte (ASSERT: low byte 0; HOME -1). Not applied:
R2 (the SPACE test of `V2_RECV_S` into HOME: it hides the hook `press_space` uses).
- **Bytes** (`make budget`): HOME 325 -> **347** free (+22), EXROM 120 -> **141** free (+21). KTAB hole: 5 B left.
- **Tests** (`make test`, 30 min, exit 0): prod-regress 127, prod-arrays 105, known-defects 15, saveall 23, qmicsave 0 failures (5 checks),
  lifecycle 23, qvmedge 221/221, qual 670 PASS + 1 XFAIL + 2 N/A, maint-qual all; `make doc-examples` 327/327.

### G3 decision on the tape version stamp (2026-11-05; owner: "practically no tapes have been created ... option 2, whatever has the smallest ROM impact")

`V2_FORMAT_MINOR` goes back to **1** (the item B bump to 2 is withdrawn). No ROM size change (a constant; HOME and EXROM free bytes
as before), so the smallest impact of the three options. A v2.2 `SAVE ... ALL` tape carries the same version word as a v2.1.x one; the
identity CRC separates the ROM builds (a v2.1.x ROM loads the program of a v2.2 ALL tape and says `NO VARIABLES`, and the reverse), plain
program tapes are unchanged and load on v2.1.x. `docs/V2_SAVE_ALL_FORMAT.md`, the comment in `include/v2_package_abi.inc` and the tests
(`sa-two-blocks` compares the header word with the ABI's, `sa-minor-rules` uses minor - 1 and minor + 1) follow. The earlier departure
note in the item B outcome ("V2_FORMAT_MINOR 2 means older ROMs refuse every tape") is superseded by this entry.

### Item C outcome (2026-11-05; owner decision G1: `$5B00-$7800`, the pool-room minimum, the MODE 1 interlock; built by an Opus agent in a worktree, reviewed by me; all [M])

Commit `65f9947` (cherry-picked from `wt/item-c` `3df4f83`, tested on `fe4342c` + the item). 

- **What:** array segment 2 is `$5B00-$77FF`, **7,424 bytes** (3.6 x the old 2,048 at `$E000`); `$E000-$E7FF` is idle and reserved; `$7800-$7FFF` stays free for user
  machine code; `$5B00-$5FFF` is no longer a user area. `FREE(1)` is 7424 on an empty machine.
  - `include/v2_layout.inc`: the two EQUs and new ASSERTs (within `$5B00-$7800`, below the program pool, low bytes 0, `$6000` inside the segment).
  - **MODE 1 interlock** (`kernel/graphics/graphics.asm`, `GFX_SET_MODE`, V2 production only, 15 B HOME): entering MODE 1 while `ARR2_END > $6000` raises error
    64 (`OUT OF MEMORY`) through `VM_ERR_ARRAY_SPACE` before anything changes, so old MODE package tapes are held to it too (the check is in the ROM, not
    the package). **`ARR2_TOP`** (HOME, 11 B): the effective top, `$6000` while `GFX_MODE` is 1; used by `VM_ARENA_FIT` and `FREE(1)`. The shell commands always run in
    MODE 0 (`V2_COMMAND_LOOP` resets the display first), so the loader and the SAVE ALL chain keep the constant limit.
  - **Loader** (`V2_LOAD_ARRAY`): passes `min(store room, pool room)` to `STORAGE_LOAD` (13 B EXROM), where the pool room is `V2_CODE_LIMIT` minus the staged
    descriptor; an array longer than that is `ARRAY STORE FULL`. `ARR_VALIDATE`'s count guard is `< 4096` (an ASSERT ties it to the store size).
  - **Two places that would have broken `LOAD ... ALL` with the new range, found and fixed:** the SA_CHAIN order (segment 2 now lies BELOW the program pool, so its
    four words come first) and SA_RESTORE's array-pointer check (segment 2 is tested before the arena).
  - The Q-04 overflow check in `VM_ARENA_FIT` stays (a string array over ~40 KB still wraps from `$5B00`); only its comment changed.
- **Bytes** (`make budget`, `fe4342c` -> with the item): HOME 347 -> **326** free (-21), EXROM 141 -> **128** free (-13). RAM 0.
- **Tests** (`make test` in the worktree, 1,986 s, exit 0; after three runs that stopped at test-side mistakes): prod-regress 127, **prod-arrays 111** (was 105),
  known-defects 15, **saveall 24**, qmicsave 9 checks, lifecycle 23, qvmedge 221/221, qual 670 PASS + 1 XFAIL + 2 N/A, maint-qual all; `make doc-examples` 327/327;
  `tools/qtapetol.py all-seg2` 10 of 10 (block 2 received into `$5B00+` at speed 0.8-1.2, bit widths 0.9/1.1, jitter 20%, pilot 1000, a 50 ms dropout).
  - Tests that encoded the old size and were rescaled or replaced (the ROM was right each time): `control_stack` (standalone: `DIM A(3300)` now fits segment 2, so the
    "deep recursion refuses" case uses `A(3800)`, 7,603 B, more than the segment holds), `dim-under-recursion` (production checks, same), and three new cases written
    without being run that used index 100 on a 100-element array (error 10 stopped the program before the interesting statement).
  - New cases: `arr-seg2-7k-string-roundtrip`, `arr-load-longer-than-pool`, `arr-mode1-interlock`, `arr-mode1-dim-limit`, `arr-free1-seg2-size`, `arr-store-ends-at-limit`,
    `sa-seg2-7k`, and in `qmicsave` `all-seg2` and `array-seg2` (the REAL sender reading its payload from `$5B00+`, with playback), in `qtapetol` ten `all-seg2` cases.
- **Speed (`tools/qual/qbench.py`, T-states around the real `V2_RUN_STORED`):** an array loop in segment 2: 11,889,982 T at `$E000` vs 11,905,559 T at `$5B00` (**+0.13 %**);
  the same loop on a main-pool array: 11,846,554 both. **Caution:** ZEsarUX may not model the TS2068 video-RAM contention that the plan quotes (15-23 % slower array access in
  `$4000-$7FFF` on Leap-C), so this figure is the emulator's and not the machine's. The manual states no speed claim; the contended-RAM timing goes to the hardware checklist
  (item E). The contended-RAM tape I/O (the real sender and receiver on `$5B00+` payloads) is measured above and passes.
- **Manual and docs** (Sonnet draft, reviewed against the code; examples recalibrated by me): the memory map, Arrays/Array Store/Memory concepts, `FREE(1)`, the MODE keyword and
  the package MODE section, error 64's row, the USR rules and every example that used `23296` (now `30720`, `$7800`), `con.store.3` (`DIM big(3706)` leaves the same 2 spare bytes),
  `V2_LANGUAGE_REFERENCE.md`, `V2_SAVE_ALL_FORMAT.md`, `PACKAGE_ABI.md` (packages keep out of `$5B00-$77FF` and `$E000-$E7FF`; the array-tape count limit is `< 4096`),
  `TESTING.md`, `V2_HARDWARE_CHECKLIST.md`. Left alone as historical: `RAM_BUDGET.md:35`, `V2_ROM_RAM_BUDGET.md:63`, R10_*/R8_* reports, `V2_DOCUMENTATION_FINDINGS.md`.
- **Risks noted:** a third-party package using `$5B00-$77FF` as scratch now corrupts arrays (no shipped package does; the ABI document says so); the manual's earlier promise of
  `$5B00-$5FFF` for user machine code is withdrawn (it moves to `$7800-$7FFF`).
- **With D:** item D costs 137 B of EXROM (see its entry); C + D together do not fit above the 32 B reserve without moving code to HOME (gate G2).

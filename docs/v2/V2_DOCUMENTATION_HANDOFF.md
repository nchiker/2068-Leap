# V2 documentation handoff

For the next session: produce a complete, accurate, polished user manual and language reference
for the **2068-Leap V2 Enhanced — Emulator-Qualified Release** (`v2-development`, release source
`integration/v2-final-rom`, ROMs from `ef81f49`). This file records what exists, what is wrong or
missing (each item checked against the ROM, the corpus or the package sources on 2026-10-11), and a
plan. It does not rewrite anything.

## 1. Current documentation, by status

### Authoritative for V2 (current)

| Path | What | Status |
|---|---|---|
| `docs/v2/V2_USER_MANUAL.md` | the V2 user manual (239 lines, 13 sections) | **authoritative but thin**: correct where it speaks (its examples were run on the release, `a91cffe`), several gaps and two inaccuracies (section 2) |
| `docs/v2/V2_LANGUAGE_REFERENCE.md` | the V2 language: lines, names, literals, expressions, statements, functions, commands, errors, sessions, limits | **authoritative**; compact; one inaccuracy (LPRINT), gaps in packages and messages |
| `tools/qual/corpus.py` | the executable form of the language reference: 667 programs with exact expected output (`make qual`) | **authoritative evidence**; when prose and corpus disagree, check the ROM and fix the prose |
| `docs/v2/V2_SESSION_VARIABLES.md` | session-variable rules (RUN, STOP, BREAK, errors, `:` statements, CLEAR, NEW, edits) | current, precise |
| `docs/v2/V2_SAVE_ALL_FORMAT.md` | `SAVE "name" ALL`: tape format, LOAD checks, VERIFY | current, precise (technical) |
| `docs/v2/V2_FEATURE_MATRIX.md` | V1 vs V2, intentional differences | current |
| `docs/v2/PACKAGE_ABI.md` | the package interface, for package authors | current (technical) |
| `docs/v2/V2_DEFECT_REGISTER.md` | open, accepted and fixed defects | current |
| `docs/v2/V2_RC_STATUS.md`, `V2_REGRESSION_REPORT.md`, `V2_ROM_RAM_BUDGET.md`, `V2_HARDWARE_CHECKLIST.md`, `AUTHORITATIVE_SOURCE.md` | release records | current |

### V1 (historical; do not use for V2 facts)

`docs/user_manual.md` and `docs/2068_Leap_Users_Manual.docx` (Release 1 Beta manual, 1543 lines,
built by `make manual` / `tools/build_user_manual_docx.py`), `docs/basic_language_reference.md`,
`docs/whats_new_release_1_beta.md` and its `.docx`, `docs/programmers_reference.md` (V1 internals),
`docs/technical_overview.md`, `docs/memory_map.md`, `docs/loadable_basic_extensions.md`,
`docs/editor_architecture.md` and the other `docs/*.md` audits and plans. Their *style* (an
example-driven tour) is worth reusing; their facts (line numbers, `GOSUB`, V1 tape format, V1
memory map) are not V2.

### Planning and study records (historical)

`docs/v2/V2_LANGUAGE_SPEC.md` (the planning-phase *target*, not what shipped), `docs/v2/R*.md`,
`ARCHITECTURE_*`, `V2_ARCHITECTURE.md`, `V2_FEATURE_COST_STUDY*`, `V2_LANGUAGE_CONFORMANCE_REPORT.md`,
`V2_OWNER_DECISIONS_REVIEW.md`, `V2_INDEPENDENT_Z80_AUDIT.md`, `V2_QUALIFICATION_STUDY_INDEX.md` and
the other design/phase documents. Useful background (decisions and their reasons), not user
documentation.

### Front door

`README.md` (repository root) -- see section 2, item 1.

## 2. Known inaccuracies and gaps (verified)

| # | Where | Problem | Evidence |
|---|---|---|---|
| 1 | `README.md` | **inaccurate for V2**: "Try it" types numbered lines (`10 X=5`), which V2 rejects (compile error); links to the V1 manual as "User Manual"; "Four loadable V2 packages" (there are five); says the V2 manual is "underway"; points to the R9 cutover ledger for status. A short release note at the top now points to the V2 documents, but the body is unchanged | corpus `lex.linenum`; `build/release-v2-rc/packages/` |
| 2 | manual s8, reference s5 | `LPRINT` is listed as a core statement: it belongs to the **printer package** (without it: compile error 32); `LLIST` and `LPRINT$` (same package) are not documented | corpus `pkg.printer.unloaded`, `pkg.printer.lprint`; `rom/ext_printer_module.asm` |
| 3 | manual s11, reference s11 | the packages are not documented for users: which tape, which statements, their arguments and errors. They are: **mode** `MODE`, `ULAPLUS`, `PALETTE`; **sprite** `GRAB`, `SHOW`, `HIDE`, `MOVE`; **printer** `LPRINT`, `LPRINT$`, `LLIST`; **shapes** `CIRCLE`, `FILL`; **graphics** `CPLOT`, `BLOCK`, `FRAME`, `INVERT`. A statement of a package that is not loaded is a compile error (2; `LPRINT`: 32) | `rom/ext_*_module.asm`; corpus `pkg.*` |
| 4 | manual s8, reference s5 | `INPUT` with a prompt works (`INPUT "N? "; n`, `INPUT "V", v$`) but only `INPUT var` is documented; `INPUT` into an array element is a compile error (not documented) | corpus `input.prompt`, `input.prompt_comma`, `input.array` |
| 5 | manual s12 | five messages the ROM can show are missing: `ARRAY NOT DIMD`, `ARRAY STORE FULL`, `BAD ARRAY TAPE`, `NO PACKAGE`, `PROGRAM FULL` | strings in the release images |
| 6 | reference s8 | compile syntax errors are summarised as "2, 3, 9..48" with a pointer to the compiler source: a user needs the full code table with messages | `rom/exrom_v2_compiler.asm` header |
| 7 | manual s5 | float `FOR` loops: no note that the step is added each time, so an exact iteration count is empirical (25 classic loops measured exact) -- recommend an integer loop when the count matters | `V2_OWNER_DECISIONS_REVIEW.md` (float FOR) |
| 8 | manual s6 / s13 | accepted limitation Q-24 is not mentioned: `CALL` of a plain label (not a `PROC`) is accepted and runs on without returning | `V2_DEFECT_REGISTER.md` |
| 9 | manual s10 | `SAVE ... ALL`, `LOAD` and `VERIFY` of an ALL tape pause ~2.4 s (the identity CRC) before the tones; not mentioned | `V2_SAVE_ALL_FORMAT.md` |
| 10 | manual s8 | units and ranges are not given: `BEEP` duration/pitch, `SOUND` register map (AY 0..15), `PAUSE` frame rate, screen coordinate orientation for `PLOT`/`LINE`/`POINT`, colour numbers | -- (needs emulator verification) |
| 11 | manual s2 | `LIST` behaviour (paging, BREAK), the status bar and keyword display are only mentioned | -- |
| 12 | manual s8 | `USR`: the machine-code contract (result in BC; the interpreter's IY is restored by the ROM; what may be destroyed) is not stated for users | `PACKAGE_ABI.md`, `V2_LANGUAGE_REFERENCE.md` s6 |
| 13 | manual s13 | performance is not discussed: an empty `FOR`/`NEXT` iteration is ~1190 T-states (RC-O6) | `V2_REGRESSION_REPORT.md` s6 |

Correct and adequately covered today (keep, expand with examples): numbers and promotion (s4),
strings and comparisons, short-circuit `AND`/`OR`, `IF` blocks, integer and float `FOR`, `PROC`/`CALL`,
`DEF FN`, arrays and the Array Store, session variables and `:` statements, `RUN`/`CLEAR`/`NEW`/BREAK
semantics, the tape commands including `SAVE ... ALL`, and the intentional V1/Sinclair differences.

## 3. Features and the documentation they need

| Feature | Manual today | Needed |
|---|---|---|
| floating point, promotion, display, error 67 | s4, good | worked examples of promotion; precision note (about 9 digits); `STR$` form |
| FOR/NEXT incl. float loops, `EXIT FOR`, `STEP 0` | s5, good | item 7; zero-trip; value after the loop |
| strings and comparisons | s4/s5, brief | all functions with examples; 31-character rule; comparison order |
| arrays | s7, good | string widths; `DIMN`; overflow to segment 2; errors 10, 11, 65 |
| session variables, `:` statements | s9, good | more examples; what survives what (table) |
| RUN, CLEAR, NEW, BREAK | s9, partial | one table: what each resets (variables, arrays, Array Store, packages, program) |
| SAVE, LOAD, VERIFY, SAVE ALL, ARRAY tapes | s10, good | item 9; messages per failure; tape names |
| Array Store | s7, brief | lifetime table; adoption rules; `ARRAY STORE FULL` |
| graphics | s8, brief | coordinates, `PLOT`/`LINE`/`POINT`/`ATTR`, colours; packages shapes/graphics/mode |
| sprites | missing | sprite package chapter |
| sound | s8, one line | `BEEP` units; `SOUND` register table |
| packages | s11, one paragraph | item 3: one section per package |
| error handling | s12, partial | items 5, 6; compile vs runtime; where the cursor goes |
| limitations | s13 | Q-24, Q-26, performance, hardware status |

## 4. Examples that need emulator verification

Every example in the new manual must run on the accepted release image (tag `v2.0.0-emu.1`; HOME
`dddd4cbb…e40dca`, EXROM `c1804641…291b527` -- check the hashes of the build you test against).
Make the manual executable, **separately from the release qualification baseline**:

* the release baseline stays as it is: `tools/qual/corpus.py` (667 cases), `make test` (1010
  cases) and `make qual` are the historical record of the emulator-qualified release and are not
  edited by documentation work;
* put the documentation examples in their own suite, e.g. `tools/qual/manual_examples.py` (same
  case format as `corpus.py`: `T(id, feature, lines, expectation, packages=...)`, ids
  `manual.<section>.<n>`, exact expected output), with its own runner entry and make target
  (e.g. `make doc-examples`) and its own results file; report its totals separately from the
  1010-case baseline;
* interactive examples (editor keys, BREAK, `INPUT`, tapes) use the existing harnesses as
  libraries -- `tools/v2_prod.py` (editor keys, tape receiver), `tools/v2_saveall_checks.py`
  (tapes), `tools/qual/qlifecycle.py` (sessions), `ts2068-debug` for screenshots (`.bmp`) -- from
  new documentation test files, not by adding cases to the release suites;
* the package chapters need cases with `packages=(...)` (see the `pkg.*` cases for the pattern).

Items 7, 10 and 12 of section 2 in particular must be measured, not copied from V1 documents.

## 5. Recommended organization (Sinclair QL User Guide style)

The QL User Guide separates a gentle *Beginner's Guide*, a *Keywords* reference (one entry per
keyword: syntax, description, example, notes) and a *Concepts* reference (alphabetical topics), with
the messages and tables in appendices. For V2:

1. **Introduction**: the machine, the two ROMs, what V2 is, emulator-qualified status.
2. **Beginner's guide** (from today's manual s1-s9, expanded): the editor, a first program, numbers
   and strings, decisions and loops, procedures, arrays, the screen, sound, tapes, stopping and
   continuing (sessions).
3. **Keywords** (alphabetical): every statement, function and command -- core and per package --
   in one format: syntax, description, examples (checked by the documentation suite), errors, see also.
4. **Concepts** (alphabetical): arithmetic and promotion, arrays and the Array Store, BREAK,
   errors, memory, packages, sessions, strings, tapes and `SAVE ALL`, V1/Sinclair differences.
5. **Appendices**: messages and error codes, character set (incl. the nine blank glyphs), limits,
   memory map for `PEEK`/`POKE`/`USR` users, package reference card, hardware notes (not tested).

Source: Markdown under `docs/v2/manual/` (one file per part), `V2_LANGUAGE_REFERENCE.md` kept as
the compact precise reference (or folded into Keywords + Concepts, then removed with a pointer),
`README.md` rewritten to point at them; a DOCX/PDF build by adapting
`tools/build_user_manual_docx.py` (`make manual` builds the V1 manual today).

## 6. Plan for the documentation session

1. Read this file, `V2_USER_MANUAL.md`, `V2_LANGUAGE_REFERENCE.md`, `V2_SESSION_VARIABLES.md`,
   `V2_FEATURE_MATRIX.md`, `V2_DEFECT_REGISTER.md`; skim `tools/qual/corpus.py` by feature.
2. Build the keyword inventory from the ROM, not from documents: the compiler's keyword table, the
   built-in function table, the five packages' keyword tables (`rom/ext_*_module.asm`), the
   message table (strings in the images); diff it against the reference.
3. Fix items 1-6 of section 2 first (they are wrong or missing facts), each with a documentation
   example case.
4. Write the Keywords part entry by entry; add each example to the documentation suite; run it.
5. Write the Beginner's guide and Concepts parts from the existing manual; verify the interactive
   examples with the harnesses.
6. Appendices; README; DOCX build; `make check` (`tools/check_docs.py`), the documentation suite
   and the unchanged `make qual` green.
7. Keep the ROM unchanged: a documentation session that finds a ROM defect records it in
   `V2_DEFECT_REGISTER.md` instead of fixing it.

## 7. Next session (instruction)

Work on a dedicated documentation branch based on `v2-development`, for example
`git switch -c docs/v2-user-manual v2-development`; merge it into `v2-development` when the owner
accepts the documentation. In that session:

* complete the V2 user manual in the style of the Sinclair QL User Guide (section 5);
* correct the V2 language reference (section 2, items 2-6);
* update `README.md` so it no longer presents V1 as the current system (item 1: the "Try it"
  examples, the manual links, the package count, the status paragraph);
* document all five packages -- mode, sprite, printer, shapes, graphics -- statement by statement;
* verify every example against the accepted emulator-qualified ROM (`v2.0.0-emu.1`);
* keep the new documentation-example tests separate from the historical 1010-case release
  qualification baseline (section 4);
* change no ROM code: record any ROM defect found in `V2_DEFECT_REGISTER.md`.


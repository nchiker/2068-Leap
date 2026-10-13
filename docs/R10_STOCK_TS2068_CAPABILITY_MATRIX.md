# Stock TS2068 BASIC → V2 capability matrix

Date: 2026-09-27. R10 deliverable. Compares the ORIGINAL, unmodified
Timex Sinclair 2068 ROM's built-in BASIC (a Sinclair ZX Spectrum-family
dialect with TS2068-specific extensions, as shipped on real hardware)
against this project's own from-scratch V2 language, as it actually
exists today. This is a product-completeness inventory relative to the
historical machine's own out-of-box capability — a separate concern
from the already-completed V1(2068-Leap)→V2 internal migration audit.

**Sourcing**: V2's own capability is read directly from current source
(`rom/exrom_v2_compiler.asm`'s real `KEYWORD_TABLE`/`BUILTIN_FN_TABLE`,
cross-checked against `rom/exrom_v2_vm_core.asm`'s real opcode/builtin
handlers), not assumed. Stock TS2068 BASIC's capability is drawn from
established, well-documented knowledge of the Sinclair ZX
Spectrum/Timex Sinclair BASIC family (the TS2068 ROM is a Timex-authored
derivative of Spectrum BASIC with 2068-specific hardware extensions);
where TS2068-specific detail is less certain than the well-documented
Spectrum-common baseline, that uncertainty is flagged explicitly rather
than asserted.

**Classification key**: PRESENT (V2 has an equivalent, possibly via a
different mechanism) · ABSENT (genuine capability gap) · INTENTIONALLY
DIFFERENT (deliberate V2 design choice, cited) · OUT OF SCOPE (not
applicable to this replacement ROM's own target).

## Statements

| Stock capability | V2 status | Notes |
|---|---|---|
| `PRINT`/`LPRINT` | PRESENT | V2-native rewrite; single-argument grammar (string or numeric, trailing `;` suppresses newline) vs. stock's comma/semicolon-separated multi-item list with tab-column zones. INTENTIONALLY DIFFERENT in grammar richness. |
| `LET` (explicit assignment) | INTENTIONALLY DIFFERENT | V2 has no `LET` keyword; assignment is bare `name = expr`, matching stock's own optional-`LET` shorthand (Spectrum BASIC never required `LET` either) — not a gap. |
| `IF ... THEN <stmt>` (single-line) | PRESENT | |
| Block `IF/ELSE/ENDIF` | INTENTIONALLY DIFFERENT | Stock Spectrum-family BASIC has no block IF at all (single-line only, no `ELSE`); V2 adds real recursive block IF/ELSE/ENDIF — a genuine V2 extension beyond stock, not a gap. |
| `FOR/NEXT` | PRESENT | Nested to 4 levels (R10 fix); stock supports arbitrary nesting depth limited only by memory. Minor capability ceiling, not a missing feature. |
| `GOTO` | PRESENT | INTENTIONALLY DIFFERENT mechanism: stock GOTOs a line NUMBER; V2 GOTOs a LABEL, resolved at compile time (`LABEL_LOOKUP`/`FIXUP_RECORD`). Program structure itself differs (see Program structure section). |
| `GOSUB`/`RETURN` | ABSENT | No GOSUB/RETURN token exists in V2's `KEYWORD_TABLE`. V2 offers `PROC`/`CALL` and `DEF FN` instead (one-parameter, by-value, real call-stack-based) as its own subroutine/function mechanism — a substitution, not an oversight, but genuine unlabeled-subroutine-via-line-return capability is absent. |
| `DIM` (array declaration) | PRESENT | INTENTIONALLY DIFFERENT: single-dimension only (stock supports multi-dimensional numeric AND string arrays), compile-time-constant size only (stock allows a runtime expression), integer-only elements (stock arrays are full float, or fixed-length string arrays via `DIM A$(n,m)`). See Array model below. |
| `INPUT` | PRESENT | V2-native rewrite; numeric and string variants. Stock's `INPUT` also supports prompt strings (`INPUT "Enter: ";A`) and multi-variable lists (`INPUT A,B,C`) — not confirmed present in V2's single-variable-per-statement grammar. |
| `DATA`/`READ`/`RESTORE` | ABSENT | No tokens in `KEYWORD_TABLE`. No V2 equivalent of stock's inline-data-with-read-cursor mechanism. |
| `DEF FN` | PRESENT | Reintegrated post-R9 (this milestone's predecessor). One parameter (matching stock's own single-parameter `DEF FN f(x)=...` exactly), real recursion support (post-R9 fix) that stock BASIC's own single global parameter slot never had to worry about (stock has no real call stack either). |
| `PLOT`/`DRAW`/`CIRCLE` | PARTIAL | `PLOT` and `LINE` present (opcode-assigned). No `DRAW` (stock's arc/relative-line drawing) or `CIRCLE` token found in `KEYWORD_TABLE` — ABSENT. |
| `BORDER`/`INK`/`PAPER` | PRESENT | Resident opcodes. |
| `BRIGHT`/`FLASH`/`OVER`/`INVERSE` (PRINT-item control codes) | ABSENT | **Correction (verified 2026-09-27 against current source, flagged by the project owner):** an earlier pass in this document marked these "uncertain." Direct grep of `rom/exrom_v2_compiler.asm`'s real `KEYWORD_TABLE` confirms no `"BRIGHT"`/`"FLASH"`/`"OVER"`/`"INVERSE"` token exists anywhere in it — genuinely absent, not just unconfirmed. `CURRENT_INVERSE`/`CURRENT_FLASH` do exist as shared-memory state cells (`rom/exrom_v2_vm_core.asm`), consumed by `BUILTIN_FN_ATTR`'s attribute-byte computation and initialized to 0 at cold boot, but there is no BASIC-level statement or `PRINT`-embedded control code that lets a running program actually set them — the state exists, the language surface to reach it does not. |
| `BEEP`/`SOUND` | PRESENT | Both resident. Stock Spectrum-family BASIC has only `BEEP` (pitch/duration via the single-channel beeper); `SOUND` is not a stock Spectrum keyword at all — if TS2068-specific (AY chip), V2 having it is a genuine V2-native addition beyond the common Spectrum baseline, not confirmed against real stock TS2068 ROM documentation in this pass. |
| `POKE` | PRESENT | Statement-side, with R10's FLOAT-tag fix applied. |
| `PAUSE` | PRESENT | |
| `RANDOMIZE`/`RANDOMISE` | PRESENT (spelled `RANDOMISE`) | |
| `STOP`/`END` | PRESENT | Both compile to the same `.end_stmt` handler in V2 (see `rom/exrom_v2_compiler.asm`'s own dispatch) — stock distinguishes them (`STOP` raises a resumable "STOP statement" condition, `END` does not); V2's identical handling is INTENTIONALLY DIFFERENT/simplified, not necessarily a gap for this dialect's own scope. |
| `REM` | PRESENT | |
| `SAVE`/`LOAD` | PRESENT | Shell-level commands (`V2_KW_SAVE`/`V2_KW_LOAD`), not compiled statements — architecturally different from stock (where `SAVE`/`LOAD` are ordinary tokenized statements, permitting e.g. `IF x THEN SAVE "prog"`). V2's SAVE/LOAD are command-loop-only, not expressible inside a running program. |
| `VERIFY`/`MERGE` | ABSENT | No equivalents found. |
| `LIST`/`RUN`/`NEW` | PRESENT | Shell-level commands, same architectural note as SAVE/LOAD above. |
| `CLEAR` | ABSENT | No token found. |
| `CLS` | PRESENT | |
| `OUT`/`IN` (as a statement/function pair) | ABSENT | Stock's `OUT` statement not found in `KEYWORD_TABLE`; V1 had an optional `OUT` extension, explicitly out of R10 scope, not restored. |

## Built-in functions (24 confirmed in `BUILTIN_FN_TABLE`, indices 0-24)

| Stock function | V2 status | Notes |
|---|---|---|
| `ABS` | PRESENT | Hybrid INT/FLOAT-aware. |
| `SGN` | PRESENT | Int-only scope (documented, not float-aware) — a known, deliberately deferred gap per the pre-R10 semantic audit, unresolved this milestone too. |
| `SQR` | PRESENT | Real Newton-Raphson, always returns FLOAT. |
| `SIN` | PRESENT | Degrees-based, always FLOAT. |
| `COS`/`TAN`/`ASN`/`ACS`/`ATN` | ABSENT | Only `SIN` exists in the current table — no cosine, tangent, or inverse trig functions found anywhere in `BUILTIN_FN_TABLE`. |
| `EXP`/`LN` | ABSENT | No natural exponential/logarithm functions found. |
| `PI` | PRESENT | 0-arg, real FLOAT constant. |
| `INT` | PRESENT | R10-fixed (was a true no-op pre-R10; now genuinely truncates via the shared FLOAT-coercion mechanism). |
| `RND` | PRESENT | Int-only scope currently (per the resource-limit table, unresolved deferred item), whereas stock `RND` returns a float in [0,1). |
| `IN`/`OUT` (as functions, port I/O) | ABSENT | No `IN` function found (statement-side `OUT` also absent, above). |
| `PEEK`/`POKE`/`USR` | PRESENT | Direct, unmodified memory/call access, matching stock semantics. |
| `POINT`/`ATTR` | PRESENT | Thin adapters onto `kernel/graphics`. |
| `SCREEN$` | ABSENT | No equivalent found (stock: returns the character at a screen cell if a standard character is displayed there). |
| `LEN`/`CODE`/`VAL` | PRESENT | |
| `VAL$` | ABSENT | Stock's string-returning counterpart to `VAL` (evaluates a string expression as a BASIC expression, returning a string) not found. |
| `STR$`/`CHR$` | PRESENT | |
| `LEFT$`/`RIGHT$`/`MID$` | PARTIAL | `LEFT$`/`RIGHT$` present; no `MID$`-equivalent (arbitrary substring extraction) found in the function table. |
| `UPPER$`/`LOWER$` | PRESENT (V2 addition) | Not present in stock Spectrum-family BASIC at all — a genuine V2-native addition beyond the stock baseline. |
| `INKEY$` | PRESENT | Reaches `kernel/io/io.asm` directly. |
| `TAB`/`AT` (as PRINT-position control) | UNCERTAIN | Not confirmed present or absent in V2's simplified single-argument `PRINT` grammar in this pass — flagged for follow-up rather than asserted either way. |
| `DEG`/`RAD` | PRESENT (V2 addition) | Degree/radian conversion helpers not part of stock Spectrum-family BASIC's own function set — genuine V2-native additions. |
| `MOD`/`DIV` | PRESENT (V2 addition) | Stock Spectrum-family BASIC has no `MOD`/`DIV` operators/functions at all (integer division/modulo must be hand-rolled); V2 provides both natively. |
| `FREE` (free-memory query) | ABSENT | **Added 2026-09-27** — not previously covered in this document, flagged by the project owner. No `"FREE"` token found anywhere in the compiler's real `KEYWORD_TABLE` or `BUILTIN_FN_TABLE`. Genuinely absent. |

## Numeric model

| Stock capability | V2 status | Notes |
|---|---|---|
| Every number is a full 5-byte Sinclair-format float, always | INTENTIONALLY DIFFERENT | V2 uses a hybrid INT (native 16-bit)/FLOAT (5-byte, via the real calculator) model with explicit per-value tags — a deliberate space/speed tradeoff, not an oversight. R10 closed several INT/FLOAT boundary gaps (VAL decimals, FLOAT-zero divide, FLOAT relational operators) but some remain open (SGN/RND int-only, `OP_MUL` overflow doesn't auto-promote — all individually documented, deliberately deferred). |
| Range: full float range (~±1.7×10³⁸, per real Sinclair format) | PRESENT for FLOAT-tagged values | INT-tagged fast-path values are bounded to 16-bit signed (-32768..32767). |

## String model

| Stock capability | V2 status | Notes |
|---|---|---|
| Arbitrary-length dynamic strings (heap-allocated, bounded only by free memory) | INTENTIONALLY DIFFERENT | V2 strings are fixed-capacity records: 4 named string variables × 31 content bytes max, plus 2 temp slots — a deliberate, documented RAM-bounded design, with the 4-variable cap specifically flagged in the pre-R10 semantic audit as a scaffolding limit "not RAM-justified" (still unraised as of R10). |
| String concatenation (`+`) | PRESENT (assumed) | Not independently re-verified in this pass; `STRTAB_TEMP_COUNT=2` round-robin temp pool is explicitly scoped to "a flat `+` chain," per prior audit findings. |
| String slicing (`a$(2 TO 5)`) | UNCERTAIN | Stock Spectrum BASIC supports this syntax; not confirmed present or absent in V2's grammar in this pass. |
| String arrays (`DIM A$(10)`) | ABSENT | V2's `DIM` (per the Array model section) has no string-array form found. |

## Array model

| Stock capability | V2 status | Notes |
|---|---|---|
| Multi-dimensional numeric/string arrays | INTENTIONALLY DIFFERENT | V2: single-dimension only, matching this project's own documented "V1's final archived state," not an oversight. |
| Runtime-computed array bounds (`DIM A(n)` where n is an expression) | ABSENT | V2 requires a compile-time CONSTANT size — explicitly self-labeled in the compiler's own error-34 comment as "a real, deliberate V2 simplification." |
| Element count / size ceiling | INTENTIONALLY DIFFERENT | V2: 4 distinct array names × 16 elements each, integer-only, no per-element type tag (a deliberate RAM saving). Stock: bounded only by free memory, full float or string elements. |

## Variable model

| Stock capability | V2 status | Notes |
|---|---|---|
| Long variable names | PRESENT | V2 already supports up to 8-character multi-char identifiers (letters + digits after the first letter) — a genuine V2 improvement over the OLD V1 2068-Leap dialect's single-letter restriction (not a stock-BASIC comparison point; stock Spectrum BASIC itself also supports long names). |
| 16 numeric scalar variable slots | INTENTIONALLY DIFFERENT | Stock: bounded only by free memory. V2: `CSYMTAB_MAX_ENTRIES=16`, a deliberate, documented, bounded implementation scope. |

## Program structure

| Stock capability | V2 status | Notes |
|---|---|---|
| Line-numbered program, GOTO/GOSUB by number | INTENTIONALLY DIFFERENT | V2 uses a generic, non-line-numbered plain-text line store with LABEL-based GOTO (real two-pass forward-reference resolution), a deliberate architectural departure documented throughout `docs/`. `LIST` shows no line numbers by design. |
| Program editing (line-numbered insert/renumber) | INTENTIONALLY DIFFERENT | V2's editor is a generic full-screen source editor (`rom/exrom_v2_shell.asm`/`rom/exrom_editor.asm`), not a line-number-addressed REPL — architecturally different editing model entirely. |
| Immediate-mode statement execution (no line number = execute now) | PRESENT | V2's leading-colon immediate-statement convention serves the same role. |

## I/O / hardware

| Stock capability | V2 status | Notes |
|---|---|---|
| Keyboard input (`INKEY$`, `INPUT`) | PRESENT | |
| Tape SAVE/LOAD (`SAVE`/`LOAD`/`VERIFY`) | PARTIAL | SAVE/LOAD present (real physical-tape-proven per R9); `VERIFY` absent (see Statements). |
| `IN`/`OUT` port I/O | ABSENT (see Statements/Functions above) | |
| Dual-screen / 64-column / Hi-Res graphics modes (TS2068-specific) | PRESENT, as a loadable package | `MODE`/`ULAPLUS`/`PALETTE` were deliberately externalized from resident opcodes to the loadable `rom/ext_mode_module.asm` package (R9-era product decision, not an R10 finding) — present, but architecturally different (must be loaded, not always resident). |
| AY-3-8912 sound chip control | UNCERTAIN | V2 has `SOUND` (see Statements) but whether it drives the AY chip with stock-equivalent richness (multiple channels, envelope control) was not independently verified against stock TS2068 ROM documentation in this pass. |
| Sprites | OUT OF SCOPE for this comparison | Not a stock TS2068 ROM BASIC capability at all (V2's `SPRITE` package is a pure V2-native addition, no stock equivalent to compare against). |
| Printer support (`LPRINT`/`LLIST`) | PRESENT, as a loadable package | Externalized to `rom/v2_package_printer.asm`, reached via the extension-registry mechanism — present but not resident. |

## Summary

V2 is a deliberately narrower, RAM-budget-driven dialect, not an
attempted stock-BASIC clone: several stock capabilities are absent by
explicit, documented design choice (GOSUB/RETURN replaced by PROC/CALL/
DEF FN; line numbers replaced by labels; multi-dimensional/runtime-sized
arrays replaced by fixed single-dimension ones; arbitrary-length strings
replaced by a fixed 4-variable/31-byte model) alongside a smaller number
of built-in functions that appear to be simply not yet implemented
rather than deliberately excluded (COS/TAN/ATN/EXP/LN, MID$, VAL$,
SCREEN$, DATA/READ/RESTORE, CIRCLE/DRAW, VERIFY/MERGE/CLEAR/IN/OUT,
FLASH/BRIGHT/OVER/INVERSE as PRINT-item control codes, FREE) and
a handful of genuine V2-native additions with no stock counterpart
(UPPER$/LOWER$, DEG/RAD, MOD/DIV, block IF/ELSE/ENDIF). This document
is a factual inventory for R11 planning, not a recommendation list —
no priority or restoration judgment is made here.

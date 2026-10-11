# V2 feature and compatibility matrix (release candidate)

V1 = the 2068-Leap "Release 1 Beta" ROM (`docs/user_manual.md`, Git `cd2f1df`). V2 RC = this
release candidate (`integration/v2-final-rom`). Intentional V1-to-V2 breaks are also recorded, with
their measured savings, in `COMPATIBILITY_BREAKS.md`; owner policy: breaking V1 compatibility is
acceptable for real ROM/RAM savings.

Legend: **=** same; **+** new or better in V2; **~** changed; **pkg** moved to a loadable package;
**--** not in V2 (deliberate).

## Language

| Feature | V1 | V2 RC | |
|---|---|---|---|
| Program structure | labels, no line numbers | same | = |
| Execution | line interpreter | whole-program compiler + bytecode VM; errors before anything runs | ~ |
| Variables | 26 single letters + strings | names up to 31 characters; 251 numeric + 251 string | + |
| Numbers | 16-bit integers (floats only in display special cases) | integers + 5-byte floats everywhere; overflow promotes; > 1.7E38 is error 67 | + |
| Number display | integer | integers plain, floats 4 decimals rounded | ~ |
| Literals 32768..65535 | 16-bit patterns (negative) | positive floats, still valid addresses (L-C) | ~ |
| Decimal / large literals | limited | exact floats | + |
| Strings | 31 characters | 31; literal > 31 is error 70; ordering comparisons `< > <= >=` | + |
| `AND`/`OR` | evaluate both sides | short-circuit | ~ |
| `IF` block / `ELSE` | yes | yes (`ENDIF`) | = |
| single-line `IF ... THEN stmt` | yes | only `THEN GOTO label` | -- |
| `ELSEIF` | yes | no (`ELSE` + nested `IF`) | -- |
| `FOR`/`NEXT`/`STEP`/`EXIT FOR` | integer | integer and float; zero-trip; bare `NEXT` | + |
| `GOSUB`/`RETurn` | yes | no (`PROC`/`CALL`/`ENDP` with a parameter, recursive) | -- / + |
| `DEF FN` | yes | yes | = |
| Arrays | numeric, `DIM a(n)` | numeric and string (`DIM a$(n[,w])`), 0-based, up to 16383 elements, overflow to segment 2 | + |
| Persistent arrays | no | Array Store (`LOAD ... ARRAY`), survives `RUN`/`CLEAR`/edits | + |
| `INT` | no-op (integers) | truncates floats toward zero (stock BASIC floors) | ~ |
| `SIN`/`COS`/`TAN`/`SQR`/`RAD`/`DEG`/`PI` | display-only special cases | full float functions (degrees) | + |
| `INSTR` | yes | no | -- |
| `VAL` | integer | integer or decimal | + |
| `MID$` | not documented | documented, clamped arguments | + |
| `HIT()`, `SPRITE` | resident | SPRITE package | pkg |
| `LPRINT`/`LLIST` | resident | `LPRINT` resident, `LLIST` in the PRINTER package | ~ / pkg |
| ULAplus `MODE`/`PALETTE` | resident | MODE package | pkg |
| `CIRCLE`, `FILL`, ... | resident (some) | SHAPES / GRAPHICS packages | pkg |
| `OUT`, `IN()`, `STICK()` | `STICK` resident; `OUT` a package | all resident | + |
| `PRINT` with several items (`;` `,`) | yes | yes | = |
| `AT`, `TAB`, colours | separate statements before `PRINT` | same | = |
| `READ`/`DATA`, string slicing, multi-dimensional arrays | no | no | = |

## Environment

| Feature | V1 | V2 RC | |
|---|---|---|---|
| Editor | full-screen, wrapped lines | same, bold keywords, status bar, faster redraw | = / + |
| BREAK | yes | CAPS SHIFT + SPACE, now also in tight loops and `PAUSE` (D5) | + |
| Variables after a stop | `STOP` kept them (breakpoint) | every stop keeps them; immediate `:` statements use them; `: GOTO label` | + |
| `CLEAR` | clears | resets variables, keeps program, packages, Array Store; ends loops | ~ |
| `SAVE`/`LOAD`/`VERIFY` | program | program; versioned tapes; `SAVE ... ALL` with variables and the Array Store | + |
| Array tapes | -- | `SAVE/LOAD ... ARRAY` | + |
| Packages | resident extensions | loadable packages, versioned ABI 2.0 (`PACKAGE_ABI.md`) | ~ |
| Tape compatibility | V1 tapes | V1 and stock tapes refused (`BAD TAPE VERSION`); V2 minor-0 tapes load; RC tapes need this ROM | ~ |

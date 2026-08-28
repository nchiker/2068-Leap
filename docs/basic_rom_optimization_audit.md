# BASIC ROM Optimization Audit

Status: first recovery pass implemented on `develop/v2` and verified by the
complete automated suite. `make audit-basic` regenerates the ranked global-
block inventory and `make budget` reports the current byte totals.

## Executive result

The first V2 recovery pass has increased free space from **2 to 312 HOME
bytes** and from **99 to 154 EXROM bytes**, without removing a user feature.
The shared low-ROM strings and dead highlighting pointer recovered 57 HOME
bytes and 55 EXROM bytes. Replacing the execution keyword chain and its jump
veneers with a table recovered another 253 HOME bytes after preserving IX.

| Opportunity | HOME | EXROM | Confidence |
|---|---:|---:|---|
| Put shared strings in unused `$00C8-$00FF` HOME window | 55 | 55 | Implemented and asserted |
| Remove dead `KW_THEN` highlighting pointer | 2 | 0 | Implemented |
| Reuse retired `$C072-$C077` EXROM entry slot | 0 | 6 | High for new internal bytes; ABI review required |
| Table-drive execution statement dispatch | 253 | 0 | Implemented and suite-verified |
| Replace numeric function ID branch chain | 35-60 | 0 | Medium; prototype required |

Current end-of-image headroom is **312 HOME bytes and 154 EXROM bytes**. The
retired six-byte entry remains an internal reusable hole and is deliberately
not counted as end-of-image free space.

## Routine-level measurements

The largest global blocks in `basic/basic.asm` are:

| Bytes | Address | Block | Assessment |
|---:|---|---|---|
| 644 | `$244A-$26CD` | `BASIC_REDRAW_PROGRAM` | Large but stateful and regression-prone |
| 610 | `$08FE-$0B5F` | `BASIC_EVAL_PRIMARY` | Contains a promising function dispatch chain |
| 510 | `$0154-$0351` | `BASIC_COMMAND_LOOP` | Includes cold initialization plus immediate-command handling |
| 509 | `$1DFC-$1FF8` | `BASIC_EXEC_STATEMENT_CONTENT` | Best first code-compression target |
| 310 | `$06BB-$07F0` | `BASIC_HANDLE_NAV` | Stateful; lower priority |
| 288 | `$26CE-$27ED` | `BASIC_DRAW_STATUS_LINE` | Multiple status modes; lower priority |
| 268 | `$0DD2-$0EDD` | `BASIC_EVAL_COMPARISON` | Possible later parser audit |
| 237 | `$0BAE-$0C9A` | `BASIC_SIN_FLOAT` | Math correctness risk outweighs first-pass return |
| 223 | `$1095-$1173` | `BASIC_EVAL_STR_FUNCTION_CALL` | Possible later dispatch consolidation |

The apparent zero textual references to `BASIC_COMMAND_LOOP` do **not** make it
dead: execution falls into it from the ROM driver. This is why the audit does
not equate reference counts with reachability.

## 1. Shared HOME/EXROM strings: 110 exact bytes

The HOME call table and magic byte end at `$00C7`; the driver then pads through
`$00FF`. Therefore `$00C8-$00FF` is an existing **56-byte physical hole inside
HOME ROM**. It does not appear in the ordinary 2-byte end-of-ROM budget because
it is internal fixed-layout padding.

Both HOME and EXROM currently assemble private copies of the strings in
`include/checker_keywords.inc`. EXROM pages only chunk 6 (`$C000-$DFFF`), so
HOME addresses `$0000-$3FFF` remain readable while EXROM executes. Placing up
to 56 bytes of common immutable string data in the low-page hole lets both
banks reference the same bytes directly.

One exact 55-byte selection is:

| String | Bytes including NUL |
|---|---:|
| `"ARRAY NOT DIMENSIONED"` | 22 |
| `"INVALID ARGUMENT"` | 17 |
| `"SYNTAX ERROR"` | 13 |
| `"IF"` | 3 |
| **Total** | **55** |

Moving these definitions into a fixed-address shared-data macro recovers 55
bytes at the end of HOME and removes the same 55 bytes from EXROM: **110 bytes
total**, while leaving one byte unused at `$00FF`. No runtime decoder or
indirection is required; both builds can derive fixed EQUs from the same
include, as the existing KTAB macro already does for code trampolines.

Risks to check in implementation: keep all RST/NMI addresses untouched, bump
the HOME/EXROM compatibility magic, assert the shared block ends at or before
`$0100`, and run both complete ROMs together so a stale bank pairing is caught.

## 2. Dead highlighting entry: 2 exact HOME bytes

`KEYWORD_HILITE_TABLE` contains `DW KW_THEN`. Its own source comment states
that the highlighter examines only the leading word of each colon-separated
segment; `THEN` cannot legally be that word and was user-confirmed not to bold.
Removing this pointer saves exactly two bytes. The `KW_THEN` string itself must
remain because IF parsing and checking use it.

## 3. Retired EXROM entry slot: 6 usable bytes

`EXROM_ENTRY_EDITOR_WRAP_TABLE_ADDR` still occupies the fixed slot
`$C072-$C077`, but its HOME wrapper and only caller were removed. For a V2 ABI,
that slot can hold a new six-byte entry, compact helper, or data. Removing it
without filling the slot does not move EXROM's final end because the following
entry remains fixed at `$C078`; the value is the ability to use those six bytes
in place.

## 4. Statement dispatcher: 253 verified HOME bytes

`BASIC_EXEC_STATEMENT_CONTENT` performs 41 explicit keyword probes. A normal
probe costs 8-9 bytes:

```asm
ld   de, keyword       ; 3
call match             ; 3
jr/jp nc, handler      ; 2 or 3
```

It then carries a large set of mostly three-byte `jp handler` veneers. A table
containing a keyword pointer and handler pointer costs four bytes per entry, or
164 bytes for 41 entries. A shared walker is expected to cost roughly 30-45
bytes and can dispatch with a synthetic return (`push handler` / `ret`) while
leaving the advanced text pointer in HL. Most current veneers disappear.

The implemented walker keeps `END IF` as a compound-keyword pre-check and uses
small handlers for `ULAPLUS`/`PALETTE`, `INPUT`, and stop semantics. It
preserves IX across dispatch, retains the original keyword order, and points
directly at ordinary statement handlers instead of retaining jump veneers.
The complete 68-fixture suite, smoke ROMs, and automated editor test pass.

## 5. Numeric function dispatch: estimated 35-60 HOME bytes

`BASIC_EVAL_PRIMARY` contains 20 `CP FUNC_ID_*` tests followed by conditional
branches, while `FUNCTION_TABLE` already carries a per-function ID and argument
count. A V2 table can carry a handler address instead of the ID. The address
costs one additional byte per entry, but removes most of the approximately
80-byte comparison chain.

HL cannot simultaneously contain both a numeric argument and an indirect jump
target—the reason documented for the current design—but the handler address
can be placed on the Z80 stack and entered with `ret` after argument parsing.
Nested function calls make a RAM scratch unsafe; the real stack is the correct
prototype. String-argument and array-name functions still require specialized
parsing paths, so the expected net saving is 35-60 bytes rather than the whole
chain.

## Recommended implementation order

1. Completed: shared low-page strings and stale-pairing magic bump.
2. Completed: dead `KW_THEN` highlighting pointer removal.
3. Completed: table-driven execution statement dispatcher.
4. Completed: static checks, smoke ROMs, editor automation, and 68 fixtures.
5. Next candidate: prototype numeric function-handler pointers separately.

No routine should be removed solely because the textual report shows zero
references. Entry fallthrough, fixed ABI addresses, jump tables, inline data,
and calculated control flow all exist in this codebase.

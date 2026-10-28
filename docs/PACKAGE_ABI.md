# 2068-Leap V2 — Package ABI 2.1 and tape-format versions

**Status:** implemented in R10.9 Phase 1 (working tree, not committed). **Single source of truth:**
[`include/v2_package_abi.inc`](../include/v2_package_abi.inc) — every number in this document is
parsed from that file by `tools/v2_abi.py` and re-verified against the built ROM by
`tools/check_package_abi.py` (part of `make check`) and by the production-ROM tests
`tools/v2_prod_regress.py` (`abi-*` cases). If this text and the file disagree, the file wins and
the checker fails.

Audience: anyone writing or changing a loadable package (SHAPES, SPRITE, MODE, GRAPHICS, PRINTER
are the shipped ones), or changing HOME-ROM code, `include/sysvars.inc`, or the tape code.

Evidence tags as in the R10.8 documents: **[M]** measured on the production ROM in this work,
**[S]** read from source, **[E]** estimate.

## 0. What the ABI is, and why it exists

A *package* is a ≤ 1 KB position-fixed binary that is loaded from tape into the *package window*
(`$F400–$F7FF`) and registers new statements (`CIRCLE`, `GRAB`, `MODE`, `LPRINT`, …) with the
compiler. Until R10.8 a package was assembled against `build/v2_crossbank.inc`, which hard-coded
~40 absolute HOME-ROM addresses and assembler-computed sysvar addresses, and the only check on
LOAD was `header word == 1`. Any later change to HOME code or the sysvar layout moved those
addresses, and an old package tape still passed the check and then called into the wrong code
(R10.8 finding **R1**).

ABI 2.0 fixes the three things a "jump table" alone cannot (ABI 2.1, back-port item 6.1, adds
package *functions*: §2 "Functions", service 16, the `EXT_CALL_RESULT` pin; item 6.2 adds floats:
§2 "The float form", service 17 `FP_OP`; item 6.3 registers the package error codes and adds an
error service: §2 "Errors", service 18 `VM_RAISE_ERROR`):

| Layer | Mechanism | Enforced by |
|---|---|---|
| **Callable services** | 19 fixed 3-byte `jp` slots in the HOME ROM at `$0096…` (the unused padding after the KTAB) | HOME build (the table is generated from the ABI file); `check_package_abi.py` §1; test `abi-service-table` |
| **Shared RAM** | 35 package-visible sysvar cells + 11 constants *pinned* to absolute addresses | HOME build `ASSERT`s every pin; `check_package_abi.py` §2–3 |
| **Data formats / banking / lifecycle** | tape header version word, record formats, banking and ownership rules (this document) | `STORAGE_LOAD` rejects a wrong word *before any byte is stored*; tests `abi-pkg-reject-*`, `abi-prog-reject-*`; `check_package_abi.py` §4–6 |

Packages are assembled with **only** `include/hardware.inc` and `include/v2_package_abi.inc`.
They no longer include `sysvars.inc` or `build/v2_crossbank.inc`, so a package *cannot name* a
HOME internal that is not listed: it is an assembler error.

## 1. Versions

All three V2 tape types carry a **version word** in the header's *autostart* field (offset 13,
little-endian):

```
word = $8000 | (major << 8) | minor        bit 15 = "V2-tagged"
```

Bit 15 set keeps the field a legal "no autostart" value for stock BASIC tooling, and lets a loader
tell *unversioned* (bit 15 clear, or major 0) from *versioned*.

| Tape | Header type | Current word | Meaning |
|---|---|---|---|
| Program | 0 | **`$8100`** | program format 1.0: the line store verbatim, `[len:2][text][CR]` records (§7.1) |
| Package (`SAVE/LOAD … EXT`) | 4 | **`$8201`** | package ABI 2.1 (this document; 2.0 tapes, `$8200`, still load). Major 1 was the unversioned raw-address ABI. 2.1 is not yet released, so its later additions (6.2's float form and service 17, 6.3's error range and service 18) are still 2.1 |
| Array (`… ARRAY`) | 8 | **`$8100`** | array format 1.0. Array persistence is an intentional V2 feature (the replacement for `DATA/READ/RESTORE`). R10.9 Phase 2C implements the persistent Array Store (§7.3): the header type, version word and check are unchanged, `SAVE ... ARRAY` now actually writes type 8 (D13) |

**Acceptance rule** (`STORAGE_LOAD`, `.name_ok`): *tag bit and major must equal the ROM's; the tape's
minor must not exceed the ROM's.* Anything else is refused with the new clean failure
(`A = STORAGE_LOAD_BAD_VERSION = $FE`, message **`BAD TAPE VERSION`**) — nothing is written to the
program area or the package window, the program survives, and a `LOAD … EXT` leaves no package
registered.

**When to bump** (edit `include/v2_package_abi.inc`; the checker and the tests follow the file):

* **minor** — a backward-compatible *addition*: a new service slot appended in the free slot area,
  a new pinned cell appended. Old packages keep working on the new ROM; new packages that use the
  addition are refused (cleanly) on an old ROM.
* **major** — anything else: a slot or pin removed, reordered, re-addressed, a changed register or
  banking contract, a changed record format. Every old tape of that type is then refused.
  Never change a contract without bumping.

## 2. Package image and lifecycle

```
$F400  jp  <install>          ; image entry (3 bytes); the rest is code + private data
...                           ; image ≤ EXTENSION_MODULE_LIMIT - EXTENSION_MODULE_BASE = 1024 bytes
```

**Install** — `V2_LOAD` calls `$F400` once after a successful LOAD, **with EXROM paged in** and
interrupts enabled. The routine registers its statements and returns *carry clear* on success,
*carry set* on any failure (a failure unregisters everything and zeroes `V2_PACKAGE_LEN`). It may
call `EXT2_REGISTER` (service 0, below) and `EXT2_EXPORTS` (service 16, ABI 2.1) and nothing else in HOME.

`EXT2_REGISTER` — In: `HL` = NUL-terminated upper-case name (≤ 8 significant characters; a literal
`$` is allowed), `DE` = execute entry point, `B` = argument count 0–5, `C` = argument-type bitmask
(bit *n* set ⇒ argument *n* is a string expression, delivered as a string-table index; ABI 2.1: bits
7-6 are the *kind*, below, 0 for a statement; bit 5 the *float form*, below). Out: carry
clear + `A` = slot, or carry set + `A = $FF` (registry full — 12 slots — `B > 5`, or the float form
with a string argument). Destroys
`AF BC DE HL`. Each registration receives a rolling, never-zero *generation* that the compiler
bakes into the bytecode; `OP_CALL_EXT` raises runtime error 9 if the slot's generation changed
(package replaced or cleared) — this part of the mechanism is unchanged and sound.

`EXT2_EXPORTS` (ABI 2.1) — In: `HL` → an export table: per export its NUL-terminated name, its entry
(2 B), its argument count (1 B) and its signature (1 B, `EXT2_REGISTER`'s `C`); a `0` byte ends the
table. Registers each export as `EXT2_REGISTER` does; out: carry clear when all are registered, carry set
+ `A = $FF` at the first that is not. An install can be `ld hl,table / jp EXT2_EXPORTS` (each export
then costs its name + 5 bytes). Destroys `AF BC DE HL`.

**Syntax a package gets.** `NAME expr, expr, …` — the name is matched only by a typed word of exactly its stored length (at most 8 characters, so a longer keyword can never be typed: CBEEP, not CLASSICBEEP); exactly `B` comma-separated expressions, no
parentheses, no optional arguments, no result (`COMPILE_EXT_CALL` is generic). Names are matched case-insensitively against the registry at *compile* time, so a
package must be registered before the program that uses it is compiled (every `RUN` recompiles).

**Functions (ABI 2.1).** The signature's bits 7-6 (`include/v2_ext_kinds.inc`) are the name's kind:
`EXT_KIND_STMT` `$00` a statement (every ABI 2.0 package), `EXT_KIND_FN` `$40` a numeric function,
`EXT_KIND_STR` `$C0` a string function (`$80` is reserved). A function is called in an expression as
`NAME(expr, …)` (a string function as `NAME$(…)`, registered without the `$`), parsed as a built-in
function call: exactly `B` arguments, each a string or a number as the signature's bits 4-0 say, the
built-ins' compile errors (29 no `(`, 30 too few, 31 too many, 3 a wrong argument type). A name binds
only where its kind fits: a function is not a statement (a function name at the start of a statement
is compiled as an assignment), a statement name in an expression is a variable or an array, and a
built-in of the same name wins over a package function. Execute routines are the statements', plus
the value: a numeric function writes it to `EXT_CALL_RESULT` (16 bits, pushed as an integer); a string
function writes there the address of `[length 0-31][text]` in its own memory (copied by the VM into a
string temporary before anything else runs). Without the float form a float argument arrives
truncated to a 16-bit integer (Q-33's rule, as for `POKE`).

**The float form (ABI 2.1, item 6.2).** Signature bit 5, `EXT_SIG_FLOAT` (`$20`), with any kind:
each argument arrives as the **address of a 5-byte float** (the calculator's format: an INT argument
is converted to its small-integer form `[0][sign][low][high][0]`), and a numeric function's value is
a float: the function writes the address of its 5 bytes to `EXT_CALL_RESULT` (in its own memory, or
one of its arguments), and the VM copies them into a float temporary. A string function's value and
a statement are as without the form. The float form's arguments are all numbers (bits 4-0 must be 0;
`EXT2_REGISTER` refuses anything else). The five argument values are the calculator's stack slots
0-4, the package's for the whole call: copies (writing one changes no variable), kept by `FP_OP`,
undefined after the call.

**Execute** — `OP_CALL_EXT` pops the arguments into `EXT_CALL_ARG0…4`, **pages EXROM out**
(`BANK_PAGE_EXROM_OUT`), then `call`s the registered entry; on return it pages EXROM back in.
Contract for an execute routine:

* Entry: arguments in `EXT_CALL_ARGn` (16-bit, little-endian; numeric values are the VM's 16-bit
  integers, string arguments are string-table indices; in the float form each is the address of a
  5-byte float). Registers: nothing is defined on entry.
* Exit: `ret`. **All registers may be destroyed** -- IY included: since the V2 Enhanced release the
  VM keeps its dispatch address in IY, and `OP_CALL_EXT` re-enters `VM_RUN` (which reloads it)
  after every package call. A statement has no return value; a function writes `EXT_CALL_RESULT`
  (ABI 2.1, above).
* Errors (ABI 2.1, item 6.3, closing R10.8 A3). **The codes a package may raise:** its own, **12–31**
  (`EXT_ERR_FIRST`..`EXT_ERR_LAST` in `include/v2_ext_kinds.inc`; the VM's own codes stay outside
  them: 1–11 and 64 up, its new ones above 67, 32–63 unassigned), and three of the VM's whose meaning
  it shares: **5** division by zero, **15** argument out of range, **67** a float result out of range
  (`EXT_ERR_DIV0`, `EXT_ERR_RANGE`, `EXT_ERR_FLOAT`). In use: 12–14 (MODE), 15–20 (SPRITE), 15
  (CBEEP), 21 (PRINTER's non-production LLIST). Compile errors are numbered apart and do not collide.
  The screen shows `RUNTIME ERROR n` (every runtime error without a message of its own).
  **Two ways to raise one:**
  - *ABI 2.0 (and 2.1):* write the code to `VM_ERROR_CODE` and `1` to `VM_HALTED`, and `ret`
    (`VM_RUN` stops on its next iteration; a function's value is not used). A package that must also
    load on a 2.0 ROM uses this.
  - *ABI 2.1:* `ld a,code` / `call VM_RAISE_ERROR` (service 18). It does not return: it unwinds to
    `VM_RUN`'s caller at once, from any depth of the package's own calls, with the EXROM paged in
    again (§3). Execute-time only.

  The code must not be 0 (that would stop the program with no error). `check_package_abi.py` checks
  every code the shipped packages raise (§8).
* Interrupts are **enabled** (IM 1, `RST $38` → `KBD_ISR_TICK`). The ISR touches only chunk-4/7
  state and the machine stack.
* Stack: the machine stack grows down from `$FF00`; `$F800–$FEFF` (1,792 bytes) is stack only. SP
  at package entry measured **`$FEFC`** under the test harness [M]; the production command-loop path
  adds a few frames. **Design allowance for a package: 512 bytes** (conservative; not a measured
  worst case).

| Event | Registry (12 slots) | Window / `V2_PACKAGE_LEN` |
|---|---|---|
| cold boot | cleared | empty |
| `LOAD "x" EXT` | cleared, then the new install registers | replaced |
| failed or refused (`BAD TAPE VERSION`) package load | cleared | length 0 |
| program `LOAD` | kept | kept |
| `NEW` | cleared | length 0; HOME also zeroes `SPRITE_SLOT_DEFINED/SHOWN`, `SPRITE_DISPLAY_DEPTH` |
| `CLEAR` statement | **kept** (R10.9 Phase 2C repaired D8: `CLEAR` is run-scoped and no longer touches packages) | kept |
| edit / `RUN` | kept | kept |

## 3. Service table (callable HOME routines)

Layout in the HOME ROM [M: read back from the emulated ROM by `abi-service-table`]:

```
$0092  5A 02 01 13      magic $5A, ABI major 2, minor 1, slot count 19
$0096  C3 lo hi         slot 0  (jp EXT2_REGISTER)
...    ...              19 slots, 3 bytes each, ending at $00CE
$00CF–$00EF             11 reserved slots (append-only), each `jp VM_ERR_EXTENSION_NOT_FOUND` (6.4)
$00F0–$00FD             slot code (PKG_NUM_TO_TEXT_SAFE, 14 bytes)
$00FE–$00FF             blank
```

A package calls a service by name (`call GFX_WRITE_PIXEL`): in a package build the name *is* the
slot address. The register contracts below are copied from the routines' own headers and are part
of the ABI (they cannot change without a major bump). "Destroys" lists what the caller must assume
lost; everything else is preserved.

| # | Slot | Name | In | Out | Destroys | Notes |
|--:|---:|---|---|---|---|---|
| 0 | `$0096` | `EXT2_REGISTER` | see §2 | carry/`A` | `AF BC DE HL` | install-time only |
| 1 | `$0099` | `GFX_SET_MODE` | `A` = 0 normal / 1 high-resolution | — | `AF BC DE HL` | writes `PORT_FF_SHADOW` + port `$FF`; invalidates sprite *shown* state; mode 1 clears the second display file |
| 2 | `$009C` | `GFX_CHAR_TO_FONT_OFFSET` | `A` = character | carry clear + `HL` → 8-byte glyph, or carry set (no glyph) | `AF BC E HL` | **`B` is destroyed**; `D` preserved |
| 3 | `$009F` | `GFX_SPRITE_CAPTURE` | `B` row 0–23, `C` col 0–31, `D` width cells, `E` height cells, `HL` buffer | carry clear ok / set = does not fit | `AF BC DE HL` | buffer = 9 bytes per cell |
| 4 | `$00A2` | `GFX_SPRITE_DRAW` | as capture | as capture | `AF BC DE HL` | straight overwrite (save-under technique) |
| 5 | `$00A5` | `GFX_PLOT_CLIPPED` | `HL` signed x, `DE` signed y, `A` attribute, `B` OVER (0 set / ≠0 xor) | — | `AF BC DE HL` | silently skips off-screen points |
| 6 | `$00A8` | `GFX_READ_PIXEL` | `B` x, `C` y (0–191) | `A` = 1 set / 0 clear | `AF BC DE HL` | |
| 7 | `$00AB` | `GFX_WRITE_PIXEL` | `B` x, `C` y (0–191), `A` attribute byte, `D` OVER (0 set / ≠0 xor) | — | `AF BC DE HL` | also writes the 8×8 attribute cell |
| 8 | `$00AE` | `MEM_LINE_FIRST` | — | `HL` → first record, or 0 if the program is empty | `AF DE HL` | record = `[len:2][text, len-1 bytes][CR]` (§7.1) |
| 9 | `$00B1` | `MEM_LINE_NEXT` | `HL` → current record | `HL` → next record, or 0 | `AF BC DE HL` | |
| 10 | `$00B4` | `MATH_MULTIPLY16` | `HL`, `DE` signed | `HL` = product (low 16 bits, truncating) | `AF BC DE` | no overflow signal |
| 11 | `$00B7` | `MATH_NEGATE16` | `HL` | `HL` = −`HL` (−32768 stays) | `AF` | |
| 12 | `$00BA` | `VM_CLAMP_Y191` | `A` | `A` clamped to 0–191 | `AF` | |
| 13 | `$00BD` | `VM_COMPUTE_PRINT_ATTR` | — | `A` = attribute byte from `CURRENT_INK/PAPER/BRIGHT/FLASH/INVERSE` | `AF BC` | |
| 14 | `$00C0` | `VM_NUM_TO_TEXT` | `HL` = value, `A` = `TAG_INT` (0) **only** | `HL` → NUL-terminated text in `PRINT_BUF` | `AF BC DE HL` | **EXROM-safe wrapper**, see below. The float tag (`HL` = float-table index) is *not* part of ABI 2.0: it reaches the calculator via `RST $28` and has not been exercised through the wrapper |
| 15 | `$00C3` | `VM_STR_ADDR` | `A` = string-table index | `HL` → record `[len:1][content…, NUL]` | `AF DE HL` | |
| 16 | `$00C6` | `EXT2_EXPORTS` | `HL` → export table (§2) | carry/`A` | `AF BC DE HL` | ABI 2.1; install-time only |
| 17 | `$00C9` | `FP_OP` | `A` = operation, `HL` → x, `DE` → y (5-byte floats) | x = the result; `FOP_TRUNC`: `HL`, carry | `AF BC DE HL` | ABI 2.1 (6.2); execute-time only; see below |
| 18 | `$00CC` | `VM_RAISE_ERROR` | `A` = the error code (§2 "Errors") | does not return | — | ABI 2.1 (6.3); execute-time only; see below |

**Slot 14 is not a direct jump** (finding **ABI-F1**). `VM_NUM_TO_TEXT` ends in a jump to
`BASIC_NUM_TO_STRING_EXROM` (`$C09C`), which is EXROM code; a package runs with chunk 6 paged to
RAM, so calling it directly executes whatever RAM is at `$C09C`. [M] On the R10.8 ROM, `LPRINT 123`
(PRINTER package) fell into a NOP slide through `$C09C…` and executed arbitrary RAM (test
`pkg-printer-lprint-number`: FAIL at baseline, PASS now). The slot therefore points at
`PKG_NUM_TO_TEXT_SAFE`, 14 bytes in the padding: `push af / call BANK_PAGE_EXROM_IN / pop af /
call VM_NUM_TO_TEXT / push hl / call BANK_PAGE_EXROM_OUT / pop hl / ret` (nest-safe: the `BANK_*`
routines keep a depth count). `check_package_abi.py` verifies those exact bytes and refuses to let
`VM_NUM_TO_TEXT` be exposed any other way.

**Service 17, `FP_OP`** (item 6.2; `rom/v2_pkg_fp.asm`): float arithmetic on 5-byte values anywhere in
RAM (the package's memory or the float form's arguments). The operations (`include/v2_ext_kinds.inc`):

| `A` | Name | Does | Out |
|--:|---|---|---|
| 0-3 | `FOP_ADD`, `FOP_SUB`, `FOP_MUL`, `FOP_DIV` | x = x + y, x − y, x × y, x / y | x; carry clear |
| 4 | `FOP_INT` | x = the 16-bit signed integer `DE` | x; carry clear |
| 5 | `FOP_TRUNC` | x truncated toward zero | `HL`; carry set when x is outside −32768..32767 (`HL` then 32767 or −32768) |

A result beyond the range (about 1.7E38) or a division by zero **stops the program with runtime error
67**, as the same operation in BASIC does: `FP_OP` uses the VM's own calculator stubs, and the error
unwinds from package code to `VM_RUN`'s caller with the EXROM paged in again (back-port item 2.3) [M:
`tools/qual/qpkgfn.py`, paging depth 1 afterwards]. So `FP_OP` is for an **execute routine only**, not
the install. It runs with the EXROM out: the calculator pages itself in and out (`RST $28` through
`V2_CALC_ENTRY`, depth-counted), `FOP_TRUNC` calls `CALC_FP_TO_INT` between `BANK_PAGE_EXROM_IN` and
`_OUT`. It works in calculator slots 5-6, so the float form's arguments (slots 0-4) survive it.

**Service 18, `VM_RAISE_ERROR`** (item 6.3): a `jp` to the VM's own `VM_ERR_COMMON`, the routine every
runtime error goes through. It stores `A` in `VM_ERROR_CODE`, sets `VM_HALTED`, resets `SP` to the one
`VM_RUN` was entered with and pages the EXROM in at depth 1 (item 2.3), so whatever the package had
on the stack is dropped [M: `tools/qual/qpkgfn.py` `RAISES`: from a function, nested in another
package call's arguments and in a statement's, in a loop; depth 1 afterwards]. That `SP` is only
defined while the program runs: **execute routines only**, never the install. Codes: §2 "Errors".

**The reserved slots trap** (item 6.4): each of the 11 reserved slots (`$00CF–$00EF`) is a `jp
VM_ERR_EXTENSION_NOT_FOUND` (it was blank `$FF`). A package that calls a service this ROM does not
have (one built for a later minor) stops with runtime error 9, the error of a package name whose
registry slot is gone, shown `RUNTIME ERROR 9`, instead of executing `$FF` bytes (`RST $38`). Like
service 18 the trap unwinds through `VM_ERR_COMMON`, so it exists only while a program runs (an
execute routine): at install time a package must check the header's minor and slot count itself
(and the tape's version word already keeps a package that needs a later minor from loading) [M:
`tools/qual/qpkgfn.py` `RAISES`: fptest `TRAP(0)` calls the first reserved slot, `TRAP(1)` the last;
both give error 9, `RUNTIME ERROR 9`, paging depth 1 afterwards; had a slot returned, 99].

**EXROM independence rule.** A service reachable from a package must never transfer control to, or
read data from, `$C000–$DFFF` unless it pages EXROM in itself. `check_package_abi.py` walks each
slot's call/jump closure in the HOME listing (§4 of the checker) and fails the build on any such
edge; the 17 plain slots have **no** EXROM edge [M], slot 14's inner routine has three
(`BASIC_NUM_TO_STRING_EXROM`, `CALC_INT_TO_FP`, `BASIC_FLOAT_TO_STRING_EXROM`), all covered by the
wrapper. Slot 17 (`FP_OP`) is audited by its own rule: its closure, its indirect call taken as the
VM's four calculator stubs, reaches the EXROM only through `RST $28` and through `CALC_FP_TO_INT`
called right after `BANK_PAGE_EXROM_IN` and followed by `BANK_PAGE_EXROM_OUT`.

**Adding a service** (minor bump): append `PKG_SVC name, home_routine` to `PKG_SVC_LIST`, bump
`PKG_SVC_COUNT` and `PKG_ABI_MINOR`. There are 11 reserved slots before `$00F0` (traps, above; a new
service replaces the next one). A routine that needs more than a `jp` must put its few bytes of code
in the slot-code area or in HOME proper.

## 4. Pinned RAM and constants

Every cell below is `ASSERT`ed in the HOME build. Owners: **H→P** HOME writes, package reads;
**P→H** package writes, HOME reads; **P** package-private (HOME never writes it, except where
noted); **H** HOME state the package may read.

| Cells | Address | Owner / access |
|---|---|---|
| `EXT_CALL_ARG0…3` | `$BED8,$BEDA,$BEDC,$BEDE` (2 B each) | H→P: written by `OP_CALL_EXT` |
| `EXT_CALL_ARG4` | `$BEEC` (2 B) | H→P: 5th argument, *not* contiguous |
| `EXT_CALL_RESULT` | `$BEE0` (2 B) | P→H: a function's value (ABI 2.1, §2) |
| `VM_ERROR_CODE`, `VM_HALTED` | `$B683`, `$B684` | P→H (package error reporting; also written by the VM) |
| `CURRENT_OVER` | `$8106` | H: current `OVER` state (INK/PAPER/etc. are read through service 13) |
| `GFX_CIRCLE_XC…GFX_CIRCLE_D` | `$8140–$8148` (9 B) | P: SHAPES `CIRCLE` scratch |
| `GFX_FILL_SP/TARGET/ATTR/X/Y` | `$814C–$8151` (6 B) | P: SHAPES `FILL` scratch |
| `SPRITE_SLOT_DEFINED/SHOWN/W/H/ROW/COL` | `$8185–$81B4` (6 × 8 B) | P: SPRITE per-slot state. **HOME also writes:** `MEM_INIT` zeroes DEFINED and SHOWN; `GFX_SPRITE_INVALIDATE` (from `GFX_CLS`, scrolling, `GFX_SET_MODE`) zeroes SHOWN |
| `SPRITE_DISPLAY_DEPTH` | `$81B5` | P, zeroed by HOME with SHOWN |
| `PRINT_ROW_BUF`, `PRINT_ROW_IDX`, `PRINT_CHUNK_ADDR/LEN`, `PRINT_REMAINING`, `PRINT_CUR_ADDR` | `$8232–$8259` | P: PRINTER raster scratch |
| *package scratch block* | `$BFB0–$BFBA` (11 B) | P: reserved, call-scoped (SPRITE `SPR_*`, addressed with literals). HOME and EXROM must never reference it — `check_package_abi.py` scans both listings |

Constants: `EXTENSION_MODULE_BASE=$F400`, `EXTENSION_MODULE_LIMIT=$F800`, `TAG_INT=0`,
`SPRITE_SLOT_MAX=8`, `SPRITE_CELL_MAX=4`, `SPRITE_SLOT_BYTES=144`, `SPRITE_SLOT_IMG_BUF=$E800`,
`SPRITE_SLOT_BG_BUF=$EC80` (1,152 B each, chunk 7, never paged), and the FILL scratch
`GFX_FILL_VISITED=$C000` (6,144 B bitmap), `GFX_FILL_STACK=$D800`, `GFX_FILL_STACK_END=$DC00`.

Where a pinned *sysvar* sits among HOME's other variables is incidental; what is promised is the
address. If a HOME change would move one, either keep it where it is (put the new variable in the
`$BE84–$BED7` gap or at the end of the block, as R10 did) or bump the major version.

**Private state.** The sysvar-resident package scratch above exists for historical reasons. New
packages should keep private state *inside their own image* (as GRAPHICS does) or in the package
scratch block, not add pinned HOME cells.

## 5. Memory, banking, ownership rules

1. **EXROM is paged out while a package statement runs** (`BANK_EXROM_DEPTH` = 0). Do not call
   EXROM code, `BASIC_*_EXROM`, the calculator (`RST $28`; float arithmetic is service 17), or
   `BANK_PAGE_EXROM_IN` (a nested page-in would hide the scratch you are using). The install call
   is the exception: it runs with EXROM *in* — do not rely on chunk 6 RAM there.
2. **`$C000–$DFFF` is hidden RAM during execute** (only). Contents are undefined between
   statements: nothing persistent may live there. Today only FILL uses it (visited bitmap
   `$C000–$D7FF`, seed stack `$D800–$DBFF`); `$DC00–$DFFF` is unused. Interrupts stay enabled; the
   ISR does not touch chunk 6. Any future ISR work that does must re-derive this.
3. **The window `$F400–$F7FF` belongs to one package at a time.** A package is its own image: code,
   constants and (if it wants) private variables. `SAVE … EXT` writes the window back out as it
   currently is — including any private variables the package has dirtied.
4. **Sprite store (`$E800–$F0FF`) is persistent and chunk-7**, owned by the SPRITE package; HOME
   only clears its metadata (§4).
5. **Segment 2 arrays (`$E000–$E7FF`) survive package calls** [M, R10.8 `t25`]; packages must not
   write below `SPRITE_SLOT_IMG_BUF` in chunk 7.
6. A package must not modify `EXT2_*`, the compile/run tables, the line store or any HOME variable
   not listed in §4. It may read the line store only through services 8–9.
7. Errors are reported only through §2's mechanisms, with the codes §2 allows; a package must not
   leave `VM_HALTED` set without an error code.

## 6. How the version check works (and what it does not do)

`STORAGE_LOAD` (EXROM, `kernel/storage/storage.asm`) receives the header block first. After the
type and name match (`.name_ok`), and **before** the length check and before any data byte is
received, it compares the header's version word with the one for `STORAGE_REQUEST_TYPE`
(`STORAGE_VERSION_WORD`: `PKG_ABI_WORD` for type 4, `V2_FORMAT_WORD` otherwise) under the rule in
§1. `STORAGE_SAVE` stamps the same word. Both are compiled in only when `STORAGE_VERSIONED` is
defined (the production EXROM, `rom/v2_exrom.asm`); the legacy V1 chain and the fake-transport
component tests assemble byte-identically to before.

It does **not** (and cannot) check that a package binary was built against the ABI it claims: the
header word is the builder's claim. `make v2-packages` stamps it from the ABI file
(`tools/make_extension_tzx.py --v2`), and `check_package_abi.py` proves the shipped sources
reference nothing outside the ABI. `SAVE … EXT` stamps the *ROM's* current ABI word on whatever is
in the window; the window can only contain a package that passed the check, so this is at worst
over-conservative on a later, lower-minor ROM.

## 7. Compatibility consequences

### 7.1 Program tapes

Format 1.0 is the line store verbatim: the bytes from `PROG_AREA_START` to `PROG_END`, i.e.
records `[len:2 LE][text, len−1 bytes][CR $0D]`, `len` including the CR, ≤ 128 and ≥ 1. `LOAD`
does not yet validate the record chain after receiving (R10.8 R3); `MEM_LINE_NEXT` is bounded by
`PROG_END`, so a malformed body yields junk lines, not a hang. Validating the chain remains
future work and will be a *minor* addition only if it rejects nothing a 1.0 writer could produce.

| Tape | Before (≤ R10.8) | Now |
|---|---|---|
| Program saved by this ROM (V2 Enhanced release) | — | version word `$8101`; accepted |
| Program saved by R10.9 .. pre-RC V2 | — | `$8100` (minor 0 <= 1): accepted |
| Program saved by R10.8 or earlier V2 | autostart = stale header-buffer contents (typically `$0000`) | **refused** (`BAD TAPE VERSION`), program untouched |
| Stock Spectrum/TS2068 BASIC program tape | accepted as garbage source (R3) | **refused** — stock autostart is a line number or `$8000` (major 0) |
| Future program format | n/a | refused if major ≠ 1 or minor > 1 |

**V2 Enhanced release (format 1.1).** The header's PROGLEN field is the program's own length. A
plain `SAVE` writes PROGLEN = the data length, exactly as 1.0. `SAVE "name" ALL` writes a longer
block -- the program followed by the variable session and the Array Store
(`V2_SAVE_ALL_FORMAT.md`) -- so PROGLEN < length marks it. Minor 1 makes every pre-RC V2 ROM
refuse this release's tapes (it would otherwise load a session as program text); this applies to array
tapes too, which share `V2_FORMAT_WORD`. Package tapes (`PKG_ABI_WORD`) are unchanged.

There is no in-ROM migration for pre-R10.9 program tapes. *Policy question for the owner*
(raised in the Phase 1 report): accepting `$0000` as "legacy V2 program" would revive them at the
cost of also accepting any stock tape saved with `LINE 0`; the one-line change would go in
`.name_ok`. It is deliberately **not** done, to honour "never silently accept incompatible data".

### 7.2 Package tapes

Every package tape built before R10.9 (header word `1`, absolute HOME addresses inside the image)
is **refused** and must be rebuilt from source with `make v2-packages`; the five shipped packages
are rebuilt by that target and their `.tzx` stamped `$8200`. This is a one-time, intentional break
(R10.8 plan M-6). Package *sizes* are unchanged (mode 165, sprite 832, printer 345, shapes 795,
graphics 467 bytes) [M].

ABI 2.1 (6.1): `make v2-packages` stamps every package tape with the ROM's word, now `$8201`, and
`SAVE … EXT` stamps the running ROM's word too; a 2.0 ROM refuses `$8201`, so packages built here no
longer load on v2.0.x ROMs although the shipped ones use nothing of 2.1. Open: stamp each package
with the minor it needs.

### 7.3 Array tapes and the Array Store (R10.9 Phase 2C)

Array tapes keep header type 8 and the `$8100` format word; **the format did not change**, so ABI 2.0 and the tape
version words are unchanged. Phase 2C repaired the writer (`SAVE ... ARRAY` wrote a type-0 header before, D13) and
specified the body, which `LOAD ... ARRAY` now validates before anything is stored (`docs/R10_9_PHASE2C_REPORT.md` §3):

* numeric: `[1][count:2][count x 2]`, `1 <= count < 2048`, length exactly `3 + 2*count`;
* string: `[1][count:2][width:1][count x width]`, `width >= 2`, every element's length byte `<= 31` and `< width`,
  length exactly `4 + count*width`.

A loaded array lives in the **Array Store**: segment 2 (`$E000` up to `PAS_END`), outside the edit-volatile pool. The
store is private to the Leap ROM (`PAS_END` is not a pinned package cell, no service slot touches it); packages must keep
treating `$E000-$E7FF` as off limits, as in §5.5. `NEW` clears it; `RUN`, `CLEAR`, edits, immediate statements and program
`LOAD` (successful or failed) keep it.

## 8. Automated guard rails

| Guard | Catches |
|---|---|
| HOME build `ASSERT`s (`PKG_PIN_LIST`, `PKG_CONST_LIST`, table layout) | any sysvar/constant moving; table overlapping the KTAB or the slot code |
| `tools/check_package_abi.py` (in `make check`) | table bytes ≠ ABI file; a reserved slot that is not exactly `jp VM_ERR_EXTENSION_NOT_FOUND` (6.4); pin overlaps; HOME/EXROM touching the package scratch block; EXROM edges from any service; the wrapper's exact bytes; a package that does not assemble against the ABI file alone; any package call/jump into HOME that is not a slot; any package memory reference outside pinned cells and hardware ranges; literal addresses in package sources; an error code a shipped package raises that §2 does not allow, or one not given as `ld a,n` right before the raise (6.3) |
| `tools/v2_prod_regress.py` `abi-*` | the shipped ROM's table; slot 14 with EXROM out; end-to-end package tape load + run; rejection of 6 package and 6 program header words with no side effects; SAVE stamps; SAVE→LOAD round trips |

Negative controls were run when the checker was written (an unpinned `ld a,($8200)` and a raw
`call $0FBA` in a package are both reported; moving a pinned cell fails the HOME build).

## 9. Checklist for a new package

1. Include `hardware.inc`, `v2_package_abi.inc`, then `PKG_SVC_LIST`, `PKG_CONST_LIST`,
   `PKG_PIN_LIST` (copy `rom/v2_package_mode.asm`). Do not include `sysvars.inc`.
2. `ORG EXTENSION_MODULE_BASE`; first instruction `jp <install>`; `ASSERT $ <= EXTENSION_MODULE_LIMIT`.
3. Use only listed services/pins. Need something else? Propose a minor ABI addition.
4. Keep private state in the image; if you need call-scoped scratch use `$BFB0–$BFBA`.
5. Never call EXROM code. Never assume chunk 6 contents between statements.
6. Add the package to `PACKAGES` in `tools/check_package_abi.py`, to `make v2-packages`, and add a
   production test next to `pkg-*` in `tools/v2_prod_regress.py`.
7. Build with `make v2-packages` (stamps the ABI word) and run `make check test`.

## 10. Inventory (what each shipped package uses)

| Package | Services | Pinned RAM / constants | Other |
|---|---|---|---|
| SHAPES (795 B) | 0, 5, 6, 7, 11, 12, 13 | `EXT_CALL_ARG0–2`, `CURRENT_OVER`, `GFX_CIRCLE_*`, `GFX_FILL_*`, FILL scratch consts | hidden chunk-6 RAM for FILL |
| SPRITE (832 B) | 0, 3, 4, 10 | `EXT_CALL_ARG0–4`, `SPRITE_SLOT_*`, sprite consts/buffers, `VM_ERROR_CODE`, `VM_HALTED` | `$BFB0–$BFBA` scratch |
| MODE (165 B) | 0, 1 | `EXT_CALL_ARG0–1`, `VM_ERROR_CODE`, `VM_HALTED` | ports `$BF3B/$FF3B` (ULAplus) written directly |
| GRAPHICS (467 B) | 0, 7, 12, 13 | `EXT_CALL_ARG0–3`, `CURRENT_OVER` | private state inside the image |
| PRINTER (345 B) | 0, 2, 8, 9, 14, 15 | `EXT_CALL_ARG0`, `VM_ERROR_CODE`, `VM_HALTED`, `PRINT_*` | port `$FB` written directly |
| CBEEP (260 B; maintenance candidate, optional) | 0 | `EXT_CALL_ARG0–2`, `VM_ERROR_CODE`, `VM_HALTED` | port `$FE` written directly (the loudspeaker; the border colour comes from the third argument, because `PORT_FE_SHADOW` is not a pinned cell); private state inside the image; `kernel/sound/sound.asm` assembled into it |

Hardware ports used directly by packages (`$BF3B`, `$FF3B`, `$FB`, `$FE`) are hardware, not HOME, and are
outside the ABI. R10.8's open item A4 (a documented clobber contract for execute routines) is
closed by §2; A3 (error-code namespace) is closed by §2 "Errors" (item 6.3): 12–31 registered for
packages, no package renumbered.

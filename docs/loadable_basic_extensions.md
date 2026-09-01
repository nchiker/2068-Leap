# Loadable BASIC extensions

## Purpose and current status

The ROM supports one loadable BASIC statement extension at a time. An
extension is Z80 code in the fixed `$F400-$F5FF` RAM window, distributed with
the normal tape transport and installed with:

```basic
LOAD "name" EXT
```

An installed extension can be written back to tape with:

```basic
SAVE "name" EXT
```

`CPLOT`, `BLOCK`, `FRAME`, `INVERT`, and `AYREG` are the reference modules. They demonstrate both supported
grammars, the stable service ABI, static editor checking, lifecycle handling,
and deterministic and pulse-level tape tests.

This is intentionally a small statement-extension gateway. It is not yet a
general overlay system: loadable numeric/string functions, custom grammars,
multiple simultaneous modules, and arbitrary access to internal ROM routines
are not supported.

## Memory layout

| Range or address | Purpose |
|---|---|
| `$F3AF-$F3B5` | Registry: magic, keyword pointer, execution pointer, and `INSTR` state |
| `$F3B6` | Service ABI version byte |
| `$F3B7-$F3C2` | Four fixed three-byte callable `JP` veneers |
| `$F3C3` | Grammar descriptor |
| `$F3C4-$F3C7` | Four grammar-result bytes |
| `$F400-$F5FF` | 512-byte extension module window |
| `$F600-$FEFF` | Reserved machine-stack headroom |

The module, its null-terminated keyword name, and its execution entry point
must all remain inside `$F400-$F5FF`. `BASIC_EXTENSION_REGISTER` checks the two
pointers before publishing the registry magic. The magic is written last, so
partially initialized registry state cannot become callable.

Only the magic is needed to unregister a module. `NEW`, cold initialization,
and every ordinary or extension `LOAD` clear it. The bytes may remain in the
module window afterward, but they are unreachable through BASIC.

## Module entry contract

The first byte at `$F400` is the installer entry called by `LOAD ... EXT` after
the tape block has passed all validation. A normal installer:

1. compares `$F3B6` with `EXT_SERVICE_ABI_VERSION`;
2. returns with carry set on a version mismatch;
3. loads `HL` with its null-terminated keyword name;
4. loads `DE` with its execution callback;
5. loads `C` with a supported grammar number;
6. calls `EXT_SERVICE_REGISTER`; and
7. returns the registration result without publishing state itself.

Minimal skeleton:

```asm
    INCLUDE "build/test_basic.sym"

    ORG EXTENSION_MODULE_BASE
    OUTPUT "build/extensions/example.bin"

EXAMPLE_INSTALL:
    ld   a, (EXT_SERVICE_VERSION_ADDR)
    cp   EXT_SERVICE_ABI_VERSION
    jr   nz, .abi_fail
    ld   hl, EXAMPLE_NAME
    ld   de, EXAMPLE_EXEC
    ld   c, 0
    call EXT_SERVICE_REGISTER
    ld   hl, 0
    ret
.abi_fail:
    scf
    ret

EXAMPLE_NAME:
    DB "EXAMPLE", 0

EXAMPLE_EXEC:
    ; Grammar 0 supplies BC=first expression and DE=second expression.
    or   a
    ret

EXAMPLE_END:
    ASSERT EXAMPLE_END <= EXTENSION_MODULE_LIMIT
```

An execution callback returns carry clear for success and carry set for an
error. It must preserve normal BASIC invariants: balance the machine stack,
leave paging as it found it, and never retain pointers to transient parser or
editor buffers.

## Stable service ABI, version 1

Modules call the fixed RAM veneer addresses, never the movable Home-ROM or
EXROM targets behind them.

| Address/symbol | Service | Contract |
|---|---|---|
| `$F3B7` `EXT_SERVICE_REGISTER` | Register module | `HL=name`, `DE=callback`, `C=grammar`; carry on invalid pointers |
| `$F3BA` `EXT_SERVICE_PRINT_ATTR` | Compute current print attribute | Returns attribute in `A` |
| `$F3BD` `EXT_SERVICE_WRITE_PIXEL` | Write a mode-aware pixel | Uses `B=x`, `C=y`, `D=OVER`, `A=attribute` |
| `$F3C0` `EXT_SERVICE_READ_OVER` | Read current OVER mode | Returns value in `A` |

Each service slot is a three-byte `JP` veneer copied into RAM by `MEM_INIT`.
Calling the veneer therefore has ordinary `CALL`/`RET` behavior while keeping
the module independent of changing ROM addresses.

The ABI is append-only once distributed modules exist: do not reorder, resize,
or repurpose a slot. A module must reject an ABI version it does not understand
by returning an error; it must never halt the machine. If an incompatible ABI
is ever unavoidable, retain the old table or introduce a separately versioned
module format.

## Supported grammar descriptors

The grammar byte is data interpreted independently by the runtime and the
static editor checker. The checker never executes module code.

| Grammar | BASIC form | Callback inputs |
|---:|---|---|
| `0` | `KEYWORD expr,expr` | `BC=first`, `DE=second` 16-bit numeric results |
| `1` | `KEYWORD expr,expr TO expr,expr` | Low bytes at `EXTENSION_ARG0..3` |

Grammar 0 is used by `CPLOT` and `AYREG`. Grammar 1 is used by `BLOCK`; its four fixed
bytes are deliberately coordinate-sized. Registration invalidates the
editor's cached verdict so a statement previously marked as unknown is checked
again immediately after its extension is installed.

Adding a grammar has a permanent resident cost in both the runtime parser and
the EXROM checker. It must remain a declarative descriptor: allowing a module
checker callback would execute untrusted RAM merely while the user edits a
line and would invalidate the current safety model.

## Tape format and validation

Extension files reuse the existing 17-byte storage header and checksummed data
block:

| Header field | Extension meaning |
|---|---|
| Type | `4`, extension module |
| Name | Normal padded tape filename |
| Length | Exactly 512 bytes |
| Autostart | Extension ABI version (`1`) |

The destination and installer address are fixed at `$F400`; they are not
accepted from tape. Before calling the installer, `LOAD ... EXT` validates the
requested name, header type, exact length, block checksum, and ABI version.
An explicit name is mandatory: `LOAD "" EXT` is rejected rather than loading
an arbitrary extension from a multi-file tape.

Ordinary program LOAD ignores extension-type headers while searching, just as
it ignores other nonmatching header types. `SAVE ... EXT` fails cleanly when no
module is registered.

The automated tests prove production parsing, validation, installation, and
round-trip behavior with only the pulse-timing transport stubbed where needed.
`BLOCK` has additionally run after a generated Direct Recording TZX passed
through the emulator's live pulse decoder. Physical cassette/hardware
qualification remains a separate task.

### Physical cassette qualification checklist

Run this unchanged for CPLOT, BLOCK, FRAME, INVERT, and AYREG on a TS2068 before describing
extension tape support as hardware-qualified:

1. Cold boot, load the module with an explicit filename, execute its simplest
   valid statement, and verify visible output.
2. `SAVE "ROUNDTRIP" EXT`, cold boot, rewind, `LOAD "ROUNDTRIP" EXT`, and
   execute the same statement again.
3. Confirm `NEW` unregisters it and an ordinary program `LOAD` also unregisters
   it before searching.
4. Try a wrong filename, truncated recording, damaged/checksum-failing data
   block, wrong ABI version, and a non-extension header encountered first.
   Each must fail or continue searching without publishing a registry entry.
5. Confirm `LOAD "" EXT` is rejected and `SAVE "name" EXT` without an installed
   module reports failure rather than stale header contents.
6. Repeat on at least two recording levels or cassette units and record the
   hardware, recorder, medium, and observed status milestones.

This is intentionally not marked complete by emulator results. The generated
TZX and deterministic transport tests validate framing and ROM behavior, but
they do not cover analog signal level, motor/cable behavior, or recorder
variation.

## Building and testing a module

Use `rom/extensions/cplot.asm`, `rom/extensions/block.asm`, and
`rom/extensions/frame.asm` as the canonical examples. Their Makefile targets
build normal, injected-test, and lifecycle variants:

```sh
make cplot-extension block-extension frame-extension
```

The full project check covers the storage and extension regression tests:

```sh
make check
bash tools/run_all_tests.sh
```

For a new module, add at minimum:

- a normal module binary and a test-injection variant;
- installed execution and unloaded-rejection fixtures;
- a `NEW`/ordinary-LOAD unregister test;
- boundary cases for every supported argument grammar;
- exact module-window and ABI-version assertions; and
- an extension tape round-trip or load test using the production dispatch and
  validation path.

Do not accept a successful assembly that reports a ROM-size warning. The
project's strict assembler wrapper treats truncation warnings as failures for
this reason.

## Feature-selection guidance

The best external features are optional, self-contained statement commands
whose implementation fits in 512 bytes, uses grammar 0 or 1, needs only the
published services, owns no state outside its module window, and can disappear
cleanly on `NEW` or `LOAD`.

### Previously discussed candidates

| Candidate | Suitability | Reason |
|---|---|---|
| `CPLOT` | Excellent; implemented | Small optional graphics command; grammar 0 and existing pixel services are sufficient |
| `BLOCK` | Excellent; implemented | Small optional graphics command; motivated and proves grammar 1 |
| `HELP` | Best next candidate after ROM recovery | Old implementation is compact and optional, but needs a no-argument grammar plus safe text/screen/key services not present in ABI v1 |
| Compact relative `DRAW`/line or box variants | Good if kept small | Can use numeric grammar and pixel services; must fit the single window without persistent engine state |
| Header/storage detail command | Conditional | Could be useful, but needs a narrow read-only storage-information service and probably a new grammar |
| `VERIFY` | Poor; rejected | The measured prototype required about 45 Home and 145 EXROM bytes despite a small RAM payload; most cost remained in resident parsing/storage support |
| `SAVE`/`LOAD ... CODE`, `SCREEN$`, array `DATA`, `CAT` | Poor under ABI v1 | Filename/string grammar and privileged storage services must remain resident; an external wrapper does not remove the expensive machinery |
| `FILL$` or other numeric/string functions | Unsupported | The gateway hooks statement dispatch only; functions require evaluator result and type contracts plus matching checker hooks |
| Multidimensional arrays | Not a module candidate | Changes core DIM syntax, descriptors, indexing, allocator behavior, and program data lifetime |
| Sprites | Poor for the current gateway | Roughly 1 KB of EXROM logic exceeds the 512-byte window and relies on persistent slots, display lifecycle, and deeper services |
| `SOUND` | Technically possible, low value | The resident sound body is already very small and sound is a desired base feature, so little ROM would be recovered |

### Maintained external-keyword roadmap

New optional statement keywords should be implemented as loadable modules by
default. Adding another resident keyword is justified only when it is a core
language facility or cannot be implemented safely through a stable extension
ABI. This is the current implementation order:

1. **`FRAME x0,y0 TO x1,y1` — complete.** The 212-byte module draws a
   rectangular outline using grammar 1 and existing attribute/OVER/pixel
   services. It adds no production ROM or ABI bytes. Tests cover reversed
   corners, empty interiors, all four edges, OVER-twice restoration, unloaded
   rejection, and `NEW` clearing.
2. **`INVERT x0,y0 TO x1,y1` — implemented.** It XORs every pixel in the
   inclusive rectangular region using grammar 1 and the existing pixel
   service with OVER enabled. Its fixtures cover reversed corners, applying
   it twice to restore the bitmap, unloaded rejection, and `NEW` clearing.
3. **`AYREG register,value` — complete.** The 53-byte grammar-0 module writes
   native AY register 0-15 and data 0-255 directly through ports `$F5/$F6`.
   Both full 16-bit arguments are validated before either port is touched. It
   adds no production ROM/ABI bytes; fixtures cover both range boundaries,
   invalid register/data, unloaded rejection, and `NEW` clearing.
4. **`ELLIPSE x0,y0 TO x1,y1`** — draw an ellipse bounded by two corners.
   Reuse grammar 1 and the pixel services. Build and measure the integer
   rasterizer before accepting it; it must fit wholly within 512 bytes.
5. **`OUT port,value`** — perform low-level Z80 output using grammar 0. This is
   a useful traditional programming facility and needs no ROM callback, but it
   is intentionally advanced: arbitrary ports can alter paging, display mode,
   interrupts, or attached hardware. Test benign ports and document unsafe
   TS2068 paging/control ports rather than pretending the operation is safe.
6. **`UDG character,address`** — install one eight-byte character bitmap from
   RAM using grammar 0. First define a stable destination/renderer contract;
   do not compile a movable internal font/sysvar address into the module. Add a
   narrow ABI service only if the operation cannot remain position-independent
   without it, and measure the resident cost before accepting that service.
7. **`HELP`** — package help text/display as an optional module after ROM
   recovery. It requires a no-argument grammar and stable text/screen/key
   services, so it follows all modules that work with ABI v1 unchanged.

### Measured next-candidate gate

The candidates after AYREG were re-measured against the current ABI and
19-Home/2-EXROM-byte production budget:

| Candidate | Measured result | Decision |
|---|---:|---|
| `ELLIPSE x0,y0 TO x1,y1` | The resident circle rasterizer and its plotting helpers occupy 368 bytes (`$37B5-$3924`). A module gets 512 bytes total and needs roughly 30 bytes for installation/name before its own wider two-radius arithmetic | Still plausible with grammar 1 and the pixel service, but tight. Require a complete assembler-built midpoint-ellipse spike; do not promise it from a surface estimate |
| `OUT port,value` | A complete position-independent grammar-0 spike assembles to 39 RAM bytes, including 16-bit port and 8-bit data validation | Strong next implementation after ELLIPSE; zero resident/ABI cost. Hardware-risk documentation and benign-port tests are mandatory |
| `UDG character,address` | The smallest safe resident copy service is 23 Home bytes; its callable ABI veneer adds 3 more, for at least 26 Home bytes plus 3 fixed RAM bytes before the module itself | Does not fit the zero-resident-ROM rule or the 19-byte Home margin. Defer; direct `POKE` remains available |

These numbers deliberately distinguish a complete module spike (`OUT`), a
measured existing-algorithm bound (`ELLIPSE`), and a measured minimum resident
dependency (`UDG`). Only the first is implementation-ready today.

For every roadmap module, “complete” means more than assembling: it needs an
installed-use fixture, unloaded rejection, `NEW`/ordinary-LOAD clearing,
argument-boundary coverage, a window-size assertion, and a tape-load or
round-trip test through the production extension path. `OUT`, `AYREG`, and
`UDG` additionally require explicit hardware/memory side-effect tests.

### Deferred and rejected feature register

The roadmap must preserve measured negative decisions as well as planned work.
The production images currently have only 19 Home-ROM bytes and 2 EXROM bytes
free; these are separate banks and cannot be combined. The following features
are therefore not in the active implementation queue:

| Feature | Status | Reason or measured result | Reconsider when |
|---|---|---|---|
| `VERIFY` | Rejected for current product | The prototype required about 45 Home + 145 EXROM bytes even with its visible keyword behavior externalized; too much permanent support for an infrequently used operation | Storage/parser infrastructure changes enough to make a new measured spike materially smaller |
| `COS`, `TAN`, `EXP`, `LN`, `LOG10` | Blocked by ABI and budget | ABI v1 dispatches statements only; a function hook, typed result contract, checker path, and calculator services would all consume resident ROM | A separately budgeted numeric-function gateway is justified; start with `COS` |
| `FILL$` and other string functions | Blocked by ABI and budget | Requires expression dispatch plus string ownership/lifetime rules, not the statement gateway | A separately designed string-function ABI exists with measured resident cost |
| `SAVE`/`LOAD ... CODE` | Deferred for ROM budget | Estimated around 180-300 Home + 80-150 EXROM bytes; most work is privileged resident storage parsing and validation, not module payload | Substantial measured recovery in both banks or a storage-overlay redesign |
| `SCREEN$` storage shorthand | Dependency-blocked | Small only after the underlying CODE-storage machinery exists | `CODE` storage is implemented and measured headroom remains |
| Typed numeric/string-array `DATA` | Deferred for ROM budget | Estimated around 300-550 resident bytes and requires interpreter/data-lifetime integration | A major bank recovery or architectural overlay phase |
| `CAT` | Deferred and unspecified | Likely more than 200 bytes; tape traversal, presentation, and transport semantics are not yet fixed | Semantics are written first and a scratch build proves a fit |
| Printer output (`COPY`, `LPRINT`, `LLIST`) | Blocked by ABI and hardware contract | ABI v1 has no no-argument/text/list grammar, printer transport, bitmap streaming, or program-listing services. Reimplementing PRINT/LIST inside each module would freeze movable internals into tape binaries | Define the supported printer hardware and a stable output ABI; prove `COPY` first, then share text output with `LPRINT` and listing with `LLIST` |
| Multidimensional numeric arrays | Core architectural work | Changes DIM grammar, descriptors, indexing, allocation, and persistent program data; it is not a detachable statement module | Adequate resident budget and a dedicated allocator/evaluator phase |
| Sprites as a module | Rejected under ABI v1 | Existing subsystem is about 1 KB of EXROM, exceeds the 512-byte module window, and owns persistent display/lifecycle state | A larger overlay architecture is deliberately designed |
| Resident `HELP` | Superseded by external plan | Keeping HELP resident would spend scarce base-ROM space on optional text | The external `HELP` roadmap item gains its required grammar/services |

“Deferred” does not mean silently abandoned: retain the measurements and
dependencies, but do not begin implementation until the stated reconsideration
condition is met. “Rejected” means do not retry the same architecture without
new evidence that changes its cost or value.

`DEF FN`, `INSTR`, prompted `INPUT`, and `SAVE ... LINE` autorun are already
resident features. They should not be moved merely because the extension
gateway exists: they are language fundamentals or require deep evaluator and
storage integration.

### Missing math functions

The previously planned but unimplemented math functions are `COS`, `TAN`,
`EXP`, `LN`, and `LOG10`. They cannot be modules under ABI v1 because they are
expression functions rather than statements. More importantly, the current
integer variable/expression model truncates a special float result as soon as
it participates in a composed expression. Adding more transcendental names
without fixing that limitation would create impressive demonstrations but
little general mathematical value. A future numeric-function gateway is
therefore subordinate to either a real floating datatype or an explicitly
composable float-result ABI. It would also need a resident evaluator hook,
numeric argument-count descriptor, checker parity, and stable calculator
services.

After that numeric representation is designed and budgeted, evaluate the
functions in this order:

1. `COS(x)` is the strongest first proof. For degree input it can reuse the
   existing sine implementation through `COS(x) = SIN(90-x)`, so its module
   body and new mathematical risk should be small.
2. `TAN(x)` can derive from sine and cosine, but needs a documented result and
   error policy near 90-degree singularities and genuine floating division.
3. `EXP(x)` needs a new approximation and overflow/range behavior.
4. `LN(x)` needs a new approximation plus a domain error for `x<=0`.
5. `LOG10(x)` should reuse `LN(x)` once that implementation and its domain
   behavior are proven, rather than carry a second independent logarithm.

Inverse trigonometric functions (`ASN`, `ACS`, and `ATN`) are familiar Sinclair
BASIC functions but were not in the project's previously selected math list.
They should remain later candidates, after the numeric-function ABI and the
smaller `COS` proof are measured.

With the current production budget at only a few EXROM bytes, even a tiny new
grammar or service cannot be added safely today. `HELP` is therefore a design
candidate, not the next immediate implementation. First recover measured ROM
headroom; then build the smallest no-argument/service-table spike and judge it
from actual assembled deltas.

## Deliberate limitations and future directions

- One module is installed at a time.
- The module window is fixed at 512 bytes.
- Only statement keywords are intercepted.
- Only grammar descriptors 0 and 1 are supported.
- ABI v1 exposes registration and three graphics-oriented services.
- Modules cannot safely call arbitrary ROM labels or read movable sysvars.
- There is no custom checker callback and no module code runs during editing.

A future function gateway, larger overlay, or multi-module registry should be
treated as a new architecture phase. It needs independent ROM/RAM accounting,
typed return-value and string-lifetime rules, static-checker parity, lifecycle
tests, and a versioning story; it should not be grown implicitly out of the
small v1 statement gateway.

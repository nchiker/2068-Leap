# R10.7 — array/data architecture audit (pre-capacity-decision)

Date: 2026-09-28. Read-only. No capacity was changed and no array
redesign was implemented — this document is the requested evidence base
for the R10.7 capacity decision, referenced from `docs/v2/R10_7_
CAPABILITY_RESTORATION.md`. All figures below are read directly from
current source (`rom/exrom_v2_compiler.asm`, `rom/exrom_v2_vm_core.asm`,
`include/sysvars.inc`), not estimated, except where explicitly marked
`ESTIMATE`.

## 1. Current numeric arrays

**Descriptor format**: there is no per-array runtime descriptor at all.
Arrays are a **compile-time symbol table entry + a fixed, pre-allocated
runtime data pool**, not a dynamically-sized/dynamically-addressed
object:

- Compile-time symbol (`ARRSYMTAB_BASE`, `rom/exrom_v2_compiler.asm`):
  `[name_len:1][name:8][size:1]` = **10 bytes/entry** (`ARRSYM_REC_LEN`),
  looked up linearly by `ARRSYM_LOOKUP`/created by `ARRSYM_FIND_OR_
  CREATE`. The `size` byte is the only thing DIM actually records — an
  array's *identity* at compile time is purely "which fixed slot index
  did this name get assigned", not an address or a length in bytes.
- Runtime data (`ARRTAB_BASE = $B460`, `rom/exrom_v2_vm_core.asm`): one
  contiguous pool, `ARRAY_MAX_COUNT`(4) × `ARRAY_MAX_ELEMS`(16) × 2
  bytes = **exactly 128 bytes, always fully reserved regardless of any
  array's own DIM'd size**. `OP_ARR_LOAD`/`OP_ARR_STORE`'s own compiled
  operand is `[array_slot:1][declared_size:1]` — the declared size
  travels with every bytecode access (baked in at compile time) purely
  for the bounds check; it does not change how much pool space that
  array actually occupies (always the full 16-element slot).

**Allocation mechanism**: none, in the dynamic-allocator sense. `DIM
name(size)` only (a) validates `1 ≤ size ≤ 16` (`ARRAY_MAX_ELEMS`) at
compile time and (b) claims the next free ARRSYMTAB slot (of 4 total).
The corresponding 32-byte ARRTAB region for that array-symbol-table
index is **always already reserved**, whether or not `DIM` ever runs —
runtime `DIM` in this dialect does no runtime allocation work at all
(consistent with V2's whole "resolve everything possible at compile
time" philosophy, per this code's own comment).

**Indexing mechanism**: `VM_ARR_ADDR` — `HL = ARRTAB_BASE +
(array_slot*16 + element_index)*2`, computed via four `add hl,hl`
doublings (a cheap shift, not `MATH_MULTIPLY16`) **because 16 is a
power of 2** — the compiler's own comment states this explicitly
("so the slot*ARRAY_MAX_ELEMS multiply below is four shifts, not a
real multiply"). This is a real constraint on any future
`ARRAY_MAX_ELEMS` choice (see item 7).

**Practical maximum size**: **16 elements per array** (hard compile-time
ceiling, error 36 "DIM size exceeds ARRAY_MAX_ELEMS" if exceeded), **4
arrays total** (`ARRAY_MAX_COUNT`/`ARRSYMTAB_MAX_ENTRIES`, both must
agree). This is dramatically smaller than "whatever free RAM allows" —
it is a small, fixed, always-fully-reserved 128-byte pool, independent
of the 48K machine's real available RAM. (The RAM-budget note in
`include/sysvars.inc` describing `ARRAYS_END`/`PROG_AREA_MAX` as a
dynamic two-ended pool describes the **program-text/scalar-variable**
pool, not the array *data* pool — a real, easy-to-conflate distinction;
`ARRAYS_END` tracks where the *program/scalar* region's own high-water
mark sits, not `ARRTAB`'s own fixed, separate 128-byte block.)

**How much of the implementation assumes 1-D**: completely, at every
layer:

- Grammar: `COMPILE_DIM`'s own literal token sequence is `DIM IDENT (
  NUMBER )` — there is no branch point for a comma-then-second-size at
  all (unlike the archived V1 2-D work, which added exactly that
  branch to `DIM`'s own grammar). Adding a 2nd dimension requires new
  grammar, not a flag flip.
- Symbol table: `ARRSYM_REC_LEN`'s `size:1` field has room for exactly
  one dimension; a 2-D array needs at minimum `rows:1][cols:1]` (or a
  combined check against `ARRAY_MAX_ELEMS` for the product), a real
  record-format change.
- Runtime addressing: `VM_ARR_ADDR`'s shift-based `slot*16+index`
  formula has no row/col decomposition at all; 2-D addressing needs
  `row*cols+col` (a real multiply, `MATH_MULTIPLY16` — no shift
  shortcut once `cols` is a runtime, not compile-time-power-of-2,
  value) — the exact same real-multiply cost the archived V1 2-D work
  already measured and hit its own budget wall on.
- Bytecode operand shape: `OP_ARR_LOAD`/`STORE`'s 2-byte operand
  (`[slot][size]`) has no room for a second declared-size byte without
  either growing the operand (cost per *call site*, i.e. per array
  access in the compiled program, not a one-time cost) or moving the
  second size to a runtime-looked-up table (reintroducing exactly the
  per-access indirection this whole design was built to avoid).
- The one dimension-agnostic piece already in the tree: `DIMN(name)`
  (see item 2) — but only because it was simplified back down to
  single-argument specifically *because* 2-D was archived.

## 2. DIMN

**Confirmed present and fully functional in current production V2** —
not lost, not disconnected. `rom/exrom_v2_compiler.asm`'s `COMPILE_
DIMN` (compiler-resident; `rom/exrom_arrays.asm`'s `ARRAY_EXROM_DIMN`
is V1's own EXROM-resident equivalent, a *different, parallel*
implementation for the *old* BASIC dialect — not what V2 programs
reach).

**Exact semantics**: `DIMN(name)` — one argument, a bare array
identifier (not an expression) — **compiles to a bare `PUSH_I8`
literal of that array's own DIM'd size, with zero runtime opcode at
all**. It is resolved entirely at compile time by looking up `name` in
`ARRSYMTAB` and reading its stored `size` byte. This means:

- `FOR I=0 TO DIMN(A)-1` compiles identically to `FOR I=0 TO 15` (if
  `A` was `DIM`'d to 16) — genuinely free at runtime, a real, useful,
  already-working convenience for writing DIM-size-independent loop
  bounds without hardcoding the literal.
- Relevance: **directly about array dimensions/size**, not some other
  purpose — it exists purely to let code reference an already-declared
  array's own bound without repeating the literal.
- Documented, deliberate limitation (not a bug): because it compiles to
  a bare literal, `DIMN(A)` **decompiles back as the plain integer**,
  not as `DIMN(A)` — the origin is not preserved through decompile.
  `rom/test_v2_arrays.asm`'s own header documents this explicitly as
  intentional.

**What was lost during R9/R10**: only the **2-argument form**,
`DIMN(name, dim)` (asking for a specific dimension's size), which only
ever existed because 2-D arrays existed — it was archived *together
with* 2-D `DIM` on 2026-08-22 (`include/sysvars.inc`'s own comment,
`docs/programmers_reference.md`'s "Multi-dimensional arrays (archived)"
section), well before R9/R10, and for the V1 dialect specifically
(`basic/basic.asm`'s own `KW_FN_DIMN`/`BASIC_ARRAY_DIMN_EXROM`) — V2's
own `DIMN` was *built* single-argument from the start (it's a
post-R9-cutover, V2-native construct, `rom/exrom_v2_compiler.asm`'s own
"R8.5 Group 6" comment), so nothing V2-specific was disconnected. R9/R10
themselves did not touch `DIMN` at all.

## 3. Multidimensional numeric arrays

**What 2-D would require** (concrete, not hypothetical — this exact
work was already done once, for V1, and its real measured cost is on
record):

- New `DIM` grammar: an optional `,<size2>` after the first size,
  switching the DIM to 2-D (V1's own approach — direct precedent).
- A widened array-symbol record: `[name_len:1][name:8][rows:1][cols:1]`
  (11 bytes/entry instead of 10 — `ARRSYMTAB`'s own total grows by
  `ARRSYMTAB_MAX_ENTRIES` bytes, 4 currently) plus a `kind` byte if 1-D
  and 2-D must coexist (V1's own `[kind][...]` variable-header approach)
  — or, cheaper for V2 specifically: **always store 2 dimension bytes,
  with the 2nd defaulting to 1** (a 1-D array becomes "N×1"), avoiding
  a variable-length record and a kind-branch at every access site, at
  the cost of 1 extra byte/entry even for 1-D arrays (4 bytes total at
  the current 4-array cap — negligible).
- Widened bytecode operand: `OP_ARR_LOAD`/`STORE` need `rows`/`cols` (or
  just `cols`, deriving `rows` from bounds-checking the flat index) at
  the call site, or a runtime table lookup by slot instead of the
  current "declared size baked into the operand" shape — a real
  operand-format change touching every array-access compile site.
- New/widened addressing: `row*cols+col` needs `MATH_MULTIPLY16` (a
  real multiply, ~10-15 T-states-class routine already in `kernel/
  math/math.asm`, reusable, not new) in place of `VM_ARR_ADDR`'s
  current 4-shift power-of-2 trick — **this alone is not what killed
  the V1 attempt** (the multiply itself is cheap and already exists);
  the V1 archival note is explicit that `DIM`'s own 2-D-aware *body*
  (grammar/validation/symbol-table code), not the read/write address
  math, was the actual budget-buster.
- New/widened grammar for reads: `A(row,col)` needs `COMPILE_FACTOR`'s
  array-read path and `COMPILE_ARRAY_ASSIGN` to each parse a
  comma-continued subscript list instead of one expression — real new
  parsing code at both of V2's two array-access sites (mirroring V1's
  own new shared `BASIC_ARRAY_PARSE_SUBSCRIPTS`/`ELEMENT_ADDR`
  routines).

**Is a general N-dimensional descriptor practical?** **Not recommended
for this dialect.** The real V1 experience (fully built, verified
working, then archived) is direct, on-the-record evidence: even
**2-D alone** pushed either bank over budget by ~26-69 bytes after real
optimization effort, in a codebase whose overall shape (fixed-slot
symbol tables, compile-time-resolved everything) is the same
architectural family V2 inherited. A fully general N-D descriptor
(variable dimension count, `Π dim_i` product ahead-of-time bounds
math, N-deep nested-loop address computation) is a materially bigger
version of the same thing that already didn't clear the bar at 2-D —
there is no evidence a general form would cost *less*, and every
reason (more grammar, more validation branches, a genuinely variable-
length descriptor) to expect it costs *more*. **2-D specifically**, if
ever revived, is the ceiling worth considering, not N-D.

**Estimated HOME/EXROM/RAM cost** (`ESTIMATE`, grounded in the V1
figures above, adjusted for V2's already-more-compact table-driven
compiler style — R10.5's own shrink pass already found and removed
V2's easy duplication wins, so there is less "free" consolidation
headroom left to offset new-feature cost than V1 had): **60-120 bytes**
combined HOME+EXROM for grammar+validation+addressing, in the same
order of magnitude as V1's own ~26-69-byte-over-budget measurement
before optimization, **not free at V2's current 899-byte HOME / 2,194-
byte EXROM reserve without a dedicated shrink pass first** if bundled
with the other R10.7 capacity increases below. RAM cost: +4 bytes
`ARRSYMTAB` (the always-2-dimension-bytes approach above) + whatever
the runtime `ARRTAB` pool itself needs if array *count* or *elements*
also grow (independent of 2-D itself — see item 7).

**Can existing syntax/structures extend cleanly?** Partially. `DIM`'s
grammar extends cleanly (one optional comma branch, direct V1
precedent). The bytecode operand and addressing do **not** extend
as cleanly — `OP_ARR_LOAD`/`STORE`'s current 2-byte "slot+declared-
size" operand shape was specifically designed around 1-D's own single
bound; 2-D genuinely needs either a wider operand or a runtime table
lookup, a real (if bounded) redesign of that one opcode pair, not an
additive change.

## 4. String arrays

**Current state**: do not exist at all, deliberately out of V2's scope
from the start (`rom/exrom_v2_compiler.asm`'s own "R8.5 Group 4" header:
"Arrays are integer-only... string arrays are not part of this group's
scope"). Nothing to restore — this would be new capability, not
recovery.

**How `DIM A$(n)` could fit the existing systems**: the *symbol-table*
half fits cleanly — a second `ARRSYMTAB`-shaped table (or a `kind` bit
added to the existing one) keyed the same way, resolving to a `STRTAB`-
shaped runtime pool instead of `ARRTAB`. The *runtime* half is where
the real design decision is:

- **Fixed-width-per-element** (mirrors `STRTAB`'s own existing 32-byte
  `[len:1][content:31]` record exactly): simplest, reuses `VM_STR_ADDR`'s
  own addressing shape almost verbatim (index arithmetic identical to
  `VM_ARR_ADDR`, just ×32 instead of ×2), and reuses every existing
  string primitive (`LEFT$`/`RIGHT$`/`MID$`/concatenation/comparison)
  unchanged once a string-array element resolves to a real `STRTAB`-
  shaped address. **But** RAM cost is severe: even a *4-element* string
  array at the existing 31-byte cap is **128 bytes for ONE array** —
  more than numeric `ARRTAB`'s entire current 128-byte pool for *all
  four* numeric arrays combined. At the R10.7-proposed 63-byte string
  length (item 7), one 4-element string array alone is **256 bytes**.
  This is the "would waste unacceptable RAM" case the user's own
  framing anticipates, and the audit confirms it: **fixed-31/63-byte
  slots applied uniformly to every array element is not practical**
  at any array-count/element-count combination worth having.
- **Variable-length / packed storage** (a real string-heap: elements
  stored back-to-back, `[len:1][content:len]` each, with a runtime
  offset table per array): the RAM-efficient answer, but a genuinely
  new subsystem — V2 currently has **zero** variable-length string
  storage anywhere (every existing string slot, named or temp, is the
  same fixed 32-byte record) — this is not an extension of an existing
  mechanism, it is new heap-management code (allocate, and — the hard
  part — either accept a *write-once* array (no reassignment once
  DIM'd content is set) to dodge fragmentation/compaction entirely, or
  take on real compaction logic). Given V2's own repeated "avoid
  inventing a general allocator" discipline (stated explicitly in the
  `STRTAB_TEMP_COUNT` comment already cited above), a full heap
  allocator is a poor fit for this codebase's own established taste.
- **Recommended middle ground** (not built, a design proposal only):
  a **smaller fixed per-element width dedicated to array use**,
  independent of the scalar `STRTAB`'s own 31/63-byte cap — e.g. an
  8- or 16-byte-per-element string array record. This keeps the cheap,
  proven fixed-slot addressing shape (no new allocator) while making
  the RAM cost tolerate a *useful* element count: an 8-element array of
  16-byte strings is 128 bytes (comparable to numeric `ARRTAB`'s
  current whole-pool size), not 512+. The real product tradeoff this
  creates — array-string elements capped shorter than scalar strings —
  is exactly the kind of explicit, informed choice this audit exists to
  surface, not to make.

**Estimated cost** (`ESTIMATE`): grammar/symbol-table reuse of the
numeric-array pattern is cheap (~40-60 bytes compiler-side, mirroring
`COMPILE_DIM`/`ARRSYM_FIND_OR_CREATE`'s own size); a new fixed-width
string-array runtime pool costs **pool_size = array_count ×
elements_per_array × element_width** in RAM (e.g. 4 arrays × 8 elements
× 16 bytes = 512 bytes — a real, deliberate RAM commitment, not free)
plus a new `VM_STRARR_ADDR`-equivalent (a close cousin of `VM_ARR_ADDR`,
~15-20 bytes) and load/store opcodes or an `EXT2`-style dispatch
reusing the existing string-copy primitives `LEFT$`/`MID$` already
established.

**Multidimensional string arrays**: explicitly **not recommended**
combined with the above — 2-D numeric arrays alone already don't clear
V2's own cost bar (item 3); stacking 2-D addressing on top of a *new*
string-array subsystem in the same milestone substantially compounds
both the design risk and the ROM cost for a use case (a genuinely
common one is a simple 1-D list of names/labels) that 1-D string
arrays already serve. If 1-D string arrays prove valuable in practice,
revisit 2-D for *both* facilities together later, informed by real
usage rather than speculatively building it now.

## 5. Array persistence (SAVE/LOAD)

**Design proposal** (not implemented): V2's existing storage layer
already has exactly the extensibility point this needs — `V2_LOAD`
already branches on `V2_REQUEST_TYPE` (0 = program, 1 = extension
package, each with a different post-load validation/install path,
`rom/exrom_v2_shell.asm`) and the wire header already carries a 2-byte
field at `STORAGE_HEADER_AUTOSTART_OFF` presently repurposed as the
package's own ABI-version check (`V2_PACKAGE_ABI_VERSION`). Array
SAVE/LOAD fits this exact pattern as a **third request type**, reusing
essentially all of it:

- **Proposed BASIC syntax**: `SAVE "name" ARRAY A` / `LOAD "name" ARRAY
  A` (or, cheaper to parse, reusing the existing `V2_REQUEST_TYPE`
  dispatch verbatim: a third shell-command keyword, `SAVEARRAY`/
  `LOADARRAY`, avoiding new grammar inside `SAVE`/`LOAD`'s own already-
  working name-parsing path entirely — recommended, since it needs
  zero changes to `V2_PARSE_NAME`/the existing `SAVE`/`LOAD` dispatch
  clauses, only a new sibling clause next to them).
- **Tape block metadata/type**: reuse the real header block byte-for-
  byte (`STORAGE_TYPE_HEADER`, `STORAGE_HEADER_BUF`'s existing 17-byte
  layout) unchanged; repurpose `STORAGE_HEADER_AUTOSTART_OFF`'s 2 bytes
  as `[kind:1][dim_count:1]` (kind: 0=numeric, 1=string, once string
  arrays exist; dim_count: 1 today, room for 2 if item 3 is ever built)
  instead of the package ABI-version value packages use there — the
  SAME field, disambiguated by `V2_REQUEST_TYPE` the same way program
  vs. package loads already are.
- **Array name/type/dimensions**: the array's *name* already has a
  natural home in the existing 10-byte filename field (`STORAGE_
  HEADER_NAME_OFF`, `STORAGE_HEADER_FILENAME_LEN`=10) — reuse it
  directly for the array's own BASIC name (padded, exactly like a
  program filename already is), rather than inventing a second name
  field; `LOAD ... ARRAY` can validate the loaded block's own name
  field against the target array symbol before accepting data, a real
  extra safety check beyond what program LOAD does today.
- **Element representation**: numeric — the *exact* existing `ARRTAB`
  on-disk shape, `[element:2]` × declared size, byte-identical to the
  live in-RAM record (no transform needed, matching `STORAGE_SAVE`'s
  own existing "write RAM verbatim" convention for programs). String
  (once they exist) — whichever fixed-width record item 4 lands on,
  same "write the live RAM shape verbatim" principle.
- **Bounds/size validation**: `STORAGE_HEADER_LENGTH_OFF`'s existing
  2-byte length field already carries the payload's real byte count —
  `LOAD ... ARRAY`'s own receive path checks it against the *target*
  array's own currently-`DIM`'d size × element width (not the source
  array's original size) before accepting, exactly mirroring `V2_LOAD`'s
  own existing "caller's max allowed length" bound (`STORAGE_MAX_LEN`)
  — a length mismatch is a clean, already-idiomatic failure mode
  (`LOAD FAILED`), not a new error class.
- **Replacement/error behavior when loading**: **require the target
  array to already exist with a matching declared size** (the array
  must have been `DIM`'d in the current program first, same "you own
  your own memory layout" contract V2's array `DIM` already has for
  everything else) — reject with a real, distinct error (e.g. "ARRAY
  NOT DIM'D" / "ARRAY SIZE MISMATCH") rather than silently auto-`DIM`ing
  from the tape's own recorded size, which would let a loaded file
  quietly change a running program's own memory layout. This also
  sidesteps ever needing to grow `ARRTAB`/`ARRSYMTAB` from a LOAD.
- **Checksum/error handling**: **entirely free** — `STORAGE_RECEIVE_
  BLOCK`'s real trailing-checksum verification and the whole retry/
  timeout/SPACE-abort machinery apply unchanged; array LOAD is just a
  different consumer of the same primitive, identical to how VERIFY
  (this milestone's own item 1) reused it with zero new checksum code.
- **Reuse of existing infrastructure**: **very high** — `STORAGE_SAVE`/
  `STORAGE_LOAD`, the header block format, the checksum/retry
  machinery, and even `V2_LOAD`'s own request-type-branching shell
  glue are all reused as-is; genuinely new code is limited to (a) the
  `SAVEARRAY`/`LOADARRAY` keyword-dispatch stub in `rom/exrom_v2_
  shell.asm` (small, same shape as `V2_VERIFY`'s own thin wrapper, this
  milestone's own item 1 precedent) and (b) the target-array
  size/kind validation described above.

**Estimated resident ROM cost** (`ESTIMATE`, grounded directly in this
milestone's own measured VERIFY cost — a very close structural analogue,
same "new shell command reusing the storage layer" shape): **80-150
bytes EXROM**, no HOME cost (the array-save/load shell commands belong
in `exrom_v2_shell.asm`, same as `SAVE`/`LOAD`/`VERIFY`).

## 6. Relationship to DATA/READ/RESTORE

**Do stronger arrays + array persistence substantially reduce the
practical need for DATA/READ/RESTORE?** For the single largest real-
world use of `DATA` — loading a fixed table of numbers/strings a
program needs at every run (lookup tables, initial game state, a small
dataset) — **yes, substantially**. `DIM`+assignment loops plus array
`SAVE`/`LOAD` (item 5) cover "get a block of known data into a running
program" at least as well as `DATA`/`READ` does, without needing a new
compiler pass or new VM cursor state at all (this milestone's own
R10.25 finding: `DATA`/`READ`/`RESTORE` is "the largest single deferred
item... new compile-time literal-indexing pass + new VM runtime cursor
state, never built in either dialect" — none of that goes away, but
fewer programs would *need* it).

**What DATA/READ/RESTORE would still uniquely provide**:

- **Data embedded directly in program source**, portable as one
  self-contained listing with no separate tape file to keep alongside
  it — the single biggest gap arrays+array-files leave open. A program
  distributed as one `LIST`able/typeable source file (the common case
  for a hobbyist BASIC program shared as text, not tape) cannot carry
  array-file data with it at all; `DATA` lines can.
- **`RESTORE`'s re-read capability** — reading the same embedded data
  multiple times from different starting points (e.g. re-initializing
  state without re-running the whole program, or reading two different
  interleaved data streams by restoring to different line numbers) has
  no arrays-alone equivalent; an array, once loaded, is just current
  RAM state — there is no "rewind and re-interpret the same literal
  text differently" facility arrays provide.
- **Working with more DATA than fits any one array's own capacity**
  — even after any of item 7's proposed capacity increases, arrays
  remain small, fixed pools; `DATA`/`READ` has no equivalent per-array
  ceiling (it is source-text-length-bound instead, a very different
  and typically much larger limit).
- **Declaring data without committing to array shape at compile time**
  — a program that reads a variable amount of `DATA` (stopping at a
  sentinel, or reading until `RESTORE`) doesn't need to know its own
  data's size up front; every array in this dialect (numeric or
  proposed string) requires a compile-time-literal size in `DIM`.

**Conclusion**: arrays + array persistence meaningfully shrink DATA/
READ/RESTORE's practical necessity for the "known fixed dataset" case,
but do not replace it for source-embedded, RESTORE-scoped, or
size-unknown-at-compile-time data. `DATA`/`READ`/`RESTORE` remains a
real, distinct capability gap — this audit does not recommend treating
arrays as a substitute for it, only as a genuinely strong alternative
for the specific "known data, tape-file-shaped" case.

## 7. Capacity decisions (recommendation only — nothing changed)

**Array count (4→8)**: **do not simply double the count under the
current architecture without also reconsidering elements-per-array.**
8 arrays × the current 16-element cap is still only 256 bytes RAM
(cheap), but doubles `ARRSYMTAB` too (4→8 entries × 10 bytes = 40→80
bytes) — inexpensive either way. The real question this audit surfaces
is whether **16 elements/array** is the more binding practical
ceiling than **4 arrays** — a program needing "an array of scores for
10 players" already can't, regardless of how many *separate* 16-slot
arrays it's allowed. **Recommendation**: if capacity work proceeds,
weight it toward **elements-per-array** over raw array *count* — e.g.
2 arrays × 32 elements uses the same RAM (128 bytes) as 4×16 but likely
serves more real programs; or, if RAM allows, increase both moderately
(e.g. 6 arrays × 32 elements = 384 bytes, up from 128) rather than only
the array-count axis originally proposed. `ARRAY_MAX_ELEMS` must stay a
power of 2 for the existing shift-based addressing to remain cheap (32
or 64 are the natural next steps, not e.g. 24 or 20).

**32 numeric scalars / 8 string variables / 63-character strings /
recursion depth 12** — assessed independently of the array question,
since none of the four shares a structure with arrays:

- **32 numeric scalars** (`CSYMTAB_MAX_ENTRIES` 16→32): mechanical,
  +144 bytes RAM (16 more × 9-byte records), no addressing-shape
  constraint (linear-scan lookup, not shift-indexed) — **still
  sensible**, no new finding changes this.
- **8 string variables** (`STRSYMTAB_MAX_ENTRIES`/`STRTAB_MAX_VARS`
  4→8): mechanical, +36 bytes compile-time symbol RAM + 4×32=128 bytes
  `STRTAB` value RAM (at the *current* 31-byte length) — **still
  sensible**; note this is a *different* pool from any future string-
  *array* pool (item 4) — the two should not be conflated when sizing
  RAM.
- **63-character strings** (`STR_REC_LEN` 32→64 bytes, content 31→63):
  doubles `STRTAB`'s total footprint at whatever variable count is
  chosen (e.g. at 8 variables: 8×64=512 bytes, vs. 8×32=256 today) —
  **still sensible as a per-variable cap**, but worth sizing *after*
  deciding the string-*variable* count above, since the two multiply
  together, not add.
- **Recursion depth 12** (`VM_PARAM_NEST_MAX`/`VM_CALL_STACK` 6→12):
  mechanical, +12 bytes (2 bytes/slot) — **still sensible**, genuinely
  cheap, and this milestone's own limit audit already flagged 6 as
  plausibly too shallow for real recursive PROC use.

None of these four is entangled with the array-architecture questions
above; all four remain sensible on their own terms and are cheap
relative to any of the array proposals in items 3-5.

## Summary table — cost ordering for the pending capacity decision

| Change | RAM cost | ROM cost | Architectural risk |
|---|---:|---:|---|
| Scalars 16→32 | +144 B | ~0 | none |
| String vars 4→8 | +164 B | ~0 | none |
| String length 31→63 | +256 B (at 8 vars) | ~0 | none |
| Recursion 6→12 | +12 B | ~0 | none |
| Arrays: rebalance count×elements (e.g. 6×32) | +256 B | ~0 | none (same shift-addressing, still power-of-2) |
| Arrays: naive count-only 4→8 | +128 B | ~0 | none, but likely the less useful axis (see above) |
| 2-D numeric arrays | +4 B (ARRSYMTAB) + pool growth | 60-120 B `ESTIMATE` | real — V1's own direct precedent already went over budget once at this exact scope |
| String arrays (fixed narrow width) | 128-512 B `ESTIMATE`, width-dependent | ~60-100 B `ESTIMATE` | moderate — new pool/addressing, but same proven shape as numeric arrays |
| Array SAVE/LOAD | 0 | 80-150 B `ESTIMATE` (EXROM) | low — very high reuse of existing, already-hardened storage code |
| 2-D string arrays | — | — | **not recommended** this cycle (see item 4) |

---

# Part 2 — dynamic array architecture (design, not implemented)

Date: 2026-09-28. Explicitly requested as a design investigation before
finalizing V2's array capacity — the 6×32 fixed idea from Part 1's own
item 7 is **not authorized and not adopted**; this part evaluates
replacing the fixed-pool model entirely instead. Nothing below is
implemented. All addresses/sizes are read from current source.

## 0. The key enabling discovery

V2 already has real, correctly-initialized, currently-**unused**
plumbing for exactly this design, left over from an apparent earlier
intent that the shipped `DIM`/`ARRTAB` implementation never connected
to:

- `ARRAYS_END` (`include/sysvars.inc`) is set to `PROG_END` at cold
  boot (`kernel/memory/memory.asm`'s `MEM_INIT`) and reset to `PROG_END`
  by both `NEW` and `CLEAR` (`rom/exrom_v2_shell.asm`'s `MEM_INIT_V2`/
  `MEM_CLEAR_V2`, this milestone's own item-1 `CLEAR` addition) — **but
  is never advanced by anything else**. No current code ever moves it
  past `PROG_END`.
- `VARS_START` is set to `V2_SOURCE_END` ($9455) at the same three
  points — a **fixed ceiling**, chosen once and never revisited, that
  `MEM_FREE_BYTES` already subtracts `ARRAYS_END` from to compute
  `FREE()`.
- Both names, and the "two-ended pool" comment already in `include/
  sysvars.inc`, describe exactly a arrays-grow-up/scalars-grow-down
  arena design — but the actual scalar/array implementations that got
  built (`SYMTAB_BASE=$B700`, fixed `[tag:1][value:2]`×16; `ARRTAB_
  BASE=$B460`, fixed 128-byte pool) **never use `VARS_START`/`ARRAYS_
  END` at all**. They are dead weight for their apparent original
  purpose today, doing nothing but `FREE()` accounting.
- **The real address gap this exposes**: `V2_SOURCE_END` ($9455,
  `VARS_START`'s fixed value) to `V2_CODE_BASE` ($A455, where compiled
  bytecode begins) is **4,096 bytes, completely unclaimed by any
  current structure** — confirmed by grep across every `.asm`/`.inc`
  file (only test-only scratch constants like `$9600`/`$9800`/`$9900`
  live in this span, each test's own comment independently describing
  it as "real, unused RAM"). Below `V2_SOURCE_END`, whatever program
  text is DIM'd shorter than the full 4KB source ceiling leaves
  additional slack in the *same* span, since `ARRAYS_END` starts at
  the real `PROG_END` (the program's own actual length), not at the
  4KB ceiling.

**This is the arena a dynamic design should use** — genuinely idle
today, already reset correctly by `NEW`/`CLEAR`/cold-boot, and already
has the exact pointer pair (`ARRAYS_END` growing up, `VARS_START` as
ceiling) a bump allocator needs. No new sysvars are required to
establish the arena itself; only to make `DIM` actually use it.

## 1. Dynamic numeric arrays — proposed design

**Two-table split**, decoupling "how many arrays can be named" from
"how much data each one holds" (today's design conflates the two —
every named slot gets an identical, wasteful, fixed-size allocation):

1. **Compile-time symbol table** (`ARRSYMTAB`, already exists) — keeps
   its current shape almost unchanged: `[name_len:1][name:8]` per
   entry, mapping a name to a small integer *array index* (0..N-1).
   Since this table no longer needs to also predict runtime size, it
   can be sized generously and cheaply — entries cost ~9 bytes each,
   and the table itself is compile-time-only RAM (reusable/overwritable
   after `COMPILE_PROGRAM` finishes, same as today). Recommend raising
   `ARRSYMTAB_MAX_ENTRIES` from 4 to e.g. 16 essentially for free
   (+108 bytes compile-time RAM) — genuinely different from raising it
   under the *current* fixed-pool design, where every added entry also
   multiplies the *runtime* pool.
2. **Runtime array-pointer table** (new, small, fixed) — one 2-byte
   slot per possible array index (same count as `ARRSYMTAB`'s own max,
   e.g. 16 × 2 = 32 bytes, permanent RAM), each slot holding either 0
   ("not yet DIM'd this run") or the arena address of that array's own
   descriptor. This is the *only* fixed-size cost of the whole design.
3. **Arena descriptor** (new, variable-length, lives in the `ARRAYS_
   END..VARS_START` arena itself): `[dim_count:1][dim1:2]...[dimN:2]
   [data: Πdim_i × 2 bytes]`. Today, `dim_count` is always 1 — see item
   3 below for why the format is already shaped to add a second
   dimension cleanly later without changing the 1-D case's own byte
   layout.

**Allocation mechanism**: sequential/arena-only, exactly as requested
— no `free()`. A new VM opcode, `OP_DIM`, executed **at runtime** (a
real behavior change from today, where `DIM` does zero runtime work):

- Compiled operand: `[array_index:1][dim_count:1][dim1:2]` (today;
  `dim2` reserved, see item 3) — `DIM`'s sizes remain compile-time
  literals in this dialect (unchanged grammar), so the operand can
  still be fully resolved at compile time, exactly like today's
  `OP_ARR_LOAD`/`STORE` operand is.
- At runtime: compute `needed = 1 + dim_count*2 + Πdim_i*2`; check
  `ARRAYS_END + needed ≤ VARS_START`; if not, raise a new, clean error
  (`VM_ERR_ARRAY_SPACE`, next free error code) — **exactly** the
  "memory exhaustion produces a clean error" requirement, and a direct
  structural twin of `OP_DIV`'s own existing `VM_ERR_DIVIDE_BY_ZERO`
  guard-then-raise shape, no new error-reporting mechanism needed.
- On success: write the descriptor at the old `ARRAYS_END`, advance
  `ARRAYS_END` by `needed`, store the new descriptor address into the
  array-pointer table at `array_index`.
- Re-`DIM`ing the same name in the same run: reuse today's existing
  compile-time "already DIM'd" check (error 38, `ARRSYM_FIND_OR_
  CREATE`) — unchanged, `DIM` remains write-once per run at the
  language level even though allocation is now real.

**Indexing mechanism** (`OP_ARR_LOAD`/`STORE`, changed): one extra
indirection versus today — `HL = (array_ptr_table + index*2)` (the
array's real arena address, resolved via the pointer table above) `+ 1
+ dim_count*2` (skip the header) `+ element_index*2` (the fast-path 1-D
case; `dim_count>1` branches to a real multiply, see item 3). Bounds
still checked against the *declared* size, still baked into the
compiled operand exactly as today (no new runtime size lookup needed
for the 1-D case) — the only new runtime cost is the one pointer-table
read, a handful of extra T-states per array access, not a new
algorithmic class of cost.

**RUN/CLEAR/NEW interaction**: `NEW`/`CLEAR` already reset `ARRAYS_
END := PROG_END` (existing code, item-1 `CLEAR` addition this
milestone) — correct and sufficient, no change needed there. **New
requirement this design introduces**: re-`RUN`ning the *same* compiled
program a second time (without an intervening `NEW`/`CLEAR`) must also
reset `ARRAYS_END`, or a second `RUN`'s own `DIM` statements would
allocate *again* on top of the first run's now-stale arena, leaking 4KB
worth of space after only a few re-runs. `VM_INIT` (already called at
the start of every `RUN`) is the correct place — add the same one-line
`ld hl,(PROG_END) / ld (ARRAYS_END),hl` reset there. This is a small,
localized, well-understood change, not a redesign of `VM_INIT` itself.

**Where the arena lives / interaction with the rest of the RAM map**:
`ARRAYS_END..VARS_START` ($9455 fixed ceiling today), entirely below
`V2_CODE_BASE` ($A455) — **no interaction at all** with compiled
bytecode, `FLOATTAB` ($B400), the (unchanged) `STRTAB`/`SYMTAB`, or any
compiler table (`CSYMTAB`/`LABELTAB`/`FIXUPTAB`, all `$B9xx`-adjacent,
compile-time only). The arena's own ceiling is bounded by program-text
length via the existing `ARRAYS_END := PROG_END` start point, so a
larger program leaves proportionally less array headroom — an
intentional, already-designed-for tradeoff (the "two-ended pool"), not
a new coupling this design introduces. **Does not touch the
authoritative-source architecture**: the compiled program's own source
text (`PROG_AREA_START..PROG_END`) and the array arena
(`PROG_END..VARS_START`) remain the same two adjacent-but-distinct
regions the existing `MEM_INIT`/`MEM_COLD_INIT` code already
maintains; nothing about how source is authored, staged, or compiled
changes.

## 2. String arrays under this architecture

Fits cleanly, reusing every piece above — only the arena descriptor's
`kind` byte and per-element width differ:

- Descriptor: `[dim_count:1][dims...][kind:1][elem_width:1][data:
  Πdim_i × elem_width bytes]` (2 bytes more than the numeric shape).
- Element representation: **fixed-width, length-prefixed**, directly
  reusing `STRTAB`'s own existing record shape at a *caller-chosen*
  width instead of the scalar system's fixed 31/63 bytes — `[len:1]
  [content: elem_width-1 bytes]` per element. This avoids inventing a
  second string representation (every existing string primitive that
  already knows the `[len][content]` shape — `LEFT$`/`RIGHT$`/`MID$`/
  concatenation/comparison — extends to an array element unchanged,
  just at a different base address and stride) while making width a
  real, deliberate, per-array choice instead of a fixed global cost.
- **Proposed syntax**: `DIM A$(n, w)` — `w` = characters per element
  (the `[len:1][content:w-1]` slot is `w` bytes total). This is not
  invented for this project: **it is real, stock Sinclair BASIC
  syntax** (`DIM A$(n,w)` declares `n` strings of `w` characters each
  on a real Spectrum) — reusing it costs nothing new to design and
  gives natural, already-documented-elsewhere semantics. `DIM A$(n)`
  alone (no width) defaults to a small, deliberately modest width
  (e.g. 8 or 16 bytes/element — a product decision, not a technical
  one) rather than silently inheriting the scalar system's 31/63-byte
  cost.
- **RAM predictability**: exactly `n × w` bytes, chosen by the
  programmer at `DIM` time — no silent 31/63-byte tax per element
  regardless of what the program actually needs, directly answering
  the "do not automatically reserve 63 bytes for every element"
  requirement.
- **Indexing**: identical arena-pointer-table indirection as numeric
  arrays, with `elem_width` (not a fixed 2) as the per-element stride
  — one more byte read per access (`elem_width` from the descriptor)
  than the numeric case, not a new addressing class.

## 3. Leaving a clean path to future 2-D arrays (not built now)

The descriptor format above is **already** dimension-count-general —
`[dim_count:1][dim1:2]...[dimN:2][data...]` — specifically so a future
2-D `DIM A(x,y)` needs no format migration:

- `dim_count=2` descriptors simply carry two dimension words instead
  of one; every *existing* `dim_count=1` array's own on-disk/in-RAM
  shape is byte-identical to today's design (no migration needed for
  1-D arrays when 2-D is added later).
- Address math: 1-D stays the current cheap `+element_index*width`
  path; 2-D adds a `row*cols+col` computation (`MATH_MULTIPLY16`,
  already exists, reused — same conclusion Part 1 item 3 already
  reached: the multiply itself was never the archived V1 design's real
  cost driver, `DIM`'s own grammar/validation body was) applied only
  when `dim_count=2`, gated by a single branch in `VM_ARR_ADDR`'s
  future replacement.
- Grammar: `DIM name(size)` vs. `DIM name(rows,cols)` still needs a new
  comma-continuation branch in `COMPILE_DIM` (unavoidable, same as
  Part 1's own finding) — but with the *arena* already dimension-count-
  agnostic, that grammar work is now the **only** remaining piece 2-D
  would need, not a combined grammar-plus-storage-format redesign. This
  is strictly less work than reviving the archived V1 design fresh, and
  the archived design's own real evidence (V1's `[kind][...]` variable-
  header approach) is reused as precedent for *this* arena descriptor's
  own shape, per instruction, without restoring any V1 code.
- String arrays inherit the same path for free: a future `DIM A$(x,y,w)`
  is `dim_count=2` plus the existing `kind`/`elem_width` bytes, no
  further format change.

**Not implemented now** — this section establishes only that today's
proposed 1-D format does not need to be discarded later, per
instruction.

## 4. DIMN under dynamic arrays

**Current behavior preserved, mechanism updated.** `DIMN(name)` stays
a **compile-time-resolved** convenience — but it can no longer fold to
a bare literal the way it does today, because an array's size is no
longer known at compile time in the same sense (it's still a compile-
time-literal *argument* to `DIM`, but querying it back out via `DIMN`
now has a real runtime descriptor to consult instead of a symbol-table
byte). Two options, both preserving `DIMN(name)`'s existing one-
argument syntax and its "array must already be DIM'd" validation
(error 47, unchanged):

- **(a) Keep it compile-time-foldable** (recommended, matches current
  behavior most closely): since `DIM`'s size argument remains a
  compile-time literal, the compiler *still* knows it during `COMPILE_
  DIM` and can still record it in `ARRSYMTAB` purely for `DIMN` to read
  back (a cheap 1-2 byte addition to the now-generously-sized compile-
  time symbol entry) — `DIMN` keeps folding to a bare `PUSH_I8`
  literal, zero runtime cost, unchanged from today. This is the
  recommended path: it costs nothing new and preserves `DIMN`'s exact
  current zero-runtime-cost behavior.
- **(b) Runtime-resolved** (only needed if a future feature makes
  array size runtime-variable, which nothing in this design proposes):
  `DIMN` would read the `dim_count`/`dims` header directly from the
  array's own arena descriptor via the pointer table — a real (if
  small) new opcode, and a behavior change (no longer foldable, and no
  longer usable before the array's own `DIM`/`OP_DIM` has actually run
  at least once this session). **Not recommended** unless a concrete
  future need for runtime-variable array sizes appears — option (a)
  is strictly cheaper and sufficient for everything this design
  proposes.

**Multi-dimensional evolution**: with the descriptor already dimension-
count-general (item 3), a future 2-D `DIMN(name,dim)` (V1's own old
2-argument form, "reused as evidence, not restored") slots in naturally
— `dim` selects which of `ARRSYMTAB`'s now-multiple stored dimension
values to fold to a literal, no architecture change beyond what item 3
already establishes. **Not implemented now** — recorded only as the
natural extension point.

## 5. Persistent array SAVE/LOAD (revised for dynamic arrays)

Supersedes Part 1 item 5's design in one important way: because array
data now lives in a *growing* arena rather than a fixed always-present
slot, **LOAD can genuinely allocate the array itself** (bump the arena
exactly like `OP_DIM` would) rather than requiring a matching `DIM` to
already exist — directly matching this request's "LOAD can safely
allocate/reconstruct the array" framing. Design:

- **Proposed syntax**: unchanged from Part 1 — `SAVE "name" ARRAY A` /
  `LOAD "name" ARRAY A` as a shell-level command (or `SAVEARRAY`/
  `LOADARRAY` if that parses more cheaply against the existing `SAVE`/
  `LOAD` dispatch — an implementation-time choice, not a design one).
- **Stored object contents (logical, not addresses)**: `[kind:1]
  [dim_count:1][dim1:2]...[dimN:2][elem_width:1 (string only)]
  [array_name:8][data...]` — every field is metadata the *loading*
  session can act on independently of where the *saving* session's own
  arena happened to place the data, satisfying "should contain logical
  metadata and data, not RAM addresses" directly. `array_name` reuses
  the existing 10-byte filename field in `STORAGE_HEADER_BUF`
  (`STORAGE_HEADER_NAME_OFF`, unchanged from Part 1).
- **Type/bounds metadata**: `kind`/`dim_count`/`dims`/`elem_width` as
  above — a strict superset of Part 1's design, now also covering the
  dimension-count-general shape from item 3.
- **Validation before replacing existing data**: if `name` is **not**
  already `DIM`'d in the current program, `LOAD ARRAY` performs a real
  `OP_DIM`-equivalent allocation from the tape's own recorded
  metadata (clean "reconstruct" case). If `name` **is** already `DIM`'d,
  reject with a clean, distinct error (reusing `DIM`'s own "already
  DIM'd" error class) rather than attempting an in-place resize —
  resizing an arbitrary, possibly-not-most-recent arena entry would be
  exactly the fragmentation this design's whole point is to avoid, so
  it is deliberately not supported. A program that wants to reload
  fresh array data issues `NEW`/`CLEAR` first (already resets the
  arena, item 1) — no special-case reset logic needed for this alone.
- **Checksum/error handling**: unchanged from Part 1 — `STORAGE_
  RECEIVE_BLOCK`'s existing checksum/retry/timeout machinery applies
  as-is, zero new code.
- **Memory-exhaustion behavior**: `LOAD ARRAY`'s own allocation step
  uses the **same** `ARRAYS_END + needed ≤ VARS_START` check `OP_DIM`
  uses (literally the same routine, called from a different context) —
  a tape file claiming more data than the receiving machine's own
  current arena headroom allows fails cleanly with the same `VM_ERR_
  ARRAY_SPACE`-class error, not a silent overrun into bytecode/
  FLOATTAB territory.
- **Reuse of existing infrastructure**: still very high — `STORAGE_
  SAVE`/`LOAD`'s transport, the header/checksum machinery, and `V2_
  LOAD`'s own request-type branching are all reused unchanged from
  Part 1's design; the genuinely new piece is the metadata-driven
  allocate-on-LOAD path, which itself is mostly a different caller of
  the same `OP_DIM` arena-bump logic item 1 already introduces — no
  separate allocation code needed.
- **EXROM placement**: yes, kept in EXROM — the shell-command glue
  belongs in `rom/exrom_v2_shell.asm` next to `SAVE`/`LOAD`/`VERIFY`,
  matching every other shell command's own placement; only the shared
  `OP_DIM`-equivalent arena-bump primitive needs to be reachable from
  both HOME (real `DIM` execution) and EXROM (`LOAD ARRAY`) — the
  existing `MEM_CLEAR_V2`-style fixed cross-bank stub (`include/v2_
  ktab.inc`, this milestone's own item-1 precedent) is the established,
  already-proven mechanism for exactly this need.

## 6. Architecture comparison

| | A. current fixed 4×16 | B. larger fixed (e.g. 6×32) | C. dynamic 1-D (proposed) |
|---|---|---|---|
| Permanently reserved RAM | 128 B (`ARRTAB`) | 384 B | **32-64 B** (pointer table only, e.g. 16 slots × 2B) |
| Descriptor/table RAM | 40 B (`ARRSYMTAB`, 4×10B) | 60 B (6×10B) | ~144-176 B compile-time-only (e.g. 16×9-11B) + 32-64 B runtime pointer table |
| Representative runtime RAM use | 128 B always, regardless of actual need | 384 B always | **Exactly what's `DIM`'d** — e.g. one `DIM A(10)` costs 23 bytes (3-byte header + 20 bytes data), not 32/64/384 |
| HOME/EXROM cost | 0 (already built) | ~0 (two `equ` bumps) | `ESTIMATE` +150-250 B HOME (`OP_DIM`, pointer-table indirection in `OP_ARR_LOAD`/`STORE`, exhaustion check) + 100-150 B EXROM (array SAVE/LOAD) |
| Indexing complexity | 1 shift-multiply, no indirection | same | +1 pointer-table read per access (small, constant extra cost) |
| Practical max arrays/elements | 4 arrays / 16 elements, hard ceiling | 6 / 32, still a hard ceiling | Bounded only by `PROG_END..VARS_START` headroom — e.g. **~2,000 INT16 elements** across all arrays combined for a short program, scaling down as program text grows |
| String-array interaction | Not designed for; would need a wholly separate fixed pool at severe RAM cost (Part 1 item 4) | Same problem, worse (larger fixed pool multiplies the waste) | **Clean** — same arena/pointer-table/`OP_DIM` machinery, `kind`+`elem_width` fields only |
| Future 2-D path | Real redesign needed (operand shape, addressing, symbol format) | Same redesign needed, on top of a bigger already-fixed pool | Descriptor already dimension-count-general (item 3); only grammar is new work |
| Array SAVE/LOAD implications | Must pre-`DIM` an exact-size match before LOAD (no dynamic allocation exists to reconstruct into) | Same | LOAD can allocate/reconstruct directly from stored metadata (item 5) |

**Recommendation**: **C (dynamic)** is the architecturally sound choice
if practical capacity should "depend primarily on available RAM" (this
request's own stated goal) — A and B both keep an arbitrary ceiling no
matter how it's tuned, while C removes the ceiling's arbitrariness
entirely at a one-time, bounded ROM cost (~250-400 bytes combined,
`ESTIMATE`) against a HOME reserve currently at 899 bytes and an EXROM
reserve at 2,194 bytes (this milestone's own final numbers) — tight but
plausible, likely needing a modest companion shrink pass to land
comfortably, not a blocking obstacle. B is strictly dominated by C
(more RAM ceiling for less real capacity, no string-array or 2-D path)
and is not recommended even as an interim step.

## 7. Other capacity limits — reassessed

Numeric scalars (16→32), string variables (4→8), scalar strings
(31→63), recursion depth (6→12): **unchanged from Part 1's own
assessment** — none of the four shares any structure with arrays
(scalars use the separate fixed `SYMTAB_BASE` table, unaffected by
this design; string *variables* use the separate fixed `STRTAB`,
likewise unaffected — only array *elements*, numeric or string, move
into the new arena). All four remain independently sensible at their
previously-estimated costs and are not entangled with the dynamic-
array RAM question — the array arena's own ceiling (`VARS_START`,
currently $9455) does not compete with `SYMTAB_BASE`/`STRTAB` for RAM
at all (different fixed addresses, `$B700`/`$B500`, both well above
`V2_CODE_BASE`). No new finding from this design changes any of the
four recommendations.

---

Stopping here per instruction — no capacity applied, no array redesign
implemented. This document, together with `docs/v2/R10_7_CAPABILITY_
RESTORATION.md`'s own item 7 (already-recommended scalar/string/
recursion increases), is the evidence base for the next R10.7 capacity
decision.

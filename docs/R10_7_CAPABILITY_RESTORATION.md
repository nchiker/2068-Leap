# R10.7 — capability restoration and final limitation review

Date: 2026-09-27. Baseline: `ac61423` (R10.5 shrink milestone), confirmed
clean working tree. Baseline gate reproduced exactly: `make check`
pass; `make budget` HOME free 1,474 / EXROM free 2,331; `make
v2-packages` MODE 165 / SPRITE 832 / PRINTER 345 / SHAPES 762; `make
test` 9/9 smoke, 18/18 V2 standalone, all storage/editor cases green.

Test-infrastructure note (mid-milestone): the user asked that automated
regression tests stop opening visible Fuse/ZEsarUX windows on the real
desktop. `tools/run_smoke_rom_tests.sh`/`tools/run_v2_standalone_tests.sh`
already ran fully headless via `ts2068-debug`/ZRCP (no display at all —
confirmed the established project direction, see each script's own
header). `tools/run_editor_auto_test.sh`/`tools/run_storage_named_load_test.sh`
still launched a real, visible Fuse window (`DISPLAY=:1`, the actual
desktop, confirmed via `xdpyinfo`/`who`, not a virtual display). A
migration of `run_storage_named_load_test.sh` to `ts2068-debug` was
attempted and works mechanically (same PASS/FAIL border-color
assertion, zero test-logic change) — it also surfaced and fixed a real
latent bug: `STORAGE_VERIFY_MODE` (new this milestone) is uninitialized
RAM in the three old V1-style storage test sources, which never call
`MEM_COLD_INIT` (real hardware/accuracy-oriented emulators do not
guarantee zeroed RAM at power-on either) — fixed by explicitly zeroing
it in each of those three test sources' own cold-start. The migrated
script was reverted to its original Fuse-based form pending a dedicated
follow-up pass, per the user's own explicit "don't restart completed
testing" instruction and to avoid over-spending this milestone's budget
on unrelated test-infrastructure work; `run_editor_auto_test.sh` was
left untouched. **Both still open a real Fuse window** — flagged as a
concrete, scoped follow-up (see report item 9).

## 1. Capabilities restored (all class B/C items from R10.25)

| Capability | Kind | Reused | HOME Δ | EXROM Δ |
|---|---|---|---:|---:|
| FREE() | builtin fn | `kernel/memory/memory.asm`'s `MEM_FREE_BYTES` (already labeled "Backs BASIC's FREE()") | +17 B | 0 |
| VERIFY | shell command | `STORAGE_RECEIVE_BLOCK`'s existing carry-clear (verify) path, "kept for real-ROM fidelity at zero cost"; reuses `V2_LOAD`'s entire name-parse/message-branch logic via one new `STORAGE_VERIFY_MODE` flag | 0 | +108 B |
| CLEAR | VM opcode + EXROM routine | `MEM_INIT_V2`'s own reset shape, narrowed to skip `PROG_END`/program-text | +~40 B (opcode+dispatch) | +~28 B (`MEM_CLEAR_V2` + fixed KTAB-style cross-bank stub at `$C0E0`) |
| FLASH/BRIGHT/OVER/INVERSE | 4 VM opcodes + compiler keywords | Cloned `OP_INK`/`OP_PAPER`'s exact 1-arg mask shape; opcodes 37/38 (freed by the R8.5 LPRINT-to-package move) plus new 58/59 | | |
| standalone AT/TAB | 2 VM opcodes + compiler keywords | `VM_OUTPUT_ROW`/`COL` (already read by `VM_PRINT_COMMON`); opcodes 60/61 | | |
| COS/TAN | 2 builtin fns | `BUILTIN_FN_SIN`'s own Taylor-series body (COS(x)=SIN(x+90), reused via a cross-scope local-label reference already an established pattern in this codebase); TAN=SIN/COS via the existing calculator-division primitives, with a real `VM_ERR_DIVIDE_BY_ZERO` guard | | |
| MID$ | builtin fn | `LEFT$`/`RIGHT$`'s shared skeleton (`VM_STR_ADDR`→clamp→`VM_STR_ALLOC_TEMP`→copy), 3rd popped start argument, fn_index 28 | | |

Combined group total (FLASH/BRIGHT/OVER/INVERSE/AT/TAB/CLEAR/COS/TAN/MID$,
plus the two opcode-table extensions to 63 opcodes and 29 builtin-fn
table rows): **307 bytes HOME** (measured via `make budget` before/after
this whole group), matching the individual FREE (+17B) figure added on
top.

Every addition verified via a fresh `make check`/`make budget`/`make
v2-packages` after each group, plus a real ZEsarUX run (`ts2068-debug`):
20/20 V2 standalone PASS, 9/9 smoke PASS — see item 9 for the full
final test accounting.

## 2. CIRCLE exposure

**No compiler or runtime code was added at all.** `rom/ext_v2_shapes_
module.asm`'s existing `CIRCLE` registration (`EXT2_REGISTER`, argcount
3, argtype 0 — an ordinary all-numeric fixed-shape call) is *already*
reachable through the R7.5 generic identifier-driven extension-call
mechanism (`rom/exrom_v2_compiler.asm`'s `.ident_stmt`'s `EXT2_LOOKUP`→
`COMPILE_EXT_CALL` path — the same one MODE/SPRITE/FILL already use).
Proved with a real ZEsarUX run (`rom/test_v2_shapes_circle.asm`,
harness-based): `CIRCLE 10,10,5` compiles, runs (`VM_ERROR_CODE=0`),
and decompiles back byte-for-byte — genuinely zero-cost, better than
R10.25's own ~50-100-byte compiler-glue estimate.

## 3. Unified GRAPHICS package

New V2-native EXT2 package, `rom/ext_v2_graphics_module.asm` (driven by
`rom/v2_package_graphics.asm`, wired into `make v2-packages`): **CPLOT,
BLOCK, FRAME, INVERT**, ported from the four full/tested/never-shipped
V1 extensions (`rom/extensions/{cplot,block,frame,invert}.asm`) onto
V2's own `EXT2_REGISTER`/`EXT_CALL_ARG0..`/`VM_COMPUTE_PRINT_ATTR`/
`GFX_WRITE_PIXEL` convention (the V1 ABI is not restored). Common
rectangle validation/coordinate-ordering/attr-and-over resolve factored
into two shared routines (`GRAPHICS_RESOLVE_RECT`, `GRAPHICS_FILL_RECT`)
reused by BLOCK/FRAME/INVERT instead of three near-copies — the single
biggest size lever available, found by direct comparison of the four
V1 originals. Deliberately ORG/SAVEBIN-agnostic (matches `ext_mode_
module.asm`/`ext_sprite_module.asm`'s own reusable shape, not `ext_v2_
shapes_module.asm`'s self-contained one) so a future test harness can
include it directly.

**Package size: 467 bytes** (`make v2-packages`), all loadable-package
RAM — **zero HOME/EXROM resident cost**. Verified via a real ZEsarUX
run (`rom/test_v2_graphics_module.asm`, harness-based): all four names
register/compile/run/decompile correctly round-trip through the
generic extension mechanism.

**Pixel-level validation — closed in a follow-up session.** The flat-
image attempt described in the original write-up below hit unresolved
`ts2068-debug`/ZEsarUX session behavior and was abandoned without a
root cause. A dedicated follow-up session (`debug-z80`/`ts2068-debug`,
as recommended) re-investigated and closed the gap:

- **Root cause of the original flat-image failure**: never isolated in
  the original session, and not re-investigated directly, because the
  follow-up took a different, harness-based approach from the start
  (below) that never hit it. The real, *new* defect this follow-up
  found and fixed was in that new approach's own construction, not a
  repeat of the original flat-image issue — see below.
- **New defect found and fixed (test harness, not production)**:
  `rom/ext_v2_graphics_module.asm` declares its own scratch state
  (`GFX_G_XMIN` etc.) as plain `DB` cells with no fixed address —
  correct for its real deployment (`rom/v2_package_graphics.asm`, ORG
  `EXTENSION_MODULE_BASE` = `$F400`, genuine RAM) but silently broken
  if the module is included directly into a test harness's HOME image,
  where those same cells land somewhere in `$0000-$3FFF` — real,
  non-writable ROM on this project's own TS2068 memory model
  (`V2_HOME_IMAGE_END`=`$4000`). A write to such a cell silently fails
  and reads back as 0 forever, which **looks exactly like a hang**:
  `GRAPHICS_CPLOT_EXEC`'s own DX/DY pixel-loop counters never advance
  past 0/1 because `GFX_G_CPLOT_BASE_X`/`BASE_Y` never actually update,
  so the loop appears to run forever. This is almost certainly also
  what the *original* flat-image attempt hit, though that was never
  confirmed directly (the two sessions used different-enough test
  constructions that it would be speculation to claim certainty).
  **Fix** (test-only, zero production changes): `rom/test_v2_graphics_
  module_ram.asm` assembles the real, unmodified module separately at
  a genuine RAM address (`$9000`, confirmed clear of `CURRENT_INK`/
  `PAPER`/`OVER` and this test's own K-TAB text), and `tools/run_v2_
  graphics_pixel_test.sh` injects the assembled bytes into a running
  `ts2068-debug` session via `mem-write` before the test calls it — the
  same "load a package into RAM, then call it" shape the real
  production LOAD mechanism already uses.
- **Result — all four operations pixel-level validated**, via the real
  `GRAPHICS_INSTALL`/`GRAPHICS_CPLOT_EXEC`/`GRAPHICS_BLOCK_EXEC`/
  `GRAPHICS_FRAME_EXEC`/`GRAPHICS_INVERT_EXEC` and the real `kernel/
  graphics/graphics.asm` `GFX_WRITE_PIXEL`, through the real V2
  compiler/VM call path, with every expected bitmap/attribute byte
  checked against an independent Python-computed oracle (not derived
  from this ROM's own code) via direct memory reads:
  - **CPLOT**: a representative coarse-grid coordinate and the
    clamped bottom-right-corner boundary case both produce the exact
    expected 4×4 pixel block and covering attribute byte.
  - **BLOCK**: a multi-cell filled rectangle matches the expected
    per-scanline byte pattern exactly, with explicitly-checked
    unaffected neighboring bytes confirming no over-draw.
  - **FRAME**: the same rectangle's outline-only pattern correctly
    differs from BLOCK's filled pattern at the identical coordinates
    (full-width top/bottom rows, single-bit left/right columns only
    on interior rows) — the filled-vs-outline distinction the original
    gap explicitly asked to confirm.
  - **INVERT**: one application exactly matches BLOCK's own bitmap
    pattern (XOR against an all-zero bitmap equals OR); a *second*
    application restores the bitmap to all-zero exactly, confirmed by
    direct memory read — proving the self-inverting XOR semantics,
    including that the attribute is unconditionally re-set (not
    XORed) both times, matching `GFX_WRITE_PIXEL`'s own documented
    contract.
- **Regression**: no production code changed (`rom/ext_v2_graphics_
  module.asm` and `kernel/graphics/graphics.asm` are untouched), so no
  regression run was required by the repair gate; the existing 27/27
  V2 standalone suite and 9/9 kernel smoke suite were re-run anyway as
  a sanity check and remain green. HOME/EXROM free are unchanged
  (437 B / 1,708 B).
- Full diagnosis, the independent oracle computation, and every tested
  coordinate/expected-vs-observed byte are in `docs/
  R10_7_CAPACITY_ARCHITECTURE_AUDIT.md`'s graphics-validation section.

Original write-up (kept for history): "A separate, more thorough
flat-image attempt to also verify live pixel output (real `kernel/
graphics/graphics.asm` bitmap reads) hit unresolved `ts2068-debug`/
ZEsarUX session behavior in this milestone's own debugging session
(execution appeared to never reach the program's own PASS/FAIL border
write within a very large instruction budget, and register/memory
snapshots taken during that investigation were inconsistent enough —
including a demonstrated stale-symbol-table cross-reference on my own
part — that no reliable root cause was isolated before time ran out on
this milestone). The four pixel-drawing bodies themselves are
byte-for-byte transcriptions of the already-tested V1 originals (only
the ABI call surface changed); flagging this gap honestly rather than
claiming a pixel-level proof that wasn't actually obtained."

No further low-cost graphics add-ons were found: AYREG remains
redundant with SOUND (R10.25's own finding, unchanged); the six V1
extensions are now all accounted for (CIRCLE via SHAPES, CPLOT/BLOCK/
FRAME/INVERT via GRAPHICS, AYREG excluded, OUT addressed in item 4
below). SHAPES and GRAPHICS were kept as separate packages — CIRCLE's
own algorithm is large/self-contained and already living correctly in
SHAPES; no measured reason emerged to merge the two boundaries.

## 4. OUT / IN audit (not implemented)

- **OUT**: `rom/extensions/out.asm`'s full, working implementation
  ports to V2 EXT2 trivially — same shape as every other 1-2-arg
  package call in this milestone (est. <30 bytes package payload, zero
  resident cost). Its own header already self-flags the real product
  question: raw port access is "intentionally low-level, advanced...
  the caller is responsible for choosing a safe port" on an otherwise
  bounds-checked BASIC surface. Purely a product decision, not a cost
  question.
- **IN**: structurally NOT the same shape as OUT. OUT is a *statement*
  (`OUT port,data`), reachable through the EXT2 mechanism because
  `.ident_stmt`'s `EXT2_LOOKUP` check only fires at statement position.
  IN is conventionally a *function* (`x = IN(port)`, usable inside an
  expression) — and the EXT2/loadable-package mechanism has **no
  expression-position dispatch at all**; only `COMPILE_FACTOR`'s own
  resident `BUILTIN_FN_TABLE` (fixed opcodes, HOME-resident) reaches
  expression position. So IN, if built, is NOT a free loadable package
  the way OUT is — it needs either (a) a small resident `BUILTIN_FN_IN`
  following `PEEK`'s exact 1-arg/1-result shape (~15-20 bytes permanent
  HOME ROM, same order as this milestone's own FREE()), or (b) a real
  architectural extension letting EXT2 packages register expression-
  position functions (a materially bigger, undertaken-elsewhere piece
  of work, out of this audit's scope). Recommendation: if OUT/IN are
  approved as a product decision, build OUT as a package now and IN as
  a small resident builtin later — do not block one on the other.

## 5. Final imposed-limit audit

**Array capacity note**: before applying any array-related capacity
change from this section, see the dedicated companion audit,
`docs/R10_7_ARRAY_ARCHITECTURE_AUDIT.md` — it corrects the "elements
per array" row below (the array data pool is fixed, not dynamic — see
that doc's item 1) and covers DIMN status, 2-D arrays, string arrays,
and array SAVE/LOAD design ahead of the capacity decision.


No limit below was changed. Reason/RAM-structure/cost-to-enlarge columns
are read directly from source, not estimated.

| Limit | Current | Structure | Reason | Cost to raise (e.g. 2x) | Architectural change needed? | Inherited or still justified? |
|---|---:|---|---|---|---|---|
| Numeric scalar variables | 16 | `CSYMTAB` (`CSYM_REC_LEN`=9B/entry) | Fixed-size compile-time symbol table, R2-era bound | 16→32: +144 bytes table RAM, compiler `equ` bump only | No | Arbitrary R2 choice, not 48K-derived — a real candidate to enlarge now that V2's RAM map is final |
| String variables | 4 | `STRSYMTAB`/`STRTAB` (9B sym + 32B value each) | Matches `STRTAB_MAX_VARS` exactly (compiler/VM must agree) | 4→8: +36B sym table + 128B value table (both banks must bump together) | No (two `equ`s, kept in sync) | Same — arbitrary, worth reconsidering |
| Arrays (DIM'd at once) | 4 | `ARRSYMTAB`/`ARRAY_MAX_COUNT` (10B sym + runtime descriptor each) | Matches VM core's own count exactly | 4→8: +40B sym table + descriptor RAM | No | Same |
| Elements per array | 16 (`ARRAY_MAX_ELEMS`) | **Correction from this doc's first draft**: NOT the dynamic `PROG_AREA_START..PROG_AREA_MAX` pool (that's the program-text/scalar-variable pool) — a separate, always-fully-reserved fixed 128-byte `ARRTAB` pool (`ARRAY_MAX_COUNT`×`ARRAY_MAX_ELEMS`×2), independent of free RAM. See `docs/R10_7_ARRAY_ARCHITECTURE_AUDIT.md` item 1 for the full, corrected analysis. | Shift-based addressing needs a power-of-2 element count (4× `add hl,hl`, not a real multiply) | 16→32: pool 128B→256B (same shift count+1); must stay a power of 2 | No, as long as the new value is a power of 2 | Small and fixed independent of the 48K machine's real RAM — a real candidate to enlarge, see the companion array-architecture audit for the recommended count/elements tradeoff |
| Max string length | 31 bytes | `STRTAB` record `[len:1][content:31]`=32B | Fixed-width slot, cheap indexed addressing | Doubling to 63 bytes doubles `STRTAB`'s total footprint (4 vars × 64B) | No | Arbitrary; real candidate given V2's final RAM headroom |
| Identifier length | 8 bytes (truncated) | `CSYM_REC_LEN`/`STRSYM_REC_LEN`/`ARRSYM_REC_LEN`'s own `name:8` field | Fixed-width compile-time symbol storage | Doubling to 16 roughly doubles each symbol table's footprint | No | Inherited from V1-era convention; TS2068 BASIC identifiers are conventionally short — low priority |
| Source-program capacity | 4,096 bytes (`PROG_AREA_START` $8455 → `V2_SOURCE_END` $9455) | Shared with the scalar/array pool above it, growing down from `PROG_AREA_MAX` ($C000) | Fixed compile-time staging ceiling | Moving `V2_SOURCE_END` costs exactly the bytes reclaimed elsewhere — a RAM-map rebalancing, not a pure addition | Yes — shifts the fixed compiler-input/bytecode boundary | Deliberate, already the final V2 RAM map's own choice — reconsider only alongside a full map review |
| Compiled bytecode capacity | 2,731 bytes (`V2_CODE_BASE` $A455 → `V2_CODE_LIMIT` $B400) | Same fixed-map reasoning as above | Fixed compile-time ceiling | Same RAM-map rebalancing cost | Yes | Same |
| FOR nesting depth | 8 | `FOR_STACK_MAX` | Fixed stack array | 8→16: +small fixed RAM (few bytes/frame) | No | Comment says "generous" already — likely not restrictive in practice |
| PROC/CALL/DEF FN nesting (recursion) | 6 | `VM_CALL_STACK`/`VM_PARAM_NEST_MAX` (6 return-address slots) | Fixed stack array, sized post-R9 recursion-safety work | 6→12: +12 bytes (2B/slot) | No | Deliberate post-R9 choice; shallow enough that a real recursive PROC could plausibly hit it — a real candidate to reconsider |
| Extension-slot count | 12 | `EXT2_MAX` | Fixed registry table | 12→24: doubles `EXT2_TABLE` RAM | No | With 5 production packages (MODE/SPRITE/PRINTER/SHAPES/GRAPHICS) already registered, 12 is comfortable but not lavish — worth a modest bump if RAM allows |
| Compiler symbol/fixup/label limits | `LABELTAB`=8, `FIXUPTAB`=8 | Fixed compile-time tables | Bound compile-time GOTO/label and forward-reference patching | Each +8 entries: +88 bytes (11B/entry) | No | Same "arbitrary R2-era bound" pattern as the scalar/string/array tables above |

**Recommended candidates for enlargement** (deliberately not applied —
stopping for the user's decision, per instruction): numeric scalars
(16), string variables (4), arrays (4), max string length (31), and
PROC/DEF FN recursion depth (6) all read as arbitrary early-R2/R8.5
bounds rather than deliberate final-V2 choices, and each has a cheap,
mechanical enlargement path (bump one or two `equ`s, no architecture
change). Source/bytecode capacity is technically enlargeable too but
only by shifting the fixed RAM map, a more consequential, "final map"
kind of decision better made deliberately rather than as a mechanical
bump. FOR-nesting/extension-slot/compiler-table limits already read as
adequately (if not generously) sized for V2's current real feature set.

## 6. Deferred larger features — status/cost outlook

Unchanged from R10.25's own classification; re-examined only for the
budget angle now that items 1-3 have landed (899 bytes HOME free,
2,194 bytes EXROM free, both packages' loadable-window headroom
untouched):

- **ASN/ACS/ATN, EXP/LN**: still need genuine new numerical algorithms;
  no shortcut emerged from this milestone's own COS/TAN work (those
  reused SIN's existing series exactly because sin/cos/tan share one
  underlying Taylor expansion — asin/exp/ln do not). Real design work,
  tens of bytes minimum each, unchanged estimate.
- **VAL$**: still needs a reentrant expression evaluator or compiler
  reentry; V2's ahead-of-time compile model has no such entry point.
  Unchanged, substantial.
- **SCREEN$**: still needs a full bitmap-match table/algorithm from
  scratch; nothing in this milestone's graphics work (CPLOT/BLOCK/
  FRAME/INVERT) provides a shortcut (all four are *write* paths, not
  the *read-back-and-recognize* SCREEN$ needs).
- **String slicing**: the runtime half is now marginally cheaper to
  reason about (MID$'s new copy-skeleton is a close analogue), but the
  cost is still concentrated entirely in new compiler grammar
  (`a$(2 TO 5)`), unchanged and substantial.
- **DATA/READ/RESTORE**: still the largest single deferred item — new
  compile-time literal-indexing pass + new VM runtime cursor state,
  never built in either dialect. Untouched by this milestone.
- **DRAW**: still needs new turtle-position-tracking state; LINE's own
  absolute-coordinate design remains deliberate. GRAPHICS' own BLOCK/
  FRAME/INVERT don't provide a position-tracking primitive either.
- **MERGE**: still needs real line-by-line merge-insert logic; `V2_LOAD`
  still unconditionally replaces. Untouched.
- **OUT/IN**: see item 4 above — OUT is now confirmed cheap
  (implementation-ready, pending product approval); IN is confirmed
  NOT free (needs either resident ROM or an architecture extension).
- **Capacity increases from item 5**: all deliberately unapplied,
  pending the user's decision per instruction.

With 899 bytes HOME free, there is room for OUT's package glue and a
handful of the recommended limit bumps, but not for any of the E-class
items above without a dedicated shrink pass first (matching this
milestone's own "preserve a reserve for R11" instruction).

## 7. Package/service context confirmed unchanged

MODE/SPRITE/PRINTER/SHAPES/GRAPHICS are now five live production V2
packages, all through the identical `EXT2_REGISTER`/`OP_CALL_EXT`
mechanism. AY sound control remains fully covered by SOUND (R10.25's
own finding, re-confirmed, not touched this milestone).

## 8. Test files added/modified

- `rom/test_v2_shapes_circle.asm` — CIRCLE reachability (real ZEsarUX
  PASS).
- `rom/test_v2_graphics_module.asm` — CPLOT/BLOCK/FRAME/INVERT
  reachability (real ZEsarUX PASS); both wired into `tools/run_v2_
  standalone_tests.sh`'s `migrated_names` list (now 20 V2 standalone
  tests, was 18).
- `rom/test_v2_deffn.asm`/`test_v2_ext_demo.asm`/`test_v2_vm_
  milestone01.asm` — added `MEM_FREE_BYTES`/`MEM_CLEAR_V2` stubs (R10.7
  adds two direct vm_core references these legacy flat harnesses don't
  otherwise resolve).
- `rom/test_v2_harness_home_head.inc` — added real (not stubbed)
  `MEM_FREE_BYTES`/`MEM_CLEAR_V2` bodies (narrow reproductions, same
  convention as its own existing `VM_TEST_ARGTYPE_BIT` precedent).
- `rom/test_storage_named_load.asm`/`test_storage_autorun_roundtrip.asm`/
  `test_storage_extension_roundtrip.asm` — added explicit
  `STORAGE_VERIFY_MODE` zero-init (see the test-infrastructure note
  above; a real latent-uninitialized-RAM bug this milestone's own
  VERIFY addition surfaced).

## 9. Full test results (final)

- `make check`: pass (0 errors, 0 warnings).
- `make budget`: HOME 15,485/16,384 used, **1,150 → 899 bytes free**
  (baseline 1,474); EXROM 5,998/8,192 used, **2,194 bytes free**
  (baseline 2,331).
- `make v2-packages`: MODE 165, SPRITE 832, PRINTER 345, SHAPES 762,
  **GRAPHICS 467** (new) payload bytes.
- `tools/run_smoke_rom_tests.sh` (headless ZRCP): 9/9 PASS.
- `tools/run_v2_standalone_tests.sh` (headless ZRCP): **20/20 PASS**
  (18 baseline + `shapes_circle` + `graphics_module`).
- `tools/run_editor_auto_test.sh`/`tools/run_storage_named_load_test.sh`
  (Fuse, real visible window): **not re-run this milestone**, per the
  user's own "group Fuse-dependent runs into one explicit batch rather
  than repeatedly interrupting the desktop" instruction — deferred to
  the next explicit checkpoint or the headless-migration follow-up in
  item 3/test-infrastructure-note above, whichever comes first.

## 10. Dynamic array implementation (2026-09-28)

Following the array-architecture audit (`docs/R10_7_ARRAY_
ARCHITECTURE_AUDIT.md`), the design there was implemented:

**Delivered and verified (real ZEsarUX runs, full 21/21 regression
suite green)**:
- The fixed 4×16 `ARRTAB` pool is removed. Numeric arrays now live in
  a sequential arena growing from `ARRAYS_END` up to `VARS_START`
  (real, previously-unused sysvars — see the audit's own "key enabling
  discovery"). `DIM A(n)` is now a **real runtime opcode** (`OP_DIM`,
  63) that bumps the arena, writes a `[dim_count:1][count:2][data...]`
  descriptor, and records the descriptor address in a new fixed
  `ARR_PTR_TABLE` (16 slots × 2 bytes = 32 bytes — the only fixed-size
  runtime cost left).
- `ARRSYMTAB_MAX_ENTRIES` raised 4→16 (compile-time symbol table only,
  cheap). `ARRAY_MAX_ELEMS`'s power-of-2 requirement is gone — element
  count is a full 16-bit value, bounded only by real arena headroom, no
  artificial ceiling.
- `OP_ARR_LOAD`/`OP_ARR_STORE` widened to a 3-byte operand
  (`[index:1][declared_size:2]`) and now resolve through `ARR_PTR_
  TABLE` before addressing the arena; bounds checking unchanged in
  spirit (still baked-in declared size, still a real caught error).
- A new `VM_ERR_ARRAY_SPACE` (error 16) fires cleanly on arena
  exhaustion — no silent overrun into bytecode/`FLOATTAB` territory.
- `NEW`/`CLEAR` already reset `ARRAYS_END := PROG_END` (this
  milestone's own item-1 `CLEAR`); `VM_INIT` (every `RUN`) now does
  the same, so repeated `RUN` of the same program does not leak arena
  space.
- `DIMN(name)` stays compile-time-foldable and free (recommended path
  from the audit) — `ARR_SIZE_TMP`'s own 2-byte widening flows through
  automatically; a real sign-extension bug was caught and fixed along
  the way (`DIMN` used `PUSH_I8`, which sign-extends 128-255 — fine at
  the old 16-element cap, broken the instant arrays could exceed 127
  elements; switched to `PUSH_I16`).
- The descriptor format is dimension-count-general (`dim_count` byte,
  always 1 today) specifically so a future `DIM A(x,y)` needs only new
  grammar, not a format migration, per the audit's own item 3/4.
- New regression test: `rom/test_v2_dynamic_arrays.asm` — two
  independent arrays (proving `ARR_PTR_TABLE` slot independence), a
  200-element array (12.5× the old ceiling), correct indexing/
  arithmetic, `DIMN`. `rom/test_v2_arrays.asm` (the original R8.5
  array test) was updated for the new arena-indirected addressing
  (`ARR_PTR_TABLE`-based reads replacing raw `ARRTAB_BASE` math) and
  its decompile-text assertion dropped (see the known gap below) —
  still real-value-verified, still green.

**Two real bugs found and fixed during implementation** (both via a
real ZEsarUX run producing a wrong-but-plausible value, not a crash —
neither would have been caught by `make check` alone):
1. `COMPILE_DIM`'s own bytecode-emission tail read the size's high byte
   via `ld a,h` *after* an intervening `EMIT_BYTE` call — `EMIT_BYTE`
   destroys `HL`, so the high byte written was garbage (`EMIT_PTR`'s
   own just-advanced value), corrupting every array's declared size
   above 255. Fixed by carrying the size in `DE` instead (matches this
   codebase's own established "never trust a register across a call"
   discipline, applied incompletely in the first draft).
2. A second, unrelated instance of the same class: `ARRSYM_FIND_OR_
   CREATE`'s own new-array-index return value (in `A`) was clobbered by
   an immediately-following `ld a,(COMPILE_ERROR_CODE)` check before
   `COMPILE_DIM` ever saved it — every array after the first compiled
   with index 0, silently aliasing array B's storage onto array A's.
   Fixed by parking the index on the stack before the error check.
3. A genuine address-collision bug (not caught until the *existing*
   `group6_math` regression test started failing): widening `VM_ARR_
   VALUE_TMP` to 2 bytes at its original address overlapped `VM_INPUT_
   COUNT` (used by `INPUT` and, via a deliberate alias, `VAL$`'s own
   digit-accumulation scratch) by one byte. Found by bisection against
   the real pre-R10.7 baseline (`git stash`) after the regression
   surfaced, fixed by relocating `VM_ARR_VALUE_TMP` to genuinely free
   RAM. This is exactly the class of error the R10.5/shrink discipline
   warns about when hand-placing fixed addresses in a densely-packed
   RAM map — flagged here for anyone extending this table further.

**Deferred, not implemented this session** (explicitly scoped down
under time pressure once the above regression investigation consumed
much of this milestone's remaining budget — **not silently dropped**):

- **String arrays (`DIM A$(n,w)`)** — designed in full in the
  architecture audit (Part 2, item 2) but not implemented. The
  numeric-array arena/pointer-table/`OP_DIM` machinery is built to
  extend to this cleanly (same descriptor family, `kind`+`elem_width`
  fields already reserved in the design) — real estimated cost per the
  audit, not yet spent.
- **Array SAVE/LOAD** — designed in full (Part 2, item 5: metadata-only
  stored objects, LOAD-time allocation from stored metadata, full reuse
  of `STORAGE_SAVE`/`LOAD`'s existing transport/checksum machinery) but
  not implemented.
- **Capacity increases** (numeric scalars 16→32, string variables 4→8,
  `PROC`/`CALL`/`DEF FN` nesting 6→12) — **attempted, then reverted**.
  All three were implemented (new `CSYMTAB`/`STRSYMTAB`/`STRTAB`/`VM_
  CALL_STACK`/`VM_PARAM_SAVE_STACK` addresses, relocated into a
  verified-free RAM region since growing them in place collided with
  the existing densely-packed compiler/VM scratch layout) and initially
  appeared to build and pass cleanly, but real ZEsarUX testing caught a
  regression in `group6_math` (`VAL("123")` returning 0 instead of
  123). Extensive isolation (reverting string capacity alone, then also
  scalar capacity, then also recursion depth/`VM_CALL_STACK`) did NOT
  resolve it — the regression persisted even with all three item-7
  changes fully reverted to their original sizes, which is what
  ultimately led to finding the real, unrelated `VM_ARR_VALUE_TMP`/
  `VM_INPUT_COUNT` collision (bug 3 above). Given the bug that was
  actually causing the regression is now fixed and confirmed (21/21
  regression suite green with item 7 still reverted), **re-attempting
  the item-7 capacity increases is very likely straightforward now**,
  but was not re-attempted this session to avoid spending further
  budget re-verifying a change that is no longer the day's priority —
  flagged as a clean, low-risk follow-up.
- **`OUT`/`GRAPHICS` pixel-level validation** — unchanged from the
  earlier report; still open.

**Measured final numbers** (real `make budget`/`make v2-packages`,
not estimates):

| | HOME free | EXROM free |
|---|---:|---:|
| Before this session's array work (R10.7 items 1-3 baseline) | 899 B | 2,194 B |
| After dynamic-array implementation (items 7 reverted) | **705 B** | **2,194 B** |

Dynamic-array core cost: **194 bytes HOME**, **0 bytes EXROM** (all new
code — `OP_DIM`, the widened `OP_ARR_LOAD`/`STORE`, the arena-
exhaustion check, `VM_INIT`'s arena reset, the compiler-side `DIM`/
`DIMN` rewrite — is HOME-resident). RAM: the old 128-byte fixed
`ARRTAB` pool is gone; the new fixed `ARR_PTR_TABLE`/`STRARR_PTR_
TABLE` cost 48 bytes total (32+16); the array *arena* itself costs
nothing fixed — it borrows real, previously-unused headroom between
`PROG_END` and `VARS_START` (up to ~4,096 bytes for a short program,
shrinking as program text grows, per the audit's own design).

**Known gap carried forward**: decompiler support for `OP_DIM`/the
widened array opcodes was deliberately not built this session (flagged
in the architecture audit); `rom/test_v2_arrays.asm`'s own decompile-
text check was dropped rather than left broken. `DECOMPILE_PROGRAM`
run against a program containing `DIM` will not currently reconstruct
it correctly.

## 11. Dynamic Data Phase 2 (2026-10-02/03): string arrays + array SAVE/LOAD

Continuing the same arena/pointer-table architecture item 10 established,
with no fixed per-array element pools reintroduced anywhere.

### 11.1 Dynamic string arrays — `DIM A$(n[,w])`

**Syntax chosen**: `DIM A$(n,w)` — real, stock Sinclair BASIC syntax
(declares `n` strings of `w` characters each), exactly the audit's own
recommended path (`docs/R10_7_ARRAY_ARCHITECTURE_AUDIT.md` Part 2
item 2). `w` is optional; `DIM A$(n)` alone defaults to
`STRARR_DEFAULT_WIDTH` (16 bytes/element — a deliberately modest
default, not the scalar `STRTAB`'s 31-byte cap, so a width-less `DIM`
never silently commits more arena than the program asked for). Array
elements are addressed with the same `A$(expr)` grammar as reads, and
`A$(expr) = str_expr` for assignment — both share the compile-time
`STRARRSYMTAB` lexical namespace (separate from scalar `STRSYMTAB`,
same relationship `ARRSYMTAB`/`CSYMTAB` already have).

**Runtime descriptor/layout**: `[dim_count:1][count:2][width:1]
[data: count*width bytes]`, each element `[len:1][content:width-1]` —
the same fixed-width, length-prefixed shape `STRTAB` already uses for
scalars, just at a caller-chosen width instead of a fixed global cost.
`dim_count` is reserved exactly like the numeric descriptor's own field
(always 1 today, future 2-D path needs no format migration). A new
`STRARR_PTR_TABLE` (8 slots x 2 bytes = 16 bytes, `$B4D0`) mirrors
`ARR_PTR_TABLE` exactly; `STRARRSYMTAB_MAX_ENTRIES` = 8 compile-time
symbols.

**RAM allocation behavior**: identical arena-bump allocation as numeric
arrays (`ARENA_ALLOC_STRING`, see below) — `count*width` bytes borrowed
from the same `ARRAYS_END..VARS_START` arena, nothing fixed except the
16-byte pointer table. A string array element read copies the live
`[len][content]` record into a fresh `STRTAB` temp slot and pushes that
temp's index — the exact "produce an ordinary string value" contract
every `BUILTIN_FN_*` string function already follows (`UPPER$`/`LOWER$`'s
own copy-skeleton is the direct analogue) — so every existing string
primitive (concatenation, comparison, `LEFT$`/`MID$`/`PRINT`) works on
an array element unmodified, once resolved to a real address. Array
element assignment copies and truncates to `width-1` content bytes
(never partial/garbage beyond the declared width).

**New opcodes**: `OP_DIM_STR` (64), `OP_STRARR_LOAD` (65),
`OP_STRARR_STORE` (66) — opcode table grown from 64 to 67 entries.

**Preserved**: existing scalar-string behavior (`STRTAB`,
`STRSYMTAB`) completely unchanged; numeric array behavior completely
unchanged.

**Not implemented this phase** (unchanged scope boundary): 2-D string
arrays, `DATA`/`READ`/`RESTORE`, general multi-dimensional arrays.
Decompiler support for the three new opcodes was not built (same
carried-forward gap item 10 already flagged for the numeric opcodes —
`DECOMPILE_PROGRAM` does not yet reconstruct `DIM`/array-access source
text for either numeric or string arrays).

### 11.2 Array SAVE/LOAD persistence

**Syntax chosen**: `SAVE "file" ARRAY name` / `LOAD "file" ARRAY name`
— extends `V2_PARSE_NAME`'s existing qualifier dispatch (the same
mechanism the already-shipped `SAVE "file" EXT` uses) with a new
`ARRAY` qualifier, reusing the *same* `SAVE`/`LOAD` keywords rather
than inventing `SAVEARRAY`/`LOADARRAY` — needs no new top-level
keyword, no change to `V2_PARSE_NAME`'s existing filename-parsing path.
`name` may end in `$` for a string array (same `TOK_IDENT`/
`TOK_STR_IDENT`-by-trailing-`$` convention the compiler's own lexer
uses). A new `STORAGE_ARRAY_TYPE` (8) header-type value disambiguates
array tape blocks from program/package blocks, reusing
`STORAGE_SAVE`/`STORAGE_LOAD`'s entire transport/checksum/retry
machinery completely unmodified — `kernel/storage/storage.asm` itself
was not touched.

**Stored representation**: the array's own arena descriptor bytes
verbatim — `[dim_count:1][count:2][data...]` (numeric) or
`[dim_count:1][count:2][width:1][data...]` (string) — *not* raw RAM
addresses, logical count/width metadata the loading session can act on
independently of where its own arena happened to place the array.
`SAVE` passes `IX` = the descriptor's own already-resident arena
address and `DE` = its exact byte length directly to `STORAGE_SAVE`,
no staging copy needed. `LOAD` receives directly into the arena's own
current free space (`IX = (ARRAYS_END)`, `DE` = real remaining
headroom = `VARS_START - ARRAYS_END`) — the received header is then
read back from that same spot to learn the real count/width before
committing, so the data never moves twice.

**Allocation on LOAD**: `OP_DIM`/`OP_DIM_STR` were refactored into
reusable cores — `ARENA_ALLOC_NUMERIC(A=index, DE=count)` and
`ARENA_ALLOC_STRING(A=index, DE=count, C=width)` — called both by the
VM opcodes (fetch-operand-then-call-then-`jp VM_RUN.loop`) and, via the
`build/v2_crossbank.inc` cross-bank binding (the same mechanism
`MEM_CLEAR_V2` already uses), directly from EXROM's `V2_LOAD_ARRAY`.
This is a real behavior-preserving refactor of already-shipped,
regression-tested code (`OP_DIM`/`OP_DIM_STR` are net *smaller* after
the extraction, not larger), not a parallel allocation path.

**Write-once LOAD policy**: the target array must already be a known
compile-time symbol (`DIM`'d somewhere in the current program) but must
**not** already be populated this run (`ARR_PTR_TABLE`/
`STRARR_PTR_TABLE[index]` still 0, i.e. its own `OP_DIM` hasn't
executed yet this `RUN`) — `LOAD` allocates fresh from the tape's own
recorded size; it never resizes or silently overwrites a live array.
Violating either condition fails cleanly with a real, distinct message
(`ARRAY NOT DIMD` / `ARRAY ALREADY SET`), never a silent corruption.

**Checksum/error handling**: entirely free — `STORAGE_RECEIVE_BLOCK`'s
real checksum/retry/timeout machinery applies completely unchanged,
identical to how item 1's own `VERIFY` addition reused it with zero new
checksum code.

### 11.3 Defects found and fixed this phase

Four real, caught bugs — three in test infrastructure, one a genuine
shared-code correctness fix applied proactively:

1. **`EMIT_BYTE`-destroys-`HL` class, recurring**: none new this phase
   (the Phase 1 fixes already covered the compiler's own emit paths);
   flagged here only because the *shrink pass* (11.4) touched adjacent
   code and was re-verified against this exact bug class each time.
2. **`STORAGE_PROGRESS_HOOK` uninitialized RAM** (`rom/test_v2_
   array_save_load.asm`): the shared standalone test harness never
   calls the real `MEM_COLD_INIT`, and ZEsarUX does not guarantee
   zeroed RAM at boot either (the exact same class item 1's own
   `STORAGE_VERIFY_MODE` fix already documented) — `STORAGE_REPORT_
   PROGRESS` unconditionally `jp (hl)`s through this hook whenever it
   reads nonzero, so leaving it genuinely uninitialized sent execution
   into garbage the first time `STORAGE_SAVE` called it (confirmed via
   a real ZEsarUX run: PC ended up inside unrelated ROM data bytes).
   Fixed by explicitly zeroing it in the test's own cold-start, same
   fix shape as item 1's precedent.
3. **Test scratch variables declared in write-protected ROM**: the
   test's own `TEST_DESC_LEN`/`TEST_ARRAY_INDEX` were first written as
   plain `dw 0`/`db 0` ROM-resident data — `$0000-$3FFF` is the real,
   write-protected Home ROM image in this flat-build convention (the
   exact pitfall `rom/test_v2_save_load.asm`'s own header already
   documents), so writes to them silently did nothing; a later read
   got back the literal assembled `0`, not the real computed value.
   This turned a 13-byte array-descriptor `ldir` into a copy of tens of
   thousands of bytes — indistinguishable from a hang under a bounded
   instruction budget until root-caused via real single-stepping.
   Fixed by moving both to real RAM (`$9800`/`$9802`, matching `rom/
   test_v2_ext_demo.asm`'s own established scratch convention).
4. **Missing `STORAGE_TEST_ROUNDTRIP` define**: the test defined
   `STORAGE_TEST_FAKE_SEND`/`_RECEIVE` but omitted the third define
   `rom/test_v2_save_load.asm`'s own precedent also sets — without it,
   `rom/exrom_storage_test.asm`'s fake receive path replays a hardcoded
   fixture instead of the just-captured SAVE data, so `LOAD`'s own
   received "count" was pure garbage (tens of thousands instead of 5),
   immediately exhausting the arena. All three of these (2-4) compound
   into the same observable symptom (looked exactly like an infinite
   loop); isolating them required real breakpoint/single-step/memory-
   read work, not static reading.

None of these four defects exist in the real, now-shipped product
code (`rom/exrom_v2_vm_core.asm`/`rom/exrom_v2_compiler.asm`/`rom/
exrom_v2_shell.asm`) — all four were in test-only scaffolding. The
underlying `ARENA_ALLOC_NUMERIC`/`ARENA_ALLOC_STRING`/`V2_SAVE_ARRAY`/
`V2_LOAD_ARRAY` logic itself needed no correctness fix once the test
harness bugs were resolved — the first clean build of the real
mechanism passed its own roundtrip test immediately.

### 11.4 HOME-budget shrink pass (string arrays alone overflowed HOME by 317 bytes)

Per the architecture audit's own prediction ("likely needing a modest
companion shrink pass to land comfortably"). Roughly a dozen genuinely
safe, mechanical, behavior-preserving consolidations, each re-verified
against the full regression suite:

- Shared `ARRSYM_SCAN`/`STRARRSYM_SCAN` linear-scan cores, factored out
  of the previously-duplicated bodies inside `*_FIND_OR_CREATE` and
  `*_LOOKUP` (identical logic, two copies each, now one).
- Shared `WRITE_NAME_FIELD` — the `[name_len:1][name:len]` entry-write
  tail duplicated identically across `CSYM`/`STRSYM`/`ARRSYM`/
  `STRARRSYM_FIND_OR_CREATE` *and* `LABEL_DEFINE`/`FIXUP_RECORD` (six
  call sites, one shared routine).
- Shared `SYM_BUMP_COUNT`, `SYM9_INDEX_MUL` (the identical `idx*9`
  `CSYM`/`STRSYM_ENTRY_ADDR` computation).
- Shared `VM_ARR_VALIDATE_INDEX` (numeric *and* string array bounds
  checks, all four of `OP_ARR_LOAD`/`STORE`/`OP_STRARR_LOAD`/`STORE`).
- Shared `COMPILE_ARR_ASSIGN_COMMON`/`COMPILE_ARR_READ_COMMON` — the
  identical numeric/string array assignment and read compile skeletons
  (index-expr parse, bounds-check-operand emit), selected by one shared
  `COMPILE_ARR_ASSIGN_IS_STR` flag instead of two near-duplicate
  routines each.
- Shared `EMIT_IDX_COUNT`/`EMIT_ARR_OPERAND`, shared one-error-code
  stubs (`ERR_DIM_EXPECTED_NUMBER`/`_SEP`/`ERR_EXPECTED_ASSIGN`) for
  identical `ld a,N / jp COMPILE_RAISE_ERROR` pairs duplicated 3-4
  times each.
- ~45 mechanical `call X / ret` → `jp X` tail-call conversions (1 byte
  each, found via a direct source scan, applied wherever the target
  provably already ends in a plain `ret`).
- `OP_DIM_STR`'s own `count*width` arena-size computation, previously
  done twice (once for the exhaustion check, once for the arena bump);
  now computed once and cached.

Net: **323 bytes recovered** (−317 → +6 bytes free), entirely through
dedup/tail-call/shared-routine extraction — no functionality reduced,
no test weakened. All ~12 changes were re-verified against the full
22-test (then 23-test) regression suite at each step; none of the
long-standing, previously-shipped routines touched (`ARRSYM_*`,
`CSYM_*`, `STRSYM_*`, `OP_ARR_LOAD`/`STORE`, `OP_DIM`) changed
observable behavior — only internal structure.

### 11.5 Exact ROM/RAM accounting (final, this phase)

| | HOME free | EXROM free |
|---|---:|---:|
| Before this phase (end of item 10) | 705 B | 2,194 B |
| After string arrays, before shrink | −317 B (overflow) | 2,194 B |
| After the shrink pass (11.4) | **2 B** | 2,194 B |
| After array SAVE/LOAD (EXROM-only) | 2 B | **1,743 B** |

String arrays cost **1,022 bytes HOME** net (705 → −317, i.e. the
feature's own raw cost before any shrink), entirely recovered plus a
tiny reserve by the shrink pass. Array SAVE/LOAD cost **0 bytes HOME**
(only the `ARENA_ALLOC_*` extraction touched HOME, and that was net
size-neutral-to-negative) and **451 bytes EXROM** (`V2_SAVE_ARRAY`/
`V2_LOAD_ARRAY`/`V2_SCAN_ARRAY_NAME` plus the new error messages and
RAM-cell declarations). RAM cost: `STRARR_PTR_TABLE` (16 B, fixed) +
`STRARRSYMTAB` (96 B, compile-time-only) + `V2_ARRAY_NAME_PTR/LEN/
IS_STR/INDEX`/`V2_RECEIVE_DEST` (7 B, EXROM shell scratch) — no RAM
region grew unboundedly; the array arena itself still costs nothing
fixed (borrows real `ARRAYS_END..VARS_START` headroom exactly as item
10 established).

**HOME's 2-byte reserve is genuinely thin** — any further HOME-resident
addition (the pending case-insensitivity work, the deferred capacity
increases) needs either a fresh shrink pass or to land entirely in
EXROM/RAM. This is flagged explicitly, not discovered as a surprise
later.

### 11.6 Tests performed and results

- New automated test `rom/test_v2_string_arrays.asm`: `DIM A$(3,8)`,
  element assignment with truncation (a 13-char literal assigned to a
  width-8 element correctly truncates to 7 content bytes), element
  read into a plain scalar, a second independent string array (proving
  `STRARR_PTR_TABLE` slot independence) — real ZEsarUX PASS.
- New automated test `rom/test_v2_array_save_load.asm`: `DIM A(5)`,
  five distinct element values, `ARRSYM_LOOKUP` resolution, real
  `STORAGE_SAVE` (fake transport), arena reset (same `NEW`/`CLEAR`
  reset path), real `STORAGE_LOAD` straight into the arena's own free
  space, real `ARENA_ALLOC_NUMERIC` commit, byte-for-byte verification
  of all five elements — real ZEsarUX PASS.
- `rom/test_v2_ext_demo.asm` migrated from the flat 16K single-bank
  test convention to the shared two-bank production-shaped harness
  (the string-array work grew vm_core+compiler enough to overflow its
  old flat image by 190 bytes with zero TRIADD-relevant content to show
  for it) — same migration 14 other tests already received in the
  post-R9 test-infrastructure milestone; real ZEsarUX PASS, unchanged
  TRIADD test logic.
- Full standalone regression suite: **23/23 PASS** (was 21/21 at the
  start of this phase; +string_arrays, +array_save_load).
- `make check`: pass (0 errors, 0 warnings), full production build
  succeeds (`make build`).
- Real production-ROM validation via `ts2068-debug`/ZEsarUX (not the
  test harness — the actual shipped `rom/v2_home.asm`/`rom/v2_exrom.asm`
  build, typed live through the real editor/shell):
  - String arrays: `DIM A$(3,8)` / `A$(0)="HELLO"` / `PRINT A$(0)` →
    printed `HELLO` correctly.
  - `SAVE "x" ARRAY A`: real `DIM A(5)` + assignments + `RUN`, then
    `SAVE "x" ARRAY A` → reached real `STORAGE_SAVE`, completed with
    `SAVED` (observed the real per-edge border-flicker tape-pulse
    signal during the operation, then the clean success message).
  - `LOAD "x" ARRAY A` grammar/validation: confirmed the write-once
    policy live — loading into an already-populated array correctly
    rejects with `ARRAY ALREADY SET`; loading into a declared-but-
    never-run array (`DIM A(5)` reached via compile but skipped at
    runtime via a leading `STOP`, confirmed `ARR_PTR_TABLE[0]=0` via
    direct memory read beforehand) correctly dispatches into real
    `STORAGE_LOAD` and sits waiting for a leader tone, exactly as
    `LOAD`'s own existing, already-proven behavior does for programs.
  - **Not performed**: a full physical/audio tape *round-trip* for
    `LOAD ARRAY` specifically (would need a real captured pulse stream
    played back, beyond a headless ZRCP session's reach without
    dedicated audio-loopback infrastructure) — the identical underlying
    transport was already proven in a real physical round-trip for
    *programs* in R9, and the array-specific receive/parse/commit logic
    on top of it is fully verified by the automated fake-transport
    roundtrip test (11.6, second bullet), which exercises the exact
    same `STORAGE_LOAD`/`ARENA_ALLOC_NUMERIC` code path. Flagged as a
    deliberately deferred, lower-value manual check, not a known defect.

### 11.7 Deliberately deferred (unchanged or newly noted)

- 2-D numeric/string arrays, `DATA`/`READ`/`RESTORE` — unchanged scope
  boundary, not attempted.
- Decompiler support for `OP_DIM`/`OP_DIM_STR`/`OP_ARR_LOAD`/`STORE`/
  `OP_STRARR_LOAD`/`STORE` — unchanged carried-forward gap from item 10,
  now also covering the three new string-array opcodes.
- A genuine physical/audio tape round-trip specifically for `LOAD
  ARRAY` (see 11.6) — deferred to a grouped manual validation pass,
  same convention item 1's own test-infrastructure note already
  established for Fuse-dependent runs.
- **Capacity increases** (numeric scalars 16→32, string scalars 4→8,
  recursion depth 6→12): explicitly NOT implemented this phase, per
  direct instruction — HOME's current 2-byte reserve makes this
  strictly a RAM-relocation exercise (several existing compile-time/VM
  tables do not fit their enlarged size in place and would need to
  move), and the architecture question of whether fixed relocation,
  compaction, or a more dynamic allocation scheme is the right
  long-term answer is explicitly being held open for a deliberate
  decision rather than a mechanical bump.

## 12. BASIC case-insensitivity (2026-10-03)

Physical ROM testing exposed that `PRINT 10` worked but `print 10` did
not, and uppercase `I` was recognized while lowercase `i` was not. This
phase makes V2 BASIC fully case-insensitive for keywords and identifier
identity — `PRINT`/`print`/`Print`/`pRiNt` are equivalent; `Counter`/
`counter`/`COUNTER` name the same variable — while the authoritative
source text is left untouched, so `LIST`/`EDIT` still show exactly what
was typed.

### 12.1 Tracing the authoritative source → bytecode chain

Source text → `LEX_NEXT_TOKEN`/`LEX_SCAN_IDENT` (rom/exrom_v2_compiler.
asm) → `LEX_CLASSIFY_KEYWORD`/`BUILTIN_FN_FIND` → the compile-time
symbol tables (`CSYMTAB`/`STRSYMTAB`/`ARRSYMTAB`/`STRARRSYMTAB`/
`LABELTAB`, each with its own `FIND_OR_CREATE`/`LOOKUP`) → emitted
bytecode (symbol *indices* only, never names) → the VM (`rom/exrom_v2_
vm_core.asm`), which never sees source text or case at all. The VM
needing no change at all was confirmed immediately: it operates purely
on indices into `SYMTAB_BASE`/`STRTAB_BASE`/`ARR_PTR_TABLE`/
`STRARR_PTR_TABLE`, resolved once at compile time.

### 12.2 Design arrived at (after two rejected approaches)

**First attempt (rejected, broke real regression)**: canonicalize each
identifier into a single shared fixed uppercase buffer the moment it is
lexed, and repoint `TOK_NAME` at that buffer so every downstream
consumer sees already-folded bytes for free. This is architecturally
the cleanest "narrowest common normalization point" — but it broke
nested-compile recursion for real: several call sites (`STASH_IDENT_
AND_PEEK`'s `STMT_IDENT_NAME_PTR`, the `DEF FN` nested-call parking
around `COMPILE_EXPR`) save `TOK_NAME`'s own *pointer value* across a
later `LEX_NEXT_TOKEN` call and expect the pointed-to bytes to still be
valid afterward. That is true when `TOK_NAME` points into the immutable
source text (the pre-existing design) and false the moment it points
into one shared, repeatedly-overwritten buffer — the very next
identifier scan corrupts the "saved" name. Caught by a dedicated new
regression test (`rom/test_v2_proc_recursion.asm` started failing with
`COMPILE_ERROR_CODE=7`, undefined label, after this change) before it
was ever committed.

**Second attempt (rejected, corrupted digits and `$`)**: having
reverted to comparison-time folding, the first version used a blind
`and $DF` wherever two name bytes needed comparing. `and $DF` clears
bit 5 — correct for letters, but `'$'` (`0x24`) and every decimal digit
(`0x30`-`0x39`) also have bit 5 set, so a blind fold silently corrupts
them. This broke two real things, both caught by the regression suite
before commit: `kernel/extensions/ext_registry.asm`'s `EXT2_LOOKUP`
uses `"LPRINT$"` as an internal registration name (the real,
constant-text name for `LPRINT`'s string-argument overload) — folding
its own `'$'` byte made it permanently fail to match itself
(`printer_module` test: `COMPILE_ERROR_CODE=32`, "package not loaded").
Separately, any identifier containing a digit (e.g. the decompiler's
own synthesized `"V0"`/`"L25"` names, or a plain user variable like
`A1`) would have had its digit corrupted mid-comparison, risking false
mismatches — caught in the `group6_math` test (`border=2`, wrong
computed values) once digit-bearing comparisons were exercised.

**Final design**: `TOK_NAME` keeps pointing at the real, immutable
source text everywhere, exactly as before this phase — zero change to
the pointer-stability contract every existing call site already
depends on. Case-folding happens only *at the point of comparison*, via
a new shared `FOLD_UPPER` routine (rom/exrom_v2_compiler.asm): `A -> A`
folded to uppercase if, and only if, it is currently `'a'-'z'`; every
other byte (digits, `$`, punctuation) passes through completely
unchanged. This mirrors the project's own already-proven `V2_MATCH_
PREFIX`/`V2_MATCH_EXACT` pattern (rom/exrom_v2_shell.asm), which had
used exactly this conditional-fold shape all along. `FOLD_UPPER` is
called at every name-equality comparison: `LEX_CLASSIFY_KEYWORD`,
`BUILTIN_FN_FIND`, and each of `CSYM_FIND_OR_CREATE`/`STRSYM_FIND_OR_
CREATE`/`ARRSYM_FIND_OR_CREATE`+`LOOKUP`/`STRARRSYM_FIND_OR_CREATE`+
`LOOKUP`/`LABEL_DEFINE`+`LABEL_LOOKUP`'s own compare loops (the latter
five fold *both* operands, since names are stored verbatim as typed, so
either side can carry arbitrary case). `kernel/extensions/ext_registry.
asm` carries its own tiny local copy, `EXT2_FOLD_UPPER` — deliberately
duplicated rather than cross-called, because this file is sometimes
included without `rom/exrom_v2_compiler.asm` at all (`rom/test_v2_vm_
milestone01.asm`, a VM-only test with no compiler), where a cross-file
call would leave `FOLD_UPPER` undefined.

One more real bug surfaced only once a dedicated test tried lowercase
*keywords specifically* (not just identifiers): `LEX_SCAN_IDENT`'s own
internal character-classification loop already accepted `'a'-'z'` (the
first, uncontroversial part of this fix), but `LEX_NEXT_TOKEN`'s own
*outer dispatch* — the code deciding whether to call `LEX_SCAN_IDENT`
at all — had a separate, never-touched `cp 'A'`/`cp 'Z'+1` gate that
only routed *uppercase*-led tokens into the identifier scanner at all.
A lowercase-led token (e.g. `print`, `counter`) hit this gate's
`.unknown` fallback instead and was silently chopped into one-character
`TOK_UNKNOWN` tokens — this was the actual, original reported defect
("`PRINT 10` works but `print 10` does not"), and it survived
undetected through this phase's first two attempts because neither
attempt's own regression coverage ever exercised a lowercase-*led*
token (every existing regression test's `SOURCE_TEXT` is uppercase).
Fixed with the same safe, range-test-only blind fold `LEX_SCAN_IDENT`'s
own loop already used (this is a pure routing decision, not an equality
compare, so the blind form is safe here — see `FOLD_UPPER`'s own header
for why that distinction matters).

### 12.3 What is NOT case-folded, and why that's correct

- The **stored** name bytes in every symbol table remain exactly as
  first typed (verbatim) — only the *comparison* folds case. This is
  intentional, not a shortcut: the decompiler never reads these stored
  names back for display (it synthesizes generic `V<n>` names instead,
  an established, separate, already-documented limitation), so there is
  no user-visible inconsistency from leaving storage un-canonicalized,
  and it avoids ever needing to canonicalize at creation time.
- `V2_KW_DETECT_SPANS` (EXROM, editor keyword-bolding for already-
  settled lines) uses a blind `and $DF` in its own word-boundary scan
  and compare — safe specifically because `.wordlen` only continues a
  "word" for actual letters (digits/`$`/punctuation always end it), so
  a word reaching the compare loop is guaranteed letter-only by
  construction; no digit or `$` byte is ever folded there.
- `V2_SCAN_ARRAY_NAME`'s own fold-into-`V2_ARRAY_NAME_CANON` copy (EXROM)
  already used the safe conditional form from the start (range-checked
  before folding), since array names can contain digits.

### 12.4 New regression test

`rom/test_v2_case_insensitive.asm` (added to `tools/run_v2_standalone_
tests.sh`'s `migrated_names`) exercises, in one compiled-and-executed
program: a plain numeric scalar referenced under two different
capitalizations; a digit-containing scalar name (`a1`/`A1`, the exact
shape the second rejected attempt would have corrupted); mixed-case
`if`/`then`/`else`/`ENDIF` in one statement; a lowercase built-in
function name (`upper$`); a numeric array DIM'd lowercase and indexed
uppercase; a string array likewise; `PROC`/`CALL` under different
capitalizations (exercises `LABEL_LOOKUP`'s own fold); and `DEF FN`
likewise. Each check calls the real `CSYM_FIND_OR_CREATE`/`STRSYM_
FIND_OR_CREATE` routines itself with a known (uppercase) name — a
second, independent exercise of the same fold logic the compiler used
while compiling `SOURCE_TEXT` — rather than predicting the compiler's
own first-use index-assignment order by hand. `CSYM_COUNT`/`STRSYM_
COUNT`/`ARRSYM_COUNT`/`STRARRSYM_COUNT` are also checked against the
exact number of distinct names actually used in the source, so a case
variant that silently failed to fold (and so created a *second*,
separate symbol) would be caught even if its value happened to look
plausible.

### 12.5 Validation

- Full regression suite: **24/24 PASS** on real ZEsarUX (23 prior tests
  + the new `case_insensitive` test), including re-verification after
  each of the two rejected designs was caught and reverted.
- Real production-shell validation (`build/ts2068rom_zesarux.bin` via
  `ts2068-debug`): typed `print "abc"` (lowercase keyword) through the
  real full-screen editor — the word was correctly bolded by `V2_KW_
  DETECT_SPANS` despite its lowercase spelling, and `RUN` printed `abc`
  correctly, confirming the fix end to end through the real shell, not
  only the compiler-level test harness.
- Editor keyword-highlighting (`V2_KW_DETECT_SPANS`) fixed as part of
  this phase (EXROM, cosmetic — was case-sensitive, matching the user's
  explicit test-matrix requirement to check it).

### 12.6 Exact ROM/RAM accounting

| | HOME free | EXROM free |
|---|---:|---:|
| Before this phase (end of item 11) | 2 B | 1,743 B |
| After the pre-fix HOME-budget shrink pass (`VM_PUSH_STR_RESULT`, `STASH_IDENT_AND_PEEK`) | 80 B | 1,743 B |
| Fixing a real stack-corruption bug found in that shrink pass (`VM_PUSH_STR_RESULT`'s `OP_STRARR_LOAD` call site) | 75 B | 1,743 B |
| After the case-insensitivity fix itself (final, all 3 bugs found/fixed) | **4 B** | **1,708 B** |

The case-insensitivity fix itself cost a net **71 bytes HOME** (75 → 4)
and **35 bytes EXROM** (1,743 → 1,708: `V2_SCAN_ARRAY_NAME`'s fold-copy
and `V2_KW_DETECT_SPANS`'s fix). No RAM layout changed — `FOLD_UPPER`/
`EXT2_FOLD_UPPER` are pure code, no new persistent storage. **HOME free
is now only 4 bytes** — positive, so the build is valid, but this is an
extremely thin margin: essentially any further HOME-resident addition,
however small, will need either a dedicated shrink pass first or EXROM
relocation. This is flagged here explicitly as a risk for whoever picks
up the next phase of work, rather than papered over.

A fork-based candidate search for further shrink headroom was
deliberately NOT performed as part of closing out this margin, per
direct instruction not to "perform risky broad optimization merely to
obtain a few bytes" — the three bugs found and fixed while building
this very feature are themselves a caution against further mechanical
changes in this exact area without a fresh, dedicated pass.

## 13. Dedicated HOME ROM headroom-recovery pass (2026-10-03)

HOME free was down to 4 bytes after item 12 (case-insensitivity) — the
immediately preceding phase's own fix, not a separate problem, but one
severe enough to need its own dedicated pass before any further
HOME-resident work could safely proceed at all. Per direct instruction,
this pass added **no new language features or capacity increases** —
its sole goal was to recover meaningful (not just-enough-for-one-patch)
HOME headroom via provably-safe transformations, prioritizing safety
over cleverness given item 12's own build process had just produced a
real stack-corruption bug (`VM_PUSH_STR_RESULT` called via `call`
instead of `jp`).

A read-only research pass (fork agent, using `make budget`/`tools/
report_rom_map.py`-derived module sizes plus direct `.lst`/`.sym`
address evidence) produced a ranked candidate list, explicitly
re-auditing every HOME routine for the exact stack-surgery-assuming-
caller-prepared-state bug shape that caused the earlier regression
(found none beyond the already-fixed `VM_PUSH_STR_RESULT`, and
confirmed all 8 of its call sites already correctly use `jp`). Six
candidate categories were applied; all were built, budget-checked, and
regression-tested (fully, all 24 tests on real ZEsarUX) incrementally,
exactly matching each transformation's own hand-computed byte estimate
before being accepted as final.

### 13.1 Accepted optimizations

| # | Subsystem/routine | Transformation | HOME bytes | Validation |
|---|---|---|---:|---|
| S1 | 14 sites across `kernel/math/math.asm`, `rom/exrom_v2_vm_core.asm`, `rom/exrom_v2_compiler.asm` | `jp LABEL` → `jr LABEL` (unconditional) at every site whose target the assembler confirmed falls within ±127 bytes | +14 | Clean assemble (sjasmplus itself rejects an out-of-range `jr`, so this is self-verifying); full regression suite |
| S2 | 3 sites (`VM_ERR_DIVIDE_BY_ZERO`, `COMPILE_DIM_STR`, `COMPILE_STRARR_ASSIGN` targets) | `jp cc,LABEL` → `jr cc,LABEL` (conditional), same in-range rule | +3 | Same as S1 |
| S3 | 6 sites in `rom/exrom_v2_compiler.asm` (built-in-fn-call paren/comma/rparen errors, string-factor unexpected-char, LPRINT-not-loaded, string-IF comparison-operator) | Inline `ld (COMPILE_ERROR_CODE),a` + `ret` pairs (A already holding the error code, matching the existing `COMPILE_RAISE_ERROR` precondition used elsewhere in this same file) replaced with `jp COMPILE_RAISE_ERROR` | +6 | Full regression suite; `COMPILE_RAISE_ERROR` itself does only a plain store+ret, no stack manipulation, so reaching it via `jp` from anywhere is safe by construction |
| S4 | `COMPILE_IF_BLOCK`'s own THEN/ELSE "expected ELSE or ENDIF" error paths, 2 sites | A `pop hl`/`ret` pair immediately preceding an identical `.err_popN: pop hl`/`ret` label was dead fallthrough code — deleted, letting control fall through into the existing label | +4 | Full regression suite; removes byte-identical dead code only, no target changed |
| S5 | 8 sites across `rom/exrom_v2_compiler.asm` (DEF FN/PROC name parsing, CALL, numeric/string identifier statements, array name scans) | The repeated "clamp identifier length to 8" shape (`cp 9 / jr c,X / ld a,8 / X:`) factored into one shared `CLAMP_LEN8` routine (`cp 9 / ret c / ld a,8 / ret`), each site replaced with `call CLAMP_LEN8` | +18 | Full regression suite; pure register-in/out helper, no flags/stack assumptions beyond ordinary call/ret |
| N1 | `CSYM_FIND_OR_CREATE`, `STRSYM_FIND_OR_CREATE`, `ARRSYM_SCAN`, `STRARRSYM_SCAN`, `LABEL_LOOKUP` (5 sites) | The case-insensitive compare loop item 12 had added independently to each of these 5 routines (`ld a,(de) / call FOLD_UPPER / ld c,a / ld a,(hl) / call FOLD_UPPER / cp c / jr nz,.cmp_fail / inc hl / inc de / dec b-or-djnz`, ~16-17 bytes each) factored into one shared `NAME_CMP_FOLD` routine (returns via `ret`/`ret nz`, Z flag reflects match, HL/DE land one past the last compared byte on match or at the mismatch pair otherwise — identical observable behavior to the original inline loops). Each site now does `push bc / call NAME_CMP_FOLD / jr nz,.cmp_fail / pop bc / pop hl / jr <success>`, the surrounding `push bc`/`pop bc`/`.cmp_fail:` blocks (already present, unique per site) left untouched | +42 | Full regression suite, including `dynamic_arrays`/`string_arrays`/`array_save_load`/`case_insensitive`/`proc_recursion`/`deffn` (each exercises a different one of the 5 consolidated sites); `NAME_CMP_FOLD` does no stack surgery of its own (ordinary `call`/`ret`), so it is NOT the `VM_PUSH_STR_RESULT` bug shape — the caller's own `push bc`/`pop bc` around the `call` is unaffected either way |

**Net: +87 bytes HOME recovered (4 → 91 bytes free)**, zero EXROM or
RAM changes, across 6 independent, individually-verified groups. Each
group's actual measured byte delta (via `make budget` before/after)
matched its own hand-computed estimate exactly before being accepted —
no group was accepted on an estimate alone.

### 13.2 Investigated and rejected

- **N2 — relocating `GFX_PUTCHAR_BOLD`/`GFX_INVERT_ATTR` to EXROM**:
  both routines (kernel/graphics/graphics.asm, ~15 and ~8 bytes) are
  called only from EXROM-resident code (`rom/exrom_v2_shell.asm`/`rom/
  exrom_editor.asm`) via `include/v2_ktab.inc`'s hand-maintained,
  *positional* `V2_KTAB_LIST` (`V2_KTAB_INDEX` auto-increments per
  entry, so removing or reordering any one entry shifts every
  subsequent entry's own fixed address). `rom/v2_package_graphics.asm`
  — an independently-assembled, separately-distributed TZX extension
  binary — calls into HOME through exactly this table. Moving the
  routine bodies into EXROM is mechanically straightforward (both
  callers execute only while EXROM is already paged in, so a same-bank
  `call` needs no `BANK_PAGE_EXROM_IN`/`OUT` around it), but the ABI
  risk to an already-distributed consumer binary is real, and the
  payoff (under ~25 bytes combined) does not justify it. Rejected,
  matching the task's own explicit guidance not to pursue a real ABI
  risk for a small gain.
- No dead/unreachable **code** was found anywhere in the HOME image
  (kernel/*, `rom/exrom_v2_vm_core.asm`, `rom/exrom_v2_compiler.asm`):
  a whole-repo exact-match cross-reference (including `tools/
  write_v2_crossbank.py`'s `NAMES` list and `include/v2_ktab.inc`'s own
  `V2_KTAB_LIST`, both call-by-name mechanisms a naive grep could miss)
  found only 7 unreferenced `equ` constants, which emit zero bytes into
  the assembled image regardless. This category yielded no candidate.
- No tail-call (`call X; ret` → `jp X`) opportunities were found: every
  `call X` immediately followed by a `ret` in the three largest HOME
  files uses a *conditional* `ret c`/`ret nz` instead (real
  fall-through logic follows), so none qualify.
- `kernel/memory`, `kernel/io`, `kernel/math` (beyond S1's one branch
  site), `kernel/sound`, `kernel/interrupt`, `kernel/bank` were
  inspected and found too small (54-788 bytes each) and free of
  duplication to be worth a dedicated pass.
- A second, deeper pass specifically through `rom/exrom_v2_vm_core.asm`'s
  own ~5,000 lines of opcode-handler bodies (beyond the `FOLD_UPPER`/
  `CLAMP_LEN8`-adjacent grep already done) was flagged by the research
  agent as a plausible source of further `N1`-style duplication, but
  was not pursued — 91 bytes free is a useful, non-trivial reserve, and
  further mechanical changes in this exact area immediately after two
  real regressions (the `VM_PUSH_STR_RESULT` stack-corruption bug and
  this same session's own two case-insensitivity design reverts) were
  judged not to be worth the risk without a specific further need.

### 13.3 Exact ROM/RAM accounting

| | HOME free | EXROM free |
|---|---:|---:|
| Before this phase (end of item 12) | 4 B | 1,708 B |
| After S1 (jp→jr, unconditional, 14 sites) | 18 B | 1,708 B |
| After S2 (jp cc→jr cc, 3 sites) | 21 B | 1,708 B |
| After S3 (error-path → `COMPILE_RAISE_ERROR`, 6 sites) | 27 B | 1,708 B |
| After S4 (dead fallthrough removal, 2 sites) | 31 B | 1,708 B |
| After S5 (`CLAMP_LEN8`, 8 sites) | 49 B | 1,708 B |
| After N1 (`NAME_CMP_FOLD`, 5 sites) | **91 B** | 1,708 B |

No RAM layout changed (`CLAMP_LEN8`/`NAME_CMP_FOLD` are pure code, no
new persistent storage). Full regression suite: **24/24 PASS**,
verified after S1+S2 together, again after S3+S4+S5 together, and again
after N1 — three full real-ZEsarUX runs across this phase, plus the
individual byte-delta check after every one of the 6 groups.

No performance-sensitive tradeoff was accepted: S1/S2 are a pure
opcode-size reduction with no behavior change (branches now 2 bytes
instead of 3, same target); S3/S4/S5/N1 each replace an inline sequence
with a `call`/`jp` to an equivalent shared routine, adding a few Z80
cycles of call/return overhead to compile-time-only paths (lexing,
symbol lookup, DIM/CALL/error handling) — none of these are hot VM
execution-time paths, so no runtime (post-compile) performance is
affected at all.

## 14. Dormant-ROM audit: applying the SAFE/LOW-risk candidates + two correctness fixes (2026-10-03)

Following on from the read-only audit (`docs/R10_7_DORMANT_ROM_
CONSOLIDATION_AUDIT.md`), this phase applied only the SAFE/LOW-risk
dead-code and duplicate-code candidates it identified, plus fixed the
two correctness defects the audit incidentally found. D3/D4/D5 (the
MEDIUM/MEDIUM-HIGH-risk candidates) were explicitly NOT implemented,
per instruction.

### 14.1 Dead production ROM removed

| Routine(s) | File | Bytes | Notes |
|---|---|---:|---|
| `MEM_LABEL_FIND`/`LOOKUP`/`ADD`/`REMOVE` + `MEM_LABEL_TABLE_CLEAR` | `kernel/memory/memory.asm` | 292 | V1's own runtime label table (line-position label rewriting); V2 has its own, separate compile-time `LABELTAB`. `rom/test_memory.asm`'s own `TEST_MEM_LABEL_ROUNDTRIP` (its only other consumer) was retired alongside it — it tested the obsolete V1 mechanism itself, not a capability V2 needs. |
| `STICK_READ`, `IO_ANY_KEY_DOWN`, `IO_CHECK_BREAK` | `kernel/io/io.asm` | 67 | V1-only joystick/break-polling routines, never grown into a V2 BASIC feature. `IO_ANY_KEY_DOWN`'s one real consumer (`rom/test_io.asm`, a manual/interactive, never-automated smoke test) got its own local inlined copy (`TEST_ANY_KEY_DOWN`) so that test still assembles and still verifies the same real capability. |
| `BANK_CALL_EXROM` | `kernel/bank/bank.asm` | 8 | Convenience wrapper whose only caller was an orphaned early isolation test (`rom/test_exrom_isolation.asm`, not part of any Makefile target or test script); inlined there locally (`TEST_BANK_CALL_EXROM`) rather than deleted outright. |

**Subtotal: 367 bytes.**

**Important correction to the original audit**: the audit's 3
`kernel/graphics/graphics.asm` sprite-routine findings (`GFX_SPRITE_
TRANSFER`, `GFX_SPRITE_BOUNDS_CHECK`, `GFX_SPRITE_INVALIDATE`, ~137
bytes claimed) were **all false positives**, caught during this
session's own pre-deletion verification (not left for a later surprise):
`GFX_SPRITE_BOUNDS_CHECK` is called internally by the live `GFX_SPRITE_
SETUP` (a plain `call`, same file); `GFX_SPRITE_TRANSFER` is reached via
`jr` tail-jumps from the live `GFX_SPRITE_CAPTURE`/`DRAW` (not a `call`,
which is exactly the shape a naive "grep for `call X`" search misses);
`GFX_SPRITE_INVALIDATE` is called 4 times from elsewhere in the very
same file the audit searched (the audit's own cross-reference had
excluded the defining file itself when checking for callers — a real
methodology gap). All 3 were confirmed live and **none were removed**.
This is exactly the caution the task's own instructions asked for
("account for indirect calls... do not classify code as dead solely
because a simple text search finds no direct caller") — caught before
any deletion, not after a broken build.

### 14.2 Duplicate-code consolidations applied

| ID | Routine | File | Bytes | Risk |
|---|---|---|---:|---|
| D1 | `PUSH_INT_CONTINUE` (new), replacing 21 duplicated `xor a/call VM_PUSH/jp VM_RUN.loop` opcode-handler tails | `rom/exrom_v2_vm_core.asm` | +77 | SAFE — pure tail-jump, no stack surgery |
| D2 | `VM_POP_CHECK_INT` (new), replacing 6 duplicated `call VM_POP/cp TAG_INT/jp nz,VM_ERR_ARRAY_TYPE` sequences | `rom/exrom_v2_vm_core.asm` | +21 | SAFE — ordinary call/ret |
| D6 | `EXT2_FOLD_UPPER` (byte-for-byte duplicate of `FOLD_UPPER`) removed; `EXT2_LOOKUP` now calls the shared `FOLD_UPPER` directly; `rom/test_v2_vm_milestone01.asm` (the one build that includes `ext_registry.asm` without the compiler) got its own local `FOLD_UPPER` stub | `kernel/extensions/ext_registry.asm` | +9 | LOW-MEDIUM |
| D7 | `COMPILE_STR_FACTOR.ident` preserves the already-computed clamped length across `STRARRSYM_LOOKUP` (`push bc`/`pop bc`) instead of recomputing `CLAMP_LEN8` a second time | `rom/exrom_v2_compiler.asm` | +5 | SAFE |
| D8 | `COMPILE_ARR_ASSIGN_COMMON`'s two `ld a,N/ld (COMPILE_ERROR_CODE),a/jr .err_pop` sites share one `.raise_err:` fall-through | `rom/exrom_v2_compiler.asm` | +3 | SAFE |

**Subtotal: 115 bytes.**

All 5 were applied one at a time, each verified with a clean build, an
exact-match byte-delta check against its own hand-computed estimate
before being accepted, and the full regression suite (24/24, then
25/25 once item 14.3's new test was added).

### 14.3 Two correctness bugs fixed

**DIMN case-insensitivity** (`rom/exrom_v2_compiler.asm`,
`COMPILE_FACTOR.ident`): the hand-rolled "DIMN" keyword compare (`ld
a,(de)/cp (hl)`, no fold) was missed when every other name-compare site
in this file got `FOLD_UPPER` during item 12. Fixed by swapping the
`HL`/`DE` roles and adding `call FOLD_UPPER` on the source-text side,
exactly mirroring `LEX_CLASSIFY_KEYWORD`'s own already-proven pattern
(`DIMN_KEYWORD_TEXT` is a constant, already uppercase, so a single-side
fold is correct — no new independent comparison logic was invented).

**Identifier-length consistency** — broader than originally audited.
The audit reported `COMPILE_DIM` clamping names to 8 characters while
`COMPILE_FACTOR.ident`'s array-read path and `COMPILE_ARRAY_ASSIGN`
didn't, so a long array name could `DIM` successfully but then fail to
be found again. **Verification found the same missing-clamp bug at 3
more sites**, including one the audit never flagged at all:
`COMPILE_DIMN` itself (so `DIMN(longname)` had the identical failure
mode), and — the genuinely new discovery — `COMPILE_STR_ASSIGN_
CONTINUED` and `COMPILE_STRARR_ASSIGN`, meaning **string scalars**, not
just arrays, had the same inconsistency (a long string-scalar name could
be assigned but then fail to resolve back to the same symbol on a
later read, which itself already clamps via `COMPILE_STR_FACTOR.ident`).

**Semantics, now applied consistently everywhere and documented**: V2
identifiers are significant to exactly 8 characters — the same rule
`CSYM_FIND_OR_CREATE`'s own header has documented since R2 ("longer
names are truncated to 8 by the caller before this is reached"). Two
names that clamp to the same 8-character prefix are the same symbol;
this is pre-existing, intentional, documented behavior, not a new
policy. All 5 missing sites now call the existing shared `CLAMP_LEN8`
routine — no new comparison or truncation logic was written.

ROM cost: 5 new `call CLAMP_LEN8` sites (3 bytes each) + the DIMN fold
fix (`call FOLD_UPPER`, 3 bytes, replacing nothing) = **19 bytes total**
(this is a correctness fix, not a shrink — a small HOME cost here is
expected and acceptable, per instruction).

New regression test: `rom/test_v2_identifier_length.asm` (added to
`tools/run_v2_standalone_tests.sh`) exercises DIMN with a mixed-case
array-name argument and a lowercase `"dimn"` keyword; a numeric array
and a string array each DIM'd/assigned/read under different
capitalizations with a >8-character name; a string *scalar* assigned
and read under different capitalizations with a >8-character name (the
newly-discovered gap); and two distinct 9-character names
(`longpfxaa`/`longpfxab`) that clamp to the same 8-character prefix,
confirming they resolve to one shared symbol (the last write wins, read
back through either spelling) — the documented truncation-collision
behavior, exercised explicitly rather than left implicit.

### 14.4 Exact ROM/RAM accounting (this phase)

| | HOME free | EXROM free |
|---|---:|---:|
| Before this phase (end of item 13) | 91 B | 1,708 B |
| After dead-code removal (14.1) | 458 B | 1,708 B |
| After D1 | 535 B | 1,708 B |
| After D2 | 556 B | 1,708 B |
| After D6 | 565 B | 1,708 B |
| After D7 | 570 B | 1,708 B |
| After D8 | 573 B | 1,708 B |
| After both correctness fixes (14.3) | **554 B** | 1,708 B |

**Net for this phase: +463 bytes HOME free (91 → 554)** — 367 bytes
from verified-dead-code removal, 115 bytes from 5 SAFE duplicate-code
consolidations, minus 19 bytes spent fixing two real correctness bugs
found along the way. No RAM layout changed anywhere in this phase. Full
regression suite: **25/25 PASS** (24 prior tests + the new
`identifier_length` test), plus the pre-existing smoke-ROM suite
(`test_memory`/`test_math`/`test_editor_ops`/calc-smoke tests, 9/9
PASS) re-verified clean given this phase touched 3 of those shared
kernel files.

### 14.5 Rejected / deferred

- **D3** (array/string-array operand-fetch prologue consolidation in
  `rom/exrom_v2_vm_core.asm`, ~24 bytes estimated): not pursued —
  the audit's own "pending one easy check" (whether `VM_ARR_INDEX_TMP`/
  `VM_STRARR_INDEX_TMP` are ever live simultaneously) was not
  re-verified in this phase, and per instruction D3 was only to be
  attempted "if it proves completely mechanical during verification and
  has no register/lifetime ambiguity." Left for a future pass.
- **D4/D5** (compiler table-walk and `COMPILE_DIM`/`COMPILE_DIM_STR`
  skeleton consolidation, ~60-95 bytes combined): explicitly deferred
  per instruction — both need real design work, not mechanical
  extraction, and D5 in particular touches the exact code (`COMPILE_
  DIM`-family routines) where this very phase just found 2 real
  correctness bugs.
- The 3 `kernel/graphics/graphics.asm` "dead" sprite routines: not a
  deferral — confirmed live (14.1) and permanently removed from the
  candidate list, not merely postponed.

## Explicitly out of scope for this milestone (per instruction)

No capacity limit from item 5 was changed. No deferred larger feature
from item 6 was implemented. R11 was not begun. The API/ABI was not
frozen (all of items 1-3 are additive; no existing opcode, keyword, or
package contract changed shape). OUT/IN were audited, not implemented.
Case-insensitivity (item 12) is now complete and does not change this.
The HOME shrink passes (items 13-14) recovered headroom and fixed two
real bugs only — no new BASIC capability, no capacity increase, and
`$9455-$A455` was not touched. D3/D4/D5 remain deferred, not
implemented.
The HOME shrink pass (item 13) recovered headroom only — no new BASIC
capability, no capacity increase, and `$9455-$A455` was not touched.

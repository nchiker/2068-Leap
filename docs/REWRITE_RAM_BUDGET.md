# 2068-Leap V2 — Rewrite RAM Budget

Evidence classes: `VERIFIED`, `ESTIMATED` (formula/reasoning shown),
`ASSUMED`. RAM pool baseline: `VERIFIED` from `make budget` at commit
`77fdc1f`: **usable program/variable/array pool = 15,275 bytes**
(`0x8455-0xBFFF`) on a stock 48K machine — this is the actual constraint,
not the full 48K (screen memory, sysvars, stack, and buffers consume the
rest and are unaffected by language-core choice).

## The central RAM design decision a rewrite must make explicitly

A rewrite must decide what the *primary* program representation in RAM is.
The study brief warns against optimizing ROM while ignoring RAM; this
decision is exactly where that trade lives.

**Option 1 — source-primary, compile-on-RUN (transient bytecode).** Keep
source text as-is (V1's existing model, editor untouched); compile the
whole program to bytecode into a second buffer each time `RUN` executes,
discard it when the program stops or is edited. RAM cost = source text
(unchanged from V1) + a transient bytecode buffer sized to the whole
compiled program, present only while running.

**Option 2 — bytecode-primary, decompile-for-LIST/EDIT.** Store only
bytecode + a compact symbol table; `LIST`/`EDIT` reconstruct a canonical
textual rendering from the bytecode (a small decompiler/pretty-printer,
already costed at 300-500 ROM bytes in `REWRITE_VM_DESIGN.md`). This is a
real, explicit compatibility break — the user's exact typed spacing/layout
is not preserved verbatim, only a canonical re-rendering is — squarely
covered by this project's own compatibility-break policy (breaking V1
behavior is acceptable for a real, measured RAM/ROM saving).

**Option 3 — both, permanently.** Rejected outright: pays the full cost of
both representations at once, the worst of both options, no offsetting
benefit identified.

**This study recommends Option 2** for the reason the LARGE-program
worked example below makes concrete: Option 1's transient buffer can
exceed the 15,275-byte pool for realistically large programs, which Option
2 never does (bytecode is generated once and is the only copy that exists,
so total resident size never exceeds whichever representation is smaller —
and bytecode is measurably smaller, see below).

## A structural RAM win Option 2 provides that is easy to miss

Once identifiers compile to a symbol **index**, the *name* itself does not
need to be stored in the runtime symbol record at all — it only existed at
compile time, in a table that can be discarded once compilation finishes.
This means a rewritten numeric scalar record can be **smaller** than even
V1's *current* 6-byte record, not larger, despite supporting multi-character
names — the opposite of evolved-V1's outcome (`STRING_AND_SYMBOL_DESIGN.md`:
widening the *name field in place* costs +8 bytes/scalar, because V1's
in-place design has nowhere else to put the name). A compiled-index design
never pays a per-scalar name cost at runtime at all.

| Record | V1 today | Evolved-V1 (in-place name widen) | Rewritten V2 (compiled index, no runtime name) |
|---|---:|---:|---:|
| Numeric scalar | 6 bytes | 14 bytes (+8) | `ESTIMATED` ~3-4 bytes (tag + 2-byte value; no name field, no length count needed for a scalar) |
| String scalar (31-byte cap unchanged) | 36 bytes | 44 bytes (+8) | `ESTIMATED` ~36 bytes (tag + length + 31 content bytes + no name field, roughly a wash vs. V1) |

## Worked examples (`ESTIMATED` — representative, not measured .bas files)

Bytecode density is estimated from the compiler spike's own opcode sizes
(`REWRITE_VM_DESIGN.md`): a typical arithmetic statement like
`SCORE = SCORE + 10` compiles to `LOAD_VAR idx(2B) PUSH_I8 10(2B) ADD(1B)
STORE_VAR idx(2B)` = 7 bytes, versus ~19 bytes of source text — roughly
**35-40% of source size** for arithmetic-heavy code. This ratio is used
below; real programs with more comments/whitespace would compress further,
programs with long string literals less.

### SMALL (≈10 lines, 3 numeric scalars, one 100-element array, no strings)

| | V1 | Evolved-V1 | Rewritten V2 (Option 2) |
|---|---:|---:|---:|
| Program text/bytecode | 250 (text) | 250 (text) | ~95 (bytecode, 38% of 250) |
| Scalars | 3×6=18 | 3×14=42 | 3×4=12 |
| Array (100 ints + header) | 204 | 204 | 204 |
| **Total** | **472** | **496** | **~311** |

### TYPICAL (≈100 lines, 10 numeric scalars, 2 string scalars, light control flow)

| | V1 | Evolved-V1 | Rewritten V2 (Option 2) |
|---|---:|---:|---:|
| Program text/bytecode | 2,500 | 2,500 | ~950 |
| Numeric scalars | 10×6=60 | 10×14=140 | 10×4=40 |
| String scalars | 2×36=72 | 2×44=88 | 2×36=72 |
| **Total** | **2,632** | **2,728** | **~1,062** |

### LARGE (≈500 lines, 30 numeric scalars, 5 strings, 3 arrays)

| | V1 | Evolved-V1 | Rewritten V2 (Option 2) |
|---|---:|---:|---:|
| Program text/bytecode | 14,000 | 14,000 | ~5,320 |
| Numeric scalars | 30×6=180 | 30×14=420 | 30×4=120 |
| String scalars | 5×36=180 | 5×44=220 | 5×36=180 |
| Arrays (3×200 + headers) | 600 | 600 | 600 |
| **Total** | **14,960** | **15,240** | **~6,220** |

The LARGE case is the important one: at V1's density, a 500-line program
already consumes **98% of the 15,275-byte pool** — there is essentially no
headroom left for anything else running at the same time (no spare array
space, no room for a second large data structure). The rewritten,
bytecode-primary design uses **~41% of the same pool** for the same
program, leaving genuine working headroom.

**If Option 1 (transient compile-on-RUN buffer) had been used instead**,
the LARGE case would need text (14,000, kept) + a *second*, simultaneous
~5,320-byte bytecode buffer while running = ~19,320 bytes just for the
program+scalars+arrays, i.e. it would not fit in the 15,275-byte pool at
all. This is the concrete evidence behind this document's Option 2
recommendation — it is not a stylistic preference.

## Fixed RAM (sysvars, stack, buffers)

Not separately re-measured in this pass — no evidence found that any
architecture changes this component's size; it is a function of the kernel/
platform layer, which is unchanged (reused) across all three architectures
per `LANGUAGE_CORE_ROM_ANALYSIS.md`.

## Update after the statement-compiler spike (`STATEMENT_COMPILER_SPIKE.md`)

A hand-traced worked example compiling real control flow (a `FOR`/`IF...THEN
GOTO`/`CALL` fragment, not just arithmetic) measured **~78% smaller**
bytecode than source text — denser than this document's original 35-40%-
of-source estimate, because control-flow keywords (`FOR`, `THEN`, `GOTO`,
`NEXT`, `CALL`) and label names compile away entirely into single-byte
opcodes and zero-cost compiled offsets. Revised overall estimate: **20-40%
of V1 source size** depending on control-flow density (dense arithmetic-only
code compresses less, at the original 35-40% figure; branchy/control-flow-
heavy code compresses more, toward 20-25%). This makes the SMALL/TYPICAL/
LARGE worked-example RAM savings above, if anything, conservative — real
programs mixing arithmetic and control flow should land at least as well as
the figures already shown, not worse.

## Summary answer to the study's RAM question

A smaller-ROM interpreter is not automatically a RAM win — but in this
specific case, with the design decision made explicitly (bytecode-primary
storage, compiled-index symbols, no runtime name field), the rewritten
architecture is **both** a large ROM win (`REWRITE_ROM_BUDGET.md`) **and** a
substantial RAM win for typical-to-large programs, `ESTIMATED` at roughly
55-60% less RAM than V1 for the TYPICAL/LARGE cases above. The one
mandatory precondition is accepting the LIST/EDIT compatibility break
(canonical re-rendering instead of verbatim source), which this project's
own stated policy explicitly permits.

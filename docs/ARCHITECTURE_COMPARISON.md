# 2068-Leap V2 — Architecture Comparison

Subsystem-by-subsystem comparison of 2068-Leap (baseline) against
structured-basic-poc (reference/research implementation) and, where relevant,
2068-Forth (comparative data point on the same physical banking hardware).
structured-basic-poc is explicitly **not** assumed to replace 2068-Leap's
architecture — this document identifies what to back-port and, just as
importantly, what not to.

Evidence: structured-basic-poc figures are from its own `RESOURCE_BASELINE.md`
and ABI docs (`VERIFIED` against that repo's stated numbers, not independently
re-measured here). 2068-Leap figures are `VERIFIED` from a fresh `make budget`.
2068-Forth figures are `LIKELY` (from its `docs/CHANGELOG.md` and headers).

## Why structured-basic-poc exists

Its own `PROJECT_PLAN.md` states the thesis directly: *"The earlier Leap
development demonstrated the cost of allowing integer-only assumptions to
spread through parsing, expression evaluation, variables, printing, and
extension interfaces. This plan therefore makes the value ABI and floating
operations an early prerequisite."* It is explicitly a reaction to a known
2068-Leap shortcoming — but the fix it built is far heavier than a 24K/48K
target can absorb alongside 2068-Leap's existing feature set. The rest of this
document explains why, subsystem by subsystem.

## Numeric / value representation

| | 2068-Leap V1 | structured-basic-poc |
|---|---|---|
| Representation | 16-bit signed int (fast path) + separate 5-byte-float EXROM calculator (narrow, non-composable) | Uniform 6-byte tagged cell (`[tag][4-byte payload][exponent]`) for *everything* |
| Integer fast path | Yes — `MATH_UMUL16`/`MATH_UDIV16` | **No.** `VALUE_ABI.md`: *"Integer arithmetic fast paths are not implemented."* All four arithmetic ops always produce FLOAT regardless of input tags. |
| ROM cost | Calculator ~1931 EXROM bytes (already paid, already tested) | "the separate numeric implementation is 2,952 bytes" — built from scratch |
| Perf | Integer sieve ~6.3 frames/unit (real ZEsarUX benchmark) | float-only accumulate loop: 1120.775ms/100 iterations (no integer baseline exists, since none is implemented) |

**What problem it's solving:** genuinely general numeric semantics that don't
special-case any operation.
**How:** a uniform value representation, at the cost of never having a fast
integer path at all.
**Appropriate for 2068-Leap?** No, not as designed. 2068-Leap's whole value
proposition (per its own README) is "a fast all-integer arithmetic core for
everyday expressions" — adopting a design that has *no* integer fast path by
construction would directly undo that. **Ideas worth back-porting:** the
tagged-value *shape* (a small tag byte determining int vs. float) is a sound
technique; the *policy* of always promoting to float is not. See
`NUMERIC_DESIGN.md` for a hybrid that keeps 2068-Leap's existing int path
untouched and reuses its *existing* calculator (avoiding structured-basic-poc's
2,952-byte from-scratch cost almost entirely).
**Cost estimate for a smaller design:** roughly 300-500 ROM bytes (tag storage,
dispatch check, promotion glue) versus structured-basic-poc's 2,952 — because
2068-Leap does not need to build float representation or arithmetic from
scratch; it already has both.

## Strings and arrays (descriptors)

| | 2068-Leap V1 | structured-basic-poc |
|---|---|---|
| Storage | 26 fixed single-letter slots, 31-byte cap, no allocator | 2048-byte first-fit-with-coalescing heap arena, 6-byte reference descriptors, generation-based use-after-free protection, holder-qualified retain/release |
| Identifiers | Single letter only | Not directly comparable — the *descriptor* design is orthogonal to identifier length, but its module system does support multi-character names |
| ROM cost | ~383 EXROM bytes (existing string funcs) | string spike +709, allocator+ownership +576, Descriptor ABI 3 construction +663, numeric-array runtime +1082 = **≈3,000+ bytes**, all HOME-resident |
| RAM cost | 0 (fixed slots already counted in sysvars) | dedicated 2048-byte arena |
| Perf tax | None measured (fixed-slot access is O(1) direct index) | Ownership-check tax measured on *every* variable load/store, even for numeric-only programs: float_loop rose 1106.49→1120.775ms and procedures rose 319.76→357.87ms purely from the ownership machinery being wired in |

**What problem it's solving:** dynamic-length strings, arrays-of-strings,
safe sharing/aliasing across module boundaries, and reclaiming space.
**How:** a real reference-counted, generational heap allocator with explicit
retain/release accounting — genuinely correct, genuinely tested, and
genuinely heavy.
**Appropriate for 2068-Leap?** No — not at this cost or with this per-access
tax. 2068-Leap doesn't have a module-sharing/aliasing problem to solve (no
runtime-loadable module registry exists or is proposed for V2), so most of
what this design pays for (holder-qualified ownership across modules,
generation counters, cross-module retain/release) has no corresponding need.
**Ideas worth back-porting:** the *concept* of a small, bounded, length-
prefixed byte-string representation (structured-basic-poc caps strings at 255
bytes with a 1-byte length prefix) is reusable; the reference-counting/GC
machinery is not. **Ideas that should NOT be back-ported:** the reference-
counted/generational ownership system, the dedicated fixed arena, and the
per-load/store ownership check — their combined cost (≈3,000 ROM bytes + a
measured, permanent perf tax on non-string code) is larger than 2068-Leap's
*entire* current ROM headroom several times over. See
`STRING_AND_SYMBOL_DESIGN.md` for a "descriptor-lite" alternative that reuses
2068-Leap's *existing* dynamic memory pool instead of adding a new arena, with
no reference counting and no per-access tax.

## Bytecode / VM

| | 2068-Leap V1 | structured-basic-poc |
|---|---|---|
| Model | No bytecode/IR — direct-execute from source text every run | Real bytecode VM, ~30 opcodes, two-tier CALL/RET vs. VCALL/VRET with 26-slot local frames |
| Safety | Static whole-program checker, once, before `RUN` | Ahead-of-time full-program instruction-boundary bitmap decode on every `RUN`, *plus* a separate checked 7-byte-record ring buffer (`$CB00`, 64 records/448 bytes) replacing the hardware call/ret stack for bytecode returns |
| ROM cost | 0 (not present) | "VM guard milestone added 691 ROM bytes and reserves 448 bytes for 64 checked return records" |
| Perf cost | N/A | Adding the return-record/operand-extent checks alone raised float_loop execution 872→1064ms — **~22% slower**, measured and accepted by that project as a documented tradeoff |

**What problem it's solving:** corruption-resistant bytecode execution — a
buggy or malicious module cannot manufacture a jump into the middle of an
instruction or smash the hardware stack with a fabricated return address.
**Appropriate for 2068-Leap?** No. 2068-Leap has no runtime-loadable *bytecode*
module system (its loadable extensions are small, fixed-ABI native Z80 code,
not a bytecode format), so it has no corresponding corruption surface to
defend against. Paying a 22%-measured perf tax and 1,139 ROM/RAM bytes for a
threat model that doesn't apply would be a straightforwardly bad trade.
**Verdict: do not back-port any part of this.** 2068-Leap's direct-execute
model, kept and refined with statement-boundary caching (see
`V2_ARCHITECTURE.md`), is the right shape for this hardware target.

## Module / extension system

| | 2068-Leap V1 | structured-basic-poc |
|---|---|---|
| Model | One tape-loadable extension at a time, fixed 512-byte RAM window, 4 fixed 3-byte JP veneers, 2 grammar shapes, no custom checker callback | SBM v4 relocatable bytecode-module format: header+exports(≤8)+signatures(≤32)+imports(≤8)+relocations+CRC-16, 32-slot registry, provider-bitmap-gated cross-module calls, dependency-tracked unload with survivor compaction, canonical resave |
| ROM cost | Already paid, small (six shipped extensions total ≈761 bytes) | Multi-KB, many regression scripts (not separately broken out in its baseline doc) |

**What problem it's solving:** safe, general multi-module composition with
relocation and dependency tracking — explicitly flagged in
structured-basic-poc's own `FEATURE_MATRIX.md`: *"The existing Leap extension
registry is a useful transport and validation reference, but its single-slot
design should not become the new architecture."* That's their own project's
verdict on 2068-Leap's design being *too small* for their goals — which is
the correct reading in the other direction too: **their** design is too big
for 2068-Leap's goals. **Appropriate for 2068-Leap? No** — V2 doesn't need
general multi-module composition; it needs, at most, one or two more grammar
shapes on the existing single-slot mechanism (e.g. so a loadable extension
could add a function, not just a statement). **Verdict: keep 2068-Leap's
existing mechanism; do not adopt SBM v4.**

## Native code interop (SBN v1-v3)

structured-basic-poc's pattern — a tiny always-resident primitive
(`PIXEL_SET(x,y)`, `AY_WRITE(reg,data)`) with everything else (`PLOT`, `LINE`,
`AYREG`, trig words, etc.) as a *loadable* package over it — is a genuinely
good, cheap, portable technique, independent of its heavier module-registry
machinery. **This is directly comparable to what 2068-Leap already does**
(six tape-loadable extensions over the resident interpreter), so there is
nothing new to back-port here — 2068-Leap already discovered the same shape
independently, at a smaller scale appropriate to its budget. Worth noting for
V2: the *trig-kernel-resident/words-loadable* split (resident kernel, small
EXROM dispatch table, loadable public names) is a specific, small,
reusable trick — see the trig row below.

## Compiler / dispatch

structured-basic-poc's compiler dispatches via dictionary lookup
(`DICT_FIND`/`DICT_COMPILE`), explicitly avoiding "a large keyword switch
[that] recreates the maintenance problem." 2068-Leap's `basic.asm` dispatch is
already table-driven (`BASIC_EXEC_DISPATCH_TABLE`) rather than a switch, and a
prior optimization pass already table-drove statement dispatch (-253 HOME
bytes) and the checker (-163 EXROM bytes) and function dispatch (-48 HOME
bytes). **Verdict: 2068-Leap already applies this principle; no back-port
needed**, though the *checker* specifically could still benefit from further
table consolidation (see `ROM_BUDGET.md`).

## EXROM / ROM placement methodology

structured-basic-poc's `PLACEMENT_ARCHITECTURE.md` describes an explicit
per-feature decision framework: existence → residency → execution-frequency →
paging-closure → interrupt/timing → RAM-ownership → net-cost → acceptance
gates. **This is a reusable *process*, not code** — it costs nothing to adopt
and directly formalizes what 2068-Leap has been doing ad hoc (its own history
of moving the editor to EXROM for budget, and removing the old 64-column mode
when its cost didn't pay for itself). **Ideas worth back-porting: yes** —
adopt this checklist explicitly for every V2 placement decision (see
`V2_ARCHITECTURE.md`).

## Editor

Both projects independently arrived at "no full-screen mirror redraw" —
2068-Leap's row-shadow diffing plus a horizontal-cursor-only fast path is
already proven on the same hardware; structured-basic-poc achieves a
comparable full-screen editor in 1,739-2,100 EXROM bytes using a NUL-separated
statement model (a different program-storage model, not directly portable) and
explicitly reused "already-tested" keyboard-scanner fixes from 2068-Forth and
ts2068rom. **Verdict: keep 2068-Leap's editor as-is** (it already measures
smaller — 730 EXROM bytes — for the equivalent function); note the general
lesson that keyboard-scanner code is worth sharing across sibling projects,
which 2068-Leap should continue doing.

## Trig / math kernel

structured-basic-poc's SIN/COS/TAN kernel is explicitly "ported in spirit from
2068-Forth" (bounded-reduction + 5-term polynomial, measured max error
3.54e-6, domain limit ~1570 rad from a 250-step reduction guard), resident in
EXROM, with the public words as a small loadable package so unloading it
doesn't invalidate already-compiled code. **Ideas worth back-porting:** the
resident-kernel/loadable-words split as a technique for adding `COS`/`TAN`
cheaply once 2068-Leap's calculator can be reached from general expressions
(see `NUMERIC_DESIGN.md`). The specific polynomial/accuracy numbers are useful
sanity-check reference points, not code to copy (2068-Leap already has its own
reworked Sinclair calculator engine, which is more capable than a bounded
trig-only kernel).

## Resource-baseline sanity check (why "just port it all" doesn't work)

structured-basic-poc's own `RESOURCE_BASELINE.md` shows its **16KB HOME ROM0
release image is already down to 71 bytes free**, before any of 2068-Leap's
graphics, sprites, sound, or storage feature set is added on top. Its 8KB
EXROM has 1,691 free. Combining the two projects' feature sets naively is not
an option — structured-basic-poc's architecture, at its *own* current feature
scope, already consumes essentially all of a 16K HOME bank on correctness
machinery (value ABI, descriptors, VM guards) before a single graphics or
sound primitive is added. This is the strongest concrete evidence for the
comparison's overall verdict.

## 2068-Forth as a tertiary data point

2068-Forth shares literal kernel module names with 2068-Leap
(`bank.asm, graphics.asm, hardware.inc, interrupt.asm, io.asm, kernel_api.inc,
keys.inc, math.asm, memory.asm, sound.asm, storage.asm, sysvars.inc`) —
`bank.asm`'s own header states it was "INHERITED FROM 2068-LEAP, THEN
RETARGETED" (moved to chunk 5 instead of chunk 6 due to a dictionary-RAM
collision). Its own numeric-model doc independently names 2068-Leap's
`exrom_calc.asm` — "a 5-byte-float engine with its own RAM operand stack and
jump-table dispatch" — as "the leading candidate to back an `F+ F- F* F.`
word set" if floats are ever added to Forth, sitting *beside* the integer
core, never under it. This is independent corroboration, from a third
project, of the same conclusion `NUMERIC_DESIGN.md` reaches: reuse
2068-Leap's existing calculator, keep it separate from the integer fast path,
don't rebuild float representation from scratch. 2068-Forth's most recent
HOME ROM measurement (16K image, 66 bytes free) confirms the same "24K is
genuinely full" pattern across every sibling project on this hardware.

## Summary: back-port verdicts

| Idea | Verdict | Reason |
|---|---|---|
| Tagged-value shape (int/float tag) | **Back-port** | Cheap, reuses existing calculator |
| Always-promote-to-float arithmetic | Reject | Destroys the integer fast path that is 2068-Leap's core value proposition |
| Length-prefixed bounded string representation | **Back-port (as a concept)** | Cheap, simple, no allocator required to state it |
| Reference-counted/generational string heap | Reject | ~3,000+ ROM bytes, permanent per-access perf tax, solves a module-sharing problem 2068-Leap doesn't have |
| Bytecode VM + checked-return-record safety layer | Reject | 1,139 bytes + measured ~22% slowdown, defends against a threat model (untrusted bytecode modules) that doesn't exist in 2068-Leap |
| SBM v4 relocatable module registry | Reject | Multi-KB, solves general multi-module composition 2068-Leap doesn't need |
| Tiny-resident-primitive + loadable-package pattern | Already present | 2068-Leap independently has the equivalent (six tape extensions) |
| Placement-decision methodology (existence→...→acceptance gates) | **Back-port (process only)** | Zero cost, formalizes existing ad hoc practice |
| Resident-kernel/loadable-words split for trig | **Back-port (as a pattern)**, gated on numeric redesign landing first | Cheap way to add COS/TAN once composable floats exist |

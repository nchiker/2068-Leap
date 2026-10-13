# 2068-Leap V2 — Architecture (Phase 2 revision, superseded by the Architecture B decision below)

## DECISION (post rewrite-feasibility-study, post statement-compiler spike): Architecture B ACCEPTED

**This section is authoritative and supersedes the rest of this document's
"recommend evolved-V1" framing below**, which is retained for its still-
valid subsystem-classification detail (numeric/string/editor/checker
findings) but is no longer the chosen path for the language core
specifically.

A dedicated rewrite feasibility study
(`docs/INTERPRETER_REWRITE_STUDY.md`) and a follow-up statement-compiler
sizing spike (`docs/STATEMENT_COMPILER_SPIKE.md`) found that evolved-V1
(this document's Alternative B, "hybrid redesign — retain the current
VM/runtime") cannot fund even its narrowed MUST HAVE feature set within
24KB, while a purpose-built compact compiler/bytecode language core
(the rewrite study's own "Architecture B" — a different, more literal
"new core, same platform" split than this document's Alternative B naming;
context makes which is meant clear, and going forward "Architecture B"
means the rewrite study's version) fits with a measured, gate-passing
8,121-byte ROM reserve at a conservative estimate. All seven acceptance
gates defined in `STATEMENT_COMPILER_SPIKE.md` passed on real, assembled
spike measurements, not prose estimates.

**The V2 strategy is now: retain the mature 2068-Leap platform (editor,
display/video, graphics, sprites, AY sound, keyboard/input, joystick,
cassette/storage, kernel/hardware services, debug infrastructure — 9,925
bytes, `VERIFIED` at commit `61bb8bb`) and replace the V1 BASIC language
core (currently 13,988 bytes) with a compact compiler/bytecode
architecture (`ESTIMATED` 4,880-6,530 bytes). The V1 language core
(`basic/basic.asm`, `rom/exrom_checker.asm`, `rom/exrom_strfuncs.asm`,
`rom/exrom_dim.asm`, `rom/exrom_arrays.asm`) is no longer the architecture
to incrementally extend.**

### Conceptual architecture

```
FULL-SCREEN EDITOR
        |
        v
  PROGRAM INTERFACE
        |
        v
COMPILER / FRONT END
        |
        v
  COMPACT BYTECODE
        |
        v
     V2 VM
        |
        v
  COMMON RUNTIME
   /    |    \
INTEGER FP  STRINGS
        |
        v
 PLATFORM SERVICES
```

This diagram is conceptual, not a literal module boundary — see
`docs/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md` §"Editor/compiler
separation" for the actual, ROM-efficient interfaces (the editor calls a
compile entry point and a decompile/`LIST` entry point; it does not call
through six separate layers at runtime). "PLATFORM SERVICES" is the
existing, reused 9,925-byte platform (`LANGUAGE_CORE_ROM_ANALYSIS.md`'s
module table); "COMMON RUNTIME" is the VM's tag-gated integer/float/string
dispatch (`REWRITE_VM_DESIGN.md`); "V2 VM" is the measured 588-byte/
20-opcode dispatch+handler core scaled to ~40 opcodes
(`ESTIMATED` 900-1,100 bytes); "COMPACT BYTECODE" is the program's primary
stored representation (bytecode-primary, per `REWRITE_RAM_BUDGET.md`'s
Option 2, with `LIST`/`EDIT` reconstructing text via a small decompiler);
"COMPILER / FRONT END" is the measured statement+expression compiler
(`STATEMENT_COMPILER_SPIKE.md`, `ESTIMATED` 3,000-4,000 bytes).

### Compatibility policy for this rewrite

V2's language core does not preserve V1 internal compatibility. It may
replace the tokenized-absent/text-only program format, invent a bytecode
format, replace the scalar/string/procedure representation, and replace the
extension ABI's language-facing half, when doing so provides a measured
ROM/RAM/performance benefit — per this project's own standing
compatibility-break policy. It preserves user-visible capabilities
(what a BASIC program can express and do), not V1's internal
implementation details (how the interpreter represents a variable in RAM).

### Migration strategy

Staged, not flag-day. See `ARCHITECTURE_B_IMPLEMENTATION_PLAN.md` for the
full milestone sequence (R1 VM foundation → R2 compiler foundation → R3
program execution → R4 structured language → R5 strings → R6 hybrid
numerics → R7 platform integration → R8 editor integration → R9 V1 removal
→ R10 optimization/ROM recovery) and `ARCHITECTURE_B_MILESTONE_01.md` for
the first concrete step.

---

## Original Phase 2 document (retained for its still-valid subsystem detail)

**Supersedes the Phase 1 version.** The subsystem classifications below are
carried forward except where Phase 2 corrected the underlying facts; the
three-alternatives comparison and Alternative B recommendation stand, but
are now explicitly sequenced behind a required Phase 0. See
`ARCHITECTURE_VALIDATION.md` for the full evidence trail behind every
change in this document.

## Phase 1 classification updates

| Subsystem | Phase 1 classification | Phase 2 update |
|---|---|---|
| Numeric representation | REDESIGN | **Unchanged classification, corrected mechanism.** The promotion mechanism (tag, converters, calculator access) already substantially exists; V2's job is a policy change at existing combine sites, not new plumbing. See `NUMERIC_DESIGN.md`. |
| Variables / symbol handling | REDESIGN | **Downgraded to REFINE.** The fixed 26-slot table Phase 1 based this on was already retired in V1's own "Phase 4" development. The actual fix (widen a 1-byte name field, extend an existing scan) is a refinement of an already-correct pool-record design, not a redesign. See `STRING_AND_SYMBOL_DESIGN.md`. |
| String representation | REDESIGN | **Split.** Identifier length: downgraded to REFINE (same reasoning as above). String content length cap (31 bytes): remains REDESIGN in principle, explicitly deferred to V2.1+ given the ROM budget crisis. |
| String variables | REDESIGN | Same split as above. |
| Editor / program representation | KEEP | **Confirmed KEEP with evidence, not assumption.** The generic editor engine (`rom/exrom_editor.asm`) is independently confirmed (by grep, not just design intent) to have zero calls into interpreter internals, communicating only through two callback hooks. The real coupling — `basic/editor_integration.asm` sharing globals with `basic.asm` — is a same-compilation-unit issue with no measured ROM/RAM/bug cost, not a leaky-API defect. See `V1_DEPENDENCY_MAP.md`/`SUBSYSTEM_BOUNDARIES.md`. Program representation (plain source text, position-addressed) is explicitly evaluated against alternatives (including structured-basic-poc's NUL-record model, itself also plain text) and kept unchanged — no deficiency was found that a different representation would fix. |
| Static checker | (not separately classified in Phase 1) | **New finding: KEEP the duplication with a documented process rule.** The checker's per-keyword grammar table duplicates the runtime dispatch's per-keyword handling by design (both share only the keyword-match primitive) and this is judged structurally necessary, not removable — but it is a real process risk (a new statement type must be added correctly in two places). `SUBSYSTEM_BOUNDARIES.md` makes this an explicit, enforced rule rather than an implicit hazard. |
| Performance-critical interpreter paths | KEEP existing + REFINE with new-path risk analysis | **Corrected finding**: `/` already always round-trips through the calculator today, for every integer division — this is a pre-existing performance characteristic Phase 1 did not know about, not something V2 introduces. See `PERFORMANCE_BASELINE.md`. |

All other Phase 1 classifications (arrays, parser, tokenizer-absence,
control structures, procedures, memory manager, program storage, error
handling, graphics, sprites, sound, tape/storage, extension system, HOME/
EXROM division, extension ABI) are **unchanged** — no Phase 2 evidence
contradicts them.

## Answer to Phase 2 question 4/5/6 (editor separation, program representation)

**Is the editor meaningfully separated from the interpreter?** Yes, at the
layer that matters most (the generic, reusable editing engine) — it has
zero knowledge of variables, expressions, or execution state, and never
will need any, confirmed by exhaustive grep. The layer that *is* fused
(BASIC's editor-integration glue) shares only four sysvars and two
narrow, checker/wrap-calculator calls with the interpreter core — not
variable or expression internals. **Can numeric representation change
without another editor rewrite?** Yes — confirmed directly:
`STRING_AND_SYMBOL_DESIGN.md`/`NUMERIC_DESIGN.md`'s changes touch
`BASIC_VAR_FIND_OR_CREATE`, arithmetic combine sites, and the number
scanner — none of which the editor calls or depends on in either
direction. **Can string representation change without another editor
rewrite?** Yes, same reasoning — even the deferred, more invasive
pool-allocated string redesign (V2.1+) would only touch `basic.asm`'s
string-handling code and the memory pool, not the editor.

## Three architecture alternatives (unchanged verdict, revised content)

### A. Conservative evolution

Unchanged verdict from Phase 1: fits trivially, doesn't meaningfully close
the fundamental limitations. Still `LOW` risk, still an inadequate answer
to the study's primary objective on its own.

### B. Hybrid redesign — retain the current VM/runtime, replace selected subsystems

**Still the recommended alternative**, but Phase 2 reveals it needs a
mandatory precursor step it didn't have in Phase 1's telling: **Phase 0,
architectural relocation.** Phase 1 assumed Alternative B's numeric/string/
procedure work could be paid for by de-duplication savings elsewhere in V1.
Phase 2's consolidation audit found those savings don't exist. Alternative
B is still the right *shape* — reuse the calculator, reuse the memory pool,
reuse the `GOSUB_STACK` shape, reject the bytecode VM and reference-counted
heap — but it cannot be funded by cleanup alone. It must be funded by
either (a) genuine HOME/EXROM content relocation (moving cold code into the
paged bank) or (b) cutting scope (deferring procedures, deferring the
string-length-cap work — both already reflected in the revised
`V2_LANGUAGE_SPEC.md`). **Recommendation: Alternative B, gated on Phase 0.**

### C. Extensive interpreter redesign inspired by structured-basic-poc

Unchanged verdict: rejected. Nothing in Phase 2's research weakens this —
if anything, the ROM budget crisis found in Phase 2 makes the case *against*
Alternative C stronger: 2068-Leap cannot even fund a hybrid, reuse-heavy
design without relocation work; a wholesale, low-reuse redesign is even
further out of reach.

## Is Phase 0 recommended? (task section 19/24 question 15 — answered explicitly)

**Yes, and it is required, not optional.** This is a change from how
Phase 1 implicitly framed things (as though V2.0 language work could start
once the design docs existed). Phase 2's evidence is unambiguous: without
Phase 0, neither bank has room for even the narrowed MUST HAVE language
core (`V2_LANGUAGE_SPEC.md`'s own arithmetic shows HOME short by ~270
bytes even with procedures cut entirely). Phase 0's content is **not**
de-duplication (foreclosed by `CONSOLIDATION_AUDIT.md`) — it is measured
relocation of genuinely-cold HOME/EXROM content into the paged bank or into
loadable extensions, informed by the placement-decision methodology
Phase 1 already adopted from structured-basic-poc. See
`FIRST_MILESTONE.md` for the concrete first step.

## Revised recommendation

**Alternative B, preceded by a mandatory Phase 0 relocation milestone,
with procedures/functions downgraded from committed to desirable-and-
deferred pending Phase 0's actual results.** Every other Phase 1 design
decision (reuse the calculator, reuse the memory pool, avoid reference
counting, avoid a bytecode VM, avoid a general module registry, keep the
editor as-is) stands, now with stronger evidence behind it than Phase 1
had.

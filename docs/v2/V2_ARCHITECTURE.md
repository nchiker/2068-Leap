# 2068-Leap V2 — Architecture (Phase 2 revision)

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

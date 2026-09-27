# Session handoff — read this first

## Current status — R9 production cutover

This section supersedes the historical status below. R8.9 is complete at
`cd2f1df`; R9 production cutover is a WIP and is not complete. The next agent
should start with [`R9_HANDOFF.md`](R9_HANDOFF.md), then use
[`R9_CUTOVER_LEDGER.md`](R9_CUTOVER_LEDGER.md) for detailed implementation,
assembled ROM/RAM accounting, proven tests, and unresolved gates. The
production Makefile builds `rom/v2_home.asm` plus `rom/v2_exrom.asm`; it no
longer builds the V1 interpreter. The immutable V1 pre-cutover implementation
remains available at `cd2f1df`.

The 14 currently buildable standalone V2 fixtures pass in real ZEsarUX.
Production interaction, runtime, graphics, and deterministic storage/package
paths have been exercised there. Physical tape LOAD has not completed through
the production V2 loader in ZEsarUX and remains the outstanding hardware gate.
The project owner has classified CPLOT, AYREG, OUT, BLOCK, FRAME, and INVERT
as optional and outside R9 scope; their omission is not a blocker. Do not
restart R8.9 or begin R10 or R11.

Concise checkpoint for a fresh session resuming this project after `/clear`.
Deeper detail lives in the docs this file points to; this file exists so you
don't have to reconstruct current state from commit history and conversation
memory that no longer exists.

## Where things stand

- Target: original Timex Sinclair 2068, 48KB RAM, 24KB replacement ROM.
  **Hard ROM ceiling: 24,576 bytes.**
- Architecture B (new V2 compiler + bytecode VM + decompiler) is mid-
  rewrite, integrated alongside the existing V1 interpreter/platform/kernel.
  Full plan and milestone log: `docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`
  (the authoritative living document — read it before assuming anything
  about scope or sequencing).
- **R8.5 Group 6 is complete** (commit `b46d34b`): CHR$/STR$/UPPER$/LOWER$/
  LEFT$/RIGHT$/INKEY$, DIMN, SQR/PI/RAD/DEG, SIN — all real-hardware-
  validated on ZEsarUX.
- **R8.5 Group 7 (DEF FN) is designed, implemented, measured, and
  deliberately DEFERRED until immediately after R9.** It does not fit the
  current 282-byte ROM reserve (measured cost: 489 bytes; shortfall: 207
  bytes). Full design + a directly reapplicable git patch:
  **`docs/v2/deffn_design/README.md`** — read that before doing any DEF FN
  work; do not redesign it from scratch.

## Authoritative current ROM/RAM numbers

Measured with the precise **`ACTUAL_END_MARKER`** literal-end-of-code
technique (a label placed immediately before the pad/`SAVEBIN` in a
temporarily-enlarged scratch copy of `rom/test_v2_group6_math.asm`) — NOT
the older "highest labeled symbol below $4000" heuristic, which was found
to undercount trailing unlabeled bytes and should not be treated as
authoritative if you find it referenced in older notes.

- V2-own code: **15,865 bytes** (end address `0x3DF9`)
- Total product ROM: **24,294 / 24,576 bytes used**
- **Free ROM: 282 bytes**
- This is the current, clean, committed state — verify with `git log -1`
  showing `b46d34b` (or later, if this handoff is stale — check the commit
  this file was last touched in against current `HEAD`).

## Regression status

14 of the current `rom/test_v2_*.asm` files build and pass on real ZEsarUX
(verified this session, not merely assumed from an older report):
`test_v2_arrays`, `test_v2_block_if`, `test_v2_decompiler`, `test_v2_ext_demo`,
`test_v2_for_step`, `test_v2_group6_math`, `test_v2_input`,
`test_v2_mode_module`, `test_v2_printer_module`, `test_v2_relational`,
`test_v2_save_load`, `test_v2_sqr_decomp`, `test_v2_strfuncs`,
`test_v2_vm_milestone01` — all PASS (green border, A=$04).

**Excluded — flat-16K test-harness limitation, not a product regression**:
`test_v2_call_fn`, `test_v2_decompiler_phase2`, `test_v2_editor_integration`,
`test_v2_ext_concurrent`, `test_v2_print`, `test_v2_sprite_module`,
`test_v2_sqr` — each has its own "KNOWN LIMITATION" header explaining it now
overflows its own standalone $4000 test-image budget as V2 has grown. This
is tracked technical debt (the harness needs either a banked test image or
to retire/merge some of these combined tests), not a functional defect —
each excluded test's *last known-passing* commit is documented in its own
file header.

**Also currently broken, pre-existing, NOT part of this session's work**:
`test_v2_compiler_r2` through `test_v2_compiler_r7` fail to assemble with
`error: Label not found: DECOMP_END_ADDR` — confirmed present at `b46d34b`
(git-stash-verified), i.e. these are stale test harnesses that predate the
LLIST/`DECOMPILE_PROGRAM` runtime integration and were never updated. Not
regressions from this session; worth cleaning up or retiring at some point
but out of scope here.

Production V1 ROM (`make build`) builds cleanly and is untouched — V2 is
not yet wired into `rom/exrom_build.asm`; it remains a standalone,
separately-tested architecture until R9.

## Architectural decisions to preserve (do not casually undo)

- **Resident ROM = general-purpose BASIC/runtime/platform capability.
  Loadable packages = specialized hardware, peripherals, and optional
  enhancements.** SPRITE GRAB/SHOW/HIDE/MOVE, MODE/ULAPLUS/PALETTE, and
  printer LPRINT/LLIST are all loadable extensions (R7.5 architecture:
  compile-time slot IDs + a runtime registry, typed arguments, `kernel/
  extensions/ext_registry.asm`) — not V1-style runtime keyword rematching.
  The sprite package still uses resident kernel graphics primitives; those
  primitives remain useful general-purpose ROM services in their own right.
- **Preserve capability and intended language semantics, not obsolete V1
  mechanism.** This is the standing project rule — applied explicitly in
  the DEF FN design (V1's single-global-slot/anti-recursion limits are
  interpreter artifacts, not language semantics worth preserving; V2's
  compile-once + real call stack gets multiple functions and real
  recursion "for free").

## STOP — this section is stale; superseded by later work in this same lineage

Everything below in this "Outstanding work" list describes the state
*before* the V2 semantic/capability audit and R8.9 existed. It is kept
for historical continuity only. **Do not start from here.** The
authoritative current state is:

1. **The V2 semantic/capability audit is DONE**: `docs/v2/
   V2_SEMANTIC_CAPABILITY_AUDIT.md`. Read its §0 first — the audit's
   original "READY FOR R9" verdict is superseded.
2. **A new mandatory milestone, R8.9 — V2 Production Integration, was
   inserted before R9**, because the audit (only after being accepted)
   was found to have missed a real gap: V2 has never been wired into the
   actual production ROM's boot/command loop, and has no multi-line
   program storage of its own. R9 does not begin until R8.9's success
   gate is demonstrated.
3. **R8.9 is IN PROGRESS — design/dependency work is done, implementation
   has NOT started.** The authoritative current entry point for a fresh
   session is **`docs/v2/R8_9_HANDOFF.md`** — read that file first, it
   supersedes the "Recommended first task" section below. It points to
   `docs/v2/R8_9_PRODUCTION_INTEGRATION_DESIGN.md` (the architecture
   decisions) and lists the exact next steps, including a RAM-relocation
   task that must happen before any new production code is written.
4. R9, DEF FN reintegration, R10, R11 remain queued in that order, after
   R8.9, exactly as this file originally described below — just insert
   R8.9 immediately before R9 in that sequence.

## Outstanding work (historical — superseded by §above, kept for context)

1. **V2 semantic/capability audit** (not yet done, should happen next or
   alongside early R9 work) — for each inherited V1 behavior, ask: why did
   V1 do this; does the constraint still exist in Architecture B; what's
   the natural V2 behavior; is there a cheap improvement now; is the result
   internally consistent. Classify each finding as (A) genuine intended
   semantics to preserve, (B) V1 implementation artifact to fix, or (C) a
   deliberate V2 compatibility choice to keep intentionally. Areas
   flagged as worth specific attention: `INT()`'s integer-only-core-era
   behavior vs. natural V2 hybrid-numeric semantics; the small named-
   string-variable table limit possibly being an inherited implementation
   constraint rather than desired V2 semantics; identifier/name
   restrictions judged against V2 compile-time symbol resolution rather
   than automatically preserved from V1. Full inherited-behavior area list
   is in the pasted instructions this handoff was generated from — if lost,
   reconstruct from `docs/v2/CURRENT_LIMITATIONS.md` and
   `docs/v2/COMPATIBILITY_BREAKS.md` as a starting point.
2. **R9 — V1 language-core removal.** See
   `ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s own R9 section for scope,
   dependencies, and success gate. Re-measure ROM precisely afterward.
3. **Reintegrate DEF FN** immediately after R9 frees space — see
   `docs/v2/deffn_design/README.md`'s reintegration checklist.
4. **R10 — final optimization/freeze**, only after DEF FN is in. Do not
   consume recovered space with new features; the 24KB ceiling is a
   ceiling, not a target to fill. Establish a protected maintenance/bug-fix
   reserve before considering optional enhancements. `OUT` is a possible
   future resident command, not currently authorized.
5. **R11 — ROM services / USR programmer interface**, after R10 stabilizes,
   aiming for zero required ROM growth.

## Recommended first task after `/clear` (historical — see the STOP section above instead)

Read this file, then `docs/v2/ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s R8.5
and R9 sections, then begin the V2 semantic/capability audit (item 1 above)
before starting R9 itself — R9's own success gate depends on knowing V2's
intended capability coverage is actually complete, which the audit is what
establishes.

# 2068-Leap V2 — BASIC Interpreter Rewrite Feasibility Study

**This is an investigation only. No production rewrite has begun.** No file
under `rom/`, `basic/`, `kernel/`, or `include/` was modified to produce this
study. Two isolated, disposable sizing spikes were created under
`~/2068-Leap/spikes/v2_vm_sizing/` — new directory, never wired into the real
Makefile, never touching production source.

**Anchor commit for all "current ROM" figures: `77fdc1f`** (see
`LANGUAGE_CORE_ROM_ANALYSIS.md` for why the live tree wasn't used —
concurrent CIRCLE+FILL bundling work was in progress on it during this
study).

## The question this study answers

> Would replacing the existing BASIC language core with a purpose-designed
> compact V2 interpreter produce a substantially better language within the
> 24KB ROM / 48KB RAM limits?

**Yes — with meaningfully lower risk of ROM starvation than continuing to
evolve V1, and no plausible RAM regression, provided one explicit,
policy-permitted compatibility break is accepted (bytecode-primary program
storage, see `REWRITE_RAM_BUDGET.md`).** This is not the answer this study
set out to find — Phase 1/2's own prior conclusion (`ARCHITECTURE_COMPARISON.md`)
was "reuse everything, evolve V1, reject anything structured-basic-poc-sized."
That conclusion was correct given what Phase 1/2 measured (evolving V1's
*numeric/string/symbol* subsystems is genuinely cheap, because most of the
needed plumbing already exists). What changed is Phase 0's finding that
there is **no consolidation saving anywhere in V1** to pay for adding even
that cheap plumbing — the ROM is already full, and every evolved-V1 feature
is pure addition against a near-zero balance. This study asked a different
question — not "is evolving V1 the right *shape*" (yes, for the subsystems
it touches) but "is V1's *language core itself* — its ~13,893-byte
direct-execute interpreter, separate from the calculator/graphics/editor/
sound/storage it calls into — the cheapest possible engine to run that
shape on." The answer, measured, is no.

## Method

1. Read the complete existing Phase 1/2 corpus (`docs/v2/*.md`) as ground
   truth — not re-derived.
2. Anchored current-ROM figures to a clean `git worktree` checkout of commit
   `77fdc1f`, ran a real `make budget` there (the live tree had concurrent,
   unrelated in-progress edits).
3. Classified every one of V1's 23 measured ROM modules as either
   **language core** (candidate for replacement) or **V2 platform**
   (mature, should survive largely unchanged) — see
   `LANGUAGE_CORE_ROM_ANALYSIS.md` for the full table and reasoning.
4. Built two real, standalone sjasmplus spikes and assembled them for real
   assembled-byte counts: a 20-opcode bytecode VM (dispatch loop, jump
   table, symbol-index access, operand stack, representative
   integer/mixed-numeric/branch/loop/call handlers) and a complete
   4-operator recursive-descent expression compiler. Both assemble clean
   (0 errors, 0 warnings). See `REWRITE_VM_DESIGN.md`.
5. Extrapolated a full-VM and full-compiler estimate from those two real
   measurements, with the extrapolation's assumptions stated explicitly and
   its weakest link (statement-compiler sizing) flagged for a follow-up
   spike rather than hidden.
6. Built representative SMALL/TYPICAL/LARGE program RAM models under all
   three architectures, using the real 15,275-byte RAM pool measurement as
   the actual constraint (not the nominal 48K).
7. Mined `~/structured-basic-poc` (already substantially covered by
   `ARCHITECTURE_COMPARISON.md`, re-checked here rather than re-derived) for
   architectural lessons — see below.

## Preserving mature hardware functionality

**Confirmed, not assumed**: the editor (`rom/exrom_editor.asm`, 730 bytes),
display/graphics (`kernel/graphics/graphics.asm`, 2,761 bytes), sprites
(`rom/exrom_sprite.asm`, 988 bytes), sound (`kernel/sound/sound.asm` +
`rom/exrom_sound.asm`, 72 bytes), input (`rom/exrom_input.asm`, 271 bytes),
storage (`rom/exrom_storage.asm` + `rom/exrom_format.asm`, 1,123 bytes), and
the low-level kernel (memory/io/interrupt/bank, 1,514 bytes) — 10,565 bytes
total, the **V2 PLATFORM COST** — have no dependency on the language core's
internal representation of numbers, variables, or strings, per
`V2_ARCHITECTURE.md`'s already-confirmed editor-separation finding and this
study's own module classification. All three architectures reuse every one
of these bytes unchanged. This is the single largest area of agreement
across this entire project's Phase 1/2/rewrite-study history: **do not
rewrite the operating environment.**

The float calculator (`rom/exrom_calc.asm`, 1,931 bytes) is classified as
platform too, not language core, even though it is "numeric runtime" in the
literal sense the study brief lists as a language-core candidate — because
every design considered (evolved-V1, this study's Architecture B, and even
the rejected Architecture C) reuses it unchanged. Reimplementing float
arithmetic from scratch was costed once, by `ARCHITECTURE_COMPARISON.md`
(structured-basic-poc's from-scratch numeric engine: 2,952 bytes vs.
2068-Leap's already-paid-for 1,931+403), and rejected on cost grounds in
Phase 1. Nothing in this study's research changes that verdict.

## V2 PLATFORM COST and MAXIMUM LANGUAGE CORE BUDGET

See `REWRITE_ROM_BUDGET.md` for the full derivation:

```
V2 PLATFORM COST                    = 10,565 bytes   (VERIFIED)
REQUIRED ENGINEERING RESERVE        =    500 bytes   (ASSUMED policy)
MAXIMUM LANGUAGE CORE BUDGET        = 24,576 - 10,565 - 500
                                     = 13,511 bytes
```

This number was computed **before** any interpreter design work, per the
study brief's instruction.

## Current language-core cost

**13,893 bytes** (`VERIFIED`): `basic/basic.asm` (11,369 — the direct-
execute interpreter, dispatch, expression evaluator, `DEF FN`, error
raising), `rom/exrom_checker.asm` (1,860 — whole-program grammar
validator), `rom/exrom_strfuncs.asm` (383), `rom/exrom_dim.asm` (210),
`rom/exrom_arrays.asm` (71). **This already exceeds the 13,511-byte maximum
language-core budget by 382 bytes, before a single V2 feature is added.**
See `LANGUAGE_CORE_ROM_ANALYSIS.md` for the architectural overhead analysis
(the checker/interpreter double-payment for syntax recognition) that a
rewrite structurally eliminates.

## Bytecode architecture, integer fast path, floating point

Investigated and specified at sizing depth (not production depth) in
`REWRITE_VM_DESIGN.md`. Key measured/estimated findings:

- A real 20-opcode VM (dispatch + jump table + symbol-index access + stack
  helpers + representative handlers covering small/large int constants,
  loads/stores, integer arithmetic, mixed int/float arithmetic, comparisons,
  branches, `FOR`/`NEXT`, calls) assembles to **588 bytes**, real, measured.
- Integer fast path is preserved by construction: the `ADD`/`SUB`/`MUL`
  handlers check a per-value tag and take a native 16-bit Z80 path when both
  operands are INT, falling back to the existing calculator only when a
  value is actually FLOAT — the same policy `NUMERIC_DESIGN.md` already
  proposes for evolved-V1, just implemented as VM opcodes instead of inline
  `basic.asm` combine-site edits.
- `/` keeps V1's own existing behavior of always round-tripping through the
  calculator (`VERIFIED` precedent from `NUMERIC_DESIGN.md`) rather than
  inventing a separate fast integer-divide path with no precedent.
- Core floating point (add/sub/mul/div/compare via the existing calculator)
  is distinguished from an optional transcendental math library
  (`COS`/`TAN`/`EXP`/`LN`/`LOG10`) exactly as the study brief asks — both
  remain OPTIONAL/DESIRABLE items costed separately in
  `REWRITE_COMPARISON.md`'s feature-budget table, not bundled into the MUST
  HAVE core.

## Variables/identifiers, strings

Multi-character identifiers compile to a symbol **index** at compile time
(a real, measured 34-byte "identifier-load compiler" slice, excluding the
symbol-table scan routine itself, which is compile-time-only cost). This is
the study brief's exact goal: `SCORE = SCORE + 10` compiles to operations
referencing a compact index, not a name re-search, and — because the name
never needs to travel into the runtime record at all — the runtime record
can be *smaller* than V1's current one despite supporting long names (see
`REWRITE_RAM_BUDGET.md`'s record-size table). Strings keep the existing
31-byte-cap, pool-allocated record shape (no new allocator invented), with
ordering comparisons added — the same string design evolved-V1 already
specified in `STRING_AND_SYMBOL_DESIGN.md`, unchanged, just executed by VM
opcodes instead of inline handlers.

## Parser/compiler: which of the three brief options?

**Hybrid, but resolved concretely, not left abstract**: source-text editing
experience is unchanged (no visible "compile step," matching V1's
instant-on feel — the checker already does a comparable whole-program pass
before every `RUN` today), but the program's *stored* representation is
bytecode, not source text (see `REWRITE_RAM_BUDGET.md`'s Option 2). `LIST`/
`EDIT` reconstruct text from bytecode via a small decompiler
(`ESTIMATED` 300-500 ROM bytes). This was chosen over pure
interpret-from-source (keeps V1's proven perf ceiling, specifically the
GOTO catastrophe) and over pure tokenize-then-recompile-every-RUN (risks
RAM exhaustion for large programs, demonstrated concretely in
`REWRITE_RAM_BUDGET.md`'s LARGE worked example: a transient second copy of
a 14,000-byte program's bytecode would not fit in the 15,275-byte pool
alongside the retained source text).

## Editor separation

The editor is already well-separated (`VERIFIED`, `V2_ARCHITECTURE.md`).
This study's design adds one further, explicit boundary: EDITOR → COMPILER
→ VM, where the editor calls a compile entry point and a decompile
(`LIST`) entry point, and knows nothing about bytecode opcodes, symbol
indexes, tags, or the VM operand stack — the same "smallest interface"
property the study brief asks for. This was not measured as a separate ROM
cost because it is a calling-convention decision, not new code beyond what
the compiler/decompiler already need to exist.

## Lessons from structured-basic-poc

Already comprehensively audited in `ARCHITECTURE_COMPARISON.md`
(re-checked, not re-derived, in this pass). Summary relevant to this
study's rewrite design:

- **Adopt**: the tagged-value shape (small tag byte distinguishing int/
  float) — this study's VM uses exactly this, gated to preserve the integer
  fast path rather than structured-basic-poc's always-promote-to-float
  policy (which its own `VALUE_ABI.md` admits has "no integer arithmetic
  fast paths implemented" — directly incompatible with 2068-Leap's core
  value proposition). Also adopt the length-prefixed bounded-string
  *concept* (not its reference-counted heap), and the placement-decision
  methodology (existence → residency → frequency → paging → acceptance
  gates) as a process, free to adopt.
- **Reject outright**: the bytecode VM's checked-return-record safety layer
  (measured ~22% perf tax + 1,139 bytes, defending against untrusted-module
  corruption 2068-Leap's single-slot loadable-extension model doesn't
  expose); the reference-counted/generational string heap (~3,000+ bytes,
  permanent per-access tax, solves a cross-module-aliasing problem
  2068-Leap doesn't have); the SBM v4 relocatable module registry
  (multi-KB, general multi-module composition 2068-Leap doesn't need).
- **The starkest lesson**: structured-basic-poc's own 16KB HOME ROM0 image
  is down to 71 bytes free **before a single graphics/sprite/sound
  primitive is added** — direct evidence that a heavier, more "general"
  correctness-first design (its VM guards, descriptor ABI, ownership
  machinery) consumes an entire 16K bank on infrastructure alone. This
  study's rewrite explicitly avoids all of that infrastructure precisely
  because 2068-Leap's threat model and sharing requirements don't need it —
  and the measured spike numbers (588 bytes for a real, working 20-opcode
  VM) confirm a *much* smaller VM is achievable when the safety/generality
  goals are dropped.
- **Growth trajectory as a warning, not a template**: structured-basic-poc's
  own `FEATURE_MATRIX.md` scopes far more than 2068-Leap's V2 language
  target (full structured control flow, procedures with locals, a module
  system) — this study's rewrite deliberately does not chase that scope,
  matching this project's own explicit non-goal ("replacing 2068-Leap's
  architecture with structured-basic-poc's" — unchanged from Phase 1).

## Critical question, answered explicitly

> Is the primary constraint the amount of functionality being requested,
> or inefficiency in the existing interpreter architecture?

**Both, but they are separable, and this study can now say which one
dominates.** The *functionality* being requested (multi-char identifiers,
composable floats, ordering comparisons, procedures) was already shown, in
Phase 2's `NUMERIC_DESIGN.md`/`STRING_AND_SYMBOL_DESIGN.md`, to be genuinely
cheap to build (~700-1,200 bytes total, MUST HAVE + procedures) — it is not
an inherently expensive feature list. The blocking constraint, per Phase 2's
own `ROM_BUDGET.md`, is that V1's *existing* architecture has nowhere to put
even that cheap addition (32-118 bytes free, depending on snapshot, against
~700-1,200 bytes needed). This study's contribution is showing that the
inefficiency is not evenly distributed across V1 — it is concentrated
specifically in the **language core** (13,893 measured bytes, of which a
large share is the double payment for syntax recognition between the
checker and the direct-execute interpreter, `LANGUAGE_CORE_ROM_ANALYSIS.md`).
The **platform** (10,565 bytes: editor, graphics, sound, sprites, storage,
calculator, kernel) shows no comparable inefficiency — nothing in this study
found evidence that graphics/sound/editor code could shrink substantially
without losing real functionality. **So: the requested functionality is not
too much for 24KB. The existing *language-core* architecture is
inefficient enough, specifically in a way a compile-once design directly
addresses, that it cannot afford that functionality — but a purpose-built
core can, with room to spare.** This is not a claim that a rewrite is
attractive in the abstract; it is a claim, backed by two real assembled
spikes and a full module-by-module ROM audit, that the arithmetic actually
works out, which the study brief explicitly required before recommending
anything.

## Recommendation (superseded — see decision update below)

**Architecture B (New language core, existing platform) is feasible and is
the recommended target if a rewrite is pursued.** It is not recommended
that the rewrite begin immediately: the single largest unmeasured number in
this whole study is the statement-compiler size (estimated at
2,700-4,200 bytes from a multiplier applied to the checker's existing size,
not directly measured). Recommended next step, before any production
commitment: a statement-compiler sizing spike (compile 3-5 representative
statement types — `LET`, `IF...THEN...ENDIF`, `FOR...NEXT`, `PRINT` — to
real bytecode, real assembled bytes), exactly the same evidence-before-
commitment discipline this project's Phase 0/1/2 work has already applied
to every other estimate in this corpus.

## Decision update: Architecture B ACCEPTED

The recommended next step above has since been carried out. See
`STATEMENT_COMPILER_SPIKE.md`: a real, assembled statement-compiler spike
(964 measured bytes covering assignment, `IF...THEN GOTO`, `GOTO`,
`FOR`/`NEXT`, and `CALL`/`RETURN`, plus a shared lexer/emitter/fixup
infrastructure measured at 82% of the total) resolved the uncertainty this
document flagged. All seven Architecture B acceptance gates defined for
that spike pass, including a 8,121-byte ROM reserve at the conservative
estimate against a 4,096-byte requirement (roughly double). Also re-
measured: two further Phase 0 relocation milestones (P0.3, P0.4) landed on
`main` since this study's original anchor, moving CIRCLE+FILL into a
loadable extension and lowering V2 PLATFORM COST from 10,565 to 9,925
bytes — real, independent evidence that the Phase 0 relocation strategy
this project has pursued in parallel continues to work.

**Architecture B is accepted as the authoritative V2 direction: retain the
mature 2068-Leap platform, replace the V1 BASIC language core with the
compact V2 compiler/bytecode architecture. The V1 language core is no
longer the architecture to incrementally extend.** This decision is
recorded in `V2_ARCHITECTURE.md`, with the production migration plan in
`ARCHITECTURE_B_IMPLEMENTATION_PLAN.md` and the first concrete production
milestone in `ARCHITECTURE_B_MILESTONE_01.md`.

## Deliverables produced by this study

1. `INTERPRETER_REWRITE_STUDY.md` (this document)
2. `LANGUAGE_CORE_ROM_ANALYSIS.md` — module-by-module platform/language-core
   classification, measured at `77fdc1f`
3. `REWRITE_ROM_BUDGET.md` — platform cost, reserve, maximum language-core
   budget, three-architecture ROM totals, break-even analysis
4. `REWRITE_RAM_BUDGET.md` — SMALL/TYPICAL/LARGE RAM models, the
   source-primary-vs-bytecode-primary design decision and why it matters
5. `REWRITE_VM_DESIGN.md` — the two real sjasmplus spikes, their measured
   byte counts, and the extrapolation to a full VM/compiler
6. `REWRITE_COMPARISON.md` — the required quantitative comparison table and
   feature-budget analysis

Spike source: `~/2068-Leap/spikes/v2_vm_sizing/vm_sizing_spike.asm`,
`~/2068-Leap/spikes/v2_vm_sizing/compiler_sizing_spike.asm` (both assemble
clean with the project's real `sjasmplus`, isolated, not wired into the
Makefile).

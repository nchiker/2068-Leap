# 2068-Leap V2 — Rewrite Comparison Table

Evidence classes: `VERIFIED`, `ESTIMATED` (formula shown elsewhere),
`ASSUMED`. Figures are pulled from `LANGUAGE_CORE_ROM_ANALYSIS.md`,
`REWRITE_VM_DESIGN.md`, `REWRITE_ROM_BUDGET.md`, `REWRITE_RAM_BUDGET.md`.
This table is the study brief's required "quantitative comparison."

| | Evolved V1 (Architecture A) | New Language Core (Architecture B) | Broader V2 Rewrite (Architecture C) |
|---|---|---|---|
| Platform ROM | 10,565 (`VERIFIED`) | 10,565 (`VERIFIED`, unchanged — same reused platform) | 10,565 + 300-600 representation-adapter tax (`ESTIMATED`) |
| Language-core ROM | 13,893 measured today (`VERIFIED`) + 695-725 MUST HAVE (`LIKELY`) ≈ 14,590-14,620; + ~500 more if procedures added | 5,010-7,220 (`ESTIMATED`, anchored on 2 real spikes) | 5,010-7,220, same estimate as B (`ESTIMATED`) — no measured saving found from the broader redesign |
| Total ROM | 25,155-25,190 (over budget) | 15,575-17,785 | 15,875-18,385 |
| ROM reserve | **Negative**: -579 to -614 bytes against the 24,576 ceiling using only currently-free ROM, before any Phase 0 relocation | 6,791-9,001 bytes | 6,191-8,701 bytes |
| Fixed RAM | Unchanged across all three (kernel/sysvar layer not touched) | Unchanged | Unchanged |
| Typical program RAM (TYPICAL worked example) | 2,632-2,728 bytes (`ESTIMATED`) | ~1,062 bytes (`ESTIMATED`, bytecode-primary) | ~1,062 bytes, same as B |
| Integer performance | Unchanged from V1 (native 16-bit path preserved) — `VERIFIED` baseline exists (`PERFORMANCE_BASELINE.md`); GOTO-based control flow remains catastrophically slow (unresolved architectural issue, `VERIFIED`) | Preserves native int fast path (design goal, `ESTIMATED`/not runtime-measured) **and** every branch — not just `FOR`/`NEXT` — gets a compiled target address, directly fixing the GOTO catastrophe | Same as B |
| FP support | Narrow, non-composable (`VERIFIED`, `CURRENT_LIMITATIONS.md`) until MUST HAVE promotion work lands (`LIKELY`, unbuilt) | Composable by design from day one (tag travels through every combine site in the VM, `ESTIMATED`) | Same as B |
| String capability | 31-byte cap, no ordering comparisons until MUST HAVE work lands | 31-byte cap unchanged (deferred, same as A), ordering comparisons included | Same as B |
| Identifier capability | Multi-char once MUST HAVE lands (`LIKELY`, unbuilt, and doesn't fit ROM yet per this study) | Multi-char from day one, compiled to index, no runtime name-scan cost at all (`ESTIMATED`) | Same as B |
| Editor separation | Already good (`VERIFIED`, `V2_ARCHITECTURE.md`) — editor unaware of numeric/string/variable representation | Same separation, now formalized through an explicit EDITOR→COMPILER→VM boundary (`ASSUMED` design choice) | Same as B, plus a new, wider boundary (editor must also accommodate decompiled `LIST` text) — marginally higher coupling risk |
| Implementation risk | `LOW` per-feature, but the aggregate plan is currently **infeasible without Phase 0's unmeasured relocation yield** — real risk is schedule/feasibility risk, not code risk | `MEDIUM` — compiler-size estimate is the least-measured number in this whole study (see confidence statement in `REWRITE_VM_DESIGN.md`); mitigated by a cheap, well-scoped next SPIKE | `MEDIUM-HIGH` — same estimate uncertainty as B, plus additional, unquantified program-representation migration risk with no measured offsetting benefit |

## Feature-budget analysis (MUST HAVE / DESIRABLE / OPTIONAL, by architecture)

| Feature | Class | Evolved V1 fits? | New Language Core fits? |
|---|---|---|---|
| Structured BASIC (`IF/ENDIF`, `FOR/NEXT`, `WHILE` if added) | MUST HAVE | Partial today (no `WHILE`); ROM-constrained for anything more | Yes, comfortably within the 6,791-9,001 byte reserve |
| Multi-character identifiers | MUST HAVE | Designed, does not currently fit (this study) | Yes, native to the design at near-zero marginal cost |
| Useful strings (ordering compares) | MUST HAVE | Designed, does not currently fit | Yes |
| Integer fast path | MUST HAVE | Preserved (V1's existing strength) | Preserved by design |
| Floating-point arithmetic | MUST HAVE | Designed, does not currently fit | Yes, and composable from the start |
| Procedures/functions | DESIRABLE | Downgraded to deferred (`ROM_BUDGET.md`) — doesn't fit | Yes — ~500 bytes fits easily inside the reserve |
| Graphics/sprites/AY sound/joystick/storage/extensions | Already shipped | Unaffected either way (platform layer, reused) | Unaffected either way (platform layer, reused) |
| Transcendental math (`COS`/`TAN`/`EXP`/`LN`/`LOG10`) | OPTIONAL | Deferred, ~200-300 bytes, doesn't fit today | Fits inside the reserve (~200-300 of 6,791-9,001) |
| `SELect ON` / `WHEN ERRor` / `REPeat` | OPTIONAL | Deferred, doesn't fit today | Fits inside the reserve (~450-750 combined) |
| Dynamic-length strings beyond 31 bytes | OPTIONAL | Deferred to V2.1+ regardless | Plausibly fits within the reserve, but not costed in this pass — flagged for a future study, not claimed here |

## Verdict

Architecture B (New Language Core, existing platform) is the only one of
the three that fits the MUST HAVE feature set with a comfortable, positive
reserve using real measurements for the platform and evolved-V1 numbers and
a spike-anchored estimate for the new language core. Architecture C adds
cost and risk with no measured benefit over B. Architecture A, as currently
scoped, does not fit even its narrowed MUST HAVE set without an
as-yet-unmeasured Phase 0 relocation win. See `INTERPRETER_REWRITE_STUDY.md`
for the full narrative answer and the critical-question analysis.

## Decision update: Architecture B ACCEPTED (post statement-compiler spike)

`STATEMENT_COMPILER_SPIKE.md` resolved the remaining uncertainty flagged
above (the statement-compiler estimate) with a real, assembled spike
(964 measured bytes, 5 statement types, shared lexer/emitter/fixup
infrastructure at 82% of the total). All seven Architecture B acceptance
gates pass, including ROM reserve at the conservative estimate (8,121 bytes
against a 4,096-byte requirement — roughly double). **Architecture B is no
longer just recommended pending validation — it is accepted as the
authoritative V2 direction.** See `V2_ARCHITECTURE.md` for the recorded
decision, `ARCHITECTURE_B_IMPLEMENTATION_PLAN.md` for the production
migration plan, and `ARCHITECTURE_B_MILESTONE_01.md` for the first
production milestone this triggers.

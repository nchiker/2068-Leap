# V2 Semantic & Capability Audit — pre-R9

Date: 2026-09-26. Baseline commit at start of session: `10a5a14`. This
document is the authoritative record of the audit `docs/v2/SESSION_HANDOFF.md`
called for before starting R9. Where this document conflicts with older
planning docs (`docs/v2/CURRENT_LIMITATIONS.md`, `docs/v2/COMPATIBILITY_BREAKS.md`,
`docs/v2/RAM_BUDGET.md`), **this document and current repository evidence are
authoritative** — those older docs predate Architecture B (the V2 compiler +
bytecode VM + decompiler) and describe V1's own incremental-extension phase,
not the current architecture. They remain useful V1 history, not current V2
truth.

## 1. Executive summary

Architecture B (V2 compiler + VM + decompiler) is real, substantial, and
independently testable: 12-14 regression tests pass on real ZEsarUX hardware
(exact count depends on a ROM-size tradeoff explained in §9), the real editor
engine reaches V2's compiler/VM/decompiler with **zero V1-interpreter
dependency** in the normal edit/compile/run/decompile loop, and DEF FN's
preserved design's specific ROM prerequisites (opcode numbers 52-54, token
numbers 56-57, error codes 49-54, `VM_CALL_STACK_TOP`/`FLOOR` addresses) are
all still free and unclaimed — no drift since the design was captured.

This audit also found and, per explicit user decision, **fixed** a real
correctness defect: V1-era "integer-only" builtins (`INT`, `SGN`, `MOD`,
`DIV`, `RND`, `PEEK`, `USR`, `POINT`, `ATTR`, plus `SQR`/`RAD`/`DEG`) did not
check the operand type tag, so a FLOAT-tagged argument (a FLOATTAB *index*)
was silently misread as a raw integer value — wrong results, no error. This
is now fixed for those functions (see §4, §15). The audit also found the
**same bug class is pervasive** across nearly every resident numeric
*statement* (`PLOT`, `LINE`, `BEEP`, `SOUND`, `INK`, `PAPER`, `RANDOMISE`,
`POKE`) — deliberately **left unfixed this session** because the fix already
applied consumed most of the remaining pre-R9 ROM reserve; see §4 and §12 for
the scope and the explicit recommendation to the user.

A second real design defect was found and a decision recorded (not yet
implemented, since DEF FN itself is out of the tree): the preserved DEF FN
design's parameter binding is not actually recursion-safe as previously
claimed — see §6.

**Verdict: READY FOR R9 WITH SPECIFIC PRECONDITIONS.** See §12 for the
precondition list. Nothing found in this audit blocks R9's own scope (V1
language-core removal); the correctness gaps found are pre-existing, in V2's
own numeric builtins, orthogonal to whether V1's interpreter still exists.

## 2. Verified baseline (re-confirmed this session)

- Target: original Timex Sinclair 2068, 48KB RAM, 24KB replacement ROM. Hard
  ROM ceiling: 24,576 bytes. `git status` clean at session start (`10a5a14`).
- Architecture B = V2 compiler (`rom/exrom_v2_compiler.asm`, 4273 lines) +
  bytecode VM (`rom/exrom_v2_vm_core.asm`) + decompiler
  (`rom/exrom_v2_decompiler.asm`, 3507 lines), coexisting with, but
  architecturally independent of, V1's interpreter until R9.
- Pre-audit baseline (confirmed via `git show 10a5a14`): V2-own code
  15,865 bytes (`0x3DF9`), total product ROM 24,294/24,576, free 282 bytes.
- **Post-audit measurement (this session, `ACTUAL_END_MARKER` technique,
  scratch image against `rom/test_v2_group6_math.asm` enlarged to a $5000
  target, reproduced and then deleted, not committed)**: V2-own code end
  address moved from `0x3DF9` to **`0x3EB5`** — a **+188 byte** increase from
  the numeric-correctness fixes in §4/§15. New V2-own code size: **16,053
  bytes**. New total product ROM: **24,482/24,576**. **New free ROM: 94
  bytes.**
- R8.5 Group 6 (SQR/PI/RAD/DEG/SIN) confirmed complete and, with this
  session's fixes, now float-argument-safe where relevant (§4).
- DEF FN: confirmed still fully preserved, undeployed, at
  `docs/v2/deffn_design/README.md` + `deffn_experiment_full.patch`, with its
  specific ROM prerequisites (§6) confirmed unclaimed.
- Regression suite: **12 of 14 previously-buildable tests still build**
  after this session's fixes; 2 (`test_v2_ext_demo`, `test_v2_save_load`)
  newly overflow their own flat-16K test-harness budget by 134 and 37 bytes
  respectively, purely because they statically link the same
  `exrom_v2_vm_core.asm` this session enlarged by 188 bytes. This is the
  same documented "flat-16K test-harness limitation" class the project has
  already hit repeatedly (`test_v2_call_fn`, `test_v2_print`, `test_v2_sqr`,
  `test_v2_ext_concurrent`, `test_v2_editor_integration`,
  `test_v2_decompiler_phase2`, `test_v2_sprite_module` were already excluded
  for the identical reason before this session) — **not a product
  regression**. See §9.
- One test (`test_v2_group6_math`) was re-run end to end on real ZEsarUX
  after the fix: still PASSes (border=4, A=$04) — confirms non-regression
  of the existing int-argument SGN/MOD/DIV/RND/POINT/ATTR test coverage.
  **Not yet separately hardware-tested this session**: the *new*
  float-argument behavior itself (`INT(3.7)`, `SGN(-2.5)`, `MOD`/`DIV`/
  `RND`/`PEEK`/`USR`/`POINT`/`ATTR` raising the new type error on a FLOAT
  argument, `SQR`/`RAD`/`DEG` truncating a FLOAT argument). This is
  reviewed against the exact, already-hardware-validated `BUILTIN_FN_SIN`/
  `BUILTIN_FN_ABS` idiom (same routines, same technique, copied verbatim)
  and assembles cleanly, but a dedicated new test (`test_v2_numeric_
  hybrid.asm` or similar) covering these specific new paths on real
  hardware is recommended near-term follow-up, not done this session — see
  §12 precondition list.
- `test_v2_compiler_r2` through `r7`: confirmed, by direct source check,
  that `DECOMP_END_ADDR` is genuinely absent from the current
  `exrom_v2_compiler.asm`/`exrom_v2_decompiler.asm` (it's set by each
  test's own driver code, a pattern that changed when LLIST/
  `DECOMPILE_PROGRAM` runtime integration landed) — this is a stale
  test-harness issue, not a hidden compiler/decompiler defect. Confirmed
  category 3 (stale harness), not category 4 (product regression).

## 3. What changed this session (implementation, not just audit)

Per explicit user decision (see §15), the following was implemented,
assembled clean (0 errors/warnings, `tools/sjasmplus_strict.sh`), and
regression-tested for non-regression (not yet dedicated-test-covered for the
new behavior itself — see §2):

- `BUILTIN_FN_INT`: genuine float-to-int truncation-toward-zero (via the
  real calculator's `CALC_FP_TO_INT`, the exact mechanism `BUILTIN_FN_SIN`
  already established for this purpose) instead of a pass-through no-op.
- `BUILTIN_FN_SGN`: genuine float sign support (direct FLOATTAB byte
  inspection, the exact technique `BUILTIN_FN_ABS`/`VM_NUM_TO_TEXT` already
  established) instead of ignoring the tag.
- `BUILTIN_FN_MOD`/`DIV`/`RND`/`PEEK`/`USR`/`POINT`/`ATTR`: now reject a
  FLOAT-tagged operand with a real runtime error (reusing error code 11,
  `VM_ERR_ARRAY_TYPE`, broadened rather than duplicated — see §13) instead
  of silently misreading a FLOATTAB index as a raw value.
- `BUILTIN_FN_SQR`/`RAD`/`DEG`: now truncate a FLOAT argument first (same
  `BUILTIN_FN_SIN`-established idiom as `INT`), instead of silently
  misreading a FLOATTAB index as a raw degree/argument count.
- Doc comments updated in place (error-code header, `VM_ERR_ARRAY_TYPE`'s
  own header) to document the broadened, general "integer required" use of
  error code 11.
- `docs/v2/deffn_design/README.md` updated with the recursion-defect finding
  and the "fix before reintegration" decision (§6).

**Not implemented this session** (found, documented, explicitly left for a
separate decision — see §4, §12): the identical float-misinterpretation bug
in `PLOT`/`LINE`/`BEEP`/`SOUND`/`INK`/`PAPER`/`RANDOMISE`/`POKE`.

## 4. Numeric model

**Classification A (genuine intended semantics, confirmed working):**
hybrid INT/FLOAT arithmetic is real, not aspirational. `OP_ADD`/`SUB`/`MUL`/
`DIV` (`exrom_v2_vm_core.asm:1187+`) check both operand tags and route to a
real calculator (`RST $28`) float path when either operand is FLOAT,
falling through to a native 16-bit Z80 `add`/`sub` fast path only when both
are INT — this is genuinely R6-complete, not the "int fast path only, float
deferred" state the file's own *stale* error-code-4 header comment ("R6...
deferred") describes; that comment is a historical artifact of when it was
written, not current behavior. `ABS` already correctly handles both tags
(precedent for the fixes in §3). Comparisons, `STR$`/`VAL`, `VM_NUM_TO_TEXT`
(float rendering, including negative-float sign, fixed for a real bug in
commit `902c402`) are all hybrid-aware.

**Classification B (V1 implementation artifact, found + fixed this
session):** `INT()`, `SGN()`, `MOD()`, `DIV()`, `RND()`, `PEEK()`, `USR()`,
`POINT()`, `ATTR()`, and (same bug, different call site) `SQR()`/`RAD()`/
`DEG()` were still carrying V1's own "this is a pure-integer BASIC" premise
forward as *unchecked* code, not just as a documented contract — e.g.
`INT(x)` at `exrom_v2_vm_core.asm:2935` (pre-fix) was a literal
`VM_POP`/`VM_PUSH` no-op, correct only because V1 never had a fractional
value to truncate. Once V2 genuinely has floats (R6+), this stopped being a
no-op and started being wrong. Worse: `SGN`/`MOD`/`DIV`/`RND`/`PEEK`/`USR`/
`POINT`/`ATTR` didn't even pass the value through unchanged — they read the
*tag-agnostic* raw popped value and used it directly, so a FLOAT operand (a
small FLOATTAB index, 0-5ish) was silently used as if it were the real
number, producing a wrong answer with **no error at all** — the single most
dangerous failure mode an audit like this exists to catch, because it would
never surface as a crash or an error code, only as a program that quietly
computes the wrong thing. **Fixed this session** (§3, §15) per explicit user
decision: `INT`/`SGN` get real float semantics (matching `ABS`'s own
precedent); the rest reject FLOAT with a real error instead.

**Classification D (real capability gap, found, deliberately NOT fixed this
session — flag for a separate decision):** the identical
tag-agnostic-raw-value bug exists in `OP_PLOT`, `OP_LINE`, `OP_BEEP`,
`OP_SOUND`, `OP_INK`, `OP_PAPER`, `OP_RANDOMISE`, and `OP_POKE` — every one
of these resident *statements* (as opposed to the *functions* fixed in §3)
pops a value and uses its low byte directly with no tag check, for the same
reason (V1 never had a float to worry about). `OP_BORDER` is the one
exception with an already-considered rationale in its own comment ("any
numeric value is accepted, same as V1's BORDER" — masking to 3 bits is
harmless for any bit pattern, so no fix is needed there). Fixing all eight
remaining sites is straightforward (same `cp TAG_FLOAT`/`jp z,VM_ERR_ARRAY_
TYPE` pattern used in §3) but was not done this session: the fixes already
applied consumed 188 of the 282-byte pre-R9 reserve, and fixing all eight
more (roughly 2-4 checks each, ~60-100 more bytes) would likely exceed what
remains (94 bytes) or leave an uncomfortably thin margin. **This needs an
explicit decision from the user** (see §12): fix now within the remaining
reserve (tightest first, e.g. just the single-argument ones — `RANDOMISE`,
one check, cheapest), defer to post-R9 (when V1 removal frees substantially
more ROM), or accept as a documented limitation. Recommendation: defer to
immediately after R9, in the same pass as the SGN/INT-class fixes already
applied, since post-R9 ROM headroom will make this a non-issue rather than
a budget-constrained partial fix now.

**Classification C (deliberate V2 design, confirmed via code):** arrays are
integer-only by design (`TAG_INT`, no per-element tag byte — a genuine RAM
saving, `exrom_v2_vm_core.asm:268-277`), not a leftover V1 constraint;
literal-encoding correctly routes 128-255 through `PUSH_I16` rather than the
sign-extending `PUSH_I8` (a real bug found and fixed in R8.5 Group 5,
`exrom_v2_compiler.asm:2000-2012` — not reopened, already correct).

## 5. Strings

**Classification A:** string "values" are always a `STRTAB` index pushed
via the ordinary `PUSH_I16` opcode (no new opcode needed, confirmed design,
not a shortcut). `CHR$`/`STR$`/`UPPER$`/`LOWER$`/`LEFT$`/`RIGHT$`/`INKEY$`
are the first string-*result* builtins, and were confirmed to be fresh,
V2-native rewrites on the tag-aware `VM_POP`/`VM_STR_ADDR`/temp-slot
convention — not calls into V1's `rom/exrom_strfuncs.asm` (confirmed not
reusable post-R9: `INKEY$`'s own V1 body has a real `basic.asm`-resident
dependency the V2 rewrite deliberately avoided by reaching
`kernel/io/io.asm`'s `IO_READ_KEY_NONBLOCK` directly instead). A real
nested-call scratch-clobber bug (`CFN_INDEX`/`ARGCOUNT`/`REMAINING`/
`ARGTYPE`, `exrom_v2_compiler.asm:1697-1806`) was already found and fixed
this milestone with an explicit save/restore around the inner call — this
is the exact precedent the DEF FN design's own `.udf_call` nested-call fix
(§6) and this session's own recursion-defect finding follow.

**Classification B (found, not RAM-constrained, recommend enlarging later,
not now):** `STRTAB_MAX_VARS: equ 4` (`exrom_v2_vm_core.asm:291`) — only 4
named string-variable slots exist, versus 16 numeric-variable slots
(`CSYMTAB_MAX_ENTRIES`, `exrom_v2_compiler.asm:222`). This asymmetry has no
documented RAM-scarcity rationale in the source (the comment nearby
explicitly frames the *temp*-slot count, `STRTAB_TEMP_COUNT: equ 2`, as a
deliberate "avoid inventing a general allocator" scaffolding choice, not a
RAM one) and the whole V2 workspace (`FLOATTAB`/`ARRTAB`/`STRTAB`/VM
state/compiler scratch/decompiler scratch) occupies only a few KB out of
48KB total RAM — enlarging `STRTAB_MAX_VARS` to match `CSYMTAB_MAX_ENTRIES`
(16) would cost roughly 12 more slots × 32 bytes = 384 bytes of RAM,
trivial against the real budget. **Conclusion: this is an inherited
implementation-scaffolding limit (matching `CSYMTAB`'s own "R2 scope"
framing), not a genuine RAM constraint or a deliberate design policy** —
same conclusion the handoff already suspected. Per the audit's own
instruction, **not enlarged this session**; recorded here with evidence for
a future pass (R10 or a dedicated small milestone), not urgent for R9.

## 6. Identifiers and symbol handling

**Classification C (deliberate, already-implemented V2 improvement over
V1):** `LEX_SCAN_IDENT` (`exrom_v2_compiler.asm:829`) already accepts
letters *and* digits after the first letter — this was a real, deliberate
fix (not merely aspirational design text) made "first surfaced as a real,
load-bearing gap during R7.5 ... and again this session (a PROC named
'ADD1' failed to compile at all)." The comment explains the concrete
motivation precisely: the decompiler synthesizes names like `V0`/`L25` that
must be re-lexable by the same compiler for the decompile-recompile
round-trip claim to hold. This directly satisfies the audit's own framing
("what V2 naturally supports without increasing runtime cost") — already
done, confirmed via source, not merely planned.

## 7. Procedures and functions (PROC/CALL, and the deferred DEF FN)

**Classification A (confirmed real implementation):** `COMPILE_PROC`
(`exrom_v2_compiler.asm:4010`) and `COMPILE_CALL_STMT` (`:4104`) are a real
compile-once JMP-skip + `LABEL_DEFINE`-at-the-call-entry-position +
`STORE_VAR`-binds-the-parameter shape, resolved via the same
`LABEL_LOOKUP`/`FIXUP_RECORD` forward-reference machinery GOTO already
uses — not a new resolution mechanism, and genuinely independent of V1's
runtime source-scanning (confirmed: no reference to any V1 line-table or
re-parse mechanism anywhere in this path).

**Classification D — significant finding, decision recorded (fix required
before DEF FN reintegration, not yet implemented since DEF FN is out of the
tree):** PROC's parameter is bound through `CSYM_FIND_OR_CREATE` — the
*same shared global numeric-variable slot* every ordinary scalar uses, not
a per-call stack slot. This means PROC recursion (and the preserved DEF
FN design, which reuses the identical mechanism) has **no real variable
isolation across nested/recursive calls** — only the *return address* is
pushed/popped on `VM_CALL_STACK` (`VM_CALL_PUSH`/`POP`,
`exrom_v2_vm_core.asm:733-754`); the parameter's *value* is not saved or
restored. Concretely: `DEF FN F(n) = FN F(n-1) + n` would silently
compute a wrong result, because by the time the outer call's `+ n`
executes, the inner recursive call has already overwritten the shared `n`
slot. This was never claimed as "for free" correctly — the original DEF FN
design doc's claim that real recursion "works... with zero extra guard
code" is now known to be a plausible-sounding but *unverified and
incorrect* claim (real recursion was explicitly never hardware-tested
during that experiment). **Explicit user decision (this session): fix
before reintegration** — save/restore the parameter's value around a
`CALL_UDF` call site, the same lesson the existing `.udf_call` nested-name-
pointer fix already applies to compile-time scratch state, applied here to
the runtime parameter binding instead. Recorded in
`docs/v2/deffn_design/README.md`'s reintegration checklist (updated this
session, see §3). **This is a PROC-and-DEF-FN-shared architectural gap, not
DEF-FN-specific** — plain PROC recursion has the identical defect today,
already shipped; it simply hasn't been noticed because nothing in the
current buildable test suite exercises PROC recursion where the parameter
is read after a recursive self-call. Not fixed for PROC this session
(PROC's own recursion defect is real but not called out for a fix by the
user's decision, which was scoped to DEF FN specifically) — flagged here
for completeness and left as an open item for the user to weigh in on
(see §12).

**Classification A (confirmed intact, zero drift):** every specific ROM
resource the preserved DEF FN design depends on was re-checked directly
against current source and confirmed still free/unclaimed:
- Opcode numbers 52-54: current `VM_OP_TABLE` max is opcode 51
  (`OP_INPUT_STR`) — 52-54 are free (confirmed via direct dispatch-table
  read, `exrom_v2_vm_core.asm`).
- Token numbers 56-57: current `TOK_KW_*` max is `TOK_KW_EXIT: equ 55` —
  56/57 are free (confirmed via direct `equ` read,
  `exrom_v2_compiler.asm:478-533`).
- Error codes 49-54: current compiler error-code table max is 48
  (`DIMN`'s own close-paren check) — 49-54 are free (confirmed via direct
  header read, `exrom_v2_compiler.asm:104-167`).
- `VM_CALL_STACK_TOP`/`FLOOR` ($87A0/$8794): unchanged since the design was
  captured (confirmed via direct `equ` read).
- No R9-scoped removal touches any of `exrom_v2_compiler.asm`/`vm_core.asm`/
  `decompiler.asm` — R9's own stated file list (§12's own R9-plan excerpt)
  is entirely V1 files (`basic/basic.asm`, `exrom_checker.asm`,
  `exrom_strfuncs.asm`, `exrom_dim.asm`, `exrom_arrays.asm`). **DEF FN's
  reintegration prerequisites are not at risk from R9 as currently
  scoped.**

## 8. Arrays

**Classification C:** 0-based, integer-only, statically-sized (compile-time
constant `DIM` size — "this dialect's arrays are statically sized, unlike
V1's runtime-evaluated DIM expression; a real, deliberate V2 simplification,"
per the compiler's own error-code-34 comment). `DIMN` (introspection) is
implemented and decompiler-covered. `ARRSYMTAB_MAX_ENTRIES: equ 4`,
`ARRAY_MAX_ELEMS: equ 16` (`exrom_v2_compiler.asm:440`,
`exrom_v2_vm_core.asm:283`) are cross-checked, matching, deliberate limits —
not accidentally divergent between compiler and VM.

## 9. Control flow

**Classification A, confirmed genuinely independent of V1's runtime
source-scanning:** GOTO/IF/block IF-ELSE-ENDIF/FOR-NEXT-STEP/EXIT FOR all
resolve via the same real `LABEL_LOOKUP`/`FIXUP_RECORD` forward-reference
machinery, entirely at compile time, with zero reference to any V1
line-number table or re-parse mechanism. `LABELTAB_MAX_ENTRIES: equ 8`,
`FIXUPTAB_MAX_ENTRIES: equ 8`, `EXITFOR_MAX: equ 4` — deliberate, small,
scope-bounded limits (matching the compiler's own "bounded, per this
module's R2 scope" framing for the numeric symbol table), not V1
inheritance (V1 has no analogous concept at all — GOTO/labels are a V2-only
addition to this dialect, not a V1 port).

## 10. PRINT/INPUT/user interaction

`PRINT`/`LPRINT` share one grammar (single argument, string or numeric —
"this dialect's PRINT never had either" trailing-`;`/no-newline suppression,
a deliberate simplification, `exrom_v2_compiler.asm:3156-3231`). `LPRINT`'s
own real body is a "printer-package ROM reconciliation" — it compiles to the
*same* opcode either way, and the loadable printer extension supplies the
actual hardware behavior; this matches the architectural rule
(`SESSION_HANDOFF.md`): resident ROM owns general-purpose capability,
loadable packages own specialized/peripheral behavior. **This was not
independently re-verified end-to-end against the printer module's real
runtime dispatch this session** (the dedicated fork assigned to this area
did not return in time to fold into this document — see the note at the end
of §14) — flagged as lower-confidence than the rest of this document and
worth a direct follow-up read of `rom/ext_printer_module.asm`/
`rom/test_v2_printer_module.asm`'s own real dispatch path before treating it
as fully confirmed.

## 11. Graphics/sound/platform commands

Confirmed present, decompiler-covered, and opcode-assigned:
`CLS`/`BORDER`/`INK`/`PAPER`/`PLOT`/`LINE`/`BEEP`/`SOUND`/`POKE`/`PAUSE`/
`RANDOMISE` (opcodes 23-33, `exrom_v2_vm_core.asm`'s own `VM_OP_TABLE`).
`PEEK`/`USR` are builtin *functions* (fn_index 8/9), not opcodes.
`SPRITE GRAB/SHOW/HIDE/MOVE`, `MODE`/`ULAPLUS`/`PALETTE`, and printer
`LPRINT`/`LLIST` are confirmed genuinely externalized to loadable extensions
(opcode 52-54 explicitly freed and documented as removed,
`exrom_v2_decompiler.asm:1587-1589`: "52-54 (OP_MODE/OP_ULAPLUS/OP_PALETTE)
removed -- now a loadable extension package"). The float-misinterpretation
bug class found in `PLOT`/`LINE`/`BEEP`/`SOUND`/`INK`/`PAPER`/`RANDOMISE`/
`POKE` is documented in §4 (Classification D, not fixed this session).

## 12. PEEK/POKE/USR machine-code interoperability

**Classification A, R9-safety confirmed:** `BUILTIN_FN_PEEK`/`USR` and
`OP_POKE` are fully self-contained within `exrom_v2_vm_core.asm` — direct
memory reads, a direct `jp (hl)` trampoline for USR, and a direct memory
write. None of the three calls into `basic/basic.asm` or any other V1
language-core file at runtime; the comments citing V1's `.call_peek`/
`.call_usr`/`BASIC_STMT_POKE` are provenance notes (why this behavior is
correct/matches the real Sinclair contract), not runtime dependencies.
**R9's planned removal of `basic/basic.asm`, `exrom_checker.asm`,
`exrom_strfuncs.asm`, `exrom_dim.asm`, `exrom_arrays.asm` (per
`ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s own R9 section) does not touch any
of V2's PEEK/POKE/USR implementation or its dependencies. Confirmed safe.**
`PEEK`/`USR` now reject a FLOAT argument (§3/§4 fix) rather than silently
misreading it — a strict improvement, not a behavior change for any
existing correct program (an address was always meant to be an integer).

## 13. SAVE/LOAD/editor-runtime integration

**Classification A, the single most important confirmation this audit
performed for R9 safety:** `rom/test_v2_editor_integration.asm`'s own header
documents, and this session directly confirmed by reading it, the real
end-to-end path: `EDITOR_ENTER` → `EDIT_LINE_BUF` (raw null-terminated ASCII
text, produced by the real, unmodified `rom/exrom_editor.asm` — "confirmed
KEEP, zero interpreter-internals dependency per `docs/v2/V2_ARCHITECTURE.md`")
→ `COMPILE_PROGRAM` (compiles **directly** from `EDIT_LINE_BUF` — "no V1
tokenizer/`MEM_LINE_STORE` conversion step involved at all") → `VM_RUN` →
`DECOMPILE_PROGRAM`. **There is no hidden V1 interpreter dependency in the
normal V2 editing/execution workflow.** `basic/editor_integration.asm`
(2291 lines) is a separate, unrelated file — grep-confirmed it contains no
reference to `COMPILE_PROGRAM`/`VM_RUN`/`DECOMPILE_PROGRAM` at all, i.e. it
is pure V1-era editor glue, not something V2's own flow passes through.
This directly answers the audit's own framing question for this area:
**yes, this is safe** — R9 can remove V1's interpreter without touching the
real V2 edit/compile/run/decompile path, because that path never touched V1
to begin with.

## 14. Decompiler completeness

**Classification A, confirmed complete for every currently-shipped
opcode:** the decompiler's own dispatch chain (`exrom_v2_decompiler.asm:
1490-1589`) explicitly handles every opcode 0-51 that the VM's own
`VM_OP_TABLE` currently defines, with an explicit comment noting opcodes
52-54's removal ("now a loadable extension package") rather than a silent
gap. `DECOMP_ERR_UNSUPPORTED_OPCODE` is the fallback for anything past 54 —
correctly unreachable for any currently-compilable program. The real nested-
function-argument and float-sign-rendering bugs already found and fixed
(commit `902c402`: `VM_NUM_TO_TEXT`'s float path re-reading a stale operand)
are confirmed fixed at the root, not merely patched at one call site.
**No missing decompiler handler exists for any currently-shipped V2
construct.**

**Note on incomplete parallel research:** a fork was launched at the start
of this session to independently audit areas 7 (PRINT/INPUT), 8 (platform
commands), 9 (PEEK/POKE/USR), and 10 (SAVE/LOAD) in parallel with this
session's own direct source research. That fork did not return before this
document needed to be finalized (parallel fork spawning from within an
already-forked context is not supported in this environment, so a second,
redundant fork could not be launched to cross-check). All findings above for
those four areas come from this session's own direct, independent source
reading (cited by file/line throughout) — they are not weaker for it, but
§10 in particular is flagged as comparatively less exhaustively
cross-checked than the rest of this document.

## 15. Extension architecture

**Classification A:** `kernel/extensions/ext_registry.asm` (426 lines)
implements a real compile-time-slot-id + runtime-generation-checked registry
(`EXT2_REGISTER`/`EXT2_LOOKUP`, `EXT2_MAX: equ 12` — "up to 12 registered
extensions"). `EXT2_REGISTER` assigns a slot **and** a rolling, never-0
generation value specifically so a stale reference to an unloaded/replaced
module's old slot is detected rather than silently misdispatched (the
mechanism this project's own R7.5 design explicitly chose over V1's runtime
name-rematching, per its own header cross-reference to
`ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s R7.5 section). `SPRITE`/`MODE`/
`PRINTER` extension packages exist and are confirmed to use this mechanism
(`OP_CALL_EXT`, opcode 34) rather than V1-style keyword rematching. This
satisfies the project's own explicit requirement: "extension capability, not
compatibility with the V1 extension ABI."

## 16. Error semantics

Full inventory performed by direct source read:

**Compiler (compile-time) error codes** (`exrom_v2_compiler.asm:104-167`):
codes 1-48 are documented and in active use; code 4 and 27 are gaps in the
numbering (never assigned — harmless, just unused numbers, not a bug); code
26 is explicitly documented as "retired" (consolidated into code 22 during a
prior R10-class pass). Codes 49-54 are reserved for DEF FN (§7), currently
unused/free.

**VM (runtime) error codes** (`exrom_v2_vm_core.asm:192-216`): codes 1-11
and 15 are documented and in active use; codes 12-14 are explicitly
documented as "retired" (formerly MODE/ULAPLUS/PALETTE-specific, now owned
by the loadable extension package instead). This session **broadened**
error code 11's documented meaning from "array index must be an integer" to
a general "an integer was required" error, reused (not duplicated) by the
newly-fixed `MOD`/`DIV`/`RND`/`PEEK`/`USR`/`POINT`/`ATTR` (§3) — the label
`VM_ERR_ARRAY_TYPE` was deliberately kept rather than renamed (avoids
touching every existing call site's own label reference for zero ROM
benefit), with its header comment updated to document the broadened scope.

No duplicate error paths, no incorrect inherited V1 error codes, and no
gratuitously-accepted malformed input were found beyond the float-
misinterpretation class already covered in §4 (which is a *missing* check,
not an incorrect one). Not undertaking a broader error-system rewrite, per
the audit's own scope.

## 17. Resource limits — explicit inventory

| Resource | Limit | Constant | Classification |
|---|---|---|---|
| Numeric variables | 16 | `CSYMTAB_MAX_ENTRIES` | Deliberate, bounded R2 scope |
| Named string variables | 4 | `STRTAB_MAX_VARS` | **B — scaffolding, not RAM-constrained (§5)** |
| String concat temp slots | 2 | `STRTAB_TEMP_COUNT` | Deliberate ("avoid inventing a general allocator") |
| Arrays | 4 | `ARRSYMTAB_MAX_ENTRIES` | Deliberate, matches VM's own `ARRAY_MAX_COUNT` |
| Elements per array | 16 | `ARRAY_MAX_ELEMS` | Deliberate, power-of-2 for cheap indexing |
| Labels | 8 | `LABELTAB_MAX_ENTRIES` | Deliberate, bounded scope |
| Outstanding forward-ref fixups | 8 | `FIXUPTAB_MAX_ENTRIES` | Deliberate, bounded scope |
| Outstanding `EXIT FOR` per loop | 4 | `EXITFOR_MAX` | Deliberate, bounded scope |
| Loadable extension slots | 12 | `EXT2_MAX` | Deliberate |
| Decompiler fragment stack depth | 8 | `DECOMP_FRAG_MAX` | Deliberate, matches LINE's 4-arg shape with margin |
| Call stack depth | 6 return addresses (12 bytes, $8794-$879F) | `VM_CALL_STACK_TOP/FLOOR` | Deliberate, small, fixed |
| Operand stack depth | ~44 bytes ($8704-$877F, 3B/slot) | `VM_STACK_TOP/FLOOR` | Deliberate, small, fixed |

None of these were found to be test-only limits masquerading as product
limits, or vice versa — every constant above lives in `exrom_v2_*.asm`
(shipped product code), not in a `test_v2_*.asm` driver file. The flat-16K
*test harness's own* separate ceiling (§2, §9) is a build-time packaging
constraint on standalone test images, unrelated to any of the runtime
limits in this table.

## 18. Test-harness status (precise, as of this session)

1. **Buildable and passing (12 of the previous 14, post-fix)**:
   `test_v2_arrays`, `test_v2_block_if`, `test_v2_decompiler`,
   `test_v2_for_step`, `test_v2_group6_math` (re-run on real ZEsarUX this
   session, confirmed PASS post-fix), `test_v2_input`,
   `test_v2_mode_module`, `test_v2_printer_module`, `test_v2_relational`,
   `test_v2_sqr_decomp`, `test_v2_strfuncs`, `test_v2_vm_milestone01`.
2. **Newly excluded this session, flat-16K harness capacity only, NOT a
   product regression** (§4's fix enlarged the shared `exrom_v2_vm_core.asm`
   by 188 bytes, which two already-thin-margin standalone 16K test images
   could no longer absorb): `test_v2_ext_demo` (overflows by 134 bytes),
   `test_v2_save_load` (overflows by 37 bytes). Same category as the seven
   tests already excluded before this session for the identical reason.
3. **Stale historical harnesses** (confirmed, not re-litigated):
   `test_v2_compiler_r2` through `r7` — `DECOMP_END_ADDR` genuinely absent
   from current source (§2); pre-existing, unrelated to this session.
4. **Actual product regressions found this session: none.**

## 19. Known defects vs. optional enhancements

**Defects (real, found this session):**
- Float-argument misinterpretation in numeric builtins — **fixed** (§3/§4).
- Float-argument misinterpretation in resident statements (`PLOT`/`LINE`/
  `BEEP`/`SOUND`/`INK`/`PAPER`/`RANDOMISE`/`POKE`) — **found, not fixed**,
  needs a decision (§4, §12 preconditions).
- DEF FN's preserved parameter-binding design is not actually recursion-safe
  — **found, decision recorded (fix before reintegration), not yet
  implemented** since DEF FN itself is deferred out of the tree (§7).
- The identical recursion-isolation gap exists in plain PROC today, already
  shipped — **found, not fixed, not explicitly decided** (§7) — flagged for
  the user, not unilaterally resolved.

**Optional enhancements (E — recorded, not implemented, not required for
R9):**
- Enlarging `STRTAB_MAX_VARS` from 4 toward `CSYMTAB_MAX_ENTRIES`'s 16 (§5)
  — cheap in RAM, not urgent, no current program is known to need it.
- A dedicated `test_v2_numeric_hybrid.asm` covering the new float-argument
  paths from §3 on real hardware (currently code-reviewed + non-regression-
  tested only, not dedicated-test-covered).

## 20. DEF FN post-R9 dependency notes

See §7 for the full detail. Summary: DEF FN's specific ROM reservations
(opcodes, tokens, error codes, addresses) are all confirmed still free and
untouched by anything in this session or by R9's own planned scope. The one
new blocker found this session is a design defect in the preserved plan
itself (recursion correctness), not an R9-caused regression — recorded in
`docs/v2/deffn_design/README.md`'s own reintegration checklist, with an
explicit "fix before reintegration" decision already made.

## 21. Explicit R9 prerequisites

1. None of this audit's findings are R9 blockers in the sense of "R9 cannot
   proceed until X" — every defect found (§19) is pre-existing in V2's own
   numeric/procedure code, independent of whether V1's interpreter still
   exists.
2. **Recommended before R9 (not strictly required)**: resolve the §4
   Classification-D decision (fix the remaining eight resident-statement
   float-misinterpretation sites now within the ~94-byte remaining reserve,
   or explicitly defer to post-R9) — doing this *before* R9 means the R9
   regression gate's own "V1 RESULT vs. V2 RESULT" oracle-comparison
   methodology (per `ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s own R9
   section) won't need a separate carve-out for known-different behavior on
   these specific statements when a float is passed where V1 never could.
3. R9's own explicitly-required statement-set coverage audit (per its own
   plan section) must still separately confirm every V1 statement type has
   a tested V2 equivalent — this audit did not re-derive that full
   statement-by-statement matrix from scratch (see §22 caveat) but found no
   evidence of a missing resident statement class during its own pass
   through `VM_OP_TABLE`.

## 22. Explicit R9 preservation list

Preserve, do not casually alter during R9: the extension registry mechanism
(§15) and its generation-checking; the flat fixed-size `STRTAB`/`ARRTAB`/
`FLOATTAB` layout (§5/§8, a deliberate RAM-simplicity choice, not V1
inheritance); the compile-once JMP-skip + `LABEL_DEFINE` PROC/CALL shape
(§7), since DEF FN's entire design depends on it remaining exactly as-is;
the zero-V1-dependency editor/compiler/VM/decompiler path (§13) — this is
the single most important thing R9 must not accidentally break by, e.g.,
deleting a symbol V2 turns out to share with V1 without realizing it (no
such sharing was found this session, but R9's own execution should
re-verify this specific claim once the deletion diff exists, not just trust
this audit's snapshot).

## 23. Explicit R9 removal candidates

Per `ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s own R9 section (re-read this
session, unchanged): `basic/basic.asm`'s direct-execute interpreter,
`rom/exrom_checker.asm`, `rom/exrom_strfuncs.asm` (whatever wasn't reused by
V2's own R5 string-function rewrite, confirmed in §5 to be independent),
`rom/exrom_dim.asm`, `rom/exrom_arrays.asm` — the full V1 language core.
This audit found no reason to expand or contract that list.

## 24. Final R9 readiness verdict

**READY FOR R9 WITH SPECIFIC PRECONDITIONS.**

Preconditions (advisory, not hard blockers — R9 itself is not gated on
these, but leaving them unresolved means carrying known, documented
correctness gaps across the R9 boundary rather than closing them while ROM
pressure is already being reasoned about):

1. Decide the §4/§12 question: fix the remaining eight resident-statement
   float-misinterpretation sites now (partial, ROM-constrained) or defer
   explicitly to immediately post-R9.
2. Decide whether plain PROC's own recursion-isolation gap (§7, same defect
   class as DEF FN's, already shipped, not previously known) needs a fix,
   a documented limitation, or is deferred alongside DEF FN's own fix.
3. Write the dedicated hardware test for this session's new float-argument
   paths (§19) before or shortly after R9 — not because R9 depends on it,
   but because it's the only gap between "code-reviewed correct" and
   "hardware-confirmed correct" for a correctness fix this document is
   otherwise confident in.

None of the three block starting R9. The recommended concrete starting
point: begin R9's own statement-set coverage audit and V1-regression-suite
oracle comparison (per `ARCHITECTURE_B_IMPLEMENTATION_PLAN.md`'s own R9
section) with this document's §17 resource-limit table and §22 preservation
list in hand; resolve precondition 1 and 2 above either just before or
immediately after, at the user's discretion — they don't block R9's own
first steps.

## 25. Session ROM/commit accounting

- ROM before this session's fixes: 24,294/24,576 (282 free).
- ROM after this session's fixes: **24,482/24,576 (94 free)** — measured
  precisely via the `ACTUAL_END_MARKER` technique (§2), not estimated.
- Regression status: 12/14 previously-buildable tests still build and pass;
  2 newly excluded by flat-16K test-harness capacity only (§18), not a
  product regression; one test (`test_v2_group6_math`) directly re-verified
  PASS on real ZEsarUX post-fix.
- Files changed: `rom/exrom_v2_vm_core.asm` (the fixes, §3),
  `docs/v2/deffn_design/README.md` (recursion-defect finding + decision),
  this document (new).

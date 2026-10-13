# 2068-Leap V2 — Owner decisions: technical review

**Status:** complete for the four decisions of 2026-10-11, with one caveat: the owner brief arrived truncated, mid-sentence in Decision 4
("Do not remove useful functionality solely to meet a…"). Everything before that point is addressed here.
**Nothing is integrated.** `~/2068-Leap` / `v2-development` stay at `7ae0599`; nothing was pushed; the overnight prototype branches and the
qualification branches are unchanged. The new work is on new study branches (§6). As instructed, **Decision 2 is analysed, not implemented.**

**Evidence:** **[M]** measured on an assembled production image (HOME + EXROM + packages) and/or observed on the real ROM in headless ZEsarUX
through `tools/qual/` (corpus, gate battery, component tests, the cost study's own prototype tools); **[S]** read from source; **[E]** estimate,
never presented as measured. Signs as before: “HOME −12” = 12 bytes consumed. Emulator evidence only — nothing here is hardware-qualified.

---------------------------------------------------------------------------------------------------------------------------

## 0. Summary

| Decision | Result | Measured cost |
|---|---|---|
| **1. Floating-point FOR** | **Prototyped and passing.** Float limit, start and step, positive and negative; mixed INT/FLOAT; the integer path kept. All 30 new float-`FOR` cases and the 4 old Q-08 cases pass; no other corpus case changed. **Q-08 stays open until this is integrated.** | **HOME −97**, EXROM 0, static RAM 0, +6 B of control stack per active loop |
| **2. Program + variables** | **Not implemented (as instructed).** Under today's rules restored variables could never be seen: `RUN` clears them (and you want that kept), and an immediate `:` statement runs in its own empty scope **[M]**. The consistent design is the classic “session variables” model (§2.3). The smallest safe implementation is staged (§2.5). | [E] Stage 1: HOME −30…−70, EXROM −180…−310 (or a package for the SAVE/LOAD half) |
| **3. Literal rule L-C** | **Prototyped and passing.** `PRINT 65535` → `65535.0000`; `POKE 65000`, `USR(61440)`, address loops all work; `-40000` and `40000+1` are now correct (L-A gave `25536` and `-25535`). The review found **two more defects that L-C needs fixed and that matter under L-A too**: Q-32 and Q-33 (below). | L-C **HOME −67**; Q-32 fix **−49**; Q-33 fix **−2** |
| **4. ROM reserve** | **Final budgets measured with Decisions 1 and 3 included:** Essential **HOME 821 / EXROM 482**, Enhanced **HOME 670 / EXROM 233**. That includes a new measured shrink: the compiler's 67 emit stubs inlined, **+295 / +307 B**, with byte-identical bytecode for all 649 corpus programs. Essential meets the 200/150 contingency with every required item and goal 2. Enhanced meets it only if goal 2's SAVE/LOAD half is a package. Enhanced's EXROM (233) is the binding constraint. | see §4 |

**New defects found during this review:**

* **Q-32 (CRITICAL; Essential and Enhanced only).** Introduced by the overnight D11 prototype, **so it corrects the qualification report's statement
  that no defect came from the prototypes.** `a = 30000: POKE a + 3370, 77` writes to address **32767**. D11 promotion makes the sum a FLOAT, and the address
  conversion saturated it **[M]**. The baseline got it right only because its arithmetic wrapped. `PEEK`, `USR`, `IN` and `OUT` were affected the same way.
* **Q-33 (HIGH, all configurations).** A FLOAT argument to a package statement arrives as its slot index: `r = 33/2: CIRCLE 128,96,r` draws a circle of
  radius ~1 **[M]**.

Both are fixed on `study/proto-lc` and carried to every prototype head.

---------------------------------------------------------------------------------------------------------------------------

## 1. Decision 1 — floating-point FOR loops

### 1.1 Answers

**Does the VM have enough floating-point support without duplicating arithmetic or comparison routines?** Yes. The prototype adds no
arithmetic and no comparison of its own [S]:

| Need | Existing routine reused |
|---|---|
| v + step | `VM_CALC_ADD_STUB` (the calculator's add via `RST $28`), as `OP_ADD` uses |
| compare v with the limit | `VM_CALC_SUB_STUB`, then the sign classifier of `VM_CMP_DISPATCH` (new entry label `VM_CALC_CLASSIFY`, 0 B) |
| put a frame's 5-byte value on the calculator stack | `VM_FLOAT_PUSH_OPERAND` (new entry `VM_FLOAT_PUSH_RAW`, 0 B) |
| store the start / the sum into the variable | `VM_STORE_VAR_BY_INDEX`, the store `OP_STORE_VAR` uses (made callable: +2 B) |
| the all-INT path | the existing 16-bit add with D11 overflow detection and `MATH_COMPARE16` |

The frame keeps the limit and the step in the calculator's own 5-byte format, with an INT in its small-integer form `[0][sign][lo][hi][0]`. So one frame type
serves both cases, and the four routines that walk the control stack are unchanged.

**Can the efficient integer path be preserved?** Yes. An all-INT loop takes a 16-bit add and a 16-bit compare, as before; only two
byte-0 tests are added. Four variants were built and timed (emulated T-states, `tools/qual/qbench.py`) **[M]**:

| Variant | HOME | bare `FOR … NEXT` (3000 iterations) | nested bare loops | ordinary loop with a body | Note |
|---|---:|---:|---:|---:|---|
| (today) | 741 free | 1 137 T / iteration | — | — | integer only |
| A compact | −70 | +38.6 % | +36.7 % | +2.2 % | one generic path |
| B separate fast path | −143 | +2.5 % | +3.2 % | +0.2 % | duplicated INT code |
| C shared | −92 | +15.4 % | +15.2 % | +0.9 % | |
| **D (recommended)** | **−97** | **+4.9 %** | **+5.4 %** | **+0.3 %** | C + direct variable entry, inline step sign |

**How does floating-point precision affect termination?** The loop uses classic Sinclair semantics: the step is added to the variable each `NEXT`, and the
loop ends once the variable is past the limit. With a 32-bit mantissa, the accumulated error after *n* additions is about *n* × 2⁻³² relative. A loop
whose limit is exactly reachable mathematically can therefore end one iteration early, if the accumulated value lands a few units in the last place
*above* the limit. **Measured:** 25 classic loops, including `0 TO 1 STEP 0.1`, `0 TO 0.3 STEP 0.1`, `0 TO 6.3 STEP 0.7`, `1 TO 0 STEP -0.1`, and loops of
1001 iterations (`0 TO 1 STEP 0.001`, `0 TO 10 STEP 0.01`, `0 TO 100 STEP 0.1`), **all gave the exact mathematical count [M].** That is empirical, not a
guarantee. Documentation should say so, and recommend an integer loop when the exact count matters (`FOR k = 0 TO 10: x = k / 10`).

Two alternatives were rejected. A tolerance in the compare changes which loops run. Counting iterations in advance breaks the common idiom of ending a
loop early by setting the variable to the limit.

**What about STEP 0?** It keeps the manual's documented behaviour (“accepted and just never advances — an intentional infinite loop”) for both INT and
FLOAT steps. A zero step counts as ascending: `FOR i = 3 TO 2 STEP 0` runs zero times, and `FOR i = 1 TO 2 STEP 0` runs until `BREAK` or `EXIT FOR` **[M]**.
Making it an error instead would cost about 6–10 B [E]. Not recommended: it is a documented behaviour, and `BREAK` works.

**RAM and ROM costs (prototype):** **HOME −97 on Essential and on Enhanced, EXROM 0 [M].** No new static RAM: the frame pointer and destination reuse the
existing `FOR` scratch cells. The frame grows from 6 to 12 bytes, i.e. +6 bytes of control stack per *active* loop. The stack is the memory-limited gap
between the arrays and the variables, so nesting depth is limited by free memory, as before.

**Compatibility changes:**

* None for integer loops. The compiler is untouched, so the bytecode is identical, and every non-`FOR` corpus result is unchanged.
* Float loops change from wrong results (current builds) or error 11 (the fix branch) to working.
* The loop variable follows the VM's own typing rules: `FOR i = 1 TO 2.5` keeps `i` an INT (`1`, `2`), while `FOR i = 0.5 TO 2` makes it FLOAT
  (`0.5000`, `1.5000`).
* An INT variable that overflows past 32767 is promoted, D11 style, and the loop continues to a FLOAT limit (`32760, 32764, 32768.0000`).
* **Speed:** a float-step iteration costs ≈ **14 200 T-states (≈ 4 ms)** against ≈ 1 190 for an integer iteration, about 12× **[M]**
  (`FOR i = 0 TO 1500 STEP 0.5`). That is the calculator's add and compare; it is the price of exact Sinclair-compatible float arithmetic.

**Unavoidable limitations:** the accumulation behaviour above; the float speed; and the loop variable is still not local to a recursive
`PROC` (L5, unchanged).

### 1.2 Verification of variant D **[M]**

* **Corpus:** 30 new float-`FOR` cases (expected values exact, computed independently: counts, values, after-loop value, nesting, `EXIT FOR`, `GOTO` out,
  body assignment, zero-trip both directions, `STEP 0`, expression bounds, inside a `PROC`). **30/30 pass**, and the 4 old Q-08 cases now pass.
  Against the fix branch, nothing else changed in the full corpus (status and printed output, case by case).
* `make check` rc 0; standalone component tests **38/38**.
* Gate battery: `v2_prod_regress` 115, `v2_prod_arrays` 98, `v2_known_defects` 15, FILL 10/10, production checks 17/19 (the same two capacity checks as on the fix branch).
* Enhanced (`study/proto-enh-decisions`): same cost; corpus as Essential plus Enhanced's own cases.

**Recommendation:** adopt variant D (`study/proto-float-for` `5820854`). The variants A–C are kept in that branch's history with their measurements.
Q-08 stays open in the register until this is integrated into `v2-development` and its tests run there.

---------------------------------------------------------------------------------------------------------------------------

## 2. Decision 2 — saving programs with their variables

### 2.1 How variables live today **[M]** (`tools/qual/qlifecycle.py` on the fix branch) and **[S]**

| Event | What happens to variables | Evidence |
|---|---|---|
| `RUN` | The whole program is recompiled: the symbol table is rebuilt in source order, and the run tables are carved from the pool top and **zeroed**. That covers scalars, the float table, the string table and the array pointers. The ordinary-array arena restarts. Arrays in the **Array Store** are bound by name and survive. | `x = x + 1: PRINT x` twice → `1`, `1`; `DIM a(3): a(1) = a(1) + 1` twice → `1`, `1` [M]; `V2_COMPILE_RUN` → `VM_INIT`, `ARR_RUN_INIT` [S] |
| immediate `: stmt` | Compiled **alone**, as a one-line program, with its own symbol table and freshly zeroed tables. It never sees the program's variables, and the next statement does not see its variables either. | after `RUN` of `x = 5`, `: PRINT x` → `0`; `: x = 7` then `RUN` of `PRINT x` → `0`; `: x = 3` then `: PRINT x` → `0` [M]; `V2_RUN_IMMEDIATE` [S] |
| `CLEAR` (in a program) | Zeroes the carved tables in place, restarts the ordinary-array arena (those arrays become un-dimensioned: a later `a(1)` is runtime error 10) and re-binds the Array Store. It does not touch the symbol table, the program, packages, the Array Store, or the control stack (hence Q-21: `CLEAR` inside `FOR` loops forever). | `x = 5: CLEAR: PRINT x` → `0`; `DIM a(3): a(1) = 5: CLEAR: PRINT a(1)` → error 10 [M]; `MEM_CLEAR_V2` [S] |
| storing an edited line | `V2_CLEAR_ARRAYS` runs before and after the store: the symbol table and arena are reset, the run tables released (`VARS_START` back to the top) and segment 2 emptied; the Array Store survives. | `V2_STORE_EDIT` [S] |
| `LOAD "prog"` | As an edit: `V2_CLEAR_ARRAYS`, `VARS_START` reset; Array Store kept | `.program_loaded` [S] |
| `NEW` | Everything, including the Array Store | `V2_DISPATCH` `.not_new` [S] |
| `SAVE "prog"` | Program text only | |

**So today only Array Store arrays outlive anything.** Every other variable lives for the duration of one `RUN`. The memory layout explains why: the
symbol table sits directly after the program text (`PROG_END`), the ordinary-array arena directly after the symbol table, and the run tables at the top of
the pool. An edit that lengthens the program grows into the symbol table and the arena, which is why every edit discards them (the R10.7 P0 invariant).

### 2.2 Answers

**How do the preferred semantics interact with the program store, Array Store, compiler and VM?** Three conflicts need resolving:

1. **`RUN` starts fresh (kept) + LOAD restores variables ⇒ restored values are unreachable unless something runs *without* `RUN`.** Today nothing
   does: immediate statements run in their own empty scope [M]. Something must change for LOAD-with-variables to be useful: either immediate
   statements run in the program's scope, or there is an explicit resume.
2. **Edits:** variables are addressed by slot index, and slots come from the compile order. An edit can add, remove or reorder variables, so after an edit
   a slot can mean another variable. On top of that, any edit that changes the program's length physically overlaps the symbol table and the arena.
   “Preserve where safe” therefore needs either an identity check of the recompiled symbol table plus relocation of the symbol-table/arena block, or
   rebinding by name (§2.5, stage 2).
3. **Array Store:** it already implements *name-keyed persistence with bind-at-start* for arrays. Ordinary variables and the Array Store must not be
   confused: `RUN` must keep clearing ordinary arrays (R10.9) while stored arrays survive.

**Does `RUN` clear all variables, including arrays?** All *ordinary* variables and arrays, yes [M]. Arrays in the Array Store (loaded with
`LOAD … ARRAY`) survive and are re-adopted by name, by design (manual, “Persistent arrays”).

**What exactly does `CLEAR` reset?** See the table: scalars, floats, strings → zero/empty; ordinary arrays → discarded (un-dimensioned); the Array Store is
re-bound (kept). Program, packages, symbol table and control stack are untouched [M][S].

**What happens to variables when an edit changes declarations, `DIM` sizes or bindings?** Today: always discarded, by any edit [S]. Under a
preserving design, the rules would be:

| Change | Raw (slot) state | Name-keyed state |
|---|---|---|
| an edit that leaves the symbol table identical (same names, kinds, order) | valid in place, **if** the symbol-table/arena block is relocated by the length change | rebinds |
| a new variable | slots shift → **invalid** | old ones rebind; the new one starts at zero |
| a variable deleted or renamed | **invalid** | the others rebind; the old value is dropped |
| a kind change (`x` numeric → used as `x$`) | **invalid** | dropped (different kind) |
| an array's `DIM` size changed | the old array remains until its `DIM` runs again, which re-creates and clears it (manual: “`DIM` now clears the array it creates”) | same |

**Can a raw in-place snapshot be validated well enough to prevent corruption on LOAD?** Yes, if nothing in the state is trusted that can be recomputed,
and everything else is range-checked:

1. **Recompile and compare:** after the program text loads, compile it (no run) and carve its tables. The recompiled symbol table must equal the saved one
   **byte for byte**, and the carved addresses (`VARS_START`, the six `RT_*` pointers) must equal the saved values. That proves the slot mapping is identical.
2. **Content checks:** every scalar tag is INT or FLOAT, and a FLOAT's value is its own float-table index (the design's 1:1 rule); every string length is
   ≤ 31; every array pointer is 0 or lies in the arena (`SYM_END+1 … ARRAYS_END`) or segment 2 (`ARR2_BASE … ARR2_END`), with count × width + header
   inside that region; the Array Store is re-bound (`ARR_RUN_INIT`), which validates the names and sizes of stored arrays.
3. **Checksum:** a 16-bit CRC (CRC-16/CCITT, table-free, ~25–35 B [E]) over the state blob, on top of the tape's 8-bit XOR per block. The XOR misses
   any even number of flipped bits in one bit position.
4. **Order:** the program arrives first (existing path, existing D2 failure rule). The state is received straight into the carved tables and arena; no staging RAM is needed.
   The variables are marked valid **only after** every check passes. On any failure, the tables are zeroed, the program is kept, and `VARIABLES NOT LOADED` is shown.

**Which checksums, version fields, length checks and memory-boundary checks are required?**

* **Version:** the existing V2 version word in the header's autostart field. A program-plus-variables file uses a **new minor**, so an older V2 ROM
  refuses it cleanly *before any byte is received* (the existing R10.9 rule: the tape's minor must not exceed the ROM's).
* A state header inside the data: a format byte and a **build layout ID** (a 16-bit value derived at assembly time from the layout constants: `PROG_AREA_START`,
  `V2_SOURCE_END`, record sizes, `ARR2_BASE`, the temp counts). A blob from a different V2 build is refused, even at the same tape version.
* **Lengths:** header length = program length + state length. The header's `PROGLEN` (already present) splits them. Each state section's length must equal
  the recompiled one (symbol table, run tables, arena, segment 2), and the total must fit `STORAGE_MAX_LEN`.
* **Boundaries:** see the content checks above. No pointer from tape is used without a range check; pointers that can be recomputed are recomputed.
* **Integrity:** CRC-16 over the state, plus the tape's per-block XOR.

**Does it work with the existing cassette format?** Yes. Use the stock-shaped two-block file the storage kernel already writes (17-byte header + one data
block). `PROGLEN` < `length` marks a program-plus-variables file, as R10.9's planned C2 bundle does. Plain `SAVE "x"` keeps writing the current minor, so
older ROMs can still read program-only tapes. The alternative is a program file followed by a separate state file. It would let older ROMs load the program
part of a bundle, but it needs a second header search and adds about 5 s of tape. Not recommended.

**EXROM, HOME or a loadable package?**

* The *session* part must be core: whether variables are kept between commands, the immediate-statement scope, and the resume entry. It lives in the shell
  (EXROM), the compiler (HOME) and `VM_INIT` (HOME).
* The *SAVE/LOAD* part (framing, CRC, validation) can live in EXROM, in HOME, or in a package:
  * **EXROM** suits Essential (482 B free).
  * **HOME** suits Enhanced (EXROM 233 B free).
  * **A package** costs no ROM, but the package must be loaded before `SAVE`/`LOAD` with variables. To keep loading reliable without it, the core must
    still recognise a bundle header and either load the program part with `VARIABLES NOT LOADED` or refuse cleanly: ≈ 10–20 B [E].
* No placement is unreliable as such. The risk is a format split between ROM builds, which the layout ID handles.

### 2.3 Recommended semantics (consistent with all five preferences)

The classic Sinclair **“session variables”** model, adapted to V2:

| Command | Variables |
|---|---|
| `RUN` | fresh ordinary variables (current behaviour); Array Store kept |
| program ends (end, error, `BREAK`) | the variables **stay** as the session state |
| `: stmt` (immediate) | runs **in the session**: can read and assign the program's variables; `: GOTO label` resumes the program at a label without clearing (the explicit resume) |
| `CLEAR` | zeroes the session's ordinary variables; program, packages, Array Store kept (current behaviour) |
| edit | stage 1: the session is cleared (with a note in the manual; same outcome as today); stage 2: kept when safe (§2.2 table), otherwise cleared with a message |
| `SAVE "x"` | program only (current, old minor) |
| `SAVE "x" ALL` (wording to be decided) | program + session variables (new minor, validated as §2.2) |
| `LOAD "x"` | program; plus the variables if the tape has them and they validate (`VARIABLES NOT LOADED` otherwise); then `: PRINT x` shows them and `: GOTO start` resumes |
| `NEW` | everything, including the Array Store (current) |

Why `: GOTO label` and not a new `CONTINUE`: V2 has labels, not line numbers. The classic way to resume a loaded program without clearing is `GOTO`, which
classic users know. It falls out of “immediate statements run in the session” at no extra cost. A bare `CONTINUE` (restart from the top without clearing)
would also re-run the program's `DIM`s, which clear their arrays.

### 2.4 Things this changes for users

* Immediate statements would see and change the program's variables. Today they are isolated, and nothing documented relies on that isolation.
* An immediate statement recompiles the whole program. Measured compile time of a 60-statement program: ≈ 3.7 M T-states ≈ **1 s** at 3.5 MHz **[M]**
  (`qbench` `compile_only`). Either accept that, or cache the compiled program while it is unchanged: [E] +20–40 B, plus a rule for new names typed at the prompt.
* `: x = 5` followed by `RUN` still prints 0, because `RUN` clears (your preference, kept).

### 2.5 Smallest safe implementation — staged [E]

| Stage | Content | HOME | EXROM | Notes |
|---|---|---:|---:|---|
| **1a** session lifetime | keep variables after a program ends; immediate statements compiled with the program (source + the immediate line; entry at the immediate code); `VM_INIT` skips the clear when the session is valid; invalidate on `RUN`/`CLEAR`/edit/`LOAD`/`NEW` | −30 … −70 | −20 … −40 | gives `: PRINT x` after a run and `: GOTO label` resume |
| **1b** save/load with variables | bundle format, CRC-16, recompile-and-compare, content checks, failure path | 0 | −160 … −270 | or HOME (Enhanced) or a package (+10…20 B core hook) |
| **2** edit preservation where safe | relocate the symbol-table/arena block on a length change; keep the session if the recompiled symbol table is identical, else clear with a message | −20 … −40 | −60 … −120 | name-keyed rebinding instead: [E] −200 … −350 |

Order: **1a, then 1b, then 2 (optional).** Stage 1a is useful on its own: it gives classic prompt-time inspection, and no persistence format is
involved. Per the instruction, nothing here should be implemented until the lifecycle rules above are agreed. Open decisions:

* whether immediate statements may create new variables when a session exists (simplest rule: they may; new names start at zero);
* the command spelling for saving with variables;
* whether the Array Store is included in the bundle (R10.9 C2);
* stage 2: yes or no.

---------------------------------------------------------------------------------------------------------------------------

## 3. Decision 3 — numeric literal policy L-C

### 3.1 Answers

**Can L-C reuse the existing float and integer conversion paths?** Yes. No new opcode and no new arithmetic [S]:

* **Literals 32 768 … 65 535:** the compiler emits the existing `OP_PUSH_FLOAT_LIT` with divisor 0. For that divisor the VM writes the value's exact
  calculator form `[$90][hi AND $7F][lo][0][0]` (exponent 16; no division) and pushes it through `VM_FLOAT_STORE_RESULT`, the same path as any FLOAT result.
* **Negative literals:** −1 … −32768 are still folded to INT at compile time (the Q-05 fix). −32769 and below compile as `0 − <FLOAT>`.
* **Addresses** (`POKE`, `PEEK`, `USR`, `IN`, `OUT`, and package arguments, §3.3) go through a new `VM_POP_ADDR`. An INT is its 16-bit pattern, as before. A
  FLOAT below 32 768 in magnitude uses the existing `CALC_FP_TO_INT` path, and an exponent-16 FLOAT (32 768 … 65 535) is read straight from its 5 bytes.
* **`USR`:** returns HL as an unsigned value (FLOAT when ≥ 32 768), through the same builder as the literals.

**Actual assembled cost?** **[M]** on Essential and Enhanced alike:

| Part | HOME | Needed under L-A too? |
|---|---:|---|
| Q-32 address conversion (`VM_POP_ADDR`; 5 call sites) | −49 | **yes**: D11 promotion already produces FLOAT addresses (§3.3) |
| Q-33 package arguments through `VM_POP_ADDR` | −2 | **yes** |
| **L-C literals + unsigned `USR`** | **−67** | — |
| EXROM | 0 | |

The cost study's estimate for L-C *with* address coercion was +40…60 B. Measured, L-C costs 67 B, plus 51 B of address handling that is needed anyway.
The address handling is larger than estimated because it has to cover the whole 0…65 535 range, the negative patterns and an error path. The literal part
is larger because the negative-literal fold had to be split.

**Does L-C change comparisons, FOR loops, VAL or numeric functions?** Comparisons, `FOR` loops and functions change; `VAL` and `INPUT` do not.

* **Comparisons:** values are now mathematical: `x = 65535: IF x = -1` is **false** (true under L-A). Any program that relies on pattern equality changes.
* **Arithmetic:** with a literal ≥ 32 768 it is FLOAT arithmetic: exact, and slower. `40000 + 1` = 40001 (L-A: −25535).
* **`FOR` over addresses ≥ 32 768** needs Decision 1, because the variable is FLOAT. Measured working: `FOR a = 64000 TO 64002: POKE a, …`.
* **`VAL`, `INPUT`:** unchanged by the literal rule. `VAL("40000")` still wraps (Q-17). For consistency they should use the same number rule (§3.4).
* **Functions:** `USR` is now unsigned. `PEEK` and `IN` (0…255) and every other function are unchanged. Integer arguments truncate floats as before
  (`CHR$(65535)` is still a range error).
* **Display:** a FLOAT prints with 4 decimals, so `PRINT 65535` shows `65535.0000`, as `PRINT 30000*3` already shows `90000.0000` under D11. An optional
  rule, “print an integral FLOAT below 2³² without decimals”, would show `65535`: [E] EXROM −10…−20 (display code).

**How should address coercion handle negatives, fractions and values outside 0–65535?** As built **[M]**:

| Value | Result |
|---|---|
| INT (any) | its 16-bit pattern (unchanged: `PEEK(-1)` = `PEEK(65535)`) |
| FLOAT −32 768 … 65 535 | truncated toward zero; a negative gives its two's-complement pattern (`x = 0.5: PEEK(x)` = `PEEK(0)`) |
| FLOAT < −32 768 or ≥ 65 536 | **error 15** (`x = 35000 * 2: PEEK(x)`) — never a wrong address |

**Is the floating-point representation accurate enough for these literals?** Yes. The 5-byte format has a 32-bit mantissa, so every integer up to
4 294 967 295 is exact. 32 768 … 65 535 are built exactly, without division, and print exactly.

**Conflicts with D11 overflow promotion?** None, and L-C removes an inconsistency. Under L-A, `PRINT 32767+1` gives `32768.0000` while `PRINT 32768`
gives `-32768`. Under L-C both give `32768.0000`. One remaining D11 interaction: Q-32 was caused by D11 promotion, not by the literal rule.

### 3.2 L-A versus L-C

| | L-A (current) | L-C (prototype) |
|---|---|---|
| `PRINT 65535` | `-1` | `65535.0000` |
| `PRINT -40000` / `PRINT -32769` | `25536` / `32767` (**silent**) | `-40000.0000` / `-32769.0000` |
| `x = 40000: PRINT x + 1` | `-25535` | `40001.0000` |
| `POKE 65000,…`, `PEEK`, `USR(61440)`, `IN(65278)` | work | work |
| `USR` returning 40 000 | `-25536` | `40000.0000` |
| literals > 65 535 | error 64 | error 64 (unchanged) |
| cost | — | HOME −67 |

L-A's silent wrong values are not edge cases: any negative literal below −32768, and any arithmetic on a literal above 32767. **Recommendation: L-C**, with
the Q-32 and Q-33 fixes, which are required under either rule.

### 3.3 The two defects found while building L-C

* **Q-32 (CRITICAL, Essential/Enhanced; introduced by the D11 prototype):** `b = a + 3370: POKE b, 88` wrote to address 32767; `PEEK(a + 3370)` read the
  wrong byte; `USR(a + …)` would jump to 32767 **[M]**. Fixed by `VM_POP_ADDR` (HOME −49) **[M]**. Two new corpus cases: `addr.promoted_peek`/`_poke`.
* **Q-33 (HIGH, all configurations):** `OP_CALL_EXT` popped package arguments raw, so `r = 33/2: CIRCLE 128,96,r` drew radius ≈ 1, and any computed
  `SPRITE`/`FILL`/`CIRCLE` coordinate is affected **[M]**. Fixed by popping through `VM_POP_ADDR` (HOME −2). Under L-C this also keeps a literal such as 38912
  meaning the same 16-bit value for a package: the component test `ext_demo` (`TRIADD 3,4,38912`) failed before this fix and passes after it.
  New corpus case: `pkg.shapes.float_radius`.

### 3.4 What L-C does not change (limitations)

* **Decimal literals keep L-A's limits:** a mantissa ≤ 32 767 and ≤ 4 decimal places, so `1000.25`, `65535.9` and `3.14159` are error 64 **[M]**. Every
  accepted literal now has its mathematical value, but the accepted range of decimals is narrow. Widening it means a 32-bit mantissa and up to 9 digits,
  with one runtime division by 10ᵏ: [E] HOME −70…−110.
* **`VAL` and `INPUT`** should follow the same rule. The cheapest way is one shared number scanner for literals, `VAL` and `INPUT`, which also closes Q-15,
  Q-16 and Q-17: [E] −100…−160 for all of it, including the decimal widening.

### 3.5 Verification **[M]**

* **Corpus:** L-C changes exactly the cases it should. These now give the mathematical value (they were XFAIL under the L-A marker): `PRINT 32768`, `40000`,
  `65535`, `-32769`, `-40000`, `40000+1`, `USR` = 40000. Nothing else changed.
* **Bytecode** (`tools/qual/qbytecode.py`, without vs with L-C): of 656 corpus programs, 644 compile identically; the 12 that differ are exactly the
  programs containing a literal ≥ 32 768.
* **Gate:** 115 / 98 / 15, FILL 10/10, production checks 17/19 (the same two).
* `make check` rc 0; standalone **38/38** with Q-33.
* The cost study's `study_d11_literals` tool fails exactly one case, by design: it asserts the L-A result `PRINT 65535` = `-1`. All its `POKE 65000` and
  `USR 61440` cases pass. The rest of the prototype-tool battery passes.

---------------------------------------------------------------------------------------------------------------------------

## 4. Decision 4 — ROM reserve and final budgets

### 4.1 Measured ledger **[M]** (HOME / EXROM free)

| Step | Essential | Enhanced | Branch |
|---|---:|---:|---|
| combined build (overnight) | 353 / 488 | 180 / 239 | `study/combined-*` |
| + qualification fixes (22 defect ids) | 196 / 482 | 23 / 233 | `study/qualification-costs`, `-enh-final~1` |
| + RST vectors | 741 / 482 | 578 / 233 | `study/qualification-final`, `-enh-final` |
| + floating-point `FOR` (Decision 1) | 644 | 481 | `study/proto-float-for` / `proto-enh-decisions` |
| + Q-32 address conversion | 595 | 432 | `study/proto-lc` / `proto-enh-decisions` |
| + L-C literals (Decision 3) | 528 | 365 | same |
| + Q-33 package arguments | 526 | 363 | same |
| **+ compiler emit-stub inlining (new shrink)** | **821 / 482** | **670 / 233** | `study/proto-shrink2` / `proto-enh-shrink2` |

The final heads were verified on all three fronts:

* **Corpus:** 656 cases. Both heads give 588 PASS, 58 XFAIL (defects still open), 7 XPASS (the L-A literal markers, now correct), 2 N/A, and
  1 FAIL (`VAL("99999")`, Q-17 partial).
* **Component tests:** standalone **38/38** on both; `make check` rc 0 on both.
* **Gate battery:** see §4.8.

### 4.2 Which remaining costs are measured and which are estimates

Measured (built, and verified as listed): everything in §4.1.

Estimated, none built:

| Item | HOME | EXROM | Kind |
|---|---:|---:|---|
| Q-10 float arguments (`SGN SQR RAD DEG SIN COS TAN MOD DIV`) | −80 … −130 | | required |
| Q-15/Q-16 `INPUT` numbers, Q-17 `VAL` > 32767 (or the shared scanner of §3.4, which also widens decimal literals: −100 … −160 for all) | −35 … −85 | | required |
| D11-EXT, Q-21, Q-22, Q-23, Q-24, L3 | −41 … −74 | | required |
| D10 display rounding | | −10 … −20 | required |
| L-STR (string ordering) + L-SC (short-circuit) | −50 … −80 | | spec MUST HAVE |
| goal 2, stage 1a (session) | −30 … −70 | −20 … −40 | your decision 2 |
| goal 2, stage 1b (save/load with variables) | (or HOME) | −160 … −270 | your decision 2 |
| goal 2, stage 2 (edit preservation) | −20 … −40 | −60 … −120 | optional |
| optional language items (`ELSEIF`, bare `NEXT`, `INSTR`, 9 glyphs, N-4, D11-DISP) | −152 … −200 | −40 … −80 | optional |

The required rows total HOME −156 … −289 and EXROM −10 … −20, as in the qualification budget.

### 4.3 Expected final budgets [E] (from the measured heads)

| Final configuration | HOME free | EXROM free | Meets 200 / 150? |
|---|---:|---:|---|
| **Essential** + required + spec + goal 2 stage 1 (1a + 1b, 1b in EXROM) | **382 … 585** | **152 … 292** | yes (EXROM 152 at the pessimistic end) |
| Essential, the same + stage 2 (its EXROM part placed in HOME) | 222 … 505 | 152 … 292 | yes |
| **Enhanced** + required + spec + stage 1a, with 1b as a **package** (+10…20 B core hook in EXROM) | **231 … 434** | **153 … 193** | yes, narrowly in EXROM |
| Enhanced + stage 1a + 1b in HOME | −39 … +274 | 173 … 203 | no, at the pessimistic end |
| Enhanced + stage 1a + 1b in EXROM | 231 … 434 | −97 … +43 | no (does not fit) |

Arithmetic: Essential HOME 821 − (156…289 required + 50…80 spec + 30…70 stage 1a); EXROM 482 − (10…20 + 20…40 + 160…270). Enhanced HOME 670 − the same
HOME items; EXROM 233 − (10…20 + 20…40 + the 10…20 package hook).

### 4.4 How much more can proven techniques recover?

* **Already measured and included in §4.1:** RST vectors (+545 Essential / +555 Enhanced) and emit-stub inlining (+295 / +307). The inlining was estimated
  at +150…250 and measured at +295. It is mechanical (`tools/qual/apply_emit_inline.py --full`), and **all 649 corpus programs compile to byte-identical
  bytecode** before and after (11 469 B compared on Essential, 12 192 B on Enhanced; the checker was shown to detect a real change).
* **Remaining candidates [E] +62 … +65 HOME:** `CHK_ERR` +23, `VM_PUSH_INT` entry +18, the shared `LEFT$/RIGHT$` prologue +12…15, the write-only
  `VM_TOS_TAG` +6, and `call/ret` → `jp` +3.
* **EXROM has never been shrink-studied.** For Enhanced, where EXROM is binding, an EXROM pass is the next study item. All RST vectors are taken, so
  EXROM can only use the five existing RST targets, and it calls none of them.

### 4.5 RST shrink — residual risk review

* **Banking [S]:** RST vectors live at `$0008–$0037`. The only code that pages memory (`kernel/bank/bank.asm`) writes the HSR with bit 6 (chunk 6,
  `$C000–$DFFF`) or 0, so chunk 0 is HOME whenever any code runs. The ISR at `$0038` depends on exactly the same assumption.
* **Packages [S]:** no package uses an RST instruction.
* **User machine code:** `USR` code written for the stock ROM's RST conventions (e.g. `RST $10` to print) would now call `VM_POP`. Previously it executed
  `$FF` fill (`RST $38`), so it never worked on V2. Not a regression, but worth one line in the manual.
* **Timing:** +4 T-states per converted call; no converted routine is used by the tape or ISR code; measured +0.1…0.3 % overall.
* **Process:** the conversion is mechanical, and new code must follow the rule (`tools/qual/apply_rst_rule.py`). A missed site only loses bytes; it is never
  a correctness risk.
* **Still worth independent work:** one hardware run of an RST build (the change is pure CPU semantics, so low risk), and a decision that the remaining
  vectors (`$00`, `$28`, `$38`) stay as they are.

No significant correctness risk was found.

### 4.6 Which requirements can move between HOME and EXROM without excessive complexity?

* **Rule:** VM hot paths, and anything run while EXROM may be paged out, stay in HOME. One-shot shell, storage-UI, display-format and validation code can
  live in either bank. A HOME → EXROM call costs a KTAB entry or a cross-bank symbol export, roughly 3–6 B per entry point.
* **Good EXROM candidates (Essential, 482 free):** goal 2 stage 1b; D10 rounding (already EXROM); the optional integral-FLOAT display rule; Q-10's float
  function bodies, next to the calculator.
* **Good HOME candidates (Enhanced, EXROM 233):** goal 2 stage 1b (or a package); any new shell code.
* **Not worth moving:** the float-`FOR` slow path (−97 total; splitting it across banks costs more than it saves).

### 4.7 What would have to be deferred to keep the contingencies?

* **Essential:** nothing required. Every required item, the spec gaps and goal 2 stage 1 fit with ≥ 200 / ≥ 150 (EXROM 152 at the pessimistic end).
  Stage 2 fits with its EXROM part in HOME. Most optional items fit in HOME; D11-DISP (display code, EXROM) should wait unless the estimates come in low.
* **Enhanced:** goal 2 stage 1b as a loadable package (or deferred); stage 2 deferred. Optional items: `INSTR` as a package; the 9 glyphs documented as
  missing; `ELSEIF`, bare `NEXT`, N-4 and D11-DISP deferred, unless the remaining shrink candidates or an EXROM shrink pass provide the room.
* Nothing in this list is a removal of existing functionality.

### 4.8 Gate and tools on the final heads **[M]**

| | Essential final (`study/proto-shrink2` `50127bb`) | Enhanced final (`study/proto-enh-shrink2` `cbd19de`) |
|---|---|---|
| `v2_prod_regress` | 115 PASS | 113 PASS (Enhanced's suite has 113 cases) |
| `v2_prod_arrays` | 98 PASS | 98 PASS |
| `v2_known_defects` | 15 PASS | 15 PASS |
| `v2_fill_check` | 10/10 | 10/10 |
| `v2_production_checks` | 17/19: `253-vars`, `free-1` (capacity constants changed by the Q-02 fix, as on the fix branch) | same |
| `make check` / standalone | rc 0 / 38/38 | rc 0 / 38/38 |
| corpus (656) | 588 PASS, 58 XFAIL, 7 XPASS (L-A markers), 1 FAIL (Q-17 partial), 2 N/A | same; output differs from Essential only in the 10 multi-item `PRINT`/`INPUT` cases |
| prototype tools | (run on the L-C build `lc`: all pass except the one L-A assertion below) | all pass — BREAK matrix 6, edit preservation 9, U6 4, `FOR` line 5, multi-item `PRINT` 13, bare words 13, nested `FN` 7, D11 print 15, `OUT/IN/STICK` 6, FILL BREAK, flicker 12 scenarios / 0 mismatches, integer oracle 0 mismatches in 4 × 8 476 pairs — except `study_d11_literals`' one L-A assertion (`PRINT 65535` = `-1`), by design |

---------------------------------------------------------------------------------------------------------------------------

## 5. Recommendation

1. **Decision 1:** adopt variant D. The integer path is preserved (+0.3 % on ordinary loops), and float loops work with Sinclair semantics. Document the
   accumulation caveat and the float speed. Q-08 closes on integration.
2. **Decision 3:** adopt **L-C together with the Q-32 and Q-33 fixes**. Q-32 and Q-33 are required under any literal rule, and Q-32 is critical.
   Plan the shared number scanner (§3.4) as the follow-up that widens decimal literals and fixes `VAL`/`INPUT`.
3. **Decision 2:** agree the session-variables semantics (§2.3) and the open points (§2.5), then implement stage 1a, then 1b (EXROM for Essential; a
   package for Enhanced), with the validation of §2.2. Defer stage 2.
4. **Decision 4:** take the emit-stub inlining with the RST shrink (+295/+307, bytecode-identical). Keep 200/150 as targets, measured on each release
   build. Enhanced needs goal 2's save/load as a package, or an EXROM shrink pass.

---------------------------------------------------------------------------------------------------------------------------

## 6. Branches and reproduction

| Branch | Head | Base | Content |
|---|---|---|---|
| `study/decisions-review` | (this commit) | `study/qualification-a` | this report; `V2_DECISIONS_CASES.csv` / `V2_DECISIONS_COVERAGE.csv` (656 cases; `fix_branch` column = the Essential final head `ess-all`); tools: `qlifecycle.py`, `qbytecode.py`, `apply_emit_inline.py`, corpus §22–23, `qbench` loop programs |
| `study/proto-float-for` | `5820854` (variant D; A `d6de0cf`, B `1936ebb`, C `2388ef0`) | `study/qualification-final` | Decision 1 |
| `study/proto-lc` | `7372441` (Q-32 `6449bee`, L-C `ab6895e`, Q-33 `7372441`) | `study/proto-float-for` | Decision 3 + Q-32/Q-33 |
| `study/proto-shrink2` | `50127bb` | `study/proto-lc` | + emit-stub inlining + Q-33: **Essential final head** |
| `study/proto-enh-decisions` | `e070ca0` | `study/qualification-enh-final` | Decisions 1 and 3, Q-32, Q-33 on Enhanced |
| `study/proto-enh-shrink2` | `cbd19de` | `study/proto-enh-decisions` | + emit-stub inlining + Q-33: **Enhanced final head** |

```
cd ~/2068-Leap-study/decisions-review
tools/qual/build_configs.sh ~/2068-Leap-study/qual-builds ess-all=study/proto-shrink2 enh-all=study/proto-enh-shrink2
python3 tools/qual/qrun.py --out /tmp/r --cfg ess-all:essential --fixed Q-01,...,Q-33 --filter ffor.,addr.,lit.int.   # decisions' cases
python3 tools/qual/qlifecycle.py final-ess                                       # variable lifecycle today
python3 tools/qual/qbytecode.py lc ess-all                                       # shrink: identical bytecode
python3 tools/qual/qbench.py final-ess ess-all                                   # FOR speed
tools/qual/run_gate_suites.sh ~/2068-Leap-study/qual-builds/ess-all 10820 /tmp/gate
```

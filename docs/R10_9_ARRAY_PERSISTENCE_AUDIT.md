# R10.9 — Array persistence architecture audit

**Status:** read-only investigation, **approved by the owner as a design baseline** (decisions recorded in §10, qualifications
in §11). **Nothing in this document is implemented.** No production file, test or build input was modified; the only new
artifact is this document. Approval is *subject to implementation measurements and regression tests*. Companion documents:
[`PACKAGE_ABI.md`](PACKAGE_ABI.md), [`R10_9_PHASE1_REPORT.md`](R10_9_PHASE1_REPORT.md),
[`R10_9_WORK_SEQUENCE.md`](R10_9_WORK_SEQUENCE.md) (step 2.5), [`R10_8_GAP_ANALYSIS.md`](R10_8_GAP_ANALYSIS.md) (D6),
[`TESTING.md`](TESTING.md). Repository state: `main` at `5873982`, clean tree.

**Evidence tags.** **[M]** measured in this audit on the production image (`build/ts2068rom_zesarux.bin`) by the
project's own harness (`tools/v2_prod.py`); **[S]** read from source (file:line); **[E]** estimate, not
assembled; **[H]** hypothesis / design proposal, not tested. Probe scripts were scratch files outside the
repository (method in Appendix B); `git status` was clean before and after. The full `make test` was *not* run (≈ 23 min,
unchanged tree); only the existing `D6-array-load-survives-run` case and the scratch probes were run.

---

## 1. Executive summary and recommended architecture

### 1.1 What exists

The three storage goals, as the code stands today:

| # | Goal | Status | Evidence |
|---|---|---|---|
| 1 | Program alone | **Exists.** `SAVE/LOAD/VERIFY "n"`, header type 0, version word `$8100`. Failure semantics are the open D1/D2 defects (step 2.3) | [S][M] Phase 1 gate |
| 2 | Program together with its current variables/data | **Does not exist.** `SAVE` serialises `PROG_AREA_START..PROG_END` only; the header's second length field (`PROGLEN`) is written equal to the data length. Scalars, strings and arrays are run-scoped state that every `RUN` zeroes; there is no bundle qualifier | [S] `rom/exrom_v2_shell.asm:977`, `kernel/storage/storage.asm:678`; [M] P5 header `…0d00 0081 0d00` |
| 3 | Array data independently | **Present but not a working feature end to end.** Four independent defects, three of them new findings of this audit (§3.3): `SAVE … ARRAY` writes a **type-0 (program) header** [M]; names longer than 8 characters cannot be saved or loaded [M]; `LOAD … ARRAY` performs no validation of count/kind/length against the target [M]; and a loaded array cannot reach a `RUN` (D6) [M] | §3 |

### 1.2 Why D6 happens, in one paragraph

Array identity in Leap is a *per-compile symbol index*, and array state (pointer table, arena, symbol table) is rebuilt on
every `RUN`. `LOAD "f" ARRAY a` allocates an arena descriptor at the prompt and records its address in a table that
`VM_CARVE_TABLES` zeroes at the start of the next `RUN`. The tape data survives in RAM but nothing refers to it, and the
program's own `DIM` re-allocates the array anyway. The design (R10.7 §11.2) assumed "load before the program's `DIM` in
this run" without defining what a run *is* relative to a prompt-time load; there is no lifetime rule that makes a loaded
array outlive the `RUN` that follows it. (Stock Sinclair BASIC has no such feature either: its `RUN` also wipes all
variables — §9.)

### 1.3 Recommendation (smallest reliable architecture)

**Separate three decisions that the current code conflates: (a) the tape *representation*, (b) the in-memory
*lifetime*, (c) the *visibility* rule.**

1. **Representation — keep it.** The descriptor-verbatim body (`[dim_count:1][count:2][(width:1)][data]`) is already
   address-independent [M: P5 bytes]. Option C ("compact address-independent representation") therefore costs nothing
   and needs no new format; it needs a *validator* and the corrected header type byte.
2. **Lifetime — a name-keyed *Array Store* in segment 2** (`$E000–$E7FF`, the existing always-visible chunk-7
   overflow area), recorded by one 2-byte length cell. It lives **outside the edit-volatile source/array pool**, so it
   survives `RUN`, immediate statements, edits and program `LOAD` by construction. Reset sites are exactly two lines
   today (`VM_INIT`, `V2_CLEAR_ARRAYS` [S]), both of which change from `ARR2_BASE` to `ARR2_BASE + store_length`.
3. **Visibility — bind by name at `VM_INIT`, adopt at `DIM`.** After the run tables are carved, each store entry is
   matched by (name, kind) against the freshly built compile symbol table and its pointer slot is filled in. `OP_DIM`
   of an already-bound slot *adopts* the stored array if the declared size equals the stored size, and raises a clean
   error if not; it allocates (and now zero-fills) only for unbound names.
4. **Failed loads cannot corrupt anything**: the tape is received into the *free tail* of the store, validated, and only
   then committed by advancing the length cell. (This is the same receive-in-place-then-commit trick `V2_LOAD_ARRAY`
   already uses in the pool [S].) It depends on the D1 fix (step 2.3) to know that the receive really succeeded.
5. **Optional, separately priced increments** (§6): single-file *program + arrays* bundle using the header's unused
   `PROGLEN` field (backward-compatible minor bump); in-program `LOAD/SAVE … ARRAY` statements (Option B — the stock
   idiom); arrays larger than the 2 KB store.

**Why not the alternatives** (detail in §4): preserving pool arrays across `RUN` (A1) depends on the compile symbol-table
size and on there having been a prior compile, and is destroyed by any immediate statement [M: P4]; Option B alone does
not give "load at the prompt, then RUN" or a program+data bundle and is the most expensive in HOME ROM, where Leap is
tightest (HOME 546 B free).

### 1.4 Cost headline (all **[E]** — nothing assembled)

| | HOME B | EXROM B | persistent RAM | notes |
|---|---:|---:|---:|---|
| Stage 0 repairs (D13, name length, validation, DIM zero-fill) | +8…+14 | −25…+10 | 0 | no architecture change; fixes real bugs |
| **Recommended core (Array Store)** | **+35…+65** | **+60…+200 net of replaced code** | **2 B sysvar** (+ ≤ 2,048 B of segment 2 only while arrays are stored) | D6 repaired |
| Bundle (program + arrays, one tape file) | 0 | +60…+110 | 0 | minor version bump |
| In-program `LOAD/SAVE … ARRAY` (Option B) | +140…+260 | +60…+160 | ≈ 6 B scratch | anchored on string arrays' measured 1,022 B HOME |

Budget context [M]: HOME 546 B free, EXROM 1,340 B free. The work-sequence floors are HOME ≥ 350 / EXROM ≥ 800, and
its projection for HOME after the rest of R10.9 is 401…491 B [E]. The core costs up to 65 B of that; **in the worst case
(with step 2.7 and the top of this range) HOME lands at ≈ 336, 14 B under the floor** — flagged in §9.

---

## 2. Current implementation inventory

### 2.1 Memory map relevant to arrays [M: `build/exrom.sym`, harness reads]

```
$825A  PROG_AREA_START ──┐ line store: [len:2][text][CR] records
       PROG_END ─────────┤
       SYM_BASE_V = PROG_END: compile symbol table (SYM_RESET), grows up toward SYM_LIMIT_V
       SYM_END_V+1 ──────┤
       ARRAYS_END ───────┤ array arena, grows UP (descriptors: dim_count|count|data)
          …free…         │
       VM_CSP ───────────┤ unified control stack, grows DOWN
       VARS_START ───────┤ carved run tables [VARS_START, V2_SOURCE_END): SYMTAB, FLOATTAB,
                         │   STRTAB, ARR ptr table (2 B/array), STRARR ptr table — zeroed by every RUN
$A327  V2_SOURCE_END ────┘ (pool = $825A..$A327 = 8,397 B)
       compile/run zone (chunk buffer 264 + state + ident buf), then bytecode $A455…
$E000..$E7FF  segment 2 (2,048 B, chunk 7, always visible): overflow arrays, ARR2_END ($B81B)
$E800..$F0FF  sprite buffers (persistent, package-owned)
```
Pool: `$825A..$A327` (8,397 B, R10.8 L4). `ARR2_BASE=$E000`, `ARR2_LIMIT=$E800`, asserts `ARR2_LIMIT ≤ SPRITE_SLOT_IMG_BUF`
and `GFX_FILL_STACK_END ≤ ARR2_BASE` [S] `include/v2_layout.inc`.

### 2.2 Descriptors, types, symbols [S]

| Item | Definition | Source |
|---|---|---|
| Numeric descriptor (arena) | `[dim_count:1 =1][count:2][data: 2·count]`, no absolute pointers | `rom/exrom_v2_vm_core.asm` `ARR_DESC_*`, `ARENA_ALLOC_NUMERIC:1526` |
| String descriptor | `[dim_count:1][count:2][width:1][data: count·width]`, element `[len:1][content:width−1]` | `ARENA_ALLOC_STRING:1754` |
| Compile symbol | `[rec_len][kind][namelen][index][name][extra]`, kind 2 = numeric array (`extra` = size:2), 3 = string array (size:2 + width:1); index = per-kind running count, **assigned in source order of first appearance**; name ≤ 31 significant chars (`IDENT_MAX_LEN`) | `rom/exrom_v2_symtab.asm:1–40` |
| Bytecode | `OP_ARR_LOAD/STORE [array_index:1][declared_size:2]`, `OP_DIM [index][count:2]`, `OP_DIM_STR [index][count:2][width]`; **sizes are literals baked at compile time** (`DIM` takes only a literal; error 34 otherwise) | `COMPILE_DIM` `exrom_v2_compiler.asm:2598` |
| Runtime pointer table | `RT_ARRPTR_PTR` / `RT_STRARRPTR_PTR`: 2 B per array symbol, inside the carved block; 0 = "not DIM'd this run" | `VM_ARR_ADDR:1411` |
| Bounds | checked against the **compile-time** declared size, not the descriptor's count (`VM_ARR_VALIDATE_INDEX`) | `OP_ARR_LOAD:1453` |

Consequence used throughout: *the descriptor's own `count` is never consulted by element access*. A descriptor whose count is
smaller than the declared size is an out-of-bounds hazard (§3.4).

### 2.3 Allocation and initialisation [S][M]

* Primary arena: `ARENA_ALLOC_*` bump `ARRAYS_END` (no free); `VM_ARENA_FIT` tries `ARRAYS_END + n < VM_CSP`, else
  segment 2 by swapping `ARRAYS_END`/`ARR2_END` around the unchanged allocator (`:1818`).
* **`DIM` does not initialise the elements** [S: no fill in `ARENA_ALLOC_*`]. [M] E1: `DIM a(5)` / `y = a(2)` / `a(2) = 33`
  run three times gives `y = 0, 33, 33` — the second run sees the previous run's value. (First run is zero only because
  `MEM_COLD_INIT` zeroes `$8000–$BFFF` at power-on [S].) `docs/v1/user_manual.md:552` and `docs/v1/basic_language_reference.md:714`
  promise "zero-initialized elements". This is a defect in its own right (**D12**, §3.3) and it matters here: it means the
  data from a previous run *accidentally* reappears when the layout repeats, which can mask a persistence bug.

### 2.4 Lifecycle: what each event does [S][M]

| Event | Symbol table | Pointer tables | `ARRAYS_END` / seg 2 | Array **data bytes** |
|---|---|---|---|---|
| Stored line (ENTER) | `V2_CLEAR_ARRAYS` → `SYM_RESET` | left stale, unreachable | reset to `SYM_END+1`; `ARR2_END=$E000`; `VARS_START` raised | untouched |
| Program `LOAD`, `NEW` | same (`MEM_INIT_V2`) | same | same | untouched |
| `RUN` | `COMPILER_INIT` → `SYM_RESET`, rebuilt by compile | **zeroed** by `VM_CARVE_TABLES` (`:707–772`) | `VM_INIT`: `ARRAYS_END = SYM_END+1`, `ARR2_END=$E000` | untouched (stale) |
| `: stmt` (immediate) | `SYM_RESET` + one-line compile → program's names **gone** [M P4: SAVE ARRAY → `ARRAY NOT DIMD`] | zeroed | reset | untouched |
| `CLEAR` | `V2_CLEAR_ARRAYS` (D8: half-implemented) | untouched (D8) | reset | untouched |
| Package call (`OP_CALL_EXT`) | – | – | segment-2 arrays survive [M R10.8 t25] | untouched |

Immediate statements and `RUN` thus share the "forget everything" path; there is no notion of a program-independent array.

### 2.5 `SAVE/LOAD … ARRAY` as implemented [S][M]

| Aspect | Behaviour | Source |
|---|---|---|
| Command entry | typed `SAVE/LOAD "f" ARRAY name`; `V2_PARSE_NAME` ARRAY qualifier → `V2_SCAN_ARRAY_NAME`; commands are prompt-only (see below) | `exrom_v2_shell.asm:831,904` |
| `SAVE` source | live array only: `ARRSYM_LOOKUP` on the **last compile's** symbol table + pointer table; "never DIM'd this run" → `ARRAY NOT DIMD`. Works only after a `RUN` with no edit / immediate statement in between [M P4] | `V2_SAVE_ARRAY:1029` |
| `SAVE` header | **type byte = `STORAGE_REQUEST_TYPE`, which `V2_SAVE_ARRAY` never sets** (it is 0 after boot; 8 only if a previous `LOAD … ARRAY` set it) → program-type header [M P5, P7] | `V2_SAVE:977` sets it, `V2_SAVE_ARRAY` does not |
| `LOAD` target | must already be a known compile symbol (so a prior compile is required [M P0b → `ARRAY NOT DIMD`]) and its pointer slot must be 0 (`ARRAY ALREADY SET` otherwise [M P0c]) | `V2_LOAD_ARRAY:1257` |
| `LOAD` receive | into the arena free space at `ARRAYS_END`, max length `VARS_START − ARRAYS_END − 1` (never spills to segment 2), then `ARENA_ALLOC_*` commits in place using the *received* count/width | `:1316–1356` |
| Validation | **none** beyond the transport's own (checksum, version word, header length ≤ max) | §3.4 |
| Failure | carry → `LOAD FAILED`; a bad version word shows `LOAD FAILED`, not `BAD TAPE VERSION` [M P3e] | `.load_failed` |

`SAVE`/`LOAD`/`VERIFY`/`RUN`/`LIST`/`NEW` are **shell commands matched on the first word of a new line at the end of the
store** (`V2_COMMAND_LOOP` → `V2_DISPATCH` only when `CUR_EDIT_POS = $FF`); they are not compiler tokens
[S: grep `rom/exrom_v2_compiler.asm`, `:140–165`]. A running program cannot save or load anything today.

### 2.6 Cassette record structure and versioning [S][M]

Header block (17 B payload): `type:1 | name:10 | length:2 | autostart:2 | proglen:2`. Version word is stored in `autostart`
(`$8000 | major<<8 | minor`; programs and arrays share `V2_FORMAT_WORD = $8100`, packages `$8200`); checked in `.name_ok` *before* any
data byte is stored; rule: tag+major equal, tape minor ≤ ROM minor (`PACKAGE_ABI.md` §1, `storage.asm:858–872`). The
transport is one data block per file. `STORAGE_LOAD` writes straight into the destination `IX` (no staging) and returns
`A=0` clean / `$FF` touched / `$FE` bad version; failure exits currently return the wrong carry polarity (D1/D2, open).

### 2.7 HOME / EXROM boundary [S]

HOME (`rom/v2_home.asm`) contains the compiler, symbol table, VM core, memory, math, graphics, bank; EXROM contains
storage, shell, editor, calculator glue, decompiler, formatting. EXROM is paged in whenever the shell or the VM runs; HOME
reaches EXROM at fixed entry addresses (`MEM_CLEAR_V2 EQU V2_EXROM_CLEAR_ADDR`, called by `OP_CLEAR`) — precedent for a
HOME→EXROM call at `VM_INIT`. A package runs with EXROM paged **out** and chunk 6 as RAM (`OP_CALL_EXT`); chunk 7
(`$E000–$FFFF`) is never paged, so segment-2 data is unaffected by banking [M R10.8 t25]. Sizes today [M, from symbol
deltas]: `V2_SAVE_ARRAY` 119 B, `V2_LOAD_ARRAY` 187 B, `V2_SCAN_ARRAY_NAME` 100 B, two messages 33 B; R10.7 measured the
whole array SAVE/LOAD feature at 451 B EXROM, 0 B HOME.

---

## 3. Root cause of D6 and the other findings

### 3.1 Exactly which state `RUN` destroys, and why D6 results

Sequence for `PROG = ["GOTO s","DIM a(5)","s:","y = a(2)"]`, tape = array `ARR` with element 2 = 33 [M, existing case
`D6-array-load-survives-run`, re-run in this audit]:

1. `RUN` once (compile only matters): symbol `a` (index 0, size 5) exists; `a`'s pointer slot is 0 because `DIM` was jumped over.
2. `LOAD "ARR" ARRAY a` → `LOADED`; descriptor at `$8293`, pointer slot written [M `ptr_after_load=8293`].
3. `RUN`: `SYM_RESET` + recompile; `VM_INIT` sets `ARRAYS_END` past the (new) symbol table and `ARR2_END=$E000`;
   `VM_CARVE_TABLES` **zero-fills the whole carved block including the array pointer tables** → slot is 0.
4. `y = a(2)` → `VM_ARR_ADDR` returns carry (slot 0) → runtime error 10 [M `vm_err=10 y=0`].

If instead the program executes its own `DIM`, `V2_LOAD_ARRAY` refuses before any data moves (`ARRAY ALREADY SET`
[M P0c]); and even without that refusal `OP_DIM` allocates unconditionally (no "already bound" test) so the loaded array would
simply be superseded. The bytes themselves are *not* wiped (nothing zeroes the arena) — they sit unreferenced, and reappear
only by accident when a later `DIM` lands on the same address (E1).

Root causes, in order of importance: **(R-a)** no program-independent identity — arrays are bound by a per-compile index;
**(R-b)** no lifetime rule — run tables are re-carved and zeroed unconditionally; **(R-c)** `OP_DIM` has no notion of an
existing array; **(R-d)** the pool is shared with the source, so any edit reclaims it.

### 3.2 Finding register (new IDs proposed by this audit)

| ID | Sev | Finding | Evidence |
|---|---|---|---|
| **D13** | **H** | `SAVE … ARRAY` emits a **type-0 header** unless `STORAGE_REQUEST_TYPE` happens to be 8. Consequences: (i) `LOAD … ARRAY` of a tape it just wrote never completes the header search [M P7: did not return within the 60 M-instruction budget, still in `STORAGE_LOAD` at `$C217`]; (ii) plain `LOAD "NUM"` **accepts the array tape as a program** and replaces the source with 13 bytes of array data [M P7: `prog_end $827E→$8267`, program changed]. Control: with the type patched to 8 the same tape loads (`LOADED`) | [M] P5, P7; [S] `V2_SAVE_ARRAY` has no store to `STORAGE_REQUEST_TYPE` |
| **D12** | M | `DIM` does not zero-fill (documents promise zero) | [M] E1; [S] |
| **D14** | M | Array names > 8 characters cannot be saved/loaded: `V2_SCAN_ARRAY_NAME` clamps to 8 (`:940–950`) while symbols keep up to 31. `DIM temperature(5)` → `SAVE … ARRAY temperature` and `… TEMPERAT` both `ARRAY NOT DIMD`; `tmp` works | [M] P2 |
| **D15** | H (latent) | `LOAD … ARRAY` never validates the received descriptor (§3.4) | [M] P3 |
| D16 | L | A bad version word on an array tape is reported as `LOAD FAILED`, not `BAD TAPE VERSION` | [M] P3e |
| D6 | H | as §3.1 | [M] |

### 3.3 Other lifecycle defects folded into the picture

* Arrays (and thus `SAVE … ARRAY`) are lost by *any* line store or immediate statement [M P4] — a consequence of R-d, not a bug per se, but it makes
  "RUN, then save the data" fragile (type `: x = 1` and the data can no longer be named).
* Segment-2 arrays can be saved (`V2_SAVE_ARRAY` serialises from the descriptor wherever it lives [M R10.8 t4]) but never reloaded
  there: the receive window is capped to the main pool.

### 3.4 What `LOAD … ARRAY` accepts today [M, probes P3/P6]

Program `GOTO s / DIM a(5) / s: / y = a(2)` compiled, then `LOAD "ARR" ARRAY a`:

| Tape | Result | Why it matters |
|---|---|---|
| good, count 5 (control) | `LOADED`, `ARRAYS_END +13` | |
| count **2** (< declared 5) | `LOADED`, descriptor count 2 | element access checks the *declared* 5, so indexes 2…4 read/write **past the descriptor** — reachable the moment D6 is repaired |
| count **100** (> declared 5) | `LOADED`, `+203` bytes | size silently disagrees with the program |
| string-array body into a numeric target | `LOADED`, `+9` | no kind check |
| header length 13, body says count 100 | `LOADED`, `+203` | arena advanced 190 B past the received data — stale RAM becomes array contents |
| `dim_count` 7 | `LOADED` (byte rewritten to 1) | harmless, but unvalidated |
| count 0 | `LOADED`, `+3` | zero-length array (compile rejects `DIM a(0)`, error 35) |
| tape truncated mid-data | `LOADED`, count from the header, tail = stale RAM | **D1** (carry polarity) |
| dropout inside data | `LOADED` | **D1** |
| bad checksum | `LOAD FAILED`, nothing registered | clean — receive-in-free-space-then-commit works |
| version word `$8200` | `LOAD FAILED` (refused before any byte) | clean |

Receive-in-free-space-then-commit is therefore a sound failure-containment property; what is missing is structural
validation and the D1 fix.

---

## 4. Evaluation of architectures

Four candidates plus the hybrid the brief asked about. "Cost" columns are **[E]** unless noted; the measurable anchors
are the existing routine sizes in §2.7 and the R10.7 data point *string arrays = 1,022 B HOME for a new compiler+VM
feature*.

### 4.1 Option A — preserve preloaded arrays across `RUN`

**A1. Keep pool-resident arrays and pointers across `RUN`** (patch `VM_INIT`/`VM_CARVE_TABLES` not to reset them).
Fails on three independent grounds: (i) the arena base is `SYM_END+1`, and the symbol table is rebuilt by each compile — an
immediate statement or any edit changes its size and either orphans or *overwrites* the arena (the compile writes the new
table over it before `VM_INIT` can react) [S]; (ii) names are known only from the previous compile, so `LOAD` needs a prior
run (`ARRAY NOT DIMD` otherwise [M P0b]); (iii) edits reclaim the pool by design. HOME +30…+60, EXROM +20…+60, **fragile**.
Rejected.

**A2. Name-keyed Array Store outside the pool (recommended).** §5. Segment 2 is outside the pool, so (iii) and the
overwrite hazard vanish; names are stored with the data, so no prior compile is needed.

**A3. Array Store at the top of the pool (below `V2_SOURCE_END`), unbounded by segment 2.** Needs a `POOL_TOP` variable
replacing the constant `V2_SOURCE_END` at ≈ 10 sites (`VM_CARVE_TABLES`, `V2_CLEAR_ARRAYS`, `MEM_INIT_V2`, `MEM_CLEAR_V2`, `V2_LOAD`
receive cap, `SYM_RESET`, `v2_home.asm:61`, symtab:49/511, compiler:3992) [S grep], and makes every stored array shrink the
source capacity. HOME +60…+110, EXROM +150…+250. Only worth it if 2 KB proves too small; listed as increment C4.

### 4.2 Option B — load/save during program execution

New statements (e.g. `LOAD "f" ARRAY a`), compiled to opcodes that call `STORAGE_LOAD/SAVE` from the VM and receive straight
into the already-DIM'd array's data. Properties: **no persistent state at all** (the array is just an array), validation is
trivial (declared count is in the operand), works for any size that fits the pool, matches the stock idiom (`LOAD "x" DATA a()`
inside the program, §9). Costs: new keyword/statement parse with a string-expression filename, opcode(s), VM handler,
decompiler support, command-dispatch conflict (a new line *starting* `LOAD`/`SAVE` at the end of the store is executed as
a command, not stored [S `V2_COMMAND_LOOP`] — the statement needs a different spelling or an editor rule), tape I/O inside
`RUN` (interrupts `di`, no BREAK until D5). HOME +140…+260, EXROM +60…+160 [E]. It does **not** provide "load at the prompt,
then `RUN`" or a program+data bundle. Strong as an *increment*, not as the foundation.

### 4.3 Option C — compact, address-independent tape representation

The existing body is already a verbatim descriptor with no addresses [M P5: numeric `01 05 00 | 0000 0000 2100 0000 0000`,
string `01 02 00 06 | …`]. The remaining value of "C" is a **validator** and, for bundling (§5.5), a tiny self-describing
*entry* (`kind, namelen, name, descriptor`). Kind can be recovered without a new field: with string width ≥ 2 enforced,
`len == 3+2·count` and `len == 4+count·width` cannot both hold for the same body (shown: `c(w−2) = −1` has no solution for
w ≥ 2; the reverse direction needs `c(2−w′) = 1`, impossible for w′ ≥ 2) [S/maths]. So the format needs *no* change beyond
the corrected type byte; the version word stays `$8100`. Cost: EXROM +25…+45 for validation; format-neutral.

### 4.4 Hybrid

C's validator + A2's store + (optionally) B's statements share one validator and one entry format, so they compose; they are
not alternatives. The recommended order is A2 first, B later only if programs need to pull data on demand.

### 4.5 Comparison table

| Criterion | A1 pool preserve | **A2 Array Store (seg 2)** | A3 pool-top store | B in-program | C format only |
|---|---|---|---|---|---|
| HOME ROM | +30…+60 | **+35…+65** | +60…+110 | +140…+260 | 0 |
| EXROM | +20…+60 | **+60…+200 net** | +150…+250 | +60…+160 | +25…+45 |
| Persistent RAM | 0 | 2 B + ≤ 2 KB seg 2 on use | 2 B + pool | 0 | 0 |
| Temp RAM | 0 | 0 (receive in place) | 0 | 0 | 0 |
| Compatible with array/string storage | yes | yes (same descriptors; seg-2 pointers already supported) | yes | yes | yes |
| Survives `RUN` / `CLEAR` / `NEW` | partly; **no** across immediate/edit | RUN yes, edit yes, immediate yes, `NEW` no (decision), `CLEAR` no-op + rebind (decision) | as A2 but edits shrink source | n/a — program-managed | n/a |
| Repeated `RUN` | fragile | stable (adopt is idempotent; also stops the repeated-`DIM` arena leak [S]) | stable | stable | n/a |
| Failed / partial tape | commit-in-place (existing) | **commit-in-place; store untouched on failure** | same | array partly overwritten (documented; stock does the same) | n/a |
| Package ABI 2.0 | none | none (§7.3) | none | none | none |
| Complexity / test surface | medium | medium | high | high (compiler+VM+decompiler) | low |
| Max array size | pool | **2,048 B total** | pool | pool | – |
| Prompt load → `RUN` | only after a prior RUN | **yes** | yes | **no** | – |

---

## 5. Recommended tape format and runtime lifecycle contract

### 5.1 Tape format

| Tape | Header type | Version word | Body |
|---|---|---|---|
| Program (unchanged) | 0 | `$8100` | line store verbatim |
| **Array (corrected, "format 1.0 normative")** | **8** (preserved; D13 fixes the writer) | `$8100` (unchanged) | numeric `[1][count:2][count × 2]`; string `[1][count:2][width:1][count × width]`; `width ≥ 2` |
| Program + arrays bundle (optional C2) | 0 | `$8101` (program format 1.1) | line store ∥ array store blob; header `length` = total, **`proglen` = program bytes** |
| Package | 4 | `$8200` | unchanged |

Reader rules for an array body of received length `L`, applied before commit: `dim_count == 1` (byte rewritten as today);
numeric: `L == 3 + 2·count` and `count ≥ 1`; string: `width ≥ 2`, `L == 4 + count·width`, and every element's `len ≤ width − 1`
(optional pass); store entry must fit. Kind is taken from the `$` suffix of the *command* (store entries record it); a wrong-kind
tape fails the length equation (§4.3). Version handling: unchanged rule; array and program share a word, so a future incompatible
array change requires a third word (`STORAGE_VERSION_WORD` +≈ 8 B EXROM) rather than bumping programs.

Header-type alternatives noted, not recommended: stock types 1/2 (number/char array) would carry kind in the header (§9) but contradict the
Phase-1 decision to preserve type 8.

### 5.2 Store layout (segment 2)

```
$E000  [entry][entry]…[entry] ← PAS_LEN bytes        then: overflow arrays (ARR2_END starts at $E000+PAS_LEN) … $E7FF
entry  = [kind:1 (2 numeric | 3 string)][namelen:1 (1–31)][name:namelen, upper-cased][descriptor: 3+2n or 4+n·w bytes]
```
`PAS_LEN` (2 B sysvar, zero at power-on because `MEM_COLD_INIT` zeroes the pool region, so it needs no init; verified-free
candidate cell `$B81E` — nothing is defined in `$B81E–$B8FF` [M symbol scan]; it is not package-visible, so it is **not** an ABI pin
and needs no ABI version change). Entries are walked linearly; there is no free list.

### 5.3 Lifecycle contract

| Event | Contract |
|---|---|
| `LOAD "f" ARRAY a` | Valid at any time (no prior compile). Discards live arrays and the symbol table (same as an edit — the store region may overlap live overflow arrays), receives into the tail after the entry header, validates, then advances `PAS_LEN`. An existing entry of the same (name, kind) is replaced (delete + compact, rebind is automatic at the next `RUN`). Failure: `PAS_LEN` unchanged, store intact, message `LOAD FAILED` / `BAD TAPE VERSION` / `ARRAY STORE FULL` / `BAD ARRAY TAPE` |
| `SAVE "f" ARRAY a` | Looks up the live array first (as today), else the store entry; writes the corrected type-8 header |
| `RUN` | After `VM_CARVE_TABLES`, **bind**: for each entry `SYM_FIND(name, kind)`; if found, pointer slot ← descriptor address. Unmatched entries stay inert in the store |
| `DIM a(n)` at runtime | Slot bound: declared size must equal stored count (and width) → **adopt** (no allocation, no clearing); mismatch → `ARRAY SIZE MISMATCH` runtime error (new code, not 64). Slot unbound: allocate **and zero-fill** (repairs D12) |
| Program writes to a bound array | Write through to the store (same memory) — values persist into the next `RUN` and into `SAVE … ARRAY` |
| Edit / immediate stmt / program `LOAD` | Store untouched (it is not in the pool) |
| `NEW` | Store cleared (`PAS_LEN = 0`) *(owner decision D-2)* |
| `CLEAR` statement | Live arrays reset as D8 repair defines; store **not** cleared; rebind runs again so subsequent `DIM` still adopts *(owner decision D-2)* |
| Package operations | `LOAD … EXT`, package calls: store untouched; packages must not write `$E000–$E7FF` (already the rule, `PACKAGE_ABI.md` §5.5; tighten wording, no ABI bump) |
| Memory exhaustion | store full → clean message, no change; overflow arrays see `ARR2_LIMIT − ARR2_END` (so `FREE(1)` already reports the reduced space) |

### 5.4 What this does to the three goals

1. Program alone — unchanged (D1/D2 fix, step 2.3).
2. Program + data — two commands today-equivalent (`SAVE "x"` then `SAVE "x" ARRAY a`…), repaired by the above; one-command bundle is increment C2 (§5.5).
3. Arrays independently — `SAVE/LOAD ARRAY` at the prompt with defined visibility at the next `RUN`.

### 5.5 Optional increments (priced separately)

| ID | Increment | HOME | EXROM | Notes |
|---|---|---:|---:|---|
| C1 | create/keep without tape (`DIM` of an unbound name marked persistent, or a `KEEP a` command) | +0…+25 | +30…+60 | needs owner syntax decision |
| C2 | **Bundle**: `SAVE "x" ALL` / `LOAD "x" ALL` — one type-0 file, `proglen` = program bytes, tail = store blob, `$8101`. A pre-1.1 ROM refuses it cleanly (`minor > ROM`); a 1.1 ROM reads old tapes unchanged (`proglen == length` ⇒ empty tail). `LOAD` validates the blob by walking entries *before* committing `PROG_END`/`PAS_LEN` | 0 | +60…+110 | the stock "program + variables" technique (§9) |
| C3 | In-program `LOAD/SAVE … ARRAY` (Option B) | +140…+260 | +60…+160 | needs statement spelling decision |
| C4 | Store larger than segment 2 (A3) | +60…+110 | +150…+250 | only if 2 KB is insufficient |

---

## 6. ROM / RAM budget table

All values are **[E]** except the measured baseline; "measure" says how to obtain the real figure during implementation.

| Item | HOME B | EXROM B | Fixed RAM | Measure with |
|---|---:|---:|---:|---|
| **Baseline [M]** | 546 free (15,838 used) | 1,340 free (6,852 used) | – | trailing-`$FF` count of `v2_home.bin` / `v2_exrom.bin` (as in this audit), `make budget` |
| Stage 0: D13 (`ld a,(V2_REQUEST_TYPE)/ld (STORAGE_REQUEST_TYPE),a`) | 0 | +5 | 0 | symbol delta of `V2_SAVE_ARRAY` |
| Stage 0: names up to 31 (drop the 8-byte fold copy; the lookups already fold case) | 0 | −20…−30 | −8 (`V2_ARRAY_NAME_CANON`) | symbol delta of `V2_SCAN_ARRAY_NAME` |
| Stage 0: `DIM` zero-fill (`MEM_FILL_ZERO` in the shared alloc tails) | +8…+14 | 0 | 0 | `ARENA_ALLOC_*` deltas |
| Stage 0: load validator (kept in the store design; see below) | 0 | +25…+45 | 0 | |
| **A2 core**: bind walk | 0 (EXROM routine) +3 call | +55…+75 | 0 | new routine size |
| A2: adopt check (shared helper + 2 call sites) | +30…+50 | 0 | 0 | `OP_DIM`/`OP_DIM_STR` deltas |
| A2: `VM_INIT`/`V2_CLEAR_ARRAYS` base change (`ld hl,ARR2_BASE` → `ld hl,(PAS_LEN)+ARR2_BASE`) | +0…+4 | +0…+4 | 2 (`PAS_LEN`) | |
| A2: load-to-store, delete/compact, save-from-store, NEW hook, messages | 0 | +150…+230 | ~4 scratch | |
| A2: removed/shrunk (`V2_LOAD_ARRAY` pool path, `CANON`) | 0 | −120…−190 | −8 | |
| **A2 total (net)** | **+35…+65** | **+60…+200** | **−2…+2 net** | `make budget`, ABI checker |
| C2 bundle | 0 | +60…+110 | 0 | |
| B statements | +140…+260 | +60…+160 | ≈ 6 | |
| Store at runtime | – | – | ≤ 2,048 B of segment 2 | `PAS_LEN` |

Floors from the work sequence: HOME ≥ 350, EXROM ≥ 800. After A2 the projection is HOME ≈ 336…456 (with/without step 2.7 and
the range ends), EXROM ≈ 900…1,280 [E]. **The HOME low end breaches the floor by up to ≈ 14 B**; mitigations are the 2.7 study
outcome or moving the adopt helper's body into EXROM behind a fixed entry (HOME +12 instead of +35).

---

## 7. Risks and compatibility

### 7.1 Risks

| Risk | Detail | Mitigation |
|---|---|---|
| D1 dependency | A store commit after a silently truncated receive keeps stale tail bytes (§3.4) | land step 2.3 (carry polarity) first; gate A2 on `D1-*` flipped |
| HOME headroom | above | measure first; helper placement |
| Semantic change of `DIM` | adoption + zero-fill alter observable behaviour (D12 is a doc-vs-code bug, so zero-fill is a fix; adoption is new) | owner decision D-3; release note |
| Stale store surprises | a program with an unrelated `DIM x` of a stored name adopts it | size-mismatch error; `NEW` clears; `PRINT FREE(1)` shows use |
| Segment-2 capacity | store + overflow arrays share 2 KB | clear message; increment C4 |
| Hidden coupling to `ARR2_END` | only two reset sites today [S], but both must read `PAS_LEN` — a third site added later would silently erase the store | assertion test + comment; regression `arr-store-survives-edit` |
| Immediate statements | `: DIM a(5)` adopts like `RUN` (same code path) | document |
| Tape corruption in the middle of a bundle | partly loaded program or store | stage order: receive, validate, then commit both; failure semantic = D2 policy (touched ⇒ NEW state) |
| Analogue tape | all failure tests are synthetic EAR streams (±226 T quantisation), not real recorders | hardware list in §8.5 |

### 7.2 Compatibility

* Existing array tapes: any `SAVE ARRAY` tape written by the current ROM has a type-0 header (D13) and cannot be loaded as an array; it
  loads as a *program* (§3.2). No type-8 tape from a pre-D13 ROM exists except after a `LOAD ARRAY` in the same session. Policy: no
  migration; document. With D13 fixed, format 1.0 means what `PACKAGE_ABI.md` §1 already says.
* Program tapes: unchanged (`$8100`); bundle is a backward-compatible minor.
* V1/legacy builds and standalone tests: the fake-transport harnesses (`STORAGE_TEST_FAKE_*`) must still assemble; the store logic
  is behind `V2_PRODUCTION`-style guards or lives only in `exrom_v2_shell.asm`. `rom/test_v2_array_save_load.asm` stays valid and should be
  extended to cross a `RUN` (the gap R10.8 recorded).

### 7.3 Interaction with package ABI 2.0

| ABI element | Effect |
|---|---|
| Service table (16 slots) | none; no new service required |
| Pinned cells (34) and constants | none touched. `PAS_LEN` goes in a verified-free cell (`$B81E`); the HOME build asserts would catch a collision with a pin. Not package-visible ⇒ no minor bump |
| Segment 2 | `PACKAGE_ABI.md` §5.5 already forbids package writes below `SPRITE_SLOT_IMG_BUF` in chunk 7; restate as "`$E000–$E7FF` is VM-owned" (docs-only) |
| `OP_CALL_EXT` / EXROM paged out | store lives in chunk 7 ⇒ unaffected [M R10.8 t25: segment-2 array intact across SHAPES `CIRCLE/FILL` and SPRITE]. The bind/adopt code runs in the VM/shell, never inside a package |
| Tape version words | array/program share `$8100`; package `$8200` unaffected; `LOAD … EXT` leaves the store alone |
| `abi-*` tests and `check_package_abi.py` | must stay green; add one assertion that no HOME/EXROM listing references a package pin in the new code |

---

## 8. Proposed incremental implementation and test sequence

Every step is gated by `make check`, `make test` (no Fuse), `make budget`, floors HOME ≥ 350 / EXROM ≥ 800, and the ABI checker. No step is started by this audit.

### 8.1 Sequence

| # | Step | Gate (all headless) | Depends on |
|---|---|---|---|
| 0 | **Step 2.3 (tape failure semantics)** lands first | `D1-*`, `D2-*` flip | – |
| 1 | Add the new known-defect cases below (`xfail=`), baseline them on the unmodified ROM | suite reports XFAIL for D12–D16 | – |
| 2 | Stage 0 repairs: D13 type byte; names ≤ 31; DIM zero-fill; D16 message; structural validator in the existing pool-path loader | `arr-save-header`, `arr-name-long`, `arr-dim-zero`, `arr-load-validate-*` flip | 1 |
| 3 | `PAS_LEN` + base change at the two reset sites; no store users yet | all existing tests unchanged; `FREE(1)` unchanged | 2 |
| 4 | Load-to-store, save-from-store, delete/compact, messages | `arr-store-*` | 3, step 0 |
| 5 | Bind at `VM_INIT` + `OP_DIM/DIM_STR` adopt + `OP_CLEAR` rebind | **`D6-array-load-survives-run` flips (XPASS → drop marker)**, `arr-adopt-*`, `arr-store-survives-*` | 4 |
| 6 | Measure, publish figures in a Phase-2 report; compare to §6 | budget within estimate or re-plan | 5 |
| 7 | Owner-approved increments C1…C4 one at a time, each with its own gate | | 6 |

### 8.2 Production-ROM regression cases to add (`tools/v2_prod_regress.py` = gate, `tools/v2_known_defects.py` = xfail until fixed)

| Group | Case id | Assertion |
|---|---|---|
| Save format | `arr-save-header` | numeric and string `SAVE ARRAY` capture: header type 8, word `$8100`, length `3+2n` / `4+n·w`, body bytes as §5.1 (captured at the transport, as `save-header` does) |
| | `arr-save-roundtrip-num/str` | SAVE blocks → synthesised tape → fresh boot → `LOAD` → `RUN` reads the same values |
| | `arr-tape-not-a-program` | an array tape given to plain `LOAD` is refused (no source change) — flips P7 |
| Success | `arr-load-visible-after-run` | the D6 case (existing) + element 0, middle, n−1 |
| | `arr-load-no-prior-run` | `LOAD ARRAY` on a freshly typed program with no `RUN` before |
| | `arr-run-repeat-x3` | three `RUN`s: values unchanged; a write in run 1 is seen in run 2 |
| | `arr-survives-edit/immediate/program-load` | store intact after a typed line, `: x = 1`, plain `LOAD` |
| | `arr-new-clears`, `arr-clear-keeps-store` | per owner decision D-2 |
| | `arr-reload-replaces` | second `LOAD` of the same name replaces; other entries intact; compaction order |
| | `arr-string-array-roundtrip`, `arr-seg2-overflow-coexist` | string kind; overflow array allocated after the store |
| Naming | `arr-name-31`, `arr-name-case`, `arr-name-collision` | 31-char names, case folding, `A` vs `A$` are distinct kinds |
| Adopt | `arr-dim-adopt`, `arr-dim-size-mismatch` (clean error, store intact), `arr-dim-unbound-zero` (dirty RAM first) | |
| Corrupt tapes | `arr-load-bad-checksum` (header and data), `-dropout`, `-truncated`, `-space-abort`, `-bad-version` (`BAD TAPE VERSION`), `-wrong-type` (type 0/4), `-wrong-name` | each asserts message **and** `PAS_LEN` and stored bytes unchanged |
| Incompatible content | `arr-load-count-0`, `-count-huge`, `-len-count-mismatch`, `-string-width-0/1`, `-numeric-into-string` , `-kind-swap`, `-element-len-overflow` | clean failure, store unchanged (flips P3) |
| Boundaries | `arr-n1-element`, `arr-exact-fit`, `arr-one-over` (`ARRAY STORE FULL`), `arr-many-small` (≈ 100 entries) | |
| Exhaustion | `arr-main-pool-full-with-store`, `arr-seg2-full-with-store` (`OUT OF MEMORY`, store intact), `FREE(1)` accounting | |
| Packages/ABI | `arr-pkg-call-keeps-store` (SHAPES `FILL`, SPRITE), `abi-*` unchanged, store not overlapping `$E800` | |
| Bundle (C2) | `bundle-roundtrip`, `bundle-old-tape-ok`, `bundle-new-tape-old-rom-refused`, `bundle-truncated-store` (program untouched or NEW state per D2 policy) | |

Standalone: extend `rom/test_v2_array_save_load.asm` with a `V2_RUN` between load and use (fake transport), and add `rom/test_v2_array_store.asm` for the walk/compact/bind logic.

### 8.3 Measurement plan per change

`python3 tools/report_budget.py` / `make budget` before and after each step (HOME/EXROM free), symbol deltas (`build/exrom.sym`) for each touched routine, the ABI checker, and an explicit RAM table (sysvar addresses, `PAS_LEN`, scratch). Record the numbers in the step report next to the §6 estimate.

### 8.4 Physical-hardware items (cannot be headless)

Real-recorder save and reload of a numeric and a string array and of a ≈ 2 KB store; deliberate dropout and SPACE abort during `LOAD ARRAY`; bundle round trip. (Same analogue-path caveat as `TESTING.md`.)

---

## 9. Lessons from the Original TS2068 ROM

**Method and limits.** Time-boxed read of the fully commented 48K Spectrum ROM disassembly (`/usr/share/doc/spectrum-roms/zx82.htm`,
Logan/O'Hara; routines SAVE-ETC `L0605`, LD-CONTRL/LD-DATA/LD-PROG `L0808–L08B6`, DIM `L2C02`, RUN/CLEAR-RUN `L1EA1/L1EAF`).
The TS2068 home ROM is a derivative of this BASIC; **TS2068-specific differences were not independently checked** — treat
the findings as "verified in the 48K listing", not as verified for the TS2068 ROM.

### Verified findings (48K listing)

| # | Finding |
|---|---|
| S1 | Program, variables and arrays live in **one contiguous, relocatable area** (`PROG … VARS … E_LINE−1`, `$80` end marker). An array is `[letter/type][length:2][ndims][dim sizes:2 each][elements]` (elements 5 B numeric, 1 B string); there are no absolute pointers inside, so the block can be slid with `MAKE-ROOM`/`RECLAIM`/`POINTERS` |
| S2 | `DIM` **zero-fills numeric and space-fills string arrays** with an `LDDR` (`DIM-CLEAR`) — contrary to current Leap (D12) |
| S3 | Plain `SAVE` writes `PROG..E_LINE−1` — **program and variables as one block**. The 17-byte header carries a *total* length (offset 11) and a separate *program* length (offset 15, `VARS−PROG`); `LOAD` uses the second to set `VARS = start + proglen` (`SA-TYPE-0`, `LD-PROG`). Leap's header already has the same two fields; it writes them equal |
| S4 | `SAVE "x" DATA a()` writes header **type 1 (numeric) or 2 (character array)**, the variable letter in the header, and the array body; kind is in the *header*, not inferred |
| S5 | `LOAD … DATA a()` looks the array up **by name at run time** (`LOOK-VARS`), reclaims any existing array, makes room at the end of the variables, restores the letter/length, then receives the block *directly into its final place*. No dimension match is required (the tape's shape replaces the old one); a `TEST-ROOM` check precedes the receive |
| S6 | Both program `LOAD` and `LOAD DATA` are **non-atomic**: the old program/array is reclaimed *before* the data arrives, and a failure raises "R Tape loading error" (the carry convention is *carry set = success*: `LD-BLOCK` does `RET C`). Failure leaves the variable absent/partial |
| S7 | **`RUN` = `RESTORE` + `CLEAR-RUN`, and `CLEAR-RUN` reclaims the entire variables area.** Stock BASIC never preserved variables across `RUN`; the usual way to keep loaded data is for the *program* to execute `LOAD "x" DATA a()` or to continue with `GO TO` instead of `RUN` |

### Possible adaptations (hypotheses, not copied wholesale)

| # | Adaptation | Assessment |
|---|---|---|
| H1 | **Use the existing `PROGLEN` header field** for a one-file program+arrays bundle (S3) | Cheap and backward-compatible with a minor bump; this is increment C2. Best idea from the stock ROM for goal 2 |
| H2 | Resolve names **at the moment of use** (S5 `LOOK-VARS`) | Leap's equivalent is binding by name at `VM_INIT`/`DIM`; the stock choice explains why stock had no D6-style problem: no compile-time indices |
| H3 | Zero-fill on `DIM` (S2) | Adopt; ≈ 8–14 B HOME; repairs D12 |
| H4 | Header-level kind (S4: types 1/2) | Would let the loader reject wrong-kind tapes without length arithmetic; conflicts with the Phase-1 "preserve type 8" decision; length equation (§4.3) achieves the same for free |
| H5 | In-program `LOAD … DATA` (S7) | This is Option B; it is the stock idiom precisely because stock `RUN` wipes variables. Leap can offer it later (C3); it is **not** needed for the prompt-then-`RUN` flow if the store exists |
| H6 | Receive-then-place with a pre-receive room check (S5) | Already how `V2_LOAD_ARRAY` and the store loader work |
| H7 | Do **not** adopt: relocatable variable area, `MAKE-ROOM/POINTERS` fix-ups, single-letter names, replace-on-load of the whole variable block | Cost and complexity with no benefit for a compiled VM whose array references are *indices*, whose arena is append-only, and whose descriptors already contain no addresses |

Net lesson: stock BASIC solved "persistent data" with a **header-borne program/data split (S3)**, **name lookup at use (S5)**, and **program-driven
reload (S7)**; Leap's analogues are, in order of value, the bundle (H1), bind-by-name (H2) and the optional in-program statement (H5).

---

## 10. Owner decisions (resolved at review)

| ID | Decision | Resolution |
|---|---|---|
| **D-1** | Lifecycle model | **Approved: name-keyed Array Store (A2)** as the preferred architecture, subject to implementation measurements and regression tests |
| **D-2** | `NEW` / `CLEAR` | **`NEW` clears persistent arrays. `CLEAR` preserves them** (contents and entries) while resetting runtime bindings safely — see §11.3 for the constraint this puts on the `CLEAR` repair |
| **D-3** | `DIM` semantics | **Approved:** `DIM` adopts a matching stored array; incompatible kind, size or string width ⇒ clean runtime error (store untouched); an ordinary `DIM` zero-fills |
| **D-4** | Capacity | **Accept the existing 2,048-byte shared segment-2 capacity initially** |
| **D-5** | Tape type / version | **Preserve array tape type 8 and format version `$8100`** (no format change; the corrected header type byte is D13's repair) |
| **D-6** | Program + arrays bundle (C2) | **Deferred** until the core works and its actual cost is measured |
| **D-7** | In-program `SAVE/LOAD … ARRAY` (Option B / C3) | **Deferred** |
| **D-8** | Defective pre-repair array tapes | **No migration** |
| **D-9** | Budget | **Planning floors preserved: HOME ≥ 350 B, EXROM ≥ 800 B.** The §6 worst case (HOME ≈ 336) is therefore *not waived*: the core must be built so that it meets the floor — measure first; the adopt helper's body moves to EXROM behind a fixed entry if HOME is short; otherwise re-plan before committing code |
| **D-10** | Ordering | **D1/D2 are fixed before persistent-array commits are enabled.** (Stage-0 repairs that do not commit data to the store — D13 type byte, name length, `DIM` zero-fill, validator — may precede; the store loader and bind/adopt may not) |

Work-sequence consequence (§8.1): step 0 (R10.9 step 2.3) stays first; step 4 onward is blocked on it. Step numbering is otherwise unchanged.

---

## 11. Qualifications to settle and test before implementation

These five items are design obligations recorded at owner review. Each lists the contract, the reasoning, and the test that must exist
(as a proposed case in §8.2, *not yet written*) before the corresponding code is accepted.

### 11.1 Persistent arrays vs live segment-2 overflow arrays

Layout and invariant: the store occupies `[ARR2_BASE, ARR2_BASE + PAS_LEN)`; live overflow arrays are allocated from `ARR2_END`, which
every reset sets to `ARR2_BASE + PAS_LEN`. **Invariant: `ARR2_BASE + PAS_LEN ≤ ARR2_END ≤ ARR2_LIMIT` at all times.** The allocator
(`VM_ARENA_FIT`/swap) is unchanged and cannot allocate below `ARR2_END`.

* **During a `RUN` the store never changes size or moves** (in-program load is deferred, D-7; `CLEAR` does not touch it). Live overflow
  arrays and bound store arrays therefore cannot overlap.
* **Any store mutation** (`LOAD … ARRAY` commit, replacement, compaction, `NEW`) is a prompt-time operation and **first discards all live
  state** exactly as an edit does: symbol table reset, `ARRAYS_END` and `ARR2_END` re-based, pointer tables stale. Rationale: a mutation
  can overwrite bytes at or above `PAS_LEN` where live overflow arrays sit, and can move descriptors that the pointer table
  references. Consequence (documented, not a bug): after a store mutation `SAVE … ARRAY` of a *live non-persistent* array reports
  `ARRAY NOT DIMD` until the next `RUN`; a store array can still be saved by name.
* Receive window for a store load is `[ARR2_BASE+PAS_LEN+entry_header, ARR2_LIMIT)`; it may lie over stale live overflow bytes, which is
  safe only because they are discarded first.
* `FREE(1)` = `ARR2_LIMIT − ARR2_END` already reports the space left for overflow arrays; the store's share is `PAS_LEN`.
* **Tests:** `arr-store-seg2-coexist` (store + overflow array in one run; both correct; `FREE(1)` accounting), `arr-store-load-after-overflow-run`
  (RUN with an overflow array, then store load, then RUN: no corruption either way; the stale live array is unreachable),
  `arr-store-overflow-exhaustion` (overflow `DIM` that no longer fits ⇒ `OUT OF MEMORY` with the store byte-identical), invariant check read from RAM in each.

### 11.2 Safe replacement and compaction without invalidating live pointers

No address of a store descriptor is ever persisted: pointer-table slots are rebuilt by the bind walk at every `VM_INIT` (and after `CLEAR`), so
moving entries cannot leave a dangling persisted pointer **provided no live binding exists while entries move**. The contract that guarantees it:

1. Replacement/compaction run **only at the prompt**, after live state is discarded (§11.1). No `RUN` is active, so the only
   references to store descriptors are the stale pointer slots, which the next `RUN` zeroes and rebinds.
2. Order of operations for `LOAD "f" ARRAY a` when an entry with the same (name, kind) exists: (i) build the new entry header in the free tail,
   receive the body there, (ii) validate it (§11.4), (iii) **only then** delete the old entry by moving everything above it down with one forward
   `LDIR` (downward overlapping moves are safe with `LDIR`), the new entry travelling with that block, (iv) set `PAS_LEN` last. Any failure at (i)/(ii) leaves
   `PAS_LEN` and all stored bytes untouched; (iii)–(iv) cannot fail.
3. **Peak space = `PAS_LEN + new_entry_size`** (old and new coexist until step iii). A replacement of a large array in a nearly full store can therefore report
   `ARRAY STORE FULL` even though the net change is zero or negative. This is intentional (atomicity over density) and is documented in the error text/help.
4. Interrupts are not a hazard: the ISR touches only chunk-4/7 sysvars and the machine stack, never segment 2 [S, `PACKAGE_ABI.md` §5.2].
5. **Tests:** `arr-store-replace-same-size`, `-smaller`, `-larger`, `-middle-entry` (entries before and after survive byte-for-byte), `arr-store-replace-failed-tape`
   (corrupt replacement ⇒ old entry intact), `arr-store-replace-peak-full` (the peak rule), `arr-store-compact-then-run` (replace entry 1 of 3, `RUN`: all three bind to the right descriptors),
   `arr-store-no-stale-pointer` (zero the pointer slots, replace, `RUN`, bind addresses match a fresh walk).

### 11.3 Repeated `RUN`, `CLEAR`, `NEW`, editing, program `LOAD`

Expected behaviour of a stored array `s` (program contains a matching `DIM s(n)`) and of a non-persistent array `t`:

| Event | `s` (stored) | `t` (ordinary) | Store |
|---|---|---|---|
| `RUN` ×N | rebinds each run; contents are those left by the previous run (writes persist) | fresh, zero-filled each run | unchanged |
| program writes `s` then ends; `SAVE "x" ARRAY s` | saved with the written values | – | unchanged |
| typed line / edit | unaffected | discarded | unchanged |
| immediate statement `: …` | bound only if that one-line compile mentions `s` (same bind rule) | discarded | unchanged |
| program `LOAD` | unaffected (inert unless the new program `DIM`s it) | discarded | unchanged |
| `CLEAR` statement | **contents preserved, rebound** | reset/zero-filled by a later `DIM` | unchanged |
| `NEW` | **gone** | gone | `PAS_LEN = 0` |
| `LOAD … ARRAY` / replace | per §11.2 | discarded | mutated |
| `LOAD … EXT` / package calls | unaffected | unaffected | unchanged |
| cold boot | gone (`PAS_LEN` is zero-initialised by `MEM_COLD_INIT`; segment-2 bytes are not trusted outside `PAS_LEN`) | gone | empty |

**Constraint found while writing this table (must be resolved in the `CLEAR` repair, R10.9 step 2.6, before the store ships):** today `OP_CLEAR` →
`MEM_CLEAR_V2` → `V2_CLEAR_ARRAYS` → **`SYM_RESET` while the program is running**, and sets `VARS_START = V2_SOURCE_END` while the carved tables still live below it [S,
`rom/exrom_v2_shell.asm:746–780`]. Rebinding after `CLEAR` needs the compile symbol table (`SYM_FIND` by name), so the repaired `CLEAR` **must not reset the symbol
table or raise `VARS_START`**, and must re-run the bind walk after zeroing the pointer slots. Step 2.6 and the store must therefore be designed together; if 2.6 lands first it
must already preserve the symbol table.

**Tests:** `arr-run-repeat-x3` (value written in run 1 seen in runs 2 and 3), `arr-clear-keeps-store` (contents and entry intact; later `DIM` re-adopts), `arr-clear-ordinary-zeroed`,
`arr-new-clears`, `arr-edit-keeps-store`, `arr-immediate-keeps-store`, `arr-program-load-keeps-store`, `arr-coldboot-empty`, `arr-store-unrelated-name-inert`.

### 11.4 Structural validation of numeric and string descriptors

Validation runs in the store loader on the *received* bytes **before** `PAS_LEN` advances, and again as a cheap consistency check at bind/adopt. All failures are clean (store unchanged) with a distinct message.

| Check | Numeric | String |
|---|---|---|
| Header type / version | type 8, word `$8100` (transport) | same |
| Received length `L` equals the header length (transport) | required | required |
| `dim_count` | `= 1` (any other value rejected, not rewritten) | same |
| `count` | `≥ 1`; `3 + 2·count` computed without 16-bit overflow | `≥ 1`; `4 + count·width` computed without 16-bit overflow |
| Length equation | `L == 3 + 2·count` | `L == 4 + count·width` |
| Width | – | `2 ≤ width ≤ 255` (width 1 would defeat the kind-by-length argument of §4.3) |
| Element integrity | – | **every element `len ≤ width − 1`** (required: a corrupted length byte must not be able to make a string-array read copy past an element or a temp string slot — *the VM's copy path was not audited here; treat the check as mandatory until the implementation proves it unnecessary*) |
| Kind vs command | `$` suffix absent | `$` suffix present; failure of the length equation is the wrong-kind detector (§4.3) |
| Name | – | store entry `namelen 1…31`, characters as the lexer accepts, stored upper-case |
| Fits | entry ≤ `ARR2_LIMIT − (ARR2_BASE+PAS_LEN)` (peak rule, §11.2) | same |
| At `DIM` adopt | stored `count == declared count` | `count == declared` **and** `width == declared width` |

Incompatible size/width at `DIM` ⇒ clean runtime error that halts the run with the store untouched (new error codes distinct from 64, allocated in the VM's namespace; to be assigned
in implementation — message text must say *size* vs *width*). Kind cannot mismatch at `DIM`: (name, kind) is the key, so `a` and `a$` are different entries.

**Tests:** the "Incompatible content" and "Corrupt tapes" groups of §8.2, plus `arr-load-string-elem-len-bad`, `arr-load-count-overflow` (count × width > 65 535), `arr-load-dim-count-2`, `arr-dim-width-mismatch`, `arr-dim-size-mismatch`.

### 11.5 Program-plus-arrays is not a program-plus-variables snapshot

The deferred bundle (C2, D-6) would store **program text + the persistent Array Store only**. It does **not** capture, and nothing in this
architecture implements: scalar numeric/string variables, non-persistent (live) arrays, floats, the control stack, `FOR`/`PROC`/`DEF FN` state, `RND` seed, print/graphics
attributes or display state, or the package registry. "Program together with its current variables/data" — the original goal 2 — therefore remains **a separate, unimplemented
goal**. After the core ships the honest status is: *program and persistent arrays can be saved/loaded together as two commands (or, later, one); a snapshot of arbitrary current
variables cannot.* Any documentation, help text or release note must use "program + arrays", never "program + variables". Reopening the full snapshot is an owner decision
that needs its own audit (it would have to define what `RUN` and `CLEAR` do to restored scalars, and a serialisation of the carved tables).

---

## Appendix A — measured results (this audit)

All on `build/ts2068rom_zesarux.bin`, headless ZEsarUX through `tools/v2_prod.py`; scratch probes outside the repo.

| Probe | Result |
|---|---|
| `D6-array-load-survives-run` (existing case) | `XFAIL`: `load_msg=LOADED ptr_after_load=8293 then RUN: vm_err=10 y=0` |
| E1 `DIM a(5)/y=a(2)/a(2)=33` ×3 | `y = 0, 33, 33`; `ARRAYS_END=$8296` each run |
| P1b cold boot `DIM a(2000)` | 0 non-zero bytes of 4,000 |
| P0 good tape after a prior `RUN` | `LOADED`, `ARRAYS_END +13` |
| P0b no prior compile | `ARRAY NOT DIMD` |
| P0c program executes `DIM a(5)` | `ARRAY ALREADY SET` |
| P2 names | `tmp` → `SAVED`; `temperature` and `TEMPERAT` → `ARRAY NOT DIMD` |
| P4 | after `RUN` → `SAVED`; after `: q = 1` → `ARRAY NOT DIMD`; after typing a new line → `ARRAY NOT DIMD` |
| P5 `SAVE` header capture | numeric: `00 'NUM       ' 0d00 0081 0d00`, body `01 0500 0000 0000 2100 0000 0000`; string: `00 'STR       ' 1000 0081 1000`, body `01 0200 06 …` (type byte 0) |
| P7 | tape as saved: `LOAD ARRAY` did not return in 60 M instructions (`HUNG@C217`); type patched to 8: `LOADED`; plain `LOAD "NUM"` of the same tape: `LOADED`, `prog_end $827E→$8267` |
| P3a–f, P6 | table in §3.4 |
| Baseline budget | HOME 546 free, EXROM 1,340 free (trailing `$FF` of the built images) |

## Appendix B — method notes

Probe scripts import `tools/v2_prod.py` (`boot`, `put_store`, `call_prompt("V2_RUN_STORED"/"V2_DISPATCH")`, `tape_op`, `TS.Tape`,
`header_payload`, `framed`), poke `EDIT_LINE_BUF` with the command text, and read `RT_ARRPTR_PTR`, `ARRAYS_END`, the descriptor and the
message name (`V2_SHOW_MESSAGE` break). The `SAVE` capture intercepts `STORAGE_SEND_BLOCK` exactly as the gate case `save-header` does.
Limits identical to `TESTING.md`: synthetic EAR stream, keys not scanned, SAVE output pulses not generated. The stock-ROM
section used the plain-text rendering of `zx82.htm`. Estimates in §1.4 and §6 are anchored on the measured sizes in §2.7 and
on R10.7's recorded costs; none was assembled.

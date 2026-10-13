# V2 ROM and RAM budget (V2 Enhanced release)

All numbers are measured (`make build v2-packages && make budget` on each commit, or the
`build/qual_budget.log` of its export under `~/2068-Leap-study/qual-builds/`), not estimated,
unless marked *est*.

## Where the release stands

| Image | Size | Used | Free | Provisional reserve target (owner decision 4) |
|---|---|---|---|---|
| HOME ROM | 16384 | 16330 | **54** | 200 |
| EXROM | 8192 | 8167 | **25** | 150 |

Additional fragments not counted as free by `make budget`: 6 bytes left in the old KTAB space
(`$008B-$0090`). The reserve targets are **not met** (owner decision 4 treats them as provisional
hardware-release contingencies, not limits: correctness first). Options to restore reserve are at
the end.

## How it got there (free bytes after each step)

| Step | Commit | HOME | EXROM | What changed |
|---|---|---|---|---|
| `v2-development` (production) | `7ae0599` | 565 | 802 | starting point |
| Enhanced chain, unshrunk | `8379ab5` | 180 | 239 | multi-item PRINT, OUT, D11 promotion, qualification fixes Q-01..Q-31 |
| + RST and emit-stub shrinks (merged) | `bb9c990` | 670 | 233 | study prototypes, bytecode identical |
| float args, D11 boundaries | `3c42a6c` | 525 | 233 | Q-10, D11-EXT |
| SIN/COS fractional degrees, TAN, SQR | `e951c82` | 425 | 233 | Q-10, Q-22 |
| exact float formatter | `02ed291` | 425 | 184 | D10, D11-DISP |
| shared number parser, PUSH_FLOAT5 | `d55d636` | 385 | 184 | Q-15/16/17, Q-09, L-C literals |
| string relations, short-circuit AND/OR | `09fdc2a` (rc1) | 318 | 184 | L-STR, L-SC, Q-25 |
| bare NEXT, N-4, PLOT clamp, STICK, CLEAR, L3 | `1a395c7` (rc2) | 260 | 184 | |
| CHK_ERR / VM_PUSH_INT / clamp shrinks | `96787a2` | 352 | 184 | |
| session variables | `f8042ab` | 195 | 49 | owner decision 2, part 1 |
| float overflow = error 67 | `85d59ee` (rc3) | 167 | 49 | RC-1 |
| session fixes; OP_AND/OR removed; jp->jr | `d404b57` (rc4) | 269 | 42 | |
| SAVE ALL + space work | `07616e7` (rc6) | 65 | 25 | owner decision 2, part 2 |
| identity CRC covers the package registry | `ef81f49` (rc7) | 54 | 25 | RC-9; ROM unchanged after it |

### The space work in `07616e7` (each measured on its own)

| Change | HOME | EXROM |
|---|---|---|
| EXROM entry slots packed (unused V1 SAVE/LOAD/EDITOR_* slots and padding removed) | -- | +153 |
| legacy-only routines left out of the V2 images (`IFNDEF V2_PRODUCTION`) | +66 | +41 |
| compiler tail calls through RST $20 / $08 | +41 | -- |
| VM handlers end `jp (iy)` | +32 | +2 |
| KTAB jump table not emitted in production (81 bytes reused for SAVE ALL code) | +81 | -- |
| six small routines in the RST-slot padding; four error stubs via RST $30 | +40 | -- |
| one more jp->jr | -- | +1 |
| SAVE ALL itself (HOME half: CRC, layout, LOAD checks / EXROM half: SA_BUILD and the shell glue) | -~465 | -~215 |

## RAM

> **Current layout (after the RAM-efficiency change, `docs/RAM_EFFICIENCY_RESULTS.md`):** main pool
> `$825A-$A654` (9211 bytes) running straight into the bytecode area `$A655-$B5FF` (4011); fixed V2 area
> `$B600-$BFFF`, which now also holds the compile zone (`$B850-$B97D`, 302). `FREE()` on an empty machine
> 8967 (was 8153). The ROM free space after the maintenance release is HOME 19 / EXROM 26 bytes
> (`V2_MAINT_RELEASE_STATUS.md`), HOME 25 after this change. The figures below are those of the
> v2.0.0-emu.1 release.

* Main pool (program text, symbol table, session gap, arrays, run-time tables): `$825A-$A326`, 8397
  bytes. Compile zone `$A327-$A454` (302). Bytecode `$A455-$B3FF` (4011). Fixed V2 area
  `$B400-$BFFF`. Segment 2 `$E000-$E7FF` (2048: Array Store + overflow arrays).
* The pool available to a program is 154 bytes smaller than in R10.7, measured with the same
  program (`FREE()` 1022 at `7ae0599`, 948 at rc2, 868 at rc4; the production check `free-1` went
  967 -> 813):
  * 74 bytes: two more string temporaries (2 x 32) and two more float temporaries (2 x 5) --
    QUAL Q-02 (temporaries are never reused while referenced, `817667f`);
  * 80 bytes: `SESS_GAP`, room for the names immediate statements add to a session.
* Scalar capacity: 255 minus the temporaries = **251** numeric and **251** string names (was 253;
  measured: 251 compile and run, the 252nd is compile error 1).
* New fixed cells: `$B82A-$B84A` (session state, `SA_AE`, `ASV_CHECK`, `SA_BUILT`); nothing
  outside `$B400-$BFFF` moved.
* `SAVE ... ALL` needs no free memory for a copy (the session is moved in place); its limit is the
  bytecode area (`V2_SAVE_ALL_FORMAT.md`).

## Options to restore the reserve (for the owner)

Ordered as the brief's space strategy (reuse, duplication, proven shrinks, rebalance, packages,
optional features). Each is an estimate until measured on a branch.

| Option | HOME | EXROM | Cost / risk |
|---|---|---|---|
| Use the 42-byte reserved package-slot room (`$00C6-$00EF`) for code | +~40 *est* | -- | reduces room for future package-ABI slots (append-only growth) |
| Replace the runtime identity CRC by a build-time ID | +~10 *est* | -- | weaker: trusts the build to stamp it |
| Drop VERIFY support for ALL tapes | -- | +~12 *est* | VERIFY of an ALL tape would always fail |
| Move the sprite capture/draw services into the SPRITE package | +~60..120 *est* | -- | package ABI major change: every sprite package tape must be rebuilt |
| Move SIN/COS/TAN (and their support) into a package | +~250 *est* | -- | trigonometry would need `LOAD ... EXT`: a language change |
| A further shrink pass (z80-shrink lanes not yet tried: dedup in the shell/editor, message strings) | +? | +? | needs a measured study |

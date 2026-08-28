# ROM Space Audit

Status: measured from a clean assembly on 2026-08-27. Run `make budget` to
regenerate the authoritative totals and module map after any source change.

## Result

The current product image has **2 free bytes in the 16K HOME ROM** and **99
free bytes in the 8K EXROM**. The ROMs contain no unallocated internal regions
between their top-level modules; their only general-purpose free space is the
final padding at `$3FFE-$3FFF` and `$DF9D-$DFFF`.

This means a V2 can add features in the same 24K, but each nontrivial feature
must first pay for itself through code/data reduction or replacement. The 101
currently free bytes are enough for a tiny fix, entry wrapper, or table change,
not a new substantial command.

## Measured map

The following figures are byte-accurate at top-level include boundaries. They
include each module's routines, local tables, strings, and any internal
alignment. They do not claim every byte in a module is live code.

### HOME ROM

| Address range | Bytes | Share | Source |
|---|---:|---:|---|
| `$0000-$010E` | 271 | 1.7% | Driver, vectors, EXROM call table, initialization |
| `$010F-$2C88` | 11,130 | 67.9% | `basic/basic.asm` |
| `$2C89-$2F8C` | 772 | 4.7% | `kernel/memory/memory.asm` |
| `$2F8D-$3196` | 522 | 3.2% | `kernel/io/io.asm` |
| `$3197-$3D5F` | 3,017 | 18.4% | `kernel/graphics/graphics.asm` |
| `$3D60-$3F00` | 417 | 2.5% | `kernel/math/math.asm` |
| `$3F01-$3F37` | 55 | 0.3% | `kernel/sound/sound.asm` |
| `$3F38-$3FC7` | 144 | 0.9% | `kernel/interrupt/interrupt.asm` |
| `$3FC8-$3FFD` | 54 | 0.3% | `kernel/bank/bank.asm` |
| `$3FFE-$3FFF` | **2** | <0.1% | **Unallocated padding** |

### EXROM

| Address range | Bytes | Share | Source |
|---|---:|---:|---|
| `$C000-$C73B` | 1,852 | 22.6% | Checker plus fixed entry table |
| `$C73C-$CABF` | 900 | 11.0% | Storage |
| `$CAC0-$CB83` | 196 | 2.4% | Formatting helpers |
| `$CB84-$CC42` | 191 | 2.3% | Help |
| `$CC43-$D48D` | 2,123 | 25.9% | Calculator |
| `$D48E-$D49E` | 17 | 0.2% | Sound command |
| `$D49F-$D4F1` | 83 | 1.0% | ULAplus |
| `$D4F2-$D8A7` | 950 | 11.6% | Sprites |
| `$D8A8-$DA2A` | 387 | 4.7% | String functions |
| `$DA2B-$DD19` | 751 | 9.2% | Editor |
| `$DD1A-$DD67` | 78 | 1.0% | Arrays |
| `$DD68-$DE35` | 206 | 2.5% | INPUT |
| `$DE36-$DF00` | 203 | 2.5% | DIM allocator |
| `$DF01-$DF9C` | 156 | 1.9% | Keyword highlighting |
| `$DF9D-$DFFF` | **99** | 1.2% | **Unallocated padding** |

## Best V2 space-recovery targets

These are candidates for measurement, not bytes already proven recoverable:

1. **BASIC (11,130 bytes).** It dominates HOME. Shared parsing tails, repeated
   whitespace/boundary checks, error exits, and command wrappers offer the
   largest likely return. A 3% reduction would recover about 334 bytes.
2. **Graphics (3,017 bytes).** Audit normal/high-resolution paths for common
   clipping, coordinate, attribute, and pixel-address logic. A 5% reduction
   would recover about 151 bytes.
3. **EXROM calculator (2,123 bytes).** Review dispatcher/table representation,
   repeated stack checks, and duplicated numeric conversion/error paths. A 5%
   reduction would recover about 106 bytes.
4. **Checker and fixed entry area (1,852 bytes).** Keep the public fixed entry
   addresses, but audit the bodies for common scanners and common failure
   returns. The six-byte trampoline spacing is an ABI cost and should not be
   casually repacked.
5. **Text and tables.** HELP text, error strings, keyword tables, note tables,
   and other data can use shared suffixes/prefixes or a compact encoding. This
   is safer than compressing executable code, provided decoding overhead is
   included in the net saving.

## What has and has not been established

- Confirmed: final free space, module boundaries, physical ROM sizes, and that
  there are no gaps between top-level modules.
- Not yet confirmed: unreachable routines, duplicate instruction sequences,
  or exact per-routine savings. Assembly labels alone cannot prove a routine is
  dead because Z80 code may reach it through jump tables, calculated addresses,
  or externally stable entry points.
- Before deleting a suspected routine, check direct references, jump/data
  tables, HOME/EXROM ABI entries, test harness entry points, and emulator or
  hardware behavior.

The practical next audit is therefore per-routine size and reference analysis
of `basic/basic.asm`, followed by graphics and the EXROM calculator. That is
where a V2 feature budget of several hundred bytes is most plausibly found.

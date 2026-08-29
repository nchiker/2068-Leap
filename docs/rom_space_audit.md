# ROM Space Audit

Status: V2 first recovery pass, verified 2026-08-28. Run `make budget` to
regenerate the authoritative totals and module map after any source change.

## Result

After the recovery work and subsequent calculator/sprite hardening, the current
V2 image has **215 free bytes in the 16K HOME ROM** and **100 free bytes in the
8K EXROM**. The V1 baseline was 2 and 99 bytes respectively.

The 315-byte combined end-of-image budget is now primarily a correction margin;
larger additions require another measured recovery pass.

## Measured map

The following figures are byte-accurate at top-level include boundaries. They
include each module's routines, local tables, strings, and any internal
alignment. They do not claim every byte in a module is live code.

### HOME ROM

| Address range | Bytes | Share | Source |
|---|---:|---:|---|
| `$0000-$0111` | 274 | 1.7% | Driver, vectors, EXROM call table, initialization |
| `$0112-$2B7E` | 10,861 | 66.3% | `basic/basic.asm` |
| `$2B7F-$2E97` | 793 | 4.8% | `kernel/memory/memory.asm` |
| `$2E98-$30A1` | 522 | 3.2% | `kernel/io/io.asm` |
| `$30A2-$3C8A` | 3,049 | 18.6% | `kernel/graphics/graphics.asm` |
| `$3C8B-$3E2B` | 417 | 2.5% | `kernel/math/math.asm` |
| `$3E2C-$3E62` | 55 | 0.3% | `kernel/sound/sound.asm` |
| `$3E63-$3EF2` | 144 | 0.9% | `kernel/interrupt/interrupt.asm` |
| `$3EF3-$3F28` | 54 | 0.3% | `kernel/bank/bank.asm` |
| `$3F29-$3FFF` | **215** | 1.3% | **Unallocated padding** |

### EXROM

| Address range | Bytes | Share | Source |
|---|---:|---:|---|
| `$C000-$C661` | 1,634 | 19.9% | Checker plus fixed entry table |
| `$C662-$C9E5` | 900 | 11.0% | Storage |
| `$C9E6-$CAA9` | 196 | 2.4% | Formatting helpers |
| `$CAAA-$CB68` | 191 | 2.3% | Help |
| `$CB69-$D3F7` | 2,191 | 26.7% | Calculator |
| `$D3F8-$D408` | 17 | 0.2% | Sound command |
| `$D409-$D45B` | 83 | 1.0% | ULAplus |
| `$D45C-$D8A6` | 1,099 | 13.4% | Sprites |
| `$D8A7-$DA29` | 387 | 4.7% | String functions |
| `$DA2A-$DD18` | 751 | 9.2% | Editor |
| `$DD19-$DD66` | 78 | 1.0% | Arrays |
| `$DD67-$DE34` | 206 | 2.5% | INPUT |
| `$DE35-$DEFF` | 203 | 2.5% | DIM allocator |
| `$DF00-$DF9B` | 156 | 1.9% | Keyword highlighting |
| `$DF9C-$DFFF` | **100** | 1.2% | **Unallocated padding** |

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

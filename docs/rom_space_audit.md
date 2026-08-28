# ROM Space Audit

Status: V2 first recovery pass, verified 2026-08-28. Run `make budget` to
regenerate the authoritative totals and module map after any source change.

## Result

The current V2 image has **360 free bytes in the 16K HOME ROM** and **317 free
bytes in the 8K EXROM**. This is up from the V1 baseline of 2 and 99 bytes.

The 677-byte combined end-of-image budget can fund modest V2 features, but it
should retain a safety margin for fixes and new EXROM entry wiring.

## Measured map

The following figures are byte-accurate at top-level include boundaries. They
include each module's routines, local tables, strings, and any internal
alignment. They do not claim every byte in a module is live code.

### HOME ROM

| Address range | Bytes | Share | Source |
|---|---:|---:|---|
| `$0000-$010E` | 271 | 1.7% | Driver, vectors, EXROM call table, initialization |
| `$010F-$2B22` | 10,772 | 65.7% | `basic/basic.asm` |
| `$2B23-$2E26` | 772 | 4.7% | `kernel/memory/memory.asm` |
| `$2E27-$3030` | 522 | 3.2% | `kernel/io/io.asm` |
| `$3031-$3BF9` | 3,017 | 18.4% | `kernel/graphics/graphics.asm` |
| `$3BFA-$3D9A` | 417 | 2.5% | `kernel/math/math.asm` |
| `$3D9B-$3DD1` | 55 | 0.3% | `kernel/sound/sound.asm` |
| `$3DD2-$3E61` | 144 | 0.9% | `kernel/interrupt/interrupt.asm` |
| `$3E62-$3E97` | 54 | 0.3% | `kernel/bank/bank.asm` |
| `$3E98-$3FFF` | **360** | 2.2% | **Unallocated padding** |

### EXROM

| Address range | Bytes | Share | Source |
|---|---:|---:|---|
| `$C000-$C661` | 1,634 | 19.9% | Checker plus fixed entry table |
| `$C662-$C9E5` | 900 | 11.0% | Storage |
| `$C9E6-$CAA9` | 196 | 2.4% | Formatting helpers |
| `$CAAA-$CB68` | 191 | 2.3% | Help |
| `$CB69-$D3B3` | 2,123 | 25.9% | Calculator |
| `$D3B4-$D3C4` | 17 | 0.2% | Sound command |
| `$D3C5-$D417` | 83 | 1.0% | ULAplus |
| `$D418-$D7CD` | 950 | 11.6% | Sprites |
| `$D7CE-$D950` | 387 | 4.7% | String functions |
| `$D951-$DC3F` | 751 | 9.2% | Editor |
| `$DC40-$DC8D` | 78 | 1.0% | Arrays |
| `$DC8E-$DD5B` | 206 | 2.5% | INPUT |
| `$DD5C-$DE26` | 203 | 2.5% | DIM allocator |
| `$DE27-$DEC2` | 156 | 1.9% | Keyword highlighting |
| `$DEC3-$DFFF` | **317** | 3.9% | **Unallocated padding** |

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

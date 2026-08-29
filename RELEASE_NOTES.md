# 2068 Leap V2 prerelease candidate

This candidate develops V2 independently on `develop/v2` while the V1 private
preview remains available on `release/v1`. It concentrates on ROM headroom,
subsystem correctness, and regression coverage rather than cartridge support.

## V2 changes

- Recovered ROM space with symbol-derived BASIC audits and table-driven BASIC
  execution, numeric-function, and EXROM checker dispatch.
- Established one canonical production editor implementation and documented
  the boundary between generic editing and BASIC-specific integration.
- Hardened the EXROM calculator against invalid literals, stack underflow and
  overflow, division by zero, numeric overflow, and conversion boundaries.
- Restored six standalone calculator smoke ROMs and made calculator and sprite
  simulator checks part of the normal validation gate.
- Hardened sprite parsing and state transitions: complete 16-bit range checks,
  transactional `MOVE`, safe re-`GRAB`, initialized state, and overflow-safe
  kernel bounds checks.
- Added an eight-slot display stack. Overlapping save-under sprites must be
  moved or hidden in reverse `SHOW` order; invalid operations fail before the
  screen changes.
- Global screen transformations (`CLS`, `MODE`, scrolling, editor entry, and
  paths using `CLS` such as RUN/NEW/LOAD/help) invalidate displayed sprite
  state while preserving captured images for reuse.
- Cold start now clears the complete ROM-owned `$8000-$BFFF` RAM region before
  any sysvar, bank-depth counter, hook, or port shadow is read. Startup no
  longer depends on an emulator providing zero-filled RAM.

## Validation baseline

- 68 integrated BASIC fixtures pass.
- Nine standalone runtime smoke ROMs pass in Fuse.
- Fifteen standalone smoke ROM targets assemble successfully.
- Automated production-editor regression passes.
- Calculator dispatcher, sprite graphics, sprite state, display-order, and
  invalidation simulator checks pass through `make check`.
- Home ROM: 238 bytes free; EXROM: 100 bytes free; dynamic RAM pool: 1,847
  bytes.

## Candidate boundaries

- V2 is not cartridge-focused; cartridge support and a public cartridge ABI
  remain deferred.
- Eight fixed sprite slots reserve 2,352 bytes including metadata and display
  ordering. Reducing or dynamically allocating them remains a future option.
- Sprite restoration uses a display stack rather than a compositor, so
  `HIDE` and `MOVE` must follow reverse display order.
- The calculator is a focused internal arithmetic service, not a complete
  implementation of the original Sinclair calculator literal set.
- Programs use 2068 Leap's structured, line-number-free representation and
  are not byte-compatible with stock tokenized Sinclair BASIC programs.

No V2 tag is assigned by this document. Tagging follows clean-build emulator
verification and explicit selection of the next prerelease version.

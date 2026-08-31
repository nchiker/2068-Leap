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
- Replaced resident `CPLOT` with the 121-byte reference RAM BASIC extension.
  Its single-slot gateway validates the existing two-expression grammar in ROM,
  invalidates cached editor errors on registration, and unregisters on `NEW`.

## Validation baseline

- 73 integrated BASIC fixtures pass.
- Nine standalone runtime smoke ROMs pass in Fuse.
- Fifteen standalone smoke ROM targets assemble successfully.
- Automated production-editor regression passes.
- Fixed CAPS SHIFT+ENTER's first-redraw omission: the statement shifted below
  a newly inserted blank line now remains visible immediately, before the user
  types into that blank line. The automated editor harness covers the exact
  two-statement insertion sequence and inspects physical display RAM.
- Calculator dispatcher, sprite graphics, sprite state, display-order, and
  invalidation simulator checks pass through `make check`.
- Home ROM: 10 bytes free; EXROM: 35 bytes free; dynamic RAM pool: 15,310
  bytes. Transient `FILL` scratch and persistent sprite, label, UDG, editor,
  and detokenizer storage now use safe upper HOME RAM. The command-phase token,
  status, EDIT-copy, and multi-statement buffers share
  one 130-byte reservation; the follow-up audit also removed 45 bytes of dead
  state. Independent review caught two unsafe lifetime assumptions before
  commit: named LOAD now retains its filename in the edit buffer, clear of its
  status callback, and static-checker string functions again have a dedicated
  128-byte pool so they cannot overwrite an uncommitted edit line.
- The dedicated string-function pool now lives at `$F328-$F3A7` in
  always-visible chunk 7, increasing dynamic BASIC RAM by another 128 bytes
  while leaving 2,304 bytes of genuine stack headroom above the fixed extension
  state and module window. A canary-based valid
  nested-expression run observed a 126-byte peak; this is a measurement, not a
  claimed global maximum.
- Added minimal classic numeric `DEF FN`: one single-letter function, one
  numeric parameter, and an expression result (`DEF FN S(X)=X*X`, called as
  `FN S(value)`). Definitions take effect when execution reaches them;
  recursion is deliberately rejected. The measured cost is 238 Home bytes and
  102 EXROM bytes.
- Added a deterministic named-LOAD regression which stubs only the pulse
  receiver while exercising the real command parser, progress redraws,
  filename comparison, `3 -> 7 -> 4` state sequence, and installed bytes.
- A byte-exact branch audit replaced 70 eligible absolute jumps with relative
  jumps and inverted five two-branch tails. Unsupported Z80 conditions,
  historically tight branches, low-margin targets, and editor code were left
  unchanged. This recovered 11 Home-ROM and 71 EXROM bytes without changing
  RAM, fixed entry addresses, or the KTAB ABI.

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

# Contributing to 2068-Leap

Contributions, bug reports, emulator results, and real-hardware test reports
are welcome.

## Before submitting a change

1. Build and run the static checks with `make check`.
2. Confirm ROM capacity with `make budget`.
3. When Fuse and an X11 display are available, run the full suite with
   `make test`.
4. Update the user and technical documentation when behavior changes.
5. Add or update a fixture in `tests/` for BASIC-language changes.

Home ROM and EXROM capacity are hard architectural limits. Please include the
before/after output of `make budget` for changes that add ROM code.

Keep commits focused and do not commit generated assembler output, local ROM
images, emulator screenshots, tape captures, or copyrighted reference ROMs.

## Coding standard

Z80 / sjasmplus, symbolic constants only (`include/`), one module = one
concern, every public routine documented in its header comment and in the
Programmer's Reference, correctness before optimization. See
[`docs/programmers_reference.md`](docs/programmers_reference.md) for the
long version and [`docs/development_log.md`](docs/development_log.md) for
the module-by-module build/test history.

**Before considering any non-trivial change to a large `.asm` file
finished**, run:
```
python3 tools/check_asm.py basic/basic.asm
```
(or list other files as arguments — no arguments defaults to
`basic/basic.asm`, the largest and most actively edited file). Catches,
from source alone with no assembler needed: duplicate global labels,
local-label scope errors (a stray bare label silently ending sjasmplus's
scoping for everything after it — this project's single most expensive
bug once), and a stack-ordering fingerprint (a routine popping something
before pushing anything of its own). None of this replaces actually
assembling and testing — sjasmplus and real hardware/emulator behavior
are still ground truth — but every check here is free, fast, and catches
something this project has genuinely shipped before.

**After adding a font glyph, punctuation mapping, or HELP topic**, run:
```
python3 tools/check_docs.py
```
Cross-checks counts/names quoted in the docs (glyph count, punctuation
count, HELP topic coverage) against the actual source tables — this
project has had exactly this kind of doc staleness slip through twice
before.

By contributing, you agree that your contribution is licensed under the MIT
License used by this repository. Changes to the Fuse-derived material under
`patches/` are instead contributed under GPL-2.0-or-later, matching Fuse.

# Contributing to 2068-Leap

Contributions, bug reports, emulator results, and real-hardware test reports
are welcome.

## Before submitting a change

Work on V2 happens on the `v2-development` branch (V1 on `main` is archived;
see [`docs/v1/README.md`](docs/v1/README.md)).

1. Build and run the static checks with `make check`.
2. Confirm ROM capacity with `make budget`.
3. With the patched ZEsarUX and `ts2068-debug` installed (see
   [`docs/TESTING.md`](docs/TESTING.md)), run the full headless
   regression gate with `make test`, and `make doc-examples` when the manual
   or the behaviour it documents changes.
4. Update the user manual (`docs/manual/`, then `make manual-v2` for the
   Word editions) and the technical documentation when behaviour changes.
5. Add or update a test case for language changes (the qualification corpus
   in `tools/qual`, see `docs/TESTING.md`).

Once per clone, `git config core.hooksPath tools/hooks` installs the pre-push check that the
simulator commit `tools/z80sim` is vendored from is already published (see
[`tools/z80sim/UPSTREAM.md`](tools/z80sim/UPSTREAM.md)).

Home ROM and EXROM capacity are hard architectural limits. Please include the
before/after output of `make budget` for changes that add ROM code.

Keep commits focused and do not commit generated assembler output, local ROM
images, emulator screenshots, tape captures, or copyrighted reference ROMs.

## Coding standard

Z80 / sjasmplus, symbolic constants only (`include/`), one module = one
concern, every public routine documented in its header comment and in the
Programmer's Reference, correctness before optimization. See
[`docs/v1/programmers_reference.md`](docs/v1/programmers_reference.md) for the
long version and [`docs/v1/development_log.md`](docs/v1/development_log.md) for
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

**When adding or editing a `tests/`/`demos/` BASIC program fixture**, run:
```
python3 tools/check_basic_source.py path/to/fixture.txt
```
Catches `DIM` bounds mistakes (a literal out-of-bounds access, or a
`FOR x = 1 TO n` loop paired with an array `DIM`'d to that same `n` — the
classic 0-vs-1-indexed off-by-one) and label-table budget overflow, from
source alone, no emulator needed. Deliberately does *not* duplicate anything
`rom/exrom_checker.asm`'s own real whole-program checker already validates
(single-letter names, the `PRINT` string;numeric pattern) — for those, the
actual pre-flight check is to run the real checker (type the program via
`ts2068-debug` and read its own verdict), not a second implementation.
Wired into `make check` against every existing fixture already.

By contributing, you agree that your contribution is licensed under the MIT
License used by this repository. Changes to the Fuse-derived material under
`patches/` are instead contributed under GPL-2.0-or-later, matching Fuse.

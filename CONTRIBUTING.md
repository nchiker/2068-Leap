# Contributing to 2068 Leap

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

By contributing, you agree that your contribution is licensed under the MIT
License used by this repository. Changes to the Fuse-derived material under
`patches/` are instead contributed under GPL-2.0-or-later, matching Fuse.

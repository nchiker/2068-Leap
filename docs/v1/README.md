# 2068-Leap V1 -- legacy / archived version

**V1 is superseded by V2.** 2068-Leap V2 (branch `v2-development`, the repository's default branch) is the current system and the only line under development; start from the [README](../../README.md). V1 is kept, unchanged, for reference: its source, documents, tags and downloads stay available, but it receives no further work.

V1 was the first 2068-Leap BASIC: the same unnumbered-line editor idea, but it read the program text again, statement by statement, every time it ran it, with mostly whole-number arithmetic. V2 is a new design (a whole-program compiler and a bytecode VM). V1 programs are plain text and often need small changes for V2 (`IF` blocks end with `ENDIF`, subroutines are `PROC`/`CALL`, `GOSUB` is gone, several statements moved into packages; see the manual's [What changed from V1](../manual/01_introduction.md#what-changed-from-v1-in-one-paragraph)), and V1 tapes are refused by V2 (`BAD TAPE VERSION`).

## Where V1 is

| What | Where |
|---|---|
| V1 source and documents, latest state (Release 1 Beta plus later fixes, last commit 2026-09-19) | branch [`main`](https://github.com/nchiker/2068-Leap/tree/main) |
| V1 README (the former project front page) | [`main:README.md`](https://github.com/nchiker/2068-Leap/blob/main/README.md) |
| **Release 1 Beta** (tag `v1.0.0-beta.1`, 2026-09-01) -- download `2068-Leap-Release-1-Beta.zip` | [release page](https://github.com/nchiker/2068-Leap/releases/tag/v1.0.0-beta.1) |
| **Private Preview 1** (tag `v0.1.0-preview.1`, 2026-08-27) | [release page](https://github.com/nchiker/2068-Leap/releases/tag/v0.1.0-preview.1) |
| the Preview 1 maintenance line (cold-start RAM fix, EightyOne cartridge; 2026-08-28) | branch [`release/v1`](https://github.com/nchiker/2068-Leap/tree/release/v1) |
| the historical Preview repository | [nchiker/2068-Leap-Preview](https://github.com/nchiker/2068-Leap-Preview) (not the V2 source) |

## V1 documents

These files are kept in this folder (`docs/v1/`) as history, together with the Release 1 Beta announcement, release notes and checksums that used to sit at the top of the repository; the copies on `main` are the V1 originals. They describe V1 only: its language and examples, its six extension tapes (`CPLOT`, `BLOCK`, `FRAME`, `INVERT`, `AYREG`, `OUT`; V2 has its own GRAPHICS package for the first four) and its release files do **not** apply to V2.

* [`user_manual.md`](user_manual.md) -- the V1 user manual ([Word edition](2068_Leap_Users_Manual.docx))
* [`whats_new_release_1_beta.md`](whats_new_release_1_beta.md) -- what Release 1 Beta changed from Preview 1
* [`technical_overview.md`](technical_overview.md), [`programmers_reference.md`](programmers_reference.md), [`loadable_basic_extensions.md`](loadable_basic_extensions.md), [`development_log.md`](development_log.md) -- V1 architecture, ROM API, extension contract and build history
* [`main:docs/emulator_setup.md`](https://github.com/nchiker/2068-Leap/blob/main/docs/emulator_setup.md) -- V1 emulator setup

The V1 demos and examples in `demos/` and `examples/` are V1 syntax too.

The rolling development download (`latest`) and every numbered release from `v2.0.0-emu.1` on are V2. A push to `main` still runs the V1 source checks but publishes nothing.

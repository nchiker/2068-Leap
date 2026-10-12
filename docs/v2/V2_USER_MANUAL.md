# 2068-Leap V2 -- User's Manual

The V2 user manual has moved to a full multi-part manual, written in the style of the Sinclair QL User Guide:

| Part | |
|---|---|
| [1. Introduction](manual/01_introduction.md) | what V2 is, how to start it, how to read the manual |
| [2. Beginner's guide](manual/02_beginners_guide.md) | the editor, a first program, numbers, words, decisions, loops, procedures, arrays, the screen, sound, tapes, sessions |
| [3. Keywords](manual/03_keywords.md) | every statement, function, operator and command, A to Z |
| [4. Concepts](manual/04_concepts.md) | numbers, strings, arrays, the Array Store, sessions, tapes, errors, memory, speed ... A to Z |
| [5. Packages](manual/05_packages.md) | mode, sprite, printer, shapes, graphics |
| [6. Practical examples](manual/06_examples.md) | complete programs |
| [Appendices](manual/07_appendices.md) | messages, error codes, character set, limits, memory map, package card, hardware notes, keyword index |

Also: the compact [language reference](V2_LANGUAGE_REFERENCE.md); a [Word edition](2068_Leap_V2_Users_Manual.docx) (`make manual-v2`); and what the documentation work found in [V2_DOCUMENTATION_FINDINGS.md](V2_DOCUMENTATION_FINDINGS.md).

Every example in the manual is run on the release ROM by `make doc-examples`, separately from the 1010-case release qualification baseline. The 239-line manual that was here before is in the git history (commit `170550e` and earlier); its content is covered by, and superseded by, the parts above. `docs/user_manual.md` is the manual of the earlier V1 "Release 1 Beta" and does not apply to V2.

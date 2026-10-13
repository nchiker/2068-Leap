# 2068-Leap V2 documentation

This folder is the documentation of **2068-Leap V2**, the current system. The archived V1 documents are in [`v1/`](v1/README.md).

## Start here

| | |
|---|---|
| **User manual** | [Markdown](manual/01_introduction.md) · [download .docx](https://github.com/nchiker/2068-Leap/raw/v2-development/docs/2068_Leap_V2_Users_Manual.docx) · [download .doc](https://github.com/nchiker/2068-Leap/raw/v2-development/docs/2068_Leap_V2_Users_Manual.doc) — [1 Introduction](manual/01_introduction.md) · [2 Beginner's guide](manual/02_beginners_guide.md) · [3 Keywords](manual/03_keywords.md) · [4 Concepts](manual/04_concepts.md) · [5 Packages](manual/05_packages.md) · [6 Examples](manual/06_examples.md) · [Appendices](manual/07_appendices.md) |
| **Language reference** | [V2_LANGUAGE_REFERENCE.md](V2_LANGUAGE_REFERENCE.md) |
| **Emulator setup** | [EMULATOR_SETUP.md](EMULATOR_SETUP.md) (ZEsarUX, EightyOne, Fuse, TSRun); EightyOne step by step: [eightyone_setup.md](eightyone_setup.md) |
| **Current release** | [V2_MAINT_RELEASE_STATUS.md](V2_MAINT_RELEASE_STATUS.md) (v2.0.1-emu.1) · first release: [V2_RC_STATUS.md](V2_RC_STATUS.md) (v2.0.0-emu.1) |
| **Known limitations** | [V2_DEFECT_REGISTER.md](V2_DEFECT_REGISTER.md) · hardware tests still to run: [V2_HARDWARE_CHECKLIST.md](V2_HARDWARE_CHECKLIST.md) |

The manual in this branch is the development edition; the manual exactly as released is inside the [release archive](https://github.com/nchiker/2068-Leap/releases/tag/v2.0.1-emu.1).

## Technical

- Design: [V2_ARCHITECTURE.md](V2_ARCHITECTURE.md), [V2_LANGUAGE_SPEC.md](V2_LANGUAGE_SPEC.md), [V2_FEATURE_MATRIX.md](V2_FEATURE_MATRIX.md), [V2_DEPENDENCY_MAP.md](V2_DEPENDENCY_MAP.md)
- Memory and ROM: [V2_ROM_RAM_BUDGET.md](V2_ROM_RAM_BUDGET.md), [RAM_EFFICIENCY_RESULTS.md](RAM_EFFICIENCY_RESULTS.md)
- Formats and interfaces: [PACKAGE_ABI.md](PACKAGE_ABI.md), [V2_SAVE_ALL_FORMAT.md](V2_SAVE_ALL_FORMAT.md), [V2_SESSION_VARIABLES.md](V2_SESSION_VARIABLES.md)
- From V1: [COMPATIBILITY_BREAKS.md](COMPATIBILITY_BREAKS.md), [V1_V2_COMPATIBILITY.md](V1_V2_COMPATIBILITY.md)
- Testing and tools: [TESTING.md](TESTING.md), [V2_QUALIFICATION_STUDY_INDEX.md](V2_QUALIFICATION_STUDY_INDEX.md), [V2_REGRESSION_REPORT.md](V2_REGRESSION_REPORT.md)
- Next steps: [V2_MAINTENANCE_BACKLOG.md](V2_MAINTENANCE_BACKLOG.md)

## Development history

The other files here are the working record of how V2 was designed, built and qualified, kept for reference: the planning studies (`ARCHITECTURE_*`, `REWRITE_*`, `IMPLEMENTATION_PLAN.md`), the R8 to R10 milestone reports and audits (`R8_*` … `R10_*`, `milestones/`), the qualification and maintenance studies (`V2_*_STUDY*.md`, `V2_OWNER_DECISIONS_REVIEW.md`, `maint/`, `maint_audio/`), and handoff notes. They describe the state at the time they were written; where they differ from the manual or the release records above, the manual and the release records are current.

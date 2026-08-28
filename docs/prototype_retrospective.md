# Prototype retrospective: designing the next 2068 Leap

2068 Leap proved that a much richer TS2068 environment can fit in the original
16K Home ROM plus 8K EXROM architecture. It also accumulated constraints in
the order prototypes usually do: features arrived before stable subsystem
boundaries, ROM placement was optimized late, and tests grew around bugs found
in integration. A second implementation should preserve the behavior and test
knowledge while changing the development order.

## What to do differently

1. **Define the memory and banking architecture first.** Reserve fixed Home
   entry points, an append-only EXROM ABI, explicit scratch-RAM ownership, and
   measured growth budgets before implementing BASIC features. Keep cold
   parsers, help text, validation, conversions, and allocators in EXROM from
   their first version rather than migrating them after Home fills.

2. **Use one parser representation.** The executor, static checker, editor
   highlighter, and help/reference tables currently encode overlapping parts
   of the language. Generate their keyword metadata and grammar tables from a
   single declarative source, with handwritten Z80 only for execution bodies.

3. **Make contracts machine-checkable.** Give every callable routine a formal
   register, flag, paging, stack, and scratch-memory contract. Add assembly-time
   assertions for fixed entries and a simulator test that checks preserved
   registers at every Home/EXROM boundary.

4. **Design the value and variable model before syntax.** Decide integer versus
   floating point, string ownership, array rank, record headers, lifetime, and
   error semantics together. A dimension-capable array header from day one
   would make multidimensional arrays incremental instead of a later rewrite.

5. **Build a deterministic headless test interface early.** Border-color
   screenshots are ingenious and useful for hardware-visible behavior, but a
   dedicated test ROM mailbox in RAM should report result codes, assertions,
   registers, and error identifiers directly. Keep screenshots for graphics
   and lifecycle tests, not as the only general result channel.

6. **Separate product behavior from test timing.** Synthetic interrupts should
   expose an explicit idle/settled handshake. Tests should never infer that an
   editor redraw is complete merely because the key queue is empty.

7. **Treat ROM size as a continuous integration invariant.** Establish per-
   subsystem budgets and fail builds before either image reaches zero margin.
   Keep a deliberate reserve for bug fixes—roughly 5–10% during development—
   instead of spending the final bytes on features.

8. **Plan compatibility and release criteria up front.** State which stock
   TS2068 syntax, tape formats, ports, and emulator behaviors are contractual.
   Define preview, beta, and hardware-release gates before the showcase phase.

## Recommended second-generation sequence

1. Freeze the current test corpus as the behavioral specification.
2. Define generated language metadata and the Home/EXROM ABI.
3. Implement memory, banking, errors, and the test mailbox.
4. Implement editor and parser foundations against those contracts.
5. Add core BASIC, arrays/strings, graphics, sound, and storage in measured
   vertical slices, keeping every slice bootable and fully tested.
6. Add showcase programs only after the public APIs and manuals stabilize.

The existing ROM should not be discarded: it is the executable specification
and a successful product prototype. The main lesson is to carry its discovered
contracts, fixtures, and hardware knowledge into a cleaner architecture rather
than merely translating the current source file by file.

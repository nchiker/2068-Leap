# DOCK cartridge build — open work, not yet started

Status: **investigated, not implemented.** No cartridge code exists in this
repository yet. This file exists so the finding below isn't lost — see
`NOTES_FROM_DESCENDANTS.md` item 5 for how this was first raised.

## Why this isn't a direct port of 2068-Leap-Forth's cartridge build

Sibling project `2068-Leap-Forth` (`2068-forth/` on disk) has a working
`-DCARTRIDGE` build (`rom/forth_boot.asm`'s `IFDEF CARTRIDGE` blocks,
`tools/make_dck.py`) — confirmed booting under both Fuse `--dock` and
stock ZEsarUX, with live keyboard input from a real person typing. The
technique looked directly portable here: replace this project's own
`RST_00: di : jp COLD_START` stub with a 5-byte in-ROM LROS header (TS2068
Technical Manual §5.1.1), and this project's Home ROM occupies chunks 0-1
just like 2068-Leap-Forth's, with EXROM at chunk 6 — no address-space
collision with the cartridge's own chunks 0-1.

That address-space argument is correct but incomplete. It misses a real
hardware hazard that 2068-Leap-Forth's own cartridge build never
encounters, because its base dictionary never touches EXROM at all (its
own `docs/lros_cartridge.md`: *"The graphics extension still can't reach
TS-Pico either way — it pages the EXROM bank, which TS-Pico has no way to
substitute"* — the graphics/EXROM path there is explicitly unfinished
follow-up work, not something the confirmed-working build exercises).

**This project's situation is different: its entire interactive
experience depends on EXROM.** `kernel/bank/bank.asm`'s
`BANK_PAGE_EXROM_IN` runs on every editor entry — and since the 2026-08-22
EXROM migration, that's essentially every boot (`EDITOR_INIT` runs on the
first `BASIC_COMMAND_LOOP` iteration).

## The actual hazard

Sourced from the vendored `ts2068-cartridge-development` skill's own
`memory-banking-faq.md` (based on the TS2068 Technical Reference Manual):

> DECR bit 7 makes all set HSR bits request EXROM instead of DOCK, so the
> two external sources are globally mutually exclusive.

> Do not call EXROM by flipping DECR while still executing in a selected
> DOCK chunk.

In a naive cartridge port, chunks 0-1 (this project's own code, now
DOCK-sourced) would need to stay marked "external" in HSR for the whole
session — otherwise the CPU falls back to whatever's in the real onboard
Home ROM socket. But `BANK_PAGE_EXROM_IN` executes `out (PORT_SCLD),a` to
flip DECR bit 7 from code that, in that scenario, is itself running from a
DOCK-selected chunk. The instant that instruction executes, chunks 0-1
also flip to EXROM-sourced content — the CPU loses its own running code
mid-instruction-stream. This is exactly the hazard class the skill's
"Why execution can fail immediately" and "What must not be done" sections
describe, not a theoretical edge case.

## What a correct fix would need

Per the skill's own documented safe pattern for DOCK-to-EXROM transitions
(`memory-banking-faq.md`, "Changing between DOCK and EXROM" /
"When is a HOME-RAM switching routine required?"): the EXROM-paging
gateway needs to run from a HOME-RAM trampoline unaffected by either
chunk 0-1 or chunk 6 toggling — this project's own RAM pool
(`$8426-$BFFF`, chunks 4-5) is never marked external by any existing code
and would work. Both `BANK_PAGE_EXROM_IN` and `BANK_PAGE_EXROM_OUT` would
need this treatment (entry AND exit), with careful DI-guarded sequencing:
set HSR=0 (all Home) from RAM, flip DECR bit 7, set HSR for only the
target chunk, jump — and the reverse on the way back into chunk 0-1
content. This is a real rework of a core, heavily-used subsystem
(`kernel/bank/bank.asm`, exercised on every editor entry), not a drop-in
port, and would need careful attention to interrupt timing during the
gateway window and to `BANK_EXROM_DEPTH`'s existing nesting-safety
contract.

## Verification path, once attempted

Not ZEsarUX first — item 1's own finding (stock ZEsarUX's incomplete
EXROM chunk mirroring) means ZEsarUX's EXROM model is already known to be
imperfect; the DOCK+EXROM mutual-exclusivity mechanic specifically hasn't
been checked against either emulator's accuracy here. Fuse models real
TS2068 chunk/HSR/DECR hardware behavior and is the tool 2068-Leap-Forth's
own cartridge build was actually confirmed against — start there
(`fuse --machine ts2068 --dock <built .dck>`), with live keyboard input
(not scripted injection — 2068-Leap-Forth's own experience: neither
ZEsarUX's `send-keys-ascii` nor raw X11 key events reliably reach a live
interactive session; a real person typing was what actually confirmed it
there).

## Open work

- HOME-RAM trampoline design and implementation for
  `BANK_PAGE_EXROM_IN`/`BANK_PAGE_EXROM_OUT`, both directions.
- Confirm what chunks 0-1 actually show when their HSR bits are cleared
  to 0 while a DOCK cartridge is physically present — untested here and
  not exercised by 2068-Leap-Forth's own cartridge build either, since it
  never clears those bits after the initial OS handoff.
- Fuse `--dock` verification with live keyboard input, not just a clean
  assemble.
- `tools/make_dck.py`-equivalent packaging once a build exists — the
  vendored cartridge-development skill's `inspect_dck.py`/`pack_dck.py`
  are available locally for this (not committed — see `.gitignore`).

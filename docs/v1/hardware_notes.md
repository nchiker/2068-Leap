# Hardware Notes

Status: DRAFT — grows as hardware facts get confirmed, one at a time.
Unlike the rest of docs/, entries here should be genuinely confirmed
(not guessed, not assumed-by-analogy) before being written down —
that's the whole point of this document existing separately from
inline TODOs.

## Keyboard

The TS2068 keyboard is laid out the same as the original Sinclair
Spectrum — **not** the Spectrum+/128's dedicated cursor keys, which an
earlier draft of this project wrongly assumed the TS2068 had. Confirmed
differences from a stock Spectrum:

- CAPS SHIFT is duplicated on both sides of the keyboard (same matrix
  position, just two physical keycaps wired to it — no extra matrix row
  or bit needed).
- An added BREAK key. **Not yet confirmed**: whether this is a genuine
  extra matrix position, or a keycap labelled "BREAK" over what's
  electrically still the standard CAPS SHIFT+SPACE break combo. Treat
  as open until checked — `kernel/io` does not yet implement BREAK
  detection either way.

Consequence: since the TS2068 uses the standard Spectrum layout,
cursor movement uses the standard Spectrum combo scheme —
`CAPS SHIFT` held together with `5`/`6`/`7`/`8`/`0`:

| Combo | Meaning |
|---|---|
| CAPS SHIFT + 5 | LEFT |
| CAPS SHIFT + 6 | DOWN |
| CAPS SHIFT + 7 | UP |
| CAPS SHIFT + 8 | RIGHT |
| CAPS SHIFT + 0 | DELETE |

This is implemented in `kernel/io/io.asm`'s `IO_READ_KEY`, returning
`KEY_CURSOR_LEFT`/`RIGHT`/`UP`/`DOWN`/`KEY_DELETE` (see
`include/keys.inc`) as single translated codes — the combo detection
happens inside `IO_READ_KEY` itself, so callers never see "CAPS SHIFT"
and "5" as two separate keypresses to combine themselves.

**CAPS SHIFT + 1** has a real Spectrum-family meaning too (EDIT), not
implemented here — this project deliberately repurposes that same
matrix combo as a project-specific one-keystroke "delete whole line"
command (`KEY_DELETE_LINE`), the same way CAPS SHIFT+ENTER and SYMBOL
SHIFT+A/S are repurposed elsewhere rather than replicating original
hardware behavior for them.

## SYMBOL SHIFT punctuation

Confirmed via web search before implementing (not guessed — this
project already got the *PC-key* mapping for SYMBOL SHIFT wrong once,
assuming Ctrl before the user's own testing against a stock Spectrum
ROM confirmed it; the *combo table* itself got the same scrutiny):

| Combo | Meaning | Combo | Meaning |
|---|---|---|---|
| SYMBOL SHIFT + 1 | `!` | SYMBOL SHIFT + 6 | `&` |
| SYMBOL SHIFT + 2 | `@` | SYMBOL SHIFT + 7 | `'` |
| SYMBOL SHIFT + 3 | `#` | SYMBOL SHIFT + 8 | `(` |
| SYMBOL SHIFT + 4 | `$` | SYMBOL SHIFT + 9 | `)` |
| SYMBOL SHIFT + 5 | `%` | SYMBOL SHIFT + 0 | `_` |
| SYMBOL SHIFT + Z | `:` | SYMBOL SHIFT + L | `=` |
| SYMBOL SHIFT + M | `.` | SYMBOL SHIFT + K | `+` |
| SYMBOL SHIFT + N | `,` | SYMBOL SHIFT + J | `-` |
| SYMBOL SHIFT + P | `"` | SYMBOL SHIFT + O | `;` |
| SYMBOL SHIFT + V | `/` | SYMBOL SHIFT + B | `*` |
| SYMBOL SHIFT + R | `<` | SYMBOL SHIFT + T | `>` |
| SYMBOL SHIFT + C | `?` |  |  |

**Deliberately not implemented, not merely unconfirmed**: real
Spectrum-family hardware's SYMBOL SHIFT table is more complex than a
flat symbol lookup. `A`-`G` give BASIC keyword tokens (`STOP`, `NOT`,
`STEP`, `TO`, `THEN`), not simple characters — not representable this
way at all. `Q`, `W`, `E` give compound TWO-CHARACTER tokens (`<=`,
`<>`, `>=` respectively — confirmed via the same source as the table
above) that this project's flat one-key-to-one-character table has no
way to represent; this BASIC's own parser reads those as two typed
characters in sequence anyway (`<` then `=`, etc.), so nothing is lost
by leaving these three unmapped rather than building multi-character
key output just for them. The stock-ROM table identifies the remaining
letter combinations as keyword tokens or characters this dialect does not
consume (`£` and `^`). They remain unmapped by design: inserting a one-byte
stock token into this editor's ASCII buffer would be incompatible with its
plain-text model. `C`=`?` is confirmed and mapped.

## Still open
- BREAK key's exact matrix position (or confirmation it's just the
  standard SHIFT+SPACE combo under a different keycap).
- Stock keyword-token and compound-token shortcuts remain deliberately
  outside this ROM's plain-text editor model; type the keyword or comparison
  characters normally.
- AY-3-8912 sound port pair — see `include/hardware.inc`'s `TODO` on
  `PORT_AY_REG`/`PORT_AY_DATA`.
- TS2068 Home/Exrom banking port behaviour — see `include/hardware.inc`'s
  `TODO` on `PORT_BANK_HOME`/`PORT_BANK_EXROM`.

## Loadable OUT command

The optional 39-byte `OUT port,value` module emits the Z80 `OUT (C),A`
instruction, so all 16 bits of the first argument appear on the address bus.
Only the data range (0-255) is restricted. This deliberately exposes hardware:

- low byte `$FE` reaches the ULA family decode and can change border/MIC/EAR;
- low byte `$F4` is reserved by this ROM for TS2068 Home/EXROM banking and can
  replace the currently visible memory bank;
- `$F5`/`$F6` are used for AY register/data access; and
- expansion hardware may decode addresses unknown to the base machine.

Tests use `$1234` as a benign unclaimed address and `$00FE` only to set a
visible green border. These tests prove instruction and argument behaviour,
not that arbitrary ports are safe.

# Editor Architecture

Status: reviewed and source ownership clarified on `develop/v2`, 2026-08-28.
The extraction was verified byte-for-byte against the preceding HOME image;
it changes source organization, not ROM layout or behavior.

## Ownership boundary

`rom/exrom_editor.asm` is the single canonical generic editing engine. It owns
the line buffer, character insertion/deletion, horizontal cursor movement,
keyboard dispatch, word wrapping, and wrapped cursor-coordinate conversion.
`kernel/editor/editor.asm` is only a compatibility adapter for standalone
HOME-based test ROMs; it includes the canonical implementation rather than
copying it.

`basic/editor_integration.asm` owns everything that requires knowledge of the
BASIC program model: loading/detokenizing a stored statement, navigating
statement positions, rendering the full program, scrolling, row-shadow
caching, syntax-error highlighting/navigation, the status line, and the thin
HOME-to-EXROM editor wrappers. Conditional emission keeps each group at its
historical address in `basic.asm`, preserving the binary exactly.

`kernel/memory/memory.asm` continues to own physical program storage and range
movement. `kernel/graphics` and `kernel/io` remain shared services rather than
editor code.

## State ownership

Generic editor state includes `EDIT_LINE_BUF`, `EDIT_BUF_OFFSET`, wrap tables
and scratch, `EDITOR_REDRAW_HOOK`, and `EDITOR_NAV_HOOK`. BASIC integration
state includes `CUR_EDIT_POS`, `CUR_EDIT_INDEX`, `VIEW_TOP_INDEX`, active/view
rows, row-shadow caches, pending edit/delete state, and checker error lists.
The variables share `include/sysvars.inc` because their fixed addresses are a
cross-bank ABI; physical declaration in one file does not imply behavioral
ownership by that file.

## Known boundary debts

- `EDITOR_BLOCK_DELETE` is a thin generic-editor name over a program-storage
  operation. Its eventual dangling-label validation requires BASIC parsing,
  so the complete operation belongs in BASIC integration. It remains in place
  for V2 compatibility until that behavior is implemented.
- The EXROM left/right cursor fast path reads `BASIC_ACTIVE_ROW` directly.
  This avoids a costly callback but is an abstraction leak. If the editor is
  reused outside BASIC, active-row state should become an explicit generic
  editor input.
- The fixed `$C072` wrap-table-address entry is retired but remains reserved
  to avoid renumbering the EXROM ABI.

These are architectural debts, not duplicated implementations. Moving the
HOME-resident BASIC integration wholesale into EXROM is not currently viable:
it is substantially larger than the available EXROM headroom and would also
move BASIC-specific policy into the wrong layer.

#!/usr/bin/env python3
"""
tools/type_basic.py — types a plain-text BASIC program into a running
Fuse window via synthetic X11 keystrokes (python-xlib's XTest
extension), presses RUN, and reports the result via border color —
this project's own established pass/fail signal (no serial/stdout on
real hardware).

WHY THIS EXISTS (2026-08-22): the established preload-harness method
(tools/preload_gen.py) bakes the encoded program directly into the 16K
Home ROM image as DB data — sharing the SAME tiny free-space margin as
the ROM's own code (currently ~245 bytes). That's fine for a handful
of statements but doesn't scale to a real regression suite covering
every keyword/function. Typing the program into the REAL interactive
editor instead stores it in RAM (PROG_AREA — thousands of bytes free),
completely sidestepping the ROM budget, and exercises the actual
editor + tokenizer path a real user's keystrokes would.

Requires: a real X server (DISPLAY set), Fuse already running against
rom/test_basic.bin + exrom.bin (NOT a preload harness — this script
drives the normal interactive boot), python-xlib.

Usage:
    python3 tools/type_basic.py <program.txt> [--window-id 0xNNNN]
                                 [--delay 0.05] [--shot out.png]

<program.txt>: one BASIC statement per line, plain text (same format
tools/preload_gen.py's input uses) — blank lines and ';;'-prefixed
comment lines are skipped. Each line is typed, then ENTER is sent.
After every line is typed, "run" + ENTER is sent to execute the
program. The convention every test program in this suite follows:
count failures in a variable, end with
    IF <fails>=0 THEN BORDER 4 : IF <fails>>0 THEN BORDER 2
(green=pass, red=fail) — this script does not itself judge pass/fail,
it just delivers the keystrokes and (optionally) saves a screenshot
so the caller can read the border color.

Known limitations:
  - No line-editing recovery: if a keystroke is dropped or mistimed,
    the typed program diverges from the source silently. --delay
    controls the per-keystroke pacing; raise it if runs seem flaky.
  - Only lowercase letters, digits, space, and the punctuation set
    this dialect's own grammar needs are mapped (see CHAR_KEYSYMS
    below) — extend that table if a test needs a character not yet
    covered, rather than guessing at a workaround in the caller.
  - Keywords are typed lowercase (case-insensitive parsing, matching
    tools/preload_gen.py's own documented behavior) — this script
    never sends Shift for letters, only for punctuation that needs it.
"""
import sys
import time
import argparse

from Xlib import display, X
from Xlib.ext import xtest
import Xlib.XK

# character -> X11 keysym NAME (not the bare character -- string_to_
# keysym only resolves letters/digits directly by codepoint, not
# punctuation; see this file's own header for why each of these was
# verified against the real virtual display before trusting it)
CHAR_KEYSYM_NAMES = {
    ' ': 'space', '+': 'plus', '-': 'minus', '*': 'asterisk',
    '/': 'slash', '=': 'equal', '<': 'less', '>': 'greater',
    '(': 'parenleft', ')': 'parenright', '$': 'dollar',
    '"': 'quotedbl', ',': 'comma', ':': 'colon', '.': 'period',
    '!': 'exclam', ';': 'semicolon',
}


class Typer:
    def __init__(self, dpy, delay=0.05):
        self.d = dpy
        self.delay = delay
        self._keycode_cache = {}

    def _resolve(self, keysym):
        """Returns (keycode, needs_shift) for a keysym, cached."""
        if keysym in self._keycode_cache:
            return self._keycode_cache[keysym]
        pairs = list(self.d.keysym_to_keycodes(keysym))
        if not pairs:
            raise ValueError(f"no keycode for keysym {hex(keysym)}")
        keycode, index = pairs[0]
        needs_shift = (index % 2) == 1
        self._keycode_cache[keysym] = (keycode, needs_shift)
        return keycode, needs_shift

    def send_keysym(self, keysym):
        keycode, needs_shift = self._resolve(keysym)
        if needs_shift:
            shift_code = self.d.keysym_to_keycode(Xlib.XK.string_to_keysym('Shift_L'))
            xtest.fake_input(self.d, X.KeyPress, shift_code)
            time.sleep(self.delay)
        xtest.fake_input(self.d, X.KeyPress, keycode)
        time.sleep(self.delay)
        xtest.fake_input(self.d, X.KeyRelease, keycode)
        time.sleep(self.delay)
        if needs_shift:
            xtest.fake_input(self.d, X.KeyRelease, shift_code)
            time.sleep(self.delay)
        self.d.flush()

    def send_char(self, ch):
        if ch.isalpha() or ch.isdigit():
            keysym = Xlib.XK.string_to_keysym(ch.lower())
        elif ch in CHAR_KEYSYM_NAMES:
            keysym = Xlib.XK.string_to_keysym(CHAR_KEYSYM_NAMES[ch])
        else:
            raise ValueError(
                f"no keysym mapping for {ch!r} -- add it to "
                f"CHAR_KEYSYM_NAMES in tools/type_basic.py")
        self.send_keysym(keysym)

    def send_text(self, text):
        for ch in text:
            self.send_char(ch)

    def send_enter(self):
        self.send_keysym(Xlib.XK.string_to_keysym('Return'))

    def send_line(self, text):
        self.send_text(text)
        self.send_enter()


def find_fuse_window(d):
    root = d.screen().root
    tree = root.query_tree()
    for w in tree.children:
        try:
            name = w.get_wm_name()
        except Exception:
            name = None
        if name and 'Fuse' in name:
            return w
    raise RuntimeError("no Fuse window found -- is it running?")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('program')
    ap.add_argument('--window-id', type=lambda s: int(s, 0), default=None)
    ap.add_argument('--delay', type=float, default=0.05)
    ap.add_argument('--shot', default=None,
                     help="save a PNG screenshot after RUN")
    ap.add_argument('--run-wait', type=float, default=1.0,
                     help="seconds to wait after RUN before the shot")
    args = ap.parse_args()

    with open(args.program) as f:
        lines = [l.rstrip('\n') for l in f]
    lines = [l for l in lines if l.strip() and not l.strip().startswith(';;')]

    d = display.Display()
    if args.window_id is not None:
        win = d.create_resource_object('window', args.window_id)
    else:
        win = find_fuse_window(d)
        print(f"found Fuse window: {hex(win.id)}")

    win.set_input_focus(X.RevertToParent, X.CurrentTime)
    d.sync()
    time.sleep(0.3)

    typer = Typer(d, delay=args.delay)

    for line in lines:
        typer.send_line(line)

    typer.send_line('run')

    time.sleep(args.run_wait)

    if args.shot:
        geom = win.get_geometry()
        raw = win.get_image(0, 0, geom.width, geom.height, X.ZPixmap, 0xffffffff)
        from PIL import Image
        img = Image.frombytes('RGBX', (geom.width, geom.height), raw.data,
                               'raw', 'BGRX')
        img.convert('RGB').save(args.shot)
        print(f"screenshot saved to {args.shot}")

    print(f"typed {len(lines)} line(s) + RUN")


if __name__ == '__main__':
    main()

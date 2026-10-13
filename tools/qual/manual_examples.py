"""Documentation-example suite for the V2 user manual (separate from the release baseline).

The examples ARE the manual: every fenced block in docs/manual/*.md that carries an `ex=<id>`
attribute is a test case.  Nothing here touches tools/qual/corpus.py (the 667-case language corpus),
`make test` (1010 cases) or `make qual`; this suite has its own runner (manual_run.py), make target
(`make doc-examples`) and results directory (build/doc-examples/).

Block syntax (info string = language, then attributes):

    ```basic ex=print.1 [pkg=shapes,sprite] [keys=...] [err=ce:N|ve:N] [maxi=N] [shot=name]
    PRINT "A"; 1
    ```
    ```output ex=print.1
    A1
    ```

* `basic` block  : the program (one stored line per source line).  It is run with RUN semantics on
  the release image; `pkg=` installs those packages first (as a LOAD ... EXT would).
* `output` block : the exact screen text (rows joined by newlines, trailing blank rows dropped).
  Without an `output` block the program must finish without an error and its output is not checked.
* `err=ce:N` / `err=ve:N` : the program must stop with that compile / runtime error code (the codes
  are internal; the user sees the message) -- the output block, if any, is what was printed first.
* `keys=` : keys delivered, in order, to INPUT / key waits.  Python-style escapes: `\\n` is ENTER.
* `code=N` / `source=N` : after the run the compiled program is exactly N bytes (the bytecode area,
  VM_CODE_BASE .. end of code) / the stored program text is N bytes (3 + length per line).
* `break=N` : the run is stopped with BREAK (CAPS SHIFT + SPACE, pressed in the emulated keyboard
  matrix) after N instructions; use `err=ve:66` -- BREAK is run-time error 66.
* `rows=N` : compare only the first N text rows of the screen (examples that draw: the pixels
  drawn lower on the screen are not text); the output block then lists just those rows.
* `shot=name` : the final screen is rendered to images/name.png and must equal the committed file.
* `session` block (directly after a `basic` block with the same ex): what is typed on the editor's
  empty last line and what is seen.  A line starting with `:` or equal to `RUN`, `NEW` or `EDIT`
  (an edit of the program) is a command; the lines after it, up to the next command, are the
  exact screen text it must produce (a command with none must print nothing).
  `[ce:N]` / `[ve:N]` after a command's text expects that error instead of output.
* `keys` block (instead of `basic`): the editor from power-on.  Each line is typed and followed by
  ENTER (a line ending in a backslash is typed without ENTER); `{NAME}` inserts a special key:
  `{ENTER} {LEFT} {RIGHT} {UP} {DOWN} {DEL} {DELLINE} {INSLINE} {BREAK} {ANY}` (ANY is the space bar).
  The following `screen` block (same ex=) is the exact 24-row screen afterwards (rows right-trimmed,
  trailing blank rows dropped; bold keywords appear as ordinary letters); a line `...` stands for
  any number of blank rows.  `shot=name` works too.
  The programs are typed through the real keyboard path (editor, RUN, compile, VM).
* `tape` block (directly after a `basic` block with the same ex): like `session`, plus tape commands.
  `SAVE "n" ...` is captured at the tape transport (what the cassette would record) and shows the
  message in `[ ]` (e.g. `[SAVED]`).  `power on` (or `---`) switches the machine off and on again with
  everything saved so far playing as the EAR signal; the next step must be a `LOAD`/`VERIFY`, which
  runs the real tape receiver on it.  `store: line ;; line` puts lines into the program store (for
  VERIFY); `package NAME` adds that package's tape to the cassette.  Expected messages: `[LOADED]`.
* `errors` block (stand-alone, no `basic` block): one case per line, `ce N | program` or `ve N | program`
  (optionally `ce N pkg=shapes | ...`): the program (lines separated by ` ;; `) must stop with that
  compile / run-time error code.  A line `@repeat COUNT template` stands for COUNT lines, `{i}` being
  0, 1, 2, ...  Case ids are `<ex>.ce<N>` / `<ex>.ve<N>`.
* in `session` / `tape` output, a last line `...` means "then whatever drawing is on the screen" (only the
  lines before it are compared).
* `table`-style blocks and plain code blocks without `ex=` are not tests.

`CASES` is the list of parsed cases.  Cases that need the tape or the keyboard-driven editor live in
manual_interactive.py and are registered into the same suite under the same id scheme.
"""
import glob
import os
import re
import shlex

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
MANUAL_DIR = os.path.join(ROOT, "docs", "manual")
IMAGE_DIR = os.path.join(MANUAL_DIR, "images")

SPECIAL_KEYS = {"ENTER": 0x0D, "LEFT": 0x01, "DOWN": 0x02, "UP": 0x03, "RIGHT": 0x04, "DEL": 0x08,
                "INSLINE": 0x0B, "DELLINE": 0x0F, "BREAK": 0x10, "ANY": 0x20}
FENCE = re.compile(r"^```(\w+)\s*(.*)$")
COMMAND_WORDS = ("RUN", "NEW", "EDIT")


class Case:
    def __init__(self, cid, path, lineno):
        self.cid, self.path, self.lineno = cid, path, lineno
        self.kind = "run"             # run | session
        self.lines = []
        self.out = None               # expected exact screen text, or None = not checked
        self.err = None               # ("ce"|"ve", code) or None
        self.pkgs = ()
        self.keys = []
        self.maxi = 60_000_000
        self.shot = None
        self.code = None              # expected bytecode bytes after the run (memory examples)
        self.source = None            # expected source bytes (program text, 3 + length per line)
        self.brk = None               # press BREAK after this many instructions of the run
        self.rows = None              # compare only the first N screen rows (graphics examples)
        self.steps = []               # session: [(command, expected text | ("ce"|"ve", n))]
        self.noscreen = False

    def where(self):
        return "%s:%d" % (os.path.relpath(self.path, ROOT), self.lineno)


def _attrs(s):
    out = {}
    for tok in shlex.split(s):
        k, _, v = tok.partition("=")
        out[k] = v
    return out


def _keys(text):
    codes = []
    text = text.encode().decode("unicode_escape")
    for ch in text:
        codes.append(0x0D if ch == "\n" else ord(ch))
    return codes


def _keycodes(lines):
    codes = []
    for ln in lines:
        enter = True
        if ln.endswith("\\"):
            ln, enter = ln[:-1], False
        i = 0
        while i < len(ln):
            if ln[i] == "{":
                j = ln.index("}", i)
                codes.append(SPECIAL_KEYS[ln[i + 1:j]])
                i = j + 1
            else:
                codes.append(ord(ln[i]))
                i += 1
        if enter:
            codes.append(0x0D)
    return codes


TAPE_WORDS = ("SAVE ", "LOAD ", "VERIFY ", "package ", "store:")


def _is_command(line, tape=False):
    if line.startswith(":") or line in COMMAND_WORDS:
        return True
    return tape and (line.startswith(TAPE_WORDS) or line in ("power on", "---"))


def _parse_session(body, tape=False):
    """-> [(command, expectation)]; expectation = exact output text, ("ce"|"ve", n) or ("msg", TEXT)."""
    steps, cur, out = [], None, []

    def flush():
        if cur is not None:
            steps.append((cur[0], cur[1] if cur[1] is not None else "\n".join(out)))
    for ln in body:
        if _is_command(ln.split("  [")[0].rstrip(), tape):
            flush()
            out = []
            m = re.match(r"^(.*?)\s+\[(ce|ve):(\d+)\]\s*$", ln)
            mm = re.match(r"^(.*?)\s+\[([A-Z][A-Z ]+)\]\s*$", ln) if tape and not m else None
            if m:
                cur = (m.group(1), (m.group(2), int(m.group(3))))
            elif mm:
                cur = (mm.group(1), ("msg", mm.group(2)))
            else:
                cur = (ln, None)
        else:
            out.append(ln)
    flush()
    return steps


def parse_file(path):
    cases = []
    with open(path, encoding="utf-8") as f:
        text = f.read().split("\n")
    i, last = 0, None
    while i < len(text):
        m = FENCE.match(text[i])
        if not m:
            i += 1
            continue
        lang, rest = m.group(1), m.group(2)
        start = i + 1
        j = start
        while j < len(text) and not text[j].startswith("```"):
            j += 1
        body = text[start:j]
        i = j + 1
        a = _attrs(rest)
        if "ex" not in a:
            continue
        cid = a["ex"]
        if lang == "basic":
            c = Case(cid, path, start)
            c.lines = list(body)
            c.pkgs = tuple(x for x in a.get("pkg", "").split(",") if x)
            if "keys" in a:
                c.keys = _keys(a["keys"])
            if "err" in a:
                k, _, n = a["err"].partition(":")
                c.err = (k, int(n))
            if "maxi" in a:
                c.maxi = int(a["maxi"])
            c.shot = a.get("shot")
            if "code" in a:
                c.code = int(a["code"])
            if "source" in a:
                c.source = int(a["source"])
            if "break" in a:
                c.brk = int(a["break"])
            if "rows" in a:
                c.rows = int(a["rows"])
            cases.append(c)
            last = c
        elif lang == "errors":
            seen_codes = {}
            for ln in body:
                if not ln.strip():
                    continue
                head, _, prog = ln.partition("|")
                toks = head.split()
                kind, code = toks[0], int(toks[1])
                n = seen_codes.get((kind, code), 0)
                seen_codes[(kind, code)] = n + 1
                c = Case("%s.%s%d%s" % (cid, kind, code, "" if n == 0 else "." + chr(ord("a") + n)), path, start)
                lines = []
                for part in prog.strip().split(" ;; "):
                    mm = re.match(r"@repeat (\d+) (.*)$", part)
                    if mm:
                        lines += [mm.group(2).replace("{i}", str(i)) for i in range(int(mm.group(1)))]
                    else:
                        lines.append(part)
                c.lines = lines
                c.err = (kind, code)
                for t in toks[2:]:
                    if t.startswith("pkg="):
                        c.pkgs = tuple(t[4:].split(","))
                cases.append(c)
        elif lang == "keys":
            c = Case(cid, path, start)
            c.kind = "keys"
            c.lines = list(body)
            c.keycodes = _keycodes(body)
            c.shot = a.get("shot")
            c.maxi = int(a.get("maxi", 300_000_000))
            cases.append(c)
            last = c
        elif lang == "screen":
            if last is None or last.cid != cid or last.kind != "keys":
                raise SystemExit("%s:%d: screen block ex=%s has no preceding keys block" % (path, start, cid))
            last.out = "\n".join(body)
        elif lang in ("output", "session", "tape"):
            if last is None or last.cid != cid:
                raise SystemExit("%s:%d: %s block ex=%s has no preceding basic block" % (path, start, lang, cid))
            if lang == "output":
                last.out = "\n".join(body)
            else:
                last.kind = lang
                last.steps = _parse_session(body, tape=(lang == "tape"))
        else:
            raise SystemExit("%s:%d: unknown example block type %r" % (path, start, lang))
    return cases


def load_cases():
    cases = []
    for p in sorted(glob.glob(os.path.join(MANUAL_DIR, "*.md"))):
        cases.extend(parse_file(p))
    seen = {}
    for c in cases:
        if c.cid in seen:
            raise SystemExit("duplicate example id %s (%s and %s)" % (c.cid, seen[c.cid].where(), c.where()))
        seen[c.cid] = c
    return cases


CASES = load_cases() if os.path.isdir(MANUAL_DIR) else []

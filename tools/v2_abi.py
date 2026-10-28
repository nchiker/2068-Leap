"""Reader for include/v2_package_abi.inc (the package-ABI single source of truth).

Used by tools/check_package_abi.py (make check), tools/make_extension_tzx.py and the
production-ROM tests, so no tool keeps its own copy of a version word, a service slot
number or a pinned address.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ABI_INC = ROOT / "include" / "v2_package_abi.inc"


# Signature constants (include/v2_ext_kinds.inc) a 2.0 ROM does not understand: a package that
# registers a function or the float form needs the minor they came in.
MINOR_CONSTS = {"EXT_KIND_FN": 1, "EXT_KIND_STR": 1, "EXT_SIG_FLOAT": 1}


def _num(expr, env):
    e = re.sub(r"\$([0-9A-Fa-f]+)", r"0x\1", expr.split(";")[0].strip())
    return int(eval(e, {"__builtins__": {}}, dict(env)))


class Abi:
    def __init__(self, path=ABI_INC):
        text = Path(path).read_text()
        env, self.services, self.consts, self.pins = {}, [], [], []
        in_macro = None
        self.svc_minor, self.pin_minor = [], {}         # the minor each slot / pin first appeared in
        for raw in text.splitlines():
            line = raw.split(";")[0].rstrip()
            since = re.search(r";.*\bABI \d+\.(\d+)", raw)
            since = int(since.group(1)) if since else 0
            m = re.match(r"\s*MACRO\s+(\w+)", line)
            if m:
                in_macro = m.group(1)
                continue
            if re.match(r"\s*ENDM\b", line):
                in_macro = None
                continue
            m = re.match(r"\s*(\w+)\s+(?:EQU|DEFL)\s+(.+)$", line)
            if m and in_macro is None:
                try:
                    env[m.group(1)] = _num(m.group(2), env)
                except Exception:
                    pass
                continue
            if in_macro in ("PKG_SVC_LIST",):
                m = re.match(r"\s*PKG_SVC\s+(\w+)\s*,\s*(\w+)", line)
                if m:
                    self.services.append((m.group(1), m.group(2)))
                    self.svc_minor.append(since)
            elif in_macro == "PKG_CONST_LIST":
                m = re.match(r"\s*PKG_CONST\s+(\w+)\s*,\s*(.+)$", line)
                if m:
                    self.consts.append((m.group(1), _num(m.group(2), env)))
            elif in_macro == "PKG_PIN_LIST":
                m = re.match(r"\s*PKG_PIN\s+(\w+)\s*,\s*([^,]+),\s*([^,]+)$", line)
                if m:
                    self.pins.append((m.group(1), _num(m.group(2), env), _num(m.group(3), env)))
                    self.pin_minor[m.group(1)] = since
        self.env = env
        g = env.__getitem__
        self.major, self.minor, self.pkg_word = g("PKG_ABI_MAJOR"), g("PKG_ABI_MINOR"), g("PKG_ABI_WORD")
        self.fmt_major, self.fmt_minor, self.fmt_word = g("V2_FORMAT_MAJOR"), g("V2_FORMAT_MINOR"), g("V2_FORMAT_WORD")
        self.header, self.entries = g("PKG_SVC_HEADER"), g("PKG_SVC_ENTRIES")
        self.magic, self.count = g("PKG_SVC_MAGIC"), g("PKG_SVC_COUNT")
        self.code, self.max_end = g("PKG_SVC_CODE"), g("PKG_SVC_MAX_END")
        self.scratch = (g("PKG_SCRATCH_BASE"), g("PKG_SCRATCH_END"))

    def slot_addr(self, index):
        return self.entries + 3 * index

    def needed_minor(self, source):
        """The ABI minor a package needs (the tape-stamp item), from its source and the rom/ files
        it includes: the highest minor of a service, pinned cell or signature constant it names in
        code (comments and strings ignored). A statement-only package that uses only 2.0's names
        needs 0 and so loads on a 2.0 ROM too."""
        since = {n: mn for (n, _), mn in zip(self.services, self.svc_minor)}
        since.update(self.pin_minor)
        since.update(MINOR_CONSTS)
        need, todo, seen = 0, [Path(source)], set()
        while todo:
            f = todo.pop()
            if f in seen:
                continue
            seen.add(f)
            for line in (ROOT / f if not f.is_absolute() else f).read_text(encoding="latin-1").splitlines():
                code = re.sub(r'"[^"]*"', '""', line.split(";")[0])
                m = re.match(r'\s*INCLUDE\s+""', code) and re.search(r'INCLUDE\s+"(rom/[^"]+)"', line)
                if m:
                    todo.append(Path(m.group(1)))
                    continue
                for word in re.findall(r"[A-Za-z_]\w*", code):
                    need = max(need, since.get(word, 0))
        return need

    def package_word(self, source):
        """The version word a package's tape carries: this major, the minor the package needs."""
        return self.pkg_word & ~0xFF | self.needed_minor(source)

    def service_addr(self, pkgname):
        for i, (n, _) in enumerate(self.services):
            if n == pkgname:
                return self.slot_addr(i)
        raise KeyError(pkgname)


def load():
    return Abi()


if __name__ == "__main__":
    a = load()
    print("PKG ABI %d.%d word=%04X; program/array format %d.%d word=%04X"
          % (a.major, a.minor, a.pkg_word, a.fmt_major, a.fmt_minor, a.fmt_word))
    for i, (p, h) in enumerate(a.services):
        print("slot %2d @%04X  %s -> %s" % (i, a.slot_addr(i), p, h))
    print(len(a.consts), "constants,", len(a.pins), "pinned cells")

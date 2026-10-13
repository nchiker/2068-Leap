#!/usr/bin/env python3
"""Static checks of the V2 user manual (docs/manual/*.md); run by `make doc-examples` first.

It needs no emulator.  What it checks, and why:

1. Keyword coverage -- every word of the compiler's KEYWORD_TABLE, every row of BUILTIN_FN_TABLE, every
   package statement (the `DB "NAME",0` of each ext_*_module / EXT2_REGISTER call) and every command the
   shell dispatches has a `## NAME` entry in 03_keywords.md, and every entry there names something that
   exists.  The manual is derived from the ROM source, not the other way round.
2. Links -- every relative link in the manual (file and #anchor, GitHub's anchor rules) resolves.
3. Figures -- every image a page uses exists, and no image in images/ is unused.
4. Examples -- ids are unique (the parser enforces it), each has a block that can run; no leftover
   placeholder or draft text.

Exit status 1 if anything is flagged.
"""
import glob
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
MANUAL = os.path.join(ROOT, "docs", "manual")
issues = []


def slug(heading):
    t = re.sub(r"[`*_]", "", heading).strip().lower()
    t = re.sub(r"[^\w\s-]", "", t)
    return re.sub(r"\s", "-", t)


def source_keywords():
    kw = set()
    comp = open(os.path.join(ROOT, "rom", "exrom_v2_compiler.asm"), encoding="latin-1").read()
    a = comp.index("\nKEYWORD_TABLE:")
    block = comp[a:comp.index("\n\n", a + 20)] if "\n\n" in comp[a + 20:a + 4000] else comp[a:a + 4000]
    for m in re.finditer(r'db\s+\d+,\s*"([A-Z$]+)",\s*TOK_KW_', block):
        kw.add(m.group(1))
    b = comp.index("\nBUILTIN_FN_TABLE:")
    for m in re.finditer(r'^\s+db\s+\d+,\s*"([A-Z]+)",\s*\d+,\s*\d+,\s*(\$?[0-9A-Fa-f]+)', comp[b:b + 6000], re.M):
        name, argtype = m.group(1), m.group(2)
        is_str = argtype.startswith("$8")
        kw.add(name + ("$" if is_str else ""))
    for f in glob.glob(os.path.join(ROOT, "rom", "ext_*module.asm")):
        for m in re.finditer(r'^\w*_NAME:\s+[Dd][Bb]\s+"([A-Z$]+)"', open(f, encoding="latin-1").read(), re.M):
            kw.add(m.group(1))
    sh = open(os.path.join(ROOT, "rom", "exrom_v2_shell.asm"), encoding="latin-1").read()
    for m in re.finditer(r'^V2_KW_(\w+):\s+DB\s+"([A-Z]+)"', sh, re.M):
        kw.add(m.group(2))
    kw.add("DIMN")                   # compiled by its own text check, not through BUILTIN_FN_TABLE
    kw.discard("LPRINT$")            # the internal string-argument form of LPRINT
    # words the tables spell in pieces
    kw -= {"DEF", "FN", "EXIT", "FOR"}
    kw |= {"DEF FN", "EXIT FOR", "FN", "FOR"}
    return kw


def manual_entries():
    ents = {}
    for ln in open(os.path.join(MANUAL, "03_keywords.md"), encoding="utf-8"):
        m = re.match(r"^## ([A-Z$ ]+?)(?:\s+\[package: (\w+)\])?\s*$", ln.rstrip("\n"))
        if m:
            ents[m.group(1).strip()] = m.group(2)
    return ents


def check_keywords():
    src, ents = source_keywords(), manual_entries()
    for k in sorted(src - set(ents)):
        issues.append("keyword in the ROM source has no entry in 03_keywords.md: %s" % k)
    # EXT/ARRAY/ALL are the words of the tape commands; TO/THEN/STEP/etc. come from the table
    for k in sorted(set(ents) - src):
        issues.append("03_keywords.md has an entry that is not in the ROM source tables: %s" % k)
    names = list(ents)
    if names != sorted(names, key=lambda x: x.replace("$", "~")) and names != sorted(names):
        issues.append("03_keywords.md entries are not in alphabetical order")


def check_links():
    files = sorted(glob.glob(os.path.join(MANUAL, "*.md")))
    heads = {}
    for f in files:
        hs = set()
        in_code = False
        for ln in open(f, encoding="utf-8"):
            if ln.startswith("```"):
                in_code = not in_code
            if not in_code:
                m = re.match(r"^#{1,6}\s+(.+?)\s*$", ln)
                if m:
                    hs.add(slug(m.group(1)))
        heads[os.path.basename(f)] = hs
    used_images = set()
    for f in files:
        base = os.path.basename(f)
        text = open(f, encoding="utf-8").read()
        text_nocode = re.sub(r"```.*?```", "", text, flags=re.S)
        for m in re.finditer(r"!\[[^\]]*\]\(([^)]+)\)", text_nocode):
            used_images.add(m.group(1))
            if not os.path.exists(os.path.join(MANUAL, m.group(1))):
                issues.append("%s: missing image %s" % (base, m.group(1)))
        for m in re.finditer(r"(?<!!)\[[^\]]+\]\(([^)\s]+)\)", text_nocode):
            target = m.group(1)
            if target.startswith("http"):
                continue
            path, _, anchor = target.partition("#")
            if path:
                tgt = os.path.normpath(os.path.join(MANUAL, path))
                if not os.path.exists(tgt):
                    issues.append("%s: link to a missing file %s" % (base, target))
                    continue
                key = os.path.basename(tgt)
            else:
                key = base
            if anchor and key in heads and anchor not in heads[key]:
                issues.append("%s: link %s: no heading with that anchor in %s" % (base, target, key))
    for img in glob.glob(os.path.join(MANUAL, "images", "*.png")):
        if "images/" + os.path.basename(img) not in used_images:
            issues.append("image not used by any page: %s" % os.path.basename(img))


def check_text():
    for f in sorted(glob.glob(os.path.join(MANUAL, "*.md"))):
        t = open(f, encoding="utf-8").read()
        for bad in ("PLACEHOLDER", "TODO", "FIXME", "XXX", "Hmm", "(draft)"):
            if bad in t:
                issues.append("%s: leftover text %r" % (os.path.basename(f), bad))


def check_examples():
    sys.path.insert(0, os.path.join(ROOT, "tools", "qual"))
    import manual_examples as M
    n = len(M.CASES)
    if n < 100:
        issues.append("only %d examples were parsed" % n)
    for c in M.CASES:
        if c.kind == "run" and not c.lines:
            issues.append("%s: empty program" % c.cid)
    return n


def main():
    check_keywords()
    check_links()
    check_text()
    n = check_examples()
    for i in issues:
        print("check_manual: " + i)
    if issues:
        return 1
    print("check_manual.py: all checks passed (%d examples parsed)." % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Collect the 2068-Leap V2 release artifacts into build/release-v2-rc/ (make rc-assets; the
directory keeps its release-candidate name so existing references stay valid).

ROM images, package binaries and tapes, the V2 documents and the user manual (Markdown and Word),
SHA256SUMS, BUILD_INFO.txt (release name and version, commit, budget, and the CRC-16 of the
HOME+EXROM pair that SAVE ... ALL stamps on its tapes) and README.txt; then the distribution archive
build/2068-Leap-V2-<version>.zip (everything under one top folder of that name) and its .sha256.
The CI workflow publishes that archive for a release tag (.github/workflows/check.yml); it sets
RELEASE_VERSION to the tag (or a dev string), which overrides VERSION below.

RELEASE / VERSION name what this tree builds. A numbered release is a v* tag (its own copy of this
script labels it; v2.0.0-emu.1, v2.0.1-emu.1 and v2.0.2-emu.1 were built that way). Anything else -- the rolling
"latest" build of v2-development, a workflow artifact, a local `make rc-assets` off a tag -- is an
UNQUALIFIED DEVELOPMENT BUILD and is labelled so in its name, BUILD_INFO.txt and README.txt.

The bundle also carries the Word 97 (.doc) edition of the manual when it is committed
(docs/2068_Leap_V2_Users_Manual.doc, `make manual-v2`), the emulator guide, the emulator patches
and the EightyOne cartridge image (roms/leap_v2_exrom.dck)."""
import hashlib
import os
import re
import shutil
import zipfile
import subprocess
import sys

OUT = "build/release-v2-rc"
PACKAGES = ("mode", "sprite", "printer", "shapes", "graphics", "cbeep")
LATEST_QUALIFIED = "v2.0.2-emu.1"
# numbered releases: designation and release record (docs/)
RELEASES = {
    "v2.0.1-emu.1": ("Sound Maintenance Release", "V2_MAINT_RELEASE_STATUS.md"),
    "v2.0.2-emu.1": ("Compiler Maintenance Release", "V2_COMPILER_MAINT_RELEASE_STATUS.md"),
}
RELEASE_TAG = re.compile(r"v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?")   # what the CI publishes as a numbered release


def crc16(data, c=0xFFFF):
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout.strip()


def version():
    v = os.environ.get("RELEASE_VERSION")
    if v:
        return v
    tag = sh("git", "describe", "--tags", "--exact-match", "--match", "v*", "HEAD")
    if tag and RELEASE_TAG.fullmatch(tag) and not sh("git", "status", "--porcelain", "--untracked-files=no"):
        return tag
    return "dev-%s-%s" % (sh("git", "log", "-1", "--format=%cd", "--date=format:%Y%m%d"), sh("git", "rev-parse", "--short", "HEAD"))


VERSION = None
RELEASE = None
STATUS = None


def main():
    global VERSION, RELEASE, STATUS
    VERSION = version()
    if RELEASE_TAG.fullmatch(VERSION):
        if VERSION in RELEASES:
            name, record = RELEASES[VERSION]
            RELEASE = "2068-Leap V2 Enhanced %s — %s (emulator-qualified, not hardware-qualified)" % (VERSION, name)
            STATUS = "emulator-qualified, NOT hardware-qualified (docs/%s)" % record
        else:
            RELEASE = "2068-Leap V2 Enhanced %s (numbered release; see its release record for the qualification status)" % VERSION
            STATUS = "numbered release; see its release record in docs/ for the qualification status"
    else:
        RELEASE = ("2068-Leap V2 development build %s — UNQUALIFIED (not a release; the latest qualified release is %s)"
                   % (VERSION, LATEST_QUALIFIED))
        STATUS = ("UNQUALIFIED DEVELOPMENT BUILD of %s -- not a release, not emulator- or hardware-qualified; "
                  "for the qualified ROMs use release %s" % (sh("git", "rev-parse", "--abbrev-ref", "HEAD"), LATEST_QUALIFIED))
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    for d in ("roms", "packages", "docs", "docs/manual", "patches"):
        os.makedirs(os.path.join(OUT, d))
    home, exrom = open("build/test_basic.bin", "rb").read(), open("build/exrom.bin", "rb").read()
    assert len(home) == 16384 and len(exrom) == 8192
    open(os.path.join(OUT, "roms/leap_v2_home.bin"), "wb").write(home)
    open(os.path.join(OUT, "roms/leap_v2_exrom.bin"), "wb").write(exrom)
    open(os.path.join(OUT, "roms/leap_v2_zesarux.bin"), "wb").write(home + exrom)
    dck = open("build/exrom.dck", "rb").read()   # tools/make_eightyone_dck.sh, part of `make build`
    assert len(dck) == 8201 and dck[9:] == exrom
    open(os.path.join(OUT, "roms/leap_v2_exrom.dck"), "wb").write(dck)
    for n in PACKAGES:
        shutil.copy("build/v2_package_%s.bin" % n, os.path.join(OUT, "packages"))
        shutil.copy("build/extensions/v2_%s.tzx" % n, os.path.join(OUT, "packages"))
    for f in sorted(os.listdir("docs")):
        if f.startswith("V2_") and f.endswith(".md") or f in ("PACKAGE_ABI.md", "AUTHORITATIVE_SOURCE.md"):
            shutil.copy(os.path.join("docs", f), os.path.join(OUT, "docs"))
    shutil.copy("docs/2068_Leap_V2_Users_Manual.docx", os.path.join(OUT, "docs"))
    has_doc = os.path.isfile("docs/2068_Leap_V2_Users_Manual.doc")
    if has_doc:
        shutil.copy("docs/2068_Leap_V2_Users_Manual.doc", os.path.join(OUT, "docs"))
    shutil.copy("docs/EMULATOR_SETUP.md", os.path.join(OUT, "docs"))
    for f in ("0001-zesarux-mirror-ts2068-exrom.patch", "0001-Add-ULAplus-support-for-Timex-machines.patch",
              "COPYING", "README.md"):
        shutil.copy(os.path.join("patches", f), os.path.join(OUT, "patches"))
    for f in sorted(os.listdir("docs/manual")):
        src = os.path.join("docs/manual", f)
        if os.path.isdir(src):
            shutil.copytree(src, os.path.join(OUT, "docs/manual", f))
        else:
            shutil.copy(src, os.path.join(OUT, "docs/manual"))
    sums = []
    for d in ("roms", "packages"):
        for f in sorted(os.listdir(os.path.join(OUT, d))):
            p = os.path.join(d, f)
            sums.append("%s  %s" % (hashlib.sha256(open(os.path.join(OUT, p), "rb").read()).hexdigest(), p))
    open(os.path.join(OUT, "SHA256SUMS"), "w").write("\n".join(sums) + "\n")
    budget = sh("python3", "tools/report_budget.py", "build/test_basic.lst", "build/exrom.lst", "build/test_basic.sym")
    info = [
        RELEASE,
        "version:     %s" % VERSION,
        "status:      %s" % STATUS,
        "hardware:    NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE (docs/V2_HARDWARE_CHECKLIST.md)",
        "commit:      %s (%s)" % (sh("git", "rev-parse", "HEAD"), sh("git", "rev-parse", "--abbrev-ref", "HEAD")),
        "describe:    %s" % sh("git", "describe", "--always", "--dirty"),
        "built:       %s" % sh("date", "-u", "+%Y-%m-%dT%H:%M:%SZ"),
        "identity CRC-16 (HOME, EXROM, empty package registry -- what SAVE ... ALL stamps with no package "
        "loaded): $%04X" % crc16(bytes(12 * 14), crc16(exrom, crc16(home))),
        "",
        budget,
    ]
    open(os.path.join(OUT, "BUILD_INFO.txt"), "w", encoding="utf-8").write("\n".join(info) + "\n")
    readme = [
        RELEASE,
        "",
    ] + ([
        "Emulator-qualified (ZEsarUX), NOT hardware-qualified: nothing in this release has been tried on a",
        "physical Timex Sinclair 2068 (docs/V2_HARDWARE_CHECKLIST.md lists the tests still to run).",
    ] if RELEASE_TAG.fullmatch(VERSION) else [
        "UNQUALIFIED DEVELOPMENT BUILD: built automatically from the development branch; it has not been",
        "through the release qualification. The recommended download is the latest numbered release,",
        "%s: https://github.com/nchiker/2068-Leap/releases/tag/%s" % (LATEST_QUALIFIED, LATEST_QUALIFIED),
    ]) + [
        "",
        "roms/leap_v2_home.bin      16 KB HOME ROM (the TS2068 system ROM socket)",
        "roms/leap_v2_exrom.bin      8 KB EXROM (the extension ROM, chunk 6)",
        "roms/leap_v2_zesarux.bin   HOME + EXROM in one file, for ZEsarUX --romfile only",
        "roms/leap_v2_exrom.dck     the EXROM as a Timex ROM cartridge, for EightyOne 1.41",
        "packages/                  the loadable packages, binary and tape: %s" % ", ".join(PACKAGES),
        "                           (LOAD \"NAME\" EXT; one package at a time)",
        "docs/manual/               the V2 user manual (Markdown, with its pictures)",
        "docs/2068_Leap_V2_Users_Manual.docx   the same manual, Word edition",
    ] + (["docs/2068_Leap_V2_Users_Manual.doc    the same manual, Word 97-2003 edition"] if has_doc else []) + [
        "docs/EMULATOR_SETUP.md     ZEsarUX (qualified; needs patches/0001-zesarux-...), EightyOne, Fuse, TSRun",
        "patches/                   the ZEsarUX EXROM-mirroring patch and the optional Fuse ULAplus patch (GPL)",
        "docs/V2_*.md ...           release record, language reference, defect register, package ABI, studies",
        "BUILD_INFO.txt             release, commit, build time, identity CRC, ROM budget",
        "SHA256SUMS                 checksums of the ROMs and packages: sha256sum -c SHA256SUMS",
    ]
    open(os.path.join(OUT, "README.txt"), "w", encoding="utf-8").write("\n".join(readme) + "\n")
    top = "2068-Leap-V2-%s" % VERSION
    archive = os.path.join("build", top + ".zip")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in sorted(os.walk(OUT)):
            for f in sorted(files):
                p = os.path.join(root, f)
                z.write(p, os.path.join(top, os.path.relpath(p, OUT)))
    digest = hashlib.sha256(open(archive, "rb").read()).hexdigest()
    open(archive + ".sha256", "w").write("%s  %s\n" % (digest, os.path.basename(archive)))
    print("\n".join(info[:8]))
    print("%d files in %s" % (sum(len(fs) for _, _, fs in os.walk(OUT)), OUT))
    print("%s  %s" % (digest, archive))
    return 0


if __name__ == "__main__":
    sys.exit(main())

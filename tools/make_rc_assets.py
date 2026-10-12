#!/usr/bin/env python3
"""Collect the 2068-Leap V2 release artifacts into build/release-v2-rc/ (make rc-assets; the
directory keeps its release-candidate name so existing references stay valid).

ROM images, package binaries and tapes, the V2 documents and the user manual (Markdown and Word),
SHA256SUMS, BUILD_INFO.txt (release name and version, commit, budget, and the CRC-16 of the
HOME+EXROM pair that SAVE ... ALL stamps on its tapes) and README.txt; then the distribution archive
build/2068-Leap-V2-<version>.zip (everything under one top folder of that name) and its .sha256.
The CI workflow publishes that archive for a release tag (.github/workflows/check.yml); it sets
RELEASE_VERSION to the tag (or a dev string), which overrides VERSION below.

RELEASE / VERSION name the release this tree builds. The original release, v2.0.0-emu.1, is the tag
of that name (its own copy of this script labels it); this tree's default build is the sound
maintenance release."""
import hashlib
import os
import shutil
import zipfile
import subprocess
import sys

OUT = "build/release-v2-rc"
VERSION = os.environ.get("RELEASE_VERSION") or "v2.0.1-emu.1"
RELEASE = "2068-Leap V2 Enhanced %s — Sound Maintenance Release (emulator-qualified, not hardware-qualified)" % VERSION
PACKAGES = ("mode", "sprite", "printer", "shapes", "graphics", "cbeep")


def crc16(data, c=0xFFFF):
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True).stdout.strip()


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    for d in ("roms", "packages", "docs", "docs/manual"):
        os.makedirs(os.path.join(OUT, d))
    home, exrom = open("build/test_basic.bin", "rb").read(), open("build/exrom.bin", "rb").read()
    assert len(home) == 16384 and len(exrom) == 8192
    open(os.path.join(OUT, "roms/leap_v2_home.bin"), "wb").write(home)
    open(os.path.join(OUT, "roms/leap_v2_exrom.bin"), "wb").write(exrom)
    open(os.path.join(OUT, "roms/leap_v2_zesarux.bin"), "wb").write(home + exrom)
    for n in PACKAGES:
        shutil.copy("build/v2_package_%s.bin" % n, os.path.join(OUT, "packages"))
        shutil.copy("build/extensions/v2_%s.tzx" % n, os.path.join(OUT, "packages"))
    for f in sorted(os.listdir("docs/v2")):
        if f.startswith("V2_") and f.endswith(".md") or f in ("PACKAGE_ABI.md", "AUTHORITATIVE_SOURCE.md"):
            shutil.copy(os.path.join("docs/v2", f), os.path.join(OUT, "docs"))
    shutil.copy("docs/v2/2068_Leap_V2_Users_Manual.docx", os.path.join(OUT, "docs"))
    for f in sorted(os.listdir("docs/v2/manual")):
        src = os.path.join("docs/v2/manual", f)
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
        "status:      emulator-qualified, NOT hardware-qualified (docs/v2/V2_MAINT_RELEASE_STATUS.md)",
        "hardware:    NOT TESTED — PHYSICAL HARDWARE UNAVAILABLE (docs/v2/V2_HARDWARE_CHECKLIST.md)",
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
        "Emulator-qualified (ZEsarUX), NOT hardware-qualified: nothing in this release has been tried on a",
        "physical Timex Sinclair 2068 (docs/V2_HARDWARE_CHECKLIST.md lists the tests still to run).",
        "",
        "roms/leap_v2_home.bin      16 KB HOME ROM (the TS2068 system ROM socket)",
        "roms/leap_v2_exrom.bin      8 KB EXROM (the extension ROM, chunk 6)",
        "roms/leap_v2_zesarux.bin   HOME + EXROM in one file, for ZEsarUX --romfile only",
        "packages/                  the loadable packages, binary and tape: %s" % ", ".join(PACKAGES),
        "                           (LOAD \"NAME\" EXT; one package at a time)",
        "docs/manual/               the V2 user manual (Markdown, with its pictures)",
        "docs/2068_Leap_V2_Users_Manual.docx   the same manual, Word edition",
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

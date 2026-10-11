#!/usr/bin/env python3
"""RC: collect the V2 release-candidate artifacts into build/release-v2-rc/ (make rc-assets).

ROM images, package binaries and tapes, the V2 documents, SHA256SUMS and BUILD_INFO.txt (commit,
budget, and the CRC-16 of the HOME+EXROM pair that SAVE ... ALL stamps on its tapes)."""
import hashlib
import os
import shutil
import subprocess
import sys

OUT = "build/release-v2-rc"


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
    for d in ("roms", "packages", "docs"):
        os.makedirs(os.path.join(OUT, d))
    home, exrom = open("build/test_basic.bin", "rb").read(), open("build/exrom.bin", "rb").read()
    assert len(home) == 16384 and len(exrom) == 8192
    open(os.path.join(OUT, "roms/leap_v2_home.bin"), "wb").write(home)
    open(os.path.join(OUT, "roms/leap_v2_exrom.bin"), "wb").write(exrom)
    open(os.path.join(OUT, "roms/leap_v2_zesarux.bin"), "wb").write(home + exrom)
    for n in ("mode", "sprite", "printer", "shapes", "graphics"):
        shutil.copy("build/v2_package_%s.bin" % n, os.path.join(OUT, "packages"))
        shutil.copy("build/extensions/v2_%s.tzx" % n, os.path.join(OUT, "packages"))
    for f in sorted(os.listdir("docs/v2")):
        if f.startswith("V2_") and f.endswith(".md") or f in ("PACKAGE_ABI.md", "AUTHORITATIVE_SOURCE.md"):
            shutil.copy(os.path.join("docs/v2", f), os.path.join(OUT, "docs"))
    sums = []
    for d in ("roms", "packages"):
        for f in sorted(os.listdir(os.path.join(OUT, d))):
            p = os.path.join(d, f)
            sums.append("%s  %s" % (hashlib.sha256(open(os.path.join(OUT, p), "rb").read()).hexdigest(), p))
    open(os.path.join(OUT, "SHA256SUMS"), "w").write("\n".join(sums) + "\n")
    budget = sh("python3", "tools/report_budget.py", "build/test_basic.lst", "build/exrom.lst", "build/test_basic.sym")
    info = [
        "2068-Leap V2 release candidate",
        "commit:      %s (%s)" % (sh("git", "rev-parse", "HEAD"), sh("git", "rev-parse", "--abbrev-ref", "HEAD")),
        "describe:    %s" % sh("git", "describe", "--always", "--dirty"),
        "built:       %s" % sh("date", "-u", "+%Y-%m-%dT%H:%M:%SZ"),
        "ROM CRC-16 (HOME then EXROM; SAVE ... ALL tapes carry it): $%04X" % crc16(exrom, crc16(home)),
        "",
        budget,
    ]
    open(os.path.join(OUT, "BUILD_INFO.txt"), "w").write("\n".join(info) + "\n")
    print("\n".join(info[:5]))
    print("%d files in %s" % (sum(len(fs) for _, _, fs in os.walk(OUT)), OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())

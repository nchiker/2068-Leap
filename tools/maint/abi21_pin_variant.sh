#!/usr/bin/env bash
# MAINT (ClassicBEEP study): the measured alternative to CBEEP's border argument -- package ABI 2.1,
# which appends one read-only pin (PORT_FE_SHADOW, $8109) so a package can keep V2's border.
# Built in a COPY of this tree (OUT/abi21); this branch's ABI file is not changed.
#   tools/maint/abi21_pin_variant.sh OUT       -> OUT/abi21 (ROM images, cbeep -DCB_PIN_FE, checks)
set -euo pipefail
tree="$(cd "$(dirname "$0")/../.." && pwd)"
d="$1/abi21"; rm -rf "$d"; mkdir -p "$d"
rsync -a --exclude build --exclude '.git' --exclude '*.bin' "$tree/" "$d/"
python3 - "$d/include/v2_package_abi.inc" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("PKG_ABI_MINOR           EQU 0", "PKG_ABI_MINOR           EQU 1          ; 2.1: PORT_FE_SHADOW pinned", 1)
anchor = "    PKG_PIN PRINT_CUR_ADDR, $8258, 2"
i = s.index(anchor)
j = s.index("\n", i) + 1
s = s[:j] + "    ; -- 2.1: HOME state the package may read (border colour + MIC, as last written to port $FE) --\n" \
          + "    PKG_PIN PORT_FE_SHADOW, $8109, 1\n" + s[j:]
open(p, "w").write(s)
PY
cd "$d"
make build >build.log 2>&1
python3 tools/report_budget.py build/test_basic.lst build/exrom.lst build/test_basic.sym | head -2
sjasmplus -DCB_PIN_FE rom/v2_package_cbeep.asm >>build.log 2>&1
ls -l build/v2_package_cbeep_pin.bin | awk '{print "cbeep (2 arguments, pinned border):", $5, "bytes"}'
sed -i 's|"cbeep": "rom/v2_package_cbeep.asm",|"cbeep": "rom/v2_package_cbeep_pin.asm",|' tools/check_package_abi.py
printf '    DEFINE CB_PIN_FE\n    INCLUDE "rom/v2_package_cbeep.asm"\n' > rom/v2_package_cbeep_pin.asm
python3 tools/check_package_abi.py
sha256sum build/test_basic.bin build/exrom.bin

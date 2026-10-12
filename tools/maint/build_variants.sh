#!/usr/bin/env bash
# MAINT (AY BEEP study): build each candidate configuration of this tree into its own directory
# (OUT/<name>/build/...) and print its HOME/EXROM free bytes. Usage: tools/maint/build_variants.sh OUT [name...]
set -euo pipefail
tree="$(cd "$(dirname "$0")/../.." && pwd)"
out="$1"; shift
B="-DV2_MAINT_SOUND0 -DV2_MAINT_AY_BEEP"
L1="-DV2_MAINT_AYB_PERIOD_HOME"
L1W="-DV2_MAINT_AYB_PERIOD_HOME -DV2_MAINT_AYB_WAIT_HOME"
L3="-DV2_MAINT_AYB_PLAY_HOME -DV2_MAINT_AYB_WAIT_HOME"
L4W="-DV2_MAINT_AYB_WAIT_HOME"
declare -A DEFS=(
  [release]=""
  [sound0]="-DV2_MAINT_SOUND0"
)
DEFS[chimeC_L1_restore]="$B -DV2_MAINT_CHIME_C $L1 -DV2_MAINT_AYB_RESTORE"
DEFS[chimeB_L3_restore]="$B -DV2_MAINT_CHIME_B $L3 -DV2_MAINT_AYB_RESTORE"
DEFS[chimeC_L1_wait]="$B -DV2_MAINT_CHIME_C $L1 -DV2_MAINT_SHARED_WAIT"
DEFS[chimeB_L3_wait]="$B -DV2_MAINT_CHIME_B $L3 -DV2_MAINT_SHARED_WAIT"
for c in A0 A B C; do
  cd=""; [ $c != A0 ] && cd="-DV2_MAINT_CHIME_$c"
  for l in L1 L1W L3 L4W L5; do
    case $l in L1) ld=$L1;; L1W) ld=$L1W;; L3) ld=$L3;; L4W) ld=$L4W;; L5) ld="";; esac
    DEFS[chime${c}_$l]="$B $cd $ld"
  done
done
names=("$@"); [ ${#names[@]} -eq 0 ] && names=(release sound0 $(printf '%s\n' "${!DEFS[@]}" | grep chime | sort))
for n in "${names[@]}"; do
  d="$out/$n"; rm -rf "$d"; mkdir -p "$d"
  rsync -a --exclude build --exclude '.git' --exclude '*.bin' "$tree/" "$d/"
  if (cd "$d" && make build EXTRA_DEFS="${DEFS[$n]}" >build.log 2>&1); then
    b=$(cd "$d" && python3 tools/report_budget.py build/test_basic.lst build/exrom.lst build/test_basic.sym | head -2 | sed 's/  */ /g' | tr '\n' ' ')
    echo "$n: $b"
  else
    echo "$n: BUILD FAILED: $(grep -hiE 'truncated|error:|assert' "$d/build.log" | grep -v 'Errors: 0' | head -2 | tr '\n' ' ')"
  fi
done

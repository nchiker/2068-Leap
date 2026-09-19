#!/usr/bin/env bash
# Mirror 2068-Leap's source into the sibling 2068-Leap-Preview repository, and
# additionally publish built ROM binaries/extensions there -- Preview is a
# real public download point (external links point at files under its
# `roms/`/`extensions/`), and 2068-Leap's own .gitignore deliberately excludes
# every built binary (/*.bin, /rom/*.bin, /build/), so a plain source mirror
# alone would leave Preview with no ROMs to download at all.
#
# This pushes a normal fast-forward commit onto Preview's existing history --
# it does not rewrite or force-push anything. Run it after any change to
# 2068-Leap that should be reflected publicly.
set -euo pipefail

LEAP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW_DIR="${PREVIEW_DIR:-$HOME/2068-Leap-Preview}"

if [ ! -d "$PREVIEW_DIR/.git" ]; then
    echo "sync-to-preview: $PREVIEW_DIR is not a git checkout; set PREVIEW_DIR" >&2
    exit 1
fi

cd "$LEAP_DIR"
if [ -n "$(git status --porcelain)" ]; then
    echo "sync-to-preview: 2068-Leap has uncommitted changes; commit or stash first" >&2
    exit 1
fi
make release-assets

LEAP_SHA="$(git rev-parse --short HEAD)"

# --- Mirror tracked source -------------------------------------------------
# Only files 2068-Leap actually tracks -- never local build artifacts, never
# whatever happens to be sitting untracked in either working tree. Clears
# every tracked path in Preview first so a file removed from 2068-Leap is
# also removed here, then re-extracts 2068-Leap's exact current tree. Preview's
# own git history (its commits, its .git/) is untouched; only the working
# tree content changes, exactly like a normal file edit.
cd "$PREVIEW_DIR"
git ls-files -z | xargs -0 -r rm -f
git clean -fd -e roms -e extensions >/dev/null
cd "$LEAP_DIR"
git archive HEAD | (cd "$PREVIEW_DIR" && tar -x)

# --- Publish built binaries -------------------------------------------------
# roms/ and extensions/ are Preview-only additions (2068-Leap has no folder by
# either name -- its own source lives in singular rom/), so the mirror step
# above never touches them.
mkdir -p "$PREVIEW_DIR/roms" "$PREVIEW_DIR/extensions"
cp build/release/roms/*.bin build/release/roms/*.dck "$PREVIEW_DIR/roms/"
cp build/release/extensions/*.tzx "$PREVIEW_DIR/extensions/"

cd "$PREVIEW_DIR"
git add -A -- . ':!roms/zesarux_index_menu.idx' ':!zesarux_index_menu.idx'

if git diff --cached --quiet; then
    echo "sync-to-preview: no changes; nothing to commit"
    exit 0
fi

git commit -m "Mirror 2068-Leap@${LEAP_SHA}, including built ROMs/extensions"
echo "sync-to-preview: committed. Run 'git push' in $PREVIEW_DIR to publish."

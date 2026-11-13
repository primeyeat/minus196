#!/bin/bash
# Installs Apple's D3DMetal (Direct3D 10-12 on Metal) from a Game Porting Toolkit download as
# the "d3dmetal" graphics backend:
#   ~/Library/Application Support/minus196/backends/gptk/{external,x86_64-windows,x86_64-unix}
# The files are Apple's, under Apple's licence (License.rtf in the disk image): each user has to
# download them with their own Apple account; they must never be committed or redistributed.
# Accepts either the "Game Porting Toolkit" image (which contains the evaluation environment
# image) or the "Evaluation environment for Windows games" image itself.
# Usage: engine/install-gptk.sh <path-to.dmg>
set -euo pipefail
DMG="${1:?usage: install-gptk.sh <Game Porting Toolkit or Evaluation environment .dmg>}"
DEST="${MINUS196_HOME:-$HOME/Library/Application Support/minus196}/backends/gptk"
TMP="$(mktemp -d)"
OUTER="$TMP/outer"; INNER="$TMP/inner"
cleanup() {
    hdiutil detach -quiet "$INNER" 2>/dev/null || true
    hdiutil detach -quiet "$OUTER" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$OUTER" "$INNER"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$OUTER" "$DMG"
ROOT="$OUTER"
if [ ! -d "$ROOT/redist/lib" ]; then
    NESTED="$(find "$OUTER" -maxdepth 1 -name 'Evaluation environment*.dmg' | head -1)"
    [ -n "$NESTED" ] || { echo "no redist/lib and no evaluation environment image in $DMG" >&2; exit 1; }
    hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$INNER" "$NESTED"
    ROOT="$INNER"
    VERSION="$(basename "$NESTED" .dmg)"
else
    VERSION="$(basename "$DMG" .dmg)"
fi
LIB="$ROOT/redist/lib"
for f in external/libd3dshared.dylib external/D3DMetal.framework wine/x86_64-windows/d3d12.dll; do
    [ -e "$LIB/$f" ] || { echo "unexpected layout: $f missing" >&2; exit 1; }
done

# The files are loaded into every game, so they must really be Apple's.
codesign --verify -R='anchor apple' "$LIB/external/libd3dshared.dylib" &&
codesign --verify --deep -R='anchor apple' "$LIB/external/D3DMetal.framework" ||
    { echo "these files are not signed by Apple; not installing" >&2; exit 1; }

rm -rf "$DEST" && mkdir -p "$DEST/x86_64-unix"
ditto "$LIB/external" "$DEST/external"
ditto "$LIB/wine/x86_64-windows" "$DEST/x86_64-windows"
# In Apple's layout the Unix halves are links to ../../external/libd3dshared.dylib; ours sit one
# level higher, so the links are made again.
for so in "$LIB"/wine/x86_64-unix/*.so; do
    ln -s ../external/libd3dshared.dylib "$DEST/x86_64-unix/$(basename "$so")"
done
# DLSS through Apple's MetalFX (experimental, per Apple's Read Me): the bridge has to be found
# under the name games ask for, nvngx. Used only when a bottle sets D3DM_ENABLE_METALFX=1.
if [ -f "$DEST/x86_64-windows/nvngx-on-metalfx.dll" ]; then
    cp "$DEST/x86_64-windows/nvngx-on-metalfx.dll" "$DEST/x86_64-windows/nvngx.dll"
    ln -s ../external/libd3dshared.dylib "$DEST/x86_64-unix/nvngx.so"
fi
cp "$ROOT/License.rtf" "$DEST/License.rtf" 2>/dev/null || true
echo "$VERSION" > "$DEST/VERSION"
echo "installed: $VERSION"
find "$DEST" -maxdepth 2 -not -path '*/D3DMetal.framework/*' | sed "s|$DEST/||" | sort

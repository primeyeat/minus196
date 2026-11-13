#!/bin/bash
# Installs Wine Mono (the open-source .NET Framework replacement Wine uses, from the Wine
# project) into the engine as a shared install, so every bottle has it without a per-bottle
# setup: <engine>/share/wine/mono/wine-mono-<version>/
# The version must be the one the engine's source asks for (WINE_MONO_VERSION in
# dlls/mscoree/mscoree_private.h).
# Usage: engine/install-mono.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"
V="$(sed -n 's/^#define WINE_MONO_VERSION "\(.*\)"/\1/p' "$SRC/wine/dlls/mscoree/mscoree_private.h")"
[ -n "$V" ] || { echo "cannot read WINE_MONO_VERSION from the source" >&2; exit 1; }
F="wine-mono-$V-x86.tar.xz"
DL="$HERE/downloads"
mkdir -p "$DL"
[ -f "$DL/$F" ] || { echo "==> downloading $F"; curl -fL --retry 3 -o "$DL/$F.part" "https://dl.winehq.org/wine/wine-mono/$V/$F" && mv "$DL/$F.part" "$DL/$F"; }
# Known files are checked against the checksum recorded when this script was written; for any
# other version the checksum is only shown, so compare it with the Wine project's yourself.
case "$V" in
    10.4.1) SUM=a16606ef0724202e6a6848ece6e0cbba64d11e2f11aefe744af1d93c6d9f99bb ;;
    *) SUM="" ;;
esac
if [ -n "$SUM" ]; then
    echo "$SUM  $DL/$F" | shasum -a 256 -c - || { echo "checksum mismatch: delete $DL/$F and try again" >&2; exit 1; }
else
    echo "warning: no recorded checksum for wine-mono $V" >&2; shasum -a 256 "$DL/$F"
fi
DEST="$DIST/share/wine/mono"
rm -rf "$DEST/wine-mono-$V" && mkdir -p "$DEST"
tar -xJf "$DL/$F" -C "$DEST"
ls "$DEST"; du -sh "$DEST/wine-mono-$V" | cut -f1

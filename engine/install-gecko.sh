#!/bin/bash
# Installs Wine Gecko (the Wine project's web-page engine, used by installers and launchers
# that show HTML) into the engine as a shared install, so every bottle has it without a
# per-bottle setup: <engine>/share/wine/gecko/wine-gecko-<version>-<arch>/
# The version must be the one the engine's source asks for (GECKO_VERSION in
# dlls/appwiz.cpl/addons.c).
# Usage: engine/install-gecko.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"
V="$(sed -n 's/^#define GECKO_VERSION "\(.*\)"/\1/p' "$SRC/wine/dlls/appwiz.cpl/addons.c")"
[ -n "$V" ] || { echo "cannot read GECKO_VERSION from the source" >&2; exit 1; }
DL="$HERE/downloads"; DEST="$DIST/share/wine/gecko"
mkdir -p "$DL" "$DEST"
for ARCH in x86 x86_64; do
    F="wine-gecko-$V-$ARCH.tar.xz"
    [ -f "$DL/$F" ] || { echo "==> downloading $F"; curl -fL --retry 3 -o "$DL/$F.part" "https://dl.winehq.org/wine/wine-gecko/$V/$F" && mv "$DL/$F.part" "$DL/$F"; }
    # Known files are checked against the checksum recorded when this script was written.
    case "$V-$ARCH" in
        2.47.4-x86)    SUM=2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6 ;;
        2.47.4-x86_64) SUM=fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814 ;;
        *) SUM="" ;;
    esac
    if [ -n "$SUM" ]; then
        echo "$SUM  $DL/$F" | shasum -a 256 -c - || { echo "checksum mismatch: delete $DL/$F and try again" >&2; exit 1; }
    else
        echo "warning: no recorded checksum for wine-gecko $V $ARCH" >&2; shasum -a 256 "$DL/$F"
    fi
    rm -rf "$DEST/wine-gecko-$V-$ARCH"
    tar -xJf "$DL/$F" -C "$DEST"
done
ls "$DEST"; du -sh "$DEST" | cut -f1

#!/bin/bash
# Builds SDL2 as an x86_64 dylib into the engine. Wine's game-controller support (winebus.sys)
# loads it for controller mappings and rumble; without it controllers still appear through
# macOS's own HID layer, but with fewer of them mapped correctly.
# The source archive is fetched from the SDL project's releases and checked against the
# checksum recorded here.
# Usage: engine/build-sdl.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"
V=2.32.10
SUM=5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165
F="SDL2-$V.tar.gz"
DL="$HERE/downloads"; WORK="$HERE/build-deps/sdl"
mkdir -p "$DL"
[ -f "$DL/$F" ] || { curl -fL --retry 3 -o "$DL/$F.part" "https://github.com/libsdl-org/SDL/releases/download/release-$V/$F" && mv "$DL/$F.part" "$DL/$F"; }
echo "$SUM  $DL/$F" | shasum -a 256 -c - || { echo "checksum mismatch: delete $DL/$F and try again" >&2; exit 1; }
rm -rf "$WORK" && mkdir -p "$WORK"
tar -xzf "$DL/$F" -C "$WORK" --strip-components 1
cd "$WORK"
$X86 ./configure --prefix="$DIST" --build=x86_64-apple-darwin --disable-static --disable-dependency-tracking \
    CFLAGS="-O2 -mmacosx-version-min=10.15" >configure.out 2>&1 || { tail -20 configure.out; exit 1; }
$X86 make -j"$(sysctl -n hw.ncpu)" >make.out 2>&1 || { tail -20 make.out; exit 1; }
$X86 make install >install.out 2>&1
file "$DIST/lib/libSDL2-2.0.0.dylib" | cut -c1-120
PKG_CONFIG_LIBDIR="$DIST/lib/pkgconfig" pkg-config --modversion sdl2

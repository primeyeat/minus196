#!/bin/bash
# Builds Wine from CodeWeavers' published source into engine/dist/<name>.
#
# STATUS: NOT YET RUN end to end. Expect to adjust it.
#
# Wine on macOS runs as x86_64 under Rosetta. Homebrew no longer installs for Intel, so:
#   - build tools (bison, pkg-config, the mingw-w64 cross-compiler) come from native arm64
#     Homebrew in /opt/homebrew; they only *produce* x86_64 and Windows code;
#   - x86_64 native libraries Wine links against are built from the tarball's own sources
#     into the same dist folder (so far: FreeType, via build-freetype.sh).
#
# Prerequisite (needs your admin password, so run it yourself once):
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#
# First engine is deliberately minimal: no GnuTLS (so no HTTPS inside Wine yet), no SDL,
# no Vulkan/MoltenVK, no GStreamer. Those are follow-up builds.
#
# Usage: engine/build-engine.sh [path-to-crossover-sources] [engine-name]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HOME/Desktop/RECO/crossover-sources-26.3.0/sources}"
NAME="${2:-cx-26.3}"
DIST="$HERE/dist/$NAME"          # no spaces in this path: Wine's build does not tolerate them
BUILD="$HERE/build-$NAME"
BREW=/opt/homebrew/bin/brew
X86="arch -x86_64"

[ -f "$SRC/wine/configure" ] || { echo "no Wine source at $SRC/wine" >&2; exit 1; }

# Our own changes to the Wine source (engine/patches). Skipped when already applied.
for p in "$HERE"/patches/*.patch; do
    [ -f "$p" ] || continue
    if patch -p1 -d "$SRC/wine" --dry-run -R -s -f < "$p" >/dev/null 2>&1; then
        echo "==> patch already applied: $(basename "$p")"
    elif patch -p1 -d "$SRC/wine" --dry-run -s -f < "$p" >/dev/null 2>&1; then
        echo "==> applying $(basename "$p")"
        patch -p1 -d "$SRC/wine" < "$p"
    else
        echo "$(basename "$p") does not fit this Wine source (written for crossover-sources-26.3.0); nothing was changed" >&2
        exit 1
    fi
done
[ -x "$BREW" ] || { echo "Homebrew not found at $BREW; see the prerequisite at the top of this script" >&2; exit 1; }
/usr/bin/pgrep -q oahd || { echo "Rosetta 2 is not running; install it with: softwareupdate --install-rosetta" >&2; exit 1; }

echo "==> Installing build tools"
"$BREW" install bison pkg-config mingw-w64

[ -f "$DIST/lib/libfreetype.6.dylib" ] || "$HERE/build-freetype.sh" "$SRC" "$DIST"

# Toolchain environment (PATH, CC, CFLAGS, pkg-config scope) lives in env.sh.
SRC="$SRC" NAME="$NAME" source "$HERE/env.sh"

mkdir -p "$BUILD" "$DIST"
cd "$BUILD"

echo "==> Configuring (log: $BUILD/config.log)"
$X86 "$SRC/wine/configure" \
    --prefix="$DIST" \
    --build=x86_64-apple-darwin \
    --enable-archs=i386,x86_64 \
    --disable-tests \
    --with-mingw --with-freetype --with-coreaudio \
    --without-x --without-alsa --without-pulse --without-oss --without-v4l2 --without-gphoto --without-sane \
    --without-cups --without-krb5 --without-capi --without-usb --without-gstreamer \
    --with-gnutls --without-sdl --with-vulkan

echo "==> Building"
$X86 make -j"$(sysctl -n hw.ncpu)" "CFLAGS=$CFLAGS"

echo "==> Installing into $DIST"
$X86 make install

# .NET programs (many game launchers) need Wine Mono in the engine.
SRC="$SRC" NAME="$NAME" "$HERE/install-mono.sh"

echo "==> Done"
"$DIST/bin/wine" --version
echo "Register it with:  minus196 engine add \"$DIST\" --name $NAME"

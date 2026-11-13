#!/bin/bash
# Builds DXMT (Direct3D 10/11 on Metal, https://github.com/3Shain/dxmt, tag v0.80) against the
# engine and installs it as the "dxmt" graphics backend:
#   ~/Library/Application Support/minus196/backends/dxmt/{x86_64-windows,i386-windows,x86_64-unix}
# Needs: build-llvm15.sh run first, the engine installed in dist/, Xcode's Metal toolchain.
# Usage: engine/build-dxmt.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"
export PATH="/opt/homebrew/bin:$PATH"
TAG=v0.80
SRCDIR="$HERE/build-deps/dxmt-src/dxmt"
LLVM="$HERE/build-deps/llvm15"
B="$HERE/build-deps/dxmt-build"
STAGE="$B/stage"
DEST="${MINUS196_HOME:-$HOME/Library/Application Support/minus196}/backends/dxmt"

[ -f "$LLVM/lib/libLLVMCore.a" ] || { echo "LLVM 15 not built: run engine/build-llvm15.sh first" >&2; exit 1; }
[ -x "$DIST/bin/winebuild" ] || { echo "engine not installed at $DIST" >&2; exit 1; }
if [ ! -d "$SRCDIR" ]; then
    mkdir -p "$(dirname "$SRCDIR")"
    git clone --depth 1 --branch "$TAG" --recurse-submodules --shallow-submodules \
        https://github.com/3Shain/dxmt.git "$SRCDIR"
fi

# env.sh's compiler variables are for building Wine itself. Here Meson must see none of them:
# they would be handed to the MinGW cross compiler as well. DXMT's own build files add
# "-arch x86_64" for the native (unix) side.
unset CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS CROSSCFLAGS PKG_CONFIG_LIBDIR

# Fixes for this machine's newer tools, applied to the checkout (safe to repeat):
#  - Xcode 27's Metal compiler takes a fifth "memory flags" argument in this builtin;
#  - current GCC no longer pulls <iomanip>/<cstdint> in indirectly (handled by -include below).
python3 -I - "$SRCDIR/src/airconv/shaders/air_tessellation.metal" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "int(memory_order_relaxed), __METAL_MEMORY_SCOPE_THREADGROUP__);"
new = "int(memory_order_relaxed), __METAL_MEMORY_SCOPE_THREADGROUP__, __METAL_MEMORY_FLAGS_NONE__);"
if old in s:
    open(p, "w").write(s.replace(old, new)); print("patched", p)
PY
MINGW_CPP_ARGS="-include iomanip -include cstdint -include cstring"

rm -rf "$B" && mkdir -p "$B"
echo "==> 64-bit (log: $B/build64.log)"
{
    meson setup "$B/build64" "$SRCDIR" --cross-file "$SRCDIR/build-win64.txt" --buildtype release \
        --prefix "$STAGE" -Dnative_llvm_path="$LLVM" -Dwine_install_path="$DIST" -Dcpp_args="$MINGW_CPP_ARGS" &&
    meson compile -C "$B/build64" &&
    meson install -C "$B/build64"
} > "$B/build64.log" 2>&1 || { grep -E "FAILED|error[: ]" -A3 "$B/build64.log" | grep -vE "warning:|note:" | head -40; exit 1; }

echo "==> 32-bit (log: $B/build32.log)"
{
    meson setup "$B/build32" "$SRCDIR" --cross-file "$SRCDIR/build-win32.txt" --buildtype release \
        --prefix "$STAGE" -Dwine_install_path="$DIST" -Dcpp_args="$MINGW_CPP_ARGS" &&
    meson compile -C "$B/build32" &&
    meson install -C "$B/build32"
} > "$B/build32.log" 2>&1 || { grep -E "FAILED|error[: ]" -A3 "$B/build32.log" | grep -vE "warning:|note:" | head -40; exit 1; }

echo "==> installing to $DEST"
# Check that everything was built before the installed copy is replaced.
for d in x86_64-windows i386-windows x86_64-unix; do
    [ -n "$(find "$STAGE" -type d -name "$d" | head -1)" ] || { echo "missing $d in $STAGE" >&2; exit 1; }
done
rm -rf "$DEST" && mkdir -p "$DEST"
for d in x86_64-windows i386-windows x86_64-unix; do
    cp -R "$(find "$STAGE" -type d -name "$d" | head -1)" "$DEST/$d"
done
echo "$TAG" > "$DEST/VERSION"
find "$DEST" -type f | sed "s|$DEST/||" | sort
file "$DEST/x86_64-unix/winemetal.so" | cut -c1-140

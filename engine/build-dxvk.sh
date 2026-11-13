#!/bin/bash
# Builds DXVK (the version in the crossover-sources tarball) as 64-bit and 32-bit Windows DLLs
# and installs them as the wrapper's "dxvk" graphics backend:
#   <-196 home>/backends/dxvk/x86_64-windows/*.dll and .../i386-windows/*.dll
# Needs Homebrew meson, ninja, glslang and mingw-w64.
# Usage: engine/build-dxvk.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"
unset CC CXX CFLAGS CPPFLAGS LDFLAGS CROSSCFLAGS   # this is a pure Windows cross build
D="$SRC/dxvk"
B="$HERE/build-deps/dxvk"
OUT="${MINUS196_HOME:-$HOME/Library/Application Support/minus196}/backends/dxvk"
mkdir -p "$B"
# DXVK 1.10.3 predates current GCC: some files use uint32_t and friends without including
# <cstdint>. Force-include it rather than editing the sources.
CPP_ARGS="-include cstdint -include cstring -Wno-template-body"

# Work on a copy so the tarball's tree stays untouched. One fix is applied to it: DXVK declares
# a placeholder D3DDEVINFO_RESOURCEMANAGER because old MinGW headers lacked it; current MinGW
# defines the real one, and the two collide.
S="$B/src"
rm -rf "$S" && cp -R "$D" "$S"
/usr/bin/python3 -I - "$S" <<'PY'
import re, sys
root = sys.argv[1]
# (file, pattern, replacement): declarations current MinGW headers now provide themselves.
fixes = [
    ("src/d3d9/d3d9_include.h",
     r"typedef struct _D3DDEVINFO_RESOURCEMANAGER\s*\{.*?\}\s*D3DDEVINFO_RESOURCEMANAGER\s*,\s*\*\s*LPD3DDEVINFO_RESOURCEMANAGER;",
     "typedef struct _D3DDEVINFO_RESOURCEMANAGER * LPD3DDEVINFO_RESOURCEMANAGER;"),
    ("src/d3d10/d3d10_interfaces.h",
     r"__CRT_UUID_DECL\(ID3D10StateBlock,[^;]*;", ""),
]
for rel, pattern, replacement in fixes:
    path = root + "/" + rel
    text = open(path).read()
    fixed, n = re.subn(pattern, replacement, text, flags=re.S)
    if n != 1: sys.exit(rel + ": expected text not found")
    open(path, "w").write(fixed)
PY
D="$S"

build() {   # build <bits> <cross file> <wine arch folder>
    local bits="$1" cross="$2" arch="$3"
    echo "==> DXVK $bits-bit"
    rm -rf "$B/build$bits"
    meson setup "$B/build$bits" "$D" --cross-file "$D/$cross" --buildtype release \
        --prefix "$B/install$bits" --bindir bin --libdir lib -Denable_tests=false \
        -Dcpp_args="$CPP_ARGS" > "$B/meson$bits.out" 2>&1
    ninja -k 0 -C "$B/build$bits" install > "$B/ninja$bits.out" 2>&1
    mkdir -p "$OUT/$arch"
    cp "$B/install$bits"/bin/*.dll "$OUT/$arch/"
    # Wine only loads DLLs from its builtin search path when they carry its builtin marker.
    "$DIST/bin/winebuild" --builtin "$OUT/$arch"/*.dll
}
build 64 build-win64.txt x86_64-windows
build 32 build-win32.txt i386-windows
cat "$D/RELEASE" > "$OUT/VERSION"

echo "==> result"
for a in x86_64-windows i386-windows; do echo "$a: $(ls "$OUT/$a" | tr '\n' ' ')"; done

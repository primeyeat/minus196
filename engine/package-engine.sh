#!/bin/bash
# Packs the built engine and the open graphics layers into one archive that -196 can download
# and unpack on any Mac. The staged copy is made to run from any folder: every library search
# path that points into this build folder is rewritten to be relative.
#
# In the archive:  engine/    the Wine install (bin, lib, share), with Wine Mono
#                  backends/  dxmt and dxvk
#                  LICENSES/  licence texts, and SOURCE.txt saying where the source is
# Never in it: Apple's D3DMetal (backends/gptk). That is under Apple's licence.
#
# Usage: engine/package-engine.sh [version]        e.g. engine/package-engine.sh 26.3-1
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"
VERSION="${1:-26.3-1}"
HOME_DIR="${MINUS196_HOME:-$HOME/Library/Application Support/minus196}"
OUT="$HERE/build-package"
STAGE="$OUT/minus196-engine"
ARCHIVE="$OUT/minus196-engine-$VERSION.tar.xz"

for need in "$DIST/bin/wine" "$DIST/lib/wine/x86_64-unix/cxcompatdb.so" "$DIST/share/wine/mono" \
            "$HOME_DIR/backends/dxmt/x86_64-windows" "$HOME_DIR/backends/dxvk/x86_64-windows"; do
    [ -e "$need" ] || { echo "missing: $need" >&2; exit 1; }
done

rm -rf "$STAGE" "$ARCHIVE"
mkdir -p "$STAGE/engine/bin" "$STAGE/backends" "$STAGE/LICENSES"

echo "copying the engine"
cp "$DIST/bin/wine" "$DIST/bin/wineserver" "$STAGE/engine/bin/"
# Headers, import libraries, pkg-config files and manual pages are only needed for building.
rsync -a --exclude 'pkgconfig' --exclude '*.la' --exclude '*.a' "$DIST/lib" "$STAGE/engine/"
rsync -a --exclude 'man' "$DIST/share" "$STAGE/engine/"
rsync -a "$HOME_DIR/backends/dxmt" "$HOME_DIR/backends/dxvk" "$STAGE/backends/"
echo "$VERSION" > "$STAGE/VERSION"

echo "making it run from any folder"
rpaths() { otool -l "$1" | awk '/LC_RPATH/ {r = 1} r && $1 == "path" {print $2; r = 0}'; }
relocate() {   # file, search path relative to the file
    local file="$1" relative="$2" dep leaf old
    file -b "$file" | grep -q 'Mach-O' || return 0
    chmod u+w "$file"
    # Its own name, if it is a library named by an absolute path.
    old="$(otool -D "$file" | tail -n +2)"
    case "$old" in "$DIST"/*) install_name_tool -id "@rpath/$(basename "$old")" "$file" 2>/dev/null ;; esac
    # Libraries it links to.
    otool -L "$file" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        case "$dep" in "$DIST"/*) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$file" 2>/dev/null ;; esac
    done
    # Search paths.
    rpaths "$file" | while read -r old; do
        case "$old" in "$DIST"/*) install_name_tool -delete_rpath "$old" "$file" 2>/dev/null ;; esac
    done
    if ! rpaths "$file" | grep -qxF "$relative"; then
        install_name_tool -add_rpath "$relative" "$file" 2>/dev/null
    fi
}
for f in "$STAGE/engine/bin/"*;                  do relocate "$f" "@loader_path/../lib"; done
for f in "$STAGE/engine/lib/"*.dylib;            do [ -L "$f" ] || relocate "$f" "@loader_path"; done
for f in "$STAGE/engine/lib/wine/x86_64-unix/"*; do relocate "$f" "@loader_path/../.."; done

# Nothing may still point into the build folder through a load command.
left=0
while IFS= read -r f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    if otool -l "$f" | grep -q "$DIST"; then echo "still points at the build folder: $f" >&2; left=1; fi
done < <(find "$STAGE/engine/bin" "$STAGE/engine/lib" -maxdepth 3 -type f ! -name '*.dll' ! -name '*.exe' ! -name '*.sys')
[ "$left" = 0 ] || exit 1

# Built files carry the full path of the folder they were built in (in error messages and as
# an unused fallback). Blank that folder out, keeping every string the same length, so the
# archive does not publish the builder's user name or folder layout.
echo "removing this Mac's folder names from the built files"
python3 - "$STAGE" "$HOME" "$HERE" "$SRC" <<'PY'
import os, sys
stage, home, here, src = sys.argv[1:5]
common = os.path.commonpath([here, src])
roots = sorted({r for r in (common, home) if r.startswith(home) and len(r) > 1}, key=len, reverse=True)
pairs = []
for r in roots:
    for enc in ("utf-8", "utf-16-le"):
        pairs.append((r.encode(enc), ("/" + "_" * (len(r) - 1)).encode(enc)))
changed = 0
for folder, _, names in os.walk(stage):
    for name in names:
        path = os.path.join(folder, name)
        if os.path.islink(path): continue
        data = open(path, "rb").read()
        new = data
        for old, blank in pairs: new = new.replace(old, blank)
        if new != data:
            mode = os.stat(path).st_mode
            os.chmod(path, mode | 0o200)
            open(path, "wb").write(new)
            os.chmod(path, mode)
            changed += 1
        if home.encode() in new or home.encode("utf-16-le") in new:
            sys.exit("still names the home folder: " + path)
print("  files changed:", changed)
PY

echo "collecting licence texts"
copy_licence() { [ -f "$1" ] && cp "$1" "$STAGE/LICENSES/$2" || echo "  (no licence file found for $2: $1)"; }
copy_licence "$SRC/wine/COPYING.LIB"      "Wine-COPYING.LIB.txt"
copy_licence "$SRC/wine/LICENSE"          "Wine-LICENSE.txt"
copy_licence "$SRC/wine/AUTHORS"          "Wine-AUTHORS.txt"
copy_licence "$SRC/freetype/LICENSE.TXT"  "FreeType-LICENSE.txt"
copy_licence "$SRC/freetype/docs/FTL.TXT" "FreeType-FTL.txt"
copy_licence "$SRC/moltenvk/LICENSE"                        "MoltenVK-LICENSE.txt"
copy_licence "$SRC/dxvk/LICENSE"                            "DXVK-LICENSE.txt"
copy_licence "$HERE/build-deps/dxmt-src/dxmt/LICENSE"       "DXMT-LICENSE.txt"
copy_licence "$HERE/build-deps/nettle/COPYING.LESSERv3"     "Nettle-GMP-COPYING.LESSERv3.txt"
copy_licence "$HERE/build-deps/nettle/COPYINGv2"            "Nettle-GMP-COPYINGv2.txt"
# GnuTLS is under the LGPL 2.1 or later: the same text as Wine-COPYING.LIB.txt.
# Wine Mono's own licence notes are inside engine/share/wine/mono.
cat > "$STAGE/LICENSES/SOURCE.txt" <<EOF
-196 engine $VERSION

This archive contains built copies of free software. Where the source is:

Wine 11.0 (GNU LGPL 2.1 or later)
    Built from the source CodeWeavers publishes for CrossOver 26.3.0
    (crossover-sources-26.3.0.tar.gz, https://www.codeweavers.com/crossover/source),
    with the patches in engine/patches of https://github.com/primeyeat/minus196 applied.
    The scripts in engine/ of that repository are the build instructions.
    The start-up hook lib/wine/x86_64-unix/cxcompatdb.so is built from
    engine/compat-hook/minus196_compat.c in the same repository (MIT).
FreeType (FreeType Licence)         from the same CodeWeavers source archive
MoltenVK (Apache 2.0)               https://github.com/KhronosGroup/MoltenVK
GnuTLS (LGPL 2.1 or later)          https://www.gnutls.org
Nettle, Hogweed (LGPL 3 / GPL 2)    https://www.lysator.liu.se/~nisse/nettle/
GMP (LGPL 3 / GPL 2)                https://gmplib.org
Wine Mono (MIT, LGPL and others)    https://gitlab.winehq.org/wine/wine-mono
DXVK $(cat "$HOME_DIR/backends/dxvk/VERSION" 2>/dev/null) (zlib)        https://github.com/doitsujin/dxvk
DXMT $(cat "$HOME_DIR/backends/dxmt/VERSION" 2>/dev/null) (zlib)          https://github.com/3Shain/dxmt

Apple's D3DMetal is not included.
EOF

echo "packing (this takes a few minutes)"
COPYFILE_DISABLE=1 tar -C "$STAGE" --uid 0 --gid 0 --uname '' --gname '' --options 'xz:compression-level=6,xz:threads=0' -cJf "$ARCHIVE" .
echo "archive:  $ARCHIVE"
echo "size:     $(du -h "$ARCHIVE" | cut -f1)"
echo "sha256:   $(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"

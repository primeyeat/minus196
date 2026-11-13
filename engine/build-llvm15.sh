#!/bin/bash
# Builds the LLVM 15 libraries DXMT links into its shader converter (x86_64, static, no
# targets, no tools), following DXMT's docs/DEVELOPMENT.md. Installed to build-deps/llvm15.
# Sources: the llvm and cmake release tarballs of llvmorg-15.0.7, kept in engine/downloads/.
# Usage: engine/build-llvm15.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
V=15.0.7
DL="$HERE/downloads"
B="$HERE/build-deps/llvm15-build"
OUT="$HERE/build-deps/llvm15"
BASE="https://github.com/llvm/llvm-project/releases/download/llvmorg-$V"
mkdir -p "$DL"
for f in "llvm-$V.src.tar.xz" "cmake-$V.src.tar.xz"; do
    [ -f "$DL/$f" ] || { echo "==> downloading $f"; curl -fL --retry 3 -o "$DL/$f.part" "$BASE/$f" && mv "$DL/$f.part" "$DL/$f"; }
done
# Checksums recorded when this script was written.
shasum -a 256 -c - <<SUMS || { echo "checksum mismatch: delete the file in $DL and try again" >&2; exit 1; }
4ad8b2cc8003c86d0078d15d987d84e3a739f24aae9033865c027abae93ee7a4  $DL/llvm-$V.src.tar.xz
8986f29b634fdaa9862eedda78513969fe9788301c9f2d938f4c10a3e7a3e7ea  $DL/cmake-$V.src.tar.xz
SUMS

rm -rf "$B" && mkdir -p "$B/llvm" "$B/cmake" "$B/build"
tar -xJf "$DL/llvm-$V.src.tar.xz" -C "$B/llvm" --strip-components=1
tar -xJf "$DL/cmake-$V.src.tar.xz" -C "$B/cmake" --strip-components=1

echo "==> configuring"
cmake -B "$B/build" -S "$B/llvm" -G Ninja \
    -DCMAKE_INSTALL_PREFIX="$OUT" \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15 \
    -DLLVM_HOST_TRIPLE=x86_64-apple-darwin \
    -DLLVM_ENABLE_ASSERTIONS=On \
    -DLLVM_ENABLE_ZSTD=Off -DLLVM_ENABLE_ZLIB=Off -DLLVM_ENABLE_TERMINFO=Off -DLLVM_ENABLE_LIBXML2=Off \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_TARGETS_TO_BUILD="" \
    -DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_TESTS=Off -DLLVM_INCLUDE_BENCHMARKS=Off -DLLVM_INCLUDE_EXAMPLES=Off \
    -DLLVM_VERSION_PRINTER_SHOW_HOST_TARGET_INFO=Off \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    > "$B/configure.out" 2>&1
echo "==> building (log: $B/build.out)"
cmake --build "$B/build" > "$B/build.out" 2>&1
rm -rf "$OUT"
cmake --install "$B/build" > "$B/install.out" 2>&1
echo "==> result"
ls "$OUT/lib" | grep -c '\.a$' | sed 's/^/static libraries: /'
lipo -info "$OUT/lib/libLLVMCore.a"

#!/bin/bash
# Builds GMP, Nettle and GnuTLS as x86_64 dylibs from the crossover-sources tarball into the
# engine's dist folder, so Wine can be configured --with-gnutls (HTTPS, schannel, bcrypt).
# Usage: engine/build-gnutls.sh   (env.sh supplies SRC, DIST, toolchain)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"
G="$SRC/gnutls"
B="$HERE/build-deps"
JOBS="$(sysctl -n hw.ncpu)"
export PATH="/opt/homebrew/opt/libtool/libexec/gnubin:$PATH"
export CFLAGS="-O2 -g0"
export CPPFLAGS="-I$DIST/include"
export LDFLAGS="-L$DIST/lib"
COMMON=(--prefix="$DIST" --build=x86_64-apple-darwin --host=x86_64-apple-darwin --enable-shared --disable-static)
mkdir -p "$B"

step() { echo "==> $*"; }

if [ ! -f "$DIST/lib/libgmp.dylib" ]; then
    step "GMP"
    mkdir -p "$B/gmp" && cd "$B/gmp"
    $X86 "$G/gmp/configure" "${COMMON[@]}" --with-pic > configure.out 2>&1
    $X86 make -j"$JOBS" > make.out 2>&1
    $X86 make install > install.out 2>&1
fi

if [ ! -f "$DIST/lib/libnettle.dylib" ]; then
    step "Nettle"
    # The tarball's nettle has neither a generated configure nor upstream's Makefile.in
    # (CodeWeavers build it with their own makefiles), so use the same version's GNU release:
    # https://ftp.gnu.org/gnu/nettle/nettle-3.10.tar.gz, kept in engine/downloads/.
    NETTLE_TGZ="$HERE/downloads/nettle-3.10.tar.gz"
    [ -f "$NETTLE_TGZ" ] || { echo "missing $NETTLE_TGZ" >&2; exit 1; }
    rm -rf "$B/nettle" && mkdir -p "$B/nettle" && tar -xzf "$NETTLE_TGZ" -C "$B/nettle" --strip-components=1
    cd "$B/nettle"
    $X86 ./configure "${COMMON[@]}" --disable-documentation --disable-openssl \
        --with-include-path="$DIST/include" --with-lib-path="$DIST/lib" > configure.out 2>&1
    $X86 make -j"$JOBS" > make.out 2>&1
    $X86 make install > install.out 2>&1
fi

if [ ! -f "$DIST/lib/libgnutls.dylib" ]; then
    step "GnuTLS"
    mkdir -p "$B/gnutls" && cd "$B/gnutls"
    # Name the libraries explicitly: this configure links its feature tests with only
    # "-lhogweed -lgmp" otherwise, which on macOS misses libnettle's symbols and makes it
    # build its own copies of functions that Nettle 3.10 already declares.
    rm -rf "$B/gnutls" && mkdir -p "$B/gnutls" && cd "$B/gnutls"
    $X86 "$G/gnutls/configure" "${COMMON[@]}" \
        NETTLE_LIBS="-lnettle" HOGWEED_LIBS="-lhogweed" GMP_LIBS="-lgmp" \
        --with-included-libtasn1 --with-included-unistring --without-p11-kit \
        --without-idn --without-brotli --without-zstd --without-zlib --without-tpm --without-tpm2 \
        --disable-doc --disable-tests --disable-tools --disable-cxx --disable-nls \
        --disable-guile --disable-libdane --disable-gtk-doc > configure.out 2>&1
    $X86 make -j"$JOBS" > make.out 2>&1
    $X86 make install > install.out 2>&1
fi

step "Result"
ls -la "$DIST/lib" | grep -E "libgmp|libnettle|libhogweed|libgnutls" | awk '{print $5, $NF}'
file "$DIST/lib/libgnutls.dylib" | cut -c1-140
PKG_CONFIG_LIBDIR="$DIST/lib/pkgconfig" pkg-config --modversion gnutls

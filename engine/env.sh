# Sourced by the engine build steps. Sets the toolchain environment for an x86_64 Wine build.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-$HOME/Desktop/RECO/crossover-sources-26.3.0/sources}"
NAME="${NAME:-cx-26.3}"
DIST="$HERE/dist/$NAME"
BUILD="$HERE/build-$NAME"
BREW_PREFIX=/opt/homebrew
export PATH="$BREW_PREFIX/opt/bison/bin:$BREW_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG_LIBDIR="$DIST/lib/pkgconfig"
unset PKG_CONFIG_PATH
export CC="clang -arch x86_64"
export CXX="clang++ -arch x86_64"
# The CodeWeavers source uses SONAME_LIBVULKAN unconditionally (CW HACK 25909 in win32u/vulkan.c),
# so a build configured --without-vulkan must still define it. With no MoltenVK present the
# dlopen simply fails at run time and Vulkan stays unavailable.
export CFLAGS="-O2 -g0"
export CROSSCFLAGS="-O2 -g0"
# -L/-I so configure finds libraries that ship no pkg-config file (MoltenVK).
export LDFLAGS="-L$DIST/lib -Wl,-rpath,$DIST/lib"
export CPPFLAGS="-I$DIST/include"
X86="arch -x86_64"

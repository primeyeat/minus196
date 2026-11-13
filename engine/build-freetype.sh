#!/bin/bash
# Builds FreeType as an x86_64 dylib from the source in the crossover-sources tarball.
# No configure step: the tarball is a git checkout without generated autotools files, so this
# compiles FreeType's documented module list directly.
# Usage: engine/build-freetype.sh [sources-dir] [dist-dir]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FT="${1:-$HOME/Desktop/RECO/crossover-sources-26.3.0/sources}/freetype"
DIST="${2:-$HERE/dist/cx-26.3}"
OBJ="$HERE/build-freetype"
CC="clang -arch x86_64 -mmacosx-version-min=10.15"
[ -f "$FT/include/freetype/freetype.h" ] || { echo "no FreeType source at $FT" >&2; exit 1; }
mkdir -p "$DIST/lib/pkgconfig" "$DIST/include" "$OBJ"
cd "$FT"
VER=$(grep -E "define FREETYPE_(MAJOR|MINOR|PATCH) " include/freetype/freetype.h | awk '{print $3}' | paste -sd. -)
SRCS=(base/ftsystem.c base/ftinit.c base/ftdebug.c base/ftbase.c base/ftbbox.c base/ftglyph.c base/ftbitmap.c
      base/ftbdf.c base/ftcid.c base/ftfstype.c base/ftgasp.c base/ftgxval.c base/ftmm.c base/ftotval.c
      base/ftpatent.c base/ftpfr.c base/ftstroke.c base/ftsynth.c base/fttype1.c base/ftwinfnt.c
      bdf/bdf.c cff/cff.c cid/type1cid.c pcf/pcf.c pfr/pfr.c sfnt/sfnt.c truetype/truetype.c type1/type1.c
      type42/type42.c winfonts/winfnt.c raster/raster.c sdf/sdf.c smooth/smooth.c svg/svg.c autofit/autofit.c
      cache/ftcache.c gzip/ftgzip.c lzw/ftlzw.c psaux/psaux.c pshinter/pshinter.c psnames/psnames.c)
OBJS=()
for s in "${SRCS[@]}"; do
    o="$OBJ/$(echo "$s" | tr '/' '_' | sed 's/\.c$/.o/')"
    $CC -O2 -fPIC -w -DFT2_BUILD_LIBRARY -Iinclude -c "src/$s" -o "$o"
    OBJS+=("$o")
done
$CC -dynamiclib -o "$DIST/lib/libfreetype.6.dylib" -install_name "$DIST/lib/libfreetype.6.dylib" \
    -compatibility_version 6 "${OBJS[@]}"
ln -sf libfreetype.6.dylib "$DIST/lib/libfreetype.dylib"
rm -rf "$DIST/include/freetype2"; mkdir -p "$DIST/include/freetype2"
cp -R include/ft2build.h include/freetype "$DIST/include/freetype2/"
cat > "$DIST/lib/pkgconfig/freetype2.pc" <<EOF
prefix=$DIST
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: FreeType 2
Description: FreeType built for x86_64 from the crossover-sources tarball
Version: $VER
Libs: -L\${libdir} -lfreetype
Cflags: -I\${includedir}/freetype2
EOF
# Self-test: load a system font and render one glyph with the x86_64 library (runs under Rosetta).
cat > "$OBJ/t.c" <<'EOF'
#include <ft2build.h>
#include FT_FREETYPE_H
#include <stdio.h>
int main(void){FT_Library l;FT_Face f;int a,b,c; if(FT_Init_FreeType(&l))return 1; FT_Library_Version(l,&a,&b,&c);
 if(FT_New_Face(l,"/System/Library/Fonts/Supplemental/Arial.ttf",0,&f))return 2; FT_Set_Pixel_Sizes(f,0,32);
 if(FT_Load_Char(f,'A',FT_LOAD_RENDER))return 3;
 printf("freetype %d.%d.%d: %s, glyph 'A' %ux%u\n",a,b,c,f->family_name,f->glyph->bitmap.width,f->glyph->bitmap.rows);return 0;}
EOF
$CC -I"$DIST/include/freetype2" "$OBJ/t.c" -L"$DIST/lib" -lfreetype -o "$OBJ/t"
"$OBJ/t"
file "$DIST/lib/libfreetype.6.dylib"

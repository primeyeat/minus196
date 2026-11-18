#!/bin/bash
# Puts GStreamer (the media framework Wine uses to play video and audio files inside Windows
# programs) into the engine, from the GStreamer project's own macOS packages. The packages are
# unpacked, never installed; only the x86_64 half of the chosen parts is copied:
#   <engine>/lib/libgst*.dylib and the libraries they need
#   <engine>/lib/gstreamer-1.0/*.dylib         plugins
#   <engine>/libexec/gstreamer-1.0/gst-plugin-scanner
# The sub-packages GStreamer marks as GPL (codecs-gpl, dvd-gpl) are not used.
# Headers for building Wine's winegstreamer come from the "devel" package and stay in
# build-deps; build-engine.sh picks them up through gstreamer-env.sh, written here.
# Usage: engine/install-gstreamer.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"
V=1.28.9
BASE="https://gstreamer.freedesktop.org/data/pkg/osx/$V"
RUNTIME="gstreamer-1.0-$V-universal.pkg";      RUNTIME_SUM=05d27c8e9b4374bbcf1788cf1604bb4b1a4bdcbdc13bc37b67d3a225c8aa86a6
DEVEL="gstreamer-1.0-devel-$V-universal.pkg";  DEVEL_SUM=54e27ccc9af096f7f12cff32b6111b7f1b867d968cb8888e80719ad46a97c777
DL="$HERE/downloads"; WORK="$HERE/build-deps/gstreamer"
mkdir -p "$DL" "$WORK"

fetch() {   # file, checksum
    [ -f "$DL/$1" ] || { echo "==> downloading $1"; curl -fL --retry 3 -o "$DL/$1.part" "$BASE/$1" && mv "$DL/$1.part" "$DL/$1"; }
    echo "$2  $DL/$1" | shasum -a 256 -c - || { echo "checksum mismatch: delete $DL/$1 and try again" >&2; exit 1; }
}
fetch "$RUNTIME" "$RUNTIME_SUM"
fetch "$DEVEL" "$DEVEL_SUM"
[ -d "$WORK/runtime" ] || pkgutil --expand-full "$DL/$RUNTIME" "$WORK/runtime"
[ -d "$WORK/devel" ]   || pkgutil --expand-full "$DL/$DEVEL" "$WORK/devel"

# One tree out of the sub-packages that are used.
ROOT="$WORK/root"
rm -rf "$ROOT" && mkdir -p "$ROOT"
for part in base-system-1.0 gstreamer-1.0-core gstreamer-1.0-playback gstreamer-1.0-codecs \
            gstreamer-1.0-codecs-restricted gstreamer-1.0-effects gstreamer-1.0-libav gstreamer-1.0-system; do
    ditto "$WORK/runtime/$part-$V-universal.pkg/Payload" "$ROOT"
done
DEV="$WORK/devel-root"
rm -rf "$DEV" && mkdir -p "$DEV"
for part in "$WORK"/devel/*.pkg; do
    [ -d "$part/Payload/include" ] && ditto "$part/Payload/include" "$DEV/include"
    [ -d "$part/Payload/lib/glib-2.0" ] && ditto "$part/Payload/lib/glib-2.0" "$DEV/lib/glib-2.0"
done
[ -f "$DEV/include/gstreamer-1.0/gst/gst.h" ] || { echo "GStreamer headers not found in the devel package" >&2; exit 1; }

# Plugins: what Wine asks for by name (decodebin, videoconvert, audioconvert, audioresample,
# deinterlace, videoflip) and the demuxers, parsers and decoders decodebin picks from.
PLUGINS="coreelements typefindfunctions app playback pbtypes rawparse
         videoconvertscale videofilter videorate deinterlace audioconvert audioresample audiorate volume
         audioparsers videoparsersbad isomp4 matroska avi flv asf mpegtsdemux mpegpsdemux realmedia mxf ivfparse
         wavparse id3demux apetag icydemux ogg subparse
         libav applemedia vorbis opus theora vpx flac mpg123 dav1d openh264 jpeg png adpcmdec alaw mulaw speex wavpack"

# Never replaced: libraries the engine already has its own build of.
keep_own() { case "$1" in libfreetype.*|libMoltenVK.*|libgmp.*|libgnutls.*|libnettle.*|libhogweed.*|libSDL2*) return 0 ;; esac; return 1; }

mkdir -p "$DIST/lib/gstreamer-1.0" "$DIST/libexec/gstreamer-1.0"
rm -f "$DIST/lib/gstreamer-1.0/"*.dylib
SEEN="$WORK/seen.txt"; : > "$SEEN"

thin() {   # from, to
    if lipo -info "$1" 2>/dev/null | grep -q 'Architectures in the fat file'; then lipo -thin x86_64 "$1" -output "$2"
    else cp "$1" "$2"; fi
    chmod 644 "$2"
}
# Copies a library from the tree into the engine's lib folder, then everything it links to.
need_library() {
    local name="$1" from dep
    grep -qxF "$name" "$SEEN" && return 0
    echo "$name" >> "$SEEN"
    if keep_own "$name"; then
        [ -e "$DIST/lib/$name" ] || { echo "plugin needs $name, which the engine does not have" >&2; exit 1; }
        return 0
    fi
    from="$ROOT/lib/$name"
    [ -e "$from" ] || { echo "missing in the GStreamer packages: $name" >&2; exit 1; }
    thin "$from" "$DIST/lib/$name"
    dependencies "$DIST/lib/$name"
}
dependencies() {
    local dep
    otool -L "$1" | tail -n +2 | awk '{print $1}' | grep '^@rpath/' | sed 's|^@rpath/||' | while read -r dep; do
        [ "$dep" = "$(basename "$1")" ] || need_library "$dep"
    done
}

for p in $PLUGINS; do
    from="$ROOT/lib/gstreamer-1.0/libgst$p.dylib"
    [ -f "$from" ] || { echo "plugin not found: $p" >&2; exit 1; }
    to="$DIST/lib/gstreamer-1.0/libgst$p.dylib"
    thin "$from" "$to"
    # The plugins already search "@loader_path/..", which is the engine's lib folder here.
    dependencies "$to"
done
# The libraries Wine itself links to, with the plain names the linker looks for.
for lib in gstreamer gstbase gstvideo gstaudio gsttag; do
    need_library "lib$lib-1.0.0.dylib"
    ln -sf "lib$lib-1.0.0.dylib" "$DIST/lib/lib$lib-1.0.dylib"
done
for lib in gobject glib; do
    need_library "lib$lib-2.0.0.dylib"
    ln -sf "lib$lib-2.0.0.dylib" "$DIST/lib/lib$lib-2.0.dylib"
done
# The helper GStreamer starts to look at plugins, so a broken plugin cannot take a game down.
thin "$ROOT/libexec/gstreamer-1.0/gst-plugin-scanner" "$DIST/libexec/gstreamer-1.0/gst-plugin-scanner"
chmod 755 "$DIST/libexec/gstreamer-1.0/gst-plugin-scanner"
install_name_tool -add_rpath "@loader_path/../../lib" "$DIST/libexec/gstreamer-1.0/gst-plugin-scanner" 2>/dev/null || true
dependencies "$DIST/libexec/gstreamer-1.0/gst-plugin-scanner"

# What build-engine.sh hands to Wine's configure.
cat > "$WORK/gstreamer-env.sh" <<EOF
export GSTREAMER_CFLAGS="-I$DEV/include/gstreamer-1.0 -I$DEV/include/glib-2.0 -I$DEV/lib/glib-2.0/include -I$DEV/include/orc-0.4"
export GSTREAMER_LIBS="-L$DIST/lib -lgstvideo-1.0 -lgstaudio-1.0 -lgsttag-1.0 -lgstbase-1.0 -lgstreamer-1.0 -lgobject-2.0 -lglib-2.0"
EOF

echo "plugins:   $(ls "$DIST/lib/gstreamer-1.0" | wc -l | tr -d ' ')"
echo "libraries: $(wc -l < "$SEEN" | tr -d ' ')"
du -sh "$DIST/lib/gstreamer-1.0" | cut -f1
# Self-test: an x86_64 GStreamer tool must find the elements Wine asks for, using the engine alone.
mkdir -p "$WORK/test"
thin "$ROOT/bin/gst-inspect-1.0" "$WORK/test/gst-inspect-1.0"
chmod 755 "$WORK/test/gst-inspect-1.0"
install_name_tool -add_rpath "$DIST/lib" "$WORK/test/gst-inspect-1.0" 2>/dev/null || true
rm -f "$WORK/registry.bin"
for element in decodebin videoconvert audioconvert audioresample deinterlace videoflip qtdemux h264parse avdec_h264 vtdec; do
    if GST_PLUGIN_SYSTEM_PATH="$DIST/lib/gstreamer-1.0" GST_PLUGIN_PATH= GST_REGISTRY="$WORK/registry.bin" \
       GST_PLUGIN_SCANNER="$DIST/libexec/gstreamer-1.0/gst-plugin-scanner" \
       arch -x86_64 "$WORK/test/gst-inspect-1.0" --exists "$element"; then echo "  ok       $element"
    else echo "  MISSING  $element"; fi
done

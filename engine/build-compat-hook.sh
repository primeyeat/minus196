#!/bin/bash
# Builds -196's start-up hook (compat-hook/minus196_compat.c) and installs it where the engine's
# ntdll looks for it. The file name cxcompatdb.so is fixed by the Wine source.
# Usage: engine/build-compat-hook.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"
OUT="$DIST/lib/wine/x86_64-unix/cxcompatdb.so"
clang -arch x86_64 -O2 -Wall -dynamiclib -o "$OUT" "$HERE/compat-hook/minus196_compat.c"
file "$OUT" | cut -c1-140

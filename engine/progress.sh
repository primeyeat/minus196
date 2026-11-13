#!/bin/bash
# Live progress bar for the Wine engine build.
# Progress = lines of build output so far / estimated total lines (from a `make -n` dry run,
# stored in progress.total). It is an estimate: steps differ a lot in how long they take.
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build-${1:-cx-26.3}"
OUT="$BUILD/make.out"
TOTAL=$(cat "$BUILD/progress.total" 2>/dev/null || echo 0)
[ -f "$OUT" ] && [ "$TOTAL" -gt 0 ] || { echo "no build in progress at $BUILD"; exit 1; }
WIDTH=$(( $(tput cols 2>/dev/null || echo 80) / 3 )); [ "$WIDTH" -gt 40 ] && WIDTH=40
START=$(date +%s)
FIRST=$(wc -l < "$OUT")
while true; do
    DONE=$(wc -l < "$OUT")
    PCT=$(( DONE * 100 / TOTAL )); [ "$PCT" -gt 100 ] && PCT=100
    FILL=$(( PCT * WIDTH / 100 ))
    BAR=$(printf '%*s' "$FILL" '' | tr ' ' '#')$(printf '%*s' $(( WIDTH - FILL )) '' | tr ' ' '.')
    ELAPSED=$(( $(date +%s) - START ))
    ETA="--"
    if [ "$ELAPSED" -gt 20 ] && [ "$DONE" -gt "$FIRST" ]; then
        LEFT=$(( (TOTAL - DONE) * ELAPSED / (DONE - FIRST) )); [ "$LEFT" -lt 0 ] && LEFT=0
        ETA="$(( LEFT / 60 ))m $(( LEFT % 60 ))s"
    fi
    NOW=$(grep -oE '(dlls|programs|server|loader|libs|tools|nls|fonts|po)/[A-Za-z0-9_.+-]+' "$OUT" | tail -1)
    COLS=$(tput cols 2>/dev/null || echo 80)
    LINE=$(printf '[%s] %3d%%  about %s left  %s' "$BAR" "$PCT" "$ETA" "$NOW")
    # Never wider than the terminal, or the line wraps and stops redrawing in place.
    printf '\r\033[K%s' "${LINE:0:$(( COLS - 1 ))}"
    if grep -q '^make exit=' "$OUT"; then
        printf '\n%s\n' "$(grep '^make exit=' "$OUT")"
        ERR=$(grep -c 'error:' "$OUT")
        [ "$ERR" -gt 0 ] && echo "$ERR error lines in $OUT"
        exit 0
    fi
    sleep 2
done

#!/usr/bin/env bash
# Regression check for #78 (the editor opening scrolled sideways, its first columns under the
# line-number gutter). Runs a Debug Runlet.app hidden with scratch data and RUNLET_DEBUG_STEPS,
# with soft wrap off and lines wider than the editor:
#   1. a fresh launch loads a 120-line file (the gutter widens past 99 lines) into the first
#      tab, then a shorter one into a new tab;
#   2. a second launch restores both tabs, switches between them, and changes the tab layout
#      and the window size.
# After each change the `editor-scroll` step prints every loaded editor's horizontal offset
# from its leading edge; the check fails unless all of them are 0.
#
# Usage: scripts/check-editor-scroll.sh <Debug Runlet.app>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: $0 <Debug Runlet.app>}"
SCRATCH="$ROOT/build/check-editor-scroll"
rm -rf "$SCRATCH" && mkdir -p "$SCRATCH/data"

LONG_LINE='$message = "This statement is long enough to run past the right edge of the editor when soft wrap is off.";'
{ echo '<?php'; echo; echo "$LONG_LINE"; for i in $(seq 120); do echo "\$value$i = $i * 2;"; done; } > "$SCRATCH/long.php"
{ echo '<?php'; echo; echo "$LONG_LINE"; echo 'echo $message;'; } > "$SCRATCH/short.php"

FRESH="ghost,frame:1200x720,wait,code:$SCRATCH/long.php,wait,editor-scroll,perform:file.newTab,wait,code:$SCRATCH/short.php,wait,editor-scroll"
RESTORE="ghost,frame:1200x720,wait,editor-scroll,select:Tab 1,wait,editor-scroll,tabs:vertical,wait,editor-scroll,frame:900x600,wait,editor-scroll,select:Tab 2,wait,editor-scroll"

failed=0
for run in fresh restore; do
    log="$SCRATCH/$run.log"
    steps="$FRESH"
    [[ "$run" == restore ]] && steps="$RESTORE"
    timeout 90 open -g -j -n -W --env RUNLET_DATA_DIR="$SCRATCH/data" --env RUNLET_DEBUG_STEPS="$steps" \
        --env SSH_AUTH_SOCK= --stderr "$log" "$APP" || true
    checks="$(grep -c 'RUNLET_DEBUG_STATE: editor-scroll ' "$log" || true)"
    offsets="$(grep 'RUNLET_DEBUG_STATE: editor-scroll ' "$log" | grep -o 'offset=[-0-9.]*' | sort -u | tr '\n' ' ' || true)"
    if grep -q "RUNLET_DEBUG_STEPS: done" "$log" && [[ "$checks" -gt 0 && "$offsets" == "offset=0.0 " ]]; then
        echo "$run: ok ($checks checks)"
    else
        echo "$run: FAILED (offsets: ${offsets:-none}), see $log" >&2
        failed=1
    fi
done
exit "$failed"

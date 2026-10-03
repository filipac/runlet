#!/usr/bin/env bash
# Regression check for #92 (a crash opening Install Command-Line Tool from Settings). Runs a
# Debug Runlet.app hidden with scratch data and RUNLET_DEBUG_STEPS: opens Settings ▸ General,
# presses Install…, lets the window settle (the shell's PATH arrives and its texts change),
# opens it again from the menu command, and checks that Runlet finished its steps with the
# window open. Each run is repeated with a scratch folder preselected (RUNLET_DEBUG_CLI_FOLDER;
# it isn't on PATH, so its hint wraps and the window grows). Nothing is ever installed.
#
# Usage: scripts/check-cli-window.sh <Debug Runlet.app> [runs, default 3]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: $0 <Debug Runlet.app> [runs]}"
RUNS="${2:-3}"
SCRATCH="$ROOT/build/check-cli-window"
rm -rf "$SCRATCH" && mkdir -p "$SCRATCH/data" "$SCRATCH/folder"
STEPS="ghost,settings,wait,settings-tab:General,wait,press:settings-cli-install,wait,wait,wait,state,perform:app.installCommandLineTool,wait,state"

failed=0
for run in $(seq "$RUNS"); do
    for folder in "" "$SCRATCH/folder"; do
        log="$SCRATCH/run-$run${folder:+-folder}.log"
        timeout 90 open -g -j -n -W --env RUNLET_DATA_DIR="$SCRATCH/data" --env RUNLET_DEBUG_STEPS="$STEPS" \
            ${folder:+--env RUNLET_DEBUG_CLI_FOLDER="$folder"} --env SSH_AUTH_SOCK= --stderr "$log" "$APP" || true
        if grep -q "RUNLET_DEBUG_STEPS: done" "$log" && [[ "$(grep -c '"Command-Line Tool:' "$log")" == 2 ]]; then
            echo "run $run${folder:+ (scratch folder)}: ok"
        else
            echo "run $run${folder:+ (scratch folder)}: FAILED, see $log" >&2
            failed=1
        fi
    done
done
exit "$failed"

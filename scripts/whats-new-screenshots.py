#!/usr/bin/env python3
"""#232: screenshots of the guided tour, What's New, and a Show Me tour, from a Debug app with
scratch data and neutral content only.

Usage: whats-new-screenshots.py /path/to/Runlet.app /path/to/output [scratch folder]

The scratch RUNLET_DATA_DIR (default build/runlet-p232 in the repository) starts empty, so the
window shows the bundled sandbox and a neutral snippet; nothing runs, connects, or opens a
project. Runlet stays in the background (`ghost`), and the steps print the tour's and the
window's state, which this script checks. Writes, for light and dark:
- tour-<appearance>.png: the first-launch tour's second stop, pointing at Run;
- whats-new-<appearance>.png: What's New after updating from 0.4.0 beta 7 (beta 8's entries);
- whats-new-since-030-<appearance>.png: What's New after updating from 0.3.0;
- show-me-<appearance>.png: Dry Run's Show Me tour, pointing at the toolbar button.
"""
from pathlib import Path
import shutil
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
root = Path(__file__).resolve().parent.parent
scratch = Path(sys.argv[3]).resolve() if len(sys.argv) > 3 else root / "build/runlet-p232"
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
scratch.mkdir(parents=True)
snippet = scratch / "orders.php"
snippet.write_text("""<?php
$orders = collect([
    ['id' => 1041, 'total' => 120.50, 'status' => 'shipped'],
    ['id' => 1042, 'total' => 89.90, 'status' => 'paid'],
    ['id' => 1043, 'total' => 42.00, 'status' => 'paid'],
]);

$orders->where('status', 'paid')->sum('total');
""")


def launch(name, steps):
    log = out / f"{name}.log"
    env = ["--env", f"RUNLET_DATA_DIR={scratch / name}", "--env", f"RUNLET_SNAPSHOT_DIR={out}", "--env", "SSH_AUTH_SOCK=",
           "--env", "RUNLET_CREDENTIALS=memory", "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}"]
    subprocess.run(["open", "-g", "-j", "-n", "-W"] + env + ["--stderr", str(log), str(app)], check=True, timeout=600)
    text = log.read_text()
    assert "RUNLET_DEBUG_STEPS: done" in text, text[-3000:]
    return [line for line in text.splitlines() if line.startswith("RUNLET_DEBUG_STATE")]


for appearance in ["light", "dark"]:
    start = ["ghost", "scale:2", f"appearance:{appearance}", "frame:1180x720", "wait", f"code:{snippet}", "caret:end", "wait"]
    states = launch(f"shots-{appearance}", start + [
        "tour:start", "wait", "tour:next", "wait", "tour-state", f"shot:tour-{appearance}", "tour:skip",
        "whats-new:show:since=0.4.0+13", "frame:What's New=720x620", "wait", "whats-new-state", f"shot:whats-new-{appearance}@What's New",
        "whats-new:show:since=0.3.0+6", "frame:What's New=720x860", "wait", "whats-new-state", f"shot:whats-new-since-030-{appearance}@What's New",
        "whats-new:show-me:dry-run", "wait", "tour-state", f"shot:show-me-{appearance}", "tour:skip", "wait", "whats-new-state",
    ])
    print("\n".join(states))
    tour = [s for s in states if s.startswith("RUNLET_DEBUG_STATE: tour ")]
    assert '"Write PHP and run it" pointing at run-button (below)' in tour[0], tour
    assert '"Turn on Dry Run" pointing at dry-run-toggle (below)' in tour[1], tour
    windows = [s for s in states if "whats-new visible" in s]
    assert 'subtitle="Since 0.4.0 beta 7"' in windows[0] and "0.4.0 beta 8 [14]" in windows[0], windows
    assert 'subtitle="Since 0.3.0"' in windows[1] and "0.4.0 beta 8 [14,13,12,11,10,9,8,7]" in windows[1], windows
    # Show Me puts What's New aside, and brings it back when the tour ends.
    assert "visible=true" in windows[2], windows
print(f"Screenshots in {out}")

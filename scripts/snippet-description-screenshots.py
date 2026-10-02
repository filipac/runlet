#!/usr/bin/env python3
"""#52: capture native description UI from a Debug app using scratch data only.

Usage: snippet-description-screenshots.py /path/to/Runlet.app /path/to/output
Uses existing RUNLET_DEBUG_STEPS and AppKit snapshots; never executes snippet code.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="runlet-snippet-preview-") as scratch:
    state = Path(scratch) / "State"
    state.mkdir()
    def save(name, data):
        (state / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": 0, "data": data}))
    now = time.time() - 978307200
    code = "collect([\n    ['order' => 'A104', 'total' => 48],\n    ['order' => 'A105', 'total' => 72],\n])->sortByDesc('total')->values();"
    def snippet(label, description, code):
        data = dict(id=str(uuid.uuid4()).upper(), label=label, code=code, createdAt=now, updatedAt=now)
        if description:
            data['description'] = description
        return data
    save("snippets", [
        snippet("Recent orders", "Pending shipments, newest first. Use this to review orders before the daily dispatch.", code),
        snippet("Monthly totals", "Reconcile invoice totals for the current month.", "collect([48, 72, 120])->sum();"),
        snippet("Quick scratch", None, "now()->toDateString();"),
    ])
    save("settings", {"appearance": "light", "libraryPanelWidth": 350, "fontSize": 14})
    save("session", {"tabs": [{"id": str(uuid.uuid4()).upper(), "title": "Order lookup", "code": code,
         "target": {"sandbox": {}}, "selection": {"location": 0, "length": 0}, "createdAt": now}]})
    steps = ",".join([
        "ghost", "frame:1200x780", "appearance:light", "inspector:snippets", "wait",
        "shot:personal-snippet-descriptions-light", "appearance:dark", "wait",
        "shot:personal-snippet-descriptions-dark", "search:snippet-search|shipments", "wait",
        "press:snippet-edit-button", "wait", "shot:personal-snippet-descriptions-edit-dark",
    ])
    # macOS open --stderr appends; validate only this capture.
    (out / "capture.log").write_text("")
    subprocess.run(["open", "-g", "-j", "-n", "-W",
        "--env", f"RUNLET_DATA_DIR={scratch}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
        "--env", f"RUNLET_DEBUG_STEPS={steps}", "--stderr", str(out / "capture.log"), str(app)], check=True)
    log = (out / "capture.log").read_text()
    assert "RUNLET_DEBUG_STEPS: done" in log
    assert "not found" not in log and "unavailable" not in log, log
    edit = log.split("shot personal-snippet-descriptions-edit-dark.png")[1].splitlines()[0]
    assert "overlays=[]" not in edit, "The edit sheet was not captured: " + edit

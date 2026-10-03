#!/usr/bin/env python3
"""#9: native timing screenshots using a Debug app, scratch data, and explicit sandbox Run.
Usage: timing-screenshots.py /path/to/Runlet.app /path/to/output
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="runlet-timing-preview-") as scratch:
    state = Path(scratch) / "State"
    state.mkdir()
    def save(name, data):
        (state / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": 0, "data": data}))
    code = "usleep(125000);\n\nDB::select('select 1 as number');\n\ncollect([2, 4, 6])->sum();"
    save("settings", {"appearance": "light", "fontSize": 14})
    save("session", {"tabs": [{"id": str(uuid.uuid4()).upper(), "title": "Timing breakdown", "code": code,
         "target": {"sandbox": {}}, "selection": {"location": 0, "length": 0}, "createdAt": 0}]})
    steps = ",".join(["ghost", "frame:1200x780", "appearance:light", "run", "wait", "wait", "wait",
                      "shot:run-timings-light", "appearance:dark", "wait", "shot:run-timings-dark"])
    log_path = out / "capture.log"
    log_path.write_text("")
    subprocess.run(["open", "-g", "-j", "-n", "-W", "--env", f"RUNLET_DATA_DIR={scratch}",
        "--env", f"RUNLET_SNAPSHOT_DIR={out}", "--env", f"RUNLET_DEBUG_STEPS={steps}",
        "--stderr", str(log_path), str(app)], check=True)
    assert "RUNLET_DEBUG_STEPS: done" in log_path.read_text()
    for name in ["run-timings-light.png", "run-timings-dark.png"]:
        assert (out / name).is_file(), name

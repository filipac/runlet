#!/usr/bin/env python3
"""#7: real string viewers with scratch state and explicit sandbox runs.
Usage: string-viewer-screenshots.py /path/to/Runlet.app /path/to/output [json text svg html]
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
svg = """<svg xmlns="http://www.w3.org/2000/svg"
     width="460" height="240">
  <rect width="460" height="240" rx="18"
        fill="#167d8d"/>
  <circle cx="100" cy="120" r="58" fill="#e9ca72"/>
  <text x="180" y="130" fill="white"
        font-family="sans-serif" font-size="32">
    Runlet preview
  </text>
</svg>"""
json_code = """return json_encode([
    'name' => 'Widget',
    'status' => 'ready',
    'items' => [
        ['id' => 1, 'stock' => 12],
        ['id' => 2, 'stock' => 8],
    ],
    'cached' => true,
]);"""
text_code = '$line = "Widget status is ready. ";\n$line .= "Shipment is scheduled for tomorrow.\\n";\nreturn str_repeat($line, 30);'
html_code = """return <<<'HTML'
<h1 style="color:#167d8d">Order confirmed</h1>
<p>Your Widget shipment is ready.</p>
<table style="border-spacing:18px">
  <tr><th>Item</th><th>Quantity</th></tr>
  <tr><td>Widget</td><td>12</td></tr>
</table>
HTML;"""
cases = [
    ("json", "API response", json_code, ["segment:JSON"], ["light", "dark"]),
    ("text", "Response body", text_code, ["search:string-search|Widget"], ["light"]),
    ("svg", "Encoded image", "// An SVG returned as base64.\nreturn base64_encode(<<<'SVG'\n" + svg + "\nSVG);", [], ["dark"]),
    ("html", "HTML response", html_code, ["segment:Preview"], ["light"]),
]
selected = set(sys.argv[3:]) or {case[0] for case in cases}
for kind, title, code, actions, appearances in cases:
    if kind not in selected:
        continue
    with tempfile.TemporaryDirectory(prefix="runlet-string-viewer-") as scratch:
        state = Path(scratch) / "State"
        state.mkdir()
        def save(name, data):
            (state / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": 0, "data": data}))
        save("settings", {"appearance": appearances[0], "fontSize": 14, "valueExpansion": "all"})
        save("session", {"tabs": [{"id": str(uuid.uuid4()).upper(), "title": title, "code": code,
             "target": {"sandbox": {}}, "selection": {"location": 0, "length": 0}, "createdAt": 0}]})
        steps = ["ghost", "frame:1200x780", f"appearance:{appearances[0]}", "run", "wait", "wait", "wait"] + actions + ["wait"]
        for appearance in appearances:
            steps += [f"appearance:{appearance}", "wait", f"shot:string-viewer-{kind}-{appearance}"]
        log = out / f"{kind}.log"
        log.write_text("")
        subprocess.run(["open", "-g", "-j", "-n", "-W", "--env", f"RUNLET_DATA_DIR={scratch}",
            "--env", f"RUNLET_SNAPSHOT_DIR={out}", "--env", "RUNLET_DEBUG_STEPS=" + ",".join(steps),
            "--stderr", str(log), str(app)], check=True)
        output = log.read_text()
        assert "RUNLET_DEBUG_STEPS: done" in output, output
        assert "not found" not in output and "unavailable" not in output, output
        for appearance in appearances:
            assert (out / f"string-viewer-{kind}-{appearance}.png").is_file()
        print(f"Captured {kind}", flush=True)

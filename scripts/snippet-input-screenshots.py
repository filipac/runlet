#!/usr/bin/env python3
"""#14: parameterised snippets end to end in a Debug app, with scratch data only.

Usage: snippet-input-screenshots.py /path/to/Runlet.app /path/to/output

Seeds a scratch RUNLET_DATA_DIR (personal snippets, a session) and a scratch project with
`.runlet/snippets/` inside the output folder, then drives the app with RUNLET_DEBUG_STEPS:
the Snippets panel, the input form, the new tab with the values at the top (nothing runs),
an explicit run of that tab, a form with an unreadable declaration and a validation error,
Cancel (nothing opens), and a snippet whose code would write a file, opened but never run.
Screenshots go to the output folder, without the window's status bar (before a run it shows
the scratch project's full path); the scratch data is removed afterwards. Needs Xcode's swift
for the crop.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
scratch = out / "scratch"
shutil.rmtree(scratch, ignore_errors=True)
state = scratch / "data" / "State"
state.mkdir(parents=True)
project = scratch / "shop"
(project / ".runlet" / "snippets").mkdir(parents=True)
marker = scratch / "probe-ran.txt"

(project / ".runlet" / "snippets" / "refund-order.php").write_text('''<?php
/**
 * @label Refund order
 * @description Refunds an order and records why. Support runbook.
 * @input int $orderId "Order ID"
 * @input float $amount "Amount" = 19.99
 * @input string $reason "Reason" = "duplicate" {duplicate, fraudulent, requested_by_customer}
 * @input string $note "Internal note"
 * @input bool $notify "Email the customer" = true
 */

$order = ['id' => $orderId, 'total' => 49.90, 'status' => 'paid'];

$refund = [
    'order' => $order['id'],
    'amount' => min($amount, $order['total']),
    'reason' => $reason,
    'note' => $note,
    'notify' => $notify,
];

$refund;
''')
(project / ".runlet" / "snippets" / "recent-orders.php").write_text('''<?php
/**
 * @label Recent orders
 * @description The newest orders first.
 */

[['id' => 1042, 'total' => 49.90], ['id' => 1041, 'total' => 12.00]];
''')


def save(name, data):
    (state / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": 0, "data": data}))


now = time.time() - 978307200


def snippet(label, code, description=None):
    data = dict(id=str(uuid.uuid4()).upper(), label=label, code=code, createdAt=now, updatedAt=now)
    if description:
        data["description"] = description
    return data


save("snippets", [
    snippet("Find user", '/**\n * @input int $userId "User ID"\n * @input integer $limit "Limit"\n */\n'
            '$user = ["id" => $userId, "name" => "Ada"];\n$user;', "Looks a user up by id."),
    snippet("Write probe", '/** @input string $path "File" */\nfile_put_contents($path, "ran");'),
    snippet("Greeting", '"Hello, " . "world";', "No inputs: opens as before."),
])
save("settings", {"appearance": "light", "libraryPanelWidth": 360, "fontSize": 13, "libraryOpenBehavior": "newTab"})
save("session", {"tabs": [{"id": str(uuid.uuid4()).upper(), "title": "Tab 1", "code": "",
                           "target": {"sandbox": {}}, "selection": {"location": 0, "length": 0}, "createdAt": now}]})

steps = [
    "ghost", "scale:2", "frame:1200x760", "appearance:light", f"project:{project}",
    "inspector:snippets", "wait",
    # The form, filled in; the note shows a quote and a dollar sign being escaped.
    "snippet-open:Refund order", "wait",
    "snippet-input:orderId=1042", "snippet-input:amount=12.5", "snippet-input:reason=fraudulent",
    "snippet-input:note=O'Neil's card was charged twice ($49.90)", "snippet-inputs:state", "wait",
    "shot:snippet-inputs-form",
    "snippet-inputs:open", "wait", "snippet-tab", "shot:snippet-inputs-tab",
    # Only an explicit run runs it.
    "run", "wait-run", "wait", "snippet-tab", "shot:snippet-inputs-run",
    # A declaration that can't be read, and a value that isn't an int; Cancel opens nothing.
    "appearance:dark", "snippet-open:Find user", "wait", "snippet-input:userId=12a", "snippet-inputs:state", "wait",
    "shot:snippet-inputs-invalid-dark", "snippet-inputs:cancel", "wait", "snippet-tab",
    # Opening a snippet whose code writes a file only loads it.
    "snippet-open:Write probe", "wait", f"snippet-input:path={marker}", "snippet-inputs:open", "wait", "snippet-tab",
]
log_path = out / "capture.log"
log_path.write_text("")
subprocess.run(["open", "-g", "-j", "-n", "-W",
                "--env", f"RUNLET_DATA_DIR={scratch / 'data'}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                "--stderr", str(log_path), str(app)], check=True)
log = log_path.read_text()
tabs = [line for line in log.splitlines() if "RUNLET_DEBUG_STATE: snippet-" in line]
print("\n".join(tabs))
assert "RUNLET_DEBUG_STEPS: done" in log, log
for problem in ["no snippet labelled", "can't set", "no input form", "not valid", "not found", "unavailable"]:
    assert problem not in log, problem
opened, ran, cancelled, probe = [line for line in tabs if "snippet-tab:" in line]
assert "ran=never" in opened and "history=0" in opened, opened
assert "$orderId = 1042;\\n$amount = 12.5;\\n$reason = 'fraudulent';\\n$note = 'O\\'Neil\\'s card was charged twice ($49.90)';\\n$notify = true;\\n\\n$order = " in opened, opened
assert "ran=never" not in ran and "history=1" in ran and "fraudulent" in ran, ran
assert "tabs=2" in cancelled and "history=1" in cancelled, cancelled
assert "title=Write probe" in probe and "ran=never" in probe and "history=1" in probe, probe
assert not marker.exists(), "Opening the probe ran it"

# The status bar is 26 points high (52 pixels at scale:2), with its divider.
crop = scratch / "crop.swift"
crop.write_text("""import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: image.height - 52))!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, cropped, CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
    CGImageDestinationFinalize(destination)
}
""")
shots = sorted(out.glob("snippet-inputs-*.png"))
subprocess.run(["swift", str(crop)] + [str(p) for p in shots], check=True)
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

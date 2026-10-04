#!/usr/bin/env python3
"""#22: PHPantom navigation screenshots and checks from a Debug app with scratch data.

Copies the `laravel-app` fixture to a scratch folder under /private/tmp and opens one PHP tab on
it as a local project, then (second launch) as a Docker profile whose local folder is that copy,
with the fake Docker CLI. Nothing runs: Go to Definition, Find References, code actions, and
inlay hints only ask PHPantom. Project files are logged instead of opening an external editor
(`nav-host:log`). Prints the RUNLET_DEBUG_STATE lines.
Usage: navigation-screenshots.py /path/to/Runlet.app /path/to/output
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
fixture = root / "Tests/Fixtures/laravel-app"
fake_docker = root / "scripts/website-screenshots/fake-docker"
assert (fixture / "vendor/autoload.php").is_file(), "run scripts/setup-fixtures.sh"

CODE = """$formatter = new PriceFormatter();
$widget = App\\Models\\Widget::query()->first();
echo $formatter->format($widget->price);

function discount(int $cents, float $rate): int
{
    return (int) round($cents * (1 - $rate));
}

$total = discount(1999, 0.2);
$prices = array_map(fn ($p) => discount($p, 0.1), [500, 1250]);
echo discount($total, 0.05);
"""
now = time.time() - 978307200  # Foundation's reference date


def launch(name, target_kind, steps, shots):
    with tempfile.TemporaryDirectory(prefix="runlet-nav-", dir="/private/tmp") as scratch:
        project = Path(scratch) / "shop"
        subprocess.run(["cp", "-cR", str(fixture), str(project)], check=True)
        state = Path(scratch) / "State"
        state.mkdir()

        def save(file, data):
            (state / f"{file}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": now, "data": data}))

        local_id, docker_id = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
        # A custom editor command, so peeks offer Open in…; `nav-host:log` logs instead of running it.
        save("settings", {"appearance": "light", "fontSize": 14, "outputVisible": False, "dockerExecutable": str(fake_docker),
                          "externalEditor": "custom", "externalEditorCommand": "/usr/bin/true {file}:{line}"})
        save("targets", {
            "localProjects": [{"id": local_id, "name": "shop", "path": str(project), "revision": 1, "lastOpenedAt": now - 60}],
            "dockerProfiles": [{
                "id": docker_id, "name": "shop",
                "identity": {"composeProject": "acme-shop", "composeService": "app", "lastImage": "acme/shop-php:8.3"},
                "workingDirectory": "/var/www/html", "phpExecutable": "php", "temporaryDirectory": "/tmp",
                "localSourcePath": str(project), "autoResolve": False, "revision": 1, "lastOpenedAt": now - 120,
            }],
            "sshProfiles": [],
        })
        target = {"local": {"_0": local_id}} if target_kind == "local" else {"docker": {"_0": docker_id}}
        save("session", {"tabs": [{"id": str(uuid.uuid4()).upper(), "title": "Pricing", "code": CODE, "target": target,
                                   "selection": {"location": 0, "length": 0}, "createdAt": now}]})
        log_path = out / f"{name}.log"
        log_path.write_text("")
        subprocess.run(["open", "-g", "-j", "-n", "-W", "--env", f"RUNLET_DATA_DIR={scratch}",
                        "--env", f"RUNLET_SNAPSHOT_DIR={out}", "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}",
                        "--env", "SSH_AUTH_SOCK=", "--stderr", str(log_path), str(app)], check=True)
        log = log_path.read_text()
        assert "RUNLET_DEBUG_STEPS: done" in log, log[-2000:]
        for line in log.splitlines():
            if line.startswith("RUNLET_DEBUG_STATE") or line.startswith("RUNLET_DEBUG_STEPS: nav-") or not line.startswith("RUNLET_"):
                print(line)
        for shot in shots:
            assert (out / f"{shot}.png").is_file(), shot


start = ["ghost", "scale:2", "frame:1180x660", "appearance:light", "nav-wait:ready:90", "nav-host:log"]
launch("local", "local", start + [
    # Inlay hints: parameter names before arguments, a type before an arrow function's parameter.
    "nav-wait:hints:30", "caret:12:1", "wait", "nav-state", "shot:nav-inlay-hints",
    # Go to Definition on `query()`: Eloquent's Model.php, in vendor/, peeked read-only.
    "nav-definition:2:32", "nav-wait:done", "wait", "nav-state", "shot:nav-definition-vendor-peek", "nav-close",
    # On `Widget`: a project file, which opens in the external editor at its line (logged here).
    "nav-click:2:23", "nav-wait:done", "nav-state",
    # On `discount(` in the tab: the caret moves to the function.
    "nav-definition:10:12", "nav-wait:done", "nav-state",
    # Find References on `discount`.
    "nav-references:5:12", "nav-wait:done", "wait", "nav-state", "shot:nav-references", "nav-choose:3", "wait", "nav-state",
    # Code actions on `PriceFormatter`: Import class, applied to the tab only, one undo step.
    "nav-actions:1:20", "nav-wait:done", "wait", "nav-state", "shot:nav-code-actions",
    "nav-choose:0", "nav-wait:done", "wait", "nav-state", "shot:nav-import-applied", "nav-undo", "wait", "nav-state",
    "nav-menu:2:23",
], ["nav-inlay-hints", "nav-definition-vendor-peek", "nav-references", "nav-code-actions", "nav-import-applied"])

launch("docker", "docker", start + [
    # A Docker profile with a local folder: the peek says where the container sees the file.
    "nav-wait:hints:30", "appearance:dark", "wait", "nav-definition:2:32", "nav-wait:done", "wait", "nav-state", "shot:nav-peek-docker-dark",
    "nav-close", "caret:12:1", "wait", "shot:nav-inlay-hints-dark",
], ["nav-peek-docker-dark", "nav-inlay-hints-dark"])

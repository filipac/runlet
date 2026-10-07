#!/usr/bin/env python3
"""#336: the status bar's PHPantom item and its popover, from a Debug app with scratch data.

Copies the `laravel-app` fixture to `build/phpantom-status/home/Sites/shop` and opens one PHP
tab on a Docker profile whose local folder is that copy, with the fake Docker CLI: the status bar
then names the container's folder, not a path on this Mac, and `RUNLET_DEBUG_HOME` makes the
popover's folder read `~/Sites/shop`. Nothing runs: PHPantom only indexes the copy.

Checks, from the RUNLET_DEBUG_STATE lines it prints:
- PHPantom registers its file watchers once its first index is done;
- a class file written after startup reaches PHPantom (`sent=` counts it), without a restart;
- Reindex Project restarts the server, which registers its watchers again.

Shots, light and dark: the item while indexing (made-up progress: on a small project it lasts a
second), its popover then, and the popover once ready.
Usage: phpantom-status-screenshots.py /path/to/Runlet.app /path/to/output
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
fixture = root / "Tests/Fixtures/laravel-app"
fake_docker = root / "Tests/Fixtures/fake-docker/docker"
assert (fixture / "vendor/autoload.php").is_file(), "run scripts/setup-fixtures.sh"

CODE = """$widget = App\\Models\\Widget::query()->first();
$formatter = new App\\Services\\PriceFormatter();
echo $formatter->format($widget->price);
"""
now = time.time() - 978307200  # Foundation's reference date

scratch = root / "build/phpantom-status"
shutil.rmtree(scratch, ignore_errors=True)
home = scratch / "home"
project = home / "Sites/shop"
project.parent.mkdir(parents=True)
subprocess.run(["cp", "-cR", str(fixture), str(project)], check=True)
data = scratch / "data"
state = data / "State"
state.mkdir(parents=True)


def save(file, value):
    (state / f"{file}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": now, "data": value}))


docker_id = str(uuid.uuid4()).upper()
save("settings", {"appearance": "light", "fontSize": 14, "outputVisible": False, "dockerExecutable": str(fake_docker)})
save("targets", {"localProjects": [], "sshProfiles": [], "dockerProfiles": [{
    "id": docker_id, "name": "shop",
    "identity": {"composeProject": "acme-shop", "composeService": "app", "lastImage": "acme/shop-php:8.3"},
    "workingDirectory": "/var/www/html", "phpExecutable": "php", "temporaryDirectory": "/tmp",
    "localSourcePath": str(project), "autoResolve": False, "revision": 1, "lastOpenedAt": now - 60,
}]})
save("session", {"tabs": [{"id": str(uuid.uuid4()).upper(), "title": "Prices", "code": CODE, "target": {"docker": {"_0": docker_id}},
                           "selection": {"location": 0, "length": 0}, "createdAt": now}]})

new_class = project / "app/Services/InvoiceTotals.php"
progress = "language-progress:42|Scanning vendor packages (1204/2867 files)"
steps = [
    "ghost", "scale:2", "frame:1040x520", "appearance:light", "nav-wait:ready:90", "language-state", "wait", "wait", "language-state",
    # Ready: the popover lists the folder, the last index, and the watched files.
    "language-popover:on", "wait", "shot:phpantom-popover-light",
    "appearance:dark", "wait", "shot:phpantom-popover-dark", "language-popover:off",
    # Indexing (made up, see the docstring): the item shows the percentage, the popover the message.
    "appearance:light", progress, "wait", "language-state", "shot:phpantom-indexing-light",
    "language-popover:on", "wait", "shot:phpantom-indexing-popover-light",
    "appearance:dark", "wait", "shot:phpantom-indexing-popover-dark", "language-popover:off", "language-progress:off",
    # A class written after startup reaches PHPantom, as a branch switch's files would.
    f"replace:{new_class}|<?php\\nnamespace App\\Services;\\n\\nclass InvoiceTotals\\n{{\\n}}\\n", "wait", "language-state",
    # Reindex Project restarts PHPantom, which watches again once it has indexed.
    "perform:library.reindexProject", "wait", "language-state", "nav-wait:ready:90", "wait", "wait", "language-state",
]
log_path = out / "phpantom-status.log"
log_path.write_text("")
# A hidden launch (-j) sometimes gets no window (#332): RUNLET_CHECK_VISIBLE_LAUNCH=1 drops -j;
# `ghost` still keeps the windows invisible and click-through, and -g keeps Runlet inactive.
hidden = [] if os.environ.get("RUNLET_CHECK_VISIBLE_LAUNCH") == "1" else ["-j"]
subprocess.run(["open", "-g", *hidden, "-n", "-W", "--env", f"RUNLET_DATA_DIR={data}", "--env", f"RUNLET_DEBUG_HOME={home}",
                "--env", f"RUNLET_SNAPSHOT_DIR={out}", "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}",
                "--env", "SSH_AUTH_SOCK=", "--stderr", str(log_path), str(app)], check=True)
log = log_path.read_text()
assert "RUNLET_DEBUG_STEPS: done" in log, log[-2000:]
states = [line for line in log.splitlines() if line.startswith("RUNLET_DEBUG_STATE: language-state")]
for line in states:
    print(line)
assert any("watched=[**/*.php" in line for line in states), "PHPantom never registered its watchers"
assert any("item=\"Indexing… 42%\"" in line for line in states), "the item didn't show the progress"
assert any("sent=1 changes" in line or "sent=2 changes" in line for line in states), "the new class never reached PHPantom"
for shot in ["phpantom-popover-light", "phpantom-popover-dark", "phpantom-indexing-light", "phpantom-indexing-popover-light", "phpantom-indexing-popover-dark"]:
    assert (out / f"{shot}.png").is_file(), shot
print("ok")

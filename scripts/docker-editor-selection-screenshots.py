#!/usr/bin/env python3
"""#318: a click on a running container always becomes the Docker profile's container.

Usage: docker-editor-selection-screenshots.py /path/to/Runlet.app /path/to/output

Checks New Docker Profile (the sheet) and the Profiles window's new profile in a hidden Debug
app: clicks the runlet-fixtures services laravel, then restricted, then postgres (posted mouse
clicks on the list's rows, through the `docker-editor:` DEBUG steps), and asserts after each
click that the profile's container, name, user, and working directory come from that row. Then
shoots both, light and dark. Scratch data only; the app runs `docker` through the fixtures-only
wrapper (Tests/Fixtures/docker/fixtures-only-docker), so only the fixture containers appear. A
saved profile "orders-api" uses the postgres service, so the form says it shares that container.
Needs `scripts/setup-fixtures.sh docker` (the runlet-fixtures containers running).
"""
import json
import re
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
NOW = time.time() - 978307200

CLICKS = [
    # container, then what the form must hold after the click
    ("runlet-fixtures-laravel-1", {"container": "runlet-fixtures/laravel", "name": "laravel", "user": "", "workingDirectory": "/var/www/html"}),
    ("runlet-fixtures-restricted-1", {"container": "runlet-fixtures/restricted", "name": "restricted", "user": "1000:1000", "workingDirectory": "/app"}),
    ("runlet-fixtures-postgres-1", {"container": "runlet-fixtures/postgres", "name": "postgres", "user": "", "workingDirectory": "/var/www/html"}),
]


def clicks() -> list[str]:
    steps = []
    for name, _ in CLICKS:
        steps += [f"docker-editor:click:{name}", "docker-editor:state"]
    return steps


def run(scratch: Path, steps: list[str]) -> str:
    data = scratch / "data"
    (data / "State").mkdir(parents=True)

    def save(name, value):
        (data / "State" / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": NOW, "data": value}))

    save("settings", {"dockerExecutable": str(ROOT / "Tests/Fixtures/docker/fixtures-only-docker"), "appearance": "light", "fontSize": 13,
                      "showTipsOnFirstLaunch": False, "showWhatsNewAfterUpdates": False, "automaticUpdateChecks": False,
                      "languageServiceEnabled": False, "notifyLongRuns": False})
    tab = str(uuid.uuid4()).upper()
    save("session", {"windows": [{"id": str(uuid.uuid4()).upper(), "selectedTabId": tab, "workspaceEdited": False, "tabs": [
        {"id": tab, "title": "Scratch", "code": "", "target": {"sandbox": {}}, "selection": {"location": 0, "length": 0}, "createdAt": NOW}]}]})
    save("targets", {"localProjects": [], "sshProfiles": [], "dockerProfiles": [
        {"id": str(uuid.uuid4()).upper(), "name": "orders-api", "identity": {"composeProject": "runlet-fixtures", "composeService": "postgres"},
         "workingDirectory": "/var/www/html", "phpExecutable": "php", "temporaryDirectory": "/tmp", "autoResolve": False, "revision": 1}]})
    log = scratch / "stderr.txt"
    subprocess.run(["open", "-g", "-j", "-n", "-W", "--env", f"RUNLET_DATA_DIR={data}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                    "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "RUNLET_CREDENTIALS=memory", "--env", "SSH_AUTH_SOCK=",
                    "--env", f"RUNLET_DEBUG_HOME={data}", "--stderr", str(log), str(app),
                    "--args", "-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"], check=True, timeout=600)
    return log.read_text()


def check(log: str, where: str) -> None:
    assert "RUNLET_DEBUG_STEPS: done" in log, log
    states = [line for line in log.splitlines() if "docker-editor-state:" in line]
    assert len(states) >= len(CLICKS), f"{where}: {len(states)} states\n{log}"
    for (name, expected), line in zip(CLICKS, states):
        fields = dict(re.findall(r'(\w+)=("[^"]*"|\S+)', line.split("docker-editor-state:", 1)[1]))
        fields = {key: value.strip('"') for key, value in fields.items()}
        assert fields["table"] == name and fields["highlighted"] == name, f"{where}: {name} isn't highlighted: {line}"
        for key, value in expected.items():
            assert fields[key] == value, f"{where}: after {name}, {key} is {fields[key]!r}, not {value!r}"
        assert fields["disagrees"] == "false", line
        print(f"{where}: {name} → {fields['container']}, name {fields['name']!r}, user {fields['user']!r}, {fields['workingDirectory']}")


with tempfile.TemporaryDirectory(prefix="runlet-318-") as scratch:
    log = run(Path(scratch) / "sheet", ["ghost", "scale:2", "frame:1000x800", "wait", "docker-editor:open-new", "wait", "wait"] + clicks()
              + ["wait", "shot:docker-sheet-light", "appearance:dark", "wait", "shot:docker-sheet-dark"])
    check(log, "sheet")
    log = run(Path(scratch) / "profiles", ["ghost", "scale:2", "wait", "docker-editor:profiles-new", "wait", "wait", "frame:Profiles=1100x760",
                                           "wait"] + clicks() + ["wait", "shot:docker-profiles-light@Profiles", "appearance:dark", "wait",
                                                                 "shot:docker-profiles-dark@Profiles"])
    check(log, "profiles")
for name in ["docker-sheet-light", "docker-sheet-dark", "docker-profiles-light", "docker-profiles-dark"]:
    assert (out / f"{name}.png").exists(), f"{name}.png is missing"
print(f"Screenshots in {out}")

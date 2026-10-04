#!/usr/bin/env python3
"""#184: connections from this Mac pick the first local PHP that has their driver, in a Debug app
with scratch data and neutral names only.

Usage: php-by-driver-screenshots.py /path/to/Runlet.app /path/to/output <scratch Runlet PHP folder> [/path/to/scratch]

<scratch Runlet PHP folder> holds `PHP/8.5.8-r3` from a scratch install (for example
`RUNLET_TEST_PHP_DOWNLOAD=<folder> swift test --filter installsThePinnedReleaseFromGitHub`); it is
copied into each scratch data folder, never Runlet's own. Needs Herd's PHPs (8.0 without
ext-mongodb or pdo_sqlsrv, 8.4 with both) and the runlet-fixtures `mongo` service. No SQL Server
is needed: the SQL Server connection points at a closed port, so its test fails after the PHP
was chosen.

Three launches:
1. Runlet's PHP installed (no SQL Server driver) and Herd's PHPs: a SQL Server connection gets
   Herd PHP 8.4, and the editor, Test Connection, and the run header say why.
2. No Runlet's PHP, Herd PHP 8.0 as the default PHP (no ext-mongodb): a MongoDB connection gets
   Herd PHP 8.4; Test Connection succeeds and names it and why; a query's header too.
3. Only Runlet's PHP is listed (RUNLET_DEBUG_HIDE_SYSTEM_PHP) and Herd PHP 8.0 is the default PHP
   (read once by the cache): no PHP has pdo_sqlsrv, and the message names the driver and both PHPs.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import time
import uuid

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
runlet_php = Path(sys.argv[3]).resolve() / "PHP"
scratch = Path(sys.argv[4] if len(sys.argv) > 4 else "/private/tmp/runlet-p184")
herd = Path.home() / "Library/Application Support/Herd/bin"
php80 = herd / "php80"
assert (runlet_php / "8.5.8-r3/bin/php").exists(), runlet_php
assert php80.exists() and (herd / "php").exists(), "needs Herd's php80 and php"
mongo_port = subprocess.run(["docker", "compose", "-p", "runlet-fixtures", "port", "mongo", "27017"], capture_output=True, text=True, check=True).stdout.strip().rsplit(":", 1)[-1]
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
scratch.mkdir(parents=True)
now = time.time() - 978307200  # Foundation's reference date


def seed(name, tabs, runlet=False, default_php=None):
    data = scratch / name
    state = data / "State"
    state.mkdir(parents=True)
    if runlet:
        shutil.copytree(runlet_php, data / "PHP", symlinks=True)

    def write(file, value):
        (state / f"{file}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": now, "data": value}, indent=2))

    if default_php:
        write("settings", {"defaultPHPExecutable": str(default_php)})
    entries = [{"id": str(uuid.uuid4()).upper(), "title": title, "code": code, "target": {"sandbox": {}}, "language": language,
                "selection": {"location": 0, "length": 0}, "createdAt": now - 600 + index}
               for index, (title, language, code) in enumerate(tabs)]
    write("session", {"windows": [{"id": str(uuid.uuid4()).upper(), "tabs": entries, "selectedTabId": entries[0]["id"], "workspaceEdited": False}]})
    return data


def launch(name, data, steps, extra_env=()):
    log_path = out / f"{name}.log"
    log_path.write_text("")
    env = ["--env", f"RUNLET_DATA_DIR={data}", "--env", f"RUNLET_SNAPSHOT_DIR={out}", "--env", "RUNLET_CREDENTIALS=memory",
           "--env", "SSH_AUTH_SOCK=", "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}"]
    for item in extra_env:
        env += ["--env", item]
    subprocess.run(["open", "-g", "-j", "-n", "-W", *env, "--stderr", str(log_path), str(app)], check=True)
    log = log_path.read_text()
    assert "RUNLET_DEBUG_STEPS: done" in log, log[-4000:]
    states = [line.split("RUNLET_DEBUG_STATE: ", 1)[1] for line in log.splitlines() if "RUNLET_DEBUG_STATE: " in line]
    print(f"== {name}\n" + "\n".join(states))
    return states


START = ["ghost", "scale:2", "frame:1280x860", "appearance:light", "wait"]
SQLSRV = ["db-editor:new", "db-field:name=Warehouse", "db-field:driver=sqlsrv", "db-field:host=127.0.0.1", "db-field:port=1433",
          "db-field:database=warehouse", "db-field:user=reporting", "db-field:password=fixture-pw", "db-field:timeout=2",
          "db-field:scope=all", "db-field:connectFrom=mac", "wait"]

# 1. Runlet's PHP lacks SQL Server's driver: Herd PHP 8.4 opens it.
data = seed("picks", [("Warehouse", "sql", "SELECT @@VERSION AS version;\n")], runlet=True)
states = launch("picks", data, START + ["select:Warehouse"] + SQLSRV + [
    "db-state", "shot:php-driver-editor", "db-test", "db-wait:30", "scroll:db-test-result", "wait", "shot:php-driver-test-sqlsrv",
    "db-save", "wait", "db-use:Warehouse", "run", "wait-run", "wait", "shot:php-driver-run-header",
])
editor = next(s for s in states if s.startswith("db-state:"))
assert "php=Herd PHP 8.4.25, the first PHP here with pdo_sqlsrv or pdo_dblib" in editor, editor
assert "reason=Runlet's PHP 8.5.8 comes first but has neither pdo_sqlsrv nor pdo_dblib." in editor, editor
# Herd's pdo_sqlsrv was loaded: whatever the server says, it isn't a missing driver.
tested = next(s for s in states if s.startswith("db-wait:")).split(" php=")[0]
assert "test=failed:" in tested and "could not find driver" not in tested and "neither pdo_sqlsrv nor pdo_dblib" not in tested, tested

# 2. No Runlet's PHP; the default PHP (Herd 8.0) has no ext-mongodb: Herd PHP 8.4 opens it.
query = '{"collection": "p184_events", "operation": "countDocuments", "filter": {}}\n'
data = seed("mongo", [("Events", "mongodb", query)], default_php=php80)
states = launch("mongo", data, START + ["select:Events", "db-editor:new", "db-field:name=Events", "db-field:driver=mongodb", "db-field:host=127.0.0.1",
                                        f"db-field:port={mongo_port}", "db-field:database=p184", "db-field:user=runlet", "db-field:password=runlet-fixture",
                                        "db-field:scope=all", "db-field:connectFrom=mac", "wait", "db-test", "db-wait:30", "scroll:db-test-result", "wait", "db-state",
                                        "shot:php-driver-test-mongo", "db-save", "wait", "db-use:Events", "run", "wait-run", "wait", "shot:php-driver-mongo-run"])
tested = next(s for s in states if s.startswith("db-wait:"))
assert "opened from this Mac (Herd PHP 8.4.25, the first PHP here with ext-mongodb)" in tested, tested
assert "reason=Herd PHP 8.0.30 comes first but has no ext-mongodb." in next(s for s in states if s.startswith("db-state:")), states

# 3. No PHP has SQL Server's driver: Runlet's PHP and the default PHP (not listed: read once).
data = seed("none", [("Warehouse", "sql", "SELECT @@VERSION AS version;\n")], runlet=True, default_php=php80)
states = launch("none", data, START + ["select:Warehouse"] + SQLSRV + [
    "db-test", "db-wait:30", "scroll:db-test-result", "wait", "db-state", "shot:php-driver-none",
    "db-save", "wait", "db-use:Warehouse", "run", "wait-run", "wait", "shot:php-driver-none-run",
], extra_env=["RUNLET_DEBUG_HIDE_SYSTEM_PHP=1"])
tested = next(s for s in states if s.startswith("db-wait:"))
assert "test=failed: No PHP on this Mac has pdo_sqlsrv or pdo_dblib, which the saved connection “Warehouse” needs, so nothing ran. Checked Runlet's PHP 8.5.8 and the default PHP." in tested, tested

shots = sorted(out.glob("php-driver-*.png"))
assert len(shots) == 7, shots
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

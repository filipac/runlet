#!/usr/bin/env python3
"""#183: runs waiting for a free run slot show as Queued in the Connection Manager, in a Debug app
with scratch data and neutral names only.

Usage: queued-runs-screenshots.py /path/to/Runlet.app /path/to/output [/path/to/scratch]

Needs only a PHP on this Mac with pdo_sqlite (Runlet picks it as it would for any local project).
Seeds a scratch data folder: a local project "acme" (a copy of the `plain` fixture), a SQLite
database in it, and six tabs. Then drives the app with RUNLET_DEBUG_STEPS: four PHP sleeps take
Runlet's four run slots, a fifth PHP run and an SQL statement on a saved SQLite connection wait
for one; shoots the Connection Manager (queued rows, counts) and the status bar; closes a running
run, so the first queued run gets its slot ("since" restarts); closes the queued statement (taken
out of the queue, nothing sent); then closes everything and checks nothing is left.
"""
from pathlib import Path
import json
import shutil
import sqlite3
import subprocess
import sys
import time
import uuid

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
scratch = Path(sys.argv[3] if len(sys.argv) > 3 else "/private/tmp/runlet-p183")
root = Path(__file__).resolve().parent.parent
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
scratch.mkdir(parents=True)
project = scratch / "acme"
shutil.copytree(root / "Tests/Fixtures/plain", project, symlinks=True)
database = project / "orders.sqlite"
with sqlite3.connect(database) as db:
    db.execute("CREATE TABLE orders (id INTEGER PRIMARY KEY, status TEXT)")
    db.executemany("INSERT INTO orders (status) VALUES (?)", [("paid",), ("paid",), ("refunded",)])
data = scratch / "data"
state = data / "State"
state.mkdir(parents=True)

now = time.time() - 978307200  # Foundation's reference date


def write(name, value):
    (state / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": now, "data": value}, indent=2))


local_id = str(uuid.uuid4()).upper()
write("targets", {
    "localProjects": [{"id": local_id, "name": "acme", "path": str(project), "revision": 1, "lastOpenedAt": now - 60}],
    "dockerProfiles": [],
    "sshProfiles": [],
})
target = {"local": {"_0": local_id}}
TABS = [
    ("Import orders", "php", "<?php\n\nsleep(120); // import orders\n"),
    ("Search index", "php", "<?php\n\nsleep(120); // rebuild the search index\n"),
    ("Digests", "php", "<?php\n\nsleep(120); // send the weekly digests\n"),
    ("Caches", "php", "<?php\n\nsleep(120); // warm the caches\n"),
    ("Nightly export", "php", "<?php\n\nsleep(120); // nightly export\n"),
    ("Order counts", "sql", "SELECT status, COUNT(*) AS orders FROM orders GROUP BY status;\n"),
]
tabs = [{"id": str(uuid.uuid4()).upper(), "title": title, "code": code, "target": target, "language": language,
         "selection": {"location": 0, "length": 0}, "createdAt": now - 600 + index}
        for index, (title, language, code) in enumerate(TABS)]
write("session", {"windows": [{"id": str(uuid.uuid4()).upper(), "tabs": tabs, "selectedTabId": tabs[0]["id"], "workspaceEdited": False}]})

steps = [
    "ghost", "scale:2", "frame:1280x820", "appearance:light", "wait",
    "select:Order counts", f"db-new:Orders|sqlite|||{database}||", "db-use:Orders",
    # Four runs take Runlet's four run slots.
    "select:Import orders", "run", "select:Search index", "run", "select:Digests", "run", "select:Caches", "run",
    "connections-wait:phpRun=4:30",
    # Two more wait for a slot: a PHP run, then a statement.
    "select:Nightly export", "run", "wait", "select:Order counts", "run",
    "connections-wait:queued=2:20", "wait", "wait", "connections-state",
    "select:Nightly export", "wait", "shot:queued-tab", "select:Order counts", "wait", "shot:queued-sql-tab",
    "connections", "wait", "frame:Connections=900x720", "wait", "shot:queued-manager@Connections",
    "appearance:dark", "wait", "shot:queued-manager-dark@Connections", "appearance:light",
    # A running run ends: the first queued one gets its slot, and its "since" restarts.
    "connection-close:sleep(120); // import", "connections-wait:queued=1:20", "wait", "wait", "connections-state",
    "shot:queued-after-close@Connections",
    # Close on the queued statement takes it out of the queue: nothing reaches the database.
    "connection-close:SELECT status", "connections-wait:queued=0:10", "connections-state",
    "select:Order counts", "wait", "sql-cancel-state", "shot:queued-closed-tab",
    # Everything else.
    "connection-close:sleep(120)", "connection-close:sleep(120)", "connection-close:sleep(120)", "connection-close:sleep(120)",
    "connections-wait:all=0:30", "connections-state",
]
log_path = out / "capture.log"
log_path.write_text("")
subprocess.run(["open", "-g", "-j", "-n", "-W",
                "--env", f"RUNLET_DATA_DIR={data}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                "--env", "RUNLET_CREDENTIALS=memory", "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                "--stderr", str(log_path), str(app)], check=True)

log = log_path.read_text()
states = [line for line in log.splitlines() if "RUNLET_DEBUG_STATE: connection" in line]
print("\n".join(states))
assert "RUNLET_DEBUG_STEPS: done" in log, log[-4000:]
connections = [line for line in states if "RUNLET_DEBUG_STATE: connections: " in line]
queued = connections[0]
# Four running, two listed as queued and not counted.
assert "connections: 4 (ssh=0 tunnel=0 database=0 phpRun=4 aiClient=0) queued=2" in queued, queued
assert "sleep(120); // nightly export" in queued and "| queued 1 |" in queued and "| queued 2 |" in queued, queued
assert "tooltip=4 active, 2 queued: / 1 database session queued / 4 PHP runs, 1 queued /" in queued, queued
promoted = connections[1]
# The nightly export runs now; the statement is next to start.
assert "connections: 4 (ssh=0 tunnel=0 database=0 phpRun=4 aiClient=0) queued=1" in promoted, promoted
assert "// import orders" not in promoted and "// nightly export" in promoted, promoted
removed = connections[2]
assert "queued=0" in removed and "SELECT status" not in removed and "closing: run:" in removed, removed
assert "connections: 0 " in connections[-1] and "queued=0" in connections[-1], connections[-1]
# The stopped statement's output says it left the queue; nothing reached the database.
closed_tab = next(line for line in log.splitlines() if "RUNLET_DEBUG_STATE: sql-cancel-state" in line)
assert "note=Removed from the queue before it started; nothing was sent." in closed_tab, closed_tab
# No database session was opened, so there was none to cancel on the server.
assert "log=[]" in closed_tab, closed_tab
shots = sorted(out.glob("queued-*.png"))
assert len(shots) == 6, shots
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

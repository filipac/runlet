#!/usr/bin/env python3
"""#146: Load Next end to end in a Debug app, with scratch data only.

Usage: sql-paging-screenshots.py /path/to/Runlet.app /path/to/output [/path/to/scratch]

Copies the `custom-driver` fixture to a scratch folder and adds an SQLite file of sensor
readings (2,600 rows, neutral data) for two saved connections: "Sensors", and "Sensors (prod)"
marked production. Then drives the app with RUNLET_DEBUG_STEPS (a scratch RUNLET_DATA_DIR, so
the saved connections' store is in memory):

- a capped result with Load Next, the result after loading the next page, and the end of the
  result (2,600 rows in 3 pages), with the main thread's timings (`wait-page`);
- the result window showing every loaded row, filtered;
- an UPDATE … RETURNING whose result is cut: no Load Next, and why;
- the production confirmation for the next page (cancelled).

It checks the pages' rows, Run History's entries, and that the UPDATE ran only once. The
scratch folder (default /private/tmp/runlet-p146) is removed afterwards.
"""
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
scratch = Path(sys.argv[3] if len(sys.argv) > 3 else "/private/tmp/runlet-p146")
root = Path(__file__).resolve().parent.parent
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
project = scratch / "acme"
shutil.copytree(root / "Tests/Fixtures/custom-driver", project, symlinks=True)
(project / "data").mkdir()
database = project / "data/readings.sqlite"
db = sqlite3.connect(database)
db.executescript("""
CREATE TABLE readings (id INTEGER PRIMARY KEY, sensor TEXT NOT NULL, recorded_at TEXT NOT NULL, celsius REAL NOT NULL, calibrated INTEGER NOT NULL DEFAULT 0);
""")
sensors = ["north-1", "north-2", "south-1", "east-1", "west-1"]
db.executemany("INSERT INTO readings (id, sensor, recorded_at, celsius) VALUES (?, ?, ?, ?)", [
    (n, sensors[n % 5], f"2026-09-{1 + (n // 120) % 28:02d} {(n // 5) % 24:02d}:{(n * 7) % 60:02d}", round(12 + (n % 37) * 0.25, 2)) for n in range(1, 2601)
])
db.commit()
db.close()

readings = scratch / "readings.sql"
readings.write_text("""-- Readings, newest first
SELECT id, sensor, recorded_at, celsius
FROM readings
ORDER BY id DESC;

-- Mark every reading calibrated, returning the rows it changed
UPDATE readings SET calibrated = calibrated + 1 RETURNING id, sensor, calibrated;
""")

steps = [
    "ghost", "scale:2", "frame:1280x820", "appearance:light", f"project:{project}", "wait",
    "perform:file.newSQLTab", "db-new:Sensors|sqlite|||data/readings.sqlite", "db-use:Sensors", f"code:{readings}", "caret:3", "wait",
    # A capped result: Load Next.
    "run", "wait-run", "wait", "sql-page-state", "shot:sql-load-next",
    # The next page: 2,000 rows in 2 pages.
    "sql-load-next", "wait-page", "wait", "sql-page-state", "sql-history", "shot:sql-load-next-loaded",
    "appearance:dark", "wait", "shot:sql-load-next-loaded-dark", "appearance:light",
    # The last page: the end of the result.
    "sql-load-next", "wait-page", "wait", "sql-page-state", "sql-history", "shot:sql-load-next-end",
    # The result window: every loaded row, filtered.
    "result-window", "wait", r"frame:SQL 1 · 2\c600 rows in 3 pages=1000x640", "result-filter:sensor|equals|north-1", "wait", "result-state",
    r"shot:sql-load-next-window@SQL 1 · 2\c600 rows in 3 pages", "close", "wait",
    # A larger page size: the first run and each page.
    "sql-rows-per-page:2500", "run", "wait-run", "wait", "sql-page-state", "sql-rows-per-page:1000",
    # A write that returns rows: cut, but never run again.
    "caret:8", "run", "wait-run", "wait", "sql-page-state", "sql-history", "shot:sql-load-next-write",
    # Production: Load Next asks again (cancelled).
    "db-new:Sensors (prod)|sqlite|||data/readings.sqlite|||production+red", "db-use:Sensors (prod)", "caret:3", "wait",
    "run", "wait", "confirm", "wait-run", "wait", "sql-load-next", "wait", "shot:sql-load-next-production", "cancel", "wait", "sql-page-state",
]
log_path = out / "capture.log"
log_path.write_text("")
subprocess.run(["open", "-g", "-j", "-n", "-W",
                "--env", f"RUNLET_DATA_DIR={scratch / 'data'}", "--env", f"RUNLET_SNAPSHOT_DIR={out}", "--env", "RUNLET_CREDENTIALS=memory",
                "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                "--stderr", str(log_path), str(app)], check=True)
log = log_path.read_text()
states = [line.split("RUNLET_DEBUG_STATE: ", 1)[1] for line in log.splitlines() if "RUNLET_DEBUG_STATE: sql-" in line or "RUNLET_DEBUG_STATE: result-" in line or "RUNLET_DEBUG_STATE: db-" in line]
timings = [line for line in log.splitlines() if "RUNLET_DEBUG_TIMING" in line]
print("\n".join(states))
print("\n".join(timings))
assert "RUNLET_DEBUG_STEPS: done" in log, log
pages = [line for line in states if line.startswith("sql-page-state:")]
assert "rows=1000 pages=1 more=true" in pages[0] and "plan=append ordered" in pages[0], pages[0]
assert "rows=2000 pages=2 more=true" in pages[1] and 'card="First 2,000 rows in 2 pages (more not shown)"' in pages[1], pages[1]
assert "rows=2600 pages=3 more=false" in pages[2] and 'card="2,600 rows in 3 pages"' in pages[2], pages[2]
assert "rows=2500 pages=1 more=true" in pages[3], pages[3]
assert "plan=refused(" in pages[4] and "(UPDATE)" in pages[4], pages[4]
assert "rows=1000 pages=1 more=true" in pages[5] and "phase=idle" in pages[5], "the cancelled page added nothing: " + pages[5]
history = [line for line in states if line.startswith("sql-history:")]
assert "Load Next: rows 1,001–2,000" in history[0], history[0]
assert "Load Next: rows 2,001–3,000" in history[1], history[1]
assert history[2].endswith("RETURNING id, sensor, calibrated"), history[2]
window = [line for line in states if line.startswith("result-state:")]
assert "shows 520 of 2600 rows" in window[0], window[0]
calibrated = sqlite3.connect(database).execute("SELECT MIN(calibrated), MAX(calibrated) FROM readings").fetchone()
assert calibrated == (1, 1), f"the UPDATE ran once: {calibrated}"
shots = sorted(out.glob("sql-load-next*.png"))
assert len(shots) == 7, shots
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

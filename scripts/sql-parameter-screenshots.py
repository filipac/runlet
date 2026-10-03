#!/usr/bin/env python3
"""#145: the SQL values sheet end to end in a Debug app, with scratch data only.

Usage: sql-parameter-screenshots.py /path/to/Runlet.app /path/to/output [/path/to/scratch]

Copies the `custom-driver` fixture (an in-memory SQLite `leases` table behind a project
driver) to a scratch folder, adds an SQLite file for a saved connection marked production,
and drives the app with RUNLET_DEBUG_STEPS: the sheet for `:name` placeholders, its result,
the sheet for `?` placeholders, the Run All sheet (a shared name, `?`s per statement, and a
`-- @param` preset) in dark, and the production confirmation listing the values (cancelled,
so nothing writes). Checks the output's note and the Run History entry. The scratch folder
(default /private/tmp/runlet-p145) is removed afterwards.
"""
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
scratch = Path(sys.argv[3] if len(sys.argv) > 3 else "/private/tmp/runlet-p145")
root = Path(__file__).resolve().parent.parent
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
project = scratch / "acme"
shutil.copytree(root / "Tests/Fixtures/custom-driver", project, symlinks=True)
(project / "data").mkdir()
billing = sqlite3.connect(project / "data/billing.sqlite")
billing.executescript("""
CREATE TABLE invoices (id INTEGER PRIMARY KEY, customer TEXT NOT NULL, total REAL NOT NULL, status TEXT NOT NULL);
INSERT INTO invoices (customer, total, status) VALUES ('Northwind', 120.0, 'open'), ('Contoso', 80.5, 'open'), ('Fabrikam', 42.0, 'paid');
""")
billing.commit()
billing.close()

queries = scratch / "leases.sql"
queries.write_text("""-- Leases at or above a rent, leaving one tenant out
SELECT tenant, rent
FROM leases
WHERE rent >= :min_rent
  AND tenant <> :skip
ORDER BY rent DESC;

-- Two leases by id
SELECT id, tenant, rent FROM leases WHERE id IN (?, ?);
""")
script = scratch / "raise.sql"
script.write_text("""-- @param :tenant text Grace
UPDATE leases SET rent = rent + :increase WHERE tenant = :tenant;
INSERT INTO leases (tenant, rent) VALUES (?, ?);
DELETE FROM leases WHERE id = ?;
SELECT tenant, rent FROM leases WHERE tenant = :tenant OR rent > :increase ORDER BY tenant;
""")
invoice = scratch / "invoice.sql"
invoice.write_text("""UPDATE invoices
SET status = :status
WHERE id = :id AND total < :limit;
""")

steps = [
    "ghost", "scale:2", "frame:1280x820", "appearance:light", f"project:{project}", "wait",
    "perform:file.newSQLTab", f"code:{queries}", "caret:4", "wait",
    # The sheet for :name placeholders.
    "run", "wait", "sql-param::min_rent=integer:1000", "sql-param::skip=text:Linus", "sql-params:state", "wait",
    "shot:sql-values-named",
    "sql-params:run", "wait-run", "wait", "state", "sql-history", "shot:sql-values-result",
    # The sheet for ? placeholders; the second statement.
    "caret:9", "run", "wait", "sql-param:?1=integer:1", "sql-param:?2=integer:3", "sql-params:state", "wait",
    "shot:sql-values-positional",
    "sql-params:run", "wait-run", "wait", "sql-history",
    # Run All: one sheet; :tenant shared and preset by -- @param, each statement's ? its own.
    "appearance:dark", f"code:{script}", "sql-run-all", "wait",
    "sql-param::increase=integer:50", "sql-param:?1@2=text:Ada Lovelace", "sql-param:?2@2=integer:1100", "sql-param:?1@3=integer:4",
    "sql-params:state", "wait", "shot:sql-values-run-all-dark",
    "sql-params:cancel", "wait",
    # Production: a saved connection marked production asks after the sheet, listing the values.
    "appearance:light", "db-new:Billing|sqlite|||data/billing.sqlite|||production+red", "db-use:Billing", f"code:{invoice}", "wait",
    "run", "wait", "sql-param::status=text:paid", "sql-param::id=integer:2", "sql-param::limit=decimal:100.00", "sql-params:run", "wait",
    "shot:sql-values-production", "cancel", "wait", "sql-history",
]
log_path = out / "capture.log"
log_path.write_text("")
subprocess.run(["open", "-g", "-j", "-n", "-W",
                "--env", f"RUNLET_DATA_DIR={scratch / 'data'}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                "--stderr", str(log_path), str(app)], check=True)
log = log_path.read_text()
states = [line for line in log.splitlines() if "RUNLET_DEBUG_STATE: sql-" in line or "RUNLET_DEBUG_STATE: state" in line]
print("\n".join(states))
assert "RUNLET_DEBUG_STEPS: done" in log, log
for problem in ["no values sheet", "can't set", "can't read", "not valid"]:
    assert problem not in log, problem
history = [line for line in states if "sql-history:" in line]
assert "-- @param :min_rent integer 1000\\n-- @param :skip text Linus\\n-- Leases at or above" in history[0], history[0]
assert "-- @param ?1 integer 1\\n-- @param ?2 integer 3\\n-- Two leases by id" in history[1], history[1]
assert "2 entries" in history[2], "the cancelled production run isn't in history: " + history[2]
shots = sorted(out.glob("sql-values-*.png"))
assert len(shots) == 5, shots
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

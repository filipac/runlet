#!/usr/bin/env python3
"""#145 and #168: the SQL parameters drawer end to end in a Debug app, with scratch data only.

Usage: sql-parameter-screenshots.py /path/to/Runlet.app /path/to/output [/path/to/scratch]

Copies the `custom-driver` fixture (an in-memory SQLite `leases` table behind a project
driver) to a scratch folder, adds an SQLite file for a saved connection marked production,
and drives the app with RUNLET_DEBUG_STEPS:

- the drawer for `:name` placeholders, in light and dark, and collapsed to its summary;
- the drawer for `?` placeholders, following the caret;
- Run with a value missing: nothing runs, the drawer focuses the field; then typing the
  value, Tab and Shift-Tab between the fields, and Return runs straight from the drawer;
  Escape returns to the editor;
- All Statements (Run All's values), in dark, with a `-- @param` preset;
- the production confirmation listing the values (cancelled, so nothing writes).

Checks the drawer's state, the keyboard, the output, and the Run History entries. The
scratch folder (default /private/tmp/runlet-p168) is removed afterwards.
"""
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
scratch = Path(sys.argv[3] if len(sys.argv) > 3 else "/private/tmp/runlet-p168")
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
missing = scratch / "tenant.sql"
missing.write_text("""-- One tenant's leases, and those at or above a rent
SELECT id, tenant, rent
FROM leases
WHERE tenant = :tenant
   OR rent >= :min_rent;
""")
script = scratch / "raise.sql"
script.write_text("""-- @param :increase integer 50
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
    # The drawer for :name placeholders, before any run: not set yet.
    "sql-params:state",
    "sql-param::min_rent=integer:1000", "sql-param::skip=text:Linus", "sql-params:state", "wait",
    "shot:sql-drawer-named",
    "appearance:dark", "wait", "shot:sql-drawer-named-dark", "appearance:light", "wait",
    "sql-params:collapse", "wait", "sql-params:state", "shot:sql-drawer-collapsed", "sql-params:expand",
    # The caret moves to the ? statement: the drawer follows it.
    "caret:9", "wait", "sql-param:?1=integer:1", "sql-param:?2=integer:3", "sql-params:state", "wait",
    "shot:sql-drawer-positional",
    "run", "wait-run", "wait", "sql-history",
    # A missing value: Run doesn't run; the drawer focuses the field. :min_rent is remembered.
    f"code:{missing}", "caret:4", "wait", "run", "wait", "sql-params:state", "sql-history",
    "shot:sql-drawer-missing",
    # Typing the value, Tab and Shift-Tab between the fields, Return runs from the drawer.
    "sql-params:type:Grace", "sql-params:tab", "sql-params:shift+tab", "sql-params:return", "wait-run", "wait",
    "sql-params:state", "sql-history", "shot:sql-drawer-result",
    "sql-params:escape",
    # All Statements: Run All's values, :increase preset by -- @param, :tenant remembered, each statement's ? its own.
    "appearance:dark", f"code:{script}", "caret:2", "wait", "sql-params:all", "wait",
    "sql-param:?1@2=text:Ada Lovelace", "sql-param:?2@2=integer:1100",
    "sql-params:state", "wait", "shot:sql-drawer-run-all-dark",
    "sql-run-all", "wait", "sql-params:state", "sql-params:statement",
    # Production: a saved connection marked production asks first, listing the values.
    "appearance:light", "db-new:Billing|sqlite|||data/billing.sqlite|||production+red", "db-use:Billing", f"code:{invoice}", "caret:2", "wait",
    "sql-param::status=text:paid", "sql-param::id=integer:2", "sql-param::limit=decimal:100.00", "run", "wait",
    "shot:sql-drawer-production", "cancel", "wait", "sql-history",
]
log_path = out / "capture.log"
log_path.write_text("")
subprocess.run(["open", "-g", "-j", "-n", "-W",
                "--env", f"RUNLET_DATA_DIR={scratch / 'data'}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                "--stderr", str(log_path), str(app)], check=True)
log = log_path.read_text()
states = [line for line in log.splitlines() if "RUNLET_DEBUG_STATE: sql-" in line]
print("\n".join(states))
assert "RUNLET_DEBUG_STEPS: done" in log, log
for problem in ["not an SQL tab", "can't set", "can't read", "no drawer field"]:
    assert problem not in log, problem
drawer = [line for line in states if "sql-params: scope=" in line]
history = [line for line in states if "sql-history:" in line]
keys = [line for line in states if "sql-params: return:" in line or "tab:" in line or "escape:" in line]
assert "rows=[:min_rent text=not set [none]; :skip text=not set [none]]" in drawer[0], drawer[0]
assert ":min_rent integer=1000 [typed]; :skip text='Linus' [typed]" in drawer[1], drawer[1]
assert "collapsed=true" in drawer[2] and "summary=2 parameters: :min_rent = 1000, :skip = 'Linus'" in drawer[2], drawer[2]
assert "rows=[?1 integer=1 [typed]; ?2 integer=3 [typed]]" in drawer[3], drawer[3]
assert "-- @param ?1 integer 1\\n-- @param ?2 integer 3\\n-- Two leases by id" in history[0], history[0]
# The missing value: nothing ran, the drawer focused the field.
assert "note=Set a value for :tenant to run." in drawer[4] and "focus-request=named(\"tenant\")" in drawer[4], drawer[4]
assert 'first-responder=field(named("tenant"))' in drawer[4], drawer[4]
assert ":tenant text=not set [none]; :min_rent integer=1000 [typed]" in drawer[4], drawer[4]
assert "1 entries" in history[1], "the refused run isn't in history: " + history[1]
assert 'sql-params: tab: first-responder=field(named("min_rent"))' in log, keys
assert 'sql-params: shift+tab: first-responder=field(named("tenant"))' in log, keys
assert "escape: first-responder=editor" in log, keys
assert "note=none" in drawer[5] and ":tenant text='Grace' [typed]" in drawer[5], drawer[5]
assert "-- @param :tenant text Grace\\n-- @param :min_rent integer 1000\\n-- One tenant's leases" in history[2], history[2]
# All Statements, then Run All with a value missing: the drawer stays on all statements.
assert "scope=all" in drawer[6] and ":increase integer=50 [preset]; :tenant text='Grace' [typed]" in drawer[6] and "?1 (statement 3) text=not set" in drawer[6], drawer[6]
assert "note=Set a value for ?1 (statement 3) to run all statements." in drawer[7], drawer[7]
assert "2 entries" in history[3], "the cancelled production run isn't in history: " + history[3]
shots = sorted(out.glob("sql-drawer-*.png"))
assert len(shots) == 8, shots
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

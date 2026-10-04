#!/usr/bin/env python3
"""#144: Stop cancels the statement on the database server, end to end in a Debug app, with
scratch data only.

Usage: sql-cancel-screenshots.py /path/to/Runlet.app /path/to/output <mariadb port> <postgres port> [/path/to/scratch]

Copies the `custom-driver` fixture to a scratch folder and saves two connections to the
throwaway fixture servers (`scripts/setup-fixtures.sh databases`; a scratch RUNLET_DATA_DIR
keeps the fixture passwords in memory): "Reporting" on MariaDB 11, and "Analytics" on
PostgreSQL 14, marked production. Then drives the app with RUNLET_DEBUG_STEPS: a sleeping
statement running with Stop, Stop's "Cancelled the statement on the server (KILL QUERY …)",
and on the production connection (which asks before the run, never before Stop) the same with
pg_cancel_backend, in dark mode. The database's cancellation error shows as "Interrupted by
Stop" rather than an error card. Checks the servers run neither statement afterwards. The
scratch folder (default /private/tmp/runlet-p144) is removed afterwards.
"""
from pathlib import Path
import shutil
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
my_port, pg_port = sys.argv[3], sys.argv[4]
scratch = Path(sys.argv[5] if len(sys.argv) > 5 else "/private/tmp/runlet-p144")
root = Path(__file__).resolve().parent.parent
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
project = scratch / "acme"
shutil.copytree(root / "Tests/Fixtures/custom-driver", project, symlinks=True)

mysql_sql = scratch / "monthly.sql"
mysql_sql.write_text("""-- Monthly revenue report (slow on purpose)
SELECT SLEEP(30) AS p144_monthly_revenue;
""")
pg_sql = scratch / "rebuild.sql"
pg_sql.write_text("""-- Rebuild the order totals (slow on purpose)
SELECT pg_sleep(30) AS p144_order_totals;
""")

steps = [
    "ghost", "scale:2", "frame:1280x820", "appearance:light", f"project:{project}", "wait",
    "perform:file.newSQLTab",
    f"db-new:Reporting|mysql|127.0.0.1|{my_port}|shop|root|runlet-fixture", "db-use:Reporting", f"code:{mysql_sql}", "caret:2", "wait",
    # MariaDB: running with Stop, then Stop's report.
    "run", "wait", "sql-cancel-state", "shot:sql-stop-running",
    "perform:run.stop", "wait-run", "wait", "sql-cancel-state", "shot:sql-stop-cancelled",
    # PostgreSQL on a production connection: the run asks; Stop doesn't.
    f"db-new:Analytics|pgsql|127.0.0.1|{pg_port}|shop|postgres|runlet-fixture|production+red", "db-use:Analytics", f"code:{pg_sql}", "caret:2", "wait",
    "run", "wait", "confirm", "wait", "sql-cancel-state",
    "perform:run.stop", "wait-run", "wait", "sql-cancel-state", "appearance:dark", "wait", "shot:sql-stop-cancelled-production-dark",
]
log_path = out / "capture.log"
log_path.write_text("")
subprocess.run(["open", "-g", "-j", "-n", "-W",
                "--env", f"RUNLET_DATA_DIR={scratch / 'data'}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                "--env", "RUNLET_CREDENTIALS=memory",
                "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                "--stderr", str(log_path), str(app)], check=True)
log = log_path.read_text()
states = [line for line in log.splitlines() if "RUNLET_DEBUG_STATE: sql-cancel-state" in line or "RUNLET_DEBUG_STATE: db-" in line]
print("\n".join(states))
assert "RUNLET_DEBUG_STEPS: done" in log, log
cancel = [line for line in states if "sql-cancel-state" in line]
assert "running" in cancel[0] and "Database session" in cancel[0], cancel[0]
assert "note=Cancelled the statement on the server (KILL QUERY " in cancel[1], cancel[1]
assert 'errors=["grey:Interrupted by Stop."]' in cancel[1], cancel[1]
assert "running" in cancel[2] and "pg_cancel_backend" in cancel[2], cancel[2]
assert "note=Cancelled the statement on the server (pg_cancel_backend(" in cancel[3], cancel[3]
assert 'errors=["grey:Interrupted by Stop."]' in cancel[3], cancel[3]


def count(dsn, user, sql):
    return subprocess.run(["php", "-r", "echo (new PDO($argv[1], $argv[2], 'runlet-fixture'))->query($argv[3])->fetchColumn();", dsn, user, sql], capture_output=True, text=True, check=True).stdout


assert count(f"mysql:host=127.0.0.1;port={my_port};dbname=shop", "root", "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO LIKE '%p144_monthly%' AND ID <> CONNECTION_ID()") == "0"
assert count(f"pgsql:host=127.0.0.1;port={pg_port};dbname=shop", "postgres", "SELECT COUNT(*) FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%p144_order%' AND pid <> pg_backend_pid()") == "0"
shots = sorted(out.glob("sql-stop-*.png"))
assert len(shots) == 3, shots
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

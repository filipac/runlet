#!/usr/bin/env python3
"""#150: the Database pane's Server section end to end in a Debug app, with scratch data only.

Usage: server-panel-screenshots.py /path/to/Runlet.app /path/to/output <mariadb port> <postgres port> [/path/to/scratch]

Copies the `custom-driver` fixture to a scratch folder and saves connections to the throwaway
fixture MariaDB 11 and PostgreSQL 14 (`scripts/setup-fixtures.sh databases`; the fixture
password, kept in memory by a scratch RUNLET_DATA_DIR). Creates `p150_orders` and the
`p150_limited` user idempotently, and opens the script's own sessions, marked `p150`: a long
export, a transaction holding a row lock, and a statement waiting for that lock. Then drives the
app with RUNLET_DEBUG_STEPS: the Server section before and after Read Server Details, the
sessions filtered to `p150`, Kill Session's confirmation and its result, Cancel Query declined,
the panel's own session refused, a refresh interval that stops when the section hides, the
production question (and no refresh there), and a user without the PROCESS privilege. Every
cancel and kill targets only this script's own sessions. They are ended, and the scratch folder
(default /private/tmp/runlet-p150) removed, afterwards.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import time

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
my_port, pg_port = sys.argv[3], sys.argv[4]
scratch = Path(sys.argv[5] if len(sys.argv) > 5 else "/private/tmp/runlet-p150")
root = Path(__file__).resolve().parent.parent
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
project = scratch / "acme"
shutil.copytree(root / "Tests/Fixtures/custom-driver", project, symlinks=True)

my = f"mysql:host=127.0.0.1;port={my_port};dbname=shop"
pg = f"pgsql:host=127.0.0.1;port={pg_port};dbname=shop"


def php(code, *args, check=True):
    return subprocess.run(["php", "-r", code, *args], capture_output=True, text=True, check=check).stdout


EXEC = "$p = new PDO($argv[1], $argv[2], 'runlet-fixture', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]); foreach (array_slice($argv, 3) as $sql) { $s = $p->query($sql); if ($s->columnCount() > 0) { foreach ($s->fetchAll(PDO::FETCH_NUM) as $r) echo implode('|', $r), \"\\n\"; } }"
php(EXEC, my, "root",
    "CREATE TABLE IF NOT EXISTS p150_orders (id INT PRIMARY KEY, status VARCHAR(20) NOT NULL, note VARCHAR(255) NOT NULL, KEY p150_orders_status (status)) ENGINE=InnoDB",
    "INSERT IGNORE INTO p150_orders (id, status, note) SELECT seq, IF(seq % 3 = 0, 'paid', 'open'), REPEAT('x', 200) FROM seq_1_to_4000",
    "ANALYZE TABLE p150_orders",
    "CREATE USER IF NOT EXISTS p150_limited@'%' IDENTIFIED BY 'p150-fixture'",
    "GRANT SELECT ON shop.p150_orders TO p150_limited@'%'")
php(EXEC, pg, "postgres",
    "CREATE TABLE IF NOT EXISTS p150_orders (id INT PRIMARY KEY, status VARCHAR(20) NOT NULL, note VARCHAR(255) NOT NULL)",
    "INSERT INTO p150_orders (id, status, note) SELECT n, CASE WHEN n % 3 = 0 THEN 'paid' ELSE 'open' END, repeat('x', 200) FROM generate_series(1, 4000) n ON CONFLICT (id) DO NOTHING",
    "ANALYZE p150_orders")

# The script's own sessions (MariaDB), each marked "p150".
VICTIM = """
$p = new PDO($argv[1], 'root', 'runlet-fixture', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$p->exec('SET SESSION innodb_lock_wait_timeout = 300');
foreach (array_slice($argv, 2) as $sql) { try { $p->exec($sql); } catch (Throwable $e) { fwrite(STDERR, $e->getMessage() . "\\n"); exit; } }
"""
PG_VICTIM = """
$p = new PDO($argv[1], 'postgres', 'runlet-fixture', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
foreach (array_slice($argv, 2) as $sql) { try { $p->exec($sql); } catch (Throwable $e) { fwrite(STDERR, $e->getMessage() . "\\n"); exit; } }
"""
victims = [
    subprocess.Popen(["php", "-r", VICTIM, my, "SELECT SLEEP(240) /* p150 nightly export */"]),
    subprocess.Popen(["php", "-r", VICTIM, my, "BEGIN", "UPDATE p150_orders SET status = 'open' WHERE id = 3 /* p150 holds lock */", "SELECT SLEEP(240) /* p150 holds lock */"]),
    subprocess.Popen(["php", "-r", PG_VICTIM, pg, "BEGIN", "UPDATE p150_orders SET status = 'open' WHERE id = 3 /* p150 holds lock */", "SELECT pg_sleep(240) /* p150 holds lock */"]),
]
time.sleep(1)
victims.append(subprocess.Popen(["php", "-r", VICTIM, my, "UPDATE p150_orders SET status = 'paid' WHERE id = 3 /* p150 waits for lock */"]))
victims.append(subprocess.Popen(["php", "-r", PG_VICTIM, pg, "SET lock_timeout = '300s'", "UPDATE p150_orders SET status = 'paid' WHERE id = 3 /* p150 waits for lock */"]))
time.sleep(1)
# The PostgreSQL session holding the lock: the one a user without the privilege tries to kill.
pg_holder = php(EXEC, pg, "postgres", "SELECT pid FROM pg_stat_activity WHERE query LIKE '%p150 holds lock%' AND query NOT LIKE '%pg_stat_activity%'").split()[0]


def end_victims():
    for victim in victims:
        if victim.poll() is None:
            victim.terminate()
    # Only this script's own sessions, by their marker.
    ids = php(EXEC, my, "root", "SELECT ID FROM information_schema.PROCESSLIST WHERE INFO LIKE '%p150 %' AND INFO NOT LIKE '%PROCESSLIST%' AND ID <> CONNECTION_ID()", check=False)
    for line in ids.split():
        php(EXEC, my, "root", f"KILL {int(line)}", check=False)
    pids = php(EXEC, pg, "postgres", "SELECT pid FROM pg_stat_activity WHERE query LIKE '%p150 %' AND query NOT LIKE '%pg_stat_activity%' AND pid <> pg_backend_pid()", check=False)
    for line in pids.split():
        php(EXEC, pg, "postgres", f"SELECT pg_terminate_backend({int(line)})", check=False)


steps = [
    "ghost", "scale:2", "frame:1280x820", "appearance:light", f"project:{project}", "wait",
    "perform:file.newSQLTab", f"db-new:Shop|mysql|127.0.0.1|{my_port}|shop|root|runlet-fixture", "db-use:Shop", "wait",
    "inspector:database", "server:server", "wait", "shot:server-placeholder",
    "server-read", "wait", "wait", "server-state", "shot:server-overview",
    "server-filter:p150", "scroll:server-sessions", "wait", "shot:server-sessions",
    # Kill Session asks (every connection), then sends KILL to the script's own session only.
    "server-action:kill:p150 nightly export", "wait", "server-state", "shot:server-kill-confirmation",
    "server-confirm:yes", "wait", "wait", "server-state", "scroll:server-sessions", "wait", "shot:server-killed",
    # Cancel Query, declined: nothing is sent.
    "server-action:cancel:p150 waits for lock", "wait", "server-state", "server-confirm:no", "wait", "server-state",
    # A refresh interval reads the sessions again, and stops when the section hides.
    "server-refresh:5", "wait", "wait", "wait", "wait", "server-state", "server:tables", "wait", "server-state", "server:server", "wait",
    # Production: the read asks first, and no refresh is offered.
    "perform:file.newSQLTab", f"db-new:Reporting|pgsql|127.0.0.1|{pg_port}|shop|postgres|runlet-fixture|production", "db-use:Reporting", "wait",
    "server-read", "wait", "server-state", "shot:server-production-question", "confirm", "wait", "wait",
    "server-refresh:5", "server-state", "scroll:server-sessions", "appearance:dark", "wait", "shot:server-postgres-dark", "appearance:light",
    # PostgreSQL without pg_read_all_stats or pg_signal_backend: others' sessions show without their
    # statements, and killing the script's own lock holder (a superuser's) is refused by the server.
    "perform:file.newSQLTab", f"db-new:Limited role|pgsql|127.0.0.1|{pg_port}|shop|p150_limited|p150-fixture", "db-use:Limited role", "wait",
    "server-filter:", "server-read", "wait", "wait", f"server-action:kill:{pg_holder}", "wait", "server-state", "server-confirm:yes", "wait", "wait", "server-state",
    "scroll:server-sessions", "wait", "shot:server-not-permitted",
    # A user without PROCESS sees only its own sessions and may not end others'.
    "perform:file.newSQLTab", f"db-new:Limited|mysql|127.0.0.1|{my_port}|shop|p150_limited|p150-fixture", "db-use:Limited", "wait",
    "server-read", "wait", "wait", "server-state", "scroll:server-sessions", "wait", "shot:server-limited",
    # The panel's own session is refused: an alert, last (closing one in a ghosted app can crash AppKit).
    "server-action:kill:own", "wait", "alert",
]
log_path = out / "capture.log"
log_path.write_text("")
try:
    own = None
    subprocess.run(["open", "-g", "-j", "-n", "-W",
                    "--env", f"RUNLET_DATA_DIR={scratch / 'data'}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                    "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                    "--stderr", str(log_path), str(app)], check=True)
    remaining = php(EXEC, my, "root", "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO LIKE '%p150 nightly export%' AND INFO NOT LIKE '%PROCESSLIST%'")
finally:
    end_victims()
log = log_path.read_text()
states = [line.split("RUNLET_DEBUG_STATE: ", 1)[1] for line in log.splitlines() if "RUNLET_DEBUG_STATE: server-state" in line or "RUNLET_DEBUG_STATE: alert" in line]
print("\n".join(states))
assert "RUNLET_DEBUG_STEPS: done" in log, log
s = [line for line in states if line.startswith("server-state")]
assert "overview=MariaDB" in s[0] and "sessions=" in s[0] and "visibility all" in s[0], s[0]
assert "confirmation=Kill session" in s[1] and "[KILL " in s[1], s[1]
assert "action: killed" in s[2] and "Kill Session on session" in s[2], s[2]
assert "confirmation=Cancel the statement of session" in s[3] and "[KILL QUERY " in s[3], s[3]
assert "confirmation=none" in s[4] and "last=not sent" in s[4], s[4]
assert "refresh=5 s" in s[5] and "last=read sessions" in s[5], s[5]
assert "refresh=off" in s[6] and "refresh stopped" in s[6], s[6]
assert "production=true" in s[7] and "loading=false" in s[7] and "overview=-" in s[7], f"production asks before reading: {s[7]}"
assert "production=true" in s[8] and "refresh=off" in s[8] and "overview=PostgreSQL" in s[8], s[8]
assert "visibility partial" in s[9] and f"[SELECT pg_terminate_backend({pg_holder})]" in s[9], s[9]
assert "action: refused" in s[10] and "pg_signal_backend" in s[10], s[10]
assert "visibility own" in s[11] and "PROCESS privilege" in s[11], s[11]
alerts = [line for line in states if line.startswith("alert")]
assert alerts and "panel's own" in alerts[-1], alerts
assert remaining.strip() == "0", f"the killed session is gone: {remaining}"
shots = sorted(out.glob("server-*.png"))
assert len(shots) == 9, shots
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

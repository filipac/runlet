#!/usr/bin/env python3
"""#147: Explain Statement end to end in a Debug app, with scratch data only.

Usage: sql-explain-screenshots.py /path/to/Runlet.app /path/to/output <postgres port> [/path/to/scratch]

Copies the `custom-driver` fixture to a scratch folder and adds an SQLite file (customers and
orders, neutral data) for a saved connection. Creates `p147_customers` and `p147_items` on the
throwaway fixture PostgreSQL 14 (`scripts/setup-fixtures.sh databases`, user postgres, the
fixture password; a scratch RUNLET_DATA_DIR keeps it in memory) and saves a connection to it.
Then drives the app with RUNLET_DEBUG_STEPS: the SQLite plan tree, the PostgreSQL plan with
its full scans, Raw, Explain Analyze of a SELECT (rolled back), and Explain Analyze's question
for a DELETE (shot last, never answered, so nothing writes). The scratch folder (default
/private/tmp/runlet-p147) is removed afterwards.
"""
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
pg_port = sys.argv[3]
scratch = Path(sys.argv[4] if len(sys.argv) > 4 else "/private/tmp/runlet-p147")
root = Path(__file__).resolve().parent.parent
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
project = scratch / "acme"
shutil.copytree(root / "Tests/Fixtures/custom-driver", project, symlinks=True)
(project / "data").mkdir()
shop = sqlite3.connect(project / "data/shop.sqlite")
countries = ["NL", "DE", "FR", "UK"]
shop.executescript("""
CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, country TEXT NOT NULL);
CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers(id), status TEXT NOT NULL, total REAL NOT NULL);
CREATE INDEX orders_customer ON orders (customer_id);
""")
shop.executemany("INSERT INTO customers (name, country) VALUES (?, ?)", [(f"Customer {n}", countries[n % 4]) for n in range(1, 201)])
shop.executemany("INSERT INTO orders (customer_id, status, total) VALUES (?, ?, ?)", [(n % 200 + 1, "open" if n % 3 else "paid", round(10 + n * 1.5, 2)) for n in range(1, 801)])
shop.commit()
shop.close()

# PostgreSQL: the fixture server's p147_ tables, created again.
pg = f"pgsql:host=127.0.0.1;port={pg_port};dbname=shop"
setup = """
$p = new PDO($argv[1], 'postgres', 'runlet-fixture', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$p->exec('DROP TABLE IF EXISTS p147_items');
$p->exec('DROP TABLE IF EXISTS p147_customers');
$p->exec('CREATE TABLE p147_customers (id SERIAL PRIMARY KEY, email VARCHAR(190) NOT NULL, country VARCHAR(2))');
$p->exec('CREATE TABLE p147_items (id SERIAL PRIMARY KEY, customer_id INT NOT NULL, sku VARCHAR(40), qty INT)');
$p->exec('CREATE INDEX p147_items_customer ON p147_items (customer_id)');
$c = []; for ($i = 1; $i <= 1000; $i++) { $c[] = "('customer$i@example.test', '" . ($i % 2 ? 'UK' : 'NL') . "')"; }
$p->exec('INSERT INTO p147_customers (email, country) VALUES ' . implode(',', $c));
$r = []; for ($i = 1; $i <= 2000; $i++) { $r[] = '(' . ($i % 1000 + 1) . ", 'SKU$i', $i)"; }
$p->exec('INSERT INTO p147_items (customer_id, sku, qty) VALUES ' . implode(',', $r));
$p->exec('ANALYZE p147_customers'); $p->exec('ANALYZE p147_items');
"""
subprocess.run(["php", "-r", setup, pg], check=True)

sqlite_sql = scratch / "shop.sql"
sqlite_sql.write_text("""-- What customers in one country with open orders spent
SELECT c.name, SUM(o.total) AS spent
FROM customers c
JOIN orders o ON o.customer_id = c.id
WHERE c.country = 'NL'
  AND c.id IN (SELECT customer_id FROM orders WHERE status = 'open')
GROUP BY c.name
ORDER BY spent DESC;
""")
pg_sql = scratch / "items.sql"
pg_sql.write_text("""-- Customers in one country with the most items
SELECT c.email, SUM(i.qty) AS items
FROM p147_customers c
JOIN p147_items i ON i.customer_id = c.id
WHERE c.country = 'UK'
GROUP BY c.email
ORDER BY items DESC
LIMIT 10;

-- Remove small line items
DELETE FROM p147_items WHERE qty < 5;
""")

steps = [
    "ghost", "scale:2", "frame:1440x860", "appearance:light", f"project:{project}", "wait",
    "perform:file.newSQLTab", "db-new:Shop|sqlite|||data/shop.sqlite", "db-use:Shop", f"code:{sqlite_sql}", "caret:2", "wait",
    # SQLite: the plan tree.
    "sql-explain", "wait-run", "wait", "sql-plan:state", "shot:explain-sqlite",
    # PostgreSQL: estimates, costs, and full scans; then Raw.
    f"db-new:Analytics|pgsql|127.0.0.1|{pg_port}|shop|postgres|runlet-fixture", "db-use:Analytics", f"code:{pg_sql}", "caret:2", "wait",
    "sql-explain", "wait-run", "wait", "sql-plan:state", "shot:explain-postgres",
    "appearance:dark", "wait", "shot:explain-postgres-dark", "appearance:light",
    "sql-plan:raw", "wait", "shot:explain-raw",
    # Explain Analyze of the SELECT: actual rows and times, rolled back.
    "sql-explain:analyze", "wait-run", "wait", "sql-plan:state", "shot:explain-analyze",
    # Explain Analyze of the DELETE asks first; shot last and never answered.
    "caret:11", "sql-explain:analyze", "wait", "sql-plan:state", "shot:explain-analyze-question",
]
log_path = out / "capture.log"
log_path.write_text("")
subprocess.run(["open", "-g", "-j", "-n", "-W",
                "--env", f"RUNLET_DATA_DIR={scratch / 'data'}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                "--stderr", str(log_path), str(app)], check=True)
log = log_path.read_text()
states = [line for line in log.splitlines() if "RUNLET_DEBUG_STATE: sql-plan" in line or "RUNLET_DEBUG_STATE: db-" in line]
print("\n".join(states))
assert "RUNLET_DEBUG_STEPS: done" in log, log
plans = [line for line in states if "sql-plan:" in line]
assert "plan sqlite" in plans[0] and "[full scan]" in plans[0], plans[0]
assert "plan pgsql" in plans[1] and "Seq Scan" in plans[1], plans[1]
assert "analyze pgsql" in plans[2] and "rolledBack=true" in plans[2], plans[2]
assert "question=EXPLAIN ANALYZE runs the DELETE" in plans[3], plans[3]
count = subprocess.run(["php", "-r", "echo (new PDO($argv[1], 'postgres', 'runlet-fixture'))->query('SELECT COUNT(*) FROM p147_items')->fetchColumn();", pg], capture_output=True, text=True, check=True).stdout
assert count == "2000", f"the DELETE never ran: {count}"
shots = sorted(out.glob("explain-*.png"))
assert len(shots) == 6, shots
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

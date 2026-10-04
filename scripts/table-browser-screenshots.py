#!/usr/bin/env python3
"""#151: Browse Table end to end in a Debug app, with scratch data only.

Usage: table-browser-screenshots.py /path/to/Runlet.app /path/to/output [/path/to/scratch]

Copies the `custom-driver` fixture to a scratch folder and adds an SQLite file (a product
catalog with a primary key, a stock log without one, and a view; neutral data) for saved
connections: "Shop", "Shop (production)" marked as production, and "Replica", read-only. Then
drives the app with RUNLET_DEBUG_STEPS: Browse Table with a filter, a sort, and the second page
read on the server; pending edits marked in the grid, Edit Value, and Review Changes; Apply,
which reads the page again; a rollback when another session changed a row; the production
question before Apply; and the read-only cases (no primary key, a read-only connection).
Checks each step's state and the database afterwards. The scratch folder (default
/private/tmp/runlet-p151) is removed afterwards.
"""
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
scratch = Path(sys.argv[3] if len(sys.argv) > 3 else "/private/tmp/runlet-p151")
root = Path(__file__).resolve().parent.parent
out.mkdir(parents=True, exist_ok=True)
for old in out.glob("browse-*.png"):
    old.unlink()
shutil.rmtree(scratch, ignore_errors=True)
project = scratch / "acme"
shutil.copytree(root / "Tests/Fixtures/custom-driver", project, symlinks=True)
(project / "data").mkdir()
database = project / "data/shop.sqlite"
shop = sqlite3.connect(database)
shop.executescript("""
CREATE TABLE products (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    price NUMERIC NOT NULL,
    stock INTEGER NOT NULL DEFAULT 0,
    note TEXT
);
CREATE TABLE stock_moves (product_id INTEGER, moved_at TEXT, quantity INTEGER);
CREATE VIEW low_stock AS SELECT id, name, stock FROM products WHERE stock < 5;
""")
categories = {
    "Lighting": ["Desk lamp", "Floor lamp", "Pendant light", "Wall light", "Table lamp", "Reading light", "Ceiling light", "Clip lamp"],
    "Desks": ["Writing desk", "Standing desk", "Corner desk", "Folding desk", "Drafting table", "Laptop stand", "Desk shelf", "Desk drawer"],
    "Chairs": ["Office chair", "Stool", "Armchair", "Dining chair", "Lounge chair", "Bench", "Footrest", "Rocking chair"],
    "Storage": ["Bookcase", "Shelf unit", "Cabinet", "Drawer unit", "Storage box", "Coat rack", "Shoe rack", "Wall shelf"],
}
models = ["Aster", "Birch", "Cedar", "Dune", "Fern"]
rows = []
for category, bases in categories.items():
    for base_index, base in enumerate(bases):
        for model_index, model in enumerate(models):
            price = 19 + (base_index * 13 + model_index * 7) % 180 + 0.9
            stock = (base_index * 5 + model_index * 3) % 40
            note = None if (base_index + model_index) % 4 == 0 else f"{model} finish"
            rows.append((f"{base} {model}", category, f"{price:.2f}", stock, note))
shop.executemany("INSERT INTO products (name, category, price, stock, note) VALUES (?, ?, ?, ?, ?)", rows)
shop.executemany("INSERT INTO stock_moves VALUES (?, ?, ?)", [(n % 40 + 1, f"2026-09-{n % 28 + 1:02d} 10:00", (n % 7) - 3) for n in range(1, 61)])
shop.commit()
shop.close()

# Another session's change, run from an SQL tab while edits are pending.
(scratch / "touch.sql").write_text("UPDATE products SET price = price + 1 WHERE id = 1;\n")
(scratch / "empty.sql").write_text("SELECT 1;\n")

title = "products · Browse"
steps = [
    "ghost", "scale:2", "frame:1440x860", "appearance:light", f"project:{project}", "wait",
    "perform:file.newSQLTab", "db-new:Shop|sqlite|||data/shop.sqlite", "db-use:Shop", f"code:{scratch / 'empty.sql'}", "wait",
    "inspector:database", "sql-schema:load", "wait", "wait",
    # Browse: a filter and a sort read on the server, then the second page.
    "browse-table:products", "browse-wait", f"frame:{title}=1240x760", "browse-size:25", "wait", "browse-wait",
    "browse-filter:category|equals|Lighting", "browse-filter:price|greaterOrEqual|50", "browse-filters:apply", "browse-wait",
    "browse-sort:price:desc", "browse-wait", "browse-page:next", "browse-wait", "browse-state", "wait",
    f"shot:browse-paging@{title}",
    # Pending edits, marked in the grid: changed cells, a deleted row, a new row.
    "browse-filters:clear", "browse-wait", "browse-sort:", "browse-wait", "browse-state",
    "browse-edit:2|price=129.90", "browse-edit:3|stock=12", "browse-edit:3|note=\\N", "browse-delete:5",
    "browse-add-row", "browse-edit:26|name=Reading light Gale", "browse-edit:26|category=Lighting", "browse-edit:26|price=79.90",
    "browse-select:5", "browse-state", "wait", f"shot:browse-edits@{title}",
    "appearance:dark", "wait", f"shot:browse-edits-dark@{title}", "appearance:light", "wait",
    # Edit Value: typed by the column, with NULL explicit.
    "browse-editor:4|price=twelve", "browse-editor:set", "wait", f"shot:browse-cell-editor@{title}", "browse-editor:cancel", "wait",
    # Review Changes: the exact statements and their values.
    "browse-review", "wait", "wait", f"shot:browse-review@{title}",
    # Apply: one transaction, then the page is read again.
    "browse-apply", "browse-wait", "wait", "browse-wait", "browse-state", f"shot:browse-applied@{title}",
    # Another session changes row 1 after the page was read: Apply rolls everything back.
    "browse-edit:1|price=24.90", "browse-delete:2",
    f"code:{scratch / 'touch.sql'}", "run", "wait-run",
    "browse-apply", "browse-wait", "wait", "browse-state", f"shot:browse-rollback@{title}",
    "browse-discard", "browse-close", "wait",
    # A table without a primary key: read-only.
    "browse-table:stock_moves", "browse-wait", "frame:stock_moves · Browse=1100x560", "wait", "browse-state", "shot:browse-no-key@stock_moves · Browse", "browse-close", "wait",
    # A read-only saved connection: read-only, whatever the table.
    "perform:file.newSQLTab", "db-new:Replica|sqlite|||data/shop.sqlite|||ro", "db-use:Replica", "wait",
    "sql-schema:load", "wait", "wait", "browse-table:products", "browse-wait", f"frame:{title}=1100x560", "wait", "browse-state", f"shot:browse-read-only@{title}", "browse-close", "wait",
    # Production: reads and Apply ask first; Apply lists every statement.
    "perform:file.newSQLTab", "db-new:Shop (production)|sqlite|||data/shop.sqlite|||production", "db-use:Shop (production)", "wait",
    "sql-schema:load", "wait", "confirm", "wait", "wait",
    "browse-table:products", "wait", "confirm", "browse-wait", f"frame:{title}=1240x760", "wait",
    "browse-edit:1|stock=7", "browse-edit:2|note=Restocked", "browse-delete:4", "browse-review", "wait", "browse-apply", "wait", "wait",
    "shot:browse-production-apply", "cancel", "wait", "browse-state", "browse-discard", "browse-close",
]
log_path = out / "capture.log"
log_path.write_text("")
subprocess.run(["open", "-g", "-j", "-n", "-W",
                "--env", f"RUNLET_DATA_DIR={scratch / 'data'}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                "--stderr", str(log_path), str(app)], check=True)
log = log_path.read_text()
states = [line for line in log.splitlines() if "RUNLET_DEBUG_STATE: browse" in line]
print("\n".join(states))
assert "RUNLET_DEBUG_STEPS: done" in log, log
def state(fragment):
    found = [line for line in states if fragment in line]
    assert found, f"no state with {fragment!r}"
    return found

assert "sort=price desc filters=2" in state("Rows 26–31 of 31")[0], "a filtered, sorted second page"
assert state("changes=4 (2 changed rows, 1 new, 1 deleted)")
assert state("report=Applied 4 changes in one transaction: 4 rows affected.")
assert state("report=Change 2 of 2 (row 1 · id = 1): row not found")
assert "editable=false" in state("browse-state: stock_moves")[0]
assert state("browse-table: products editable=The saved connection “Replica” is read-only")
assert "changes=3" in states[-1], f"production asked and Cancel kept the changes: {states[-1]}"
check = sqlite3.connect(database)
assert check.execute("SELECT COUNT(*) FROM products").fetchone() == (160,), "4 changes applied: one row deleted, one added"
assert check.execute("SELECT price FROM products WHERE id = 2").fetchone() == (129.9,)
assert check.execute("SELECT stock, note FROM products WHERE id = 3").fetchone() == (12, None)
assert check.execute("SELECT COUNT(*) FROM products WHERE id = 5").fetchone() == (0,)
assert check.execute("SELECT category, price, stock FROM products WHERE name = 'Reading light Gale'").fetchone() == ("Lighting", 79.9, 0), "defaults for the rest"
assert check.execute("SELECT price FROM products WHERE id = 1").fetchone() == (20.9,), "the rolled-back Apply left another session's change"
assert check.execute("SELECT stock FROM products WHERE id = 1").fetchone() == (0,), "production's Apply was cancelled"
shots = sorted(out.glob("browse-*.png"))
assert len(shots) == 10, shots
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

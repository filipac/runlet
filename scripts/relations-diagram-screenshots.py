#!/usr/bin/env python3
"""#153: Show Relations end to end in a Debug app, with scratch data only.

Usage: relations-diagram-screenshots.py /path/to/Runlet.app /path/to/output [/path/to/scratch]

Copies the `custom-driver` fixture to a scratch folder and adds an SQLite file for a saved
connection: a small shop (customers, addresses, employees with a manager, products, orders, order
lines with a composite primary key, shipments that reference an order line by both columns,
payments, reviews; neutral names, no rows needed) and a `regions` table that 56 `branch_nn` tables
reference, past the diagram's limit of 50. Then drives the app with RUNLET_DEBUG_STEPS: the
explorer row's menu, the diagram centred on orders (one and two hops), re-centred on order lines
(the composite key) and on employees (the self-reference), Copy Join and Insert Join, dark mode,
the collapsed groups, and both exports. Checks the diagram's state, the copied and inserted JOIN,
and the exported files. The scratch folder (default /private/tmp/runlet-p153) is removed afterwards.
"""
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import xml.dom.minidom

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
scratch = Path(sys.argv[3] if len(sys.argv) > 3 else "/private/tmp/runlet-p153")
root = Path(__file__).resolve().parent.parent
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
project = scratch / "acme"
shutil.copytree(root / "Tests/Fixtures/custom-driver", project, symlinks=True)
(project / "data").mkdir()
shop = sqlite3.connect(project / "data/shop.sqlite")
shop.executescript("""
CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE, country TEXT);
CREATE TABLE addresses (id INTEGER PRIMARY KEY, customer_id INTEGER NOT NULL REFERENCES customers (id), city TEXT, postcode TEXT);
CREATE TABLE employees (id INTEGER PRIMARY KEY, name TEXT NOT NULL, manager_id INTEGER REFERENCES employees (id));
CREATE TABLE categories (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE products (id INTEGER PRIMARY KEY, sku TEXT NOT NULL UNIQUE, title TEXT, price NUMERIC, category_id INTEGER REFERENCES categories (id));
CREATE TABLE orders (
    id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers (id),
    sold_by INTEGER REFERENCES employees (id),
    shipping_address_id INTEGER REFERENCES addresses (id),
    status TEXT NOT NULL DEFAULT 'open',
    placed_at TEXT
);
CREATE TABLE order_lines (
    order_id INTEGER NOT NULL REFERENCES orders (id),
    line_no INTEGER NOT NULL,
    product_id INTEGER NOT NULL REFERENCES products (id),
    qty INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (order_id, line_no)
);
CREATE TABLE shipments (
    id INTEGER PRIMARY KEY,
    order_id INTEGER NOT NULL,
    line_no INTEGER NOT NULL,
    carrier TEXT,
    FOREIGN KEY (order_id, line_no) REFERENCES order_lines (order_id, line_no)
);
CREATE TABLE payments (id INTEGER PRIMARY KEY, order_id INTEGER NOT NULL REFERENCES orders (id), amount NUMERIC NOT NULL, paid_at TEXT);
CREATE TABLE reviews (id INTEGER PRIMARY KEY, product_id INTEGER NOT NULL REFERENCES products (id), customer_id INTEGER REFERENCES customers (id), rating INTEGER);
CREATE VIEW order_totals AS SELECT order_id, SUM(qty) AS items FROM order_lines GROUP BY order_id;
CREATE TABLE countries (code TEXT PRIMARY KEY, name TEXT);
CREATE TABLE regions (id INTEGER PRIMARY KEY, name TEXT, country_code TEXT REFERENCES countries (code));
""")
for n in range(1, 57):
    shop.execute(f"CREATE TABLE branch_{n:02d} (id INTEGER PRIMARY KEY, region_id INTEGER NOT NULL REFERENCES regions (id), name TEXT)")
shop.commit()
shop.close()

query = scratch / "orders.sql"
query.write_text("-- Orders with their customer\nSELECT *\nFROM orders\n")

svg_path = out / "relations-export.svg"
png_path = out / "relations-export.png"
size = "frame:Relations · {}=1280x820"
steps = [
    "ghost", "scale:2", "frame:1280x820", "appearance:light", f"project:{project}", "wait",
    "perform:file.newSQLTab", "db-new:Shop|sqlite|||data/shop.sqlite", "db-use:Shop", f"code:{query}", "caret:end", "wait",
    "inspector:database", "sql-schema:load", "wait", "schema-expand:orders", "wait",
    # The explorer row's menu has Show Relations (a menu can't be drawn: a DEBUG popover shows it).
    "schema-search:orders", "wait", "schema-menu:orders", "wait", "shot:relations-menu", "schema-menu:off", "schema-search:", "wait",
    # Centred on orders, one hop, then two.
    "relations:orders", "wait", "wait", size.format("orders"), "wait", "relations-state", "shot:relations-orders-one-hop@Relations · orders",
    "relations-hops:2", "wait", "relations-zoom:fit", "wait", "relations-state", "shot:relations-orders-two-hops@Relations · orders", "relations-zoom:100",
    # Re-centred on order_lines: the shipments composite key is one line with both pairs.
    "relations-focus:order_lines", "wait", "relations-hops:1", "wait", "relations-state", "shot:relations-composite@Relations · order_lines",
    # Copy Join on the composite key: the line's menu, then the footer with its JOIN.
    "relations-key-menu:shipments|order_lines", "wait", "shot:relations-copy-join-menu@Relations · order_lines", "relations-key-menu:off", "wait",
    "relations-select:shipments|order_lines", "wait", "relations-copy-join", "relations-state", "shot:relations-copy-join@Relations · order_lines",
    # The self-reference, then Back and Forward.
    "relations-focus:employees", "wait", "relations-state", "shot:relations-self-reference@Relations · employees",
    "relations-back", "wait", "relations-state", "relations-forward", "wait", "relations-state",
    # Insert Join into the SQL tab (orders → customers), from the orders diagram.
    "relations-back", "relations-back", "wait", "relations-select:orders|customers", "relations-insert-join", "wait",
    # Dark mode, two hops, all columns.
    "relations-hops:2", "relations-columns:all", "relations-select:", "appearance:dark", "relations-zoom:fit", "wait", "wait", "shot:relations-dark@Relations · orders", "appearance:light", "relations-zoom:100",
    "relations-columns:keys", "wait",
    # Past 50 related tables: collapsed groups, then one expanded.
    "relations:regions", "wait", "wait", size.format("regions"), "wait", "relations-zoom:fit", "wait", "relations-state", "shot:relations-collapsed@Relations · regions",
    "relations-expand:referencing-1", "wait", "relations-state",
    # Exports of the orders diagram (the latest is regions: re-centre it on orders, two hops).
    "relations-focus:orders", "relations-hops:2", "wait", f"relations-export:svg:{svg_path}", f"relations-export:png:{png_path}",
]
log_path = out / "capture.log"
log_path.write_text("")
subprocess.run(["open", "-g", "-j", "-n", "-W",
                "--env", f"RUNLET_DATA_DIR={scratch / 'data'}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                "--stderr", str(log_path), str(app)], check=True)
log = log_path.read_text()
states = [line.split("RUNLET_DEBUG_STATE: ", 1)[1] for line in log.splitlines() if "RUNLET_DEBUG_STATE: relations" in line]
print("\n".join(states))
assert "RUNLET_DEBUG_STEPS: done" in log, log
diagram = [line for line in states if line.startswith("relations-state:")]
one_hop, two_hops, composite, copied_state, self_ref, back, forward, collapsed, expanded = diagram
assert "Relations · orders" in one_hop and "hops 1" in one_hop and "window 1280x820" in one_hop, one_hop
assert "tables addresses[referenced 1], customers[referenced 1], employees[referenced 1], orders[focus 0], order_lines[referencing 1], payments[referencing 1]" in one_hop, one_hop
assert "employees.manager_id → employees.id (loop)" in one_hop, one_hop
assert "hops 2" in two_hops and "products[referencing 2]" in two_hops and "shipments[referencing 2]" in two_hops and "reviews[referenced 2]" in two_hops, two_hops
assert "Relations · order_lines" in composite and "shipments(order_id, line_no) → order_lines(order_id, line_no)" in composite, composite
assert "history orders > order_lines at order_lines" in composite, composite
copy = next(line for line in states if line.startswith("relations-copy-join:"))
assert copy == "relations-copy-join: copied JOIN shipments ON shipments.order_id = order_lines.order_id AND shipments.line_no = order_lines.line_no", copy
assert "selected shipments(order_id, line_no)" in copied_state, copied_state
assert "Relations · employees" in self_ref and "employees.manager_id → employees.id (loop)" in self_ref, self_ref
assert "at order_lines" in back and "at employees" in forward, (back, forward)
inserted = next(line for line in states if line.startswith("relations-insert-join:"))
assert "inserted into" in inserted and "FROM orders⏎JOIN customers ON customers.id = orders.customer_id" in inserted, inserted
assert "Relations · regions" in collapsed and "groups referencing-1 +7 more" in collapsed and "7 collapsed" in collapsed, collapsed
assert "groups " in expanded and "+7 more" not in expanded and "branch_56[referencing 1]" in expanded, expanded
exports = [line for line in states if line.startswith("relations-export:")]
assert len(exports) == 2 and all("wrote" in line for line in exports), exports
xml.dom.minidom.parse(str(svg_path))  # well-formed
assert png_path.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
shots = sorted(out.glob("relations-*.png"))
print("ok:", [p.name for p in shots])
shutil.rmtree(scratch)

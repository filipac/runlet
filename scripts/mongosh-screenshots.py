#!/usr/bin/env python3
"""#220: mongosh queries in a MongoDB tab, end to end in a Debug app, with scratch data only.

Usage: mongosh-screenshots.py /path/to/Runlet.app /path/to/output <mongo port> [/path/to/scratch]

Seeds `p220_shop.p220_orders` idempotently in the fixture `mongo:7` container
(`scripts/setup-fixtures.sh databases`, `runlet-fixtures-mongo-1`) through the fixtures-only
Docker CLI, and saves a connection to it (the fixture password, kept in memory by a scratch
RUNLET_DATA_DIR). Then drives the app with RUNLET_DEBUG_STEPS: a mongosh find runs and the output
names the JSON query it ran as (light and dark), Run History keeps that JSON; a deleteMany({})
reaches the danger sheet as its translated JSON and is cancelled (nothing is deleted); a query
with $where is refused before anything runs. The scratch folder (default
/private/tmp/runlet-p220) is removed afterwards.
"""
from pathlib import Path
import shutil
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
port = sys.argv[3]
scratch = Path(sys.argv[4] if len(sys.argv) > 4 else "/private/tmp/runlet-p220")
root = Path(__file__).resolve().parent.parent
docker = str(root / "Tests/Fixtures/docker/fixtures-only-docker")
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
scratch.mkdir(parents=True)

SEED = r"""
const shop = db.getSiblingDB("p220_shop");
shop.p220_orders.drop();
const cities = ["Oslo", "Lisbon", "Vienna", "Porto", "Ghent"];
const statuses = ["paid", "pending", "shipped", "paid", "void"];
const orders = [];
for (let i = 1; i <= 40; i++) {
  orders.push({ number: 1000 + i, status: statuses[i % statuses.length], customer: { name: "Customer " + (i % 9 + 1), city: cities[i % cities.length] },
    total: NumberDecimal(((i * 53) % 400 + 19.5).toFixed(2)), placed_at: new Date(Date.UTC(2026, i % 9, 1 + (i % 27), 9 + (i % 8), 30)) });
}
shop.p220_orders.insertMany(orders);
print(shop.p220_orders.countDocuments() + " orders");
"""
seeded = subprocess.run([docker, "exec", "-i", "runlet-fixtures-mongo-1", "mongosh", "--quiet", "-u", "runlet", "-p", "runlet-fixture",
                         "--authenticationDatabase", "admin"], input=SEED, check=True, capture_output=True, text=True).stdout
assert "40 orders" in seeded, seeded

FIND = """// Paid orders over 100 since March, newest first
db.p220_orders.find(
  {
    status: 'paid',
    placed_at: {$gte: ISODate('2026-03-01')},
    total: {$gt: NumberDecimal('100')},  /* Decimal128 */
  },
  {_id: 0, number: 1, total: 1, placed_at: 1, 'customer.city': 1},
).sort({placed_at: -1}).limit(10)
"""
DELETE = """// Everything: the danger sheet asks first
db.p220_orders.deleteMany({})
"""
REFUSED = """db.p220_orders.find({
  status: 'paid',
  $where: 'this.total > 100',
})
"""
for name, text in [("find.mongodb", FIND), ("delete.mongodb", DELETE), ("refused.mongodb", REFUSED)]:
    (scratch / name).write_text(text)

steps = [
    "ghost", "scale:2", "frame:1400x860", "appearance:light", "wait",
    "perform:file.newMongoDBTab", f"db-new:Shop|mongodb|127.0.0.1|{port}|p220_shop|runlet|runlet-fixture", "db-use:Shop", "wait",
    # A mongosh find: the output's first line names the JSON query it ran as.
    f"code:{scratch / 'find.mongodb'}", "caret:1", "wait", "mongosh-state",
    "run", "wait-run", "wait", "mongosh-state", "shot:mongosh-find",
    "appearance:dark", "wait", "shot:mongosh-find-dark", "appearance:light", "wait",
    # deleteMany({}): the danger sheet shows the translated JSON; cancelled, nothing runs.
    f"code:{scratch / 'delete.mongodb'}", "caret:1", "wait", "run", "wait", "mongosh-state", "shot:mongosh-danger",
    "mongo-confirm:no", "wait", "mongosh-state",
    # $where: refused before anything runs (an alert, so it's shot last).
    f"code:{scratch / 'refused.mongodb'}", "caret:1", "wait", "run", "wait", "mongosh-state", "shot:mongosh-refused",
]
log_path = out / "capture.log"
log_path.write_text("")
subprocess.run(["open", "-g", "-j", "-n", "-W",
                "--env", f"RUNLET_DATA_DIR={scratch / 'data'}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                "--stderr", str(log_path), str(app)], check=True)
log = log_path.read_text()
states = [line.split("RUNLET_DEBUG_STATE: ", 1)[1] for line in log.splitlines() if "RUNLET_DEBUG_STATE: mongosh " in line]
print("\n".join(s[:900] for s in states))
assert "RUNLET_DEBUG_STEPS: done" in log, log[-3000:]
assert len(states) == 5, states
before, ran, danger, cancelled, refused = states
assert 'json={ "collection": "p220_orders", "operation": "find", "filter": { "status": "paid", "placed_at": { "$gte": { "$date": "2026-03-01T00:00:00Z" } }' in before, before
assert "note=mongosh query on the saved connection “Shop”" in ran and 'run as this JSON query: { "collection": "p220_orders", "operation": "find"' in ran, ran
assert 'history={⏎  "collection": "p220_orders",⏎  "operation": "find",' in ran, ran
assert 'danger=Run deleteMany on the collection “p220_orders” in the database “p220_shop”' in danger, danger
assert 'Line 2: deleteMany has an empty filter: it deletes every document of “p220_orders”.' in danger, danger
assert r'{ \"collection\": \"p220_orders\", \"operation\": \"deleteMany\", \"filter\": {} }' in danger, danger
assert "danger=-" in cancelled and 'history={⏎  "collection": "p220_orders",⏎  "operation": "find",' in cancelled, cancelled
assert "alert=Couldn't translate the mongosh query: Line 3, column 3: $where runs JavaScript on the server" in refused and "Nothing ran." in refused, refused
remaining = subprocess.run([docker, "exec", "runlet-fixtures-mongo-1", "mongosh", "--quiet", "-u", "runlet", "-p", "runlet-fixture",
                            "--authenticationDatabase", "admin", "--eval", 'db.getSiblingDB("p220_shop").p220_orders.countDocuments()'],
                           check=True, capture_output=True, text=True).stdout.strip()
assert remaining == "40", f"the cancelled deleteMany deleted documents: {remaining} left"
subprocess.run([docker, "exec", "runlet-fixtures-mongo-1", "mongosh", "--quiet", "-u", "runlet", "-p", "runlet-fixture",
                "--authenticationDatabase", "admin", "--eval", 'db.getSiblingDB("p220_shop").dropDatabase()'], check=True, capture_output=True)
shots = sorted(out.glob("mongosh-*.png"))
assert len(shots) == 4, shots
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

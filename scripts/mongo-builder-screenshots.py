#!/usr/bin/env python3
"""#217: the MongoDB query builder end to end in a Debug app, with scratch data only.

Usage: mongo-builder-screenshots.py /path/to/Runlet.app /path/to/output <mongo port> [/path/to/scratch]

Seeds `p217_shop` (`p217_orders` and `p217_customers`: ObjectIds, UTC dates, Decimal128, Int64,
embedded documents, arrays, nulls) idempotently in the fixture `mongo:7` container
(`scripts/setup-fixtures.sh databases`, `runlet-fixtures-mongo-1`) with mongosh, and saves a
connection to it (the fixture password, kept in memory by a scratch RUNLET_DATA_DIR). Then drives
the app with RUNLET_DEBUG_STEPS: Start from Collection on a blank tab; a find built in the
builder (typed date, ObjectId and Decimal128 inputs, an Any-of group, projection, sort, limit)
and run as written; an aggregation (`$match`, `$lookup`, `$unwind`, `$group`, `$sort`) and its
result; an update; a hand-written tab of two queries read back with raw JSON blocks; a query the
builder can't read; dark mode. It checks one Undo step per write and one write per burst of
changes. The scratch folder (default /private/tmp/runlet-p217) is removed afterwards.
"""
from pathlib import Path
import json
import shutil
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
port = sys.argv[3]
scratch = Path(sys.argv[4] if len(sys.argv) > 4 else "/private/tmp/runlet-p217")
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
scratch.mkdir(parents=True)

SEED = r"""
const shop = db.getSiblingDB("p217_shop");
shop.p217_orders.drop();
shop.p217_customers.drop();
const cities = ["Cluj-Napoca", "Bucharest", "Iasi", "Timisoara", "Brasov"];
const customers = [];
for (let i = 1; i <= 12; i++) {
  customers.push({ _id: ObjectId("66a00000000000000000000" + i.toString(16)), name: "Customer " + i, vip: i % 4 === 0,
    address: { city: cities[i % cities.length], zip: String(400000 + i * 7) }, since: new Date(Date.UTC(2024, i % 12, 1 + i)) });
}
shop.p217_customers.insertMany(customers);
const statuses = ["paid", "pending", "shipped", "void"];
const orders = [];
for (let i = 1; i <= 60; i++) {
  const c = customers[i % customers.length];
  orders.push({ number: 1000 + i, status: statuses[i % statuses.length], customer_id: c._id, customer: { name: c.name, city: c.address.city },
    total: NumberDecimal(((i * 37) % 500 + 9.5).toFixed(2)), items: [{ sku: "SKU-" + (i % 7), qty: 1 + (i % 3) }, { sku: "SKU-" + ((i + 3) % 7), qty: 1 }],
    tags: i % 5 === 0 ? ["gift", "priority"] : ["web"], placed_at: new Date(Date.UTC(2026, i % 9, 1 + (i % 27), 9 + (i % 8), 30)),
    weight: NumberLong(String(250 * (1 + i % 6))), note: i % 6 === 0 ? null : "Order " + i });
}
shop.p217_orders.insertMany(orders);
print(shop.p217_orders.countDocuments() + " orders");
"""
(scratch / "seed.js").write_text(SEED)
subprocess.run(["docker", "cp", str(scratch / "seed.js"), "runlet-fixtures-mongo-1:/tmp/p217-seed.js"], check=True)
seeded = subprocess.run(["docker", "exec", "runlet-fixtures-mongo-1", "mongosh", "--quiet", "-u", "runlet", "-p", "runlet-fixture",
                         "--authenticationDatabase", "admin", "/tmp/p217-seed.js"], check=True, capture_output=True, text=True).stdout
assert "60 orders" in seeded, seeded


def arg(query):
    """A query as one step argument: compact JSON, commas as \\c."""
    return json.dumps(query, separators=(", ", ": ")).replace(",", "\\c")


FIND = {
    "collection": "p217_orders", "operation": "find",
    "filter": {
        "status": {"$in": ["paid", "shipped"]},
        "placed_at": {"$gte": {"$date": "2026-03-01T00:00:00Z"}, "$lt": {"$date": "2026-08-01T00:00:00Z"}},
        "total": {"$gte": {"$numberDecimal": "100.00"}},
        "$or": [{"customer_id": {"$oid": "66a000000000000000000004"}}, {"tags": "priority"}, {"customer.city": {"$regex": "^cluj", "$options": "i"}}],
    },
    "projection": {"number": 1, "status": 1, "total": 1, "placed_at": 1, "customer.city": 1, "_id": 0},
    "sort": {"placed_at": -1, "number": 1},
    "limit": 20,
}
AGGREGATE = {
    "collection": "p217_orders", "operation": "aggregate",
    "pipeline": [
        {"$match": {"status": {"$ne": "void"}, "placed_at": {"$gte": {"$date": "2026-01-01T00:00:00Z"}}}},
        {"$lookup": {"from": "p217_customers", "localField": "customer_id", "foreignField": "_id", "as": "customer_doc"}},
        {"$unwind": "$customer_doc"},
        {"$group": {"_id": "$customer_doc.address.city", "orders": {"$count": {}}, "revenue": {"$sum": "$total"}, "vips": {"$max": "$customer_doc.vip"}}},
        {"$sort": {"revenue": -1}},
        {"$limit": 5},
    ],
}
UPDATE = {
    "collection": "p217_orders", "operation": "updateMany",
    "filter": {"status": "pending", "placed_at": {"$lt": {"$date": "2026-02-01T00:00:00Z"}}},
    "update": {"$set": {"status": "void", "voided_at": {"$date": "2026-10-04T09:30:00Z"}}, "$inc": {"revision": 1}, "$unset": {"note": ""}, "$push": {"tags": "auto-void"}},
}
HAND = """{
  "collection": "p217_orders",
  "operation": "countDocuments",
  "filter": { "status": "paid" }
}

{
  "operation": "aggregate",
  "collection": "p217_orders",
  "pipeline": [
    { "$match": { "items": { "$elemMatch": { "qty": { "$gte": 2 } } }, "status": "paid" } },
    { "$facet": { "byCity": [{ "$sortByCount": "$customer.city" }], "count": [{ "$count": "n" }] } }
  ]
}
"""
BROKEN = """{
  "collection": "p217_orders",
  "operation": "find",
  "filter": { "status": "paid", }
}
"""
(scratch / "hand.json").write_text(HAND)
(scratch / "broken.json").write_text(BROKEN)

steps = [
    "ghost", "scale:2", "frame:1720x1000", "appearance:light", "wait",
    "perform:file.newMongoDBTab", f"db-new:Shop|mongodb|127.0.0.1|{port}|p217_shop|runlet|runlet-fixture", "db-use:Shop", "wait",
    "mongo-explorer", "wait-run", "mongo-sample:p217_orders", "wait-run", "mongo-sample:p217_customers", "wait-run",
    "inspector:", "section:", "wait",
    # A blank tab: Start from Collection.
    "mongo-builder:open", "wait", "mongo-builder:state", "shot:builder-start",
    "mongo-builder-start:p217_orders", "wait", "mongo-builder:state",
    # A find built in the forms: written into the tab, then run as written.
    f"mongo-builder-set:{arg(FIND)}", "wait", "mongo-builder:state", "shot:builder-filter",
    "mongo-builder-scroll:mongo-builder-projection", "wait", "shot:builder-projection-sort",
    "run", "wait-run", "wait", "shot:builder-find-result",
    # Typing a value is one write; each write is one Undo step.
    "mongo-builder:burst", "wait", "mongo-builder:state", "mongo-builder:undo-check",
    # An aggregation.
    f"mongo-builder-set:{arg(AGGREGATE)}", "wait", "mongo-builder-scroll:mongo-builder-top", "wait", "mongo-builder:state", "shot:builder-pipeline",
    "mongo-builder-scroll:mongo-builder-stage-3", "wait", "shot:builder-pipeline-group",
    "run", "wait-run", "wait", "shot:builder-aggregate-result",
    # An update (written, not run).
    f"mongo-builder-set:{arg(UPDATE)}", "wait", "mongo-builder-scroll:mongo-builder-top", "wait", "mongo-builder:state", "shot:builder-update",
    # Filter by This Value adds a rule.
    'mongo-builder-filter:customer_id|{"$oid": "66a000000000000000000004"}', "wait", "mongo-builder:state",
    # Dark mode.
    f"mongo-builder-set:{arg(FIND)}", "wait", "appearance:dark", "mongo-builder-scroll:mongo-builder-top", "wait", "shot:builder-dark", "appearance:light", "wait",
    # A hand-written tab of two queries: the caret's query is read back, the unsupported parts as JSON.
    "perform:file.newMongoDBTab", "db-use:Shop", f"code:{scratch / 'hand.json'}", "caret:10", "wait",
    "mongo-builder:open", "wait", "mongo-builder:state", "shot:builder-read-back",
    "appearance:dark", "wait", "shot:builder-read-back-dark", "appearance:light", "wait",
    # A query the builder can't read: a note, and Start from Collection; the text stays.
    f"code:{scratch / 'broken.json'}", "caret:2", "mongo-builder:read", "wait", "mongo-builder:state", "shot:builder-unreadable",
]
log_path = out / "capture.log"
log_path.write_text("")
subprocess.run(["open", "-g", "-j", "-n", "-W",
                "--env", f"RUNLET_DATA_DIR={scratch / 'data'}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                "--stderr", str(log_path), str(app)], check=True)
log = log_path.read_text()
states = [line.split("RUNLET_DEBUG_STATE: ", 1)[1] for line in log.splitlines() if "RUNLET_DEBUG_STATE: mongo-builder" in line]
print("\n".join(s[:600] for s in states))
assert "RUNLET_DEBUG_STEPS: done" in log, log[-3000:]
s = [line for line in states if line.startswith("mongo-builder: ")]
assert "phase=fresh" in s[0], s[0]
assert '"collection": "p217_orders"' in s[1] and "writes=1" in s[1], s[1]
assert "writes=2" in s[2] and "note=Wrote the query on lines 1–" in s[2] and '"$oid": "66a000000000000000000004"' in s[2] and "effect=read" in s[2], s[2]
assert "writes=3" in s[3] and '"limit": 50' in s[3], f"one write for the burst: {s[3]}"
assert any(line.startswith("mongo-builder undo-check: ok") for line in states), states
assert '"$lookup"' in s[4] and "effect=read" in s[4], s[4]
assert '"$inc"' in s[5] and "effect=write" in s[5], s[5]
assert '"customer_id": { "$oid": "66a000000000000000000004" }' in s[6], s[6]
assert "phase=ready" in s[7] and "raw=2" in s[7] and "countDocuments" in s[7] and "lines=7-14" in s[7], s[7]
assert "phase=unreadable" in s[8] and '"status": "paid", }' in s[8], s[8]
shots = sorted(out.glob("builder-*.png"))
assert len(shots) == 12, shots
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

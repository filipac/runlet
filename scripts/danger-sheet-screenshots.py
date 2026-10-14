#!/usr/bin/env python3
"""#367: the risky confirmations of database tabs, in a Debug app, with scratch data only.

Usage: danger-sheet-screenshots.py /path/to/Runlet.app /path/to/output <mongo port> <redis port> [/path/to/scratch]

Uses the `runlet-fixtures` `mongo` and `redis` containers (`scripts/setup-fixtures.sh databases`)
through the fixtures-only Docker CLI: seeds `p367_shop.orders` and Redis database 12, starts a
slow report on MongoDB (application name `nightly-report`) and a worker blocked in BLPOP on Redis,
so Kill Op and Kill Client have something to ask about. Then takes, in light and dark: MongoDB's
deleteMany({}) confirmation, Kill Op's, Redis's FLUSHDB, and Kill Client's. Every confirmation is
cancelled, so nothing is deleted, flushed, or killed: the script checks that afterwards. The
scratch folder (default /private/tmp/runlet-p367) is removed afterwards.
"""
from pathlib import Path
import shutil
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
mongo_port, redis_port = sys.argv[3], sys.argv[4]
scratch = Path(sys.argv[5] if len(sys.argv) > 5 else "/private/tmp/runlet-p367")
root = Path(__file__).resolve().parent.parent
docker = str(root / "Tests/Fixtures/docker/fixtures-only-docker")
password = "runlet-fixture"
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
scratch.mkdir(parents=True)


def mongosh(script: str) -> str:
    return subprocess.run([docker, "exec", "runlet-fixtures-mongo-1", "mongosh", "--quiet", "-u", "runlet", "-p", password, "--authenticationDatabase", "admin",
                           "--eval", script], check=True, capture_output=True, text=True).stdout.strip()


def redis(*args: str) -> str:
    return subprocess.run([docker, "exec", "runlet-fixtures-redis-1", "redis-cli", "-a", password, "--no-auth-warning", "-n", "12", *args],
                          check=True, capture_output=True, text=True).stdout.strip()


mongosh('const s = db.getSiblingDB("p367_shop"); s.orders.drop(); s.orders.insertMany([1, 2, 3].map(n => ({n, status: "paid"}))); print(s.orders.countDocuments())')
redis("SET", "greeting", "hello")
(scratch / "delete.mongodb").write_text("// Every order: the confirmation asks first\ndb.orders.deleteMany({})\n")
(scratch / "flush.redis").write_text("# Empties the connection's database\nFLUSHDB\n")


def both(name: str) -> list[str]:
    return [f"shot:{name}-light", "appearance:dark", "wait", f"shot:{name}-dark", "appearance:light", "wait"]


def launch(name: str, steps: list[str]) -> str:
    """One hidden Runlet with its own scratch data; its log."""
    log_path = out / f"capture-{name}.log"
    log_path.write_text("")
    subprocess.run(["open", "-g", "-j", "-n", "-W",
                    "--env", f"RUNLET_DATA_DIR={scratch / name}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                    "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                    "--stderr", str(log_path), str(app)], check=True)
    log = log_path.read_text()
    assert "RUNLET_DEBUG_STEPS: done" in log, log[-3000:]
    return log


# Redis: FLUSHDB, then Kill Client on a worker blocked in BLPOP (ended on the fixture afterwards).
blocked = subprocess.Popen([docker, "exec", "-i", "runlet-fixtures-redis-1", "redis-cli", "-a", password, "--no-auth-warning", "-n", "12"],
                           stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
blocked.stdin.write("CLIENT SETNAME mail-worker\nBLPOP queue:emails 120\n")
blocked.stdin.close()
try:
    redis_log = launch("redis", ["ghost", "scale:2", "frame:1300x820", "appearance:light", "wait",
                     "perform:file.newRedisTab", f"db-new:Shop cache|redis|127.0.0.1|{redis_port}|12||{password}|mac", "db-use:Shop cache", "wait",
                     f"code:{scratch / 'flush.redis'}", "caret:1", "wait", "redis-danger:ask", "run", "wait"] + both("danger-flushdb") +
           ["redis-danger:cancel", "wait", "inspector:database", "redis-server", "wait", "wait", "redis-kill:blocked", "wait"] + both("danger-kill-client") +
           ["redis-kill:cancel", "wait"])
finally:
    blocked.terminate()
    for line in redis("CLIENT", "LIST").splitlines():
        if " name=mail-worker " in line:
            redis("CLIENT", "KILL", "ID", line.split(" ", 1)[0].removeprefix("id="))

# MongoDB: deleteMany({}), then Kill Op on a slow report (the server ends its JavaScript after a
# minute, so it starts right before; it's ended on the fixture afterwards).
slow = subprocess.Popen([docker, "exec", "runlet-fixtures-mongo-1", "mongosh", "--quiet",
                         f"mongodb://runlet:{password}@127.0.0.1:27017/p367_shop?authSource=admin&appName=nightly-report",
                         "--eval", "db.orders.find({$where: 'sleep(55000) || true'}).limit(1).toArray()"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    log = launch("mongo", ["ghost", "scale:2", "frame:1300x820", "appearance:light", "wait",
                           "perform:file.newMongoDBTab", f"db-new:Shop|mongodb|127.0.0.1|{mongo_port}|p367_shop|runlet|{password}|mac", "db-use:Shop", "wait",
                           "inspector:database", "mongo-server", "wait", "mongo-kill:app=nightly-report", "wait", "mongo-server-state"] + both("danger-kill-op") +
                 ["mongo-kill-confirm:no", "wait", "mongo-server-state", "inspector:",
                  f"code:{scratch / 'delete.mongodb'}", "caret:1", "wait", "run", "wait", "mongo-state"] + both("danger-mongo") +
                 ["mongo-confirm:no", "wait", "mongo-state"])
finally:
    slow.terminate()
    mongosh('db.getSiblingDB("admin").aggregate([{$currentOp: {}}, {$match: {appName: "nightly-report"}}]).forEach(op => db.killOp(op.opid))')

assert "redis-kill: no client" not in redis_log and "redis-kill: read the server first" not in redis_log, "Kill Client didn't ask"
states = [line.split("RUNLET_DEBUG_STATE: ", 1)[1] for line in log.splitlines() if "RUNLET_DEBUG_STATE: mongo" in line]
print("\n".join(s[:400] for s in states))
assert "kill=Kill operation" in states[0], states[0]
assert "kill=-" in states[1], states[1]
assert "danger=Run deleteMany on the collection “orders”" in states[2], states[2]
assert "danger=-" in states[3], states[3]
assert mongosh('print(db.getSiblingDB("p367_shop").orders.countDocuments())').endswith("3"), "the cancelled deleteMany deleted documents"
assert redis("GET", "greeting") == "hello", "the cancelled FLUSHDB flushed"
mongosh('db.getSiblingDB("p367_shop").dropDatabase()')
redis("DEL", "greeting")
shots = sorted(out.glob("danger-*.png"))
assert len(shots) == 8, shots
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

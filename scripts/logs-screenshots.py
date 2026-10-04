#!/usr/bin/env python3
"""#20: the Logs window end to end in a Debug app, with scratch data and neutral names only.

Usage: logs-screenshots.py /path/to/Runlet.app /path/to/output [local|docker|ssh|all]

Seeds a scratch RUNLET_DATA_DIR under /private/tmp/runlet-p20 with:
- a local project "shop" (a plain PHP folder) whose storage/logs holds generated Monolog logs: a
  Laravel-style laravel.log with a multi-line stack trace, a nested daily log, and a JSON-formatter
  queue log; the frames point at files of the project, so their links open (logged here);
- a Docker profile "shop-docker" on the runlet-fixtures Laravel container (no local folder), reached
  through Tests/Fixtures/docker/fixtures-only-docker, so Runlet sees no other container;
- an SSH profile "shop-server" on the runlet-fixtures SSH host (127.0.0.1:2222) through a throwaway
  key and config (RUNLET_SSH_CONFIG); SSH_AUTH_SOCK is empty and ~/.ssh is never read.

Then drives the app with RUNLET_DEBUG_STEPS and checks what it printed: the picker, parsed
entries (collapsed and expanded, frame links), the JSON formatter, level filter and search,
Follow on a file (lines appended while following), Logs written by the last run (a snippet that
writes to the log), dark mode, a `docker logs` follow and a `docker exec … tail -F` follow, an
SSH `tail -F` follow, the Connection Manager listing them, and that Stop and closing leave no
`tail` behind in the container or on the server.
"""
from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
which = sys.argv[3] if len(sys.argv) > 3 else "all"
out.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
scratch = Path("/private/tmp/runlet-p20")
shutil.rmtree(scratch, ignore_errors=True)
scratch.mkdir(parents=True)
project = scratch / "shop"
now = time.time() - 978307200  # Foundation's reference date
fixtures_docker = root / "Tests/Fixtures/docker/fixtures-only-docker"

# MARK: The project and its logs

for relative in ["app/Services/Totals.php", "app/Http/Controllers/OrderController.php", "app/Jobs/SendInvoice.php",
                 "vendor/laravel/framework/src/Illuminate/Routing/Controller.php", "vendor/laravel/framework/src/Illuminate/Queue/CallQueuedHandler.php"]:
    path = project / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("<?php\n\n" + "\n".join(f"// line {n}" for n in range(3, 80)) + "\n")
(project / "index.php").write_text("<?php\n")
logs = project / "storage/logs"
logs.mkdir(parents=True)
P = str(project)


def stamp(minute, second):
    return f"2026-10-04 09:{minute:02d}:{second:02d}"


TRACE = f"""[stacktrace]
#0 {P}/app/Http/Controllers/OrderController.php(31): App\\\\Services\\\\Totals->average()
#1 {P}/vendor/laravel/framework/src/Illuminate/Routing/Controller.php(54): App\\\\Http\\\\Controllers\\\\OrderController->show()
#2 {P}/vendor/laravel/framework/src/Illuminate/Routing/ControllerDispatcher.php(43): Illuminate\\\\Routing\\\\Controller->callAction()
#3 {P}/vendor/laravel/framework/src/Illuminate/Routing/Route.php(260): Illuminate\\\\Routing\\\\ControllerDispatcher->dispatch()
#4 {P}/vendor/laravel/framework/src/Illuminate/Routing/Router.php(808): Illuminate\\\\Routing\\\\Route->run()
#5 {P}/public/index.php(17): Illuminate\\\\Foundation\\\\Http\\\\Kernel->handle()
#6 {{main}}
"}} """
lines = [
    f"[{stamp(14, 2)}] local.DEBUG: Cache miss {{\"key\":\"pricing:eu\"}} []",
    f"[{stamp(14, 2)}] local.INFO: Importing orders {{\"batch\":42,\"source\":\"api\"}} []",
    f"[{stamp(14, 5)}] local.INFO: Imported 120 orders {{\"batch\":42,\"ms\":812}} []",
    f"[{stamp(15, 11)}] local.NOTICE: Coupon SPRING expires tomorrow [] []",
    f"[{stamp(15, 40)}] local.WARNING: Slow query {{\"ms\":1240,\"sql\":\"select * from orders where status = ?\"}} []",
    f"[{stamp(16, 3)}] local.ERROR: Division by zero {{\"userId\":7,\"exception\":\"[object] (DivisionByZeroError(code: 0): Division by zero at {P}/app/Services/Totals.php:18)\n" + TRACE,
    f"[{stamp(16, 9)}] local.INFO: Order 1041 shipped {{\"order\":1041,\"carrier\":\"post\"}} []",
    f"[{stamp(17, 22)}] local.CRITICAL: Payment gateway unreachable {{\"gateway\":\"acme-pay\",\"attempts\":3}} []",
    f"[{stamp(17, 30)}] local.INFO: Retrying payments {{\"queue\":\"payments\"}} []",
    f"[{stamp(18, 1)}] local.DEBUG: Mail queued {{\"to\":\"customer@example.com\",\"template\":\"invoice\"}} []",
]
(logs / "laravel.log").write_text("\n".join(lines) + "\n")
daily = logs / "2026/10"
daily.mkdir(parents=True)
(daily / "laravel-2026-10-03.log").write_text("\n".join(
    f"[2026-10-03 18:{m:02d}:00] local.INFO: Nightly report {m} {{\"rows\":{m * 7}}} []" for m in range(0, 30, 3)) + "\n")
queue = [
    {"message": "Processing job", "context": {"job": "App\\Jobs\\SendInvoice", "order": 1040}, "level": 200, "level_name": "INFO", "channel": "queue", "datetime": "2026-10-04T09:12:00.120000+00:00", "extra": {}},
    {"message": "Job failed", "context": {"job": "App\\Jobs\\SendInvoice", "exception": {"class": "RuntimeException", "message": "SMTP timeout", "code": 0,
     "file": f"{P}/app/Jobs/SendInvoice.php:27", "trace": [f"{P}/vendor/laravel/framework/src/Illuminate/Queue/CallQueuedHandler.php:130"]}},
     "level": 400, "level_name": "ERROR", "channel": "queue", "datetime": "2026-10-04T09:12:04.500000+00:00", "extra": {"attempt": 2}},
    {"message": "Job released", "context": {"job": "App\\Jobs\\SendInvoice", "delay": 60}, "level": 300, "level_name": "WARNING", "channel": "queue", "datetime": "2026-10-04T09:12:04.600000+00:00", "extra": {}},
]
(logs / "worker").mkdir()
(logs / "worker/queue.log").write_text("\n".join(json.dumps(entry) for entry in queue) + "\n")


def append(path, text):
    with open(path, "a") as handle:
        handle.write(text)


# MARK: SSH fixture: a throwaway key and config, and logs on the server

ssh_container = subprocess.run(["docker", "compose", "-p", "runlet-fixtures", "ps", "-q", "ssh"], capture_output=True, text=True).stdout.strip()
laravel_container = subprocess.run(["docker", "compose", "-p", "runlet-fixtures", "ps", "-q", "laravel"], capture_output=True, text=True).stdout.strip()
ssh_dir = scratch / "ssh"
ssh_dir.mkdir()
config = ssh_dir / "config"
server_site = "/home/runlet/p20-site"
if which in ("ssh", "all"):
    assert ssh_container, "the runlet-fixtures ssh service isn't running"
    key = ssh_dir / "id_ed25519"
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "runlet-p20", "-f", str(key)], check=True)
    subprocess.run(["docker", "exec", "-i", ssh_container, "sh", "-c",
                    "cat >> /home/runlet/.ssh/authorized_keys2 && chown runlet:runlet /home/runlet/.ssh/authorized_keys2 && chmod 600 /home/runlet/.ssh/authorized_keys2"],
                   input=key.with_suffix(".pub").read_bytes(), check=True)
    host_key = subprocess.run(["docker", "exec", ssh_container, "cat", "/etc/ssh/ssh_host_ed25519_key.pub"], capture_output=True, text=True, check=True).stdout.split()[:2]
    (ssh_dir / "known_hosts").write_text(f"[127.0.0.1]:2222 {' '.join(host_key)}\n")
    config.write_text(f"""Host shop.example.com
    HostName 127.0.0.1
    Port 2222
    User runlet
    IdentityFile {key}
    IdentitiesOnly yes
    IdentityAgent none
    PasswordAuthentication no
    UserKnownHostsFile {ssh_dir / 'known_hosts'}
    GlobalKnownHostsFile /dev/null
""")
    server_log = "\n".join([
        "[2026-10-04 09:20:00] production.INFO: Deploy finished {\"release\":\"20261004-0918\"} []",
        "[2026-10-04 09:20:41] production.WARNING: Queue backlog {\"queue\":\"emails\",\"size\":180} []",
    ]) + "\n"
    subprocess.run(["docker", "exec", "-i", ssh_container, "sh", "-c",
                    f"mkdir -p {server_site}/storage/logs/2026 && cat > {server_site}/storage/logs/laravel.log && touch {server_site}/storage/logs/2026/laravel-2026-10-03.log && chown -R runlet:runlet {server_site}"],
                   input=server_log.encode(), check=True)
else:
    config.write_text("")


def ssh_append(text):
    subprocess.run(["docker", "exec", "-i", ssh_container, "sh", "-c", f"cat >> {server_site}/storage/logs/laravel.log"], input=text.encode(), check=True)


container_log = "/tmp/runlet-p20-app.log"
if which in ("docker", "all"):
    assert laravel_container, "the runlet-fixtures laravel service isn't running"
    subprocess.run(["docker", "exec", "-i", laravel_container, "sh", "-c", f"cat > {container_log}"],
                   input=b"[2026-10-04 09:25:00] local.INFO: Worker started {\"pid\":41} []\n", check=True)


def docker_append(text):
    subprocess.run(["docker", "exec", "-i", laravel_container, "sh", "-c", f"cat >> {container_log}"], input=text.encode(), check=True)


def docker_output(text):
    # What the container's main process prints (docker logs shows it).
    subprocess.run(["docker", "exec", laravel_container, "sh", "-c", f"printf '%s\\n' \"$1\" > /proc/1/fd/1", "sh", text], check=True)


def remote_tails(container, marker):
    script = 'm="$1$2"; for f in /proc/[0-9]*/cmdline; do c=$(tr \'\\0\' \' \' < "$f" 2>/dev/null) || continue; case "$c" in *"$m"*) echo "${f%/cmdline} $c";; esac; done; true'
    result = subprocess.run(["docker", "exec", container, "sh", "-c", script, "sh", marker[:8], marker[8:]], capture_output=True, text=True, check=True)
    return [line for line in result.stdout.splitlines() if line.strip()]


# MARK: Scratch data

data = scratch / "data"
state = data / "State"
state.mkdir(parents=True)


def write(name, value):
    (state / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": now, "data": value}, indent=2))


local_id, docker_id, ssh_id = (str(uuid.uuid4()).upper() for _ in range(3))
write("settings", {"appearance": "light", "fontSize": 14, "dockerExecutable": str(fixtures_docker),
                   "externalEditor": "custom", "externalEditorCommand": "/usr/bin/true {file}:{line}"})
write("targets", {
    "localProjects": [{"id": local_id, "name": "shop", "path": str(project), "revision": 1, "lastOpenedAt": now - 60}],
    "dockerProfiles": [{
        "id": docker_id, "name": "shop-docker",
        "identity": {"composeProject": "runlet-fixtures", "composeService": "laravel"},
        "workingDirectory": "/var/www/html", "phpExecutable": "php", "temporaryDirectory": "/tmp",
        "autoResolve": False, "revision": 1, "lastOpenedAt": now - 120,
    }],
    "sshProfiles": [{
        "id": ssh_id, "name": "shop-server", "host": "shop.example.com", "remoteDirectory": server_site,
        "phpExecutable": "php", "authentication": "automatic", "keepAliveMinutes": 1, "compression": False,
        "environment": "staging", "checkDrift": False, "revision": 1, "lastOpenedAt": now - 180,
    }],
})
CODE = """<?php

// Ships an order and logs it.
$line = sprintf("[%s] local.INFO: Order 1042 shipped {\\"order\\":1042,\\"carrier\\":\\"post\\"} []\\n", date('Y-m-d H:i:s'));
file_put_contents(__DIR__ . '/storage/logs/laravel.log', $line, FILE_APPEND);
file_put_contents(__DIR__ . '/storage/logs/laravel.log', sprintf("[%s] local.NOTICE: Stock low {\\"sku\\":\\"MUG-01\\",\\"left\\":3} []\\n", date('Y-m-d H:i:s')), FILE_APPEND);
echo 'shipped';
"""
tabs = [{"id": str(uuid.uuid4()).upper(), "title": "Ship order", "code": CODE, "target": {"local": {"_0": local_id}},
         "selection": {"location": 0, "length": 0}, "createdAt": now - 30}]
write("session", {"windows": [{"id": str(uuid.uuid4()).upper(), "tabs": tabs, "selectedTabId": tabs[0]["id"], "workspaceEdited": False}]})


def launch(name, steps, during=None):
    log_path = out / f"{name}.log"
    log_path.write_text("")
    env = ["--env", f"RUNLET_DATA_DIR={data}", "--env", f"RUNLET_SNAPSHOT_DIR={out}", "--env", "RUNLET_CREDENTIALS=memory",
           "--env", f"RUNLET_SSH_CONFIG={config}", "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
           "--env", f"RUNLET_REAL_DOCKER={shutil.which('docker') or ''}"]
    process = subprocess.Popen(["open", "-g", "-j", "-n", "-W"] + env + ["--stderr", str(log_path), str(app)])
    if during:
        threading.Thread(target=during, args=(log_path,), daemon=True).start()
    process.wait(timeout=600)
    text = log_path.read_text()
    assert "RUNLET_DEBUG_STEPS: done" in text, text[-3000:]
    return [line for line in text.splitlines() if line.startswith("RUNLET_DEBUG_STATE")]


def wait_for(log_path, marker, timeout=120):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if marker in log_path.read_text():
            return True
        time.sleep(0.2)
    return False


start = ["ghost", "scale:2", "appearance:light", "wait"]
states = []

if which in ("local", "all"):
    def local_during(log_path):
        # Appended while the window follows the file.
        if wait_for(log_path, "RUNLET_DEBUG_STEPS: logs-wait:following"):
            time.sleep(1.0)
            append(logs / "laravel.log", f"[{stamp(19, 4)}] local.WARNING: Stock low {{\"sku\":\"TEE-M\",\"left\":2}} []\n")
            append(logs / "laravel.log", f"[{stamp(19, 5)}] local.ERROR: Webhook rejected {{\"provider\":\"acme-pay\",\"status\":401}} []\n")

    states += launch("local", start + [
        "logs:shop", "frame:Logs=1180x700", "logs-wait:10", "logs-frames:log", "wait", "logs-state", "shot:logs-picker-and-entries@Logs",
        "logs-expand:Division by zero", "wait", "logs-state", "shot:logs-trace-expanded@Logs",
        "logs-frame:1", "logs-frame:2", "logs-frame:3", "logs-frame:4",
        # Vendor code opens in the read-only peek (#8's), next to the entry.
        "logs-frames:open", "logs-frame:3", "wait", "wait", "logs-state", "shot:logs-frame-peek@Logs", "logs-peek:off", "logs-frames:log",
        "logs-collapse", "logs-level:warning", "logs-search:query", "wait", "logs-state", "shot:logs-level-and-search@Logs",
        "logs-search:", "logs-level:all",
        "logs-source:worker/queue.log", "logs-wait:3", "logs-expand:Job failed", "wait", "logs-state", "shot:logs-json-formatter@Logs",
        "logs-source:laravel.log", "logs-wait:10", "logs-wait:following", "wait", "wait", "wait", "logs-wait:12", "logs-state", "shot:logs-follow@Logs",
        "logs-pause", "wait", "logs-state", "logs-pause",
        # Logs written by the last run: the tab's snippet appends two lines.
        "run", "wait-run:60", "wait", "logs-last-run:on", "wait", "logs-wait:2", "logs-state", "shot:logs-last-run@Logs",
        "logs-last-run:off", "appearance:dark", "logs-expand:Division by zero", "wait", "shot:logs-dark@Logs", "appearance:light",
        "logs-clear", "wait", "logs-state", "logs:off", "wait", "logs-state",
    ], local_during)

if which in ("docker", "all"):
    marker = container_log

    def docker_during(log_path):
        if wait_for(log_path, "RUNLET_DEBUG_STATE: logs-wait following: reached"):
            time.sleep(1.0)
            docker_append("[2026-10-04 09:25:30] local.ERROR: Mailer offline {\"host\":\"smtp\",\"attempt\":1} []\n")
        if wait_for(log_path, "RUNLET_DEBUG_STEPS: logs-source:Container output"):
            pass
        if wait_for(log_path, "RUNLET_DEBUG_STATE: logs-wait following: reached", timeout=5):
            pass
        # The container's own output for docker logs.
        if wait_for(log_path, "RUNLET_DEBUG_STEPS: logs-wait:following:31"):
            time.sleep(1.5)
            docker_output("[2026-10-04 09:26:00] local.INFO: GET /orders 200 12ms [] []")
            docker_output("[2026-10-04 09:26:01] local.WARNING: GET /orders/9 404 3ms [] []")

    states += launch("docker", start + [
        "logs:shop-docker", "frame:Logs=1180x700", "wait", "logs-state", "shot:logs-docker-sources@Logs",
        f"logs-other:{marker}", "logs-follow", "logs-wait:following", "logs-wait:2", "logs-state", "connections-state", "shot:logs-docker-exec-follow@Logs",
        "logs-stop", "logs-wait:idle", "wait", "logs-state",
        # Clear empties the list (older container output); then the container prints two lines.
        "logs-source:Container output", "logs-follow", "logs-wait:following", "wait", "logs-clear", "logs-wait:following:31", "logs-wait:2", "wait", "logs-state", "connections-state",
        "connections", "wait", "frame:Connections=760x420", "wait", "shot:logs-connection-manager@Connections", "connections:off",
        "shot:logs-docker-logs-follow@Logs",
        "logs:off", "wait", "wait", "logs-state", "connections-state",
    ], docker_during)
    time.sleep(1)
    left = remote_tails(laravel_container, marker)
    assert not left, f"tail left in the container: {left}"

if which in ("ssh", "all"):
    def ssh_during(log_path):
        if wait_for(log_path, "RUNLET_DEBUG_STATE: logs-wait following: reached"):
            time.sleep(1.0)
            ssh_append("[2026-10-04 09:30:12] production.ERROR: Disk almost full {\"mount\":\"/var\",\"free\":\"3%\"} []\n")

    states += launch("ssh", start + [
        "connect:shop-server", "connections-wait:ssh=1:25",
        "logs:shop-server", "frame:Logs=1180x700", "wait", "logs-find", "logs-wait:found", "wait", "logs-state",
        "logs-source:storage/logs/laravel.log", "logs-follow", "logs-wait:following", "logs-wait:3", "wait", "logs-state", "connections-state",
        "shot:logs-ssh-follow@Logs", "appearance:dark", "wait", "shot:logs-ssh-follow-dark@Logs", "appearance:light",
        "logs-stop", "logs-wait:idle", "wait", "logs-state", "connections-state",
        "disconnect:shop-server", "wait",
    ], ssh_during)
    time.sleep(1)
    left = remote_tails(ssh_container, server_site)
    assert not left, f"tail left on the server: {left}"
    subprocess.run(["docker", "exec", ssh_container, "sh", "-c", f"rm -rf {server_site}; sed -i '/runlet-p20/d' /home/runlet/.ssh/authorized_keys2"], check=False)

if which in ("docker", "all"):
    subprocess.run(["docker", "exec", laravel_container, "rm", "-f", container_log], check=False)

print("\n".join(states))
shots = sorted(out.glob("logs-*.png"))
print("shots:", [p.name for p in shots])

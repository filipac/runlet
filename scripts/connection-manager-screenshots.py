#!/usr/bin/env python3
"""#180: the Connection Manager end to end in a Debug app, with scratch data and neutral names only.

Usage: connection-manager-screenshots.py /path/to/Runlet.app /path/to/output <mariadb port> <postgres port> [/path/to/scratch]

Needs the disposable runlet-fixtures services: `ssh` (127.0.0.1:2222) and the MariaDB and
PostgreSQL databases (`scripts/setup-fixtures.sh databases`). It never reads ~/.ssh, never uses
your ssh-agent (SSH_AUTH_SOCK is empty), and keeps passwords in memory (a scratch RUNLET_DATA_DIR).

Seeds a scratch data folder: a local project "acme" (a copy of the `custom-driver` fixture), an SSH
profile "bastion" (password-or-2FA style login, production) and "acme-app" (agent or key login), both
reaching the fixture through a throwaway key and config (RUNLET_SSH_CONFIG), and four tabs. A
throwaway key goes into the fixture's /home/runlet/.ssh/authorized_keys2 (appended, removed again).
Then drives the app with RUNLET_DEBUG_STEPS: Connect… for bastion, a MariaDB SLEEP and a PostgreSQL
pg_sleep on saved connections (the second production, through bastion's SSH tunnel to the fixture
network's PostgreSQL, #143), PHP sleeps on bastion and acme-app (four runs: Runlet runs four at once), and an AI client
(`runlet mcp`) connected; shoots the status bar, the Connection Manager, Close's questions for
bastion and the tunnel, and dark mode; closes the MariaDB session from the window (and checks the
server no longer runs it), the tunnelled statement, the tunnel (and checks its listener is gone),
then everything else, and checks nothing is left open.
"""
from pathlib import Path
import json
import os
import re
import socket
import shutil
import signal
import subprocess
import sys
import time
import uuid

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
my_port, pg_port = sys.argv[3], sys.argv[4]
scratch = Path(sys.argv[5] if len(sys.argv) > 5 else "/private/tmp/runlet-p180")
root = Path(__file__).resolve().parent.parent
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
scratch.mkdir(parents=True)
project = scratch / "acme"
shutil.copytree(root / "Tests/Fixtures/custom-driver", project, symlinks=True)
data = scratch / "data"
state = data / "State"
state.mkdir(parents=True)

# SSH fixture: a throwaway key, appended to authorized_keys2 (the SSH tests rewrite authorized_keys).
container = subprocess.run(["docker", "compose", "-p", "runlet-fixtures", "ps", "-q", "ssh"], capture_output=True, text=True).stdout.strip()
assert container, "the runlet-fixtures ssh service isn't running"
ssh_dir = scratch / "ssh"
ssh_dir.mkdir()
key = ssh_dir / "id_ed25519"
subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "runlet-p180", "-f", str(key)], check=True)
subprocess.run(["docker", "exec", "-i", container, "sh", "-c",
                "cat >> /home/runlet/.ssh/authorized_keys2 && chown runlet:runlet /home/runlet/.ssh/authorized_keys2 && chmod 600 /home/runlet/.ssh/authorized_keys2"],
               input=key.with_suffix(".pub").read_bytes(), check=True)
host_key = subprocess.run(["docker", "exec", container, "cat", "/etc/ssh/ssh_host_ed25519_key.pub"], capture_output=True, text=True, check=True).stdout.split()[:2]
(ssh_dir / "known_hosts").write_text(f"[127.0.0.1]:2222 {' '.join(host_key)}\n")
config = ssh_dir / "config"
config.write_text("".join(f"""Host {host}
    HostName 127.0.0.1
    Port 2222
    User runlet
    IdentityFile {key}
    IdentitiesOnly yes
    IdentityAgent none
    PasswordAuthentication no
    UserKnownHostsFile {ssh_dir / 'known_hosts'}
    GlobalKnownHostsFile /dev/null

""" for host in ["bastion.example.com", "acme.example.com"]))
subprocess.run(["ssh", "-F", str(config), "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", "acme.example.com", "true"], check=True, env={**os.environ, "SSH_AUTH_SOCK": ""})

now = time.time() - 978307200  # Foundation's reference date


def write(name, value):
    (state / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": now, "data": value}, indent=2))


def ref(kind, ident=None):
    return {kind: {}} if ident is None else {kind: {"_0": ident}}


local_id, bastion_id, app_id = (str(uuid.uuid4()).upper() for _ in range(3))
write("targets", {
    "localProjects": [{"id": local_id, "name": "acme", "path": str(project), "revision": 1, "lastOpenedAt": now - 60}],
    "dockerProfiles": [],
    "sshProfiles": [
        {"id": bastion_id, "name": "bastion", "host": "bastion.example.com", "remoteDirectory": "/home/runlet/site/current",
         "phpExecutable": "php", "authentication": "interactive", "compression": False,
         "environment": "production", "checkDrift": False, "revision": 1, "lastOpenedAt": now - 120},
        {"id": app_id, "name": "acme-app", "host": "acme.example.com", "remoteDirectory": "/home/runlet/site/current",
         "phpExecutable": "php", "authentication": "automatic", "keepAliveMinutes": 1, "compression": False,
         "environment": "development", "checkDrift": False, "revision": 1, "lastOpenedAt": now - 180},
    ],
})
TABS = [
    ("Monthly report", ref("local", local_id), "sql", "-- Monthly revenue (slow on purpose)\nSELECT SLEEP(120) AS p180_monthly_report;\n"),
    ("Order totals", ref("local", local_id), "sql", "-- Rebuild the order totals (slow on purpose)\nSELECT pg_sleep(120) AS p180_order_totals;\n"),
    ("Server check", ref("ssh", bastion_id), "php", "<?php\n\n// Waits on the server.\nsleep(120);\n"),
    ("Queue check", ref("ssh", app_id), "php", "<?php\n\n// Waits on the server.\nsleep(120);\n"),
]
tabs = [{"id": str(uuid.uuid4()).upper(), "title": title, "code": code, "target": target, "language": language,
         "selection": {"location": 0, "length": 0}, "createdAt": now - 600 + index}
        for index, (title, target, language, code) in enumerate(TABS)]
write("session", {"windows": [{"id": str(uuid.uuid4()).upper(), "tabs": tabs, "selectedTabId": tabs[0]["id"], "workspaceEdited": False}]})

steps = [
    "ghost", "scale:2", "frame:1280x820", "appearance:light", "mcp:on", "wait",
    # A password-or-2FA style login: Connect… (the fixture key logs in without a prompt).
    "connect:bastion", "connections-wait:ssh=1:25",
    "select:Monthly report", f"db-new:Reporting|mysql|127.0.0.1|{my_port}|shop|root|runlet-fixture", "db-use:Reporting", "run",
    # Through bastion's SSH tunnel (#143) to the fixture network's PostgreSQL, marked production.
    "select:Order totals", "db-new:Analytics|pgsql|postgres|5432|shop|postgres|runlet-fixture|production+red+via-bastion", "db-use:Analytics", "run", "wait", "confirm",
    "select:Server check", "run", "wait", "confirm",
    "select:Queue check", "run",
    "connections-wait:phpRun=2:30", "connections-wait:database=2:40", "connections-wait:tunnel=1:30", "connections-wait:ssh=2:30", "connections-wait:aiClient=1:30",
    "select:Monthly report", "wait", "connections-state", "shot:connections-status-bar",
    "connections", "wait", "frame:Connections=900x1040", "wait", "shot:connections-manager-tunnels@Connections",
    # Close on bastion asks: it carries a tunnel, a statement, and a run, and its login needs the password or code again.
    "connection-close:bastion", "wait", "connections-state", "shot:connections-close-ssh@Connections", "connection-confirm:no",
    # Close on the tunnel asks while a statement uses it.
    "connection-close:Analytics", "wait", "connections-state", "shot:connections-close-tunnel@Connections", "connection-confirm:no",
    # Close on the MariaDB session: Stop, with the server-side cancel.
    "connection-close:SELECT SLEEP", "wait", "wait", "connections-state",
    "appearance:dark", "wait", "shot:connections-manager-dark@Connections", "appearance:light",
    # The statement through the tunnel stops (cancelled on the server through the tunnel), then
    # the unused tunnel closes without a question.
    "connection-close:SELECT pg_sleep", "connections-wait:database=0:30", "connections-state",
    "connection-close:Analytics", "connections-wait:tunnel=0:20", "connections-state",
    # Everything else.
    "connection-close:sleep(120)", "connection-close:sleep(120)", "connections-wait:phpRun=0:30",
    "connection-close:Claude Code", "connection-close:acme-app", "connection-close:bastion", "wait", "connection-confirm:yes",
    "connections-wait:all=0:30", "connections-state", "shot:connections-empty@Connections",
]
log_path = out / "capture.log"
log_path.write_text("")
cli = app / "Contents/Helpers/runlet"
init = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "claude-code", "title": "Claude Code", "version": "2.1"}}})
# The AI client connects once Runlet listens (`mcp:on` comes early in the steps).
mcp = subprocess.Popen(["sh", "-c", f"sleep 10; (printf '%s\\n' '{init}'; sleep 240) | '{cli}' mcp"],
                       env={**os.environ, "RUNLET_DATA_DIR": str(data), "RUNLET_MCP_NO_LAUNCH": "1", "SSH_AUTH_SOCK": ""},
                       stdout=subprocess.DEVNULL, stderr=open(out / "mcp.log", "w"), start_new_session=True)
try:
    subprocess.run(["open", "-g", "-j", "-n", "-W",
                    "--env", f"RUNLET_DATA_DIR={data}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                    "--env", "RUNLET_CREDENTIALS=memory", "--env", f"RUNLET_SSH_CONFIG={config}",
                    "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "SSH_AUTH_SOCK=",
                    "--stderr", str(log_path), str(app)], check=True)
finally:
    os.killpg(mcp.pid, signal.SIGTERM)
    # Whatever is still connected (a failed run of this script) goes.
    for control in (data / "SSH").glob("*.sock") if (data / "SSH").exists() else []:
        subprocess.run(["ssh", "-F", str(config), "-S", str(control), "-O", "exit", "bastion.example.com"], capture_output=True)
    subprocess.run(["docker", "exec", container, "sh", "-c", "sed -i '/runlet-p180/d' /home/runlet/.ssh/authorized_keys2"], check=False)

log = log_path.read_text()
states = [line for line in log.splitlines() if "RUNLET_DEBUG_STATE: connection" in line]
print("\n".join(states))
assert "RUNLET_DEBUG_STEPS: done" in log, log[-4000:]
assert "runlet-fixture" not in "\n".join(states), "a password reached the list"
connections = [line for line in states if "RUNLET_DEBUG_STATE: connections: " in line]
full = connections[0]
assert "(ssh=2 tunnel=1 database=2 phpRun=2 aiClient=1)" in full, full
assert "Claude Code" in full and "Database session" in full, full
assert "used by 1 SSH tunnel, 1 database session, and 1 PHP run" in full, full
port = re.search(r"tunnel \| Analytics \| 127\.0\.0\.1:(\d+) → postgres:5432 through bastion", full)
assert port, full
port = int(port.group(1))
ssh_question = connections[1]
assert "question=Disconnect from “bastion”?" in ssh_question and "log in again" in ssh_question and "1 SSH tunnel, 1 database session, and 1 PHP run use this connection" in ssh_question, ssh_question
tunnel_question = connections[2]
assert "question=Close the tunnel to 127.0.0.1:" in tunnel_question and "A statement is using this tunnel" in tunnel_question, tunnel_question
after_close = connections[3]
assert "database=1" in after_close and "p180_monthly" not in after_close, after_close
assert "database=0" in connections[4] and "tunnel=1" in connections[4] and "Unused; closes after" in connections[4], connections[4]
assert "tunnel=0" in connections[5], connections[5]
assert "connections: 0 " in connections[-1], connections[-1]
probe = socket.socket()
probe.settimeout(1)
assert probe.connect_ex(("127.0.0.1", port)) != 0, f"the tunnel's listener on {port} is still there"
probe.close()


def count(dsn, user, sql):
    return subprocess.run(["php", "-r", "echo (new PDO($argv[1], $argv[2], 'runlet-fixture'))->query($argv[3])->fetchColumn();", dsn, user, sql], capture_output=True, text=True, check=True).stdout


assert count(f"mysql:host=127.0.0.1;port={my_port};dbname=shop", "root", "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE INFO LIKE '%p180_monthly%' AND ID <> CONNECTION_ID()") == "0"
assert count(f"pgsql:host=127.0.0.1;port={pg_port};dbname=shop", "postgres", "SELECT COUNT(*) FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%p180_order%' AND pid <> pg_backend_pid()") == "0"
assert not list((data / "SSH").glob("*.sock")) if (data / "SSH").exists() else True, "an SSH connection is still open"
shots = sorted(out.glob("connections-*.png"))
assert len(shots) == 6, shots
shutil.rmtree(scratch)
print("ok:", [p.name for p in shots])

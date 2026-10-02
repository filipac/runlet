#!/usr/bin/env python3
"""End-to-end check of `runlet mcp` (#43) against a Debug build of Runlet.

Starts the app hidden (`ghost`) with scratch data and RUNLET_DEBUG_STEPS from steps.txt,
then drives two `runlet mcp` processes with JSON-RPC lines, the way an AI client would. The
app's steps answer the approval sheets (mcp-approve / mcp-decline) and take screenshots.
Nothing here touches the real Runlet data folder, ~/.ssh, a real server, or Docker: SSH
profiles are made-up hosts that are never approved, and the app uses the fake ssh fixture.

Usage: driver.py <Runlet.app> <work folder>
Writes transcripts, the app's stderr, and screenshots to <work folder>/out.
"""

import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import uuid

APP = os.path.abspath(sys.argv[1])
WORK = os.path.abspath(sys.argv[2])
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DATA = os.path.join(WORK, "data")
OUT = os.path.join(WORK, "out")
PROJECT = os.path.join(WORK, "project")
TOOL = os.path.join(APP, "Contents/Helpers/runlet")

results = []


def check(name, condition, detail=""):
    results.append((name, bool(condition), detail))
    print(("PASS " if condition else "FAIL ") + name + ("" if condition else f"  [{detail}]"), flush=True)


def seed():
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(os.path.join(DATA, "State"))
    os.makedirs(OUT)
    os.makedirs(PROJECT)
    with open(os.path.join(PROJECT, "index.php"), "w") as f:
        f.write("<?php\necho 'demo';\n")
    ssh = lambda name, host, user, directory, auth, env: {
        "id": str(uuid.uuid4()).upper(), "name": name, "host": host, "user": user,
        "remoteDirectory": directory, "phpExecutable": "php", "authentication": auth,
        "keepAliveMinutes": 10, "compression": True, "keepCompiledPHP": True,
        "environment": env, "checkDrift": False, "revision": 1,
    }
    library = {
        "localProjects": [{"id": str(uuid.uuid4()).upper(), "name": "demo", "path": PROJECT, "revision": 1}],
        "dockerProfiles": [],
        "sshProfiles": [
            ssh("staging", "staging.example.com", "deploy", "/srv/app/current", "automatic", "staging"),
            ssh("shop-production", "shop.example.com", "forge", "/home/forge/shop/current", "automatic", "production"),
            ssh("legacy-login", "legacy.example.com", "admin", "/var/www", "interactive", "development"),
        ],
    }
    # Runlet's document envelope (JSONStore.swift): dates are seconds since 2001-01-01.
    with open(os.path.join(DATA, "State", "targets.json"), "w") as f:
        json.dump({"schemaVersion": 1, "savedAt": time.time() - 978307200, "data": library}, f)
    with open(os.path.join(WORK, "ssh_config"), "w") as f:
        f.write("# empty: the end-to-end check never connects anywhere\n")


class Helper:
    """One `runlet mcp` process, as an AI client starts it."""

    def __init__(self, name, env):
        self.name = name
        self.log = open(os.path.join(OUT, f"transcript-{name}.jsonl"), "w")
        self.process = subprocess.Popen([TOOL, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=open(os.path.join(OUT, f"helper-{name}.stderr"), "w"), env=env, text=True, bufsize=1)
        self.messages = queue.Queue()
        self.notifications = []
        self.non_json = []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            self.log.write("<- " + line)
            self.log.flush()
            try:
                message = json.loads(line)
            except ValueError:
                self.non_json.append(line)
                continue
            if "method" in message:
                self.notifications.append(message)
            self.messages.put(message)

    def send(self, message):
        line = json.dumps(message)
        self.log.write("-> " + line + "\n")
        self.log.flush()
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()

    def request(self, id, method, params=None, timeout=60):
        message = {"jsonrpc": "2.0", "id": id, "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)
        return self.wait(id, timeout)

    def wait(self, id, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                message = self.messages.get(timeout=0.2)
            except queue.Empty:
                continue
            if message.get("id") == id and "method" not in message:
                return message
        return None

    def call(self, id, tool, arguments, meta=None, timeout=60):
        params = {"name": tool, "arguments": arguments}
        if meta:
            params["_meta"] = meta
        started = time.time()
        reply = self.request(id, "tools/call", params, timeout)
        return reply, time.time() - started

    def close(self):
        self.process.stdin.close()
        try:
            return self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            return None


def text(reply):
    try:
        return "\n".join(block["text"] for block in reply["result"]["content"])
    except (TypeError, KeyError):
        return json.dumps(reply)


def is_error(reply):
    return bool(reply and reply.get("result", {}).get("isError"))


def expiry(env):
    """Second launch: a request nobody answers expires (the timeout shortened to 4 s)."""
    stderr_path = os.path.join(OUT, "app-stderr-expiry.log")
    app = subprocess.Popen([
        "open", "-g", "-j", "-n", "-W",
        "--env", f"RUNLET_DATA_DIR={DATA}",
        "--env", "RUNLET_DEBUG_STEPS=ghost,mcp:on,mcp-wait:90,wait,wait,wait,wait,mcp-state,wait",
        "--env", "RUNLET_DEBUG_MCP_APPROVAL_TIMEOUT=4",
        "--env", f"RUNLET_SSH_EXECUTABLE={os.path.join(ROOT, 'Tests/Fixtures/fake-ssh/ssh')}",
        "--env", f"RUNLET_SSH_CONFIG={os.path.join(WORK, 'ssh_config')}",
        "--env", "SSH_AUTH_SOCK=",
        "--stderr", stderr_path,
        APP,
    ])
    deadline = time.time() + 60
    while time.time() < deadline:
        try:
            if "mcp listening=true" in open(stderr_path).read():
                break
        except OSError:
            pass
        time.sleep(0.25)
    p3 = Helper("expiry", env)
    p3.request(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}})
    reply, took = p3.call(2, "run_php", {"target": "sandbox", "code": "echo 'nobody answers';"}, timeout=60)
    check("an unanswered request expires with a tool error, and nothing ran", is_error(reply) and "expired" in text(reply) and "nobody answers" not in text(reply) and took < 20, (text(reply), took))
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        app.kill()
    log = open(stderr_path).read()
    states = [line for line in log.splitlines() if "mcp presented=" in line]
    check("the expired sheet was withdrawn", states and "presented=none" in states[0], states)
    p3.close()


def main():
    seed()
    steps = ",".join(line.strip() for line in open(os.path.join(HERE, "steps.txt")) if line.strip() and not line.strip().startswith("#"))
    env = dict(os.environ)
    env["RUNLET_DATA_DIR"] = DATA
    # Never start a visible Runlet if the hidden one went away.
    env["RUNLET_MCP_NO_LAUNCH"] = "1"
    stderr_path = os.path.join(OUT, "app-stderr.log")
    app = subprocess.Popen([
        "open", "-g", "-j", "-n", "-W",
        "--env", f"RUNLET_DATA_DIR={DATA}",
        "--env", f"RUNLET_SNAPSHOT_DIR={OUT}",
        "--env", f"RUNLET_DEBUG_STEPS={steps}",
        "--env", f"RUNLET_SSH_CONFIG={os.path.join(WORK, 'ssh_config')}",
        "--env", f"RUNLET_SSH_EXECUTABLE={os.path.join(ROOT, 'Tests/Fixtures/fake-ssh/ssh')}",
        "--env", "RUNLET_DEBUG_APP_PATH=/Applications/Runlet.app",
        "--env", "SSH_AUTH_SOCK=",
        "--env", f"PATH={os.environ.get('PATH', '')}",
        "--stderr", stderr_path,
        APP,
    ])

    def app_log():
        try:
            return open(stderr_path).read()
        except OSError:
            return ""

    deadline = time.time() + 60
    while "mcp listening=true" not in app_log() and time.time() < deadline:
        time.sleep(0.25)
    check("app listens on its MCP socket after mcp:on", "mcp listening=true" in app_log(), app_log()[-500:])

    # Client 1: a legacy client (initialize), like most clients today.
    p1 = Helper("claude-code", env)
    init = p1.request(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "claude-code", "title": "Claude Code", "version": "2.1.0"}})
    check("initialize agrees on 2025-11-25", init and init["result"]["protocolVersion"] == "2025-11-25", init)
    p1.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    tools = p1.request(2, "tools/list")
    names = [tool["name"] for tool in tools["result"]["tools"]] if tools else []
    check("tools/list offers the six tools", names == ["list_targets", "list_snippets", "get_snippet", "add_snippet", "run_php", "get_last_output"], names)

    targets, _ = p1.call(3, "list_targets", {})
    listed = [entry["target"] for entry in targets["result"]["structuredContent"]["targets"]] if targets else []
    check("list_targets lists the sandbox, the project, and the SSH hosts", listed == ["sandbox", "local:demo", "ssh:legacy-login", "ssh:shop-production", "ssh:staging"], listed)
    production = next((t for t in targets["result"]["structuredContent"]["targets"] if t["target"] == "ssh:shop-production"), {}) if targets else {}
    check("list_targets marks production and the connection state", production.get("environment") == "production" and "not connected" in production.get("connection", ""), production)

    added, _ = p1.call(4, "add_snippet", {"label": "Count words", "code": "str('one two three')->wordCount();", "target": "sandbox"})
    snippet_id = added["result"]["structuredContent"]["id"] if added and not is_error(added) else None
    check("add_snippet saves (and says nothing ran)", snippet_id and "Nothing ran" in text(added), text(added))
    got, _ = p1.call(5, "get_snippet", {"id": snippet_id or "?"})
    check("get_snippet returns the saved code", got and got["result"]["structuredContent"]["code"] == "str('one two three')->wordCount();", text(got))
    listed_snippets, _ = p1.call(6, "list_snippets", {"query": "words"})
    check("list_snippets finds it", listed_snippets and any(s["id"] == snippet_id for s in listed_snippets["result"]["structuredContent"]["snippets"]), text(listed_snippets))

    # 1. Sandbox run: sheet, screenshot, approved.
    code_a = "$words = collect(['runlet', 'mcp', 'sandbox'])\n    ->map(fn ($word) => str($word)->upper());\n\ndump($words->count());\n\nreturn $words->implode(' ');"
    reply, took = p1.call(10, "run_php", {"target": "sandbox", "code": code_a}, timeout=180)
    check("run 1 (sandbox, approved) completes with its result and dump", reply and not is_error(reply) and "RUNLET MCP SANDBOX" in text(reply) and "dump (line 4)" in text(reply), text(reply))
    check("run 1 reports where it ran", reply and "Runlet tab “Claude Code”" in text(reply) and reply["result"]["structuredContent"]["status"] == "completed", text(reply))
    time.sleep(7)  # the app screenshots the run's tab

    # 2. Declined.
    reply, _ = p1.call(11, "run_php", {"target": "sandbox", "code": "echo 'should not run';"}, timeout=120)
    check("run 2 (declined) is a tool error and nothing ran", is_error(reply) and "declined" in text(reply) and "should not run" not in text(reply), text(reply))

    # 3. Approved with "Allow for this session".
    reply, _ = p1.call(12, "run_php", {"target": "sandbox", "code": "return 6 * 7;"}, timeout=120)
    check("run 3 (allowed for the session) completes", reply and not is_error(reply) and "42" in text(reply), text(reply))

    # 4. Same connection, sandbox: no sheet. It throws on line 2, so the error and line come back.
    reply, took = p1.call(13, "run_php", {"target": "sandbox", "code": "$value = 21 * 2;\nthrow new RuntimeException(\"Answer is $value\");"}, timeout=60)
    check("run 4 runs without a sheet (session allowance)", reply is not None and took < 30, f"{took:.1f}s")
    check("run 4's exception comes back as a tool error with its line", is_error(reply) and "RuntimeException: Answer is 42 (line 2)" in text(reply), text(reply))

    # 5. A second client (new connection, 2026-07-28 per-request metadata) still has to ask.
    p2 = Helper("cursor", env)
    meta = {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}, "io.modelcontextprotocol/clientInfo": {"name": "cursor", "title": "Cursor", "version": "1.7"}}
    discover = p2.request(1, "server/discover", {"_meta": meta})
    check("server/discover lists 2026-07-28 and the legacy revisions", discover and discover["result"]["supportedVersions"][0] == "2026-07-28" and discover["result"]["resultType"] == "complete", discover)
    old = p2.request(2, "tools/list", {"_meta": dict(meta, **{"io.modelcontextprotocol/protocolVersion": "1999-01-01"})})
    check("an unsupported version gets UnsupportedProtocolVersionError", old and old.get("error", {}).get("code") == -32022, old)
    reply, _ = p2.call(3, "run_php", {"target": "sandbox", "code": "echo 'second client';"}, meta=meta, timeout=120)
    check("run 5 (second client, sandbox) asked and was declined", is_error(reply) and "declined" in text(reply) and reply["result"].get("resultType") == "complete", text(reply))

    # 6. An SSH host that needs a login is refused at once; Runlet never logs in for a client.
    reply, took = p1.call(14, "run_php", {"target": "ssh:legacy-login", "code": "echo 1;"}, timeout=30)
    check("run 6 (SSH host that needs a login) is refused without a sheet", is_error(reply) and "Connect…" in text(reply) and took < 10, text(reply))

    # 7. SSH host that isn't connected: sheet (screenshot), then the client cancels.
    p1.send({"jsonrpc": "2.0", "id": 15, "method": "tools/call", "params": {"name": "run_php", "arguments": {"target": "ssh:staging", "code": "echo gethostname();"}, "_meta": {"progressToken": "staging-run"}}})
    deadline = time.time() + 60
    while not any(n.get("params", {}).get("progressToken") == "staging-run" for n in p1.notifications) and time.time() < deadline:
        time.sleep(0.1)
    progress = [n for n in p1.notifications if n.get("params", {}).get("progressToken") == "staging-run"]
    check("run 7 reports that it waits for approval (progress)", progress and "approve" in progress[0]["params"]["message"], progress)
    time.sleep(4)
    p1.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 15, "reason": "user stopped"}})
    late = p1.wait(15, timeout=6)
    check("run 7 (cancelled) gets no response", late is None, late)

    # 8. Production SSH host: sheet with the production warning (screenshot), declined.
    reply, _ = p1.call(16, "run_php", {"target": "ssh:shop-production", "code": "return App\\Models\\Order::count();"}, timeout=120)
    check("run 8 (production) asked and was declined", is_error(reply) and "declined" in text(reply), text(reply))

    # 9. Local project: asks, approved, runs.
    reply, _ = p1.call(17, "run_php", {"target": "local:demo", "code": "return PHP_VERSION_ID >= 80000;"}, timeout=120)
    check("run 9 (local project, approved) completes", reply and not is_error(reply) and "true" in text(reply), text(reply))
    last, _ = p1.call(18, "get_last_output", {})
    check("get_last_output returns the last run", last and not is_error(last) and "true" in text(last) and "demo" in last["result"]["structuredContent"]["target"], text(last))

    # The app finishes its steps (Settings screenshot) and quits.
    try:
        app.wait(timeout=120)
    except subprocess.TimeoutExpired:
        app.kill()
    log = app_log()
    check("the app finished its steps", "RUNLET_DEBUG_STEPS: done" in log, log[-500:])
    approvals = [line.split("mcp approval ", 1)[1] for line in log.splitlines() if "RUNLET_DEBUG_STATE: mcp approval " in line]
    expected = ["Claude Code → Laravel Sandbox", "Claude Code → Laravel Sandbox", "Claude Code → Laravel Sandbox", "Cursor → Laravel Sandbox", "Claude Code → staging (SSH)", "Claude Code → shop-production (SSH)", "Claude Code → demo"]
    check("sheets appeared exactly for runs 1, 2, 3, 5, 7, 8, 9", len(approvals) == len(expected) and all(a.startswith(e) for a, e in zip(approvals, expected)), approvals)
    states = [line for line in log.splitlines() if "RUNLET_DEBUG_STATE: mcp presented=" in line]
    check("the cancelled request's sheet was withdrawn", states and "presented=none" in states[0] and "waiting=0" in states[0], states)
    check("clients and the session allowance are listed", len(states) > 1 and "Claude Code(sandbox allowed)" in states[-1] and "Cursor" in states[-1], states)

    for helper in (p1, p2):
        status = helper.close()
        check(f"{helper.name}: stdout carried only JSON-RPC, and it exits on end of input", not helper.non_json and status == 0, (helper.non_json, status))

    expiry(env)

    failed = [name for name, ok, _ in results if not ok]
    print(f"\n{len(results) - len(failed)} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

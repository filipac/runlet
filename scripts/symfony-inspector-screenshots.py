#!/usr/bin/env python3
"""#315: the run inspector's HTTP and Jobs sections for a Symfony project (HttpClient, Messenger).

Usage: symfony-inspector-screenshots.py /path/to/Runlet.app /path/to/output [http jobs]

Copies Tests/Fixtures/symfony-app (scripts/setup-fixtures.sh, with its `.runlet-inspector-ready`
Messenger and HttpClient setup) into build/shots-315/home/shop, so the fixture stays clean and the
tab card shows the project as ~/shop (RUNLET_DEBUG_HOME). The project's PHP is a wrapper that sets
APP_ENV=dev, where the fixture's profiler traces requests and dispatches. Each shot runs one snippet
in a hidden Debug app with scratch data, checks `recorder-state`, and shoots light and dark:

- http: Symfony HttpClient requests through `http_client` (one with `auth_bearer`, opened, its
  Authorization and the token in its body redacted) and the scoped client `local.client` (its
  X-Api-Key redacted), to a `php -S` server on 127.0.0.1 that the script starts and stops, plus
  one to a closed local port. Bodies are recorded.
- jobs: Messenger messages handled right away (PROCESSED), one whose handler throws (FAILED,
  opened), one sent to the `in-memory://` transport with a delay (QUEUED, opened), and one sent to
  `sync://` (PROCESSED, timed).

Nothing else is contacted, and nothing reads ~/Library/Application Support/Runlet, the Keychain,
or ~/.ssh. Look at every image before publishing it.
"""
import json
import re
import shutil
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "Tests" / "Fixtures" / "symfony-app"
WORK = ROOT / "build" / "shots-315"
NOW = time.time() - 978307200
PROJECT_ID = "5A0B7C1E-0D0C-4E55-9A6B-3D2C1B0A9315"

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
selected = set(sys.argv[3:]) or {"http", "jobs"}


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


API = free_port()
CLOSED = free_port()  # nothing listens there: the request fails to connect

ROUTER = """<?php
header('Content-Type: application/json');
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if (str_starts_with($path, '/v1/customers/')) {
    http_response_code(404);
    echo json_encode(['error' => 'Customer not found']);
} elseif ($path === '/v1/orders' && $_SERVER['REQUEST_METHOD'] === 'POST') {
    http_response_code(201);
    echo json_encode(['id' => 1042, 'status' => 'pending']);
} elseif (str_starts_with($path, '/v1/orders/')) {
    echo json_encode(['id' => 1042, 'status' => 'paid', 'total' => 4699, 'access_token' => 'example-access-token']);
} else {
    echo json_encode(['status' => 'ok', 'version' => '2.4.1']);
}
"""

HTTP = f"""use App\\Service\\Fetcher;
use Symfony\\Contracts\\HttpClient\\Exception\\TransportExceptionInterface;

$fetcher = $container->get(Fetcher::class);
$api = 'http://127.0.0.1:{API}';

$order = $fetcher->client->request('GET', "$api/v1/orders/1042", [
    'auth_bearer' => 'example-api-token',
    'headers' => ['X-Trace' => 'checkout'],
])->toArray();

// The scoped client "local.client" adds its X-Api-Key header.
$fetcher->localClient->request('POST', "$api/v1/orders", [
    'json' => ['sku' => 'TSHIRT-M', 'quantity' => 2],
])->toArray();

$fetcher->client->request('GET', "$api/v1/customers/77")
    ->getStatusCode();
$fetcher->client->request('GET', "$api/health")->toArray();

// Nothing listens on this port: the connection fails.
try {{
    $fetcher->client->request('GET', 'http://127.0.0.1:{CLOSED}/')
        ->getStatusCode();
}} catch (TransportExceptionInterface) {{
}}

$order['status'];
"""

JOBS = """use App\\Message\\{ChargeCard, ExportReport, RebuildIndex, SendInvoice};
use Symfony\\Component\\Messenger\\Exception\\HandlerFailedException;
use Symfony\\Component\\Messenger\\Stamp\\DelayStamp;

$bus = $container->get('messenger.default_bus');

$bus->dispatch(new SendInvoice(1042));

try {
    $bus->dispatch(new ChargeCard());
} catch (HandlerFailedException) {
}

// Routed to the in-memory:// transport "async", in a minute.
$bus->dispatch(new ExportReport(), [new DelayStamp(60_000)]);

// Routed to the sync:// transport "now".
$bus->dispatch(new RebuildIndex());
"""

SHOTS = {
    # name: tab title, code, settings, the window's size, steps after the run
    "http": ("Orders API", HTTP, {"recordHTTPBodies": True}, "1280x780",
             ["section:HTTP", "recorder-expand:HTTP:redacted", "wait"]),
    "jobs": ("Invoices", JOBS, {}, "1280x560",
             ["section:Jobs", "recorder-expand:Jobs:2", "recorder-expand:Jobs:3", "wait"]),
}


def project(home: Path) -> tuple[Path, Path]:
    """A fresh copy of the fixture as ~/shop, and a php that runs it in dev."""
    shop = home / "shop"
    shutil.rmtree(shop, ignore_errors=True)
    home.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cp", "-cR", str(FIXTURE), str(shop)], check=True)
    shutil.rmtree(shop / "var" / "cache", ignore_errors=True)  # the fixture's cache holds its own paths
    php = shutil.which("php")
    assert php, "php isn't on PATH"
    wrapper = WORK / "bin" / "php"
    wrapper.parent.mkdir(parents=True, exist_ok=True)
    wrapper.write_text(f"#!/bin/sh\nAPP_ENV=dev\nexport APP_ENV\nexec '{Path(php).resolve()}' \"$@\"\n")
    wrapper.chmod(0o755)
    return shop, wrapper


def local_api() -> subprocess.Popen:
    folder = WORK / "local-api"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "router.php").write_text(ROUTER)
    server = subprocess.Popen(["php", "-S", f"127.0.0.1:{API}", "router.php"], cwd=folder,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 10
    while time.time() < deadline:
        with socket.socket() as probe:
            if probe.connect_ex(("127.0.0.1", API)) == 0:
                return server
        time.sleep(0.05)
    server.kill()
    raise RuntimeError("the local API server didn't start")


def take(name: str) -> str:
    title, code, settings, frame, steps = SHOTS[name]
    home = WORK / "home"
    shop, php = project(home)
    data = WORK / f"data-{name}"
    shutil.rmtree(data, ignore_errors=True)
    (data / "State").mkdir(parents=True)

    def save(state, value):
        (data / "State" / f"{state}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": NOW, "data": value}))

    save("settings", {"appearance": "light", "fontSize": 13, "showTipsOnFirstLaunch": False, "showWhatsNewAfterUpdates": False,
                      "automaticUpdateChecks": False, "languageServiceEnabled": False, "notifyLongRuns": False, **settings})
    save("targets", {"localProjects": [{"id": PROJECT_ID, "name": "shop", "path": str(shop), "phpExecutable": str(php),
                                        "revision": 1, "lastOpenedAt": NOW - 60}], "dockerProfiles": [], "sshProfiles": []})
    tab = str(uuid.uuid4()).upper()
    save("session", {"windows": [{"id": str(uuid.uuid4()).upper(), "selectedTabId": tab, "workspaceEdited": False, "tabs": [
        {"id": tab, "title": title, "code": code, "target": {"local": {"_0": PROJECT_ID}},
         "selection": {"location": len(code), "length": 0}, "createdAt": NOW - 600}]}]})
    stamp = time.strftime("%H%M%S")
    shots = [f"symfony-{name}-light-{stamp}", f"symfony-{name}-dark-{stamp}"]
    all_steps = (["ghost", "scale:2", f"frame:{frame}", "appearance:light", "wait", "run", "wait-run:120", "wait"] + steps
                 + ["recorder-state", f"shot:{shots[0]}", "appearance:dark", "wait", f"shot:{shots[1]}"])
    log = WORK / f"{name}-315.log"
    log.write_text("")
    server = local_api() if name == "http" else None
    try:
        subprocess.run(["open", "-g", "-j", "-n", "-W", "--env", f"RUNLET_DATA_DIR={data}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                        "--env", f"RUNLET_DEBUG_STEPS={','.join(all_steps)}", "--env", "RUNLET_CREDENTIALS=memory",
                        "--env", "SSH_AUTH_SOCK=", "--env", f"RUNLET_DEBUG_HOME={home}", "--env", "TZ=UTC",
                        "--stderr", str(log), str(app), "--args", "-ApplePersistenceIgnoreState", "YES",
                        "-AppleLanguages", "(en)", "-AppleLocale", "en_US"], check=True, timeout=600)
    finally:
        if server:
            server.kill()
            server.wait()
    text = log.read_text()
    assert "RUNLET_DEBUG_STEPS: done" in text, text
    state = next((line for line in text.splitlines() if "recorder-state:" in line), "")
    print(f"{name}: {state.split('recorder-state:', 1)[-1].strip()}")
    for shot in shots:
        assert (out / f"{shot}.png").is_file(), f"{shot}.png is missing; see {log}"
        print(f"  {out / f'{shot}.png'}")
    return state


for name in ["http", "jobs"]:
    if name not in selected:
        continue
    state = take(name)
    if name == "http":
        assert re.search(r"http: \[.*redacted=[1-9]", state), "no request with a redacted header"
        assert "example-api-token" not in state and "example-access-token" not in state
    else:
        for status in ["processed", "failed", "queued"]:
            assert status in state.lower(), f"no {status} message"

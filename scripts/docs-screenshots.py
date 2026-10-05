#!/usr/bin/env python3
"""Takes the documentation's screenshots (#295): every image in docs/screenshots/, as a light and
a dark pair, from a Debug build of Runlet with scratch data only.

    scripts/docs-screenshots.py                  every shot this Mac can take
    scripts/docs-screenshots.py logs history     shots by id (`running-code/history`), name, or page
    scripts/docs-screenshots.py --list           the manifest: id, what it needs, and its page
    scripts/docs-screenshots.py --app <path>     use a built Runlet.app instead of building one
    scripts/docs-screenshots.py --keep           keep the raw PNGs and scratch data in build/docs-shots/
    scripts/docs-screenshots.py --jobs 1         one shot at a time (default: half the CPUs, at most 6)

Each shot in SHOTS names its page, its scratch data (tabs, settings, targets, history, snippets,
files), the RUNLET_DEBUG_STEPS that lead up to the picture, and what it needs: "sandbox" (the
bundled Laravel sandbox, nothing else) or fixtures from NEEDS (#304): redis, mongo, postgres,
ssh, docker, and profiler, the runlet-fixtures containers. The script builds the app with
the prshots bundle id, launches it hidden in the background (`open -g -j`, then the `ghost`
step) once per shot, takes the picture in light, switches the app's appearance, takes it in
dark, and converts both with cwebp into docs/screenshots/<page>/<name>-light.webp and
-dark.webp, at most 1600 pixels wide.

Scratch data lives in build/docs-shots/: a base data folder with the sandbox installed and
seeded with neutral users once, then a fresh clone of it for every shot. The script never reads
or writes ~/Library/Application Support/Runlet, the Keychain, or ~/.ssh, and connects to no
server but the fixtures. Sandbox shots get a fake ssh (Tests/Fixtures/fake-ssh/ssh) with an empty
config; their one SSH profile (a production target, for the confirmation sheet and the mail chip)
is never run. Fixture shots reach the containers through Tests/Fixtures/docker/fixtures-only-docker
and the fixture SSH host through a throwaway key and config; the script seeds Redis database 11
and the MongoDB database docs_shop with example data, and removes them, the key, and the SSH
connections when it ends (PREPARE).

Needs Xcode, PHP, cwebp (brew install webp), scripts/build-sandbox.sh to have run, and a Retina
screen: the `shot` step moves each hidden window there, at its shot's size, before drawing it, and
fails saying why when it can't (a tiling window manager; the script warns about AeroSpace). Look
at every image before committing it: no names, paths, hosts, or containers of your own.
Conventions and how to add a shot: docs/writing-docs.md#screenshots.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
import os
import json
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import sys
import threading
import time
from typing import Callable
import uuid

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "build" / "docs-shots"
DOCS = ROOT / "docs" / "screenshots"
SANDBOX_TEMPLATE = ROOT / "Resources" / "Sandbox" / "laravel"
FAKE_SSH = ROOT / "Tests" / "Fixtures" / "fake-ssh" / "ssh"
# The real Docker CLI, limited to the runlet-fixtures containers: the script and the app's
# Docker profiles go through it, so neither ever sees your own containers (docs/testing.md).
FIXTURE_DOCKER = ROOT / "Tests" / "Fixtures" / "docker" / "fixtures-only-docker"
FIXTURE_PASSWORD = "runlet-fixture"  # the fixtures' throwaway password (compose.yml)
REDIS_DB = 11  # the docs' own Redis database on the fixture; the tests use 0, 3, and 7
MONGO_DB = "docs_shop"  # the docs' own MongoDB database on the fixture
SSH_KEY_COMMENT = "runlet-docs-shots"
BUNDLE_ID = "dev.runlet.Runlet.prshots"
WIDTH = 1600  # pixels: sharp when zoomed, small on disk
QUALITY = 85
NOW = time.time() - 978307200  # Foundation's reference date, as the state files store dates
# Every instance shares the prshots bundle id's defaults (window frames, Settings' last tab) and
# saved state. Shots set what they depend on with steps (`frame`, `appearance`, `settings-tab`),
# and these arguments override the rest for one launch without writing them, so shots can run in
# parallel: no restored windows, Settings opens on General, and English names and number
# formats, whatever this Mac's language is.
LAUNCH_ARGUMENTS = ["-ApplePersistenceIgnoreState", "YES", "-com_apple_SwiftUI_Settings_selectedTabIndex", "0",
                    "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
SETTINGS_TAB = LAUNCH_ARGUMENTS.index("-com_apple_SwiftUI_Settings_selectedTabIndex") + 1

# MARK: Scratch data helpers


def uid() -> str:
    return str(uuid.uuid4()).upper()


SANDBOX = {"sandbox": {}}
SHOP_ID = "5A0B7C1E-0D0C-4E55-9A6B-3D2C1B0A9F01"
SHOP = {"ssh": {"_0": SHOP_ID}}


def tab(title: str, code: str, target=None, language: str | None = None, caret: int | None = None, **extra) -> dict:
    state = {"id": uid(), "title": title, "code": code, "target": target or SANDBOX,
             "selection": {"location": len(code) if caret is None else caret, "length": 0}, "createdAt": NOW - 600}
    if language:
        state["language"] = language
    state.update(extra)
    return state


# A production SSH target that is never connected to: Runlet asks before every run on it, and the
# steps cancel. Its host is an example.com name, and ssh is a fake with an empty config.
PRODUCTION_TARGETS = {
    "localProjects": [],
    "dockerProfiles": [],
    "sshProfiles": [{
        "id": SHOP_ID, "name": "shop", "host": "shop.example.com", "user": "deploy",
        "remoteDirectory": "/var/www/shop/current", "phpExecutable": "php", "authentication": "automatic",
        "keepAliveMinutes": 10, "compression": True, "environment": "production", "checkDrift": False,
        "interceptMail": True, "revision": 1, "lastOpenedAt": NOW - 3600,
    }],
}

# Settings every shot starts from: no tips, What's New, or update checks; PHPantom off unless a
# shot turns it on (its status would change between the light and the dark picture).
BASE_SETTINGS = {
    "appearance": "light", "fontSize": 13, "showTipsOnFirstLaunch": False, "showWhatsNewAfterUpdates": False,
    "automaticUpdateChecks": False, "languageServiceEnabled": False, "notifyLongRuns": False,
}


@dataclass
class Shot:
    page: str
    name: str
    steps: list[str]
    tabs: list[dict]
    #: "sandbox", or fixtures in NEEDS joined by "+" ("ssh+postgres"), #304.
    needs: str = "sandbox"
    settings: dict = field(default_factory=dict)
    targets: dict | None = None
    history: list[dict] | None = None
    snippets: list[dict] | None = None
    #: Called with the shot's data folder and its installed sandbox, before the launch.
    seed: Callable[[Path, Path], None] | None = None
    #: The main window's size in points.
    frame: str = "1200x760"
    #: The index of the selected tab.
    selected: int = 0
    #: `shot:<name>@<window>`: another window, such as Settings or Logs.
    window: str | None = None
    #: Steps between the light and the dark picture (after `appearance:dark`).
    dark_steps: list[str] = field(default_factory=list)
    #: (x, y, width, height) in points of the picture, to keep a part of it.
    crop: tuple[int, int, int, int] | None = None
    #: Shown by --list.
    about: str = ""
    #: More environment variables for the launch; `{data}` is the shot's data folder.
    env: dict = field(default_factory=dict)
    #: Started before the launch and stopped after it, such as a client the picture shows.
    background: Callable[[], subprocess.Popen] | None = None
    #: The tab Settings opens on (0 is General, 7 Databases): the launch arguments hold it, so
    #: the `settings-tab` step can't switch tabs.
    settings_tab: int = 0

    @property
    def id(self) -> str:
        return f"{self.page}/{self.name}"


# MARK: Code the shots run (neutral names and example.com addresses only)

USERS = [("Alice Example", "alice@example.com"), ("Bob Example", "bob@example.com"), ("Carol Example", "carol@example.com")]

QUICKSTART_INLINE = """use App\\Models\\User;

$user = User::latest()->first(); //?
$user->email; //?

foreach (User::all() as $user) {
    $user->name; //?
}
"""

MAGIC_COMMENTS = """use App\\Models\\User;

$user = User::first(); //?
$user->name; //?
User::all() /*?->count()*/;

foreach (User::all() as $user) {
    $user->email; //?
}
/*?.*/
"""

OUTPUT_PANE = """use App\\Models\\User;

dump('Users: ' . User::count());

User::query()
    ->latest('id')
    ->get(['id', 'name', 'email', 'created_at']);
"""

# #307: Values | Object on a collection of models: a changed attribute, a new model, and the
# hidden password and remember token.
MODEL_VALUES = """use App\\Models\\User;

$users = User::query()->oldest('id')->take(2)->get();

$users->first()->name = 'Alice Example-Smith';
$users->push(new User(['name' => 'Dave Example']));

$users
"""

QUERIES = """use App\\Models\\User;
use Illuminate\\Support\\Facades\\DB;

$users = User::latest('id')->take(3)->get();

// One sessions query per user: an N+1 pattern.
$users->map(fn (User $user) => [
    'name' => $user->name,
    'sessions' => DB::table('sessions')->where('user_id', $user->id)->count(),
]);

// The same check twice: a repeated statement.
User::where('email', 'alice@example.com')->exists();
User::where('email', 'alice@example.com')->exists();
"""

# #5: the HTTP, Jobs, and Events sections. HTTP goes to Http::fake() for api.example.com and to a
# PHP server on 127.0.0.1 that the shot starts and stops (local_api); nothing else is contacted.


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


LOCAL_API_PORT = free_port()
CLOSED_PORT = free_port()  # nothing listens there: the request fails to connect

HTTP_CALLS = f"""use Illuminate\\Support\\Facades\\Http;

Http::fake([
    'api.example.com/v1/orders*' => Http::response([
        'id' => 1042,
        'access_token' => 'example-access-token',
    ], 201),
    'api.example.com/v1/customers/*' => Http::response(status: 404),
]);

$order = Http::withToken('example-api-token')
    ->withHeaders(['X-Api-Key' => 'example-key'])
    ->post('https://api.example.com/v1/orders?signature=abc123', [
        'sku' => 'TSHIRT-M',
        'quantity' => 2,
    ]);

Http::get('https://api.example.com/v1/customers/77');
Http::get('http://127.0.0.1:{LOCAL_API_PORT}/health');

// Nothing listens on this port: the connection fails.
rescue(fn () => Http::get('http://127.0.0.1:{CLOSED_PORT}/'), report: false);
"""


def local_api() -> subprocess.Popen:
    """A PHP server on 127.0.0.1 for the HTTP shot's real request, stopped after the shot."""
    folder = WORK / "local-api"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "router.php").write_text("<?php\nheader('Content-Type: application/json');\n"
                                      "echo json_encode(['status' => 'ok', 'version' => '2.4.1']);\n")
    server = subprocess.Popen(["php", "-S", f"127.0.0.1:{LOCAL_API_PORT}", "router.php"], cwd=folder,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + 10
    while not reachable(LOCAL_API_PORT) and time.time() < deadline:
        time.sleep(0.05)
    return server


JOBS = """use App\\Models\\User;
use Illuminate\\Bus\\Queueable;
use Illuminate\\Contracts\\Queue\\ShouldQueue;
use Illuminate\\Foundation\\Bus\\Dispatchable;

class SendWelcomeEmail implements ShouldQueue
{
    use Dispatchable, Queueable;

    public function __construct(public int $userId) {}

    public function handle(): void
    {
        usleep(12000); // render and send
    }
}

class SyncToCrm implements ShouldQueue
{
    use Dispatchable, Queueable;

    public function handle(): void
    {
        throw new RuntimeException('CRM API rate limit reached');
    }
}

SendWelcomeEmail::dispatch(User::first()->id);

rescue(function () {
    SyncToCrm::dispatch();
}, report: false);

SendWelcomeEmail::dispatch(2)
    ->onConnection('database')
    ->onQueue('emails')
    ->delay(now()->addMinutes(5));
"""

EVENTS = """use App\\Models\\User;
use Illuminate\\Support\\Facades\\Cache;

class OrderShipped
{
    public function __construct(
        public int $orderId,
        public string $carrier,
    ) {}
}

$user = User::create([
    'name' => 'Dana Example',
    'email' => 'dana@example.com',
    'password' => 'not-a-real-password',
]);
Cache::remember('dashboard.stats', 60, fn () => ['orders' => 128]);

event(new OrderShipped(1042, 'Example Post'));
event('cart.updated', [['items' => 3, 'total' => 59.80]]);
"""

DRY_RUN = """use App\\Models\\User;

User::where('email', 'like', '%@example.com')
    ->update(['name' => 'Renamed']);

User::pluck('name');
"""

BENCH = """Runlet\\bench([
    'array_map' => fn () => array_map(fn ($x) => $x * 2, range(1, 1000)),
    'foreach' => function () {
        $doubled = [];
        foreach (range(1, 1000) as $x) {
            $doubled[] = $x * 2;
        }
        return $doubled;
    },
], 2000);
"""

PRODUCTION = """use App\\Models\\Order;

// Production asks before every run.
Order::where('status', 'paid')
    ->whereNull('shipped_at')
    ->update(['status' => 'review']);
"""

# MARK: The manifest

STRING_JSON = """return json_encode([
    'name' => 'Widget',
    'status' => 'ready',
    'items' => [
        ['id' => 1, 'stock' => 12],
        ['id' => 2, 'stock' => 8],
    ],
    'cached' => true,
]);
"""

STRING_SVG = """// An SVG returned as base64.
return base64_encode(<<<'SVG'
<svg xmlns="http://www.w3.org/2000/svg"
     width="460" height="240">
  <rect width="460" height="240" rx="18"
        fill="#167d8d"/>
  <circle cx="100" cy="120" r="58" fill="#e9ca72"/>
  <text x="180" y="130" fill="white"
        font-family="sans-serif" font-size="32">
    Runlet preview
  </text>
</svg>
SVG);
"""

TIMINGS = """usleep(125000);

DB::select('select 1 as number');

collect([2, 4, 6])->sum();
"""

AUTO_RUN = """use Illuminate\\Support\\Str;

collect(['Alice Example', 'Bob Example'])
    ->map(fn ($name) => Str::slug($name))
"""

EXPLAIN = """use App\\Models\\User;

User::where('name', 'like', '%Example')
    ->orderBy('name')
    ->get(['id', 'name', 'email']);
"""

# What Explain opens for EXPLAIN's query (QueryExplain.code in RunletCore). The shots seed the tab:
# the Explain button can't be pressed through accessibility in a hidden instance.
EXPLAIN_TAB = r"""// Review this plan request, then press Run.
// Opening or restoring this tab never runs it.
$sql = "EXPLAIN QUERY PLAN select \"id\", \"name\", \"email\" from \"users\" where \"name\" like ? order by \"name\" asc";
$bindings = [
    0 => "%Example",
];
$connectionName = "sqlite";
$connection = \Illuminate\Support\Facades\DB::connection($connectionName);
$plan = $connection->select($sql, $bindings);
// Runlet shows the plan as a tree, with the database's own output under Raw.
return function_exists('Runlet\explainPlan')
    ? \Runlet\explainPlan($plan, $connection, $connectionName)
    : $plan;
"""

LOGS = """use Illuminate\\Support\\Facades\\Log;

Log::info('Import started', ['batch' => 42]);

try {
    throw new RuntimeException('Payment gateway timed out');
} catch (RuntimeException $e) {
    Log::error('Checkout failed', ['order' => 1042, 'exception' => $e]);
}

Log::warning('Retrying payment', ['order' => 1042, 'attempt' => 2]);
"""

REFERENCES = """use Illuminate\\Support\\Str;

$names = ['Alice Example', 'Bob Example'];

array_map(fn ($name) => Str::slug($name), $names);
"""

APP_INFO = """use App\\Models\\User;

User::count();
"""

REFUND_ORDER = """/**
 * @input int $orderId "Order ID"
 * @input float $amount "Amount" = 19.99
 * @input string $reason "Reason" = "duplicate" {duplicate, fraudulent, requested_by_customer}
 * @input string $note "Internal note"
 * @input bool $notify "Email the customer" = true
 */

use App\\Models\\Order;

$order = Order::findOrFail($orderId);
$order->refund($amount, reason: $reason, note: $note, notify: $notify);
$order->fresh();
"""

PROMOTE = """use App\\Models\\User;

$user = User::factory()->create(['email' => 'dana@example.com']);

expect($user->fresh()->email)->toBe('dana@example.com');
"""

DESCRIBED = """collect([
    ['order' => 'A104', 'total' => 48],
    ['order' => 'A105', 'total' => 72],
])->sortByDesc('total')->values();
"""


def snippet(label: str, code: str, description: str | None = None, hours: int = 1, **extra) -> dict:
    data = {"id": uid(), "label": label, "code": code, "createdAt": NOW - 3600 * hours, "updatedAt": NOW - 3600 * hours}
    if description:
        data["description"] = description
    data.update(extra)
    return data


def history(code: str, minutes: int, status: str = "completed", target=None, label: str = "Laravel Sandbox",
            environment: str = "development", reason: str | None = None, elapsed: int = 180) -> dict:
    return {"id": uid(), "runId": uid(), "timestamp": NOW - 60 * minutes, "code": code, "target": target or SANDBOX,
            "targetLabel": label, "status": status, "reason": reason or ("completed" if status == "completed" else "error" if status == "failed" else "cancelled"),
            "elapsedMs": elapsed, "targetEnvironment": environment}


HISTORY = [
    history("use App\\Models\\User;\n\nUser::latest('id')->take(5)->get();\n", 3, elapsed=164),
    history("use App\\Models\\User;\n\nUser::where('email', 'alice@example.com')->firstOrFail();\n", 9, elapsed=151),
    history("use App\\Models\\Order;\n\nOrder::where('status', 'paid')->whereNull('shipped_at')->count();\n", 26,
            target=SHOP, label="shop", environment="production", elapsed=842),
    history("collect([3, 5, 8])->sum() / 0;\n", 41, status="failed", elapsed=97),
    history("sleep(30);\n", 58, status="cancelled", elapsed=4210),
    history("Str::slug('Alice Example');\n", 75, elapsed=133),
]


def logs_seed(data: Path, sandbox: Path) -> None:
    """Earlier entries in the sandbox's laravel.log, before the run adds its own."""
    lines = [
        "[2026-10-04 09:14:02] local.INFO: Cache cleared [] []",
        "[2026-10-04 09:15:40] local.WARNING: Slow query {\"ms\":1240,\"table\":\"users\"} []",
        "[2026-10-04 09:16:09] local.INFO: Welcome mail queued {\"user\":2} []",
    ]
    (sandbox / "storage" / "logs").mkdir(parents=True, exist_ok=True)
    (sandbox / "storage" / "logs" / "laravel.log").write_text("\n".join(lines) + "\n")


def shop_project(data: Path) -> Path:
    """A local project "shop": a copy of the installed sandbox, with project snippets."""
    project = data / "projects" / "shop"
    project.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cp", "-cR", str(sandbox_dir(data)), str(project)], check=True)
    (project / ".runlet-installed").unlink(missing_ok=True)
    snippets = project / ".runlet" / "snippets"
    snippets.mkdir(parents=True, exist_ok=True)
    (snippets / "refund-order.php").write_text("<?php\n/**\n * @label Refund order\n * @description Refunds an order and records why.\n"
                                               + REFUND_ORDER.split("/**\n", 1)[1])
    (snippets / "recent-users.php").write_text("<?php\n/**\n * @label Recent users\n * @description The newest sign-ups first.\n */\n\n"
                                               "App\\Models\\User::latest('id')->take(10)->get();\n")
    (snippets / "open-orders.sql").write_text("-- @label Open orders\n-- @description Orders waiting to ship.\nSELECT id, status, total\nFROM orders\nWHERE status = 'open';\n")
    return project


SHOP_PROJECT_ID = "5A0B7C1E-0D0C-4E55-9A6B-3D2C1B0A9F02"
SHOP_PROJECT = {"local": {"_0": SHOP_PROJECT_ID}}


def shop_targets(data: Path) -> None:
    project = shop_project(data)
    write_state(data, "targets", {"localProjects": [{"id": SHOP_PROJECT_ID, "name": "shop", "path": str(project), "revision": 1,
                                                       "lastOpenedAt": NOW - 60}], "dockerProfiles": [], "sshProfiles": []})


CASTERS = """use App\\Support\\EmailAddress;
use App\\Support\\Money;

$order = [
    'number' => 'A-1042',
    'customer' => new EmailAddress('alice@example.com'),
    'subtotal' => new Money(4200, 'EUR'),
    'shipping' => new Money(499, 'EUR'),
    'total' => new Money(4699, 'EUR'),
];

dump($order['total']);

$order;
"""

CASTERS_DRIVER = """<?php

use App\\Support\\EmailAddress;
use App\\Support\\Money;
use Runlet\\Drivers\\LaravelDriver;

class ShopDriver extends LaravelDriver
{
    public function casters(): array
    {
        return [
            Money::class => fn (Money $money) => new \\Runlet\\Cast($money->format(), [
                'amount' => $money->amount(),
                'currency' => $money->currency(),
            ]),
            EmailAddress::class => fn (EmailAddress $email) => $email->value(),
        ];
    }
}
"""

CASTERS_CLASSES = {
    "Money": """<?php

namespace App\\Support;

final class Money
{
    public function __construct(private int $amount, private string $currency) {}

    public function amount(): int { return $this->amount; }

    public function currency(): string { return $this->currency; }

    public function format(): string
    {
        return number_format($this->amount / 100, 2) . ' ' . $this->currency;
    }
}
""",
    "EmailAddress": """<?php

namespace App\\Support;

final class EmailAddress
{
    public function __construct(private string $value) {}

    public function value(): string { return $this->value; }
}
""",
}


def casters_seed(data: Path, sandbox: Path) -> None:
    """The project "shop" with a driver whose casters show Money and EmailAddress (#6)."""
    shop_targets(data)
    project = data / "projects" / "shop"
    (project / ".runlet" / "ShopDriver.php").write_text(CASTERS_DRIVER)
    (project / "app" / "Support").mkdir(parents=True, exist_ok=True)
    for name, source in CASTERS_CLASSES.items():
        (project / "app" / "Support" / f"{name}.php").write_text(source)


def promote_seed(data: Path, sandbox: Path) -> None:
    shop_targets(data)
    # Where Save as Test writes the file: the installed sandbox has no tests/ folder.
    (data / "projects" / "shop" / "tests" / "Feature").mkdir(parents=True, exist_ok=True)


def tests_seed(data: Path) -> None:
    """The project "shop" with tests, so the Commands panel shows its Tests group."""
    shop_targets(data)
    for suite in ["Feature", "Unit"]:
        folder = data / "projects" / "shop" / "tests" / suite
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "ExampleTest.php").write_text(f"<?php\n\nnamespace Tests\\{suite};\n\ntest('example', function () {{\n    expect(true)->toBeTrue();\n}});\n")


SHOTS: list[Shot] = [
    # Basics
    Shot("quickstart", "inline-values", about="Magic comments' values after a run, as in Your First Snippet",
         tabs=[tab("Scratch", QUICKSTART_INLINE)], frame="1080x560", settings={"editorSplitRight": 0.6},
         steps=["run", "wait-run", "wait"]),
    Shot("magic-comments", "values", about="//?, a projection, a loop's ×N, and a timing",
         tabs=[tab("Scratch", MAGIC_COMMENTS)], frame="1080x560", settings={"editorSplitRight": 0.6},
         steps=["run", "wait-run", "wait"]),
    Shot("running-code", "output-pane", about="A dump card, a Result table, and the footer",
         tabs=[tab("Users", OUTPUT_PANE)], frame="1200x640",
         steps=["run", "wait-run", "wait", "segment:Table", "wait"]),
    Shot("running-code", "model-values", about="Values: a collection of users, a changed one, a new one, hidden attributes",
         tabs=[tab("Users", MODEL_VALUES)], frame="1200x760", settings={"valueExpansion": "all", "editorSplitRight": 0.45},
         steps=["run", "wait-run", "wait", "model-state", "wait"]),
    Shot("running-code", "model-object", about="Object: the same collection as the whole object",
         tabs=[tab("Users", MODEL_VALUES)], frame="1200x640", settings={"valueExpansion": "all", "editorSplitRight": 0.45},
         steps=["run", "wait-run", "wait", "segment:Object", "wait", "model-state", "wait"]),
    Shot("running-code", "history", about="History: All Projects, statuses, and a PROD badge",
         tabs=[tab("Scratch", "use App\\Models\\User;\n\nUser::count();\n")], history=HISTORY, frame="1200x680",
         # Typing in the search selects the best match; clearing it keeps the newest run selected.
         steps=["inspector:history", "wait", "segment:All Projects", "wait", "search:history-search|User", "wait",
                "search:history-search|", "wait"]),
    Shot("run-timings", "finished-line", about="The finished line: total, memory, queries, bootstrap, execute",
         tabs=[tab("Timing breakdown", TIMINGS)], frame="1080x520",
         steps=["run", "wait-run", "wait"]),
    Shot("sandbox-auto-run", "idle", about="Auto-run on, nothing run yet",
         tabs=[tab("Slugs", AUTO_RUN)], frame="1080x520",
         steps=["auto-run:on", "wait"]),
    Shot("sandbox-auto-run", "result", about="An auto-run's result after an edit",
         tabs=[tab("Slugs", AUTO_RUN)], frame="1080x520",
         steps=["auto-run:on", "wait", "caret:end", "edit:    ->implode(' / ');", "wait", "wait-run", "wait"]),
    # Writing code
    Shot("navigation", "find-references", about="Find References: the tab first, then project and vendor files",
         tabs=[tab("Slugs", REFERENCES)], settings={"languageServiceEnabled": True, "outputVisible": False}, frame="1080x600",
         steps=["nav-wait:ready:120", "nav-references:5:31", "nav-wait:done", "wait", "wait"]),
    Shot("snippet-inputs", "input-form", about="The input form of the Refund order snippet",
         tabs=[tab("Scratch", "")], snippets=[snippet("Refund order", REFUND_ORDER, "Refunds an order and records why.")],
         frame="1080x640", steps=["snippet-open:Refund order", "wait", "snippet-input:orderId=1042",
                                   "snippet-input:note=Charged twice at checkout", "wait"]),
    Shot("personal-snippets", "snippets-panel", about="Personal snippets with descriptions",
         tabs=[tab("Order lookup", DESCRIBED)], frame="1200x680", settings={"libraryPanelWidth": 350},
         snippets=[snippet("Recent orders", DESCRIBED, "Pending shipments, newest first. Use this to review orders before the daily dispatch."),
                   snippet("Monthly totals", "collect([48, 72, 120])->sum();\n", "Reconcile invoice totals for the current month.", hours=5),
                   snippet("Quick scratch", "now()->toDateString();\n", hours=9)],
         steps=["inspector:snippets", "wait"]),
    Shot("personal-snippets", "edit-sheet", about="Editing a personal snippet's description",
         tabs=[tab("Order lookup", DESCRIBED)], frame="1200x680", settings={"libraryPanelWidth": 350},
         snippets=[snippet("Recent orders", DESCRIBED, "Pending shipments, newest first. Use this to review orders before the daily dispatch."),
                   snippet("Monthly totals", "collect([48, 72, 120])->sum();\n", "Reconcile invoice totals for the current month.", hours=5)],
         steps=["inspector:snippets", "wait", "search:snippet-search|shipments", "wait", "press:snippet-edit-button", "wait"]),
    Shot("project-snippets", "snippets-panel", about="Project snippets above personal ones, with inputs and SQL badges",
         tabs=[tab("Scratch", "", target=SHOP_PROJECT)], frame="1200x680", settings={"libraryPanelWidth": 350},
         snippets=[snippet("Quick scratch", "now()->toDateString();\n", "Today's date.", hours=9)],
         seed=lambda data, sandbox: shop_targets(data), crop=(0, 0, 1200, 652),  # without the status bar (the folder)
         steps=["inspector:snippets", "wait", "wait"]),
    Shot("promote-snippets", "save-as-test", about="The sheet after Save as Test…",
         tabs=[tab("New user", PROMOTE, target=SHOP_PROJECT)], frame="1080x600",
         settings={"externalEditor": "phpstorm"}, seed=promote_seed, crop=(0, 0, 1080, 572),  # without the status bar
         steps=["promote:test:{project}/tests/Feature/NewUserTest.php", "wait", "wait"]),
    # Inspecting runs
    Shot("run-inspector", "queries", about="Queries with an N+1 and a repeated statement (also Quickstart)",
         tabs=[tab("Sessions", QUERIES)], frame="1200x680",
         steps=["run", "wait-run", "wait", "section:Queries", "wait"]),
    # #5: the HTTP section (bodies on, the first request open), Jobs, and Events (Events on).
    Shot("run-inspector", "http", about="HTTP: faked, local, and failed requests, one open with redacted headers and bodies",
         tabs=[tab("Orders API", HTTP_CALLS)], frame="1280x780", settings={"recordHTTPBodies": True}, background=local_api,
         steps=["run", "wait-run", "wait", "section:HTTP", "recorder-expand:HTTP:redacted", "wait", "recorder-state"]),
    Shot("run-inspector", "jobs", about="Jobs: a sync job that ran, one that failed, and one queued on the database queue",
         tabs=[tab("Welcome emails", JOBS)], frame="1280x780",
         steps=["run", "wait-run", "wait", "section:Jobs", "recorder-expand:Jobs:3", "wait", "recorder-state"]),
    Shot("run-inspector", "events", about="Events: model, cache, and the snippet's own events (Record events on)",
         tabs=[tab("Ship order", EVENTS)], frame="1280x780", settings={"recordEvents": True},
         steps=["run", "wait-run", "wait", "recorder-expand:Events:7", "section:Events", "wait", "recorder-state"]),
    Shot("benchmarks", "benchmark-card", about="bench() comparing array_map and foreach",
         tabs=[tab("Benchmark", BENCH)], frame="1200x760",
         steps=["run", "wait-run:90", "wait", "wait"]),
    Shot("string-viewers", "json", about="A JSON string in the JSON viewer",
         tabs=[tab("API response", STRING_JSON)], settings={"valueExpansion": "all"}, frame="1080x600",
         steps=["run", "wait-run", "wait", "segment:JSON", "wait"]),
    Shot("string-viewers", "image", about="A base64 SVG in the Image viewer",
         tabs=[tab("Encoded image", STRING_SVG)], frame="1080x600",
         steps=["run", "wait-run", "wait", "wait"]),
    Shot("logs", "logs-window", about="The Logs window: sources, an error's stack trace, and Last Run",
         tabs=[tab("Checkout", LOGS)], seed=logs_seed, window="Logs",
         steps=["run", "wait-run", "wait", "logs", "frame:Logs=1180x700", "logs-wait:3", "logs-last-run:on", "wait",
                "logs-expand:Checkout failed", "wait"]),
    Shot("sql-explain", "explain-tab", about="Queries with Explain, and the Explain #1 tab it opened",
         tabs=[tab("Users by name", EXPLAIN), tab("Explain #1", EXPLAIN_TAB)], frame="1200x640",
         steps=["run", "wait-run", "wait", "section:Queries", "wait"]),
    Shot("sql-explain", "plan-card", about="The plan card of an explained query, with a full scan",
         tabs=[tab("Users by name", EXPLAIN), tab("Explain #1", EXPLAIN_TAB)], selected=1, frame="1200x640",
         steps=["run", "wait-run", "wait"]),
    Shot("app-info", "app-info", about="The App Info popover for the sandbox",
         tabs=[tab("Users", APP_INFO)], frame="1200x820",
         steps=["app-info", "wait", "wait", "wait"]),
    Shot("project-commands", "commands", about="The Commands panel of a Laravel project: REPL, Tests, and Artisan commands",
         tabs=[tab("Users", APP_INFO, target=SHOP_PROJECT)], frame="1200x760", settings={"libraryPanelWidth": 360},
         # The crop leaves out the status bar, which shows the project's folder.
         seed=lambda data, sandbox: tests_seed(data), crop=(0, 0, 1200, 732),
         steps=["inspector:commands", "wait", "wait", "wait", "wait"]),
    # Targets and drivers
    Shot("dry-run", "dry-run", about="Dry Run on, and its card at the end of the output",
         tabs=[tab("Rename users", DRY_RUN)], frame="1200x640",
         steps=["rollback:on", "wait", "run", "wait-run", "wait"]),
    Shot("environments", "production-confirmation", about="Run this code on production? (never answered)",
         tabs=[tab("Unshipped orders", PRODUCTION, target=SHOP)], targets=PRODUCTION_TARGETS, frame="1080x640",
         steps=["run", "wait", "wait"]),
    Shot("drivers", "casters", about="Values a project driver's casters show, one of them raw",
         tabs=[tab("Order", CASTERS, target=SHOP_PROJECT)], frame="1240x600", settings={"valueExpansion": "firstLevel"},
         seed=casters_seed, crop=(0, 0, 1240, 572),  # without the status bar (the folder)
         steps=["run", "wait-run", "wait", "press:value-cast-mark", "wait"]),
    Shot("driver-inspector", "mail-chip", about="The mail chip's popover on a production target that intercepts mail",
         tabs=[tab("Unshipped orders", PRODUCTION, target=SHOP)], targets=PRODUCTION_TARGETS, frame="1080x560",
         steps=["mail-chip:on", "wait", "wait"]),
    # Settings
    Shot("settings", "general", about="Settings ▸ General: Appearance, Running, and Notifications",
         tabs=[tab("Scratch", "")], window="General",
         steps=["settings", "wait", "settings-tab:General", "wait", "frame:General=600x760", "wait"]),
    Shot("run-notifications", "notifications", about="Settings ▸ General ▸ Notifications, allowed",
         tabs=[tab("Scratch", "")], window="General", settings={"notifyLongRuns": True, "longRunNotificationSeconds": 10},
         # Tall enough not to scroll (the toolbar would show the scrolled text), then the section only.
         steps=["notifications:allowed", "settings", "wait", "settings-tab:General", "wait", "frame:General=600x1000", "wait"],
         crop=(0, 462, 600, 228)),
]

# MARK: Fixture-backed shots (#304)
#
# Redis, MongoDB, PostgreSQL, Docker, and SSH shots use the runlet-fixtures containers only
# (docs/testing.md#setting-up-the-fixtures), with neutral data the script seeds into its own Redis
# database and MongoDB database and removes again. Connections are saved by steps (`db-new`), so
# their passwords stay in the instance's memory; `{redis-port}`, `{mongo-port}`, and `{pg-port}` in
# a step are the fixtures' published ports, found by the checks in NEEDS.

REDIS_SEED = f"""SELECT {REDIS_DB}
FLUSHDB
SET greeting "hello world"
HSET user:42 name "Alice Example" email alice@example.com plan pro visits 18
HSET user:43 name "Bob Example" email bob@example.com plan free visits 3
HSET user:44 name "Carol Example" email carol@example.com plan pro visits 41
HSET session:42 user 42 ip 203.0.113.7 agent "Safari 26"
EXPIRE session:42 3600
HSET cart:1042 TEE-ORG 2 MUG-ENM 1
EXPIRE cart:1042 86400
RPUSH recent:orders order:1042 order:1041 order:1040 order:1039
ZADD leaderboard 1430 carol 1250 alice 980 bob 610 dana
SADD tags:featured mugs tees socks
SET cache:catalog:featured '{{"ids":[12,7,31],"updated":"2026-10-04T09:00:00Z"}}'
EXPIRE cache:catalog:featured 600
SET page:views 1024
XADD events * type signup user 42
XADD events * type order user 43 total 48.00
"""

MONGO_SEED = f"""
const shop = db.getSiblingDB("{MONGO_DB}");
shop.dropDatabase();
const people = [["Alice Example", "alice@example.com", "pro"], ["Bob Example", "bob@example.com", "free"],
  ["Carol Example", "carol@example.com", "pro"], ["Dana Example", "dana@example.com", "free"], ["Erin Example", "erin@example.com", "team"]];
const customers = people.map(([name, email, plan], i) => ({{ _id: ObjectId("66b0000000000000000000a" + i), name, email, plan,
  since: new Date(Date.UTC(2025, 2 + i * 2, 1 + i * 3)) }}));
shop.customers.insertMany(customers);
const statuses = ["paid", "shipped", "pending", "paid", "refunded", "shipped"];
const skus = [["TEE-ORG", "Organic cotton tee"], ["MUG-ENM", "Enamel camp mug"], ["TOTE-CNV", "Canvas tote bag"], ["SOCK-MER", "Merino socks"]];
const orders = [];
for (let i = 0; i < 40; i++) {{
  const c = customers[i % customers.length];
  const status = statuses[i % statuses.length];
  const placed = new Date(Date.UTC(2026, 8, 1 + (i % 30), 8 + (i % 10), (i * 17) % 60));
  orders.push({{ number: 1001 + i, status, customer_id: c._id, customer: {{ name: c.name, email: c.email }},
    total: NumberDecimal(((i * 37) % 180 + 12.5).toFixed(2)),
    items: [{{ sku: skus[i % 4][0], name: skus[i % 4][1], qty: NumberInt(1 + (i % 3)) }}],
    placed_at: placed, shipped_at: status === "shipped" ? new Date(placed.getTime() + 86400000) : null }});
}}
shop.orders.insertMany(orders);
shop.products.insertMany(skus.map(([sku, name], i) => ({{ sku, name, price: NumberDecimal((12 + i * 7).toFixed(2)), in_stock: i !== 2 }})));
print(shop.orders.countDocuments() + " orders");
"""


def docker(*args: str, input: str | None = None) -> str:
    """The fixtures-only Docker CLI; its output, or "" when it fails."""
    result = subprocess.run([str(FIXTURE_DOCKER), *args], capture_output=True, text=True, input=input)
    return result.stdout.strip() if result.returncode == 0 else ""


def container(service: str) -> str:
    """The running runlet-fixtures container of a Compose service, or ""."""
    return docker("compose", "-p", "runlet-fixtures", "ps", "-q", service).split("\n")[0]


def published_port(container_id: str, port: int) -> str | None:
    ports = json.loads(docker("inspect", "--format", "{{json .NetworkSettings.Ports}}", container_id) or "{}") or {}
    return next((binding["HostPort"] for binding in ports.get(f"{port}/tcp") or [] if binding.get("HostIp") in ("127.0.0.1", "0.0.0.0", "")), None)


def reachable(port: int) -> bool:
    with socket.socket() as probe:
        probe.settimeout(2)
        return probe.connect_ex(("127.0.0.1", port)) == 0


#: Published ports of the fixtures the chosen shots need, for `{redis-port}` and the like in steps.
FIXTURE: dict[str, str] = {}
SSH_DIR = WORK / "ssh"
#: The fixture SSH host's names in the throwaway ssh config: example.com names, so pictures show
#: no address or port.
SSH_HOSTS = ["app.example.com", "shop.example.com"]


def fixture(service: str, start: str, port: int | None = None, key: str | None = None) -> Callable[[], str | None]:
    """A check that the runlet-fixtures `service` runs (and, with `port`, listens on this Mac)."""
    def check() -> str | None:
        found = container(service)
        if not found:
            return f"the runlet-fixtures {service} container isn't running (start it with {start})"
        if port is not None:
            published = published_port(found, port)
            if not published or not reachable(int(published)):
                return f"the runlet-fixtures {service} container doesn't listen on 127.0.0.1 (start it with {start})"
            FIXTURE[key or service] = published
        return None
    return check


def ssh_ready() -> str | None:
    problem = fixture("ssh", "scripts/setup-fixtures.sh docker")()
    if problem:
        return problem
    if not reachable(2222):
        return "the runlet-fixtures ssh container doesn't listen on 127.0.0.1:2222"
    return None if Path("/usr/bin/ssh").exists() else "/usr/bin/ssh is missing"


def seed_redis() -> None:
    docker("exec", "-i", container("redis"), "redis-cli", "-a", FIXTURE_PASSWORD, "--no-auth-warning", input=REDIS_SEED)


def clean_redis() -> None:
    docker("exec", "-i", container("redis"), "redis-cli", "-a", FIXTURE_PASSWORD, "--no-auth-warning", "-n", str(REDIS_DB), "FLUSHDB")


def mongosh(script: str) -> str:
    return docker("exec", "-i", container("mongo"), "mongosh", "--quiet", "-u", "runlet", "-p", FIXTURE_PASSWORD,
                  "--authenticationDatabase", "admin", input=script)


def seed_mongo() -> None:
    if "40 orders" not in mongosh(MONGO_SEED):
        raise RuntimeError(f"couldn't seed the {MONGO_DB} database in the runlet-fixtures mongo container")


def clean_mongo() -> None:
    mongosh(f'db.getSiblingDB("{MONGO_DB}").dropDatabase()')


def seed_ssh() -> None:
    """A throwaway key in the fixture's authorized_keys2 (the SSH tests rewrite authorized_keys),
    and an ssh config that sends the example.com names to it. ~/.ssh is never read."""
    close_ssh()
    shutil.rmtree(SSH_DIR, ignore_errors=True)
    SSH_DIR.mkdir(parents=True)
    key = SSH_DIR / "id_ed25519"
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", SSH_KEY_COMMENT, "-f", str(key)], check=True)
    ssh = container("ssh")
    docker("exec", "-i", ssh, "sh", "-c", "cat >> /home/runlet/.ssh/authorized_keys2 && chown runlet:runlet /home/runlet/.ssh/authorized_keys2"
           " && chmod 600 /home/runlet/.ssh/authorized_keys2", input=key.with_suffix(".pub").read_text())
    host_key = docker("exec", ssh, "cat", "/etc/ssh/ssh_host_ed25519_key.pub").split()[:2]
    (SSH_DIR / "known_hosts").write_text(f"[127.0.0.1]:2222 {' '.join(host_key)}\n")
    (SSH_DIR / "config").write_text("".join(
        f"Host {host}\n    HostName 127.0.0.1\n    Port 2222\n    User runlet\n    IdentityFile {key}\n    IdentitiesOnly yes\n"
        f"    IdentityAgent none\n    PasswordAuthentication no\n    UserKnownHostsFile {SSH_DIR / 'known_hosts'}\n"
        "    GlobalKnownHostsFile /dev/null\n\n" for host in SSH_HOSTS))
    subprocess.run(["/usr/bin/ssh", "-F", str(SSH_DIR / "config"), "-o", "BatchMode=yes", "-o", "LogLevel=ERROR", SSH_HOSTS[0], "true"],
                   check=True, env={**os.environ, "SSH_AUTH_SOCK": ""}, timeout=30)


def clean_ssh() -> None:
    close_ssh()
    docker("exec", container("ssh"), "sh", "-c", f"sed -i '/{SSH_KEY_COMMENT}/d' /home/runlet/.ssh/authorized_keys2")
    shutil.rmtree(SSH_DIR, ignore_errors=True)


def close_ssh() -> None:
    """Ends the fixture profiles' SSH connections. A hidden instance quits without closing
    them, and every instance shares their control sockets (Runlet's temporary `runlet-ssh`
    folder, by profile id: SSHControlPaths), so this runs before the shots and after them."""
    folder = Path(subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()) / "runlet-ssh"
    for ident in [STAGING_ID, PRODUCTION_ID]:
        control = folder / (ident.replace("-", "")[:8].lower() + ".sock")
        if control.exists():
            subprocess.run(["/usr/bin/ssh", "-F", "/dev/null", "-S", str(control), "-O", "exit", SSH_HOSTS[0]],
                           capture_output=True, timeout=10)


#: What a fixture needs before its shots and after them: seed and clean up its data.
PREPARE: dict[str, tuple[Callable[[], None], Callable[[], None]]] = {
    "redis": (seed_redis, clean_redis),
    "mongo": (seed_mongo, clean_mongo),
    "ssh": (seed_ssh, clean_ssh),
}

REDIS_CONNECTION = [f"db-new:Shop cache|redis|127.0.0.1|{{redis-port}}|{REDIS_DB}||{FIXTURE_PASSWORD}|mac", "db-use:Shop cache", "wait"]
MONGO_CONNECTION = [f"db-new:Shop|mongodb|127.0.0.1|{{mongo-port}}|{MONGO_DB}|runlet|{FIXTURE_PASSWORD}|mac", "db-use:Shop", "wait"]

REDIS_REPLIES = """GET greeting
HGETALL user:42
LRANGE recent:orders 0 2
ZRANGE leaderboard 0 2 REV WITHSCORES
# An error: Run All stops here.
INCR greeting
"""

REDIS_LOOKUP = """# Look up a customer
HGETALL user:42
TTL session:42
ZSCORE leaderboard alice
"""

REDIS_SESSION = """# @input string $user "User id" = "42"
HGETALL session:$user
TTL session:$user
"""

MONGO_FIND = """{
  "collection": "orders",
  "operation": "find",
  "filter": { "status": "paid" },
  "projection": { "_id": 0, "number": 1, "customer.name": 1, "total": 1, "placed_at": 1 },
  "sort": { "total": -1, "_id": 1 },
  "limit": 3
}
"""


def step_json(query: dict) -> str:
    """A query as one step argument: compact JSON, commas as \\c."""
    return json.dumps(query, separators=(", ", ": ")).replace(",", "\\c")


MONGO_BUILDER = {
    "collection": "orders", "operation": "find",
    "filter": {"status": {"$in": ["paid", "shipped"]}, "total": {"$gte": {"$numberDecimal": "50.00"}},
               "placed_at": {"$gte": {"$date": "2026-09-15T00:00:00Z"}}},
    "projection": {"_id": 0, "number": 1, "customer.name": 1, "total": 1, "placed_at": 1},
    "sort": {"placed_at": -1},
    "limit": 20,
}

PG_SLEEP = """-- Rebuild the order totals (slow on purpose)
SELECT pg_sleep(45) AS order_totals;
"""

SSH_SLEEP = """// A long job on the server.
sleep(45);
"""

DOCKER_LARAVEL = """use Illuminate\\Support\\Str;

collect(['Alice Example', 'Bob Example', 'Carol Example'])
    ->map(fn ($name) => [
        'name' => $name,
        'slug' => Str::slug($name),
        'initials' => Str::initials($name),
    ])
    ->all();
"""

PROFILE = """use Illuminate\\Support\\Str;

function slugs(int $count): array
{
    $slugs = [];
    for ($i = 1; $i <= $count; $i++) {
        $slugs[] = Str::slug("Order {$i} shipped");
    }
    return $slugs;
}

function checksums(array $values): array
{
    return array_map(fn ($value) => hash('sha256', $value), $values);
}

function ranked(array $values): array
{
    usort($values, fn ($a, $b) => strcmp($b, $a));
    return $values;
}

$slugs = slugs(150000);
checksums($slugs);
ranked($slugs)[0];
"""

MCP_CODE = ("use App\\Models\\Order;\\n\\n// Paid orders that haven't shipped after a day.\\nOrder::where('status'\\c 'paid')\\n"
            "    ->whereNull('shipped_at')\\n    ->where('paid_at'\\c '<'\\c now()->subDay())\\n    ->count();")

# Runlet names an SSH profile's control socket by the first 8 hex digits of its id, so the
# fixture profiles' ids differ there (and from SHOP_ID's).
STAGING_ID = "D0C5A001-0D0C-4E55-9A6B-3D2C1B0A9F04"
PRODUCTION_ID = "D0C5A002-0D0C-4E55-9A6B-3D2C1B0A9F05"
DOCKER_ID = "5A0B7C1E-0D0C-4E55-9A6B-3D2C1B0A9F03"
STAGING = {"ssh": {"_0": STAGING_ID}}
PRODUCTION_SSH = {"ssh": {"_0": PRODUCTION_ID}}
DOCKER_TARGET = {"docker": {"_0": DOCKER_ID}}


def ssh_profile(ident: str, name: str, host: str, environment: str, minutes: int) -> dict:
    return {"id": ident, "name": name, "host": host, "remoteDirectory": "/home/runlet/site/current", "phpExecutable": "php",
            "authentication": "automatic", "keepAliveMinutes": 10, "compression": False, "environment": environment,
            "checkDrift": False, "revision": 1, "lastOpenedAt": NOW - 60 * minutes}


def docker_profile(service: str, source: Path) -> dict:
    """"orders-api": a runlet-fixtures Compose service, through the fixtures-only Docker CLI. Its
    local source is a scratch copy of the sandbox, so no banner names the folder the fixture mounts."""
    return {"id": DOCKER_ID, "name": "orders-api", "identity": {"composeProject": "runlet-fixtures", "composeService": service},
            "workingDirectory": "/var/www/html", "phpExecutable": "php", "temporaryDirectory": "/tmp", "localSourcePath": str(source),
            "autoResolve": False, "revision": 1, "lastOpenedAt": NOW - 120}


DOCKER_SETTINGS = {"dockerExecutable": str(FIXTURE_DOCKER)}


def fixture_targets(data: Path, service: str | None = "laravel", project: bool = True, production: bool = True) -> None:
    """The saved targets of the fixture shots: the local project "shop" (a copy of the
    sandbox), "orders-api" on a fixture container (with `service`; such shots also set
    DOCKER_SETTINGS), and SSH hosts that are the fixture: staging, and production."""
    folder = shop_project(data) if project or service else None
    local = [{"id": SHOP_PROJECT_ID, "name": "shop", "path": str(folder), "revision": 1, "lastOpenedAt": NOW - 30}] if project else []
    containers = [docker_profile(service, folder)] if service else []
    hosts = [ssh_profile(STAGING_ID, "staging", SSH_HOSTS[0], "staging", 3)]
    if production:
        hosts.append(ssh_profile(PRODUCTION_ID, "production", SSH_HOSTS[1], "production", 4))
    write_state(data, "targets", {"localProjects": local, "dockerProfiles": containers, "sshProfiles": hosts})


def tableplus_seed(data: Path, sandbox: Path) -> None:
    """A made-up TablePlus export (Tests/Fixtures/tableplus) in the shot's data folder; the app
    reads it instead of TablePlus's own files, and its fake Keychain file instead of the Keychain."""
    shutil.copytree(ROOT / "Tests" / "Fixtures" / "tableplus", data / "TablePlus")


def redis_blocked_client() -> subprocess.Popen:
    """A worker blocked in BLPOP on the docs' Redis database, for the server details."""
    process = subprocess.Popen([str(FIXTURE_DOCKER), "exec", "-i", container("redis"), "redis-cli", "-a", FIXTURE_PASSWORD,
                                "--no-auth-warning", "-n", str(REDIS_DB)], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, text=True)
    process.stdin.write("CLIENT SETNAME mail-worker\nBLPOP queue:emails 60\n")
    process.stdin.close()
    return process


def mongo_slow_operation() -> subprocess.Popen:
    """A report that runs for a minute on the docs' MongoDB database, for the Server section."""
    url = f"mongodb://runlet:{FIXTURE_PASSWORD}@127.0.0.1:27017/{MONGO_DB}?authSource=admin&appName=nightly-report"
    return subprocess.Popen([str(FIXTURE_DOCKER), "exec", container("mongo"), "mongosh", "--quiet", url, "--eval",
                             "db.orders.find({$where: 'sleep(60000) || true'}).limit(1).toArray()"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


SHOTS += [
    # Redis (redis.md): the docs' own database on the fixture, connected from this Mac.
    Shot("redis", "replies", needs="redis", about="String, hash, list, sorted-set, and error replies after Run All",
         tabs=[tab("Shop cache", REDIS_REPLIES, language="redis")], frame="1200x1060",
         steps=REDIS_CONNECTION + ["redis-run-all", "wait-run", "wait", "wait"]),
    Shot("redis", "connection-editor", needs="redis", about="A Redis connection in the editor, after Test Connection",
         tabs=[tab("Shop cache", REDIS_LOOKUP, language="redis")], frame="1200x900",
         steps=["db-editor:new", "wait", "db-field:name=Shop cache", "db-field:driver=redis", "db-field:host=127.0.0.1",
                "db-field:port={redis-port}", f"db-field:database={REDIS_DB}", f"db-field:password={FIXTURE_PASSWORD}",
                "db-field:connectFrom=mac", "wait", "db-test", "db-wait", "scroll:db-test-result", "wait"]),
    Shot("redis", "command-builder", needs="redis", about="The Command Builder's command list",
         tabs=[tab("Shop cache", REDIS_LOOKUP, language="redis")], frame="1200x760",
         steps=REDIS_CONNECTION + ["redis-builder:open", "wait", "redis-builder:picker", "wait", "wait"]),
    Shot("redis", "zrange-form", needs="redis", about="ZRANGE's form with BYSCORE, REV, LIMIT, WITHSCORES, and the line it inserted",
         tabs=[tab("Shop cache", REDIS_LOOKUP, language="redis")], frame="1200x760",
         steps=REDIS_CONNECTION + ["redis-builder:open", "wait", "caret:end",
                                   "redis-builder-line:ZRANGE leaderboard +inf 1000 BYSCORE REV LIMIT 0 10 WITHSCORES", "wait",
                                   "redis-builder:insert", "wait", "wait"]),
    Shot("redis", "completion", needs="redis", about="Completion after HGETALL: hash keys from the key browser's scan first",
         tabs=[tab("Shop cache", "# Look up a customer\n", language="redis")], frame="1200x700",
         steps=REDIS_CONNECTION + ["inspector:database", "wait", f"redis-db:{REDIS_DB}", "redis-scan", "redis-wait", "wait", "caret:end",
                                   "redis-type:HGETALL\\s", "redis-complete", "wait", "wait"]),
    Shot("redis", "key-browser", needs="redis", about="The key browser: keys, types, TTLs, and a key's memory usage",
         tabs=[tab("Shop cache", REDIS_LOOKUP, language="redis")], frame="1200x760",
         steps=REDIS_CONNECTION + ["inspector:database", "wait", f"redis-db:{REDIS_DB}", "redis-scan", "redis-wait", "wait",
                                   "redis-memory:user:42", "redis-wait", "wait"]),
    Shot("redis", "server-details", needs="redis", about="Server details with the connected clients, one blocked",
         tabs=[tab("Shop cache", REDIS_LOOKUP, language="redis")], frame="1200x800", background=redis_blocked_client,
         steps=REDIS_CONNECTION + ["inspector:database", "wait", "redis-server", "redis-wait", "wait", "wait"]),
    Shot("redis", "snippet-inputs", needs="redis", about="The input form of a Redis snippet",
         tabs=[tab("Shop cache", REDIS_LOOKUP, language="redis")], frame="1080x640",
         snippets=[snippet("Inspect a user's session", REDIS_SESSION, "The session hash and how long it lives", language="redis")],
         steps=REDIS_CONNECTION + ["snippet-open:Inspect a user's session", "wait", "snippet-input:user=43", "wait"]),
    Shot("redis", "flushdb-confirmation", needs="redis", about="The confirmation FLUSHDB asks for (never answered)",
         tabs=[tab("Maintenance", "# Empties the connection's database\nFLUSHDB\n", language="redis")], frame="1080x640",
         steps=REDIS_CONNECTION + ["redis-danger:ask", "run", "wait", "wait"]),
    # MongoDB (mongodb.md): the docs' own database on the fixture, connected from this Mac.
    Shot("mongodb", "find-query", needs="mongo", about="A find query, its result table, and the Extended JSON tree",
         tabs=[tab("Paid orders", MONGO_FIND, language="mongodb")], frame="1200x900", settings={"valueExpansion": "all"},
         steps=MONGO_CONNECTION + ["run", "wait-run", "wait", "scroll-top:output-list", "wait"]),
    Shot("mongodb", "query-builder", needs="mongo", about="The Query Builder beside a find: three rules and a date value",
         tabs=[tab("Recent orders", "", language="mongodb")], frame="1280x820",
         steps=MONGO_CONNECTION + ["mongo-explorer", "wait-run", "mongo-sample:orders", "wait-run", "inspector:", "section:", "wait",
                                   "mongo-builder:open", "wait", f"mongo-builder-set:{step_json(MONGO_BUILDER)}", "wait", "wait",
                                   "mongo-builder-scroll:mongo-builder-top", "run", "wait-run", "wait"]),
    Shot("mongodb", "collection-explorer", needs="mongo", about="The collection explorer with sampled fields",
         tabs=[tab("Paid orders", MONGO_FIND, language="mongodb")], frame="1200x800",
         steps=MONGO_CONNECTION + ["inspector:database", "mongo-explorer", "wait-run", "mongo-sample:orders", "wait-run", "wait", "wait"]),
    Shot("mongodb", "server-operations", needs="mongo", about="The Server section with a running operation and Kill…",
         tabs=[tab("Paid orders", MONGO_FIND, language="mongodb")], frame="1200x820", background=mongo_slow_operation,
         steps=MONGO_CONNECTION + ["inspector:database", "wait", "mongo-server", "wait", "wait", "wait", "mongo-server-state"]),
    # Connections (connections.md)
    Shot("connections", "postgres-editor", needs="postgres", about="A PostgreSQL connection in the editor, after Test Connection",
         tabs=[tab("Reports", "SELECT 1;\n", language="sql")], frame="1200x900",
         steps=["db-editor:new", "wait", "db-field:name=Reporting", "db-field:driver=pgsql", "db-field:host=127.0.0.1",
                "db-field:port={pg-port}", "db-field:database=shop", "db-field:user=postgres", f"db-field:password={FIXTURE_PASSWORD}",
                "wait", "db-test", "db-wait", "scroll:db-test-result", "wait"]),
    Shot("connections", "tableplus-import", about="Import from TablePlus with a few connections selected (a made-up export)",
         tabs=[tab("Scratch", "")], window="Databases", seed=tableplus_seed, settings_tab=7,
         env={"RUNLET_TABLEPLUS_DIR": "{data}/TablePlus", "RUNLET_FEATURE_FLAGS": "tablePlusImport",
              "RUNLET_DEBUG_TABLEPLUS_PATH": "~/Library/Application Support/com.tinyapp.TablePlus/Data/Connections.plist"},
         steps=["ssh-add:Acme jump|ops@jump.example.org|/srv/app|staging",
                "db-new:Acme Shop (staging)|mysql|staging-db.acme.example.com|3307|shop|shop|",
                "settings", "wait", "wait", "frame:Databases=600x780", "wait",
                "tableplus-open", "wait", "wait", "tableplus-select:Acme Shop (production)", "tableplus-select:Acme Shop (staging)",
                "tableplus-select:Acme Reports", "tableplus-select:Example Blog", "wait", "tableplus-state"]),
    Shot("connections", "connection-manager", needs="ssh+postgres",
         about="The Connection Manager: an SSH connection, its tunnel, a database session, and a PHP run",
         tabs=[tab("Order totals", PG_SLEEP, language="sql"), tab("Server check", SSH_SLEEP, target=STAGING)],
         seed=lambda data, sandbox: fixture_targets(data, service=None, project=False, production=False), window="Connections",
         steps=["connect:staging", "connections-wait:ssh=1:25", "select:Order totals",
                f"db-new:Analytics|pgsql|postgres|5432|shop|postgres|{FIXTURE_PASSWORD}|via-staging", "db-use:Analytics", "run", "wait",
                "select:Server check", "run", "connections-wait:phpRun=1:30", "connections-wait:database=1:40",
                "connections-wait:tunnel=1:30", "select:Order totals", "wait", "connections", "wait", "frame:Connections=900x680", "wait",
                "connections-state"]),
    # Targets (targets.md): vertical tabs on the sandbox, a local project, a fixture container, and the fixture SSH host.
    Shot("targets", "targets", needs="docker+ssh", about="Vertical tabs on five targets, and a Laravel snippet's output in Docker",
         tabs=[tab("Scratch", "Str::slug('Alice Example');\n"), tab("Recent users", "User::latest('id')->take(5)->get();\n", target=SHOP_PROJECT),
               tab("Slugs", DOCKER_LARAVEL, target=DOCKER_TARGET), tab("Server check", "PHP_VERSION;\n", target=STAGING),
               tab("Unshipped orders", PRODUCTION, target=PRODUCTION_SSH)],
         selected=2, frame="1200x680", settings={**DOCKER_SETTINGS, "tabLayout": "vertical", "verticalTabsWidth": 220},
         seed=lambda data, sandbox: fixture_targets(data), env={"RUNLET_DEBUG_HOME": "{data}"},
         steps=["run", "wait-run:90", "wait", "segment:Table", "wait"]),
    # MCP (mcp.md): the approval sheet for a made-up client; no `runlet mcp` process, and Cancel only.
    Shot("mcp", "approval-sheet", about="Run code from Claude Code on production? (a made-up client, never answered)",
         tabs=[tab("Scratch", "use App\\Models\\User;\n\nUser::count();\n")], targets=PRODUCTION_TARGETS, frame="1200x720",
         steps=[f"mcp-ask:Claude Code|shop|{MCP_CODE}", "wait", "wait", "mcp-state"]),
    # Run notifications: notifications off, as Debug builds' logging notifier reports it.
    Shot("run-notifications", "notifications-off", about="Settings ▸ General ▸ Notifications, off for Runlet",
         tabs=[tab("Scratch", "")], window="General", settings={"notifyLongRuns": True, "longRunNotificationSeconds": 10},
         steps=["notifications:denied", "settings", "wait", "settings-tab:General", "wait", "frame:General=600x1000", "wait"],
         crop=(0, 462, 600, 262)),
    # Benchmarks: Profile Run needs Excimer, which the fixture's `profiler` container has.
    Shot("benchmarks", "profile-run", needs="profiler", about="Profile Run's flame graph and hottest functions",
         tabs=[tab("Profile", PROFILE, target=DOCKER_TARGET)], frame="1200x640", settings=DOCKER_SETTINGS,
         seed=lambda data, sandbox: fixture_targets(data, service="profiler", project=False),
         steps=["perform:run.profile", "wait-run:120", "wait", "section:Profile", "wait", "wait"]),
]

# MARK: Fixtures a shot can need


def sandbox_ready() -> str | None:
    if not (SANDBOX_TEMPLATE / "vendor" / "autoload.php").is_file():
        return "the sandbox has no vendor/ (run scripts/build-sandbox.sh)"
    return None


NEEDS: dict[str, Callable[[], str | None]] = {
    "sandbox": sandbox_ready,
    "redis": fixture("redis", "scripts/setup-fixtures.sh databases", 6379, "redis-port"),
    "mongo": fixture("mongo", "scripts/setup-fixtures.sh databases", 27017, "mongo-port"),
    "postgres": fixture("postgres", "scripts/setup-fixtures.sh databases", 5432, "pg-port"),
    "ssh": ssh_ready,
    "docker": fixture("laravel", "scripts/setup-fixtures.sh docker"),
    "profiler": fixture("profiler", "docker compose -p runlet-fixtures -f Tests/Fixtures/docker/compose.yml up -d profiler"),
}

# MARK: Running


def log(message: str) -> None:
    print(message, flush=True)


def build_app() -> Path:
    log("== Building Runlet (Debug, bundle id %s)" % BUNDLE_ID)
    subprocess.run(["xcodebuild", "-quiet", "-project", str(ROOT / "Runlet.xcodeproj"), "-scheme", "Runlet",
                    "-configuration", "Debug", "-derivedDataPath", str(ROOT / "build" / "DerivedData"),
                    f"PRODUCT_BUNDLE_IDENTIFIER={BUNDLE_ID}", "build"], check=True)
    return ROOT / "build" / "DerivedData" / "Build" / "Products" / "Debug" / "Runlet.app"


def write_state(data: Path, name: str, value) -> None:
    state = data / "State"
    state.mkdir(parents=True, exist_ok=True)
    (state / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": NOW, "data": value}, indent=1))


def launch(app: Path, data: Path, steps: list[str], snapshots: Path, log_path: Path, env: dict | None = None,
           fixture_ssh: bool = False, settings_tab: int = 0) -> str:
    """Runs the app hidden with these steps until it quits; returns its stderr. ssh is a fake
    with an empty config, or with `fixture_ssh`, the real one with the config that sends the
    example.com names to the fixture SSH host (seed_ssh)."""
    ssh_config = WORK / "ssh-config"
    if not ssh_config.exists():
        ssh_config.write_text("")
    if fixture_ssh:
        ssh_config = SSH_DIR / "config"
    log_path.write_text("")
    extra = [part for name, value in (env or {}).items() for part in ["--env", f"{name}={value}"]]
    arguments = list(LAUNCH_ARGUMENTS)
    arguments[SETTINGS_TAB] = str(settings_tab)
    # TZ=UTC, as the sandbox's Laravel logs: the Logs window matches a run's entries by their
    # time, and no picture shows this Mac's time zone.
    command = ["open", "-g", "-j", "-n", "-W",
               "--env", f"RUNLET_DATA_DIR={data}", "--env", f"RUNLET_SNAPSHOT_DIR={snapshots}",
               "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "RUNLET_CREDENTIALS=memory",
               "--env", f"RUNLET_SSH_CONFIG={ssh_config}", "--env", f"RUNLET_SSH_EXECUTABLE={'/usr/bin/ssh' if fixture_ssh else FAKE_SSH}",
               "--env", "SSH_AUTH_SOCK=", "--env", "TZ=UTC"] + extra + ["--stderr", str(log_path), str(app), "--args"] + arguments
    with subprocess.Popen(command) as process:
        check_window_manager(process)
        if process.wait(timeout=900) != 0:
            raise RuntimeError(f"open failed with status {process.returncode}")
    text = log_path.read_text()
    if "RUNLET_DEBUG_STEPS: done" not in text:
        raise RuntimeError(f"the app quit early; see {log_path}")
    return text


AEROSPACE_RULE = (f'[[on-window-detected]]\nif.app-id = "{BUNDLE_ID}"\n'
                  "run = ['layout floating', 'move-node-to-workspace 1']  # a workspace on a Retina display")
_window_manager_checked = threading.Lock()


def check_window_manager(process: subprocess.Popen) -> None:
    """Once per run, while the first instance is open: warns when AeroSpace tiles its windows.
    AeroSpace resizes a tiled window, and keeps every window on its workspace's display, so the
    `shot` step can't keep it at the shot's size on a Retina screen and fails."""
    if shutil.which("aerospace") is None or not _window_manager_checked.acquire(blocking=False):
        return
    deadline = time.time() + 20
    while time.time() < deadline and process.poll() is None:
        listing = subprocess.run(["aerospace", "list-windows", "--all", "--format", "%{app-bundle-id}|%{window-layout}"],
                                 capture_output=True, text=True).stdout
        # AeroSpace lists the windows as a hidden app's until the `ghost` step shows them.
        layouts = {line.split("|", 1)[1] for line in listing.splitlines() if line.startswith(BUNDLE_ID + "|")} - {"macos_native_window_of_hidden_app"}
        if layouts:
            if layouts != {"floating"}:
                log(f"! AeroSpace tiles {BUNDLE_ID}'s windows ({', '.join(sorted(layouts))}), so shots can fail or come out"
                    f" at the wrong size. Add this to ~/.aerospace.toml and run `aerospace reload-config`:\n{AEROSPACE_RULE}")
            return
        time.sleep(0.5)


def sandbox_dir(data: Path) -> Path:
    found = sorted((data / "Sandbox").glob("laravel-*"))
    return found[0] if found else data / "Sandbox" / "missing"


def prepare_base(app: Path) -> Path:
    """A data folder with the sandbox installed by the app, and three neutral users."""
    base = WORK / "base"
    if (sandbox_dir(base) / ".runlet-installed").is_file():
        return base
    log("== Installing the sandbox into scratch data")
    shutil.rmtree(base, ignore_errors=True)
    write_state(base, "settings", BASE_SETTINGS)
    write_state(base, "session", {"windows": [{"id": uid(), "tabs": [tab("Setup", "User::count();\n")], "workspaceEdited": False}]})
    launch(app, base, ["ghost", "run", "wait-run:120"], WORK / "raw", WORK / "base.log")
    sandbox = sandbox_dir(base)
    if not (sandbox / ".runlet-installed").is_file():
        raise RuntimeError(f"the sandbox wasn't installed; see {WORK / 'base.log'}")
    database = sqlite3.connect(sandbox / "database" / "database.sqlite")
    database.executemany("INSERT INTO users (name, email, password, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                         [(name, email, "not-a-password-hash", f"2026-10-0{day} 09:00:00", f"2026-10-0{day} 09:00:00")
                          for day, (name, email) in enumerate(USERS, 1)])
    database.commit()
    database.close()
    # Nothing of the setup run: no history, no session.
    for leftover in ["history.json", "session.json"]:
        (base / "State" / leftover).unlink(missing_ok=True)
    return base


def convert(png: Path, webp: Path, scale: float, crop: tuple[int, int, int, int] | None) -> None:
    webp.parent.mkdir(parents=True, exist_ok=True)
    width = int(subprocess.run(["sips", "-g", "pixelWidth", str(png)], capture_output=True, text=True, check=True).stdout.split()[-1])
    command = ["cwebp", "-quiet", "-q", str(QUALITY), "-m", "6", "-sharp_yuv", "-metadata", "none"]
    if crop:
        x, y, w, h = (int(round(value * scale)) for value in crop)
        command += ["-crop", str(x), str(y), str(w), str(h)]
        width = w
    if width > WIDTH:
        command += ["-resize", str(WIDTH), "0"]
    subprocess.run(command + [str(png), "-o", str(webp)], check=True)


def take(app: Path, base: Path, shot: Shot) -> list[Path]:
    slug = shot.id.replace("/", "--")
    data = WORK / "data" / slug
    raw = WORK / "raw"
    raw.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(data, ignore_errors=True)
    data.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cp", "-cR", str(base), str(data)], check=True)
    write_state(data, "settings", {**BASE_SETTINGS, **shot.settings})
    write_state(data, "session", {"windows": [{"id": uid(), "tabs": shot.tabs, "selectedTabId": shot.tabs[shot.selected]["id"], "workspaceEdited": False}]})
    if shot.targets is not None:
        write_state(data, "targets", shot.targets)
    if shot.history is not None:
        write_state(data, "history", shot.history)
    if shot.snippets is not None:
        write_state(data, "snippets", shot.snippets)
    if shot.seed:
        shot.seed(data, sandbox_dir(data))
    window = f"@{shot.window}" if shot.window else ""
    # `{project}` in a step is the shot's local project "shop" (see shop_project), and
    # `{redis-port}` and the like a fixture's port (FIXTURE).
    values = {"project": str(data / "projects" / "shop"), "data": str(data), **FIXTURE}

    def filled(text: str) -> str:
        for key, value in values.items():
            text = text.replace("{" + key + "}", value)
        return text

    steps = [filled(step) for step in shot.steps]
    steps = (["ghost", "scale:2", f"frame:{shot.frame}", "appearance:light", "wait"] + steps
             + [f"shot:{slug}-light{window}", "appearance:dark", "wait"] + shot.dark_steps + ["wait", f"shot:{slug}-dark{window}"])
    for appearance in ["light", "dark"]:
        (raw / f"{slug}-{appearance}.png").unlink(missing_ok=True)
    fixture_ssh = "ssh" in shot.needs.split("+")
    background = shot.background() if shot.background else None
    try:
        text = launch(app, data, steps, raw, WORK / "logs" / f"{slug}.log", {name: filled(value) for name, value in shot.env.items()}, fixture_ssh, shot.settings_tab)
    finally:
        if background:
            background.kill()
            background.wait()
    # Now and then a run doesn't start in a busy instance; the retry takes the shot again.
    if "RUNLET_DEBUG_TIMING: status=- " in text:
        raise RuntimeError(f"{shot.id}: the run didn't start; see {WORK / 'logs' / (slug + '.log')}")
    for line in text.splitlines():
        if line.startswith("RUNLET_DEBUG_STATE:") and any(problem in line for problem in ["not found", "unavailable", "failed", "no window", "blurry"]):
            log(f"   ! {shot.id}: {line.removeprefix('RUNLET_DEBUG_STATE: ')}")
        # A shot is drawn while Runlet stays in the background; if it became the active app,
        # something took the keyboard from you, and the picture shows an active window.
        if line.startswith("RUNLET_DEBUG_STATE: shot ") and " active=true" in line:
            raise RuntimeError(f"{shot.id}: Runlet became the active app; see {WORK / 'logs' / (slug + '.log')}")
    written = []
    for appearance in ["light", "dark"]:
        png = raw / f"{slug}-{appearance}.png"
        if not png.is_file():
            raise RuntimeError(f"{shot.id}: no {appearance} picture; see {WORK / 'logs' / (slug + '.log')}")
        webp = DOCS / shot.page / f"{shot.name}-{appearance}.webp"
        convert(png, webp, 2, shot.crop)
        written.append(webp)
    return written


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("shots", nargs="*", help="shot ids (page/name), names, or pages; all by default")
    parser.add_argument("--list", action="store_true", help="list the shots and exit")
    parser.add_argument("--app", type=Path, help="a built Runlet.app (Debug, prshots bundle id); built when left out")
    parser.add_argument("--keep", action="store_true", help="keep build/docs-shots/data and raw/ afterwards")
    parser.add_argument("--jobs", type=int, default=min(6, max(1, (os.cpu_count() or 2) // 2)),
                        help="shots taken at once, each by its own hidden instance (default: half the CPUs, at most 6; 1 for one at a time)")
    args = parser.parse_args()

    ids = [shot.id for shot in SHOTS]
    duplicates = {i for i in ids if ids.count(i) > 1}
    if duplicates:
        raise SystemExit(f"duplicate shot ids: {sorted(duplicates)}")
    if args.list:
        # "missing": the pair isn't in docs/screenshots/ yet.
        for shot in SHOTS:
            taken = all((DOCS / shot.page / f"{shot.name}-{appearance}.webp").is_file() for appearance in ["light", "dark"])
            print(f"{shot.id:45} {shot.needs:13} {'' if taken else 'missing':8} {shot.about}")
        return 0
    chosen = [shot for shot in SHOTS if not args.shots or any(key in (shot.id, shot.name, shot.page) for key in args.shots)]
    if not chosen:
        raise SystemExit(f"no shot matches {args.shots}; see --list")
    if shutil.which("cwebp") is None:
        raise SystemExit("cwebp is missing (brew install webp)")
    # A shot needs the sandbox and its fixtures ("ssh+postgres"); each fixture is checked once.
    needed = sorted({need for shot in chosen for need in ["sandbox", *shot.needs.split("+")]})
    missing = {need: problem for need in needed for problem in [NEEDS[need]() if need in NEEDS else f"unknown fixture {need}"] if problem}
    runnable = [shot for shot in chosen if not missing.keys() & {"sandbox", *shot.needs.split("+")}]
    for need, problem in missing.items():
        log(f"Skipping the shots that need {need}: {problem}")
    if not runnable:
        return 1

    app = args.app.resolve() if args.app else build_app()
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / "logs").mkdir(exist_ok=True)
    base = prepare_base(app)
    # Seeds the fixtures' docs data (and the SSH key) once; cleaned up however the run ends.
    used = sorted({need for shot in runnable for need in shot.needs.split("+") if need in PREPARE})
    cleanups = []
    try:
        for need in used:
            log(f"== Preparing the {need} fixture")
            seed, clean = PREPARE[need]
            cleanups.append(clean)
            seed()
        return take_all(app, base, runnable, args)
    finally:
        for clean in cleanups:
            clean()


def take_all(app: Path, base: Path, runnable: list[Shot], args: argparse.Namespace) -> int:
    started = time.time()

    def attempt(shot: Shot) -> str | None:
        """Takes one shot; returns why it failed, or None."""
        began = time.time()
        try:
            paths = take(app, base, shot)
        except (RuntimeError, subprocess.SubprocessError, OSError) as error:
            log(f"   {shot.id}: failed ({error})")
            return str(error)
        sizes = ", ".join(f"{path.name} {path.stat().st_size // 1024} KB" for path in paths)
        log(f"   {shot.id}: {sizes} ({time.time() - began:.0f} s)")
        return None

    # Every shot has its own data folder (a clone of the base), so instances don't share files.
    jobs = max(1, min(args.jobs, len(runnable)))
    log(f"== {len(runnable)} shot{'s' if len(runnable) != 1 else ''}, {jobs} at a time")
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        results = list(pool.map(attempt, runnable))
    failed = [shot for shot, error in zip(runnable, results) if error]
    if failed:
        log(f"== Retrying {len(failed)} failed shot{'s' if len(failed) != 1 else ''}, one at a time")
        failed = [shot for shot in failed if attempt(shot)]
    log(f"== {time.time() - started:.0f} s for {len(runnable)} shots")
    if not args.keep:
        shutil.rmtree(WORK / "data", ignore_errors=True)
        shutil.rmtree(WORK / "raw", ignore_errors=True)
    if failed:
        log("Failed: " + ", ".join(shot.id for shot in failed) + f" (logs in {(WORK / 'logs').relative_to(ROOT)})")
        return 1
    log("Done. Look at every image before committing it: no names, paths, hosts, or containers of your own.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

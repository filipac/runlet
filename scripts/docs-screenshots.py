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
bundled Laravel sandbox, nothing else) or a fixture from NEEDS. The script builds the app with
the prshots bundle id, launches it hidden in the background (`open -g -j`, then the `ghost`
step) once per shot, takes the picture in light, switches the app's appearance, takes it in
dark, and converts both with cwebp into docs/screenshots/<page>/<name>-light.webp and
-dark.webp, at most 1600 pixels wide.

Scratch data lives in build/docs-shots/: a base data folder with the sandbox installed and
seeded with neutral users once, then a fresh clone of it for every shot. The script never reads
or writes ~/Library/Application Support/Runlet, the Keychain, or ~/.ssh, and never connects to
a server: the one SSH profile (a production target, for the confirmation sheet and the mail
chip) is never run, and ssh is a fake (Tests/Fixtures/fake-ssh/ssh) with an empty config.

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
    #: "sandbox", or a fixture in NEEDS (#304 adds them).
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

# MARK: Fixtures a shot can need (#304 adds Redis, MongoDB, PostgreSQL, Docker, and SSH)


def sandbox_ready() -> str | None:
    if not (SANDBOX_TEMPLATE / "vendor" / "autoload.php").is_file():
        return "the sandbox has no vendor/ (run scripts/build-sandbox.sh)"
    return None


NEEDS: dict[str, Callable[[], str | None]] = {
    "sandbox": sandbox_ready,
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


def launch(app: Path, data: Path, steps: list[str], snapshots: Path, log_path: Path) -> str:
    """Runs the app hidden with these steps until it quits; returns its stderr."""
    ssh_config = WORK / "ssh-config"
    if not ssh_config.exists():
        ssh_config.write_text("")
    log_path.write_text("")
    # TZ=UTC, as the sandbox's Laravel logs: the Logs window matches a run's entries by their
    # time, and no picture shows this Mac's time zone.
    command = ["open", "-g", "-j", "-n", "-W",
               "--env", f"RUNLET_DATA_DIR={data}", "--env", f"RUNLET_SNAPSHOT_DIR={snapshots}",
               "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", "RUNLET_CREDENTIALS=memory",
               "--env", f"RUNLET_SSH_CONFIG={ssh_config}", "--env", f"RUNLET_SSH_EXECUTABLE={FAKE_SSH}",
               "--env", "SSH_AUTH_SOCK=", "--env", "TZ=UTC", "--stderr", str(log_path), str(app), "--args"] + LAUNCH_ARGUMENTS
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
    # `{project}` in a step is the shot's local project "shop" (see shop_project).
    steps = [step.replace("{project}", str(data / "projects" / "shop")) for step in shot.steps]
    steps = (["ghost", "scale:2", f"frame:{shot.frame}", "appearance:light", "wait"] + steps
             + [f"shot:{slug}-light{window}", "appearance:dark", "wait"] + shot.dark_steps + ["wait", f"shot:{slug}-dark{window}"])
    for appearance in ["light", "dark"]:
        (raw / f"{slug}-{appearance}.png").unlink(missing_ok=True)
    text = launch(app, data, steps, raw, WORK / "logs" / f"{slug}.log")
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
            print(f"{shot.id:45} {shot.needs:10} {'' if taken else 'missing':8} {shot.about}")
        return 0
    chosen = [shot for shot in SHOTS if not args.shots or any(key in (shot.id, shot.name, shot.page) for key in args.shots)]
    if not chosen:
        raise SystemExit(f"no shot matches {args.shots}; see --list")
    if shutil.which("cwebp") is None:
        raise SystemExit("cwebp is missing (brew install webp)")
    missing = {need: problem for need in {shot.needs for shot in chosen}
               for problem in [NEEDS[need]() if need in NEEDS else f"unknown fixture {need}"] if problem}
    runnable = [shot for shot in chosen if shot.needs not in missing]
    for need, problem in missing.items():
        log(f"Skipping the {need} shots: {problem}")
    if not runnable:
        return 1

    app = args.app.resolve() if args.app else build_app()
    WORK.mkdir(parents=True, exist_ok=True)
    (WORK / "logs").mkdir(exist_ok=True)
    base = prepare_base(app)
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

#!/usr/bin/env python3
"""#320: the inspector panes keep their scroll position when something else in the window changes.

Usage: inspector-scroll-check.py /path/to/Runlet.app [history|snippets|commands|database ...] [--local] [--strict]

Runs a Debug app in the background (`ghost`), with scratch data under build/ of this checkout
and the sandbox only: a window with two sandbox tabs (with `--local`, on a local project "shop",
a copy of the sandbox in the scratch data), 150 history entries, and 60 snippets. For
each pane it fills a long list (the sandbox's Artisan commands; the sandbox's tables with their
columns expanded), scrolls it to the middle, and watches it (`inspector-scroll-watch`) while:

- a 5-second snippet runs in the selected tab (`sleep(5)`);
- a row is clicked, on its middle and on its text, and the pane's header is clicked;
- the output pane is hidden and shown again (a setting the pane doesn't show);
- the window switches to the other tab (on the same target) and back;
- (Commands) a listed command runs in a terminal tab, as its ▶ button does (`command:about`).

After each step it prints the list's offset from the top (`y`), its document height, and how
often they changed in between, even for a moment (`offsetChanges`, `heightChanges`, with the
ranges they went through), how often the list itself was resized (`frameChanges`), what AppKit did
to the list's table and scroller (`appKit`), and which pane and row views SwiftUI evaluated again
(`renders`). With `--strict`, it fails unless the offset, the heights, and the frame stayed
constant and no row was drawn again, except where the pane's own rows change (the History pane
gains the run's entry when it ends).
"""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "build" / "inspector-scroll-check"
FAKE_SSH = ROOT / "Tests" / "Fixtures" / "fake-ssh" / "ssh"
FAKE_DOCKER = ROOT / "Tests" / "Fixtures" / "fake-docker" / "docker"
NOW = time.time() - 978307200  # Foundation's reference date, as the state files store dates
SANDBOX = {"sandbox": {}}
SHOP_ID = "5A0B7C1E-0D0C-4E55-9A6B-3D2C1B0A9F32"
SHOP = {"local": {"_0": SHOP_ID}}
TARGET = SANDBOX
LAUNCH_ARGUMENTS = ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
SETTINGS = {
    "appearance": "light", "fontSize": 13, "showTipsOnFirstLaunch": False, "showWhatsNewAfterUpdates": False,
    "automaticUpdateChecks": False, "languageServiceEnabled": False, "notifyLongRuns": False,
    "dockerExecutable": str(FAKE_DOCKER), "libraryPanelWidth": 340,
}
PANES = ["history", "snippets", "commands", "database"]
DRIVER = """<?php

use Runlet\\Drivers\\LaravelDriver;

class ShopDriver extends LaravelDriver
{
    public function name(): string
    {
        return 'Shop';
    }

    public function variables(): array
    {
        return parent::variables() + ['tenant' => 'acme', 'region' => 'eu-west', 'currency' => 'EUR'];
    }

    public function hostCommands(): array
    {
        return ['status' => ['command' => 'git status', 'description' => 'Show the working tree status'], 'tool' => ['list' => 'echo not json; exit 3']];
    }
}
"""


def uid() -> str:
    return str(uuid.uuid4()).upper()


def tab(title: str, code: str) -> dict:
    return {"id": uid(), "title": title, "code": code, "target": TARGET,
            "selection": {"location": len(code), "length": 0}, "createdAt": NOW - 600}


def history() -> list[dict]:
    entries = []
    for n in range(150):
        lines = ["$users = User::query()", f"    ->where('id', '>', {n})", "    ->limit(5)->get();"][: 1 + n % 3]
        status = ["completed", "completed", "failed", "completed", "cancelled"][n % 5]
        entries.append({"id": uid(), "runId": uid(), "timestamp": NOW - 60 * (n + 1), "code": "\n".join(lines) + "\n",
                        "target": TARGET, "targetLabel": "Laravel Sandbox" if TARGET == SANDBOX else "shop", "status": status,
                        "reason": {"completed": "completed", "failed": "error", "cancelled": "cancelled"}[status],
                        "elapsedMs": 100 + n, "targetEnvironment": "development"})
    return entries


def snippets() -> list[dict]:
    items = []
    for n in range(60):
        item = {"id": uid(), "label": f"Snippet {n + 1:02d}", "code": f"collect(range(1, {n + 2}))->sum();\n// line two\n",
                "createdAt": NOW - 3600 * (n + 1), "updatedAt": NOW - 3600 * (n + 1)}
        if n % 3 == 0:
            item["description"] = "Adds the numbers up. " * (1 + n % 4)
        if n % 4 == 1:
            item["target"] = TARGET
            item["targetLabel"] = "Laravel Sandbox" if TARGET == SANDBOX else "shop"
        items.append(item)
    return items


def write_state(data: Path, name: str, value) -> None:
    state = data / "State"
    state.mkdir(parents=True, exist_ok=True)
    (state / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": NOW, "data": value}, indent=1))


def launch(app: Path, data: Path, steps: list[str], log_path: Path) -> str:
    ssh_config = WORK / "ssh-config"
    ssh_config.write_text("")
    log_path.write_text("")
    command = ["open", "-g", "-j", "-n", "-W",
               "--env", f"RUNLET_DATA_DIR={data}", "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}",
               "--env", "RUNLET_CREDENTIALS=memory", "--env", f"RUNLET_SSH_CONFIG={ssh_config}",
               "--env", f"RUNLET_SSH_EXECUTABLE={FAKE_SSH}", "--env", "SSH_AUTH_SOCK=",
               "--stderr", str(log_path), str(app), "--args"] + LAUNCH_ARGUMENTS
    subprocess.run(command, check=True, timeout=600)
    text = log_path.read_text()
    if "RUNLET_DEBUG_STEPS: done" not in text:
        raise RuntimeError(f"the app quit early; see {log_path}")
    return text


def base(app: Path) -> Path:
    """Scratch data with the sandbox installed by the app (one run), without its history."""
    data = WORK / "base"
    if any((data / "Sandbox").glob("laravel-*/.runlet-installed")):
        return data
    shutil.rmtree(data, ignore_errors=True)
    write_state(data, "settings", SETTINGS)
    write_state(data, "session", {"windows": [{"id": uid(), "tabs": [tab("Setup", "1 + 1;\n")], "workspaceEdited": False}]})
    launch(app, data, ["ghost", "run", "wait-run:120"], WORK / "base.log")
    if not any((data / "Sandbox").glob("laravel-*/.runlet-installed")):
        raise RuntimeError(f"the sandbox wasn't installed; see {WORK / 'base.log'}")
    for leftover in ["history.json", "session.json"]:
        (data / "State" / leftover).unlink(missing_ok=True)
    return data


def steps_for(pane: str) -> list[str]:
    def state(label: str) -> str:
        return f"inspector-scroll-state:{label}"
    fill = {
        "history": [],
        "snippets": [],
        "commands": ["inspector-wait:90"],
        "database": ["sql-schema:load", "wait", "wait"] + [f"schema-expand:{table}" for table in
                     ["cache", "cache_locks", "failed_jobs", "job_batches", "jobs", "migrations", "password_reset_tokens", "sessions", "users"]],
    }[pane]
    steps = ["ghost", "frame:1100x720", f"inspector:{pane}", "wait"] + fill + ["inspector-wait:30", "inspector-scroll:middle", "wait",
             "inspector-scroll-watch", "wait", state("idle")]
    # A 5-second run in the selected tab.
    steps += ["run", state("run-started"), state("running"), "wait-run:30", state("run-ended"), "wait", state("after-run")]
    # Clicks in the pane: a row's middle, a row's text, the header above the list.
    steps += ["inspector-click:row", "wait", state("click-row"), "inspector-click:row-text", "wait", state("click-row-text"),
              "inspector-click:above:10", "wait", state("click-header")]
    # A setting the pane doesn't show: the output pane hidden and shown again (Show/Hide Output Pane).
    steps += ["perform:output.toggle", "wait", state("output-hidden"), "perform:output.toggle", "wait", state("output-shown")]
    # Another tab on the same target, and back.
    steps += ["select:Other", "wait", state("tab-other"), "select:Scratch", "wait", state("tab-back")]
    if pane == "commands":
        # A command in a terminal tab, as its ▶ button runs it.
        steps += ["command:about", state("command-started"), "wait", "wait", state("command-ended")]
    # The selected row half hidden under the list's bottom edge, then the same changes again.
    if pane != "database":
        steps += ["inspector-scroll:selected-bottom", "wait", state("edge"), "run", state("edge-run-started"), "wait-run:30",
                  state("edge-run-ended"), "select:Other", "wait", state("edge-tab-other"), "select:Scratch", "wait", state("edge-tab-back"),
                  "inspector-click:above:10", "wait", state("edge-click-header")]
    return steps


def parse(text: str) -> list[dict]:
    rows = []
    for line in text.splitlines():
        match = re.search(r"RUNLET_DEBUG_STATE: inspector-scroll-state (\S+): (.*)", line)
        if match:
            fields = dict(re.findall(r"(\w+)=(\S+)", match.group(2)))
            fields["label"] = match.group(1)
            rows.append(fields)
    return rows


# Steps after which the pane's own rows may have changed: the History pane gains the run's entry,
# and `edge` is the list scrolled by the check itself (it draws rows it hadn't shown).
ROWS_CHANGE = {"history": {"run-ended", "after-run", "edge-run-ended"}}
SCROLLED = {"edge"}
COLUMNS = ["label", "y", "height", "visible", "rows", "selected", "responder", "offsetChanges", "heightChanges", "yRange", "heightRange", "frameChanges",
           "scrollViewSame", "documentSame", "appKit", "renders"]


def check(app: Path, pane: str, strict: bool) -> bool:
    data = WORK / f"data-{pane}{'-local' if TARGET == SHOP else ''}"
    shutil.rmtree(data, ignore_errors=True)
    subprocess.run(["cp", "-cR", str(base(app)), str(data)], check=True)
    tabs = [tab("Scratch", "sleep(5);\n'done';\n"), tab("Other", "now();\n")]
    write_state(data, "settings", SETTINGS)
    write_state(data, "session", {"windows": [{"id": uid(), "tabs": tabs, "selectedTabId": tabs[0]["id"], "workspaceEdited": False}]})
    write_state(data, "history", history())
    write_state(data, "snippets", snippets())
    if TARGET == SHOP:
        project = data / "projects" / "shop"
        project.parent.mkdir(parents=True, exist_ok=True)
        sandbox = sorted((data / "Sandbox").glob("laravel-*"))[0]
        subprocess.run(["cp", "-cR", str(sandbox), str(project)], check=True)
        (project / ".runlet-installed").unlink(missing_ok=True)
        # A project driver with variables and host commands, as projects with their own driver have.
        (project / ".runlet").mkdir(exist_ok=True)
        (project / ".runlet" / "ShopDriver.php").write_text(DRIVER)
        write_state(data, "targets", {"localProjects": [{"id": SHOP_ID, "name": "shop", "path": str(project), "revision": 1,
                                                          "lastOpenedAt": NOW - 60}], "dockerProfiles": [], "sshProfiles": []})
    text = launch(app, data, steps_for(pane), WORK / f"{pane}{'-local' if TARGET == SHOP else ''}.log")
    for line in text.splitlines():
        if "RUNLET_DEBUG_STATE: inspector-" in line and "inspector-scroll-state" not in line:
            print("  " + line.split("RUNLET_DEBUG_STATE: ", 1)[1])
    rows = parse(text)
    print(f"--- {pane}")
    widths = {column: max(len(column), *(len(row.get(column, "")) for row in rows)) for column in COLUMNS}
    print("  ".join(column.ljust(widths[column]) for column in COLUMNS))
    for row in rows:
        print("  ".join(row.get(column, "").ljust(widths[column]) for column in COLUMNS))
    stable = True
    for row in rows:
        if row["label"] in ROWS_CHANGE.get(pane, set()) | SCROLLED:
            continue
        redrawn = [key for key in re.findall(r"([\w-]+-row):\d+", row.get("renders", ""))]
        if any(row.get(key) != "0" for key in ["offsetChanges", "heightChanges", "frameChanges"]) or row.get("scrollViewSame") != "yes" or redrawn:
            print(f"  {row['label']}: moved or redrew rows ({', '.join(redrawn) or 'no rows'})")
            stable = False
    if not rows:
        stable = False
        print(f"  no list; see {WORK / (pane + '.log')}")
    print(f"  {pane}: {'stable' if stable else 'MOVED'}")
    return stable or not strict


def main() -> None:
    app = Path(sys.argv[1]).resolve()
    panes = [arg for arg in sys.argv[2:] if arg in PANES] or PANES
    strict = "--strict" in sys.argv
    global TARGET
    if "--local" in sys.argv:
        TARGET = SHOP
    WORK.mkdir(parents=True, exist_ok=True)
    results = [check(app, pane, strict) for pane in panes]
    if not all(results):
        sys.exit(1)


if __name__ == "__main__":
    main()

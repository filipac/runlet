#!/usr/bin/env python3
"""#8: source excerpts in error cards, from a Debug app with scratch data.

Copies the `laravel-app` fixture twice under /private/tmp: `shop` (a local project, and the SSH
profile's local folder) and `server/shop` (the SSH profile's directory, which the fake ssh client
runs in on this Mac). Both get `app/Services/InvoiceTotals.php`, which throws from a collection
callback. Runs only the fixture copies: a local project, and an SSH profile on a made-up host
through `Tests/Fixtures/fake-ssh/ssh` with an empty `RUNLET_SSH_CONFIG`, so nothing reads ~/.ssh
or reaches a server. Project lines would open in a custom editor command that does nothing.
Prints the RUNLET_DEBUG_STATE lines.
Usage: source-excerpt-screenshots.py /path/to/Runlet.app /path/to/output
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
fixture = root / "Tests/Fixtures/laravel-app"
fake_ssh = root / "Tests/Fixtures/fake-ssh/ssh"
assert (fixture / "vendor/autoload.php").is_file(), "run scripts/setup-fixtures.sh"
php = shutil.which("php")
assert php, "needs PHP on PATH"

INVOICE_TOTALS = """<?php

namespace App\\Services;

use DomainException;

class InvoiceTotals
{
    /**
     * The invoice's total, in cents.
     */
    public function sum(array $lines): int
    {
        return collect($lines)
            ->map(fn (int $cents) => $this->checked($cents))
            ->sum();
    }

    private function checked(int $cents): int
    {
        if ($cents < 0) {
            throw new DomainException("Invoice line is negative: {$cents} cents");
        }

        return $cents;
    }
}
"""

INVOICE = """use App\\Services\\InvoiceTotals;

$lines = [1999, 2500, -300];

$totals = new InvoiceTotals();
$totals->sum($lines);
"""

GENERATED = """// A compiled file that is gone by the time the error card shows.
$path = storage_path('framework/cache/report-template.php');
file_put_contents($path, "<?php\\n\\nfunction report_template(): array\\n{\\n    throw new LogicException('The report template changed');\\n}\\n");
require $path;
unlink($path);

report_template();
"""

now = time.time() - 978307200  # Foundation's reference date


def arr_map_line():
    """The line of Laravel's Arr::map that calls array_map, the vendor frame's line."""
    arr = fixture / "vendor/laravel/framework/src/Illuminate/Collections/Arr.php"
    lines = arr.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if "public static function map(" in line)
    return next(i + 1 for i in range(start, len(lines)) if "array_map($callback" in lines[i])


def launch(name, tabs, steps, shots):
    with tempfile.TemporaryDirectory(prefix="runlet-excerpts-", dir="/private/tmp") as scratch:
        scratch = Path(scratch)
        shop = scratch / "shop"
        server = scratch / "server/shop"
        server.parent.mkdir()
        for copy in (shop, server):
            subprocess.run(["cp", "-cR", str(fixture), str(copy)], check=True)
            (copy / "app/Services").mkdir(exist_ok=True)
            (copy / "app/Services/InvoiceTotals.php").write_text(INVOICE_TOTALS)
        (scratch / "bin").mkdir()
        (scratch / "bin/php").symlink_to(php)
        (scratch / "ssh_config").write_text("# empty: the fake ssh client runs commands on this Mac\n")
        state = scratch / "State"
        state.mkdir()

        def save(file, data):
            (state / f"{file}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": now, "data": data}))

        local_id, ssh_id = str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()
        # A custom editor command, so project lines would open in it (it does nothing).
        save("settings", {"appearance": "light", "fontSize": 13, "externalEditor": "custom", "externalEditorCommand": "/usr/bin/true {file}:{line}"})
        save("targets", {
            "localProjects": [{"id": local_id, "name": "shop", "path": str(shop), "revision": 1, "lastOpenedAt": now - 60}],
            "dockerProfiles": [],
            "sshProfiles": [{
                "id": ssh_id, "name": "shop-staging", "host": "staging.example.com", "user": "forge", "remoteDirectory": str(server),
                "phpExecutable": str(scratch / "bin/php"), "authentication": "automatic", "keepAliveMinutes": 10, "compression": True,
                "localSourcePath": str(shop), "environment": "development", "checkDrift": False, "revision": 1, "lastOpenedAt": now - 120,
            }],
        })
        targets = {"local": {"local": {"_0": local_id}}, "ssh": {"ssh": {"_0": ssh_id}}}
        save("session", {"tabs": [{"id": str(uuid.uuid4()).upper(), "title": title, "code": code, "target": targets[kind],
                                   "selection": {"location": 0, "length": 0}, "createdAt": now} for title, kind, code in tabs]})
        log_path = out / f"{name}.log"
        log_path.write_text("")
        subprocess.run(["open", "-g", "-j", "-n", "-W", "--env", f"RUNLET_DATA_DIR={scratch}",
                        "--env", f"RUNLET_SNAPSHOT_DIR={out}", "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}",
                        "--env", f"RUNLET_SSH_EXECUTABLE={fake_ssh}", "--env", f"RUNLET_SSH_CONFIG={scratch / 'ssh_config'}",
                        "--env", "SSH_AUTH_SOCK=", "--stderr", str(log_path), str(app)], check=True)
        log = log_path.read_text()
        assert "RUNLET_DEBUG_STEPS: done" in log, log[-2000:]
        for line in log.splitlines():
            if line.startswith("RUNLET_DEBUG_STATE") or line.startswith("  ") or line.startswith("RUNLET_DEBUG_TIMING"):
                print(line)
        for shot in shots:
            assert (out / f"{shot}.png").is_file(), shot


start = ["ghost", "scale:2", "frame:1180x900"]
vendor_line = arr_map_line()

# 1. A local project: the card shows where it was thrown; the trace opens its first project
#    frame; the vendor frame and the snippet's own frame open by hand; dark mode; a vendor line
#    in the read-only peek.
launch("local", [("Invoice", "local", INVOICE)], start + [
    "appearance:light", "select:Invoice", "run", "wait-run:120", "wait", "excerpt-state", "shot:excerpt-error-card",
    "press:stack-trace-toggle", "wait", "press:stack-frame-toggle-2", "press:stack-frame-toggle-5", "wait", "shot:excerpt-stack-trace",
    "appearance:dark", "wait", "shot:excerpt-stack-trace-dark", "appearance:light", "wait",
    f"press:excerpt-Arr.php-{vendor_line}", "wait", "shot:excerpt-vendor-peek",
], ["excerpt-error-card", "excerpt-stack-trace", "excerpt-stack-trace-dark", "excerpt-vendor-peek"])

# 2. A file that is gone when the card shows, and an SSH profile whose frames come from its
#    local folder ("local copy").
launch("missing-and-ssh", [("Generated", "local", GENERATED), ("Server", "ssh", INVOICE)], start + [
    "appearance:light", "select:Generated", "run", "wait-run:120", "wait", "excerpt-state", "shot:excerpt-missing-file",
    "select:Server", "run", "wait-run:120", "wait", "excerpt-state", "press:stack-trace-toggle", "wait", "shot:excerpt-ssh-local-copy",
], ["excerpt-missing-file", "excerpt-ssh-local-copy"])

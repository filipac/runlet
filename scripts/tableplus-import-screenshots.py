#!/usr/bin/env python3
"""#187 and #188: Settings ▸ Advanced and Import from TablePlus… in a Debug app, with scratch data
and the made-up fixtures in Tests/Fixtures/tableplus only.

Usage: tableplus-import-screenshots.py /path/to/Runlet.app /path/to/output [/path/to/scratch]

Copies the fixture folder to a neutral path under the scratch folder (the sheet shows the file's
path) and points the app at it with RUNLET_TABLEPLUS_DIR, which also swaps the Keychain for the
fixture's keychain-fixture.json: nothing reads TablePlus's real files or any keychain. A scratch
RUNLET_DATA_DIR keeps Runlet's own passwords in memory. Seeds an SSH profile "Acme jump" (matching
one TablePlus connection's SSH server) and an all-targets connection "Acme Shop (staging)" (a
duplicate by name), then shoots: Settings ▸ Databases with the flag off (no Advanced tab, no
button), Settings ▸ Advanced revealed with the flag on, the Databases tab's button, the import
sheet (supported, production, duplicate, SSH rows with a new and an existing profile), its
unsupported rows, the password opt-in, and the summary.
"""
from pathlib import Path
import shutil
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
scratch = Path(sys.argv[3] if len(sys.argv) > 3 else "/private/tmp/runlet-tableplus-shots")
root = Path(__file__).resolve().parent.parent
out.mkdir(parents=True, exist_ok=True)
shutil.rmtree(scratch, ignore_errors=True)
data = scratch / "data"
fixtures = scratch / "TablePlus"
data.mkdir(parents=True)
shutil.copytree(root / "Tests/Fixtures/tableplus", fixtures)

steps = [
    "ghost", "scale:2", "frame:1280x820",
    "ssh-add:Acme jump|ops@jump.example.org|/srv/app|staging",
    "db-new:Acme Shop (staging)|mysql|staging-db.acme.example.com|3307|shop|shop|",
    "settings", "wait", "settings-tab:Databases", "wait", "frame:Databases=600x520", "wait",
    "shot:settings-flag-off@Databases",
    "advanced:reveal", "wait", "wait", "flag:tablePlusImport=on", "wait", "frame:Advanced=640x520", "wait",
    "shot:advanced-flags@Advanced",
    "settings-tab:Databases", "wait", "wait", "frame:Databases=640x520", "wait",
    "shot:databases-import-button@Databases",
    "frame:Databases=640x780", "wait",
    "tableplus-open", "wait", "wait",
    "tableplus-select:Acme Shop (production)", "tableplus-select:Acme Shop (staging)",
    "tableplus-select:Acme Reports", "tableplus-select:Acme Billing", "tableplus-select:Example Analytics",
    "tableplus-select:Example Blog", "tableplus-select:Acme Warehouse", "tableplus-select:Local SQLite",
    "wait", "tableplus-state", "shot:import-sheet@Databases",
    "tableplus-scroll:Local MySQL socket", "wait", "shot:import-sheet-unsupported@Databases",
    "tableplus-scroll:Acme Shop (production)", "tableplus-passwords:on", "wait", "shot:import-passwords@Databases",
    "tableplus-import", "tableplus-wait", "wait", "shot:import-summary@Databases",
]
log = scratch / "stderr.txt"
subprocess.run([
    "open", "-g", "-j", "-n", "-W",
    "--env", f"RUNLET_DATA_DIR={data}",
    "--env", f"RUNLET_SNAPSHOT_DIR={out}",
    "--env", f"RUNLET_TABLEPLUS_DIR={fixtures}",
    "--env", "RUNLET_DEBUG_STEPS=" + ",".join(steps),
    "--env", "SSH_AUTH_SOCK=",
    "--stderr", str(log),
    str(app),
], check=True, timeout=300)
for line in log.read_text().splitlines():
    if "RUNLET_DEBUG_STATE" in line or "tableplus-state:" in line or "no " in line:
        print(line)

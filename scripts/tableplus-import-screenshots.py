#!/usr/bin/env python3
"""#187 and #188: Settings ▸ Advanced and Import from TablePlus… in a Debug app, with scratch data
and the made-up fixtures in Tests/Fixtures/tableplus only.

Usage: tableplus-import-screenshots.py [--mongodb] /path/to/Runlet.app /path/to/output [/path/to/scratch]

Copies the fixture folder to a neutral path under the scratch folder (the sheet shows the file's
path) and points the app at it with RUNLET_TABLEPLUS_DIR, which also swaps the Keychain for the
fixture's keychain-fixture.json: nothing reads TablePlus's real files or any keychain. A scratch
RUNLET_DATA_DIR keeps Runlet's own passwords in memory. Seeds an SSH profile "Acme jump" (matching
one TablePlus connection's SSH server) and an all-targets connection "Acme Shop (staging)" (a
duplicate by name), then shoots: Settings ▸ Databases with the flag off (no Advanced tab, no
button), Settings ▸ Advanced revealed with the flag on, the Databases tab's button, the import
sheet (supported, production, duplicate, SSH rows with a new and an existing profile), its
unsupported rows, the password opt-in, and the summary.

--mongodb (#209) shoots the fixture's MongoDB rows instead: the sheet with a replica set, SRV,
TLS, SSH (sharing the new bastion profile with an SQL row), connection strings, and SRV over SSH;
the plain row next to a still-unsupported driver; and the summary with passwords copied.
"""
from pathlib import Path
import shutil
import subprocess
import sys

args = [a for a in sys.argv[1:] if a != "--mongodb"]
mongodb = "--mongodb" in sys.argv[1:]
app = Path(args[0]).resolve()
out = Path(args[1]).resolve()
scratch = Path(args[2] if len(args) > 2 else "/private/tmp/runlet-tableplus-shots")
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
if mongodb:
    steps = [
        "ghost", "scale:2", "frame:1280x820",
        "settings", "wait", "settings-tab:Databases", "wait", "wait", "frame:Databases=640x780", "wait",
        "tableplus-open", "wait", "wait",
        "tableplus-select:Acme Events", "tableplus-select:Acme Orders", "tableplus-select:Atlas Analytics",
        "tableplus-select:Acme Audit", "tableplus-select:Acme Sessions", "tableplus-select:Acme Search",
        "tableplus-select:Example Inventory", "tableplus-select:Atlas Reports", "tableplus-select:Acme Reports",
        "tableplus-scroll:Acme Orders", "wait", "wait", "tableplus-state", "shot:mongodb-sheet@Databases",
        "tableplus-scroll:Acme Sessions", "wait", "shot:mongodb-sheet-srv-ssh@Databases",
        "tableplus-scroll:Acme Cache", "wait", "shot:mongodb-sheet-plain@Databases",
        "tableplus-passwords:on", "tableplus-scroll:Acme Orders", "wait",
        "tableplus-import", "tableplus-wait", "wait", "tableplus-state", "shot:mongodb-summary@Databases",
    ]
log = scratch / "stderr.txt"
subprocess.run([
    "open", "-g", "-j", "-n", "-W",
    "--env", f"RUNLET_DATA_DIR={data}",
    "--env", f"RUNLET_SNAPSHOT_DIR={out}",
    "--env", f"RUNLET_TABLEPLUS_DIR={fixtures}",
    # The #188 shots start with the flag off; the MongoDB shots need it on.
    "--env", f"RUNLET_FEATURE_FLAGS={'tablePlusImport' if mongodb else ''}",
    "--env", "RUNLET_DEBUG_STEPS=" + ",".join(steps),
    "--env", "SSH_AUTH_SOCK=",
    "--stderr", str(log),
    str(app),
], check=True, timeout=300)
for line in log.read_text().splitlines():
    if "RUNLET_DEBUG_STATE" in line or "tableplus-state:" in line or "no " in line:
        print(line)

#!/usr/bin/env python3
"""#279: pinned tabs end to end in a Debug app, with scratch data and neutral names only.

Usage: pinned-tabs-screenshots.py /path/to/Runlet.app /path/to/output

Seeds a scratch RUNLET_DATA_DIR (under build/ of this checkout) with one window of sandbox tabs
of every kind, three of them pinned, and runs nothing. The first launch checks the order rules
with RUNLET_DEBUG_STEPS (pin, unpin, new tab, a drag across the boundary, ⌘1, Close Other Tabs,
⌘W on a pinned tab) and prints the tab context menu; the second, on the same data, checks that
the pins came back after the relaunch. The third, on fresh data, takes the screenshots: both tab
layouts, light and dark, and the context menu of a pinned tab.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
scratch = root / "build" / "pinned-tabs-data"


def tab(title, code, language="php", pinned=False):
    state = {"id": str(uuid.uuid4()).upper(), "title": title, "code": code, "target": {"sandbox": {}},
             "selection": {"location": 0, "length": 0}, "createdAt": 0}
    if language != "php":
        state["language"] = language
    if pinned:
        state["pinned"] = True
    return state


def seed():
    shutil.rmtree(scratch, ignore_errors=True)
    state = scratch / "State"
    state.mkdir(parents=True)
    # Out of order on purpose: restoring puts the pinned tabs first.
    tabs = [
        tab("Scratch", "$total = collect([3, 5, 8])->sum();\n$total * 2\n", pinned=True),
        tab("Orders", "select id, status, total\nfrom orders\nwhere status = 'open'\nlimit 20;\n", "sql", pinned=True),
        tab("Report", "$rows = range(1, 5);\narray_map(fn ($n) => $n ** 2, $rows)\n"),
        tab("Cache", "KEYS app:*\nGET app:settings\n", "redis", pinned=True),
        tab("Events", '{ "find": "events", "filter": { "type": "signup" }, "limit": 10 }\n', "mongodb"),
        tab("Tab 6", "now()->toDateString()\n"),
    ]
    session = {"windows": [{"id": str(uuid.uuid4()).upper(), "tabs": tabs, "selectedTabId": tabs[1]["id"]}]}

    def save(name, data):
        (state / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": 0, "data": data}))
    save("settings", {"appearance": "light", "fontSize": 14, "languageServiceEnabled": False,
                      "outputVisible": False, "tabLayout": "horizontal"})
    save("session", session)


def launch(steps, name):
    log_path = out / f"{name}.log"
    log_path.write_text("")
    subprocess.run(["open", "-g", "-j", "-n", "-W", "--env", f"RUNLET_DATA_DIR={scratch}",
                    "--env", f"RUNLET_SNAPSHOT_DIR={out}", "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}",
                    "--env", "SSH_AUTH_SOCK=", "--stderr", str(log_path), str(app)], check=True)
    text = log_path.read_text()
    assert "RUNLET_DEBUG_STEPS: done" in text, text[-2000:]
    return [line.split("RUNLET_DEBUG_STATE: ", 1)[1] for line in text.splitlines() if "RUNLET_DEBUG_STATE: " in line]


def pins(lines):
    return [line for line in lines if line.startswith("pins-state:")]


# MARK: The rules, on a first launch (no screenshots)

seed()
states = launch(["ghost", "pins-state",
                 "pin:Report", "unpin:Scratch",
                 "select:Cache", "perform:file.newTab", "pins-state",
                 "move-tab:Tab 6=0", "move-tab:Orders=5",
                 "perform:tabs.select1", "pins-state",
                 "tab-menu-items:Orders",
                 "select:Report", "perform:tabs.closeOthers", "pins-state",
                 "select:Cache", "close-front:editor", "pins-state"], "rules")
print("\n".join(states))
steps = pins(states)
# Restored: pinned first, in their order; Orders selected.
assert steps[0] == "pins-state: pinned=3 tabs=[\"📌Scratch\", \"*📌Orders\", \"📌Cache\", \"Report\", \"Events\", \"Tab 6\"] cmd1=Scratch", steps[0]
# Pin Report: the end of the pinned tabs. Unpin Scratch: the start of the others.
assert steps[1].startswith("pins-state: pinned=4 tabs=[\"📌Scratch\", \"*📌Orders\", \"📌Cache\", \"📌Report\""), steps[1]
assert steps[2].startswith("pins-state: pinned=3 tabs=[\"*📌Orders\", \"📌Cache\", \"📌Report\", \"Scratch\", \"Events\""), steps[2]
# A new tab while a pinned tab is selected opens after the pinned tabs.
assert steps[3] == "pins-state: pinned=3 tabs=[\"📌Orders\", \"📌Cache\", \"📌Report\", \"*Tab 7\", \"Scratch\", \"Events\", \"Tab 6\"] cmd1=Orders", steps[3]
# Drags across the boundary stay in their group: Tab 6 to the front becomes the first unpinned
# tab, Orders to the end the last pinned one. ⌘1 then selects the first pinned tab.
assert steps[4] == "pins-state: pinned=3 tabs=[\"📌Orders\", \"📌Cache\", \"📌Report\", \"Tab 6\", \"*Tab 7\", \"Scratch\", \"Events\"] cmd1=Orders", steps[4]
assert steps[5] == "pins-state: pinned=3 tabs=[\"📌Cache\", \"📌Report\", \"📌Orders\", \"Tab 6\", \"*Tab 7\", \"Scratch\", \"Events\"] cmd1=Cache", steps[5]
assert steps[6].startswith("pins-state: pinned=3 tabs=[\"*📌Cache\""), steps[6]
assert any("Unpin Tab" in line for line in states if line.startswith("tab-menu")), states
# Close Other Tabs keeps the pinned tabs.
assert steps[7] == "pins-state: pinned=3 tabs=[\"📌Cache\", \"*📌Report\", \"📌Orders\"] cmd1=Cache", steps[7]
# ⌘W on a pinned tab still closes it.
assert steps[8] == "pins-state: pinned=2 tabs=[\"*📌Report\", \"📌Orders\"] cmd1=Report", steps[8]

# MARK: A relaunch keeps the pins (Report was pinned in the first launch)

states = launch(["ghost", "pins-state"], "relaunch")
print("\n".join(states))
assert pins(states) == ["pins-state: pinned=2 tabs=[\"*📌Report\", \"📌Orders\"] cmd1=Report"], states

# MARK: Screenshots

seed()
states = launch(["ghost", "scale:2", "frame:980x420", "appearance:light", "tabs:horizontal", "pins-state", "wait",
                 "shot:horizontal-light",
                 "tab-menu:Orders", "wait", "shot:menu-light", "tab-menu:off",
                 "tabs:vertical", "wait", "shot:vertical-light",
                 "appearance:dark", "wait", "shot:vertical-dark",
                 "tabs:horizontal", "wait", "shot:horizontal-dark"], "shots")
print("\n".join(states))
assert pins(states)[0].startswith("pins-state: pinned=3 tabs=[\"📌Scratch\", \"*📌Orders\", \"📌Cache\""), pins(states)
for name in ["horizontal-light", "menu-light", "vertical-light", "vertical-dark", "horizontal-dark"]:
    assert (out / f"{name}.png").is_file(), name
print("ok")

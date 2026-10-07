#!/usr/bin/env python3
"""#345: shortcut tips, end to end in a Debug app, with scratch data and neutral names only.

Usage: shortcut-tip-check.py /path/to/Runlet.app /path/to/output [--no-shots]

Seeds a scratch RUNLET_DATA_DIR (under build/ of this checkout) with one window and one sandbox
tab, and runs nothing. Runlet stays in the background (`ghost`) and never takes the keyboard:
buttons are pressed through accessibility, menu items are chosen in the main menu, and
shortcuts are key events posted to Runlet alone.

Checks that a toolbar button runs its command and counts a click; that a scripted run shows no
tip until a step turns tips on; that a click shows the tip once a day, a menu item and the
palette too, and the shortcut itself never; that three uses of the shortcut, or Don't Show
Again, stop the tip for good; that the tip moves to the top when the caret's line is at the
bottom; that Clear Command History keeps Don't Show Again; and that Settings can turn tips off.
Then the screenshots: the tip in light and dark, at the top, and Settings ▸ General ▸ Tips.
"""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
shots = "--no-shots" not in sys.argv
out.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
scratch = root / "build" / "shortcut-tip-data"

SHORT = "$orders = collect([\n    ['id' => 1, 'total' => 120],\n    ['id' => 2, 'total' => 80],\n]);\n\n$orders->sum('total')\n"
LONG = "".join(f"$line{n} = {n} * 2;\n" for n in range(1, 61))


def seed(code=SHORT, **settings):
    shutil.rmtree(scratch, ignore_errors=True)
    state = scratch / "State"
    state.mkdir(parents=True)
    tab = {"id": str(uuid.uuid4()).upper(), "title": "Totals", "code": code, "target": {"sandbox": {}},
           "selection": {"location": 0, "length": 0}, "createdAt": 0}

    def save(name, data):
        (state / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": 0, "data": data}))
    save("settings", {"appearance": "light", "fontSize": 14, "languageServiceEnabled": False, "outputVisible": True, **settings})
    save("session", {"windows": [{"id": str(uuid.uuid4()).upper(), "tabs": [tab], "selectedTabId": tab["id"]}]})


def launch(steps, name):
    log_path = out / f"{name}.log"
    log_path.write_text("")
    subprocess.run(["open", "-g", "-j", "-n", "-W", "--env", f"RUNLET_DATA_DIR={scratch}",
                    "--env", f"RUNLET_SNAPSHOT_DIR={out}", "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}",
                    "--env", "SSH_AUTH_SOCK=", "--stderr", str(log_path), str(app)], check=True)
    text = log_path.read_text()
    assert "RUNLET_DEBUG_STEPS: done" in text, text[-3000:]
    lines = [line.split("RUNLET_DEBUG_STATE: ", 1)[1] for line in text.splitlines() if "RUNLET_DEBUG_STATE: " in line]
    print(f"--- {name}")
    print("\n".join(lines))
    return lines


def tips(lines):
    return [line for line in lines if line.startswith(("shortcut-tip-state:", "shortcut-tip ", "shortcut-tip-menu ", "shortcut-tip-clear:"))]


def field(line, key):
    match = re.search(rf"\b{key}=(\"[^\"]*\"|\S+)", line)
    return match.group(1).strip('"') if match else None


def uses(line, command):
    match = re.search(rf"{re.escape(command)} uses\{{([^}}]*)\}}", line)
    return dict(pair.split("=") for pair in match.group(1).split(",") if pair) if match else {}


def check():
    seed()
    lines = tips(launch([
        "ghost", "frame:1000x620",
        # 1. The toolbar's tab layout button runs Toggle Vertical Tabs and counts a click; a
        #    scripted run shows no tip until a step asks for them.
        "press:tab-layout-toggle", "wait", "shortcut-tip-state",
        # 2. With tips on, a click shows the tip: once.
        "shortcut-tips:on", "press:tab-layout-toggle", "wait", "shortcut-tip-state",
        "press:tab-layout-toggle", "wait", "shortcut-tip-state",
        # 3. A menu item: the tip says so. The shortcut itself counts, and hides the tip.
        "shortcut-tip-menu:file.newTab", "wait", "key:ctrl+cmd+t", "wait", "shortcut-tip-state",
        # 4. Three uses of the shortcut: never again.
        "shortcut-tip-key:view.verticalTabs", "shortcut-tip-key:view.verticalTabs", "shortcut-tip:view.verticalTabs|toolbar",
        # 5. Don't Show Again, then the palette, then Clear Command History.
        "shortcut-tip:output.copy", "shortcut-tip-dont-show", "shortcut-tip:output.copy",
        "palette:commands:show database", "wait", "palette-return", "wait", "shortcut-tip-state",
        "shortcut-tip-clear", "shortcut-tip:output.copy",
        # 6. The output pane's Structured | Plain | Raw runs Output: Plain.
        "shortcut-tip:off", "segment:Plain", "wait", "shortcut-tip-state",
    ], "check"))
    # 1.
    assert field(lines[0], "tip") == "none", lines[0]
    assert uses(lines[0], "view.verticalTabs") == {"toolbar": "1"}, lines[0]
    # 2.
    assert field(lines[1], "tip") == "view.verticalTabs" and field(lines[1], "edge") == "bottom", lines[1]
    assert 'text="⌃⌘T is the shortcut for Toggle Vertical Tabs. It saves a trip to the toolbar."' in lines[1], lines[1]
    assert field(lines[2], "tip") == "none" and uses(lines[2], "view.verticalTabs") == {"toolbar": "3"}, lines[2]
    # 3.
    assert 'text="⌘T is the shortcut for New Tab. It saves a trip to the menu bar."' in lines[3], lines[3]
    assert uses(lines[3], "file.newTab") == {"menu": "1"}, lines[3]
    assert field(lines[4], "tip") == "none", lines[4]
    assert uses(lines[4], "view.verticalTabs") == {"keyboard": "1", "toolbar": "3"}, lines[4]
    # 4.
    assert lines[5].startswith("shortcut-tip view.verticalTabs from toolbar: learned"), lines[5]
    # 5.
    assert lines[6].startswith("shortcut-tip output.copy from button: show"), lines[6]
    assert lines[7].startswith("shortcut-tip output.copy from button: dismissed"), lines[7]
    assert 'text="⇧⌘B is the shortcut for Show Database. It skips the palette."' in lines[8], lines[8]
    assert uses(lines[8], "library.database") == {"palette": "1"}, lines[8]
    assert "output.copy uses{} lastTip=never dismissed" in lines[9] and "view.verticalTabs" not in lines[9], lines[9]
    assert lines[10].startswith("shortcut-tip output.copy from button: dismissed"), lines[10]
    # 6.
    assert 'text="⌃⌘2 is the shortcut for Output: Plain. It keeps your hands on the keyboard."' in lines[11], lines[11]
    assert uses(lines[11], "output.plain") == {"button": "1"}, lines[11]

    # 7. The caret's line at the bottom of the editor: the tip goes to the top.
    seed(LONG)
    lines = tips(launch(["ghost", "frame:1000x620", "caret:end", "wait", "shortcut-tip:run.run|toolbar", "wait", "shortcut-tip-state",
                         *(["shot:shortcut-tip-top-light"] if shots else [])], "caret"))
    assert lines[0].startswith("shortcut-tip run.run from toolbar: show") and field(lines[1], "edge") == "top", lines

    # 8. Settings ▸ General ▸ Tips ▸ Show shortcut tips off.
    seed(shortcutTips=False)
    lines = tips(launch(["ghost", "shortcut-tip:view.verticalTabs|toolbar"], "off"))
    assert lines[0].startswith("shortcut-tip view.verticalTabs from toolbar: turnedOff"), lines[0]


def screenshots():
    for appearance in ["light", "dark"]:
        seed(appearance=appearance)
        launch(["ghost", "frame:1000x620", f"appearance:{appearance}", "wait", "shortcut-tip:view.verticalTabs|toolbar", "wait",
                f"shot:shortcut-tip-{appearance}",
                "shortcut-tip:off", "settings", "wait", "settings-tab:General", "wait", "scroll:settings-shortcut-tips", "wait",
                f"shot:shortcut-tip-settings-{appearance}@General"], f"shots-{appearance}")


check()
if shots:
    screenshots()
print("Shortcut tips: all checks passed.")

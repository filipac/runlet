#!/usr/bin/env python3
"""#285: renaming a tab, end to end in a Debug app, with scratch data and neutral names only.

Usage: tab-rename-check.py /path/to/Runlet.app /path/to/output [--no-shots]

Seeds a scratch RUNLET_DATA_DIR (under build/ of this checkout) with one window of sandbox tabs,
two of them pinned, and runs nothing. Runlet stays in the background (`ghost`): the steps hand
keys to the rename field's editor, so nothing needs the keyboard.

In each tab layout, for an unpinned and a pinned tab, a rename from Rename… (as the context menu
starts it), Rename Tab…, the command palette (⇧⌘P), and Open Anything (⌘P) opens the field with
the keyboard and the whole title selected. Typing replaces the title; Return commits, Esc keeps
the old title, the editor taking the keyboard (a click in it) or a click elsewhere commits, an
empty or whitespace-only name keeps the old title, and ⌘W closes nothing. Keys never reach the
editor, Esc doesn't hide the output pane, and the editor gets the keyboard back afterwards. Then
the screenshots: a rename in progress in both layouts, light and dark.
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
scratch = root / "build" / "tab-rename-data"


def tab(title, code, language="php", pinned=False):
    state = {"id": str(uuid.uuid4()).upper(), "title": title, "code": code, "target": {"sandbox": {}},
             "selection": {"location": 0, "length": 0}, "createdAt": 0}
    if language != "php":
        state["language"] = language
    if pinned:
        state["pinned"] = True
    return state


def seed(layout):
    shutil.rmtree(scratch, ignore_errors=True)
    state = scratch / "State"
    state.mkdir(parents=True)
    tabs = [
        tab("Scratch", "$total = collect([3, 5, 8])->sum();\n$total * 2\n", pinned=True),
        tab("Orders", "select id, status, total\nfrom orders\nwhere status = 'open'\nlimit 20;\n", "sql", pinned=True),
        tab("Report", "$rows = range(1, 5);\narray_map(fn ($n) => $n ** 2, $rows)\n"),
        tab("Events", '{ "find": "events", "filter": { "type": "signup" }, "limit": 10 }\n', "mongodb"),
        tab("Tab 5", "now()->toDateString()\n"),
    ]
    session = {"windows": [{"id": str(uuid.uuid4()).upper(), "tabs": tabs, "selectedTabId": tabs[2]["id"]}]}

    def save(name, data):
        (state / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": 0, "data": data}))
    save("settings", {"appearance": "light", "fontSize": 14, "languageServiceEnabled": False,
                      "outputVisible": True, "tabLayout": layout})
    save("session", session)


def launch(steps, name):
    log_path = out / f"{name}.log"
    log_path.write_text("")
    subprocess.run(["open", "-g", "-j", "-n", "-W", "--env", f"RUNLET_DATA_DIR={scratch}",
                    "--env", f"RUNLET_SNAPSHOT_DIR={out}", "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}",
                    "--env", "SSH_AUTH_SOCK=", "--stderr", str(log_path), str(app)], check=True)
    text = log_path.read_text()
    assert "RUNLET_DEBUG_STEPS: done" in text, text[-3000:]
    return [line.split("RUNLET_DEBUG_STATE: ", 1)[1] for line in text.splitlines() if "RUNLET_DEBUG_STATE: " in line]


def renames(lines):
    return [line for line in lines if line.startswith("rename-state:")]


def field(line, key):
    match = re.search(rf"\b{key}=(\"[^\"]*\"|\[[^\]]*\]|\S+)", line)
    return match.group(1).strip('"') if match else None


def open_with_title_selected(line, title, pinned, layout):
    assert field(line, "layout") == layout, line
    assert field(line, "renaming") == title, line
    assert field(line, "pinned") == ("yes" if pinned else "no"), line
    assert field(line, "field") == "yes", line
    assert field(line, "keyboard") == "rename-field", line
    assert field(line, "all-selected") == "yes", line
    assert f"selection={{0, {len(title)}}}" in line, line
    assert field(line, "text") == title, line
    # What gets the keyboard back: the editor, or nothing when nothing had it (`none`).
    assert field(line, "then") in ("editor", "none"), line


def closed(line, titles, keyboard="editor"):
    assert field(line, "renaming") == "none", line
    assert field(line, "field") == "no", line
    assert field(line, "keyboard") == keyboard, line
    assert field(line, "output") == "shown", line
    assert field(line, "tabs") == "[" + ", ".join(f'"{t}"' for t in titles) + "]", line


CODE = 'code="$rows = range(1, 5);\\narray_map(fn ($n) "'


def check(layout):
    seed(layout)
    states = launch([
        "ghost", "rename-state",
        # 1. Rename… (as the context menu and a double-click start it): the title is selected,
        #    typing replaces it, Return commits.
        "rename-begin:Report", "rename-state", "rename-type:Weekly report", "rename-state", "rename-key:return",
        # 2. Esc keeps the old title, and nothing else (the output pane stays).
        "rename-begin:Weekly report", "rename-type:Nope", "rename-key:escape",
        # 3. The editor taking the keyboard (a click in it) commits.
        "rename-begin:Weekly report", "rename-type:Report", "rename-blur:editor", "rename-state",
        # 4. An empty or whitespace-only name keeps the title.
        "rename-begin:Report", "rename-key:delete", "rename-key:return", "rename-state",
        "rename-begin:Report", "rename-key:space", "rename-key:space", "rename-key:return", "rename-state",
        # 5. A pinned tab: a click elsewhere commits, and the keyboard goes back to the editor.
        "rename-begin:Orders", "rename-state", "rename-type:Ledger", "rename-blur:click", "rename-state",
        # 6. ⌘W while renaming closes nothing; Esc then ends the rename.
        "rename-begin:Ledger", "perform:file.closeTab", "rename-state", "rename-key:escape",
        # 7. Rename Tab… (Window menu) on the selected tab.
        "perform:tabs.rename", "rename-state", "rename-key:escape",
        # 8. The command palette (⇧⌘P) and Open Anything (⌘P): the palette closes, then the field
        #    takes the keyboard.
        "palette:commands:rename tab", "wait", "palette-return", "rename-state", "rename-key:escape",
        "palette:anything:rename", "wait", "palette-return", "rename-state", "rename-type:Palette", "rename-key:return", "rename-state",
        # 9. The same for a pinned tab.
        "select:Scratch", "rename-state", "palette:commands:rename tab", "wait", "palette-return", "rename-state", "rename-key:escape",
        "palette:anything:rename tab", "wait", "palette-return", "rename-state", "rename-key:escape",
        # 10. Code grabbing the keyboard right after the start: the field takes it back.
        "select:Palette", "rename-state", "rename-begin-steal:Events", "rename-state", "rename-key:escape", "rename-state",
        # 11. Renaming another tab while one is renamed commits the first; the editor gets the
        #     keyboard back after the second.
        "rename-begin:Palette", "rename-type:Summary", "rename-begin:Tab 5", "rename-state", "rename-type:Notes", "rename-key:return",
    ], f"check-{layout}")
    print(f"--- {layout}")
    print("\n".join(states))
    lines = renames(states)
    keyed = [line for line in states if line.startswith("rename-key")]
    start = lines[0]
    # Before any rename: the editor has the keyboard.
    assert field(start, "renaming") == "none" and field(start, "keyboard") == "editor", start
    assert CODE in start, start
    order = ["📌Scratch", "📌Orders", "*Report", "Events", "Tab 5"]
    # 1.
    open_with_title_selected(lines[1], "Report", False, layout)
    assert field(lines[2], "text") == "Weekly report" and field(lines[2], "keyboard") == "rename-field", lines[2]
    assert CODE in lines[2], lines[2]
    renamed = ["📌Scratch", "📌Orders", "*Weekly report", "Events", "Tab 5"]
    closed(keyed[0].split(": ", 1)[1], renamed)
    # 2.
    closed(keyed[1].split(": ", 1)[1], renamed)
    # 3.
    closed(lines[3], order)
    # 4.
    closed(lines[4], order)
    closed(lines[5], order)
    # 5.
    open_with_title_selected(lines[6], "Orders", True, layout)
    ledger = ["📌Scratch", "📌Ledger", "*Report", "Events", "Tab 5"]
    closed(lines[7], ledger)
    assert any(line == "rename-blur click: ended=true" for line in states), states
    # 6. ⌘W: still renaming, no tab closed.
    assert field(lines[8], "renaming") == "Ledger" and field(lines[8], "keyboard") == "rename-field", lines[8]
    assert field(lines[8], "tabs") == "[" + ", ".join(f'"{t}"' for t in ledger) + "]", lines[8]
    closed(keyed[7].split(": ", 1)[1], ledger)
    # 7.
    open_with_title_selected(lines[9], "Report", False, layout)
    # 8.
    open_with_title_selected(lines[10], "Report", False, layout)
    open_with_title_selected(lines[11], "Report", False, layout)
    closed(lines[12], ["📌Scratch", "📌Ledger", "*Palette", "Events", "Tab 5"])
    # From here on a tab is selected first. Its editor takes the keyboard on its own, which can
    # lose a race under load (then nothing has it): whatever had it before a rename gets it back.
    def then(keyboard):
        return "none" if keyboard == "window" else keyboard
    # 9.
    before = field(lines[13], "keyboard")
    pinned = ["*📌Scratch", "📌Ledger", "Palette", "Events", "Tab 5"]
    open_with_title_selected(lines[14], "Scratch", True, layout)
    assert field(lines[14], "then") == then(before), (before, lines[14])
    closed(keyed[11].split(": ", 1)[1], pinned, keyboard=before)
    open_with_title_selected(lines[15], "Scratch", True, layout)
    closed(keyed[12].split(": ", 1)[1], pinned, keyboard=before)
    # 10.
    before = field(lines[16], "keyboard")
    open_with_title_selected(lines[17], "Events", False, layout)
    assert field(lines[17], "reclaimed") == "1", lines[17]
    assert field(lines[17], "then") == then(before), (before, lines[17])
    closed(lines[18], ["📌Scratch", "📌Ledger", "*Palette", "Events", "Tab 5"], keyboard=before)
    # 11.
    open_with_title_selected(lines[19], "Tab 5", False, layout)
    assert field(lines[19], "tabs") == '["📌Scratch", "📌Ledger", "*Summary", "Events", "Tab 5"]', lines[19]
    assert field(lines[19], "then") == then(before), (before, lines[19])
    closed(keyed[-1].split(": ", 1)[1], ["📌Scratch", "📌Ledger", "*Summary", "Events", "Notes"], keyboard=before)


check("horizontal")
check("vertical")

if shots:
    seed("horizontal")
    # A first launch on the fresh data places the window; the next one draws where it belongs.
    launch(["ghost"], "place")
    states = launch(["ghost", "scale:2", "frame:900x400", "appearance:light", "tabs:horizontal",
                     "rename-begin:Report", "wait", "rename-state", "shot:rename-horizontal-light", "rename-key:escape",
                     "rename-begin:Orders", "wait", "rename-state", "shot:rename-pinned-horizontal-light", "rename-key:escape",
                     "tabs:vertical", "wait",
                     "rename-begin:Report", "wait", "rename-state", "shot:rename-vertical-light", "rename-key:escape",
                     "rename-begin:Orders", "wait", "rename-state", "shot:rename-pinned-vertical-light", "rename-key:escape",
                     "appearance:dark", "wait",
                     "rename-begin:Report", "wait", "rename-state", "shot:rename-vertical-dark", "rename-key:escape"], "shots")
    print("--- shots")
    print("\n".join(states))
    for line in renames(states):
        assert field(line, "all-selected") == "yes", line
    for name in ["rename-horizontal-light", "rename-pinned-horizontal-light", "rename-vertical-light",
                 "rename-pinned-vertical-light", "rename-vertical-dark"]:
        assert (out / f"{name}.png").is_file(), name
print("ok")

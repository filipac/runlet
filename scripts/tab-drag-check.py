#!/usr/bin/env python3
"""#322: dragging tabs along the horizontal tab bar, end to end in a Debug app, with scratch data
and neutral names only. Takes no screenshots.

Usage: tab-drag-check.py /path/to/Runlet.app /path/to/output [steps…]

Seeds a scratch RUNLET_DATA_DIR (under build/ of this checkout) with one window of fourteen
sandbox tabs, two of them pinned, in the horizontal layout, and runs nothing. Runlet stays in
the background (`ghost`): the `tab-drag` steps move the pointer through the same drag a mouse
makes, without a mouse.

1. Drags: a tab lands where it is dropped, the tabs it passes slide aside by its width, and the
   dragged tab is selected. A drag across the pinned/unpinned boundary stops at its group's
   end, both ways. A cancelled drag moves nothing.
2. Edge scrolling: with the pointer at the end of the visible bar, the bar scrolls to its end
   and the tab comes along; at the start, it scrolls back.
3. Move Tab Left and Move Tab Right, inside the tab's group. A tab opened mid-drag ends the drag.
4. A relaunch on the same data: the order was saved.

With steps after the output folder, it only runs those (after `ghost`), and prints what they
print.
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
out.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
scratch = root / "build" / "tab-drag-data"

PINNED = ["Notes", "Queries"]
OTHERS = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa", "Lambda", "Omicron"]


def tab(title, pinned=False):
    state = {"id": str(uuid.uuid4()).upper(), "title": title, "code": f"// {title}\n'{title}'\n",
             "target": {"sandbox": {}}, "selection": {"location": 0, "length": 0}, "createdAt": 0}
    if pinned:
        state["pinned"] = True
    return state


def seed():
    shutil.rmtree(scratch, ignore_errors=True)
    state = scratch / "State"
    state.mkdir(parents=True)
    tabs = [tab(title, pinned=True) for title in PINNED] + [tab(title) for title in OTHERS]
    session = {"windows": [{"id": str(uuid.uuid4()).upper(), "tabs": tabs, "selectedTabId": tabs[2]["id"]}]}

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
                    "--env", "RUNLET_CREDENTIALS=memory", "--env", "SSH_AUTH_SOCK=", "--env", f"RUNLET_DEBUG_HOME={scratch}",
                    "--stderr", str(log_path), str(app)], check=True)
    text = log_path.read_text()
    assert "RUNLET_DEBUG_STEPS: done" in text, text[-2000:]
    return [line.split("RUNLET_DEBUG_STATE: ", 1)[1] for line in text.splitlines() if "RUNLET_DEBUG_STATE: " in line]


def tabs(line):
    """The tabs a line ends with: `*` selected, `📌` pinned."""
    return json.loads(line[line.index("tabs=") + 5:].split("]", 1)[0] + "]")


def field(line, name):
    return re.search(rf"\b{name}=(\S+)", line).group(1)


def slid(line):
    """The tabs that slid aside, and by how much: {title: points}."""
    pairs = json.loads(re.search(r"slid=(\[[^\]]*\])", line).group(1))
    return {m.group(1): int(m.group(2)) for m in (re.fullmatch(r"(.+?)([+-]\d+)", pair) for pair in pairs)}


if len(sys.argv) > 3:
    seed()
    print("\n".join(launch(["ghost"] + sys.argv[3:], "custom")))
    sys.exit(0)

# MARK: Drags, edge scrolling, Move Tab Left/Right

seed()
states = launch(["ghost", "frame:900x600", "wait", "tab-drag-state",
                 # Inside the unpinned tabs, to the right; then the left.
                 "tab-drag:Alpha=5", "tab-drop",
                 "tab-drag:Delta=3", "tab-drop",
                 # Across the boundary, both ways: each stops at its group's end.
                 "tab-drag:Gamma=0", "tab-drop",
                 "tab-drag:Notes=6", "tab-drop",
                 # Not moved far enough, and cancelled: nothing moves.
                 "tab-drag:Queries=0", "tab-drop",
                 "tab-drag:Beta=8", "tab-drag-cancel",
                 # Near the ends of the visible bar, it scrolls; the tab comes along.
                 "tab-drag-edge:Kappa=end", "wait", "tab-drag-state", "tab-drop",
                 "tab-drag-edge:Lambda=start", "wait", "tab-drag-state", "tab-drop",
                 # Move Tab Left/Right stay in the group.
                 "select:Notes", "perform:tabs.moveRight", "pins-state",
                 "perform:tabs.moveLeft", "perform:tabs.moveLeft", "pins-state",
                 "select:Gamma", "perform:tabs.moveLeft", "pins-state",
                 "perform:tabs.moveRight", "pins-state",
                 # A tab opened mid-drag (⌘T works with the button down) ends the drag.
                 "tab-drag:Delta=9", "perform:file.newTab", "tab-drag-state", "perform:file.closeTab", "pins-state"], "drags")
print("\n".join(states))
assert not any("isn't laid out" in line for line in states), "no tab bar"
drags = [line for line in states if line.startswith(("tab-drag:", "tab-drag-edge:", "tab-drag-state:"))]
drops = [line for line in states if line.startswith(("tab-drop:", "tab-drag-cancel:"))]
pins = [line for line in states if line.startswith("pins-state:")]
start = ["📌Notes", "📌Queries", "*Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa", "Lambda", "Omicron"]
assert drags[0].startswith("tab-drag-state: no drag scroll=0/") and tabs(drags[0]) == start, drags[0]
# The bar is wider than the window: there is something to scroll.
assert int(field(drags[0], "scroll").split("/")[1]) > 100, drags[0]

# Alpha to 5: Beta, Gamma, and Delta slide left by Alpha's width and the spacing.
alpha = drags[1]
assert field(alpha, "dragging") == "Alpha" and field(alpha, "lands") == "5" and field(alpha, "moves") == "true", alpha
shifts = slid(alpha)
assert list(shifts) == ["Beta", "Gamma", "Delta"] and len(set(shifts.values())) == 1 and shifts["Beta"] < -50, alpha
assert tabs(drops[0]) == ["📌Notes", "📌Queries", "Beta", "Gamma", "Delta", "*Alpha", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa", "Lambda", "Omicron"], drops[0]
# Delta to 3, leftward: Gamma slides right.
assert field(drags[2], "lands") == "3" and list(slid(drags[2])) == ["Gamma"] and slid(drags[2])["Gamma"] > 50, drags[2]
assert tabs(drops[1]) == ["📌Notes", "📌Queries", "Beta", "*Delta", "Gamma", "Alpha", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa", "Lambda", "Omicron"], drops[1]
# Gamma aimed at the first pinned tab: the first unpinned place; the pinned tabs don't move.
assert field(drags[3], "lands") == "2" and list(slid(drags[3])) == ["Beta", "Delta"], drags[3]
assert tabs(drops[2]) == ["📌Notes", "📌Queries", "*Gamma", "Beta", "Delta", "Alpha", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa", "Lambda", "Omicron"], drops[2]
# Notes aimed at an unpinned tab: the last pinned place.
assert field(drags[4], "lands") == "1" and list(slid(drags[4])) == ["Queries"], drags[4]
assert tabs(drops[3]) == ["📌Queries", "*📌Notes", "Gamma", "Beta", "Delta", "Alpha", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa", "Lambda", "Omicron"], drops[3]
# Queries is the first pinned tab already: nothing moves (it is selected, as a click would).
assert field(drags[5], "moves") == "false" and slid(drags[5]) == {}, drags[5]
assert tabs(drops[4]) == ["*📌Queries", "📌Notes", "Gamma", "Beta", "Delta", "Alpha", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa", "Lambda", "Omicron"], drops[4]
# A cancelled drag puts Beta back.
assert field(drags[6], "lands") == "8", drags[6]
assert tabs(drops[5]) == ["📌Queries", "📌Notes", "Gamma", "*Beta", "Delta", "Alpha", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa", "Lambda", "Omicron"], drops[5]

# The end of the bar: it scrolled all the way, and Kappa came along to the last place.
assert field(drags[7], "edge") == "1" and field(drags[7], "moves") == "false", drags[7]
scrolled, most = field(drags[8], "scroll").split("/")
assert scrolled == most and int(most) > 100 and field(drags[8], "lands") == "13", drags[8]
assert tabs(drops[6])[-1] == "*Kappa", drops[6]
# The start: back to the beginning, and Lambda came along, staying after the pinned tabs.
assert field(drags[9], "edge") == "-1", drags[9]
assert field(drags[10], "scroll").startswith("0/") and 2 <= int(field(drags[10], "lands")) < 11, drags[10]
after_edges = tabs(drops[7])
assert after_edges[:2] == ["📌Queries", "📌Notes"] and "*Lambda" in after_edges[2:11], drops[7]

# Move Tab Right on the last pinned tab, and Left on the first unpinned one, do nothing.
assert tabs(pins[0])[:3] == ["📌Queries", "*📌Notes", after_edges[2]], pins[0]
assert tabs(pins[1])[:3] == ["*📌Notes", "📌Queries", after_edges[2]], pins[1]
# Gamma: Move Tab Left once it is the first unpinned tab does nothing; Right moves it one along.
assert tabs(pins[2])[:3] == ["📌Notes", "📌Queries", "*Gamma"], pins[2]
assert tabs(pins[3])[2:4] == [tabs(pins[2])[3], "*Gamma"], pins[3]
# The new tab ended the drag: nothing slid, nothing moved.
assert drags[11].startswith("tab-drag:") and field(drags[11], "lands") == "9", drags[11]
assert drags[12].startswith("tab-drag-state: no drag"), drags[12]
assert [title.lstrip("*") for title in tabs(pins[4])] == [title.lstrip("*") for title in tabs(pins[3])], pins[4]
saved = [title.lstrip("*") for title in tabs(pins[4])]

# MARK: A relaunch: the order was saved

states = launch(["ghost", "pins-state"], "relaunch")
print("\n".join(states))
assert [title.lstrip("*") for title in tabs(states[0])] == saved, (states[0], saved)
print("tab-drag-check: OK")

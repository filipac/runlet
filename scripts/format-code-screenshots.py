#!/usr/bin/env python3
"""#36: Format Code screenshots from a Debug app with scratch data.

The first launch runs nothing: the tab's code is formatted (and a syntax error shown), the palette
lists the command, and Settings shows the Formatting section. The second launch turns on Format
before run and explicitly runs only the seeded snippet in Runlet's own sandbox (in the scratch
data directory), to show that Run formats first.
Usage: format-code-screenshots.py /path/to/Runlet.app /path/to/output
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
messy = """$users = User::query()->where("active",true)->latest()->take(3)->get(); //?
$total=0;
foreach($users as $user){ //?
$total += strlen($user->name); //?
}
$names = $users->map(fn($u)=>["id"=>$u->id,"name"=>$u->name]);
$total /*?*/ * 2;
$names->count()
"""
broken = """$items = [1, 2, 3;
collect($items)->sum()
"""
before_run = """$items=[3,1,2];
sort($items); //?
$doubled=array_map(fn($i)=>$i*2,$items); //?
array_sum($doubled)
"""


def launch(settings, title, code, steps, names, files=None):
    # Under /private/tmp, so paths in Settings show no user-specific temporary directory.
    with tempfile.TemporaryDirectory(prefix="runlet-format-preview-", dir="/private/tmp") as scratch:
        state = Path(scratch) / "State"
        state.mkdir()

        def save(name, data):
            (state / f"{name}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": 0, "data": data}))
        save("settings", settings)
        save("session", {"tabs": [{"id": str(uuid.uuid4()).upper(), "title": title, "code": code,
             "target": {"sandbox": {}}, "selection": {"location": 0, "length": 0}, "createdAt": 0}]})
        for name, text in (files or {}).items():
            (Path(scratch) / name).write_text(text)
        steps = [step.replace("{scratch}", scratch) for step in steps]
        log_path = out / "capture.log"
        log_path.write_text("")
        subprocess.run(["open", "-g", "-j", "-n", "-W", "--env", f"RUNLET_DATA_DIR={scratch}",
            "--env", f"RUNLET_SNAPSHOT_DIR={out}", "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}",
            "--env", "SSH_AUTH_SOCK=", "--stderr", str(log_path), str(app)], check=True)
        assert "RUNLET_DEBUG_STEPS: done" in log_path.read_text()
        for name in names:
            assert (out / f"{name}.png").is_file(), name


base = {"appearance": "light", "fontSize": 14, "languageServiceEnabled": False}
launch({**base, "outputVisible": False}, "Format Code", messy,
       ["ghost", "scale:2", "frame:1180x640", "appearance:light", "caret:1", "wait",
        "shot:format-before", "perform:edit.formatCode", "wait", "shot:format-after",
        "palette:commands:format", "wait", "shot:format-palette", "palette:off",
        "code:{scratch}/broken.php", "wait", "perform:edit.formatCode", "wait", "shot:format-error",
        "settings", "wait", "settings-tab:Editor", "wait", "frame:Editor=640x640",
        "scroll:settings-format-quotes", "wait", "shot:format-settings@Editor"],
       ["format-before", "format-after", "format-palette", "format-error", "format-settings"],
       files={"broken.php": broken})
launch({**base, "formatBeforeRun": True}, "Format before run", before_run,
       ["ghost", "scale:2", "frame:1180x640", "appearance:light", "run", "wait-run", "wait",
        "shot:format-before-run"],
       ["format-before-run"])

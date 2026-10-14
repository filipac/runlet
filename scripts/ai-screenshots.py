#!/usr/bin/env python3
"""#368, #44: Settings ▸ AI and Explain or Fix Error, from a Debug app with scratch data.

Usage: ai-screenshots.py /path/to/Runlet.app /path/to/output

Build the app with the screenshot bundle id first (docs/testing.md, "Checking the App"). The
script starts the AI providers' stand-in (scripts/ai_stub.py: `Tests/Fixtures/ai-stub/router.php`
under `php -S` on 127.0.0.1) and points the app at it with `RUNLET_AI_BASE_URL`, so nothing reaches Anthropic or
OpenAI. The key is made up, and a scratch `RUNLET_DATA_DIR` keeps it in memory, never in the
Keychain. The tab runs in a copy of the `laravel-app` fixture under /private/tmp, where a class
throws for a negative invoice line.

Takes, in light and dark where it matters: Settings ▸ AI with a saved (masked) key that Test Key
checked; the disclosure (what would be sent); the answer while it streams; the proposed fix with
Apply Fix; the fix applied; and the disclosure without a key. Checks the steps' states and what
the stand-in received: one request per Send, with only the parts that were on; and that the
sheet's Open AI Settings… brings Settings forward on its AI tab. Prints the RUNLET_DEBUG_STATE
lines.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

from ai_stub import INVOICE, KEY, MASKED, STREAMING, Stub, seed_project

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
fixture = root / "Tests/Fixtures/laravel-app"
assert (fixture / "vendor/autoload.php").is_file(), "run scripts/setup-fixtures.sh"
assert shutil.which("php"), "needs PHP on PATH"

now = time.time() - 978307200  # Foundation's reference date


def launch(name: str, steps: list[str], shots: list[str], scenario: dict) -> tuple[list[str], list[dict]]:
    with tempfile.TemporaryDirectory(prefix="runlet-ai-", dir="/private/tmp") as scratch:
        scratch = Path(scratch)
        shop = scratch / "shop"
        subprocess.run(["cp", "-cR", str(fixture), str(shop)], check=True)
        seed_project(shop)
        state = scratch / "State"
        state.mkdir()

        def save(file, data):
            (state / f"{file}.json").write_text(json.dumps({"schemaVersion": 1, "savedAt": now, "data": data}))

        local_id = str(uuid.uuid4()).upper()
        save("settings", {"appearance": "light", "fontSize": 13})
        save("targets", {"localProjects": [{"id": local_id, "name": "shop", "path": str(shop), "revision": 1, "lastOpenedAt": now - 60}],
                         "dockerProfiles": [], "sshProfiles": []})
        save("session", {"tabs": [{"id": str(uuid.uuid4()).upper(), "title": "Invoice", "code": INVOICE, "target": {"local": {"_0": local_id}},
                                   "selection": {"location": 0, "length": 0}, "createdAt": now}]})
        stub = Stub(scratch / "stub", scenario)
        try:
            log_path = out / f"{name}.log"
            log_path.write_text("")
            subprocess.run(["open", "-g", "-j", "-n", "-W", "--env", f"RUNLET_DATA_DIR={scratch}", "--env", f"RUNLET_SNAPSHOT_DIR={out}",
                            "--env", f"RUNLET_DEBUG_STEPS={','.join(steps)}", "--env", f"RUNLET_AI_BASE_URL={stub.url}",
                            "--env", f"RUNLET_DEBUG_HOME={scratch}", "--env", "SSH_AUTH_SOCK=", "--stderr", str(log_path), str(app),
                            "--args", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"], check=True)
            requests = stub.requests()
        finally:
            stub.stop()
        log = log_path.read_text()
        assert "RUNLET_DEBUG_STEPS: done" in log, log[-3000:]
        states = [line for line in log.splitlines() if line.startswith("RUNLET_DEBUG_STATE")]
        for line in states:
            print(line)
        for shot in shots:
            assert (out / f"{shot}.png").is_file(), f"missing {shot}.png"
        # The made-up key never reaches the app's own lines (the step runner echoes the step that
        # types it).
        assert not any(KEY in line for line in log.splitlines() if not line.startswith("RUNLET_DEBUG_STEPS:")), "the key is in the log"
        return states, requests


def state(states: list[str], index: int) -> str:
    return [line for line in states if " ai provider=" in line][index]


start = ["ghost", "scale:2", "appearance:light", f"ai-key:anthropic={KEY}"]

# 1. Settings ▸ AI: the saved key, masked, after Test Key listed the account's models.
states, requests = launch("settings", start + [
    "ai-test:anthropic", "ai-wait:tested", "ai-state", "settings", "wait", "settings-tab:AI", "wait", "frame:AI=640x900", "wait",
    "shot:ai-settings-light@AI", "appearance:dark", "wait", "shot:ai-settings-dark@AI",
], ["ai-settings-light", "ai-settings-dark"], {})
assert f"anthropic: key=saved({MASKED}) test=ok(4 models)" in state(states, 0), state(states, 0)
assert [r["path"] for r in requests] == ["/v1/models"], requests
assert requests[0]["key"] == "present" and requests[0]["body"] is None

# 2. The error card's Explain or Fix…, the disclosure, the answer while it streams, the fix, Apply
#    Fix, and Undo Apply Fix.
states, requests = launch("explain", start + [
    "frame:1180x900", "select:Invoice", "run", "wait-run:120", "wait",
    "ai-explain:card", "ai-wait:sheet", "wait", "ai-state", "shot:ai-disclosure-light", "appearance:dark", "wait", "shot:ai-disclosure-dark",
    "appearance:light", "wait", "ai-send", "ai-wait:text", "wait", "ai-state", "shot:ai-streaming-light",
    "ai-wait:done:30", "wait", "ai-state", "shot:ai-fix-light", "appearance:dark", "wait", "shot:ai-fix-dark", "appearance:light", "wait",
    "ai-apply", "wait", "ai-state", "shot:ai-fix-applied-light", "ai-undo", "wait", "ai-state", "ai-close", "wait", "ai-state",
], ["ai-disclosure-light", "ai-disclosure-dark", "ai-streaming-light", "ai-fix-light", "ai-fix-dark", "ai-fix-applied-light"], STREAMING)
assert "sheet=review parts=[error=on,code=on,source=off]" in state(states, 0), state(states, 0)
assert "sheet=streaming" in state(states, 1), state(states, 1)
assert "sheet=finished" in state(states, 2) and "fix=yes" in state(states, 2) and "tabCode=unchanged" in state(states, 2), state(states, 2)
assert "applied=true" in state(states, 3) and "tabCode=changed autoRun=false" in state(states, 3), state(states, 3)
assert "applied=false" in state(states, 4) and "tabCode=unchanged" in state(states, 4), state(states, 4)
assert "sheet=none" in state(states, 5), state(states, 5)
sent = [r for r in requests if r["path"] == "/v1/messages"]
assert len(sent) == 1, requests
body = sent[0]["body"]
message = body["messages"][0]["content"]
assert body["model"] == "claude-opus-5-5" and body["stream"] is True and body["fallbacks"] == "default", body
assert "## The error" in message and "## The tab's PHP code" in message and "## The source" not in message, message
assert "Invoice line is negative" in message and "$lines = [1999, 2500, -300];" in message, message

# 3. No key: the disclosure says so, offers Settings ▸ AI, and can't send.
states, requests = launch("no-key", ["ghost", "scale:2", "appearance:light", "frame:1180x900", "select:Invoice", "run", "wait-run:120", "wait",
                                     "ai-explain", "ai-wait:sheet", "wait", "ai-state", "shot:ai-no-key-light",
                                     "press:explain-error-open-settings", "wait", "wait", "ai-windows"],
                          ["ai-no-key-light"], {})
assert "anthropic: key=none" in state(states, 0) and "sheet=review" in state(states, 0), state(states, 0)
assert requests == [], requests
# Open AI Settings… brings Settings forward on its AI tab, and leaves the sheet open.
windows = next(line for line in states if "ai-windows" in line)
assert 'front-to-back=["AI", "Runlet"] sheet=open' in windows, windows
print("ok: every check passed")

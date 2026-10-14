#!/usr/bin/env python3
"""#368, #44, #45: Settings ▸ AI, Explain or Fix Error, and the chat, from a Debug app with
scratch data.

Usage: ai-screenshots.py /path/to/Runlet.app /path/to/output [explain|chat|all]

Build the app with the screenshot bundle id first (docs/testing.md, "Checking the App"). The
script starts the AI providers' stand-in (scripts/ai_stub.py: `Tests/Fixtures/ai-stub/router.php`
under `php -S` on 127.0.0.1) and points the app at it with `RUNLET_AI_BASE_URL`, so nothing reaches Anthropic or
OpenAI. The key is made up, and a scratch `RUNLET_DATA_DIR` keeps it in memory, never in the
Keychain. The tab runs in a copy of the `laravel-app` fixture under /private/tmp, where a class
throws for a negative invoice line.

`explain` (#368, #44) takes, in light and dark where it matters: Settings ▸ AI with a saved
(masked) key that Test Key checked; the disclosure (what would be sent); the answer while it
streams; the proposed fix with Apply Fix; the fix applied; and the disclosure without a key. It
checks the steps' states and what the stand-in received: one request per Send, with only the parts
that were on; and that the sheet's Open AI Settings… brings Settings forward on its AI tab.

`chat` (#45) takes the chat: what a message with an @ file sends, the @ suggestions, a second
answer while it streams, the conversation, a code block inserted into the tab, the provider and
model picker with OpenAI unconfigured, the reasoning picker, the note before a provider switch,
and the chat without a key. It checks that each Send makes one request with the earlier turns
and only the checked context, that Insert into Tab changes the tab as one undoable edit with auto-run off, that
Stop keeps what arrived and sends it again, that Explain or Fix's Continue in Chat carries its
exchange over, that a provider without a key can't be chosen, that the reasoning level goes with
the next message, that switching providers and models sends the whole conversation as plain
text, that removing keys moves the chat or stops it, and that nothing is sent without a key.

Both by default. Prints the RUNLET_DEBUG_STATE lines.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

from ai_stub import (ANSWER, CHAT_ANSWERS, CHAT_FILE, CHAT_FIRST, CHAT_QUICK, CHAT_SECOND, CHAT_STREAMING, INVOICE, KEY, MASKED, STREAMING, Stub,
                     seed_project)

app = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
parts = {"explain", "chat"} if len(sys.argv) < 4 or sys.argv[3] == "all" else {sys.argv[3]}
out.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parent.parent
fixture = root / "Tests/Fixtures/laravel-app"
assert (fixture / "vendor/autoload.php").is_file(), "run scripts/setup-fixtures.sh"
assert shutil.which("php"), "needs PHP on PATH"

now = time.time() - 978307200  # Foundation's reference date


def launch(name: str, steps: list[str], shots: list[str], scenario: dict, settings: dict | None = None) -> tuple[list[str], list[dict]]:
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
        save("settings", {"appearance": "light", "fontSize": 13, **(settings or {})})
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
if "explain" in parts:
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


def chat_state(states: list[str], index: int) -> str:
    return [line for line in states if "RUNLET_DEBUG_STATE: chat " in line][index]


if "chat" in parts:
    # The chat beside the tab, at a width that shows its code blocks.
    wide = {"libraryPanelWidth": 440}
    first = CHAT_FIRST.replace(",", "\\c")

    # 4. A message with an @ file: what it sends (light and dark), the @ suggestions, the first
    #    answer, a second answer while it streams, the conversation, and Insert into Tab.
    states, requests = launch("chat", start + [
        "frame:1240x900", "select:Invoice", "run", "wait-run:120", "wait", "chat", "wait",
        "chat-type:Compare it with @invoice", "ai-wait:chat-index", "wait", "chat-state", "shot:chat-mention-light",
        f"chat-type:{first}", "chat-include:output=on", "ai-wait:chat-files", "wait",
        f"chat-expand:file:{CHAT_FILE}", "wait", "chat-state", "shot:chat-disclosure-light", "appearance:dark", "wait", "shot:chat-disclosure-dark",
        "appearance:light", "chat-collapse", "chat-send", "ai-wait:chat-done:30", "wait", "chat-state",
        f"chat-type:{CHAT_SECOND}", "chat-send", "ai-wait:chat-text", "wait", "chat-state", "shot:chat-streaming-light",
        "ai-wait:chat-done:30", "wait", "chat-state", "shot:chat-conversation-light", "appearance:dark", "wait", "shot:chat-conversation-dark",
        "appearance:light", "wait", "caret:end", "chat-insert", "wait", "chat-state", "shot:chat-inserted-light",
        # The pickers: OpenAI has no key, so it can't be chosen; the reasoning level applies to
        # the next message.
        "chat-provider:openai", "chat-picker:model", "wait", "chat-state", "shot:chat-model-picker-light", "appearance:dark", "wait",
        "shot:chat-model-picker-dark", "appearance:light", "chat-picker:effort", "wait", "shot:chat-effort-picker-light", "chat-picker:off",
        "chat-effort:xhigh", "chat-type:Shorter please.", "chat-send", "ai-wait:chat-done:30", "wait", "chat-state",
    ], ["chat-mention-light", "chat-disclosure-light", "chat-disclosure-dark", "chat-streaming-light", "chat-conversation-light",
        "chat-conversation-dark", "chat-inserted-light", "chat-model-picker-light", "chat-model-picker-dark", "chat-effort-picker-light"],
        CHAT_STREAMING, wide)
    assert "suggestions=[app/Services/InvoiceTotals.php" in chat_state(states, 0), chat_state(states, 0)
    typed = chat_state(states, 1)
    assert f"parts=[editor=on,output=on,file:{CHAT_FILE}=on]" in typed and "canSend=true" in typed, typed
    assert "turns=[complete:" in chat_state(states, 2) and "1code" in chat_state(states, 2), chat_state(states, 2)
    assert "turns=[complete:" in chat_state(states, 3) and "streaming(" in chat_state(states, 3), chat_state(states, 3)
    assert chat_state(states, 4).count("complete:") == 2 and "history=4" in chat_state(states, 4), chat_state(states, 4)
    inserted = chat_state(states, 5)
    assert "autoRun=false" in inserted and "undo=Insert into Tab" in inserted, inserted
    picker = chat_state(states, 6)
    assert "to=anthropic/claude-opus-5-5/default" in picker and 'configured=["anthropic"]' in picker and "picker=model" in picker, picker
    leveled = chat_state(states, 7)
    assert leveled.count("complete:") == 3 and "anthropic/claude-opus-5-5/xhigh]" in leveled, leveled
    sent = [r for r in requests if r["path"] == "/v1/messages"]
    assert len(sent) == 3, requests
    assert "output_config" not in sent[0]["body"] and sent[2]["body"]["output_config"] == {"effort": "xhigh"}, sent[2]["body"]
    sent = sent[:2]
    one, two = (r["body"]["messages"] for r in sent)
    assert [m["role"] for m in one] == ["user"] and [m["role"] for m in two] == ["user", "assistant", "user"], (one, two)
    message = one[0]["content"]
    for expected in ["## The tab's PHP code (“Invoice”)", "$lines = [1999, 2500, -300];", "## The last output, with its error (“Invoice”)",
                     "Invoice line is negative", f"## {CHAT_FILE}", "class InvoiceTotals", f"## Message\n\n{CHAT_FIRST}"]:
        assert expected in message, (expected, message)
    assert two[0]["content"] == message and two[1]["content"] == CHAT_ANSWERS[0], two
    assert two[2]["content"].endswith(f"## Message\n\n{CHAT_SECOND}"), two[2]
    assert sent[0]["body"]["model"] == "claude-opus-5-5" and sent[0]["body"]["stream"] is True, sent[0]["body"]

    # 5. Explain or Fix's answer continues in the chat; a follow-up streams and Stop keeps what
    #    arrived, which the next message sends again.
    slow = {"answer": ANSWER, "chunk": 9, "delay_ms": 25, "hold_after": 120, "hold_ms": 6000}
    states, requests = launch("chat-continue", start + [
        "frame:1240x900", "select:Invoice", "run", "wait-run:120", "wait", "ai-explain:card", "ai-wait:sheet", "wait", "ai-send",
        "ai-wait:done:40", "wait", "chat-continue", "wait", "chat-state",
        "chat-include:editor=off", "chat-type:And without the class?", "chat-send", "ai-wait:chat-text", "wait", "chat-stop", "wait", "chat-state",
        "chat-type:Go on.", "chat-send", "ai-wait:chat-done:40", "wait", "chat-state",
    ], [], slow, wide)
    assert "shown=true" in chat_state(states, 0) and "turns=[complete:" in chat_state(states, 0) and "history=2" in chat_state(states, 0), chat_state(states, 0)
    assert "stopped:" in chat_state(states, 1), chat_state(states, 1)
    assert "history=6" in chat_state(states, 2), chat_state(states, 2)
    sent = [r for r in requests if r["path"] == "/v1/messages"]
    assert len(sent) == 3, requests
    explain, follow, last = (r["body"]["messages"] for r in sent)
    assert follow[0]["content"] == explain[0]["content"] and "## The tab's PHP code" not in follow[2]["content"], follow
    assert [m["role"] for m in last] == ["user", "assistant", "user", "assistant", "user"], last
    assert 0 < len(last[3]["content"]) < len(ANSWER), last[3]

    # 6. Switching providers mid-conversation: the whole conversation, with what went with each
    #    message, goes to the other provider as plain text; then a model switch on the same
    #    provider, and back. Removing the chosen provider's key moves the chat to the other one,
    #    and with no key left nothing is sent.
    openai_key = "sk-proj-EXAMPLE-not-a-real-key-0000"
    states, requests = launch("chat-switch", start + [
        f"ai-key:openai={openai_key}", "frame:1240x900", "select:Invoice", "chat", "wait",
        "chat-type:Why does it throw?", "chat-send", "ai-wait:chat-done:30", "wait",
        "chat-provider:openai", "chat-type:And in dollars?", "wait", "chat-state", "shot:chat-switch-light",
        "chat-send", "ai-wait:chat-done:30", "wait", "chat-model:gpt-6-luna", "chat-effort:none", "chat-type:Shorter?", "chat-send", "ai-wait:chat-done:30", "wait",
        "chat-provider:anthropic", "chat-type:Thanks. One more?", "chat-send", "ai-wait:chat-done:30", "wait", "chat-state",
        "chat-provider:openai", "ai-remove:openai", "wait", "chat-state", "ai-remove:anthropic", "wait", "chat-type:Anyone?", "chat-send", "wait", "chat-state",
        "shot:chat-no-provider-light",
    ], ["chat-switch-light", "chat-no-provider-light"], CHAT_QUICK, wide)
    switched = chat_state(states, 0)
    assert "to=openai/gpt-6-astra/default" in switched and "switch=anthropic/claude-opus-5-5" in switched and "canSend=true" in switched, switched
    after = chat_state(states, 1)
    assert after.count("complete:") == 4 and "history=8" in after, after
    for turn in ["anthropic/claude-opus-5-5/default", "openai/gpt-6-astra/default", "openai/gpt-6-luna/none", "anthropic/claude-opus-5-5/default]"]:
        assert turn in after, (turn, after)
    assert "to=anthropic/" in chat_state(states, 2), chat_state(states, 2)
    gone = chat_state(states, 3)
    assert "to=none" in gone and "key=false" in gone and gone.count("complete:") == 4, gone
    sent = [r for r in requests if r["method"] == "POST"]
    assert [r["path"] for r in sent] == ["/v1/messages", "/v1/responses", "/v1/responses", "/v1/messages"], [r["path"] for r in sent]
    first, to_openai, luna, back = (r["body"] for r in sent)
    assert to_openai["model"] == "gpt-6-astra" and "reasoning" not in to_openai and to_openai["store"] is False, to_openai
    roles = [m["role"] for m in to_openai["input"]]
    assert roles == ["user", "assistant", "user"], roles
    assert to_openai["input"][0]["content"] == first["messages"][0]["content"] and "## The tab's PHP code" in to_openai["input"][0]["content"], to_openai
    assert to_openai["input"][1]["content"] == CHAT_ANSWERS[0], to_openai
    assert all(set(m) == {"role", "content"} and isinstance(m["content"], str) for m in to_openai["input"] + back["messages"]), (to_openai, back)
    assert luna["model"] == "gpt-6-luna" and luna["reasoning"] == {"effort": "none"} and len(luna["input"]) == 5, luna
    assert back["model"] == "claude-opus-5-5" and [m["role"] for m in back["messages"]] == ["user", "assistant"] * 3 + ["user"], back
    for body in (to_openai, luna, back):
        text = json.dumps(body)
        assert all(opaque not in text for opaque in ["thinking", "signature", "rs_stub", "msg_stub", "previous_response_id"]), text

    # 7. No key: the chat says so, offers Settings ▸ AI, and sends nothing.
    states, requests = launch("chat-no-key", ["ghost", "scale:2", "appearance:light", "frame:1240x900", "select:Invoice", "chat", "wait",
                                              "chat-type:What does this tab do?", "wait", "chat-send", "wait", "chat-state", "shot:chat-no-key-light",
                                              "press:chat-open-settings", "wait", "wait", "ai-windows"],
                              ["chat-no-key-light"], {}, wide)
    assert "key=false" in chat_state(states, 0) and "turns=[]" in chat_state(states, 0), chat_state(states, 0)
    assert requests == [], requests
    windows = next(line for line in states if "ai-windows" in line)
    assert 'front-to-back=["AI", "Runlet"]' in windows, windows

print("ok: every check passed")

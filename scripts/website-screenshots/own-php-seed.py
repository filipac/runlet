#!/usr/bin/env python3
"""Writes a scratch Runlet data folder for shoot-own-php.sh: one sandbox tab with a demo snippet,
and a Docker CLI that finds no engine.

Usage: own-php-seed.py <data dir> <fake docker CLI>
Never touches ~/Library/Application Support/Runlet.
"""
import json
import os
import sys
import time
import uuid

data, fake_docker = sys.argv[1], sys.argv[2]
state = os.path.join(data, "State")
os.makedirs(state, exist_ok=True)
now = time.time() - 978307200  # Foundation reference date


def write(name, value):
    with open(os.path.join(state, name + ".json"), "w") as f:
        json.dump({"schemaVersion": 1, "savedAt": now, "data": value}, f, indent=2)


write("settings", {
    "fontSize": 14,
    "editorSplitRight": 0.55,
    "dockerExecutable": fake_docker,
    "inlayHints": False,
})

CODE = """// No PHP, no Docker: Runlet brought its own.
use Illuminate\\Support\\Facades\\DB;
use Illuminate\\Support\\Number;

[
    'php' => PHP_VERSION,
    'build' => basename(dirname(PHP_BINARY, 2)),
    'intl' => Number::currency(1234.5, 'EUR', 'de'),
    'sqlite' => DB::scalar('select sqlite_version()'),
    'mongodb' => extension_loaded('mongodb'),
    'sodium' => extension_loaded('sodium'),
    'extensions' => count(get_loaded_extensions()),
];
"""
tab = {
    "id": str(uuid.uuid4()).upper(), "title": "Scratch", "code": CODE, "target": {"sandbox": {}},
    "selection": {"location": len(CODE), "length": 0}, "createdAt": now - 60,
}
write("session", {"windows": [{"id": str(uuid.uuid4()).upper(), "tabs": [tab], "selectedTabId": tab["id"], "workspaceEdited": False}]})
print(f"seeded {data}")

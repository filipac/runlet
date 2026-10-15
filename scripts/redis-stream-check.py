#!/usr/bin/env python3
"""#203: hidden live Redis stream checks and PR screenshots, using only runlet-fixtures.
Usage: scripts/redis-stream-check.py [path/to/Runlet.app] [shot-name]
Artifacts and scratch data stay in this worktree's build/issue-203-shots.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parent.parent
APP = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'build/DerivedData/Build/Products/Debug/Runlet.app'
OUT = ROOT / 'build/issue-203-shots'
OUT.mkdir(parents=True, exist_ok=True)
port = subprocess.check_output(['docker', 'compose', '-p', 'runlet-fixtures', '-f', str(ROOT / 'Tests/Fixtures/docker/compose.yml'), 'port', 'redis', '6379'], text=True).strip().rsplit(':', 1)[1]


def shoot(name, command, steps):
    if len(sys.argv) > 2 and sys.argv[2] != name:
        return None
    data = OUT / (name + '-data')
    state = data / 'State'
    state.mkdir(parents=True, exist_ok=True)
    tabid = str(uuid.uuid4()).upper()
    tab = {'id': tabid, 'title': 'Live Events', 'code': command, 'target': {'sandbox': {}},
           'language': 'redis', 'selection': {'location': 0, 'length': 0}, 'createdAt': 0}
    def save(key, value):
        (state / (key + '.json')).write_text(json.dumps({'schemaVersion': 1, 'savedAt': 0, 'data': value}))
    save('session', {'windows': [{'id': str(uuid.uuid4()).upper(), 'tabs': [tab], 'selectedTabId': tabid}]})
    save('settings', {'appearance': 'light', 'fontSize': 13, 'languageServiceEnabled': False,
                      'outputVisible': True, 'editorSplitBottom': 0.24, 'dockerExecutable': str(ROOT / 'Tests/Fixtures/fake-docker/docker')})
    common = ['ghost', 'frame:1200x940', 'appearance:light',
              f'db-new:Shop cache|redis|127.0.0.1|{port}|0||runlet-fixture|mac', 'db-use:Shop cache', 'wait']
    log = OUT / (name + '.log')
    subprocess.run(['open', '-g', '-j', '-n', '-W', '--env', f'RUNLET_DATA_DIR={data}',
                    '--env', f'RUNLET_SNAPSHOT_DIR={OUT}', '--env', 'SSH_AUTH_SOCK=',
                    '--env', f'RUNLET_DEBUG_STEPS={",".join(common + steps)}',
                    '--stderr', str(log), str(APP)], check=True, timeout=150)
    text = log.read_text()
    assert 'RUNLET_DEBUG_STEPS: done' in text and 'no window' not in text, text[-5000:]
    assert (OUT / (name + '.png')).exists(), text[-5000:]
    print(name + ': ' + '\n'.join(x for x in text.splitlines() if 'redis-stream-state:' in x), flush=True)
    return text


text = shoot('subscribe-json', 'SUBSCRIBE orders', [
    'redis-stream-start', 'wait', 'redis-stream-publish:orders|3', 'redis-stream-wait:messages=3',
    'redis-stream-expand', 'shot:subscribe-json', 'redis-stream-pause', 'redis-stream-publish:orders|2',
    'redis-stream-wait:messages=5', 'redis-stream-state', 'redis-stream-resume', 'redis-stream-state',
    'redis-stream-clear', 'redis-stream-state', 'redis-stream-stop', 'wait-run', 'redis-stream-state'])
if text is not None:
    assert 'paused=true' in text and 'visible=0' in text and 'stopped' in text, text
shoot('pattern', 'PSUBSCRIBE orders.*', ['redis-stream-start', 'wait', 'redis-stream-publish:orders.created|3',
      'redis-stream-wait:messages=3', 'shot:pattern', 'redis-stream-stop', 'wait-run'])
shoot('monitor-confirmation', 'MONITOR', ['redis-danger:ask', 'redis-stream-start', 'wait',
      'shot:monitor-confirmation@sheet', 'redis-danger:cancel'])
shoot('monitor', 'MONITOR', ['redis-danger:yes', 'redis-stream-start', 'wait', 'redis-stream-publish:orders.created|3',
      'redis-stream-wait:messages=3', 'shot:monitor', 'redis-stream-stop', 'wait-run'])
shoot('limit-ended', 'SUBSCRIBE orders', ['redis-stream-limit:4', 'redis-stream-start', 'wait-run',
      'redis-stream-state', 'shot:limit-ended'])
shoot('connection-manager', 'SUBSCRIBE orders', ['redis-stream-start', 'wait', 'redis-stream-publish:orders|3',
      'redis-stream-wait:messages=3', 'connections', 'connections-state', 'wait',
      'shot:connection-manager@Connections', 'redis-stream-stop', 'wait-run'])

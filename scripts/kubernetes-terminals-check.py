#!/usr/bin/env python3
"""#373: hidden app checks and screenshots using only fake kubectl and scratch state.
Usage: scripts/kubernetes-terminals-check.py build/DerivedData/Build/Products/Debug/Runlet.app [scenario]
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]).resolve()
assert subprocess.check_output(['/usr/libexec/PlistBuddy', '-c', 'Print CFBundleIdentifier', str(app / 'Contents/Info.plist')], text=True).strip() == 'dev.runlet.Runlet.prshots'
out = root / 'build/issue-373-screenshots'
out.mkdir(parents=True, exist_ok=True)


def launch(name, steps, *, production=False, container='app', interchangeable=True):
    scratch = root / 'build' / ('issue-373-' + name + '-' + uuid.uuid4().hex[:8])
    state = scratch / 'State'
    state.mkdir(parents=True)
    # Keep the host login shell's startup files and title neutral in scratch screenshots.
    (scratch / '.zshrc').write_text("PROMPT='Local shell % '\nprintf '\\033]2;Local Shell\\007'\n")
    config = scratch / 'ssh-config'
    config.write_text('Host *\n  IdentityAgent none\n  IdentitiesOnly yes\n  IdentityFile none\n')
    now = time.time() - 978307200
    def save(name, data):
        (state / (name + '.json')).write_text(json.dumps({'schemaVersion': 1, 'savedAt': now, 'data': data}))
    profile_id = str(uuid.uuid4()).upper()
    save('settings', {'appearance': 'light', 'fontSize': 14, 'languageServiceEnabled': False,
                      'sandboxRuntime': 'localPHP', 'defaultPHPExecutable': shutil.which('php'), 'terminalVisible': True,
                      'dockerExecutable': str(root / 'Tests/Fixtures/fake-docker/docker'),
                      'kubectlExecutable': str(root / 'Tests/Fixtures/fake-kubectl/kubectl')})
    save('targets', {'kubernetesProfiles': [{'id': profile_id, 'name': 'Shop', 'context': 'example', 'namespace': 'shop',
         'labelSelector': 'app=shop', 'container': container, 'workingDirectory': '/tmp', 'phpExecutable': 'php',
         'temporaryDirectory': '/tmp', 'environment': 'production' if production else 'development', 'autoResolve': True,
         'interchangeableReplicas': interchangeable, 'revision': 1}]})
    save('session', {'tabs': [{'id': str(uuid.uuid4()).upper(), 'title': 'Shop', 'code': "// Commands and shells run in the chosen pod.\napp()->version();",
         'target': {'kubernetes': {'_0': profile_id}}, 'selection': {'location': 0, 'length': 0}, 'createdAt': now}]})
    log = out / (name + '.log')
    log.write_text('')
    args = ['open', '-g', '-j', '-n', '-W', '--env', f'RUNLET_DATA_DIR={scratch}', '--env', f'RUNLET_SNAPSHOT_DIR={out}',
            '--env', f'RUNLET_DEBUG_HOME={scratch}', '--env', f'ZDOTDIR={scratch}', '--env', f'RUNLET_SSH_CONFIG={config}', '--env', 'SSH_AUTH_SOCK=',
            '--env', f'RUNLET_TEST_KUBE_LOG={scratch}/kubectl.jsonl', '--env', f'RUNLET_SSH_EXECUTABLE={root}/Tests/Fixtures/fake-ssh/ssh',
            '--env', 'RUNLET_DEBUG_STEPS=' + ','.join(['ghost', 'frame:1100x760', 'inspector:commands'] + steps + ['kubernetes:terminal-state']),
            '--stderr', str(log), str(app)]
    subprocess.run(args, check=True, timeout=150)
    text = log.read_text()
    assert 'RUNLET_DEBUG_STEPS: done' in text and 'no window' not in text, text[-3000:]
    assert 'key=true' not in text, 'Hidden app must never have a key window'
    calls_file = scratch / 'kubectl.jsonl'
    calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
    print(name + ': ' + '\n'.join(line for line in text.splitlines() if line.startswith('RUNLET_DEBUG_STATE:')), flush=True)
    return text, calls


def check(name):
    if name == 'restore':
        text, calls = launch(name, ['pause:3'])
        assert not calls, calls
        assert 'terminals=1 local:' in text, text
    elif name == 'command':
        text, calls = launch(name, ['kubernetes:command', 'pause:2', 'kubernetes:terminal-state', 'shot:kubernetes-command-v3',
                                   'kubernetes:again', 'pause:2', 'kubernetes:terminal-state',
                                   'kubernetes:production', 'kubernetes:again', 'kubernetes:terminal-state', 'shot:kubernetes-rerun-production-v3@sheet', 'cancel'])
        assert sum('-it' in call for call in calls) == 2, calls
        assert 'terminals=3' in text and 'pending=true' in text, text
        assert sum('get' in call and 'pod' in call for call in calls) == 4, calls
    elif name == 'production':
        text, calls = launch(name, ['kubernetes:command', 'kubernetes:terminal-state', 'cancel',
                                   'perform:project.openREPL', 'kubernetes:terminal-state', 'cancel',
                                   'perform:kubernetes.openShell', 'kubernetes:terminal-state', 'cancel', 'tests:all'], production=True)
        assert not calls, calls
        assert text.count('pending=true') == 3 and 'terminals=1' in text, text
    elif name == 'shell':
        text, calls = launch(name, ['perform:kubernetes.openShell', 'pause:2', 'terminal:printf "Pod shell ready\\n"\\n',
                                   'pause:1', 'shot:kubernetes-shell-v3', 'terminal:exit\\n'])
        assert sum('-it' in call for call in calls) == 1, calls
    elif name == 'missing-shell':
        text, calls = launch(name, ['kubernetes:command', 'pause:2'], container='no-shell')
        assert 'This container has no shell' in text and 'terminals=1' in text, text
        assert not any('-it' in call for call in calls), calls
    elif name == 'ambiguous':
        text, calls = launch(name, ['kubernetes:command', 'pause:2', 'kubernetes:state', 'kubernetes:confirm', 'pause:2',
                                   'kubernetes:terminal-state', 'kubernetes:command', 'pause:2'], interchangeable=False)
        assert 'choice=shop-app-a,shop-app-b' in text, text
        assert 'terminals=1' in text and sum('-it' in call for call in calls) == 1, (text, calls)
    elif name == 'repl-tests':
        text, calls = launch(name, ['perform:project.openREPL', 'pause:2', 'terminal:echo 6 * 7;\\n', 'terminal:exit\\n',
                                   'tests:all', 'pause:2'])
        assert sum('-it' in call for call in calls) == 2, calls
    elif name == 'needs-input':
        text, calls = launch(name, ['kubernetes:needs-input', 'pause:2', 'kubernetes:terminal-state', 'terminal:\\n', 'pause:2', 'terminal:exit\\n'])
        assert sum('-it' in call for call in calls) == 1, calls
        assert 'pod:running' in text, text
    elif name == 'menu':
        text, calls = launch(name, ['kubernetes:command', 'pause:2', 'kubernetes-menu-shot:kubernetes-terminal-menu-v3', 'pause:2'])
        assert (out / 'kubernetes-terminal-menu-v3.png').is_file(), text


for name in ([sys.argv[2]] if len(sys.argv) > 2 else ['restore', 'command', 'production', 'shell', 'missing-shell', 'ambiguous', 'repl-tests', 'needs-input', 'menu']):
    check(name)
print(out)

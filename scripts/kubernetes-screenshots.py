#!/usr/bin/env python3
"""#33: editor, searchable pod list, ambiguity, and a PHP run using fake kubectl only.
Usage: scripts/kubernetes-screenshots.py build/DerivedData/Build/Products/Debug/Runlet.app
Uses the screenshot bundle id, ghost windows, and issue-specific scratch data under build/.
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
bundle_id = subprocess.check_output(['/usr/libexec/PlistBuddy', '-c', 'Print CFBundleIdentifier', str(app / 'Contents/Info.plist')], text=True).strip()
assert bundle_id == 'dev.runlet.Runlet.prshots', 'Use the isolated screenshot build'
out = root / 'build/issue-33-screenshots'
out.mkdir(parents=True, exist_ok=True)


def launch(name, steps, shots):
    scratch = root / 'build' / ('issue-33-shots-' + name + '-' + uuid.uuid4().hex[:8])
    state = scratch / 'State'
    state.mkdir(parents=True)
    config = scratch / 'ssh-config'
    config.write_text('Host *\n  IdentityAgent none\n  IdentitiesOnly yes\n  IdentityFile none\n')
    now = time.time() - 978307200
    def save(name, data):
        (state / (name + '.json')).write_text(json.dumps({'schemaVersion': 1, 'savedAt': now, 'data': data}))
    profile_id = str(uuid.uuid4()).upper()
    save('settings', {'appearance': 'light', 'fontSize': 14, 'languageServiceEnabled': False,
                      'sandboxRuntime': 'localPHP', 'defaultPHPExecutable': shutil.which('php'),
                      'dockerExecutable': str(root / 'Tests/Fixtures/fake-docker/docker'),
                      'kubectlExecutable': str(root / 'Tests/Fixtures/fake-kubectl/kubectl')})
    save('targets', {'kubernetesProfiles': [{'id': profile_id, 'name': 'Shop', 'context': 'example', 'namespace': 'shop',
         'labelSelector': 'app=shop', 'container': 'app', 'workingDirectory': '/tmp', 'phpExecutable': 'php',
         'temporaryDirectory': '/tmp', 'autoResolve': False, 'interchangeableReplicas': False, 'revision': 1}]})
    save('session', {'tabs': [{'id': str(uuid.uuid4()).upper(), 'title': 'Pod Check',
         'code': "dump(['application' => 'shop', 'status' => 'ready']);\n['orders' => 42, 'currency' => 'EUR']",
         'target': {'kubernetes': {'_0': profile_id}}, 'selection': {'location': 0, 'length': 0}, 'createdAt': now}]})
    log = out / (name + '.log')
    args = ['open', '-g', '-j', '-n', '-W', '--env', f'RUNLET_DATA_DIR={scratch}', '--env', f'RUNLET_SNAPSHOT_DIR={out}',
            '--env', f'RUNLET_DEBUG_HOME={scratch}', '--env', f'RUNLET_SSH_CONFIG={config}', '--env', 'SSH_AUTH_SOCK=',
            '--env', f'RUNLET_SSH_EXECUTABLE={root}/Tests/Fixtures/fake-ssh/ssh',
            '--env', 'RUNLET_DEBUG_STEPS=' + ','.join(['ghost', 'frame:1100x760'] + steps), '--stderr', str(log), str(app)]
    subprocess.run(args, check=True, timeout=150)
    text = log.read_text()
    assert 'RUNLET_DEBUG_STEPS: done' in text, text[-3000:]
    assert 'no window' not in text
    for shot in shots:
        assert (out / (shot + '.png')).is_file(), text[-3000:]
    print('\n'.join(line for line in text.splitlines() if line.startswith('RUNLET_DEBUG_STATE:')))
    return text

launch('editor', ['kubernetes:editor', 'frame:Profiles=1100x900', 'shot:kubernetes-editor@Profiles',
                  'kubernetes:list', 'pause:2', 'shot:kubernetes-pods@Profiles'], ['kubernetes-editor', 'kubernetes-pods'])
result = launch('run', ['kubernetes:choose', 'pause:2', 'kubernetes:state', 'shot:kubernetes-choice@sheet',
                       'kubernetes:confirm', 'run', 'wait-run', 'state', 'shot:kubernetes-run'], ['kubernetes-choice', 'kubernetes-run'])
assert 'shop-app-a,shop-app-b' in result, result[-3000:]
assert 'completed' in result, result[-3000:]
print(out)

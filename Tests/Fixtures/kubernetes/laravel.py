#!/usr/bin/env python3
"""#33: build a local-only hostPath fixture from this checkout, never a private project."""
import json
from pathlib import Path
root = Path(__file__).resolve().parents[3]
print(json.dumps({
    'apiVersion': 'v1', 'kind': 'Pod',
    'metadata': {'name': 'runlet-laravel', 'namespace': 'runlet-fixtures',
                 'labels': {'app': 'runlet-laravel', 'runlet.fixture': 'kubernetes'}},
    'spec': {
        'containers': [{'name': 'app', 'image': 'php:8.4-cli', 'imagePullPolicy': 'Never',
                        'command': ['sleep', 'infinity'],
                        'volumeMounts': [{'name': 'app', 'mountPath': '/app'}]}],
        'volumes': [{'name': 'app', 'hostPath': {'path': str(root / 'Tests/Fixtures/laravel-app'), 'type': 'Directory'}}]
    }
}))

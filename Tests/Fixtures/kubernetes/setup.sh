#!/usr/bin/env bash
# #33: only the disposable local namespace, never current-context or image pulls.
set -euo pipefail
export SSH_AUTH_SOCK=
KUBE=(kubectl --context orbstack --namespace runlet-fixtures)
if [[ "${1:-}" == kubernetes-down ]]; then
    "${KUBE[@]}" delete namespace runlet-fixtures --ignore-not-found --wait=true --timeout=90s
    exit
fi
for image in php:8.4-cli php:8.2-cli-alpine php:7.4-cli; do
    docker image inspect "$image" >/dev/null || { echo "Missing local image $image; no image was pulled." >&2; exit 1; }
done
"${KUBE[@]}" apply -f "$(dirname "$0")/fixtures.yaml"
python3 "$(dirname "$0")/laravel.py" | "${KUBE[@]}" apply -f -
"${KUBE[@]}" wait --for=condition=Ready pod -l runlet.fixture=kubernetes --timeout=120s
echo 'export RUNLET_TEST_KUBE_CONTEXT=orbstack'

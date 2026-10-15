#!/usr/bin/env bash
# #33: only the disposable local namespace, never current-context or image pulls.
set -euo pipefail
export SSH_AUTH_SOCK=
if [[ -z "${RUNLET_TEST_KUBE_CONTEXT:-}" ]]; then
    echo 'Set RUNLET_TEST_KUBE_CONTEXT to your disposable local cluster context; current-context is never used.' >&2
    exit 1
fi
KUBE=(kubectl --context "$RUNLET_TEST_KUBE_CONTEXT" --namespace runlet-fixtures)
printf 'export RUNLET_TEST_KUBE_CONTEXT=%q\n' "$RUNLET_TEST_KUBE_CONTEXT"
if [[ "${1:-}" == kubernetes-down ]]; then
    "${KUBE[@]}" delete namespace runlet-fixtures --ignore-not-found --wait=true --timeout=90s
    exit
fi
echo 'Checking Docker images: the cluster must share Docker’s image store (OrbStack or Docker Desktop). kind and minikube need images loaded separately; this script never pulls or loads images.'
for image in php:8.4-cli php:8.2-cli-alpine php:7.4-cli; do
    docker image inspect "$image" >/dev/null || { echo "Missing local image $image; no image was pulled." >&2; exit 1; }
done
"${KUBE[@]}" apply -f "$(dirname "$0")/fixtures.yaml"
python3 "$(dirname "$0")/laravel.py" | "${KUBE[@]}" apply -f -
"${KUBE[@]}" wait --for=condition=Ready pod -l runlet.fixture=kubernetes --timeout=120s

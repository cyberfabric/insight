#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TENANT="${1:-}"
echo "=== Updating connections ==="

# Build toolbox with latest project files
echo "  Building toolbox..."
./tools/toolbox/build.sh 2>&1 | tail -1

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kind-ingestion}"

ARGS="${TENANT:---all}"
kubectl delete pod update-connections -n data --ignore-not-found 2>/dev/null
kubectl run update-connections \
  --restart=Never \
  --image=insight-toolbox:local \
  --image-pull-policy=Never \
  -n data \
  --env="AIRBYTE_API=http://airbyte-airbyte-server-svc.airbyte.svc.cluster.local:8001" \
  --command -- bash -c "
    cd /ingestion
    source ./scripts/resolve-airbyte-env.sh 2>&1
    ./scripts/apply-connections.sh ${ARGS} 2>&1
  "

echo "  Waiting..."
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/update-connections -n data --timeout=180s 2>/dev/null || {
  kubectl logs update-connections -n data --tail=20 2>&1
}
kubectl delete pod update-connections -n data --ignore-not-found 2>/dev/null

echo "=== Done ==="

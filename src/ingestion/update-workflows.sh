#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

TENANT="${1:-}"
echo "=== Updating workflows ==="

# Build toolbox with latest project files
echo "  Building toolbox..."
./tools/toolbox/build.sh 2>&1 | tail -1

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kind-ingestion}"

ARGS="${TENANT:---all}"
kubectl delete pod update-workflows -n data --ignore-not-found 2>/dev/null
kubectl run update-workflows \
  --restart=Never \
  --image=insight-toolbox:local \
  --image-pull-policy=Never \
  -n data \
  --env="AIRBYTE_API=http://airbyte-airbyte-server-svc.airbyte.svc.cluster.local:8001" \
  --command -- bash -c "
    cd /ingestion
    ./scripts/sync-flows.sh ${ARGS} 2>&1
  "

echo "  Waiting..."
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/update-workflows -n data --timeout=60s 2>/dev/null || {
  kubectl logs update-workflows -n data --tail=20 2>&1
}
kubectl delete pod update-workflows -n data --ignore-not-found 2>/dev/null

echo "=== Done ==="

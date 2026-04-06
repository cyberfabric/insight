#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

echo "=== Updating connectors ==="

# Build toolbox with latest project files
echo "  Building toolbox..."
./tools/toolbox/build.sh 2>&1 | tail -1

# Run upload inside cluster
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kind-ingestion}"

kubectl delete pod update-connectors -n data --ignore-not-found 2>/dev/null
kubectl run update-connectors \
  --restart=Never \
  --image=insight-toolbox:local \
  --image-pull-policy=Never \
  -n data \
  --env="AIRBYTE_API=http://airbyte-airbyte-server-svc.airbyte.svc.cluster.local:8001" \
  --command -- bash -c '
    cd /ingestion
    source ./scripts/resolve-airbyte-env.sh 2>&1
    ./scripts/upload-manifests.sh --all 2>&1
  '

echo "  Waiting..."
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/update-connectors -n data --timeout=120s 2>/dev/null || {
  kubectl logs update-connectors -n data --tail=20 2>&1
}
kubectl delete pod update-connectors -n data --ignore-not-found 2>/dev/null

echo "=== Done ==="

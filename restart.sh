#!/usr/bin/env bash
# Quick restart of the Insight Kind cluster after WSL crash / Docker restart.
# Unlike up.sh, this only restarts existing infrastructure — no helm installs.
# If the cluster is gone, falls back to full up.sh + run-init.sh.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="insight"
COMPONENT="${1:-ingestion}"

# --- Clean up ghost containers from crashed sessions ---
echo "=== Cleaning up stale containers ==="
for c in $(docker ps -a --filter "status=exited" --filter "name=kind" --format '{{.Names}}' 2>/dev/null); do
  echo "  Removing dead container: $c"
  docker rm -f "$c" 2>/dev/null || true
done

# Also remove any old 'ingestion' Kind cluster that might hold ports
if kind get clusters 2>/dev/null | grep -q "^ingestion$"; then
  echo "  Deleting stale 'ingestion' Kind cluster..."
  kind delete cluster --name ingestion
fi

# --- Check if the insight cluster still exists ---
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "=== Restarting existing Kind cluster '${CLUSTER_NAME}' ==="
  docker start "${CLUSTER_NAME}-control-plane" 2>/dev/null || true
  sleep 5

  KUBECONFIG_PATH="${HOME}/.kube/insight.kubeconfig"
  kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}" 2>/dev/null || true
  export KUBECONFIG="${KUBECONFIG_PATH}"

  echo "  Waiting for API server..."
  kubectl cluster-info --request-timeout=30s 2>/dev/null && {
    echo "  Cluster is up. Scaling services back to 1..."

    # ClickHouse
    kubectl scale deployment/clickhouse -n data --replicas=1 2>/dev/null || true
    # Argo
    kubectl scale deployment -n argo --all --replicas=1 2>/dev/null || true
    # Airbyte
    kubectl scale statefulset -n airbyte --all --replicas=1 2>/dev/null || true
    kubectl scale deployment -n airbyte --all --replicas=1 2>/dev/null || true
    # App services
    kubectl scale deployment -n insight --all --replicas=1 2>/dev/null || true

    echo "  Waiting for key pods..."
    kubectl wait --for=condition=ready pod -l app=clickhouse -n data --timeout=120s 2>/dev/null || echo "  WARNING: ClickHouse not ready"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argo-workflows-server -n argo --timeout=120s 2>/dev/null || echo "  WARNING: Argo not ready"

    # Airbyte port-forward
    pkill -f 'port-forward.*airbyte' 2>/dev/null || true
    nohup kubectl -n airbyte port-forward svc/airbyte-airbyte-server-svc 8001:8001 >/dev/null 2>&1 &
    disown

    echo ""
    echo "=== Restart complete ==="
    echo "  Airbyte:    http://localhost:8001"
    echo "  Argo UI:    http://localhost:30500"
    echo "  ClickHouse: http://localhost:30123"
    exit 0
  }

  echo "  Cluster not responding — will recreate."
  kind delete cluster --name "${CLUSTER_NAME}"
fi

# --- Fallback: full setup ---
echo "=== Cluster not found — running full up.sh ${COMPONENT} ==="

# Clean up stuck helm releases that block reinstall
for ns_release in "airbyte:airbyte" "argo:argo-workflows"; do
  ns="${ns_release%%:*}"
  release="${ns_release##*:}"
  status=$(helm status "$release" -n "$ns" -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('info',{}).get('status',''))" 2>/dev/null || true)
  if [[ "$status" == pending-* ]]; then
    echo "  Cleaning stuck helm release: $release ($status)"
    helm uninstall "$release" -n "$ns" --no-hooks 2>/dev/null || true
  fi
done

"$ROOT_DIR/up.sh" "$COMPONENT"

echo ""
echo "=== Running init (databases, connectors, connections)... ==="
cd "$ROOT_DIR/src/ingestion"
./secrets/apply.sh
./run-init.sh

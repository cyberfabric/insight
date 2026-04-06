#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV="${ENV:-local}"
CLUSTER_NAME="ingestion"
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/kind-ingestion}"

if [[ "$ENV" == "local" ]]; then
  kind export kubeconfig --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}" 2>/dev/null || true
fi

export KUBECONFIG="${KUBECONFIG_PATH}"

echo "=== Stopping services (data preserved) ==="

# Stop Argo workflows
echo "  Stopping Argo workflows..."
kubectl scale deployment -n argo --all --replicas=0 2>/dev/null || true

# Stop ClickHouse
echo "  Stopping ClickHouse..."
kubectl scale deployment/clickhouse -n data --replicas=0 2>/dev/null || true

# Stop Airbyte
echo "  Stopping Airbyte..."
kubectl scale deployment -n airbyte --all --replicas=0 2>/dev/null || true
kubectl scale statefulset -n airbyte --all --replicas=0 2>/dev/null || true

# Stop port-forward
pkill -f 'port-forward.*airbyte' 2>/dev/null || true

# Stop Kind cluster (local only) — preserves all data inside
if [[ "$ENV" == "local" ]]; then
  echo "  Stopping Kind cluster..."
  docker stop "${CLUSTER_NAME}-control-plane" 2>/dev/null || true
fi

echo "=== Done (data preserved, run up.sh to restart) ==="

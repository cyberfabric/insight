#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV="${ENV:-local}"
CLUSTER_NAME="ingestion"

echo "=== WARNING: This will DELETE all data and the cluster ==="
read -p "Are you sure? [y/N] " -r
[[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

if [[ "$ENV" == "local" ]]; then
  echo "  Deleting Kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}" 2>/dev/null || true
  rm -f "${HOME}/.kube/kind-${CLUSTER_NAME}" "${HOME}/.kube/ingestion.kubeconfig"
fi

# Kill port-forwards
pkill -f 'port-forward.*airbyte' 2>/dev/null || true

# Clean Airbyte state
rm -f connections/.airbyte-state.yaml 2>/dev/null || true

# Clean generated workflows
rm -rf workflows/example-tenant 2>/dev/null || true

echo "=== Cleaned. Run up.sh for fresh install ==="

#!/usr/bin/env bash
# Initialize the ingestion stack: create databases, register connectors, apply connections, sync workflows.
# Runs from the host machine (requires kubectl, curl, node, python3).
# Run AFTER: ./dev-up.sh && ./secrets/apply.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"

# --- Verify secrets exist ---
echo "=== Verifying secrets ==="
if ! kubectl get secret clickhouse-credentials -n data &>/dev/null; then
  echo "ERROR: clickhouse-credentials Secret not found in namespace 'data'" >&2
  echo "  Run: ./secrets/apply.sh" >&2
  exit 1
fi

# --- Run init directly from host ---
source ./scripts/init.sh

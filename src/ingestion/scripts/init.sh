#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# KUBECONFIG can be empty when running in-cluster

# Resolve Airbyte env ONCE — all scripts below will reuse it
echo "=== Resolving Airbyte environment ==="
source ./scripts/resolve-airbyte-env.sh
export AIRBYTE_TOKEN AIRBYTE_CLIENT_ID AIRBYTE_CLIENT_SECRET WORKSPACE_ID

echo "=== Creating dbt databases ==="
kubectl exec -n data deploy/clickhouse -- clickhouse-client --password clickhouse \
  --query "CREATE DATABASE IF NOT EXISTS staging" 2>/dev/null
kubectl exec -n data deploy/clickhouse -- clickhouse-client --password clickhouse \
  --query "CREATE DATABASE IF NOT EXISTS silver" 2>/dev/null

echo "=== Registering connectors ==="
./scripts/upload-manifests.sh --all

echo "=== Applying connections ==="
./scripts/apply-connections.sh --all

echo "=== Syncing workflows ==="
./scripts/sync-flows.sh --all

echo "=== Init complete ==="

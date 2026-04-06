#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# KUBECONFIG can be empty when running in-cluster

# Resolve Airbyte env ONCE — all scripts below will reuse it
echo "=== Resolving Airbyte environment ==="
source ./scripts/resolve-airbyte-env.sh
export AIRBYTE_TOKEN AIRBYTE_CLIENT_ID AIRBYTE_CLIENT_SECRET WORKSPACE_ID

echo "=== Resolving ClickHouse credentials ==="
CH_PASS="${CLICKHOUSE_PASSWORD:-$(kubectl get secret clickhouse-credentials -n data -o jsonpath='{.data.password}' | base64 -d)}"
if [[ -z "$CH_PASS" ]]; then
  echo "ERROR: clickhouse-credentials Secret not found or empty in namespace 'data'" >&2
  echo "  Run: ./secrets/apply.sh --infra-only" >&2
  exit 1
fi
export CLICKHOUSE_PASSWORD="$CH_PASS"

echo "=== Creating dbt databases ==="
kubectl exec -n data deploy/clickhouse -- clickhouse-client --password "$CH_PASS" \
  --query "CREATE DATABASE IF NOT EXISTS staging" 2>/dev/null
kubectl exec -n data deploy/clickhouse -- clickhouse-client --password "$CH_PASS" \
  --query "CREATE DATABASE IF NOT EXISTS silver" 2>/dev/null

echo "=== Registering connectors ==="
./scripts/upload-manifests.sh --all

echo "=== Applying connections ==="
./scripts/apply-connections.sh --all

echo "=== Syncing workflows ==="
./scripts/sync-flows.sh --all

echo "=== Init complete ==="

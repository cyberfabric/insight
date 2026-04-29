#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# KUBECONFIG can be empty when running in-cluster

export TOOLKIT_DIR="${SCRIPT_DIR}/../airbyte-toolkit"

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
kubectl exec -n data deploy/clickhouse -- clickhouse-client --password "$CH_PASS" \
  --query "CREATE DATABASE IF NOT EXISTS insight" 2>/dev/null

echo "=== Running migrations ==="
for migration in "$SCRIPT_DIR/migrations"/*.sql; do
  [ -f "$migration" ] || continue
  echo "  $(basename "$migration")"
  grep -v '^\s*--' "$migration" \
    | kubectl exec -i -n data deploy/clickhouse -- clickhouse-client --password "$CH_PASS" --multiquery
done

echo "=== Registering connectors ==="
"${TOOLKIT_DIR}/register.sh" --all

echo "=== Applying connections ==="
"${TOOLKIT_DIR}/connect.sh" --all

echo "=== Syncing workflows ==="
./scripts/sync-flows.sh --all

echo "=== Init complete ==="

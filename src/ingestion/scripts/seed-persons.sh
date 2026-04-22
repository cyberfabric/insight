#!/usr/bin/env bash
# One-time seed: identity_inputs (ClickHouse) → persons (MariaDB).
#
# Reads identity.identity_inputs via HTTP, groups by source-account,
# assigns deterministic person_id per (tenant, email), INSERT IGNOREs
# every observation into persons.
#
# This script does NOT apply DDL. The persons table is created by the
# MariaDB migration runner (run-migrations-mariadb.sh → migrations/mariadb/).
# See ADR-0002 (seed idempotency) and ADR-0004 (migration runner).
#
# Prerequisites:
#   - Cluster running, ClickHouse + MariaDB healthy
#   - identity_inputs dbt view populated (dbt run --select +identity_inputs)
#   - persons migration applied (./scripts/run-migrations-mariadb.sh
#     or ./scripts/init.sh)
#
# Usage:
#   cd src/ingestion && ./scripts/seed-persons.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"

echo "=== Seed: identity_inputs → MariaDB persons ==="

# ── Resolve ClickHouse credentials ───────────────────────────────────────
CH_PASS="${CLICKHOUSE_PASSWORD:-$(kubectl get secret clickhouse-credentials -n data -o jsonpath='{.data.password}' | base64 -d)}"
export CLICKHOUSE_URL="${CLICKHOUSE_URL:-http://localhost:30123}"
export CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
export CLICKHOUSE_PASSWORD="$CH_PASS"

# ── Resolve MariaDB credentials ──────────────────────────────────────────
MARIADB_USER="${MARIADB_USER:-insight}"
MARIADB_PASSWORD="${MARIADB_PASSWORD:-insight-pass}"
MARIADB_HOST="${MARIADB_HOST:-localhost}"
MARIADB_PORT="${MARIADB_PORT:-3306}"
MARIADB_DB="${MARIADB_DB:-analytics}"
export MARIADB_URL="mysql://${MARIADB_USER}:${MARIADB_PASSWORD}@${MARIADB_HOST}:${MARIADB_PORT}/${MARIADB_DB}"

# ── Ensure MariaDB port-forward ──────────────────────────────────────────
if ! nc -z localhost 3306 2>/dev/null; then
  echo "  Starting MariaDB port-forward..."
  nohup kubectl -n insight port-forward svc/insight-mariadb 3306:3306 >/dev/null 2>&1 &
  disown
  sleep 3
fi

# ── Run seed ─────────────────────────────────────────────────────────────
echo "  Running seed script..."
pip install pymysql --quiet 2>/dev/null || true
python3 "$SCRIPT_DIR/seed-persons-from-identity-input.py"

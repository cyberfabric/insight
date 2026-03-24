#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "=== Stopping Kestra + ClickHouse ==="
docker compose down

echo "=== Stopping Airbyte ==="
abctl local uninstall 2>/dev/null || true

echo "=== Done ==="

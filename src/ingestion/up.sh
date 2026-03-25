#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v docker &>/dev/null; then
  echo "Docker is required. Install: https://docs.docker.com/get-docker/"
  exit 1
fi

if ! command -v abctl &>/dev/null; then
  echo "Installing abctl..."
  curl -LsfS https://get.airbyte.com | bash
fi

echo "=== Starting Airbyte ==="
abctl local install --low-resource-mode --values config/airbyte/values.yaml 2>&1 | tail -3

echo "=== Starting Kestra + ClickHouse ==="
docker compose up -d

echo "=== Waiting for services ==="
./scripts/wait-for-services.sh

echo "=== Initializing ==="
./scripts/init.sh

echo "=== Ready ==="
echo "Airbyte:    http://localhost:8000"
echo "Kestra:     http://localhost:8085"
echo "ClickHouse: http://localhost:8123"

#!/usr/bin/env bash
set -euo pipefail

# KUBECONFIG must be set by the caller (up.sh sets it)
# KUBECONFIG can be empty when running in-cluster

TIMEOUT=180

echo "  Waiting for ClickHouse..."
kubectl wait --for=condition=ready pod \
  -l app=clickhouse -n data \
  --timeout="${TIMEOUT}s"

echo "  Waiting for Argo Workflows..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argo-workflows-server -n argo \
  --timeout="${TIMEOUT}s"

echo "  Waiting for Airbyte..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=server -n airbyte \
  --timeout="${TIMEOUT}s" 2>/dev/null || {
  # Fallback: poll health endpoint
  printf "  Polling Airbyte health..."
  for i in $(seq 1 60); do
    if curl -sf "http://localhost:8000/api/v1/health" >/dev/null 2>&1; then
      echo " ok"
      break
    fi
    sleep 3
  done
}

echo "  All services ready"

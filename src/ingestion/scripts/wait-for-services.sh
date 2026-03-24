#!/usr/bin/env bash
set -euo pipefail

wait_for() {
  local name="$1" url="$2" max=60
  printf "  Waiting for %s..." "$name"
  for i in $(seq 1 $max); do
    if curl -sf "$url" >/dev/null 2>&1; then
      echo " ok"
      return 0
    fi
    sleep 2
  done
  echo " TIMEOUT"
  return 1
}

wait_for "ClickHouse" "http://localhost:8123/ping"
wait_for "Kestra"     "http://localhost:8085/api/v1/flows/search?q=*&size=0"
wait_for "Airbyte"    "http://localhost:8000/api/v1/health"

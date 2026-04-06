#!/usr/bin/env bash
# Apply all K8s Secrets: infrastructure (this directory) and connectors (connectors/).
#
# Usage: ./apply.sh [--connectors-only | --infra-only]
#
# 1. Copy *.yaml.example → *.yaml (here and in connectors/)
# 2. Fill in real credentials
# 3. Run this script
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="all"
if [[ "${1:-}" == "--connectors-only" ]]; then
  MODE="connectors"
elif [[ "${1:-}" == "--infra-only" ]]; then
  MODE="infra"
fi

apply_file() {
  local f="$1"
  local label="$2"
  local name
  name="$(basename "$f")"

  # ClickHouse credentials needed in both 'data' and 'argo' namespaces
  if [[ "$name" == "clickhouse.yaml" ]]; then
    echo "[$label] $name → data + argo"
    kubectl apply -f "$f" -n data
    kubectl apply -f "$f" -n argo
    return
  fi

  # Airbyte credentials managed by Helm chart (global.auth.enabled: true)
  # No custom Secret needed — Helm generates airbyte-auth-secrets automatically

  # Argo credentials → argo namespace
  if [[ "$name" == argo-*.yaml ]]; then
    echo "[$label] $name → argo"
    kubectl apply -f "$f" -n argo
    return
  fi

  # Connector secrets → data namespace
  echo "[$label] $name → data"
  kubectl apply -f "$f" -n data
}

apply_dir() {
  local dir="$1"
  local label="$2"

  shopt -s nullglob
  local files=("$dir"/*.yaml)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No .yaml files in $dir"
    echo "  Copy .yaml.example files and fill in credentials:"
    for ex in "$dir"/*.yaml.example; do
      local base
      base="$(basename "$ex" .yaml.example).yaml"
      echo "    cp $ex $dir/$base"
    done
    return
  fi

  for f in "${files[@]}"; do
    apply_file "$f" "$label"
  done
}

if [[ "$MODE" == "all" || "$MODE" == "infra" ]]; then
  echo "=== Infrastructure Secrets ==="
  apply_dir "$DIR" "infra"
fi

if [[ "$MODE" == "all" || "$MODE" == "connectors" ]]; then
  echo "=== Connector Secrets ==="
  apply_dir "$DIR/connectors" "connector"
fi

echo "Done."

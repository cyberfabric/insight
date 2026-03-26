#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

KESTRA_URL="${KESTRA_URL:-http://localhost:8085}"
FLOWS_DIR="./flows"

upload_flow() {
  local flow_file="$1"
  local response
  response=$(curl -sf -X POST "${KESTRA_URL}/api/v1/flows/import" \
    -F "fileUpload=@${flow_file}" 2>&1) || {
    echo "  ERROR uploading ${flow_file}: ${response}"
    return 1
  }
  echo "  OK: ${flow_file}"
}

sync_tenant() {
  local tenant="$1"
  local tenant_dir="${FLOWS_DIR}/${tenant}"

  if [[ ! -d "$tenant_dir" ]]; then
    echo "  SKIP: no flows directory for tenant ${tenant}"
    return 0
  fi

  for flow_file in "${tenant_dir}"/*.yml; do
    [[ -f "$flow_file" ]] || continue
    upload_flow "$flow_file"
  done
}

if [[ "${1:-}" == "--all" ]]; then
  if [[ ! -d "$FLOWS_DIR" ]]; then
    echo "  No flows directory found"
    exit 0
  fi
  for tenant_dir in "${FLOWS_DIR}"/*/; do
    [[ -d "$tenant_dir" ]] || continue
    tenant=$(basename "$tenant_dir")
    echo "  Syncing flows for tenant: $tenant"
    sync_tenant "$tenant"
  done
else
  tenant="${1:?Usage: $0 <tenant_id> | --all}"
  echo "  Syncing flows for tenant: $tenant"
  sync_tenant "$tenant"
fi

#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONNECTIONS_DIR="./connections"

get_airbyte_creds() {
  local creds
  creds=$(abctl local credentials 2>/dev/null | grep -E "Email|Password" || true)
  AIRBYTE_EMAIL=$(echo "$creds" | grep Email | awk '{print $NF}')
  AIRBYTE_PASSWORD=$(echo "$creds" | grep Password | awk '{print $NF}')
}

apply_tenant() {
  local tenant="$1"
  local tfvars="${CONNECTIONS_DIR}/${tenant}.tfvars"

  if [[ ! -f "$tfvars" ]]; then
    echo "  SKIP: no ${tfvars}"
    return 0
  fi

  get_airbyte_creds

  cd "$CONNECTIONS_DIR"

  terraform init -input=false -no-color >/dev/null 2>&1

  terraform workspace select "$tenant" 2>/dev/null || terraform workspace new "$tenant" >/dev/null

  terraform apply -auto-approve -input=false -no-color \
    -var="tenant_id=${tenant}" \
    -var="airbyte_username=${AIRBYTE_EMAIL}" \
    -var="airbyte_password=${AIRBYTE_PASSWORD}" \
    -var-file="../${tfvars}" 2>&1 | grep -E "Apply|Plan|Error" || true

  cd ..
}

if [[ "${1:-}" == "--all" ]]; then
  tfvars_files=$(find "$CONNECTIONS_DIR" -name "*.tfvars" 2>/dev/null)
  if [[ -z "$tfvars_files" ]]; then
    echo "  No tenant tfvars found"
    exit 0
  fi
  for tfvars in $tfvars_files; do
    tenant=$(basename "$tfvars" .tfvars)
    echo "  Applying connections for tenant: $tenant"
    apply_tenant "$tenant"
  done
else
  tenant="${1:?Usage: $0 <tenant_id> | --all}"
  echo "  Applying connections for tenant: $tenant"
  apply_tenant "$tenant"
fi

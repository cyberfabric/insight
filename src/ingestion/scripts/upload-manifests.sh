#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

AIRBYTE_URL="${AIRBYTE_URL:-http://localhost:8000}"
CONNECTORS_DIR="./connectors"

get_credentials() {
  local creds
  creds=$(abctl local credentials 2>/dev/null | grep -E "Email|Password" || true)
  if [[ -z "$creds" ]]; then
    echo "Cannot get Airbyte credentials from abctl" >&2
    exit 1
  fi
  AIRBYTE_EMAIL=$(echo "$creds" | grep Email | awk '{print $NF}')
  AIRBYTE_PASSWORD=$(echo "$creds" | grep Password | awk '{print $NF}')
  AIRBYTE_AUTH=$(echo -n "${AIRBYTE_EMAIL}:${AIRBYTE_PASSWORD}" | base64)
}

airbyte_api() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sf -X "$method" "${AIRBYTE_URL}${path}" -H "Authorization: Basic ${AIRBYTE_AUTH}" -H "Content-Type: application/json")
  if [[ -n "$data" ]]; then
    args+=(-d "$data")
  fi
  curl "${args[@]}"
}

get_workspace_id() {
  airbyte_api GET "/api/v1/workspaces/list" '{}' 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
workspaces = data.get('workspaces', [])
if workspaces:
    print(workspaces[0]['workspaceId'])
" 2>/dev/null
}

upload_connector() {
  local connector="$1"
  local connector_dir="${CONNECTORS_DIR}/${connector}"
  local manifest_path="${connector_dir}/connector.yaml"
  local descriptor_path="${connector_dir}/descriptor.yaml"

  if [[ ! -f "$manifest_path" ]]; then
    echo "  SKIP: no manifest at ${manifest_path}"
    return 0
  fi

  local name
  if [[ -f "$descriptor_path" ]]; then
    name=$(python3 -c "import yaml; print(yaml.safe_load(open('${descriptor_path}'))['name'])" 2>/dev/null || echo "$connector")
  else
    name=$(basename "$connector")
  fi

  local manifest_json
  manifest_json=$(python3 -c "
import yaml, json, sys
with open('${manifest_path}') as f:
    manifest = yaml.safe_load(f)
print(json.dumps(manifest))
")

  local workspace_id
  workspace_id=$(get_workspace_id)
  if [[ -z "$workspace_id" ]]; then
    echo "  ERROR: cannot get workspace ID"
    return 1
  fi

  local existing
  existing=$(airbyte_api POST "/api/v1/sources/list" "{\"workspaceId\":\"${workspace_id}\"}" 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for s in data.get('sources', []):
    if s.get('name') == '${name}':
        print(s['sourceId'])
        break
" 2>/dev/null)

  if [[ -n "$existing" ]]; then
    echo "  Updating source '${name}' (${existing})..."
    airbyte_api POST "/api/v1/sources/update" "{
      \"sourceId\": \"${existing}\",
      \"name\": \"${name}\",
      \"connectionConfiguration\": {
        \"__injected_declarative_manifest\": ${manifest_json}
      }
    }" >/dev/null
  else
    echo "  Creating source '${name}'..."
    airbyte_api POST "/api/v1/sources/create" "{
      \"workspaceId\": \"${workspace_id}\",
      \"name\": \"${name}\",
      \"sourceDefinitionId\": \"64a2f99c-542f-4af8-9a6f-355f1217b436\",
      \"connectionConfiguration\": {
        \"__injected_declarative_manifest\": ${manifest_json}
      }
    }" >/dev/null
  fi
  echo "  Done: ${name}"
}

get_credentials

if [[ "${1:-}" == "--all" ]]; then
  manifests=$(find "$CONNECTORS_DIR" -name "connector.yaml" 2>/dev/null)
  if [[ -z "$manifests" ]]; then
    echo "  No connector manifests found"
    exit 0
  fi
  for manifest in $manifests; do
    connector_dir=$(dirname "$manifest")
    connector=$(echo "$connector_dir" | sed "s|${CONNECTORS_DIR}/||")
    upload_connector "$connector"
  done
else
  connector="${1:?Usage: $0 <class/connector> | --all}"
  upload_connector "$connector"
fi

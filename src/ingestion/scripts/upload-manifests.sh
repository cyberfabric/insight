#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

AIRBYTE_URL="${AIRBYTE_URL:-http://localhost:8000}"
CONNECTORS_DIR="./connectors"

get_token() {
  local secret
  secret=$(KUBECONFIG=${HOME}/.airbyte/abctl/abctl.kubeconfig kubectl exec -n airbyte-abctl \
    "$(KUBECONFIG=${HOME}/.airbyte/abctl/abctl.kubeconfig kubectl get pod -n airbyte-abctl -l app.kubernetes.io/name=server -o jsonpath='{.items[0].metadata.name}')" \
    -- printenv AB_JWT_SIGNATURE_SECRET 2>/dev/null)

  AIRBYTE_TOKEN=$(node -e "
    const c=require('crypto');
    const h=Buffer.from(JSON.stringify({alg:'HS256',typ:'JWT'})).toString('base64url');
    const n=Math.floor(Date.now()/1000);
    const p=Buffer.from(JSON.stringify({iss:'airbyte-server',sub:'00000000-0000-0000-0000-000000000000',iat:n,exp:n+300})).toString('base64url');
    const s=c.createHmac('sha256','${secret}').update(h+'.'+p).digest('base64url');
    console.log(h+'.'+p+'.'+s);
  ")
}

api() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sf -X "$method" "${AIRBYTE_URL}${path}" -H "Authorization: Bearer ${AIRBYTE_TOKEN}" -H "Content-Type: application/json")
  [[ -n "$data" ]] && args+=(-d "$data")
  curl "${args[@]}"
}

get_workspace_id() {
  local public_token
  public_token=$(curl -sf -X POST "${AIRBYTE_URL}/api/public/v1/applications/token" \
    -H "Content-Type: application/json" \
    -d "$(abctl local credentials 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | awk '/Client-Id/{cid=$NF} /Client-Secret/{cs=$NF} END{printf "{\"client_id\":\"%s\",\"client_secret\":\"%s\",\"grant_type\":\"client_credentials\"}", cid, cs}')" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
  curl -sf -H "Authorization: Bearer ${public_token}" "${AIRBYTE_URL}/api/public/v1/workspaces" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['workspaceId'])"
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
  name=$(yq -r '.name' "${descriptor_path}" 2>/dev/null || basename "$connector")

  local manifest_json conn_spec
  manifest_json=$(yq -c '.' "${manifest_path}")
  conn_spec=$(yq -c '.spec.connection_specification' "${manifest_path}")

  local workspace_id
  workspace_id=$(get_workspace_id)

  get_token

  # Check if builder project exists
  local project_id
  project_id=$(api POST "/api/v1/connector_builder_projects/list" \
    "{\"workspaceId\":\"${workspace_id}\"}" | python3 -c "
import sys,json
for p in json.load(sys.stdin).get('projects',[]):
    if p['name']=='${name}':
        print(p['builderProjectId'])
        break
" 2>/dev/null || true)

  if [[ -n "$project_id" ]]; then
    echo "  Updating '${name}' (project ${project_id})..."
    get_token
    api POST "/api/v1/connector_builder_projects/update" \
      "{\"workspaceId\":\"${workspace_id}\",\"builderProjectId\":\"${project_id}\",\"builderProject\":{\"name\":\"${name}\",\"draftManifest\":${manifest_json}}}" >/dev/null

    echo "  Publishing active manifest..."
    get_token

    local source_def_id
    source_def_id=$(api POST "/api/v1/connector_builder_projects/get" \
      "{\"workspaceId\":\"${workspace_id}\",\"builderProjectId\":\"${project_id}\"}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('declarativeManifest',{}).get('sourceDefinitionId',''))" 2>/dev/null || true)

    if [[ -n "$source_def_id" ]]; then
      get_token
      api POST "/api/v1/declarative_source_definitions/update_active_manifest" \
        "{\"sourceDefinitionId\":\"${source_def_id}\",\"manifest\":${manifest_json},\"spec\":{\"connectionSpecification\":${conn_spec}},\"version\":$(date +%s)}" >/dev/null
    fi

    # Note: testing values in Airbyte UI must be set manually.
    # The update_testing_values API requires session auth not available via CLI.
  else
    echo "  Creating '${name}'..."
    get_token
    project_id=$(api POST "/api/v1/connector_builder_projects/create" \
      "{\"workspaceId\":\"${workspace_id}\",\"builderProject\":{\"name\":\"${name}\",\"draftManifest\":${manifest_json}}}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['builderProjectId'])")

    echo "  Publishing '${name}'..."
    get_token
    local def_id
    def_id=$(api POST "/api/v1/connector_builder_projects/publish" \
      "{\"workspaceId\":\"${workspace_id}\",\"builderProjectId\":\"${project_id}\",\"name\":\"${name}\",\"initialDeclarativeManifest\":{\"manifest\":${manifest_json},\"spec\":{\"connectionSpecification\":${conn_spec}},\"version\":1,\"description\":\"${name}\"}}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['sourceDefinitionId'])")
    echo "  Published: definition ${def_id}"
  fi
  echo "  Done: ${name}"
}

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

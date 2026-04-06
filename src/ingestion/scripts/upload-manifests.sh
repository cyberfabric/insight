#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# KUBECONFIG can be empty when running in-cluster

# Resolve shared Airbyte env (AIRBYTE_TOKEN, WORKSPACE_ID, etc.)
if [[ -z "${AIRBYTE_TOKEN:-}" ]]; then
  source ./scripts/resolve-airbyte-env.sh
fi

AIRBYTE_URL="${AIRBYTE_API:-http://localhost:8000}"
CONNECTORS_DIR="./connectors"

source ./scripts/airbyte-state.sh

# Use Python for all Airbyte API calls — shell interpolation breaks JSON with large manifests
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

  local output
  output=$(python3 - "$AIRBYTE_URL" "$AIRBYTE_TOKEN" "$WORKSPACE_ID" "$name" "$manifest_path" <<'PYTHON'
import sys, json, yaml, urllib.request

airbyte_url, token, workspace_id, name, manifest_path = sys.argv[1:6]
headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def api(method, path, data=None):
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(f"{airbyte_url}{path}", data=body, headers=headers, method=method)
    try:
        resp = urllib.request.urlopen(req)
        content = resp.read()
        return json.loads(content) if content else {}
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()
        print(f"  API error {e.code}: {err_body[:200]}", file=sys.stderr)
        return None

# Load manifest
with open(manifest_path) as f:
    manifest = yaml.safe_load(f)
spec = manifest.get("spec", {}).get("connection_specification", {})

# List existing projects
projects = api("POST", "/api/v1/connector_builder_projects/list", {"workspaceId": workspace_id})
existing_id = None
if projects:
    for p in projects.get("projects", []):
        if p["name"] == name:
            existing_id = p["builderProjectId"]
            break

# Update existing or create new
if existing_id:
    print(f"  Updating '{name}' in-place...")
    # Update draft manifest
    api("POST", "/api/v1/connector_builder_projects/update", {
        "workspaceId": workspace_id,
        "builderProjectId": existing_id,
        "builderProject": {"name": name, "draftManifest": manifest}
    })
    # Update active (published) manifest — keeps same definition ID
    api("POST", "/api/v1/connector_builder_projects/update_active_manifest", {
        "workspaceId": workspace_id,
        "builderProjectId": existing_id,
        "manifest": manifest,
        "spec": {"connectionSpecification": spec}
    })
    # Get existing definition ID
    project_detail = api("POST", "/api/v1/connector_builder_projects/get", {
        "workspaceId": workspace_id,
        "builderProjectId": existing_id
    })
    def_id = None
    if project_detail:
        dm = project_detail.get("declarativeManifest", {})
        def_id = dm.get("sourceDefinitionId") if dm else None
    if def_id:
        print(f"  Updated: definition {def_id}")
        print(f"  DEF_ID:{def_id}")
    else:
        print(f"  Updated draft+active manifest (definition ID in project)")
else:
    # Create new
    print(f"  Creating '{name}'...")
    result = api("POST", "/api/v1/connector_builder_projects/create", {
        "workspaceId": workspace_id,
        "builderProject": {"name": name, "draftManifest": manifest}
    })
    if not result or "builderProjectId" not in result:
        print(f"  ERROR: create failed: {result}", file=sys.stderr)
        sys.exit(1)
    project_id = result["builderProjectId"]

    # Publish
    print(f"  Publishing '{name}'...")
    pub_result = api("POST", "/api/v1/connector_builder_projects/publish", {
        "workspaceId": workspace_id,
        "builderProjectId": project_id,
        "name": name,
        "initialDeclarativeManifest": {
            "manifest": manifest,
            "spec": {"connectionSpecification": spec},
            "version": 1,
            "description": name
        }
    })
    if pub_result and "sourceDefinitionId" in pub_result:
        print(f"  Published: definition {pub_result['sourceDefinitionId']}")
        print(f"  DEF_ID:{pub_result['sourceDefinitionId']}")
    else:
        print(f"  WARN: publish response: {str(pub_result)[:200]}", file=sys.stderr)

print(f"  Done: {name}")
PYTHON
)
  echo "$output"

  # Save definition ID to state
  local def_id
  def_id=$(echo "$output" | grep "^  DEF_ID:" | tail -1 | cut -d: -f2)
  if [[ -n "$def_id" ]]; then
    state_set "definitions.${name}" "$def_id"
  fi
}

if [[ "${1:-}" == "--all" ]]; then
  manifests=$(find "$CONNECTORS_DIR" -name "connector.yaml" 2>/dev/null)
  if [[ -z "$manifests" ]]; then
    echo "  No connector manifests found"
    exit 0
  fi
  for manifest in $manifests; do
    connector_dir=$(dirname "$manifest")
    connector="${connector_dir#${CONNECTORS_DIR}/}"
    upload_connector "$connector"
  done
else
  upload_connector "${1:?Usage: $0 <connector_path> | --all}"
fi

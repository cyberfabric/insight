#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Airbyte Toolkit — Register connector manifests as Airbyte source definitions
#
# Usage: ./register.sh [--all | connector_name]
#
# connector_name is the relative path under connectors/, e.g. "collaboration/m365"
# --all registers every connector that has a connector.yaml manifest
# ---------------------------------------------------------------------------

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INGESTION_DIR="$(cd "$TOOLKIT_DIR/.." && pwd)"

CONNECTORS_DIR="${INGESTION_DIR}/connectors"

source "${TOOLKIT_DIR}/lib/env.sh"
source "${TOOLKIT_DIR}/lib/state.sh"

# ---------------------------------------------------------------------------
# upload_connector <connector_path>
#   connector_path — relative to CONNECTORS_DIR, e.g. "collaboration/m365"
# ---------------------------------------------------------------------------
upload_connector() {
  local connector="$1"
  local connector_dir="${CONNECTORS_DIR}/${connector}"
  local manifest_path="${connector_dir}/connector.yaml"
  local descriptor_path="${connector_dir}/descriptor.yaml"

  # Auto-detect connector type and route accordingly
  if [[ -f "$descriptor_path" ]]; then
    local conn_type
    conn_type=$(yq -r '.type // "nocode"' "$descriptor_path")
    if [[ "$conn_type" == "cdk" ]]; then
      echo "  CDK connector detected — delegating to build-connector.sh"
      "${TOOLKIT_DIR}/build-connector.sh" "$connector"
      return $?
    fi
  fi

  if [[ ! -f "$manifest_path" ]]; then
    echo "  SKIP: no manifest at ${manifest_path}"
    return 0
  fi

  local name
  name=$(yq -r '.name' "${descriptor_path}" 2>/dev/null || basename "$connector")

  local output
  output=$(python3 - "$AIRBYTE_API" "$AIRBYTE_TOKEN" "$WORKSPACE_ID" "$name" "$manifest_path" <<'PYTHON'
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
        return {"_error": e.code, "_body": err_body[:300]}

# Load manifest
with open(manifest_path) as f:
    manifest = yaml.safe_load(f)
spec = manifest.get("spec", {}).get("connection_specification", {})

# List existing projects
projects = api("POST", "/api/v1/connector_builder_projects/list", {"workspaceId": workspace_id})
existing = None
if projects and "_error" not in projects:
    for p in projects.get("projects", []):
        if p["name"] == name:
            existing = p
            break

# If project exists, check if it's healthy (has a working definition)
if existing:
    pid = existing["builderProjectId"]
    detail = api("POST", "/api/v1/connector_builder_projects/get",
                 {"workspaceId": workspace_id, "builderProjectId": pid})
    if detail and "_error" not in detail:
        dm = detail.get("declarativeManifest")
        if dm and dm.get("sourceDefinitionId"):
            # Healthy — update in place
            def_id = dm["sourceDefinitionId"]
            print(f"  Updating '{name}' (definition {def_id})...")
            api("POST", "/api/v1/connector_builder_projects/update", {
                "workspaceId": workspace_id,
                "builderProjectId": pid,
                "builderProject": {"name": name, "draftManifest": manifest}
            })
            api("POST", "/api/v1/connector_builder_projects/update_active_manifest", {
                "workspaceId": workspace_id,
                "builderProjectId": pid,
                "manifest": manifest,
                "spec": {"connectionSpecification": spec}
            })
            print(f"  DEF_ID:{def_id}")
            print(f"  Done: {name}")
            sys.exit(0)

    # Broken project — delete and recreate
    print(f"  Deleting broken project '{name}'...")
    api("POST", "/api/v1/connector_builder_projects/delete",
        {"workspaceId": workspace_id, "builderProjectId": pid})

# Create new project
print(f"  Creating '{name}'...")
result = api("POST", "/api/v1/connector_builder_projects/create", {
    "workspaceId": workspace_id,
    "builderProject": {"name": name, "draftManifest": manifest}
})
if not result or "_error" in result:
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
if pub_result and "_error" not in pub_result and "sourceDefinitionId" in pub_result:
    print(f"  Published: definition {pub_result['sourceDefinitionId']}")
    print(f"  DEF_ID:{pub_result['sourceDefinitionId']}")
else:
    print(f"  WARN: publish response: {str(pub_result)[:300]}", file=sys.stderr)

print(f"  Done: {name}")
PYTHON
)
  echo "$output"

  # Save definition ID to state at definitions.<connector_name>.id
  local def_id
  def_id=$(echo "$output" | grep "^  DEF_ID:" | tail -1 | cut -d: -f2)
  if [[ -n "$def_id" ]]; then
    state_set "definitions.${name}.id" "$def_id"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--all" ]]; then
  # Find all connectors by descriptor.yaml (covers both nocode and CDK)
  found=0
  errors=0
  while IFS= read -r -d '' desc; do
    connector_dir=$(dirname "$desc")
    connector="${connector_dir#${CONNECTORS_DIR}/}"
    echo "  Registering connector: $connector"
    if ! upload_connector "$connector"; then
      echo "  ERROR: failed to register $connector (continuing...)" >&2
      errors=$((errors + 1))
    fi
    found=1
  done < <(find "$CONNECTORS_DIR" -name "descriptor.yaml" -print0 2>/dev/null)
  if [[ "$found" -eq 0 ]]; then
    echo "  No connectors found"
    exit 0
  fi
  if [[ "$errors" -gt 0 ]]; then
    echo "  WARNING: $errors connector(s) failed to register" >&2
  fi
else
  upload_connector "${1:?Usage: $0 <connector_path> | --all}"
fi

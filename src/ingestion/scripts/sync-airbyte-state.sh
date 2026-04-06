#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Sync .airbyte-state.yaml with current Airbyte instance.
# Re-fetches all IDs from Airbyte API.
#
# Usage: ./scripts/sync-airbyte-state.sh
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

source ./scripts/resolve-airbyte-env.sh
source ./scripts/airbyte-state.sh

echo "Syncing Airbyte state..."

state_set "workspace_id" "$WORKSPACE_ID"

python3 - "${AIRBYTE_API}" "${AIRBYTE_TOKEN}" "${WORKSPACE_ID}" "${STATE_FILE}" <<'PY'
import sys, json, yaml, urllib.request, urllib.error, os

airbyte_url, token, workspace_id, state_file = sys.argv[1:5]
headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def api(path, data):
    body = json.dumps(data).encode()
    req = urllib.request.Request(f"{airbyte_url}{path}", data=body, headers=headers, method="POST")
    try:
        return json.loads(urllib.request.urlopen(req).read())
    except urllib.error.HTTPError as e:
        print(f"  API error {e.code}: {e.read().decode()[:200]}", file=sys.stderr)
        return {}

# Load existing state
data = yaml.safe_load(open(state_file)) if os.path.exists(state_file) else {}
if not data: data = {}
data["workspace_id"] = workspace_id

# --- Definitions ---
# Custom definitions = lowercase names (our connectors)
defs = api("/api/v1/source_definitions/list", {"workspaceId": workspace_id})
definitions = {}
for d in defs.get("sourceDefinitions", []):
    name = d["name"]
    # Our custom connectors have lowercase names
    if name == name.lower() and not name.startswith("source-"):
        definitions[name] = d["sourceDefinitionId"]
data["definitions"] = definitions
print(f"  Definitions: {len(definitions)} ({', '.join(definitions.keys())})")

# --- Sources ---
sources = api("/api/v1/sources/list", {"workspaceId": workspace_id})
for s in sources.get("sources", []):
    name = s["name"]  # format: {connector}-{tenant}
    parts = name.rsplit("-", 1)
    if len(parts) == 2:
        connector, tenant = parts
    else:
        connector, tenant = name, "default"
    data.setdefault("tenants", {}).setdefault(tenant, {}).setdefault("sources", {})[connector] = s["sourceId"]
    print(f"  Source: {name} → tenants.{tenant}.sources.{connector}")

# --- Destinations ---
dests = api("/api/v1/destinations/list", {"workspaceId": workspace_id})
for d in dests.get("destinations", []):
    name = d["name"]  # format: clickhouse-{connector}
    connector = name.replace("clickhouse-", "")
    # Find tenant from connections later; for now put under _global
    data.setdefault("destinations", {})[connector] = d["destinationId"]
    print(f"  Destination: {name} → destinations.{connector}")

# --- Connections ---
conns = api("/api/v1/connections/list", {"workspaceId": workspace_id})
for c in conns.get("connections", []):
    name = c["name"]  # format: {connector}-to-clickhouse-{tenant}
    parts = name.split("-to-clickhouse-")
    if len(parts) == 2:
        connector, tenant = parts
    else:
        connector, tenant = name, "default"
    data.setdefault("tenants", {}).setdefault(tenant, {}).setdefault("connections", {})[connector] = c["connectionId"]
    print(f"  Connection: {name} → tenants.{tenant}.connections.{connector}")

# Write state
with open(state_file, "w") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
print(f"\nState saved: {state_file}")
PY

# Sync to ConfigMap if in-cluster
if [[ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]]; then
  kubectl create configmap "$STATE_CM_NAME" -n "$STATE_CM_NS" \
    --from-file=state.yaml="$STATE_FILE" --dry-run=client -o yaml | \
    kubectl apply -f - >/dev/null 2>&1
  echo "  ConfigMap synced"
fi

echo "Done."

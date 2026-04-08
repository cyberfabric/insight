#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Reset a connector: delete Airbyte connection + source + definition,
# drop Bronze tables in ClickHouse, and clean state files.
#
# Usage:
#   ./scripts/reset-connector.sh <connector_name> <tenant>
#   ./scripts/reset-connector.sh github example-tenant
#
# Use when: schema breaking changes, pk migration, full re-sync needed.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

source ./scripts/airbyte-state.sh

CONNECTOR="${1:?Usage: $0 <connector_name> <tenant>}"
TENANT="${2:?Usage: $0 <connector_name> <tenant>}"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kind-ingestion}"

# Resolve tenant_id from tenant config
TENANT_ID=$(python3 -c "
import yaml, sys
try:
    t = yaml.safe_load(open('connections/${TENANT}.yaml'))
    print(t.get('tenant_id', '${TENANT}'))
except Exception:
    print('${TENANT}')
" 2>/dev/null)

echo "=== Resetting connector: ${CONNECTOR} (tenant: ${TENANT}) ==="

# --- Resolve Airbyte env ---
if [[ -z "${AIRBYTE_TOKEN:-}" ]]; then
  source ./scripts/resolve-airbyte-env.sh
fi

# --- Read state ---
STATE_FILE_TENANT="./connections/.state/${TENANT}.yaml"

python3 - "$CONNECTOR" "$TENANT_ID" "$AIRBYTE_API" "$AIRBYTE_TOKEN" \
  "$STATE_FILE_TENANT" <<'PYTHON'
import sys, os, json, yaml, urllib.request, urllib.error, subprocess, base64

connector, tenant_id, airbyte_url, token, state_path = sys.argv[1:6]
headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def api(path, data):
    body = json.dumps(data).encode()
    req = urllib.request.Request(f"{airbyte_url}{path}", data=body, headers=headers, method="POST")
    try:
        urllib.request.urlopen(req)
        return True
    except urllib.error.HTTPError as e:
        code = e.code
        if code == 404:
            return True  # already gone
        print(f"  API {code}: {e.read().decode()[:200]}", file=sys.stderr)
        return False

# Load state
state = {}
if os.path.exists(state_path):
    with open(state_path) as f:
        state = yaml.safe_load(f) or {}

connectors = state.get("connectors", {})

# Find matching connector keys (e.g. "github-github-cyberfabric")
matching_keys = [k for k in connectors if k.startswith(f"{connector}-")]
if not matching_keys:
    print(f"  No state entries found for connector '{connector}'")

for key in matching_keys:
    entry = connectors[key]

    # Delete connection
    conn_id = entry.get("connection_id")
    if conn_id:
        print(f"  Deleting connection: {conn_id}")
        api("/api/v1/connections/delete", {"connectionId": conn_id})

    # Delete source
    source_id = entry.get("source_id")
    if source_id:
        print(f"  Deleting source: {source_id}")
        api("/api/v1/sources/delete", {"sourceId": source_id})

    # Delete definition
    def_id = entry.get("definition_id")
    if def_id:
        print(f"  Deleting definition: {def_id}")
        api("/api/v1/source_definitions/delete", {"sourceDefinitionId": def_id})

    # Remove from state
    del connectors[key]
    print(f"  Removed state entry: {key}")

# Clean tenant-level state references
for section in ("sources", "connections"):
    t = state.get("tenants", {}).get(tenant_id, {}).get(section, {})
    keys_to_remove = [k for k in t if k.startswith(f"{connector}-")]
    for k in keys_to_remove:
        del t[k]

# Clean definitions
defs = state.get("definitions", {})
keys_to_remove = [k for k in defs if k.startswith(f"{connector}")]
for k in keys_to_remove:
    del defs[k]

# Save state
with open(state_path, "w") as f:
    yaml.dump(state, f, default_flow_style=False, sort_keys=False)
print(f"  State cleaned: {state_path}")

# --- Drop Bronze tables ---
# Resolve ClickHouse password
ch_pass = os.environ.get("CLICKHOUSE_PASSWORD", "")
if not ch_pass:
    result = subprocess.run(
        ["kubectl", "get", "secret", "clickhouse-credentials", "-n", "data",
         "-o", "jsonpath={.data.password}"],
        capture_output=True, text=True, timeout=10
    )
    if result.returncode == 0 and result.stdout.strip():
        ch_pass = base64.b64decode(result.stdout.strip()).decode()

db_name = f"bronze_{connector}"
if ch_pass:
    print(f"  Dropping Bronze database: {db_name}")
    result = subprocess.run(
        ["kubectl", "exec", "-n", "data", "deploy/clickhouse", "--",
         "clickhouse-client", "--password", ch_pass,
         "--query", f"DROP DATABASE IF EXISTS {db_name}"],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode == 0:
        print(f"  Database dropped: {db_name}")
    else:
        print(f"  WARN: drop failed: {result.stderr.strip()}", file=sys.stderr)
else:
    print(f"  SKIP: no ClickHouse password, cannot drop {db_name}")
PYTHON

# Clean main state file too
MAIN_STATE="./connections/.airbyte-state.yaml"
if [[ -f "$MAIN_STATE" ]]; then
  python3 -c "
import yaml, sys
with open('$MAIN_STATE') as f:
    state = yaml.safe_load(f) or {}
defs = state.get('definitions', {})
if '$CONNECTOR' in defs:
    del defs['$CONNECTOR']
    with open('$MAIN_STATE', 'w') as f:
        yaml.dump(state, f, default_flow_style=False, sort_keys=False)
    print('  Cleaned main state: $MAIN_STATE')
"
fi

echo ""
echo "=== Reset complete: ${CONNECTOR} ==="
echo ""
echo "  To recreate:"
echo "    ./scripts/build-connector.sh <path>     # CDK only"
echo "    ./scripts/upload-manifests.sh <path>     # nocode only"
echo "    ./scripts/apply-connections.sh ${TENANT}"
echo "    ./run-sync.sh ${CONNECTOR} ${TENANT}"

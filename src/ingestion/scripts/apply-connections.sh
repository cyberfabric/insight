#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

# KUBECONFIG can be empty when running in-cluster

# Resolve shared Airbyte env
if [[ -z "${AIRBYTE_TOKEN:-}" ]]; then
  source ./scripts/resolve-airbyte-env.sh
fi

CONNECTIONS_DIR="./connections"
CONNECTORS_DIR="./connectors"

apply_tenant() {
  local tenant_config="$1"

  python3 - "$tenant_config" "$CONNECTORS_DIR" "$CONNECTIONS_DIR" \
    "${AIRBYTE_API:-http://localhost:8000}" "$AIRBYTE_TOKEN" "$WORKSPACE_ID" <<'PYTHON'
import sys, os, json, yaml, urllib.request, urllib.error, pathlib

tenant_config_path, connectors_dir, connections_dir, airbyte_url, token, workspace_id = sys.argv[1:7]
state_dir = os.path.join(connections_dir, ".state")
os.makedirs(state_dir, exist_ok=True)

# Derive state file name from config file name (not tenant_id)
config_basename = os.path.splitext(os.path.basename(tenant_config_path))[0]

# Load tenant config
with open(tenant_config_path) as f:
    tenant = yaml.safe_load(f)

tenant_id = tenant["tenant_id"]
dest_config = tenant.get("destination", {})
state_path = os.path.join(state_dir, f"{config_basename}.yaml")

# Load existing state
state = {}
if os.path.exists(state_path):
    with open(state_path) as f:
        state = yaml.safe_load(f) or {}

headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}

def api(method, path, data=None):
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(f"{airbyte_url}{path}", data=body, headers=headers, method=method)
    try:
        resp = urllib.request.urlopen(req)
        content = resp.read()
        return json.loads(content) if content else {}
    except urllib.error.HTTPError as e:
        err = e.read().decode()
        print(f"  API {e.code}: {err[:200]}", file=sys.stderr)
        return None

def find_or_create(resource_type, list_path, list_key, create_path, create_data, id_key, name_field, name_value):
    """Find existing resource by name or create new one."""
    existing = api("POST", list_path, {"workspaceId": workspace_id})
    if existing:
        for item in existing.get(list_key, []):
            if item.get("name") == name_value:
                print(f"  Found existing {resource_type}: {item[id_key]}")
                return item[id_key]

    result = api("POST", create_path, create_data)
    if result and id_key in result:
        print(f"  Created {resource_type}: {result[id_key]}")
        return result[id_key]

    print(f"  ERROR: could not create {resource_type}", file=sys.stderr)
    return None

# --- Lookup ClickHouse definition ID (shared across connectors) ---
ch_def_id = state.get("clickhouse_definition_id")
if not ch_def_id:
    defs = api("POST", "/api/v1/destination_definitions/list", {"workspaceId": workspace_id})
    if defs:
        for d in defs.get("destinationDefinitions", []):
            if "clickhouse" in d["name"].lower():
                ch_def_id = d["destinationDefinitionId"]
                break
if not ch_def_id:
    print("  ERROR: ClickHouse destination definition not found in Airbyte", file=sys.stderr)
    sys.exit(1)
state["clickhouse_definition_id"] = ch_def_id

# --- Per-connector sources + connections ---
state.setdefault("connectors", {})

for connector_name, creds in tenant.get("connectors", {}).items():
    print(f"  Connector: {connector_name}")

    # Find descriptor
    descriptor_path = None
    for p in pathlib.Path(connectors_dir).rglob("descriptor.yaml"):
        with open(p) as f:
            desc = yaml.safe_load(f)
        if desc.get("name") == connector_name:
            descriptor_path = p
            break

    if not descriptor_path:
        print(f"    SKIP: no descriptor for {connector_name}")
        continue

    with open(descriptor_path) as f:
        descriptor = yaml.safe_load(f)

    conn_state = state["connectors"].setdefault(connector_name, {})

    # Create ClickHouse database for this connector
    db_name = descriptor.get("connection", {}).get("namespace", f"bronze_{connector_name}")
    print(f"    Creating database: {db_name}")
    os.system(f'kubectl exec -n data deploy/clickhouse -- clickhouse-client --password clickhouse --query "CREATE DATABASE IF NOT EXISTS {db_name}" 2>/dev/null')

    # Create/find per-connector destination (database = bronze_{name})
    dest_name = f"clickhouse-{connector_name}"
    dest_id = conn_state.get("destination_id")
    if not dest_id:
        existing = api("POST", "/api/v1/destinations/list", {"workspaceId": workspace_id})
        if existing:
            for d in existing.get("destinations", []):
                if d["name"] == dest_name:
                    dest_id = d["destinationId"]
                    print(f"    Destination found: {dest_id}")
                    break
    if not dest_id:
        result = api("POST", "/api/v1/destinations/create", {
            "workspaceId": workspace_id,
            "name": dest_name,
            "destinationDefinitionId": ch_def_id,
            "connectionConfiguration": {
                "host": dest_config.get("host", "clickhouse.data.svc.cluster.local"),
                "port": str(dest_config.get("port", 8123)),
                "database": db_name,
                "username": dest_config.get("username", "default"),
                "password": dest_config.get("password", "clickhouse"),
                "protocol": "http",
                "enable_json": True,
            }
        })
        if result and "destinationId" in result:
            dest_id = result["destinationId"]
            print(f"    Destination created: {dest_id}")
        else:
            print(f"    ERROR: could not create destination for {connector_name}: {result}", file=sys.stderr)
            continue
    conn_state["destination_id"] = dest_id

    # Find source definition ID (prefer exact name match over case-insensitive)
    def_id = conn_state.get("definition_id")
    if not def_id:
        defs = api("POST", "/api/v1/source_definitions/list", {"workspaceId": workspace_id})
        if defs:
            # Exact match first (our custom connectors use lowercase names)
            for d in defs.get("sourceDefinitions", []):
                if d["name"] == connector_name:
                    def_id = d["sourceDefinitionId"]
                    break
            # Fallback to case-insensitive
            if not def_id:
                for d in defs.get("sourceDefinitions", []):
                    if d["name"].lower() == connector_name.lower():
                        def_id = d["sourceDefinitionId"]
                        break
    if not def_id:
        print(f"    SKIP: source definition not found for {connector_name} (run upload-manifests first)")
        continue
    conn_state["definition_id"] = def_id

    # Create/find source
    source_name = f"{connector_name}-{tenant_id}"
    source_id = conn_state.get("source_id")
    if not source_id:
        # Fill in tenant_id in credentials
        config = dict(creds)
        if "insight_tenant_id" not in config or config["insight_tenant_id"] == "${tenant_id}":
            config["insight_tenant_id"] = tenant_id

        source_id = find_or_create(
            "source",
            "/api/v1/sources/list", "sources",
            "/api/v1/sources/create",
            {
                "workspaceId": workspace_id,
                "name": source_name,
                "sourceDefinitionId": def_id,
                "connectionConfiguration": config,
            },
            "sourceId", "name", source_name
        )
    if not source_id:
        print(f"    ERROR: no source created for {connector_name}")
        continue
    conn_state["source_id"] = source_id

    # Create/find connection
    connection_config = descriptor.get("connection", {})
    connection_name = f"{connector_name}-to-clickhouse-{tenant_id}"
    connection_id = conn_state.get("connection_id")

    if not connection_id:
        configured_streams = connection_config.get("streams", [])
        configured_names = {s["name"] for s in configured_streams}

        # Discover real schema from source
        print(f"    Discovering schema from source...")
        discover_result = api("POST", "/api/v1/sources/discover_schema", {
            "sourceId": source_id,
            "disable_cache": True,
        })

        # Build catalog from discovered schema + configured streams
        sync_catalog = {"streams": []}
        if discover_result and "catalog" in discover_result:
            for entry in discover_result["catalog"].get("streams", []):
                # Discover returns {"stream": {...}, "config": {...}}
                stream_def = entry.get("stream", entry)
                stream_name = stream_def.get("name", "")
                # Include all streams if no explicit list, otherwise filter
                if configured_names and stream_name not in configured_names:
                    continue

                supported = stream_def.get("supportedSyncModes", ["full_refresh"])
                sync_mode = "incremental" if "incremental" in supported else "full_refresh"
                # Always use append_dedup — ClickHouse destination v2 NPEs on overwrite with no cursor
                dest_sync_mode = "append_dedup"

                stream_config = {
                    "syncMode": sync_mode,
                    "destinationSyncMode": dest_sync_mode,
                    "selected": True,
                }
                # Use source-defined primary key and cursor if available
                if stream_def.get("sourceDefinedPrimaryKey"):
                    stream_config["primaryKey"] = stream_def["sourceDefinedPrimaryKey"]
                if stream_def.get("defaultCursorField"):
                    stream_config["cursorField"] = stream_def["defaultCursorField"]

                sync_catalog["streams"].append({
                    "stream": stream_def,
                    "config": stream_config,
                })
                print(f"      Stream: {stream_name} ({sync_mode})")
        else:
            print(f"    WARNING: discover failed, creating connection without catalog")

        connection_id = find_or_create(
            "connection",
            "/api/v1/connections/list", "connections",
            "/api/v1/connections/create",
            {
                "sourceId": source_id,
                "destinationId": dest_id,
                "name": connection_name,
                "namespaceDefinition": "destination",
                "status": "active",
                "syncCatalog": sync_catalog,
            },
            "connectionId", "name", connection_name
        )
    if connection_id:
        conn_state["connection_id"] = connection_id
        print(f"    Connection: {connection_id}")

# Save state to file
state["workspace_id"] = workspace_id
with open(state_path, "w") as f:
    yaml.dump(state, f, default_flow_style=False)

# Persist state as K8s ConfigMap (survives pod restarts)
cm_name = f"connection-state-{config_basename}"
os.system(f'kubectl create configmap {cm_name} --from-file=state.yaml={state_path} -n data --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null')

print(f"  State saved: {state_path} + configmap/{cm_name}")
PYTHON
}

# --- Main ---
if [[ "${1:-}" == "--all" ]]; then
  for config_file in "${CONNECTIONS_DIR}"/*.yaml; do
    [[ -f "$config_file" ]] || continue
    tenant=$(basename "$config_file" .yaml)
    echo "  Applying connections for tenant: $tenant"
    apply_tenant "$config_file"
  done
else
  tenant="${1:?Usage: $0 <tenant_id> | --all}"
  config_file="${CONNECTIONS_DIR}/${tenant}.yaml"
  [[ -f "$config_file" ]] || { echo "ERROR: no config at ${config_file}" >&2; exit 1; }
  echo "  Applying connections for tenant: $tenant"
  apply_tenant "$config_file"
fi

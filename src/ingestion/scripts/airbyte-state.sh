#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Airbyte state library — source this file to use state_get / state_set.
#
# Storage backend auto-detected:
#   Host:       connections/.airbyte-state.yaml
#   In-cluster: ConfigMap airbyte-state in namespace data
#
# Usage:
#   source ./scripts/airbyte-state.sh
#   state_set "definitions.zoom" "abc-123"
#   state_get "definitions.zoom"   # → abc-123
#   state_get_all                  # → full YAML
# ---------------------------------------------------------------------------

INGESTION_DIR="${INGESTION_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_FILE="${INGESTION_DIR}/connections/.airbyte-state.yaml"
STATE_CM_NAME="airbyte-state"
STATE_CM_NS="data"

_state_in_cluster() {
  [[ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]]
}

_state_init() {
  if _state_in_cluster; then
    kubectl get configmap "$STATE_CM_NAME" -n "$STATE_CM_NS" >/dev/null 2>&1 || \
      kubectl create configmap "$STATE_CM_NAME" -n "$STATE_CM_NS" --from-literal=state.yaml="{}" 2>/dev/null
  fi
  [[ -f "$STATE_FILE" ]] || echo "{}" > "$STATE_FILE"
}

# state_get <dotpath>
# e.g. state_get "definitions.zoom" → "abc-123"
state_get() {
  local path="$1"
  _state_init
  local src="$STATE_FILE"
  if _state_in_cluster; then
    src="/tmp/_airbyte_state.yaml"
    kubectl get configmap "$STATE_CM_NAME" -n "$STATE_CM_NS" -o jsonpath='{.data.state\.yaml}' > "$src" 2>/dev/null || echo "{}" > "$src"
  fi
  python3 -c "
import yaml, sys
d = yaml.safe_load(open('$src')) or {}
for k in '$path'.split('.'):
    if isinstance(d, dict):
        d = d.get(k, '')
    else:
        d = ''
        break
print(d if isinstance(d, str) else '')
"
}

# state_set <dotpath> <value>
# e.g. state_set "definitions.zoom" "abc-123"
state_set() {
  local path="$1" value="$2"
  _state_init
  python3 - "$STATE_FILE" "$path" "$value" <<'PY'
import sys, yaml, os
state_file, path, value = sys.argv[1], sys.argv[2], sys.argv[3]
data = yaml.safe_load(open(state_file)) if os.path.exists(state_file) and os.path.getsize(state_file) > 0 else {}
if not data: data = {}
keys = path.split(".")
d = data
for k in keys[:-1]:
    d = d.setdefault(k, {})
d[keys[-1]] = value
with open(state_file, "w") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)
PY

  if _state_in_cluster; then
    kubectl create configmap "$STATE_CM_NAME" -n "$STATE_CM_NS" \
      --from-file=state.yaml="$STATE_FILE" --dry-run=client -o yaml | \
      kubectl apply -f - >/dev/null 2>&1
  fi
}

# state_get_all — dump entire state
state_get_all() {
  _state_init
  if _state_in_cluster; then
    kubectl get configmap "$STATE_CM_NAME" -n "$STATE_CM_NS" -o jsonpath='{.data.state\.yaml}' 2>/dev/null
  else
    cat "$STATE_FILE" 2>/dev/null
  fi
}

#!/usr/bin/env bash
# Trigger Airbyte sync for all connections in state.yaml.
#
# Usage:
#   ./sync-all.sh                     # sync all connections
#   ./sync-all.sh --tenant test-local # sync connections for one tenant
#
# Reads connection IDs from airbyte-toolkit/state.yaml and triggers
# Airbyte API sync for each. Does NOT run dbt transforms — those
# happen via Argo ingestion-pipeline workflows or manually.
#
# Prerequisites:
#   - Airbyte running and port-forwarded (localhost:8001)
#   - state.yaml populated by connect.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"
export TOOLKIT_DIR="${SCRIPT_DIR}/airbyte-toolkit"

source "${TOOLKIT_DIR}/lib/env.sh"
source "${TOOLKIT_DIR}/lib/state.sh"

# Parse args
TENANT_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      if [[ -z "${2-}" ]]; then
        echo "ERROR: --tenant requires a value (e.g. --tenant test-local)" >&2
        exit 1
      fi
      TENANT_FILTER="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Collect all connection IDs from state
CONNECTION_IDS=()
CONNECTION_LABELS=()

for tenant in $(state_list "tenants"); do
  [[ -n "$TENANT_FILTER" && "$tenant" != "$TENANT_FILTER" ]] && continue
  for connector in $(state_list "tenants.${tenant}.connectors"); do
    for source_key in $(state_list "tenants.${tenant}.connectors.${connector}"); do
      conn_id=$(state_get "tenants.${tenant}.connectors.${connector}.${source_key}.connection_id")
      if [[ -n "$conn_id" ]]; then
        CONNECTION_IDS+=("$conn_id")
        CONNECTION_LABELS+=("${connector}/${source_key}")
      fi
    done
  done
done

if [[ ${#CONNECTION_IDS[@]} -eq 0 ]]; then
  echo "No connections found in state. Run connect.sh --all first."
  exit 1
fi

echo "=== Triggering Airbyte sync for ${#CONNECTION_IDS[@]} connection(s) ==="

FAILED=0
for i in "${!CONNECTION_IDS[@]}"; do
  cid="${CONNECTION_IDS[$i]}"
  label="${CONNECTION_LABELS[$i]}"
  echo -n "  ${label} (${cid})... "
  if result=$(curl -sf --connect-timeout 10 --max-time 60 \
      -X POST "${AIRBYTE_API}/api/v1/connections/sync" \
      -H "Authorization: Bearer ${AIRBYTE_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "{\"connectionId\":\"${cid}\"}" 2>&1); then
    job_id=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('job',{}).get('id','?'))" 2>/dev/null || echo "?")
    echo "started (job: ${job_id})"
  else
    echo "FAILED"
    FAILED=$((FAILED + 1))
  fi
done

echo ""
echo "=== Done: $((${#CONNECTION_IDS[@]} - FAILED)) started, ${FAILED} failed ==="
echo "  Monitor: http://localhost:8001 (Airbyte UI)"
echo "  Monitor: http://localhost:30500 (Argo UI)"

# Propagate partial failure so CI / orchestration treats a mixed result
# as failure, not success.
[[ $FAILED -gt 0 ]] && exit 1
exit 0

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONNECTOR="${1:?Usage: $0 <connector> <tenant_id>}"
TENANT="${2:?Usage: $0 <connector> <tenant_id>}"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kind-ingestion}"

# Read connection_id from state (check per-tenant state files and main state)
CONNECTION_ID=$(python3 -c "
import yaml, glob, sys

connector = '${CONNECTOR}'
tenant = '${TENANT}'

# Search in per-tenant state files first, then main state
state_files = glob.glob('connections/.state/*.yaml') + ['connections/.airbyte-state.yaml']
for sf in state_files:
    try:
        state = yaml.safe_load(open(sf)) or {}
    except Exception:
        continue
    conns = state.get('tenants', {}).get(tenant, {}).get('connections', {})
    if not conns:
        continue
    # Exact match
    if connector in conns:
        print(conns[connector])
        sys.exit(0)
    # Prefix match: m365 → m365-m365-main
    for k, v in conns.items():
        if k.startswith(connector + '-'):
            print(v)
            sys.exit(0)
" 2>/dev/null)
[[ -n "$CONNECTION_ID" ]] || { echo "ERROR: no connection_id for connector '$CONNECTOR' tenant '$TENANT'. Run update-connections.sh first." >&2; exit 1; }

# Find descriptor by connector name — try exact match, then prefix match
DBT_SELECT=$(python3 -c "
import yaml, pathlib, sys
connector = '${CONNECTOR}'
for p in sorted(pathlib.Path('connectors').rglob('descriptor.yaml')):
    desc = yaml.safe_load(open(p))
    name = desc.get('name', '')
    if name == connector or connector.startswith(name + '-'):
        print(desc.get('dbt_select', '+tag:silver'))
        sys.exit(0)
print('+tag:silver')
" 2>/dev/null)

echo "Running sync: ${CONNECTOR} / ${TENANT}"
echo "  connection_id: ${CONNECTION_ID}"
echo "  dbt_select: ${DBT_SELECT}"

kubectl create -n argo -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: ${CONNECTOR}-${TENANT//_/-}-
  namespace: argo
  labels:
    tenant: "${TENANT}"
    connector: "${CONNECTOR}"
spec:
  entrypoint: run
  templates:
    - name: run
      steps:
        - - name: pipeline
            templateRef:
              name: ingestion-pipeline
              template: pipeline
            arguments:
              parameters:
                - name: connection_id
                  value: "${CONNECTION_ID}"
                - name: dbt_select
                  value: "${DBT_SELECT}"
EOF

echo "Workflow submitted. Monitor at http://localhost:30500 or:"
echo "  kubectl get workflows -n argo -l connector=${CONNECTOR},tenant=${TENANT}"

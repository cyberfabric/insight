#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONNECTOR="${1:?Usage: $0 <connector> <tenant_id>}"
TENANT="${2:?Usage: $0 <connector> <tenant_id>}"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/kind-ingestion}"

# Read connection_id from Airbyte state
source ./scripts/airbyte-state.sh
CONNECTION_ID=$(state_get "tenants.${TENANT}.connections.${CONNECTOR}")
[[ -n "$CONNECTION_ID" ]] || { echo "ERROR: no connection_id for connector '$CONNECTOR' tenant '$TENANT'. Run update-connections.sh first." >&2; exit 1; }

DBT_SELECT=$(find connectors -name descriptor.yaml -exec grep -l "name: ${CONNECTOR}" {} \; | head -1 | xargs yq -r '.dbt_select // "+tag:silver"' 2>/dev/null)

echo "Running sync: ${CONNECTOR} / ${TENANT}"
echo "  connection_id: ${CONNECTION_ID}"
echo "  dbt_select: ${DBT_SELECT}"

kubectl create -n argo -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: ${CONNECTOR}-${TENANT}-
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

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CONNECTOR="${1:?Usage: $0 <connector> <tenant_id>}"
TENANT="${2:?Usage: $0 <connector> <tenant_id>}"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"
export TOOLKIT_DIR="${SCRIPT_DIR}/airbyte-toolkit"
source "${TOOLKIT_DIR}/lib/state.sh"

# Read connection_id from state — iterate source_ids under the connector
CONNECTION_ID=""
for source_key in $(state_list "tenants.${TENANT}.connectors.${CONNECTOR}"); do
  CONNECTION_ID=$(state_get "tenants.${TENANT}.connectors.${CONNECTOR}.${source_key}.connection_id")
  [[ -n "$CONNECTION_ID" ]] && break
done
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

# ─── Resolve toolbox_image for the dbt-run step ────────────────────────────
# Precedence:
#   1. $TOOLBOX_IMAGE env var (explicit caller override)
#   2. Auto-detect on Kind: if the current kubectl context is a kind cluster
#      AND the Kind node has a locally-loaded `insight-toolbox:local` image
#      (put there by up.sh → `kind load docker-image`), use that image.
#   3. Fallback: ghcr.io/cyberfabric/insight-toolbox:latest (prod).
#
# Without this, the workflow template's default fetches the :latest tag
# from ghcr.io, which requires imagePullSecrets and network access — both
# absent on a fresh local Kind cluster. The dbt-run pod then sits in
# ImagePullBackOff / Pending until the workflow's 30-minute activeDeadline
# kills it, leaving Bronze populated but Silver never materialised.
TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-}"
if [[ -z "$TOOLBOX_IMAGE" ]]; then
  _ctx=$(kubectl config current-context 2>/dev/null || echo "")
  if [[ "$_ctx" == kind-* ]]; then
    _node="${_ctx#kind-}-control-plane"
    if docker exec "$_node" crictl images 2>/dev/null | grep -qE "^docker\.io/library/insight-toolbox\s+local\b"; then
      TOOLBOX_IMAGE="insight-toolbox:local"
      echo "  toolbox_image: $TOOLBOX_IMAGE (auto-detected, loaded in kind node)"
    fi
  fi
  TOOLBOX_IMAGE="${TOOLBOX_IMAGE:-ghcr.io/cyberfabric/insight-toolbox:latest}"
fi

echo "Running sync: ${CONNECTOR} / ${TENANT}"
echo "  connection_id: ${CONNECTION_ID}"
echo "  dbt_select:    ${DBT_SELECT}"
echo "  toolbox_image: ${TOOLBOX_IMAGE}"

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
                - name: toolbox_image
                  value: "${TOOLBOX_IMAGE}"
EOF

echo "Workflow submitted. Monitor at http://localhost:30500 or:"
echo "  kubectl get workflows -n argo -l connector=${CONNECTOR},tenant=${TENANT}"

#!/usr/bin/env bash
set -euo pipefail

# Run only the Silver transformations for Jira on bronze data that's already
# in ClickHouse (no Airbyte sync). Steps:
#   1. dbt run --select tag:jira              — staging models
#   2. tt-enrich-jira-run                     — Rust binary writes task_field_history
#   3. dbt run --select tag:silver,tag:jira+  — silver models downstream of jira (class_task_*)
#
# All ingestion infrastructure parameters (toolbox_image, jira_enrich_image,
# clickhouse_host/port/user, batch_size) come from WorkflowTemplate defaults —
# see charts/insight/templates/ingestion/{dbt-run,tt-enrich-jira-run}.yaml.
#
# Usage:
#   ./run-tt-enrich-jira.sh <tenant> [<insight_source_id>]
#
# When <insight_source_id> is omitted, it is read from the Jira Secret
# annotation `insight.cyberfabric.com/source-id` in the release namespace.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TENANT="${1:?Usage: $0 <tenant> [<insight_source_id>]}"
SOURCE_ID="${2:-}"

NAMESPACE="${INSIGHT_NAMESPACE:-insight}"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"

# ─── Resolve insight_source_id from Secret annotation ───────────────────
# Single-namespace model: connector Secrets live in the same namespace as
# the umbrella (default `insight`). Multi-tenant clusters use multiple
# namespaces; we filter by tenant to avoid picking the wrong source.
if [[ -z "$SOURCE_ID" ]]; then
  SOURCE_ID=$(TENANT="$TENANT" \
    kubectl get secret -n "$NAMESPACE" -l app.kubernetes.io/part-of=insight -o json \
    | python3 -c "
import json, os, sys
tenant = os.environ['TENANT']
matches = []
for s in json.load(sys.stdin).get('items', []):
    ann = (s.get('metadata') or {}).get('annotations') or {}
    if ann.get('insight.cyberfabric.com/connector') != 'jira':
        continue
    # tenant annotation optional — if missing, accept any tenant the caller asked for
    sec_tenant = ann.get('insight.cyberfabric.com/tenant', tenant)
    if sec_tenant != tenant:
        continue
    sid = ann.get('insight.cyberfabric.com/source-id', '')
    if sid:
        matches.append(sid)
if len(matches) == 1:
    print(matches[0])
elif len(matches) > 1:
    sys.stderr.write(f'ERROR: multiple Jira secrets match tenant {tenant}: {matches}\n')
    sys.exit(2)
" 2>/dev/null)
fi
[[ -n "$SOURCE_ID" ]] || {
  echo "ERROR: could not resolve insight_source_id for tenant '$TENANT'." >&2
  echo "       Pass it explicitly as the second argument." >&2
  exit 1
}

echo "Running Jira tt-enrich (staging-jira → enrich → silver):"
echo "  namespace:         $NAMESPACE"
echo "  tenant:            $TENANT"
echo "  insight_source_id: $SOURCE_ID"

# Inline DAG that chains three pre-registered WorkflowTemplate steps.
# We don't pass image tags or clickhouse coordinates — chart defaults fire.
kubectl create -n "$NAMESPACE" -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: jira-${TENANT//_/-}-tt-enrich-
  namespace: $NAMESPACE
  labels:
    tenant: "$TENANT"
    connector: "jira"
    workflow-kind: "tt-enrich"
    # Controller picks up workflows by this label — value MUST match
    # `instanceID` in the argo-workflows-workflow-controller ConfigMap.
    workflows.argoproj.io/controller-instanceid: argo-workflows-insight
spec:
  serviceAccountName: argo-workflow
  entrypoint: run
  templates:
    - name: run
      dag:
        tasks:
          - name: staging-jira
            templateRef:
              name: dbt-run
              template: run
            arguments:
              parameters:
                - name: dbt_select
                  value: "tag:jira"

          - name: enrich
            depends: staging-jira
            templateRef:
              name: tt-enrich-jira-run
              template: run
            arguments:
              parameters:
                - name: insight_source_id
                  value: "$SOURCE_ID"

          - name: silver
            depends: enrich
            templateRef:
              name: dbt-run
              template: run
            arguments:
              parameters:
                - name: dbt_select
                  value: "tag:silver,tag:jira+"
EOF

echo
echo "Monitor:"
echo "  kubectl -n $NAMESPACE get workflows -l connector=jira,workflow-kind=tt-enrich --watch"

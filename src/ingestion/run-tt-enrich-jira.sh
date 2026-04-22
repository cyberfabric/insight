#!/usr/bin/env bash
set -euo pipefail

# Run only the Silver transformations for Jira on bronze data that's already in ClickHouse.
# Steps (no Airbyte sync):
#   1. dbt run --select jira        — builds per-source staging models (staging.jira__*)
#   2. jira-enrich                  — rust binary writes staging.jira__task_field_history
#   3. dbt run --select tag:silver  — unions staging into silver.class_task_* via union_by_tag
#
# Usage:
#   ./run-tt-enrich-jira.sh <tenant> [<insight_source_id>]
#
# If <insight_source_id> is omitted, it is read from the K8s Secret annotation
# `insight.cyberfabric.com/source-id` of the Jira Secret in the `data` namespace.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TENANT="${1:?Usage: $0 <tenant> [<insight_source_id>]}"
SOURCE_ID="${2:-}"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/insight.kubeconfig}"

# Resolve insight_source_id from Secret annotation if not passed.
# Filter by BOTH connector and tenant — in a multi-tenant cluster several Jira secrets
# coexist and picking "the first one" gets the wrong source silently.
if [[ -z "$SOURCE_ID" ]]; then
    SOURCE_ID=$(TENANT="$TENANT" kubectl get secret -n data \
        -l app.kubernetes.io/part-of=insight \
        -o json | \
        python3 -c "
import json, os, sys
tenant = os.environ['TENANT']
secrets = json.load(sys.stdin).get('items', [])
matches = []
for s in secrets:
    ann = s.get('metadata', {}).get('annotations', {}) or {}
    if ann.get('insight.cyberfabric.com/connector') != 'jira':
        continue
    if ann.get('insight.cyberfabric.com/tenant') != tenant:
        continue
    sid = ann.get('insight.cyberfabric.com/source-id', '')
    if sid:
        matches.append(sid)
if len(matches) == 1:
    print(matches[0])
elif len(matches) > 1:
    sys.stderr.write(f'ERROR: multiple Jira secrets match tenant {tenant}: {matches}\n')
    sys.exit(2)
")
fi
[[ -n "$SOURCE_ID" ]] || { echo "ERROR: could not resolve insight_source_id for tenant '${TENANT}'; pass it explicitly as the second arg" >&2; exit 1; }

echo "Running Jira Silver transforms (dbt jira → enrich → dbt silver)"
echo "  tenant:            ${TENANT}"
echo "  insight_source_id: ${SOURCE_ID}"

kubectl create -n argo -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: jira-${TENANT//_/-}-tt-enrich-
  namespace: argo
  labels:
    tenant: "${TENANT}"
    connector: "jira"
    workflow-kind: "tt-enrich"
spec:
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
                  value: "${SOURCE_ID}"

          - name: silver
            depends: enrich
            templateRef:
              name: dbt-run
              template: run
            arguments:
              parameters:
                - name: dbt_select
                  value: "tag:silver"
EOF

echo
echo "Workflow submitted. Monitor:"
echo "  Argo UI:   http://localhost:30500"
echo "  kubectl:   kubectl get workflows -n argo -l connector=jira,workflow-kind=tt-enrich --watch"

# Generic sync CronWorkflow template
# Variables resolved by sync-flows.sh from descriptor.yaml + connection state:
#   CONNECTOR, TENANT_ID, CONNECTION_ID, SCHEDULE, DBT_SELECT

apiVersion: argoproj.io/v1alpha1
kind: CronWorkflow
metadata:
  name: ${CONNECTOR}-sync
  namespace: argo
  labels:
    app.kubernetes.io/part-of: ingestion
    tenant: "${TENANT_ID}"
    connector: "${CONNECTOR}"
spec:
  schedules:
    - "${SCHEDULE}"
  timezone: UTC
  concurrencyPolicy: Replace
  startingDeadlineSeconds: 600
  workflowSpec:
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

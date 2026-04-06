---
name: connector
description: "Create, test, validate, and deploy Insight Connectors"
---

# Connector Skill

Manages the full lifecycle of Insight Connectors: creation, testing, schema generation, validation, and deployment.

## References

Before executing any workflow, read the connector specification:
- **DESIGN**: `docs/domain/connector/specs/DESIGN.md` — mandatory fields, manifest rules, package structure
- **README**: `src/ingestion/README.md` — commands, project structure

## Command Routing

Parse the user's command and route to the appropriate workflow:

| Command | Workflow | Description |
|---------|----------|-------------|
| `/connector create <name>` | [create.md](workflows/create.md) | Create new connector package |
| `/connector test <name>` | [test.md](workflows/test.md) | Test connector (check, discover, read) |
| `/connector schema <name>` | [schema.md](workflows/schema.md) | Generate JSON schema from real data |
| `/connector validate <name>` | [validate.md](workflows/validate.md) | Validate package against spec |
| `/connector deploy <name>` | [deploy.md](workflows/deploy.md) | Deploy to Airbyte + Argo |
| `/connector workflow <name>` | [workflow.md](workflows/workflow.md) | Create/customize Argo workflow templates |
| `/connector logs [job-id\|latest]` | Direct | Show Airbyte job or Argo workflow logs |

## Airbyte Logs

ALWAYS use `{INGESTION_DIR}/logs.sh` to read Airbyte job logs or Argo workflow logs. NEVER call Airbyte REST API directly for log retrieval.

| Use case | Command |
|----------|---------|
| Airbyte job by ID | `./logs.sh airbyte <job-id>` |
| Latest Airbyte job | `./logs.sh airbyte latest` |
| Argo workflow logs | `./logs.sh <workflow-name\|latest>` |
| Only sync step | `./logs.sh <workflow\|latest> sync` |
| Only dbt step | `./logs.sh <workflow\|latest> dbt` |
| Follow live | `./logs.sh -f <workflow\|latest>` |

ALWAYS run `logs.sh` from `{INGESTION_DIR}` directory with `KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kind-ingestion}"`.

## E2E Sync

E2E (end-to-end) sync means running the full pipeline through Argo, not just triggering an Airbyte sync via API. The Argo pipeline includes: Airbyte sync → dbt transformations (Bronze → Silver). Without Argo, dbt models are not executed and Silver tables are not populated.

ALWAYS use `{INGESTION_DIR}/run-sync.sh <connector> <tenant>` for e2e sync. This submits an Argo workflow that runs the complete ingestion pipeline.

ALWAYS use `./logs.sh -f latest` or `./logs.sh latest` to monitor the Argo workflow (which includes both sync and dbt steps).

NEVER consider a raw Airbyte API sync (`/api/v1/connections/sync`) as e2e — it only populates Bronze tables.

| Step | What it does | Tool |
|------|-------------|------|
| Airbyte sync | API → ClickHouse Bronze tables | `run-sync.sh` (step 1) |
| dbt run | Bronze → Silver transformations | `run-sync.sh` (step 2) |
| Full e2e | Both steps via Argo DAG | `./run-sync.sh <connector> <tenant>` |

## Service Credentials

ALWAYS obtain credentials from the cluster, not from hardcoded values.

### ClickHouse

| Environment | How to get credentials |
|-------------|----------------------|
| Local (Kind) | Defined in `{INGESTION_DIR}/k8s/clickhouse/configmap.yaml` (`default.xml` → `<users><default><password>`) |
| Any cluster | `kubectl get configmap clickhouse-config -n data -o jsonpath='{.data.default\.xml}'` and parse `<password>` |
| Tenant config | `yq '.destination' {INGESTION_DIR}/connections/<tenant>.yaml` |

Quick test: `kubectl exec -n data deploy/clickhouse -- clickhouse-client --password <password> --query "SELECT currentUser()"`

### Airbyte

| Environment | How to get credentials |
|-------------|----------------------|
| Local (Kind) | API at `http://localhost:8000`, token via `{INGESTION_DIR}/scripts/resolve-airbyte-env.sh` |
| In-cluster | API at `http://airbyte-airbyte-server-svc.airbyte.svc.cluster.local:8001` |
| Any cluster | `source {INGESTION_DIR}/scripts/resolve-airbyte-env.sh` → sets `AIRBYTE_API`, `AIRBYTE_TOKEN`, `WORKSPACE_ID` |

Quick test: `curl -s -H "Authorization: Bearer $AIRBYTE_TOKEN" "$AIRBYTE_API/api/v1/health"`

### Argo

| Environment | How to get credentials |
|-------------|----------------------|
| Local (Kind) | UI at `http://localhost:30500`, no auth |
| Any cluster | `kubectl -n argo port-forward svc/argo-server 2746:2746` then `http://localhost:2746` |

Quick test: `kubectl get workflows -n argo --no-headers | tail -5`

### Argument Parsing

```
/connector <command> <name> [options]

<name>     Connector name (e.g. m365, bamboohr, jira)
           Or full path: collaboration/m365, hr-directory/bamboohr
```

If `<name>` is not a path, search `src/ingestion/connectors/` for it.

If `<command>` is omitted, show available commands and existing connectors.

### Context Variables

Set these before routing to workflow:

| Variable | Source | Example |
|----------|--------|---------|
| `CONNECTOR_NAME` | from argument | `m365` |
| `CONNECTOR_PATH` | resolved | `collaboration/m365` |
| `CONNECTOR_DIR` | full path | `src/ingestion/connectors/collaboration/m365` |
| `CONNECTOR_TYPE` | from descriptor.yaml or user input | `nocode` or `cdk` |
| `INGESTION_DIR` | fixed | `src/ingestion` |

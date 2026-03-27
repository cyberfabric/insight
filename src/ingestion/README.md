# Ingestion Stack

Data pipeline: External APIs → Airbyte → ClickHouse Bronze → dbt → Silver.
Everything runs in a Kind Kubernetes cluster.

## Prerequisites

```bash
brew install kind kubectl helm
```

## Quick Start

```bash
# 1. Copy tenant config and fill in credentials
cp connections/example-tenant.yaml.example connections/my-tenant.yaml
# Edit my-tenant.yaml with real API keys

# 2. Start the stack
./up.sh

# 3. Run a sync
./run-sync.sh m365 my-tenant
```

## Commands

### Lifecycle

| Command | Description |
|---------|-------------|
| `./up.sh` | Start all services (idempotent, safe to re-run) |
| `./down.sh` | Stop all services. **Data preserved** |
| `./cleanup.sh` | Delete cluster and all data. Asks for confirmation |

### Day-to-day

| Command | Description |
|---------|-------------|
| `./run-sync.sh <connector> <tenant>` | Run sync + dbt pipeline now |
| `./update-connectors.sh` | Re-upload connector manifests to Airbyte |
| `./update-connections.sh [tenant]` | Re-create sources, destinations, connections |
| `./update-workflows.sh [tenant]` | Regenerate CronWorkflow schedules |

### Examples

```bash
# Run M365 sync for example_tenant
./run-sync.sh m365 example-tenant

# Update after editing connector.yaml
./update-connectors.sh

# Update after changing tenant credentials
./update-connections.sh example-tenant

# Update after changing schedule in descriptor.yaml
./update-workflows.sh

# Monitor workflows
open http://localhost:30500
```

## Services

After `./up.sh`:

| Service | URL | Credentials |
|---------|-----|-------------|
| Airbyte | http://localhost:8000 | Printed by `up.sh` |
| Argo UI | http://localhost:30500 | No auth (local) |
| ClickHouse | http://localhost:30123 | `default` / `clickhouse` |

## Project Structure

```
src/ingestion/
│
├── up.sh / down.sh / cleanup.sh    # Cluster lifecycle
├── run-sync.sh                      # Manual pipeline run
├── update-connectors.sh             # Re-upload manifests
├── update-connections.sh            # Re-apply connections
├── update-workflows.sh              # Regenerate schedules
│
├── connectors/                      # Connector packages
│   └── collaboration/m365/
│       ├── connector.yaml           #   Airbyte declarative manifest
│       ├── descriptor.yaml          #   Schedule, streams, dbt_select
│       ├── .env.local               #   Test credentials (gitignored)
│       └── dbt/
│           ├── to_comms_events.sql  #   Bronze → Silver model
│           └── schema.yml           #   Source + tests
│
├── connections/                     # Tenant configs
│   ├── example-tenant.yaml.example  #   Template (tracked)
│   ├── example-tenant.yaml          #   Real credentials (gitignored)
│   └── .state/                      #   Generated IDs (gitignored)
│
├── dbt/                             # Shared dbt project
│   ├── dbt_project.yml
│   ├── profiles.yml
│   ├── silver/                      #   Union models (class_*)
│   └── macros/                      #   union_by_tag
│
├── workflows/
│   ├── templates/                   #   Argo WorkflowTemplates (tracked)
│   │   ├── airbyte-sync.yaml        #     Trigger sync + poll
│   │   ├── dbt-run.yaml             #     Run dbt in container
│   │   └── ingestion-pipeline.yaml  #     DAG: sync → dbt
│   └── schedules/
│       └── sync.yaml.tpl            #   CronWorkflow template (tracked)
│
├── k8s/                             # Kubernetes manifests
│   ├── kind-config.yaml             #   Kind cluster config
│   ├── airbyte/                     #   Helm values (local + production)
│   ├── argo/                        #   Helm values + RBAC
│   └── clickhouse/                  #   Deployment, Service, PVC, ConfigMap
│
├── scripts/                         # Internal scripts (used by toolbox)
│   ├── init.sh                      #   Full initialization
│   ├── resolve-airbyte-env.sh       #   JWT token + workspace resolution
│   ├── upload-manifests.sh          #   Register connectors via API
│   ├── apply-connections.sh         #   Create sources/destinations/connections
│   ├── sync-flows.sh               #   Generate + apply CronWorkflows
│   └── wait-for-services.sh        #   kubectl wait for pods
│
└── tools/
    ├── toolbox/                     # insight-toolbox Docker image
    │   ├── Dockerfile               #   python + dbt + kubectl + yq + tofu
    │   └── build.sh                 #   Build + load into Kind
    └── declarative-connector/       # Local connector debugging
        └── source.sh               #   check / discover / read
```

## Adding a New Connector

1. Create package:
   ```
   connectors/{category}/{name}/
     connector.yaml       # Airbyte manifest
     descriptor.yaml      # name, schedule, streams, dbt_select, workflow
     dbt/
       to_{domain}.sql    # Transformation
       schema.yml         # Source definition + tests
   ```

2. Add credentials to tenant config:
   ```yaml
   # connections/my-tenant.yaml
   connectors:
     new_connector:
       api_key: "..."
   ```

3. Deploy:
   ```bash
   ./update-connectors.sh
   ./update-connections.sh my-tenant
   ./update-workflows.sh my-tenant
   ```

## Adding a New Tenant

1. Copy example config:
   ```bash
   cp connections/example-tenant.yaml.example connections/acme.yaml
   ```

2. Fill in credentials and set `tenant_id: acme`

3. Deploy:
   ```bash
   ./update-connections.sh acme
   ./update-workflows.sh acme
   ```

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `ENV` | `local` | `local` (Kind) or `production` (existing K8s cluster) |
| `KUBECONFIG` | `~/.kube/kind-ingestion` | Path to kubeconfig |
| `TOOLBOX_IMAGE` | `insight-toolbox:local` | Docker image for toolbox |

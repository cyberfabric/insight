# Ingestion Stack

Data pipeline: External APIs → Airbyte → ClickHouse Bronze → dbt → Silver.
Everything runs in a Kubernetes cluster (Kind for local development).

## Concepts

### Insight Connector vs Airbyte Connector

An **Airbyte Connector** knows how to extract data from a specific API:
- `connector.yaml` — declarative manifest (or Docker image for CDK connectors)
- Implements Airbyte Protocol: check, discover, read

An **Insight Connector** is a complete pipeline package built around an Airbyte Connector:

```
Insight Connector = Airbyte Connector + descriptor + dbt transformations + credentials template
```

| Component | Purpose | Who manages |
|-----------|---------|-------------|
| `connector.yaml` | Airbyte manifest — how to extract data | Connector developer |
| `descriptor.yaml` | Schedule, streams, dbt_select, workflow type | Connector developer |
| `credentials.yaml.example` | Template listing required credentials | Connector developer |
| `dbt/` | Bronze → Silver transformations | Connector developer |
| `connections/{tenant}.yaml` | Real credentials per tenant | Tenant admin |

Connector developers create the package. Tenant admins only fill in credentials — they never touch the connector code.

### Credential Separation

Credentials are strictly separated from connector code:

```
connectors/collaboration/m365/            # In repo (shared, read-only for tenants)
  connector.yaml                          #   Airbyte manifest
  descriptor.yaml                         #   Metadata + schedule
  credentials.yaml.example                #   Template: which credentials are needed
  dbt/                                    #   Transformations

connections/                              # Per-tenant credentials
  example-tenant.yaml.example             #   Template (tracked in repo)
  example-tenant.yaml                     #   Real credentials (NEVER committed)
```

One tenant = one file with all credentials for all connectors:

```yaml
# connections/acme-corp.yaml (gitignored — never committed)
tenant_id: acme_corp

connectors:
  m365:
    azure_tenant_id: "63b4c45f-..."
    azure_client_id: "309e3a13-..."
    azure_client_secret: "G2x8Q~..."
  bamboohr:
    api_key: "abc123..."
    subdomain: "acme"
  jira:
    domain: "acme.atlassian.net"
    email: "integration@acme.com"
    api_token: "ATATT3x..."
```

Each connector's `credentials.yaml.example` documents what's required:

```yaml
# connectors/collaboration/m365/credentials.yaml.example
# Required credentials for M365 connector
azure_tenant_id: ""       # Azure AD tenant ID
azure_client_id: ""       # App registration client ID
azure_client_secret: ""   # App registration client secret
```

## Prerequisites

```bash
brew install kind kubectl helm
```

## Quick Start

```bash
# 1. Start the cluster (creates namespaces, deploys Airbyte + Argo)
#    ClickHouse will be skipped until its Secret exists
./up.sh

# 2. Create and apply secrets
cp secrets/clickhouse.yaml.example secrets/clickhouse.yaml
cp secrets/airbyte.yaml.example secrets/airbyte.yaml
cp secrets/connectors/m365.yaml.example secrets/connectors/m365.yaml
# Edit each .yaml with real credentials
./secrets/apply.sh

# 3. Re-run up.sh — now ClickHouse will deploy
./up.sh

# 4. Initialize (register connectors, create connections, sync workflows)
./run-init.sh

# 5. Run a sync
./run-sync.sh m365 my-tenant
```

## Commands

### Lifecycle

| Command | Description |
|---------|-------------|
| `./up.sh` | Create cluster and deploy services (idempotent, safe to re-run) |
| `./secrets/apply.sh` | Apply K8s Secrets (infra + connectors). Run after `up.sh` |
| `./run-init.sh` | Initialize: create databases, register connectors, apply connections. Run after secrets |
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

### ClickHouse Credentials

**Production:** password from K8s Secret `clickhouse-credentials` in namespace `data` (see [Production Deployment](#production-deployment)).

**Local (Kind):** falls back to default password `clickhouse` from `k8s/clickhouse/configmap.yaml` when Secret is absent.

**Any environment:**

```bash
# Read password from Secret (production)
kubectl get secret clickhouse-credentials -n data -o jsonpath='{.data.password}' | base64 -d

# Quick test
kubectl exec -n data deploy/clickhouse -- clickhouse-client --password "$(kubectl get secret clickhouse-credentials -n data -o jsonpath='{.data.password}' | base64 -d 2>/dev/null || echo clickhouse)" --query "SELECT currentUser()"
```

### Airbyte Credentials

**Local (Kind):** API at `http://localhost:8000`. Token and workspace ID are resolved automatically.

**Any environment:**

```bash
# Sets AIRBYTE_API, AIRBYTE_TOKEN, WORKSPACE_ID
source ./scripts/resolve-airbyte-env.sh

# Quick test
curl -s -H "Authorization: Bearer $AIRBYTE_TOKEN" "$AIRBYTE_API/api/v1/health"
```

In-cluster API address: `http://airbyte-airbyte-server-svc.airbyte.svc.cluster.local:8001`.

### Argo Credentials

**Local (Kind):** UI at `http://localhost:30500`, no authentication (`--auth-mode=server`).

**Production:** UI requires a Bearer token (`--auth-mode=client`):

```bash
# Create a ServiceAccount for UI access (one-time)
kubectl create sa argo-admin -n argo
kubectl create clusterrolebinding argo-admin --clusterrole=admin --serviceaccount=argo:argo-admin

# Get a token (valid 24h)
kubectl create token argo-admin -n argo --duration=24h

# Paste the token into the Argo UI login page
```

**Any environment:**

```bash
# List recent workflows
kubectl get workflows -n argo --sort-by=.metadata.creationTimestamp --no-headers | tail -5
```

## Project Structure

```
src/ingestion/
│
├── up.sh / down.sh / cleanup.sh    # Cluster lifecycle
├── run-init.sh                      # Initialize after secrets applied
├── run-sync.sh                      # Manual pipeline run
├── update-connectors.sh             # Re-upload manifests
├── update-connections.sh            # Re-apply connections
├── update-workflows.sh              # Regenerate schedules
│
├── connectors/                      # Insight Connector packages
│   └── collaboration/m365/
│       ├── connector.yaml           #   Airbyte declarative manifest
│       ├── descriptor.yaml          #   Schedule, streams, dbt_select
│       ├── credentials.yaml.example #   Credential template (tracked)
│       ├── schemas/                 #   Generated JSON schemas (gitignored)
│       └── dbt/
│           ├── m365__comms_events.sql  # Bronze → Staging model
│           └── schema.yml              # Source + tests
│
├── connections/                     # Tenant configs + Airbyte state
│   ├── example-tenant.yaml.example  #   Template (tracked)
│   ├── example-tenant.yaml          #   Real credentials (gitignored)
│   └── .airbyte-state.yaml          #   Airbyte IDs registry (gitignored, auto-generated)
│
├── secrets/                         # K8s Secrets (all gitignored, examples tracked)
│   ├── apply.sh                     #   Apply all secrets (infra + connectors)
│   ├── clickhouse.yaml.example      #   ClickHouse password
│   ├── airbyte.yaml.example         #   Airbyte admin credentials
│   └── connectors/                  #   Per-connector secrets
│       ├── m365.yaml.example        #     M365 OAuth credentials
│       └── zoom.yaml.example        #     Zoom OAuth credentials
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
├── scripts/                         # Internal scripts (run inside toolbox)
│   ├── init.sh                      #   Full initialization
│   ├── resolve-airbyte-env.sh       #   JWT token + workspace resolution
│   ├── airbyte-state.sh             #   State library (state_get/state_set)
│   ├── sync-airbyte-state.sh        #   Sync state from Airbyte API
│   ├── upload-manifests.sh          #   Register connectors via API
│   ├── apply-connections.sh         #   Create sources/destinations/connections
│   ├── sync-flows.sh               #   Generate + apply CronWorkflows
│   └── wait-for-services.sh        #   kubectl wait for pods
│
└── tools/
    ├── toolbox/                     # insight-toolbox Docker image
    │   ├── Dockerfile               #   python + dbt + kubectl + yq
    │   └── build.sh                 #   Build + load into Kind
    └── declarative-connector/       # Local connector debugging
        └── source.sh               #   check / discover / read
```

## Airbyte State

All Airbyte resource IDs (definitions, sources, destinations, connections) are tracked in
`connections/.airbyte-state.yaml`. This file is auto-generated and gitignored — it's specific
to the current Airbyte instance.

```yaml
# connections/.airbyte-state.yaml (auto-generated)
workspace_id: "8564ee19-..."
definitions:
  m365: "f8b1f832-..."
  zoom: "1227c334-..."
tenants:
  example-tenant:
    destinations:
      m365: "09e5fc84-..."
      zoom: "cb676fc0-..."
    sources:
      m365: "591af227-..."
      zoom: "73dab641-..."
    connections:
      m365: "b4a78d7b-..."
      zoom: "d04a508a-..."
```

Scripts read/write this state automatically. If state gets out of sync:

```bash
./scripts/sync-airbyte-state.sh    # re-fetch all IDs from Airbyte API
```

**Storage backend**:
- **Local (host)**: file `connections/.airbyte-state.yaml`
- **In-cluster (K8s)**: ConfigMap `airbyte-state` in namespace `data`
- Scripts auto-detect the backend

## Adding a New Connector

1. Create the Insight Connector package:
   ```
   connectors/{category}/{name}/
     connector.yaml            # Airbyte manifest
     descriptor.yaml           # name, schedule, streams, dbt_select, workflow
     credentials.yaml.example  # Required credentials (template)
     dbt/
       to_{domain}.sql         # Transformation
       schema.yml              # Source definition + tests
   ```

2. Create K8s Secret with connector credentials:
   ```yaml
   # secrets/connectors/new-connector.yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: insight-new-connector-main
     labels:
       app.kubernetes.io/part-of: insight
     annotations:
       insight.cyberfabric.com/connector: new_connector
       insight.cyberfabric.com/source-id: new-connector-main
   type: Opaque
   stringData:
     api_key: "..."
     # All parameters required by connector spec
   ```

3. Deploy:
   ```bash
   ./update-connectors.sh
   ./update-connections.sh my-tenant
   ./update-workflows.sh my-tenant
   ```

## Adding a New Tenant

1. Create tenant config:
   ```bash
   cat > connections/acme.yaml <<EOF
   tenant_id: acme
   EOF
   ```

2. Create K8s Secrets for each connector (see `secrets/connectors/*.yaml.example`)

3. Deploy:
   ```bash
   ./secrets/apply.sh --connectors-only
   ./run-init.sh
   ```

## Production Deployment

### Prerequisites

A running K8s cluster with `kubectl` access. Set environment:

```bash
export ENV=production
export KUBECONFIG=/path/to/your/kubeconfig
```

### Step 1: Deploy Services

```bash
./up.sh   # Uses ENV=production, applies production Helm values
```

### Step 2: Create and Apply Secrets

All credentials are stored in K8s Secrets. Example templates live in `secrets/`:

```bash
# Copy example templates and fill in real credentials
cp secrets/clickhouse.yaml.example secrets/clickhouse.yaml
cp secrets/airbyte.yaml.example secrets/airbyte.yaml
cp secrets/connectors/m365.yaml.example secrets/connectors/m365.yaml
cp secrets/connectors/zoom.yaml.example secrets/connectors/zoom.yaml
# Edit each .yaml file with real credentials
```

Apply all secrets at once:

```bash
./secrets/apply.sh                    # All (infra + connectors)
./secrets/apply.sh --infra-only       # Only infrastructure secrets
./secrets/apply.sh --connectors-only  # Only connector secrets
```

### Step 3: Initialize

```bash
./run-init.sh   # Creates databases, registers connectors, applies connections, syncs workflows
```

### Required Secrets Summary

| Secret | Namespace | Keys | Required |
|--------|-----------|------|----------|
| `clickhouse-credentials` | `data` + `argo` | `password` | Yes |
| `airbyte-admin-credentials` | `airbyte` | `email`, `password` | Yes |
| `insight-{connector}-{source-id}` | `data` | Connector-specific | Per connector |

### Password Rotation

To change ClickHouse password:

```bash
# 1. Update Secret file
vim secrets/clickhouse.yaml   # set new password

# 2. Apply to cluster (both data and argo namespaces)
./secrets/apply.sh --infra-only

# 3. Restart ClickHouse to pick up new password
kubectl rollout restart deployment/clickhouse -n data
kubectl rollout status deployment/clickhouse -n data

# 4. Update Airbyte destination + connections with new password
./scripts/apply-connections.sh example-tenant
```

ClickHouse uses `strategy: Recreate` — the old pod is terminated before the new one starts. This avoids PVC conflicts (ReadWriteOnce) and ensures the new password takes effect immediately.

`apply-connections.sh` always updates the destination password from K8s Secret on every run. Existing connections are reused (they reference the destination by ID).

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `ENV` | `local` | `local` (Kind) or `production` (existing K8s cluster) |
| `KUBECONFIG` | `~/.kube/kind-ingestion` | Path to kubeconfig |
| `TOOLBOX_IMAGE` | `insight-toolbox:local` | Docker image for toolbox |

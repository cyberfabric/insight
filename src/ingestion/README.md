# Ingestion Stack

Data pipeline: External APIs → Airbyte → ClickHouse Bronze → dbt → Silver.
Everything runs in a Kubernetes cluster (Kind for local development, K8s for production).

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
| `connections/{tenant}.yaml` | Tenant identity (tenant_id only) | Platform admin |

Connector developers create the package. Credentials are managed via K8s Secrets — never in tenant YAML or repo.

### Credential Separation

Credentials are strictly separated from connector code and tenant config:

```
connectors/collaboration/m365/            # In repo (shared, read-only for tenants)
  connector.yaml                          #   Airbyte manifest
  descriptor.yaml                         #   Metadata + schedule
  README.md                               #   K8s Secret fields documentation
  dbt/                                    #   Transformations

connections/                              # Tenant identity only
  example-tenant.yaml.example             #   Template (tracked in repo)
  example-tenant.yaml                     #   Tenant config (gitignored)

secrets/connectors/                       # K8s Secret templates
  m365.yaml.example                       #   Template (tracked in repo)
  m365.yaml                               #   Real credentials (gitignored)
```

Tenant config contains ONLY `tenant_id` — no credentials, no connector list:

```yaml
# connections/acme-corp.yaml
tenant_id: acme_corp
```

All credentials and connector parameters are in K8s Secrets. Active connectors are discovered automatically by label `app.kubernetes.io/part-of=insight`:

```yaml
# secrets/connectors/m365.yaml (gitignored — never committed)
apiVersion: v1
kind: Secret
metadata:
  name: insight-m365-main
  labels:
    app.kubernetes.io/part-of: insight
  annotations:
    insight.cyberfabric.com/connector: m365
    insight.cyberfabric.com/source-id: m365-main
type: Opaque
stringData:
  azure_tenant_id: "63b4c45f-..."
  azure_client_id: "309e3a13-..."
  azure_client_secret: "G2x8Q~..."
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

The ingestion stack is deployed as part of the Insight platform. Use the **root-level scripts** to manage the cluster:

```bash
# From the repo root:
./dev-up.sh          # Create cluster + deploy all services (including ingestion)
./init.sh        # Apply secrets + initialize ingestion
./dev-down.sh        # Stop everything
./cleanup.sh     # Delete cluster and all data
```

See the root [README.md](../../README.md) for full Quick Start instructions.

## Ingestion-only Quick Start

If the cluster is already running and you only need to work with ingestion:

```bash
# Ensure KUBECONFIG is set
export KUBECONFIG=~/.kube/insight.kubeconfig

# Apply secrets (if not already done)
./secrets/apply.sh

# Initialize (register connectors, create connections, sync workflows)
./run-init.sh

# Run a sync
./run-sync.sh m365 my-tenant
```

## Commands

### Lifecycle

| Command | Description |
|---------|-------------|
| `./dev-up.sh` | Create cluster and deploy services (idempotent, safe to re-run) |
| `./secrets/apply.sh` | Apply K8s Secrets (infra + connectors). Run after `dev-up.sh` |
| `./run-init.sh` | Initialize: create databases, register connectors, apply connections. Run after secrets |
| `./dev-down.sh` | Stop all services. **Data preserved** |
| `./cleanup.sh` | Delete cluster and all data. Asks for confirmation |

### Day-to-day

| Command | Description |
|---------|-------------|
| `./run-sync.sh <connector> <tenant>` | Run sync + dbt pipeline now |
| `./update-connectors.sh` | Re-upload all connector manifests/images to Airbyte (auto-detects nocode vs CDK) |
| `./update-connections.sh [tenant]` | Re-create sources, destinations, connections |
| `./update-workflows.sh [tenant]` | Regenerate CronWorkflow schedules |

### CDK Connectors

| Command | Description |
|---------|-------------|
| `./airbyte-toolkit/build-connector.sh <path> [--push]` | Build Docker image, push to registry (or load into Kind), register Airbyte definition |
| `./airbyte-toolkit/reset-connector.sh <name> <tenant>` | Delete connection + source + definition, drop Bronze tables, clean state |

### Examples

```bash
# Run M365 sync for example_tenant
./run-sync.sh m365 example-tenant

# Update after editing connector.yaml (nocode) or Python source (CDK)
./update-connectors.sh

# Build/rebuild a CDK connector (Docker image + Airbyte definition)
./airbyte-toolkit/build-connector.sh git/github

# Update after changing tenant credentials
./update-connections.sh example-tenant

# Update after changing schedule in descriptor.yaml
./update-workflows.sh

# Reset a connector (breaking schema change, full re-sync)
./airbyte-toolkit/reset-connector.sh github example-tenant

# Monitor workflows
open http://localhost:30500
```

## Services

After `./dev-up.sh`:

| Service | URL | Credentials |
|---------|-----|-------------|
| Airbyte | http://localhost:8001 | Port-forward |
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

**Local (Kind):** API at `http://localhost:8001`. Token and workspace ID are resolved automatically.

**Any environment:**

```bash
# Sets AIRBYTE_API, AIRBYTE_TOKEN, WORKSPACE_ID
source ./airbyte-toolkit/lib/env.sh

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
│           ├── m365__collab_*.sql       # Bronze → Staging models
│           └── schema.yml              # Source + tests
│
├── connections/                     # Tenant configs
│   ├── example-tenant.yaml.example  #   Template (tracked)
│   └── example-tenant.yaml          #   Real credentials (gitignored)
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
│   ├── identity/                    #   Identity-resolution engine
│   └── macros/                      #   union_by_tag
│
├── silver/                          # Silver layer, split by domain
│   ├── _shared/                     #   Cross-domain (class_people, bootstrap_inputs)
│   ├── git/                         #   class_git_* union models
│   ├── collaboration/               #   class_collab_* (chat, meeting, email, document)
│   └── crm/                         #   class_crm_*
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
├── airbyte-toolkit/                 # Airbyte management module
│   ├── register.sh                  #   Register connectors via API
│   ├── connect.sh                   #   Create sources/destinations/connections
│   ├── sync-state.sh                #   Sync state from Airbyte API
│   ├── cleanup.sh                   #   Remove Airbyte resources
│   ├── state.yaml                   #   Airbyte IDs registry (gitignored, auto-generated)
│   └── lib/
│       ├── env.sh                   #   JWT token + workspace resolution
│       └── state.sh                 #   State library (state_get/state_set)
│
├── scripts/                         # Internal scripts (run inside toolbox)
│   ├── init.sh                      #   Full initialization
│   ├── build-connector.sh           #   Build CDK connector (Docker → registry/Kind → Airbyte)
│   ├── reset-connector.sh           #   Reset connector (delete all + drop tables + clean state)
│   ├── sync-flows.sh               #   Generate + apply CronWorkflows
│   └── wait-for-services.sh        #   kubectl wait for pods
│
└── tools/
    ├── toolbox/                     # insight-toolbox Docker image (insight-toolbox)
    │   ├── Dockerfile               #   python + dbt + kubectl + yq
    │   └── build.sh                 #   Build + push to GHCR (or load into Kind)
    └── declarative-connector/       # Local connector debugging
        └── source.sh               #   check / discover / read
```

## Airbyte State

All Airbyte resource IDs (definitions, sources, destinations, connections) are tracked in a
single state file: `airbyte-toolkit/state.yaml`. This file is auto-generated and gitignored —
it's specific to the current Airbyte instance.

```yaml
# airbyte-toolkit/state.yaml (auto-generated, single file for all tenants)
workspace_id: "4f79767b-..."

destinations:
  clickhouse:
    id: "731c8d42-..."

definitions:
  m365:
    id: "046ef483-..."
  zoom:
    id: "a1b2c3d4-..."

tenants:
  example-tenant:
    connectors:
      m365:
        m365-main:
          source_id: "60c560e8-..."
          connection_id: "0220d2fe-..."
      zoom:
        zoom-main:
          source_id: "b2c3d4e5-..."
          connection_id: "c3d4e5f6-..."
```

Every ID is accessed via a deterministic YAML path (no string concatenation, no search):

| Resource | Path |
|----------|------|
| Workspace | `workspace_id` |
| Destination | `destinations.clickhouse.id` |
| Definition | `definitions.{connector}.id` |
| Source | `tenants.{tenant}.connectors.{connector}.{source_id}.source_id` |
| Connection | `tenants.{tenant}.connectors.{connector}.{source_id}.connection_id` |

**Storage backend**:
- **Local (host)**: `airbyte-toolkit/state.yaml`
- **In-cluster (K8s)**: ConfigMap `airbyte-state` in namespace `data`
- Scripts auto-detect the backend

## Adding a New Connector

### Nocode (declarative YAML)

1. Create package:
   ```
   connectors/{category}/{name}/
     connector.yaml            # Airbyte declarative manifest
     descriptor.yaml           # name, schedule, dbt_select, workflow, connection namespace
     dbt/                      # Bronze → Silver models
   ```

2. Create K8s Secret (see [Connector Credentials](#connector-credentials-via-k8s-secrets)):
   ```bash
   cp secrets/connectors/m365.yaml.example secrets/connectors/new-connector.yaml
   # Edit with real credentials, then apply
   ./secrets/apply.sh --connectors-only
   ```

3. Deploy:
   ```bash
   ./update-connectors.sh          # Registers manifest in Airbyte
   ./update-connections.sh my-tenant
   ./update-workflows.sh my-tenant
   ```

### CDK (Python)

1. Create package:
   ```
   connectors/{category}/{name}/
     Dockerfile                # Airbyte Python CDK image
     source_{name}/            # Python source code
       source.py, spec.json, streams/
     descriptor.yaml           # type: cdk, name, schedule, dbt_select, workflow
     dbt/                      # Bronze → Silver models
   ```

2. Create K8s Secret and apply (same as nocode).

3. Deploy:
   ```bash
   ./airbyte-toolkit/build-connector.sh {category}/{name}   # Build image + register definition
   ./airbyte-toolkit/connect.sh my-tenant             # Create source + connection
   ./update-workflows.sh my-tenant
   ```

### Reset (breaking schema change)

```bash
./airbyte-toolkit/reset-connector.sh <name> <tenant>   # Delete everything + drop Bronze tables
# Then re-deploy using the steps above
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
./dev-up.sh   # Uses ENV=production, applies production Helm values
```

### Step 2: Build and Load Toolbox Image

Argo workflow templates use `insight-toolbox:local` for dbt jobs.
The image is built locally and loaded into the cluster:

```bash
cd src/ingestion
./tools/toolbox/build.sh   # Builds and loads into Kind (done automatically by up.sh)
```

### Step 3: Create and Apply Secrets

All credentials are stored in K8s Secrets. Example templates live in `secrets/`:

```bash
# Copy example templates and fill in real credentials
cp secrets/clickhouse.yaml.example secrets/clickhouse.yaml
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

### Step 4: Initialize

```bash
./run-init.sh   # Creates databases, registers connectors, applies connections, syncs workflows
```

### Required Secrets Summary

| Secret | Namespace | Keys | Created by |
|--------|-----------|------|------------|
| `clickhouse-credentials` | `data` + `argo` | `username`, `password` | `secrets/apply.sh` |
| `airbyte-auth-secrets` | `airbyte` | `instance-admin-password`, ... | Helm chart (auto) |
| `insight-{connector}-{source-id}` | `data` | Connector-specific | `secrets/apply.sh` |

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
./airbyte-toolkit/connect.sh example-tenant
```

ClickHouse uses `strategy: Recreate` — the old pod is terminated before the new one starts. This avoids PVC conflicts (ReadWriteOnce) and ensures the new password takes effect immediately.

`connect.sh` always updates the destination password from K8s Secret on every run. Existing connections are reused (they reference the destination by ID).

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `ENV` | `local` | `local` (Kind) or `production` (existing K8s cluster) |
| `KUBECONFIG` | `~/.kube/insight.kubeconfig` | Path to kubeconfig |
| `TOOLBOX_IMAGE_TAG` | `$IMAGE_TAG` | Tag for toolbox image (uses same registry as other services) |
| `TOOLBOX_IMAGE` | auto | Full image override, e.g. `ghcr.io/cyberfabric/insight-toolbox:2026.04.21.14.30-abc1234` |

The Argo workflow templates (`dbt-run`, `ingestion-pipeline`) also accept a `toolbox_image` parameter to override the image at submission time.
